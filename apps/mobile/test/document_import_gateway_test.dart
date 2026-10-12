import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/features/document_import/data/document_import_gateway.dart';
import 'package:university_schedule_mobile/features/document_import/data/drift_document_import_repository.dart';
import 'package:university_schedule_mobile/features/document_import/domain/document_import_models.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const owner = '11111111-1111-4111-8111-111111111111';
  const source = '22222222-2222-4222-8222-222222222222';
  const path = '$owner/$source/source.pdf';

  test(
    'active replay uses the authoritative rotated source id end to end',
    () async {
      final fileBytes = Uint8List.fromList(utf8.encode('course handout'));
      final file = DocumentSelectedFile.validate(
        extension: 'txt',
        declaredSize: fileBytes.length,
        bytes: fileBytes,
      );
      final authoritativePath = '$owner/$source/source.txt';
      final candidateKey = '$source:assignment:1';
      final batch = _batch(
        sourceId: source,
        contentHash: file.contentHash,
        candidateKey: candidateKey,
      );
      final requests = <http.Request>[];
      var markAttempts = 0;
      String? requestedSourceId;
      final client = await _client(
        owner: owner,
        handler: (request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/rest/v1/rpc/create_document_source':
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requestedSourceId = body['p_source_id']! as String;
              return _jsonResponse(
                request,
                {
                  'source_id': source,
                  'storage_path': authoritativePath,
                  'processing_state': 'pending_upload',
                  'replayed': true,
                },
              );
            case '/rest/v1/rpc/mark_document_source_uploaded':
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              expect(body, {'p_source_id': source});
              markAttempts++;
              if (markAttempts == 1) {
                return _jsonResponse(
                  request,
                  {
                    'code': '22023',
                    'message': 'The object is not uploaded yet.',
                    'details': null,
                    'hint': null,
                  },
                  status: 409,
                );
              }
              return _jsonResponse(
                request,
                {'processing_state': 'uploaded', 'version': 2},
              );
            case '/functions/v1/document-import':
              expect(jsonDecode(request.body), {'source_id': source});
              return http.Response(
                const DocumentCandidateBatchCodec().encode(batch),
                200,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            case '/rest/v1/document_candidates':
              expect(request.url.queryParameters['source_id'], 'eq.$source');
              return _jsonResponse(request, [
                {
                  'id': '33333333-3333-4333-8333-333333333333',
                  'candidate_key': candidateKey,
                  'version': 1,
                },
              ]);
            default:
              if (request.url.path ==
                  '/storage/v1/object/$documentStorageBucket/'
                      '$authoritativePath') {
                return _jsonResponse(
                  request,
                  {'Key': '$documentStorageBucket/$authoritativePath'},
                );
              }
              fail('Unexpected request: ${request.method} ${request.url}');
          }
        },
      );
      addTearDown(client.dispose);
      final gateway = SupabaseDocumentImportGateway(
        client: client,
        authenticatedUserId: () => owner,
      );

      final result = await gateway.analyze(file);

      expect(requestedSourceId, isNot(source));
      expect(result.batch.sourceId, source);
      expect(result.storagePath, authoritativePath);
      expect(result.remoteSourceVersion, 2);
      expect(result.remoteCandidates.keys, [candidateKey]);
      expect(markAttempts, 2);
      expect(
        requests.any(
          (request) =>
              request.url.path ==
              '/storage/v1/object/$documentStorageBucket/'
                  '$authoritativePath',
        ),
        isTrue,
      );
    },
  );

  test('cancelling a processed replay never deletes the existing source',
      () async {
    final fileBytes = Uint8List.fromList(utf8.encode('processed handout'));
    final file = DocumentSelectedFile.validate(
      extension: 'txt',
      declaredSize: fileBytes.length,
      bytes: fileBytes,
    );
    final candidateKey = '$source:assignment:1';
    final batch = _batch(
      sourceId: source,
      contentHash: file.contentHash,
      candidateKey: candidateKey,
    );
    final cancellation = DocumentImportCancellation();
    final requests = <http.Request>[];
    final client = await _client(
      owner: owner,
      handler: (request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/rest/v1/rpc/create_document_source':
            return _jsonResponse(request, {
              'source_id': source,
              'storage_path': '$owner/$source/source.txt',
              'processing_state': 'processed',
              'replayed': true,
            });
          case '/rest/v1/document_candidates':
            expect(
              request.url.queryParameters['select'],
              'candidate_key,validated_payload',
            );
            cancellation.cancel();
            return _jsonResponse(request, [
              {
                'candidate_key': candidateKey,
                'validated_payload': documentCandidateToJson(
                  batch.candidates.single,
                  sourceId: source,
                  contentHash: file.contentHash,
                ),
              },
            ]);
          case '/rest/v1/rpc/delete_document_source':
            fail('A replayed processed source must never be cancelled away.');
          default:
            fail('Unexpected request: ${request.method} ${request.url}');
        }
      },
    );
    addTearDown(client.dispose);
    final gateway = SupabaseDocumentImportGateway(
      client: client,
      authenticatedUserId: () => owner,
    );

    await expectLater(
      gateway.analyze(file, cancellation: cancellation),
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.cancelled,
        ),
      ),
    );

    expect(
      requests.where(
        (request) => request.url.path == '/rest/v1/rpc/delete_document_source',
      ),
      isEmpty,
    );
  });

  test(
      'fresh reservation cancellation cannot delete a source concurrently replayed and cached',
      () async {
    final fileBytes = Uint8List.fromList(utf8.encode('new handout'));
    final file = DocumentSelectedFile.validate(
      extension: 'txt',
      declaredSize: fileBytes.length,
      bytes: fileBytes,
    );
    final storagePath = '$owner/$source/source.txt';
    final candidateKey = '$source:assignment:1';
    final batch = _batch(
      sourceId: source,
      contentHash: file.contentHash,
      candidateKey: candidateKey,
    );
    final cancellation = DocumentImportCancellation();
    final requests = <http.Request>[];
    final replayDecisions = <bool>[];
    var createCalls = 0;
    late final DriftDocumentImportRepository repository;
    DocumentReviewBatch? replayBatch;
    final client = await _client(
      owner: owner,
      handler: (request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/rest/v1/rpc/create_document_source':
            final replayed = createCalls++ > 0;
            replayDecisions.add(replayed);
            return _jsonResponse(request, {
              'source_id': source,
              'storage_path': storagePath,
              'processing_state': replayed ? 'processed' : 'pending_upload',
              'replayed': replayed,
            });
          case '/rest/v1/document_candidates':
            final select = request.url.queryParameters['select'];
            if (select == 'candidate_key,validated_payload') {
              return _jsonResponse(request, [
                {
                  'candidate_key': candidateKey,
                  'validated_payload': documentCandidateToJson(
                    batch.candidates.single,
                    sourceId: source,
                    contentHash: file.contentHash,
                  ),
                },
              ]);
            }
            expect(select, 'id,candidate_key,version');
            return _jsonResponse(request, [
              {
                'id': '33333333-3333-4333-8333-333333333333',
                'candidate_key': candidateKey,
                'version': 1,
              },
            ]);
          case '/rest/v1/rpc/delete_document_source':
            fail(
                'Cancellation must never delete a concurrently replayed source.');
          default:
            if (request.url.path ==
                '/storage/v1/object/$documentStorageBucket/$storagePath') {
              replayBatch = await repository.analyze(file);
              cancellation.cancel();
              return _jsonResponse(
                request,
                {'Key': '$documentStorageBucket/$storagePath'},
              );
            }
            fail('Unexpected request: ${request.method} ${request.url}');
        }
      },
    );
    addTearDown(client.dispose);
    final gateway = SupabaseDocumentImportGateway(
      client: client,
      authenticatedUserId: () => owner,
    );
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => owner,
    );

    await expectLater(
      repository.analyze(file, cancellation: cancellation),
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.cancelled,
        ),
      ),
    );
    expect(replayDecisions, orderedEquals(const [false, true]));
    expect(replayBatch?.sourceId, source);
    expect(replayBatch?.candidates, hasLength(1));
    final cached = await repository.loadSource(
      ownerUserId: owner,
      sourceId: source,
    );
    expect(cached.candidates, hasLength(1));
    expect(await db.select(db.documentSourcesCache).get(), hasLength(1));
    expect(await db.select(db.documentCandidatesCache).get(), hasLength(1));
    expect(
      requests.where(
        (request) => request.url.path == '/rest/v1/rpc/delete_document_source',
      ),
      isEmpty,
    );
  });

  test('committed review acknowledgement remains observable after owner switch',
      () async {
    var activeOwner = owner;
    final fileBytes = Uint8List.fromList(utf8.encode('review handout'));
    final file = DocumentSelectedFile.validate(
      extension: 'txt',
      declaredSize: fileBytes.length,
      bytes: fileBytes,
    );
    final candidate = _batch(
      sourceId: source,
      contentHash: file.contentHash,
      candidateKey: '$source:assignment:1',
    ).candidates.single;
    final client = await _client(
      owner: owner,
      handler: (request) async {
        expect(
          request.url.path,
          '/rest/v1/rpc/update_document_candidate',
        );
        expect(jsonDecode(request.body), {
          'p_candidate_id': '33333333-3333-4333-8333-333333333333',
          'p_expected_version': 1,
          'p_payload': null,
          'p_action': 'deselect',
        });
        activeOwner = '44444444-4444-4444-8444-444444444444';
        return _jsonResponse(request, {'version': 2});
      },
    );
    addTearDown(client.dispose);
    final gateway = SupabaseDocumentImportGateway(
      client: client,
      authenticatedUserId: () => activeOwner,
    );

    final nextVersion = await gateway.updateCandidate(
      identity: const RemoteDocumentCandidateIdentity(
        id: '33333333-3333-4333-8333-333333333333',
        version: 1,
      ),
      candidate: candidate,
      action: 'deselect',
    );

    expect(nextVersion, 2);
    expect(activeOwner, isNot(owner));
  });

  test(
      'delete accepts the strict queued cleanup ack and never calls Storage remove',
      () async {
    final requests = <http.Request>[];
    final client = await _client(
      owner: owner,
      handler: (request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(_deletionAck(owner: owner, source: source)),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      },
    );
    addTearDown(client.dispose);
    final gateway = SupabaseDocumentImportGateway(
      client: client,
      authenticatedUserId: () => owner,
    );

    await gateway.deleteSource(sourceId: source, storagePath: path);

    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/rest/v1/rpc/delete_document_source');
    expect(jsonDecode(requests.single.body), {'p_source_id': source});
    expect(
      requests.where((request) => request.url.path.contains('/storage/v1/')),
      isEmpty,
    );
  });

  test('delete rejects mismatched or non-queued acknowledgements', () async {
    final invalid = <Map<String, Object?>>[
      _deletionAck(
          owner: owner, source: '33333333-3333-4333-8333-333333333333'),
      {
        ..._deletionAck(owner: owner, source: source),
        'storage_path': '$owner/$source/other.pdf'
      },
      {
        ..._deletionAck(owner: owner, source: source),
        'schedule_entities_retained': false
      },
      {
        ..._deletionAck(owner: owner, source: source),
        'storage_deletion_queued': false
      },
    ];

    for (final acknowledgement in invalid) {
      final client = await _client(
        owner: owner,
        handler: (request) async => http.Response(
          jsonEncode(acknowledgement),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      );
      final gateway = SupabaseDocumentImportGateway(
        client: client,
        authenticatedUserId: () => owner,
      );
      await expectLater(
        gateway.deleteSource(sourceId: source, storagePath: path),
        throwsA(
          isA<DocumentImportFailure>().having(
            (failure) => failure.category,
            'category',
            DocumentImportErrorCategory.internalError,
          ),
        ),
      );
      client.dispose();
    }
  });
}

Future<SupabaseClient> _client({
  required String owner,
  required Future<http.Response> Function(http.Request request) handler,
}) async {
  final client = SupabaseClient(
    'https://test.supabase.co',
    'test-publishable-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(handler),
  );
  final session = Session(
    accessToken: 'test-access-token',
    tokenType: 'bearer',
    user: User(
      id: owner,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.utc(2026, 8, 10).toIso8601String(),
    ),
  );
  await client.auth.recoverSession(jsonEncode(session.toJson()));
  return client;
}

Map<String, Object?> _deletionAck({
  required String owner,
  required String source,
}) {
  return {
    'source_id': source,
    'storage_path': '$owner/$source/source.pdf',
    'schedule_entities_retained': true,
    'storage_deletion_queued': true,
  };
}

ScheduleCandidateBatch _batch({
  required String sourceId,
  required String contentHash,
  required String candidateKey,
}) {
  return ScheduleCandidateBatch(
    schemaVersion: DocumentCandidateBatchCodec.schemaVersion,
    sourceId: sourceId,
    contentHash: contentHash,
    timezone: DocumentCandidateBatchCodec.timezone,
    candidates: [
      DocumentScheduleCandidate(
        candidateId: candidateKey,
        type: DocumentCandidateType.assignment,
        title: 'レポート',
        courseHint: const DocumentCourseHint(name: '情報科学'),
        dueAt: DateTime.utc(2026, 8, 20, 14, 59),
        allDay: false,
        timezone: DocumentCandidateBatchCodec.timezone,
        confidence: const DocumentCandidateConfidence(
          overall: 0.9,
          course: 0.8,
          dateTime: 0.9,
        ),
        evidence: const [
          DocumentCandidateEvidence(
            pageNumber: 1,
            excerpt: '提出期限は8月20日23時59分',
          ),
        ],
        warnings: const [],
        requiresUserConfirmation: true,
      ),
    ],
  );
}

http.Response _jsonResponse(
  http.Request request,
  Object body, {
  int status = 200,
}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
    request: request,
  );
}
