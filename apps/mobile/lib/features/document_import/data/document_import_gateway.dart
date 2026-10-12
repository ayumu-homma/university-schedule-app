import 'package:shared_domain/document_import_trusted.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../domain/document_import_models.dart';

const documentStorageBucket = 'schedule-documents';
final _canonicalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, Object?> documentCandidateToJson(
  DocumentScheduleCandidate candidate, {
  required String sourceId,
  required String contentHash,
}) {
  final encoded = const DocumentCandidateBatchCodec().toJson(
    ScheduleCandidateBatch(
      schemaVersion: DocumentCandidateBatchCodec.schemaVersion,
      sourceId: sourceId,
      contentHash: contentHash,
      timezone: DocumentCandidateBatchCodec.timezone,
      candidates: [candidate],
    ),
  );
  return Map<String, Object?>.from(
    (encoded['candidates']! as List<Object?>).single! as Map,
  );
}

class SupabaseDocumentImportGateway implements DocumentImportGateway {
  SupabaseDocumentImportGateway({
    required this.client,
    required this.authenticatedUserId,
    Uuid uuid = const Uuid(),
  }) : _uuid = uuid;

  final SupabaseClient client;
  final String? Function() authenticatedUserId;
  final Uuid _uuid;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    final ownerUserId = _requireOwner();
    final requestedSourceId = _uuid.v5(
      Namespace.url.value,
      'document-source\u0000$ownerUserId\u0000${file.contentHash}',
    );
    try {
      cancellation?.throwIfCancelled();
      final created = _asMap(
        await client.rpc(
          'create_document_source',
          params: {
            'p_source_id': requestedSourceId,
            'p_media_type': file.mediaType.mimeType,
            'p_byte_size': file.byteLength,
            'p_content_hash': file.contentHash,
          },
        ),
      );
      final sourceId = _requiredString(created, 'source_id');
      final storagePath = _requiredString(created, 'storage_path');
      var processingState = _requiredString(created, 'processing_state');
      final replayed = created['replayed'] == true;
      if (!_isCanonicalUuid(sourceId) ||
          !_isOwnerStoragePath(storagePath, ownerUserId, sourceId)) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      cancellation?.throwIfCancelled();
      _requireOwner();

      int? remoteSourceVersion;
      if (processingState == 'pending_upload') {
        cancellation?.throwIfCancelled();
        onState?.call(DocumentImportState.uploading);
        if (replayed) {
          try {
            final marked = await _markUploaded(sourceId);
            cancellation?.throwIfCancelled();
            processingState = _requiredString(marked, 'processing_state');
            remoteSourceVersion = _optionalInt(marked['version']);
          } on Object {
            cancellation?.throwIfCancelled();
            await _upload(storagePath, file);
            cancellation?.throwIfCancelled();
            final marked = await _markUploaded(sourceId);
            cancellation?.throwIfCancelled();
            processingState = _requiredString(marked, 'processing_state');
            remoteSourceVersion = _optionalInt(marked['version']);
          }
        } else {
          await _upload(storagePath, file);
          cancellation?.throwIfCancelled();
          final marked = await _markUploaded(sourceId);
          cancellation?.throwIfCancelled();
          processingState = _requiredString(marked, 'processing_state');
          remoteSourceVersion = _optionalInt(marked['version']);
        }
      }

      late ScheduleCandidateBatch batch;
      if (processingState == 'processed') {
        batch = await _readProcessedBatch(
          sourceId: sourceId,
          contentHash: file.contentHash,
        );
        cancellation?.throwIfCancelled();
      } else {
        cancellation?.throwIfCancelled();
        onState?.call(DocumentImportState.analyzing);
        final session = client.auth.currentSession;
        if (session == null || session.user.id != ownerUserId) {
          throw const DocumentImportFailure(
            DocumentImportErrorCategory.configurationMissing,
          );
        }
        final response = await client.functions.invoke(
          'document-import',
          body: {'source_id': sourceId},
          headers: {'Authorization': 'Bearer ${session.accessToken}'},
        ).timeout(const Duration(seconds: 60));
        cancellation?.throwIfCancelled();
        if (response.status < 200 || response.status >= 300) {
          throw DocumentImportFailure(_categoryForStatus(response.status));
        }
        batch = _decodeBatch(response.data);
      }
      _validateBatchIdentity(batch, sourceId, file.contentHash);
      final identities = await _readRemoteCandidateIdentities(sourceId);
      cancellation?.throwIfCancelled();
      if (identities.length != batch.candidates.length ||
          batch.candidates.any(
            (candidate) => !identities.containsKey(candidate.candidateId),
          )) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      return DocumentAnalysisResult(
        batch: batch,
        storagePath: storagePath,
        remoteCandidates: identities,
        remoteSourceVersion: remoteSourceVersion,
      );
    } on Object catch (error) {
      if (cancellation?.isCancelled == true) {
        // `replayed: false` is only a create-time observation. Another caller
        // can replay this source immediately, so cancellation never retires
        // shared server state; retention cleanup owns abandoned uploads.
        throw const DocumentImportFailure(
            DocumentImportErrorCategory.cancelled);
      }
      if (error is DocumentImportFailure) rethrow;
      if (error is FunctionException) {
        throw DocumentImportFailure(_categoryForStatus(error.status));
      }
      if (error is PostgrestException) {
        throw DocumentImportFailure(_categoryForPostgrest(error.code));
      }
      if (error is StorageException) {
        throw DocumentImportFailure(
          _categoryForStatus(int.tryParse(error.statusCode ?? '')),
        );
      }
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
  }

  Future<void> _upload(
    String storagePath,
    DocumentSelectedFile file,
  ) async {
    await client.storage.from(documentStorageBucket).uploadBinary(
          storagePath,
          file.bytes,
          fileOptions: FileOptions(
            contentType: file.mediaType.mimeType,
            upsert: false,
          ),
        );
  }

  Future<Map<String, Object?>> _markUploaded(String sourceId) async {
    return _asMap(
      await client.rpc(
        'mark_document_source_uploaded',
        params: {'p_source_id': sourceId},
      ),
    );
  }

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async {
    _requireOwner();
    if (!const {'edit', 'select', 'deselect', 'exclude', 'restore'}
        .contains(action)) {
      throw ArgumentError.value(action, 'action');
    }
    try {
      final response = _asMap(
        await client.rpc(
          'update_document_candidate',
          params: {
            'p_candidate_id': identity.id,
            'p_expected_version': identity.version,
            'p_payload': action == 'edit'
                ? documentCandidateToJson(
                    candidate,
                    sourceId: _sourceIdFromCandidate(candidate),
                    contentHash: '0' * 64,
                  )
                : null,
            'p_action': action,
          },
        ),
      );
      final nextVersion = _optionalInt(response['version']);
      if (nextVersion == null || nextVersion <= identity.version) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      return nextVersion;
    } on PostgrestException catch (error) {
      throw DocumentImportFailure(_categoryForPostgrest(error.code));
    } on DocumentImportFailure {
      rethrow;
    } on Object {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    _requireOwner();
    try {
      final response = _asMap(
        await client.rpc(
          'confirm_document_candidate',
          params: {
            'p_candidate_id': identity.id,
            'p_expected_version': identity.version,
            'p_entity_id': entityId,
            'p_idempotency_key': idempotencyKey,
            'p_confirmed_payload': documentCandidateToJson(
              candidate,
              sourceId: _sourceIdFromCandidate(candidate),
              contentHash: '0' * 64,
            ),
            'p_course_id': courseId,
          },
        ),
      );
      _requireOwner();
      return DocumentRemoteConfirmation(
        entityType: DocumentCandidateType.fromWire(
          _requiredString(response, 'entity_type'),
        ),
        entityId: _requiredString(response, 'entity_id'),
        replayed: response['replayed'] == true,
      );
    } on PostgrestException catch (error) {
      throw DocumentImportFailure(_categoryForPostgrest(error.code));
    } on DocumentImportFailure {
      rethrow;
    } on Object {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {
    final ownerUserId = _requireOwner();
    try {
      final response = _asMap(
        await client.rpc(
          'delete_document_source',
          params: {'p_source_id': sourceId},
        ),
      );
      final returnedSourceId = _requiredString(response, 'source_id');
      final returnedPath = _requiredString(response, 'storage_path');
      if (returnedSourceId != sourceId ||
          (storagePath != null && returnedPath != storagePath) ||
          !_isOwnerStoragePath(returnedPath, ownerUserId, sourceId) ||
          response['schedule_entities_retained'] != true ||
          response['storage_deletion_queued'] != true) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      _requireOwner();
    } on PostgrestException catch (error) {
      throw DocumentImportFailure(_categoryForPostgrest(error.code));
    } on DocumentImportFailure {
      rethrow;
    } on Object {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
  }

  Future<ScheduleCandidateBatch> _readProcessedBatch({
    required String sourceId,
    required String contentHash,
  }) async {
    final rows = await client
        .from('document_candidates')
        .select('candidate_key, validated_payload')
        .eq('source_id', sourceId)
        .order('created_at');
    return const DocumentCandidateBatchCodec().decodeObject({
      'schema_version': DocumentCandidateBatchCodec.schemaVersion,
      'source_id': sourceId,
      'content_hash': contentHash,
      'timezone': DocumentCandidateBatchCodec.timezone,
      'candidates': [
        for (final row in rows) _asMap(row)['validated_payload'],
      ],
    });
  }

  Future<Map<String, RemoteDocumentCandidateIdentity>>
      _readRemoteCandidateIdentities(String sourceId) async {
    final rows = await client
        .from('document_candidates')
        .select('id, candidate_key, version')
        .eq('source_id', sourceId);
    return {
      for (final raw in rows)
        _requiredString(_asMap(raw), 'candidate_key'):
            RemoteDocumentCandidateIdentity(
          id: _requiredString(_asMap(raw), 'id'),
          version: _optionalInt(_asMap(raw)['version']) ?? 1,
        ),
    };
  }

  ScheduleCandidateBatch _decodeBatch(Object? data) {
    try {
      return data is String
          ? const DocumentCandidateBatchCodec().decode(data)
          : const DocumentCandidateBatchCodec().decodeObject(data);
    } on DocumentCandidateValidationException {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
  }

  void _validateBatchIdentity(
    ScheduleCandidateBatch batch,
    String sourceId,
    String contentHash,
  ) {
    if (batch.sourceId != sourceId ||
        batch.contentHash != contentHash ||
        batch.timezone != DocumentCandidateBatchCodec.timezone) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
  }

  String _requireOwner() {
    final expected = authenticatedUserId();
    final session = client.auth.currentSession;
    if (expected == null ||
        expected.isEmpty ||
        session == null ||
        session.user.id != expected) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.configurationMissing,
      );
    }
    return expected;
  }

  bool _isOwnerStoragePath(
    String path,
    String ownerUserId,
    String sourceId,
  ) {
    return path.startsWith('$ownerUserId/$sourceId/source.') &&
        !path.contains('..') &&
        !path.startsWith('/');
  }

  bool _isCanonicalUuid(String value) => _canonicalUuidPattern.hasMatch(value);

  // Candidate keys generated by the strict contract include their source ID.
  String _sourceIdFromCandidate(DocumentScheduleCandidate candidate) {
    final separator = candidate.candidateId.indexOf(':');
    return separator == -1
        ? candidate.candidateId
        : candidate.candidateId.substring(0, separator);
  }

  DocumentImportErrorCategory _categoryForStatus(int? status) {
    if (status == null) return DocumentImportErrorCategory.networkUnavailable;
    return switch (status) {
      408 || 504 => DocumentImportErrorCategory.timeout,
      413 => DocumentImportErrorCategory.oversizedFile,
      422 => DocumentImportErrorCategory.invalidExtraction,
      429 => DocumentImportErrorCategory.rateLimited,
      401 || 403 => DocumentImportErrorCategory.configurationMissing,
      >= 500 => DocumentImportErrorCategory.providerUnavailable,
      _ => DocumentImportErrorCategory.networkUnavailable,
    };
  }

  DocumentImportErrorCategory _categoryForPostgrest(String? code) {
    return switch (code) {
      '40001' => DocumentImportErrorCategory.networkUnavailable,
      '42501' => DocumentImportErrorCategory.configurationMissing,
      '22023' => DocumentImportErrorCategory.invalidExtraction,
      'P0001' => DocumentImportErrorCategory.rateLimited,
      _ => DocumentImportErrorCategory.networkUnavailable,
    };
  }
}

/// Explicit secret-free composition for local demo, widget tests, and CI.
class FakeDocumentImportGateway implements DocumentImportGateway {
  FakeDocumentImportGateway({
    required this.ownerUserId,
    Uuid uuid = const Uuid(),
    DocumentScheduleExtractor extractor =
        const DeterministicDocumentScheduleExtractor(),
  })  : _uuid = uuid,
        _extractor = GuardedDocumentScheduleExtractor(extractor);

  final String ownerUserId;
  final Uuid _uuid;
  final DocumentScheduleExtractor _extractor;

  @override
  bool get confirmsOnServer => false;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final sourceId = _uuid.v5(
      Namespace.url.value,
      'document-demo-source\u0000$ownerUserId\u0000${file.contentHash}',
    );
    onState?.call(DocumentImportState.uploading);
    cancellation?.throwIfCancelled();
    onState?.call(DocumentImportState.analyzing);
    final batch = await _extractor.extract(
      SanitizedDocumentInput(
        sourceId: sourceId,
        contentHash: file.contentHash,
        mediaType: file.mediaType,
        byteLength: file.byteLength,
        pageCount: 1,
        sanitizedText: 'Synthetic class document fixture for local demo.',
        uploadedAt: DateTime.utc(2026, 8, 10),
      ),
    );
    cancellation?.throwIfCancelled();
    return DocumentAnalysisResult(
      batch: batch,
      storagePath: null,
      remoteCandidates: const {},
      remoteSourceVersion: null,
    );
  }

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async {
    return identity.version;
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: entityId,
      replayed: false,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {}
}

Map<String, Object?> _asMap(Object? value) {
  if (value is! Map) {
    throw const DocumentImportFailure(
      DocumentImportErrorCategory.invalidExtraction,
    );
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _requiredString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is! String || field.isEmpty || field != field.trim()) {
    throw const DocumentImportFailure(
      DocumentImportErrorCategory.invalidExtraction,
    );
  }
  return field;
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}
