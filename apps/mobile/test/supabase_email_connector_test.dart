import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_connector_binding.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/supabase_email_connector.dart';

const _oauthClientId = 'client.apps.googleusercontent.com';
final _oauthRedirectUri = Uri.parse(
  'https://project.supabase.co/functions/v1/email-import',
);

void main() {
  const ownerUserId = '11111111-1111-4111-8111-111111111111';
  const connectionId = '22222222-2222-4222-8222-222222222222';

  test('disabled production connector stays disconnected without invocation',
      () async {
    var invoked = false;
    final connector = SupabaseEmailConnector(
      emailImportEnabled: false,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async {
        invoked = true;
        throw StateError('disabled connector must not call the endpoint');
      },
    );

    final state = await connector.connect();

    expect(state.status, EmailConnectionStatus.disconnected);
    expect(invoked, isFalse);
    await expectLater(
      connector.fetchDelta(),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.errorCategory,
          'category',
          EmailErrorCategory.configurationMissing,
        ),
      ),
    );
    expect(invoked, isFalse);
  });

  test('authenticated fetch sends only action, connection and opaque cursor',
      () async {
    final requests = <Map<String, Object?>>[];
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async {
        requests.add(body);
        return _successEnvelope();
      },
    );

    final page = await connector.fetchDelta(cursor: 'opaque-cursor-1');

    expect(requests, [
      {
        'action': 'fetch_delta',
        'connectionId': connectionId,
        'cursor': 'opaque-cursor-1',
      },
    ]);
    expect(requests.single.keys, isNot(contains('ownerUserId')));
    expect(requests.single.toString(), isNot(contains('token')));
    expect(page.nextCursor, 'opaque-cursor-2');
    expect(page.items, hasLength(1));
    expect(page.items.single.providerThreadId, 'provider-thread-1');
    expect(
      page.items.single.candidate!.candidateType,
      EmailCandidateType.assignment,
    );
    expect(page.items.single.candidate!.requiresUserConfirmation, isTrue);
  });

  test('failed message response contains no candidate or evidence', () async {
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (_) async => _failedEnvelope(),
    );

    final item = (await connector.fetchDelta()).items.single;

    expect(item.providerThreadId, isNull);
    expect(item.candidate, isNull);
    expect(item.evidenceExcerpts, isEmpty);
    expect(item.errorCategory, EmailErrorCategory.unsafeContent);
  });

  test('targeted retry uses one message and does not accept a cursor',
      () async {
    final requests = <Map<String, Object?>>[];
    final response = _successEnvelope();
    final page = response['page']! as Map<String, Object?>;
    page['nextCursor'] = null;
    response['retryOutcome'] = 'persisted';
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async {
        requests.add(body);
        return response;
      },
    );

    final result = await connector.retryCandidate(
      providerMessageId: 'provider-message-1',
      expectedProviderMessageIdHash: 'd' * 64,
      expectedSanitizedContentHash: 'f' * 64,
      retryIdempotencyKey: 'e' * 64,
    );

    expect(requests, [
      {
        'action': 'retry_candidate',
        'connectionId': connectionId,
        'providerMessageId': 'provider-message-1',
        'expectedSanitizedContentHash': 'f' * 64,
        'retryIdempotencyKey': 'e' * 64,
      },
    ]);
    expect(result.outcome, TargetedEmailRetryOutcome.persisted);
    expect(result.item?.candidate, isNotNull);
    expect(result.suppression, isNull);
  });

  test('targeted retry accepts one strict committed suppression ack', () async {
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (_) async => {
        'connection': _connection(status: 'connected'),
        'page': <String, Object?>{
          'items': <Object?>[],
          'suppressions': <Object?>[
            <String, Object?>{
              'providerMessageIdHash': 'd' * 64,
              'reason': 'dismissed',
            },
          ],
          'nextCursor': null,
          'hasMore': false,
        },
        'retryOutcome': 'suppressed',
      },
    );

    final result = await connector.retryCandidate(
      providerMessageId: 'provider-message-1',
      expectedProviderMessageIdHash: 'd' * 64,
      expectedSanitizedContentHash: 'f' * 64,
      retryIdempotencyKey: 'e' * 64,
    );

    expect(result.outcome, TargetedEmailRetryOutcome.suppressed);
    expect(result.item, isNull);
    expect(
      result.suppression?.reason,
      EmailFetchSuppressionReason.dismissed,
    );
  });

  test('targeted retry rejects a suppression hash for another message',
      () async {
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (_) async => {
        'connection': _connection(status: 'connected'),
        'page': <String, Object?>{
          'items': <Object?>[],
          'suppressions': <Object?>[
            <String, Object?>{
              'providerMessageIdHash': 'c' * 64,
              'reason': 'dismissed',
            },
          ],
          'nextCursor': null,
          'hasMore': false,
        },
        'retryOutcome': 'suppressed',
      },
    );

    await expectLater(
      connector.retryCandidate(
        providerMessageId: 'provider-message-1',
        expectedProviderMessageIdHash: 'd' * 64,
        expectedSanitizedContentHash: 'f' * 64,
        retryIdempotencyKey: 'e' * 64,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
  });

  test('unknown and duplicate suppression acks fail closed', () async {
    final unknown = <String, Object?>{
      'connection': _connection(status: 'connected'),
      'page': <String, Object?>{
        'items': <Object?>[],
        'suppressions': <Object?>[
          <String, Object?>{
            'providerMessageIdHash': 'd' * 64,
            'reason': 'invented',
          },
        ],
        'nextCursor': 'cursor-after-unknown',
        'hasMore': false,
      },
    };
    final duplicate = _successEnvelope();
    final duplicatePage = duplicate['page']! as Map<String, Object?>;
    duplicatePage['suppressions'] = <Object?>[
      <String, Object?>{
        'providerMessageIdHash': 'd' * 64,
        'reason': 'dismissed',
      },
      <String, Object?>{
        'providerMessageIdHash': 'd' * 64,
        'reason': 'dismissed',
      },
    ];

    for (final response in [unknown, duplicate]) {
      final connector = SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: connectionId,
        authenticatedUserIdOverride: () => ownerUserId,
        invokeOverride: (_) async => response,
      );
      await expectLater(
        connector.fetchDelta(),
        throwsA(isA<EmailImportFailure>()),
      );
    }
  });

  test('multiple account connectors keep opaque connection IDs separated',
      () async {
    const otherConnectionId = '33333333-3333-4333-8333-333333333333';
    final requests = <Map<String, Object?>>[];
    SupabaseEmailConnector connector(String boundConnectionId) {
      return SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: boundConnectionId,
        authenticatedUserIdOverride: () => ownerUserId,
        invokeOverride: (body) async {
          requests.add(body);
          return _successEnvelope();
        },
      );
    }

    await connector(connectionId).fetchDelta();
    await connector(otherConnectionId).fetchDelta();

    expect(
      requests.map((request) => request['connectionId']),
      [connectionId, otherConnectionId],
    );
    expect(requests.every((request) => !request.containsKey('ownerUserId')),
        isTrue);
  });

  test('connect exposes a safe failed state instead of provider diagnostics',
      () async {
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async => {
        'connection': _connection(
          status: 'failed',
          errorCategory: 'configuration_missing',
        ),
        'page': null,
      },
    );

    final state = await connector.connect();

    expect(state.status, EmailConnectionStatus.failed);
    expect(state.errorCategory, EmailErrorCategory.configurationMissing);
  });

  test('connect validates and exposes only the public OAuth challenge',
      () async {
    final now = DateTime.utc(2030, 4, 1);
    final requests = <Map<String, Object?>>[];
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      clock: () => now,
      expectedOAuthClientId: _oauthClientId,
      expectedOAuthRedirectUri: _oauthRedirectUri,
      invokeOverride: (body) async {
        requests.add(body);
        return _oauthEnvelope(now);
      },
    );

    final state = await connector.connect();

    expect(requests, [
      {'action': 'connect', 'connectionId': connectionId},
    ]);
    expect(state.status, EmailConnectionStatus.connecting);
    expect(state.oauthChallenge, isNotNull);
    expect(state.oauthChallenge!.authorizationUri.scheme, 'https');
    expect(state.oauthChallenge!.authorizationUri.host, 'accounts.google.com');
    expect(state.oauthChallenge!.codeChallenge, 'c' * 43);
    expect(
        state.oauthChallenge!.expiresAt, now.add(const Duration(minutes: 10)));
    expect(state.toString(), isNot(contains('access_token')));
    expect(state.toString(), isNot(contains('refresh_token')));
  });

  test('OAuth challenge rejects hostile origins, pins, ports and expiry',
      () async {
    final now = DateTime.utc(2030, 4, 1);
    final unsafeEnvelopes = <Map<String, Object?>>[
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(host: 'attacker.example'),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: '${_oauthAuthorizationUri()}#leak',
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri().replaceFirst(
          'https://accounts.google.com/',
          'https://accounts.google.com:444/',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          clientId: 'different.apps.googleusercontent.com',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          redirectUri: 'https://attacker.example/functions/v1/email-import',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          redirectUri: 'https://127.0.0.1/functions/v1/email-import',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          redirectUri:
              'https://project.supabase.co:444/functions/v1/email-import',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          redirectUri: 'https://project.supabase.co/functions/v1/other',
        ),
      ),
      _oauthEnvelope(
        now,
        authorizationUri: _oauthAuthorizationUri(
          redirectUri:
              'https://project.supabase.co/functions/v1/email-import?next=bad',
        ),
      ),
      _oauthEnvelope(
        now,
        expiresAt: now.add(const Duration(minutes: 16)),
      ),
    ];

    for (final envelope in unsafeEnvelopes) {
      final connector = SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: connectionId,
        authenticatedUserIdOverride: () => ownerUserId,
        clock: () => now,
        expectedOAuthClientId: _oauthClientId,
        expectedOAuthRedirectUri: _oauthRedirectUri,
        invokeOverride: (_) async => envelope,
      );
      await expectLater(
        connector.connect(),
        completion(
          isA<EmailConnectionState>()
              .having(
                (state) => state.status,
                'status',
                EmailConnectionStatus.failed,
              )
              .having(
                (state) => state.errorCategory,
                'category',
                anyOf(
                  EmailErrorCategory.unsafeUrl,
                  EmailErrorCategory.validationFailed,
                ),
              ),
        ),
      );
    }
  });

  test('OAuth challenge fails closed when trusted public pins are absent',
      () async {
    final now = DateTime.utc(2030, 4, 1);
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      clock: () => now,
      invokeOverride: (_) async => _oauthEnvelope(now),
    );

    final state = await connector.connect();

    expect(state.status, EmailConnectionStatus.failed);
    expect(state.errorCategory, EmailErrorCategory.configurationMissing);
  });

  test('authorization receipt check sends exact UUIDs and parses safe result',
      () async {
    const callbackCorrelationId = '33333333-3333-4333-8333-333333333333';
    const effectiveConnectionId = '44444444-4444-4444-8444-444444444444';
    final requests = <Map<String, Object?>>[];
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async {
        requests.add(body);
        return {
          'connection': _connection(status: 'connected'),
          'page': null,
          'authorization': {
            'effectiveConnectionId': effectiveConnectionId,
          },
        };
      },
    );

    final resolution = await connector.checkAuthorization(
      callbackCorrelationId: callbackCorrelationId,
    );

    expect(requests, [
      {
        'action': 'check_authorization',
        'connectionId': connectionId,
        'callbackCorrelationId': callbackCorrelationId,
      },
    ]);
    expect(resolution.effectiveConnectionId, effectiveConnectionId);
    expect(resolution.connection.status, EmailConnectionStatus.connected);
    expect(requests.single, isNot(contains('ownerUserId')));
  });

  test('authorization receipt check rejects unbound or expanded responses',
      () async {
    const callbackCorrelationId = '33333333-3333-4333-8333-333333333333';
    for (final authorization in <Map<String, Object?>>[
      {'effectiveConnectionId': 'not-a-uuid'},
      {
        'effectiveConnectionId': '44444444-4444-4444-8444-444444444444',
        'providerAccountHash': 'a' * 64,
      },
    ]) {
      final connector = SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: connectionId,
        authenticatedUserIdOverride: () => ownerUserId,
        invokeOverride: (_) async => {
          'connection': _connection(status: 'connected'),
          'page': null,
          'authorization': authorization,
        },
      );
      await expectLater(
        connector.checkAuthorization(
          callbackCorrelationId: callbackCorrelationId,
        ),
        throwsA(
          isA<EmailImportFailure>().having(
            (error) => error.errorCategory,
            'category',
            EmailErrorCategory.validationFailed,
          ),
        ),
      );
    }
  });

  test('account data deletion sends no owner or connection identifier',
      () async {
    final requests = <Map<String, Object?>>[];
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async {
        requests.add(body);
        return _emptyEnvelope(status: 'disconnected');
      },
    );

    await connector.deleteAccountData();

    expect(requests, [
      const {'action': 'delete_account_data'}
    ]);
    expect(requests.single, isNot(contains('ownerUserId')));
    expect(requests.single, isNot(contains('connectionId')));
  });

  test('strict response parsing rejects unknown candidate fields', () async {
    final envelope = _successEnvelope();
    final page = envelope['page']! as Map<String, Object?>;
    final items = page['items']! as List<Object?>;
    final item = items.single! as Map<String, Object?>;
    final candidate = item['candidate']! as Map<String, Object?>;
    candidate['unexpected'] = 'rejected';
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async => envelope,
    );

    await expectLater(
      connector.fetchDelta(),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.errorCategory,
          'category',
          EmailErrorCategory.invalidExtraction,
        ),
      ),
    );
  });

  test('strict response parsing rejects unsafe candidate URLs', () async {
    final envelope = _successEnvelope();
    final page = envelope['page']! as Map<String, Object?>;
    final items = page['items']! as List<Object?>;
    final item = items.single! as Map<String, Object?>;
    final candidate = item['candidate']! as Map<String, Object?>;
    candidate['submission_url'] = 'http://127.0.0.1/private';
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async => envelope,
    );

    await expectLater(
      connector.fetchDelta(),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.errorCategory,
          'category',
          EmailErrorCategory.unsafeUrl,
        ),
      ),
    );
  });

  test('rate-limit and revoked states are safe typed failures', () async {
    final cases = <(Map<String, Object?>, EmailConnectionStatus)>[
      (
        _emptyEnvelope(
          status: 'rate_limited',
          retryAfterSeconds: 45,
        ),
        EmailConnectionStatus.rateLimited,
      ),
      (
        _emptyEnvelope(status: 'reauth_required'),
        EmailConnectionStatus.reauthRequired,
      ),
    ];

    for (final (response, expectedStatus) in cases) {
      final connector = SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: connectionId,
        authenticatedUserIdOverride: () => ownerUserId,
        invokeOverride: (body) async => response,
      );
      await expectLater(
        connector.fetchDelta(),
        throwsA(
          isA<EmailImportFailure>().having(
            (error) => error.connectionStatus,
            'status',
            expectedStatus,
          ),
        ),
      );
    }
  });

  test('missing authenticated session fails before endpoint invocation',
      () async {
    var invoked = false;
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => null,
      invokeOverride: (body) async {
        invoked = true;
        return _successEnvelope();
      },
    );

    await expectLater(
      connector.fetchDelta(),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.connectionStatus,
          'status',
          EmailConnectionStatus.reauthRequired,
        ),
      ),
    );
    expect(invoked, isFalse);
  });

  test('unknown endpoint enums become validation failures', () async {
    final connector = SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      authenticatedUserIdOverride: () => ownerUserId,
      invokeOverride: (body) async => {
        'connection': _connection(status: 'invented_state'),
        'page': null,
      },
    );

    await expectLater(
      connector.fetchDelta(),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.errorCategory,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
  });
}

Map<String, Object?> _successEnvelope() {
  return {
    'connection': _connection(status: 'connected'),
    'page': <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'providerMessageId': 'provider-message-1',
          'providerThreadId': 'provider-thread-1',
          'receivedAt': '2030-04-01T01:00:00Z',
          'sanitizedContentHash': 'a' * 64,
          'evidenceExcerpts': <Object?>['締切 4月10日 23:59'],
          'candidate': _candidateJson(),
          'errorCategory': null,
        },
      ],
      'suppressions': <Object?>[],
      'nextCursor': 'opaque-cursor-2',
      'hasMore': false,
    },
  };
}

Map<String, Object?> _failedEnvelope() {
  return {
    'connection': _connection(status: 'connected'),
    'page': <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'providerMessageId': 'provider-message-failed',
          'providerThreadId': null,
          'receivedAt': '2030-04-01T01:00:00Z',
          'sanitizedContentHash': 'f' * 64,
          'evidenceExcerpts': <Object?>[],
          'candidate': null,
          'errorCategory': 'unsafe_content',
        },
      ],
      'suppressions': <Object?>[],
      'nextCursor': 'opaque-cursor-failed',
      'hasMore': false,
    },
  };
}

Map<String, Object?> _oauthEnvelope(
  DateTime now, {
  String? authorizationUri,
  DateTime? expiresAt,
}) {
  return {
    'connection': _connection(status: 'connecting'),
    'page': null,
    'oauth': <String, Object?>{
      'authorizationUri': authorizationUri ?? _oauthAuthorizationUri(),
      'codeChallenge': 'c' * 43,
      'expiresAt':
          (expiresAt ?? now.add(const Duration(minutes: 10))).toIso8601String(),
    },
  };
}

String _oauthAuthorizationUri({
  String host = 'accounts.google.com',
  String clientId = _oauthClientId,
  String redirectUri = 'https://project.supabase.co/functions/v1/email-import',
}) {
  return Uri.https(host, '/o/oauth2/v2/auth', {
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'response_type': 'code',
    'scope': 'https://www.googleapis.com/auth/gmail.readonly',
    'state': 's' * 43,
    'code_challenge': 'c' * 43,
    'code_challenge_method': 'S256',
    'access_type': 'offline',
    'prompt': 'consent',
    'include_granted_scopes': 'false',
  }).toString();
}

Map<String, Object?> _emptyEnvelope({
  required String status,
  int? retryAfterSeconds,
}) {
  return {
    'connection': _connection(
      status: status,
      retryAfterSeconds: retryAfterSeconds,
    ),
    'page': null,
  };
}

Map<String, Object?> _connection({
  required String status,
  int? retryAfterSeconds,
  String? errorCategory,
}) {
  return {
    'provider': 'gmail',
    'status': status,
    'errorCategory': errorCategory,
    'retryAfterSeconds': retryAfterSeconds,
    'connectedAt': status == 'connected' ? '2030-04-01T00:00:00Z' : null,
  };
}

Map<String, Object?> _candidateJson() {
  return {
    'schema_version': '1.0',
    'candidate_type': 'assignment',
    'title': 'レポート課題',
    'course_hint': <String, Object?>{
      'name': '情報数学',
      'code': 'CS101',
    },
    'due': <String, Object?>{
      'at': '2030-04-10T14:59:00Z',
      'all_day': false,
      'timezone': 'Asia/Tokyo',
      'raw_text': '4月10日 23:59',
    },
    'start_at': null,
    'end_at': null,
    'location': null,
    'submission_url': 'https://lms.example.edu/tasks/1',
    'summary': null,
    'suggested_reminders_minutes': <Object?>[1440, 180],
    'confidence': <String, Object?>{
      'overall': 0.9,
      'title': 0.9,
      'course': 0.8,
      'date_time': 0.9,
    },
    'evidence': <Object?>[
      <String, Object?>{
        'field': 'due.at',
        'text': '締切 4月10日 23:59',
      },
    ],
    'warnings': <Object?>[],
    'requires_user_confirmation': true,
  };
}
