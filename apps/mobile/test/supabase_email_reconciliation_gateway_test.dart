import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/supabase_email_reconciliation_gateway.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_reconciliation.dart';

void main() {
  test('confirmation sends the exact safe body and accepts a strict ack',
      () async {
    Map<String, Object?>? captured;
    final gateway = _gateway((body) async {
      captured = body;
      return _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'assignment',
        entityId: _entityId,
      );
    });

    final result = await gateway.reconcile(_confirmationRequest());

    expect(
      captured!.keys.toSet(),
      {
        'action',
        'connectionId',
        'provider',
        'providerAccountHash',
        'providerMessageIdHash',
        'providerThreadIdHash',
        'sanitizedContentHash',
        'idempotencyKey',
        'reviewedPayload',
        'entityType',
        'entityId',
      },
    );
    expect(captured!['action'], 'reconcile_confirmation');
    expect(captured!['reviewedPayload'], _candidateJson());
    expect(result.connectionId, _connectionId);
    expect(result.idempotencyKey, 'confirmation-safe-key');
    expect(result.outcome, EmailReconciliationOutcome.confirmed);
  });

  test('a disconnected current connection cannot block an exact safe ack',
      () async {
    final gateway = _gateway((_) async {
      return _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'assignment',
        entityId: _entityId,
        connectionStatus: 'disconnected',
        connectedAt: null,
      );
    });

    final result = await gateway.reconcile(_confirmationRequest());

    expect(result.connectionId, _connectionId);
    expect(result.idempotencyKey, 'confirmation-safe-key');
    expect(result.outcome, EmailReconciliationOutcome.confirmed);
  });

  test('dismissal and update bodies contain no unrequested fields', () async {
    final bodies = <Map<String, Object?>>[];
    final gateway = _gateway((body) async {
      bodies.add(body);
      if (body['action'] == 'reconcile_dismissal') {
        return _response(action: 'dismissal', outcome: 'dismissed');
      }
      return _response(
        action: 'update',
        outcome: 'rejected',
        entityType: 'assignment',
        entityId: _entityId,
      );
    });

    await gateway.reconcile(_dismissalRequest());
    await gateway.reconcile(_updateRequest());

    expect(
      bodies.first.keys.toSet(),
      {
        'action',
        'connectionId',
        'provider',
        'providerAccountHash',
        'providerMessageIdHash',
        'providerThreadIdHash',
        'sanitizedContentHash',
        'idempotencyKey',
      },
    );
    expect(bodies.first.values, isNot(contains(_entityId)));
    expect(
      bodies.last.keys.toSet(),
      {
        'action',
        'connectionId',
        'provider',
        'providerAccountHash',
        'providerMessageIdHash',
        'providerThreadIdHash',
        'sanitizedContentHash',
        'idempotencyKey',
        'resolution',
        'entityType',
        'entityId',
      },
    );
    expect(bodies.last['resolution'], 'rejected');
    expect(bodies.last.containsKey('reviewedPayload'), isFalse);
  });

  test('mismatched or non-exact acknowledgements fail closed', () async {
    for (final response in [
      _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'assignment',
        entityId: _entityId,
        connectionId: _otherConnectionId,
      ),
      _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'assignment',
        entityId: _entityId,
        idempotencyKey: 'stale-confirmation-key',
      ),
      _response(
        action: 'confirmation',
        outcome: 'dismissed',
        entityType: 'assignment',
        entityId: _entityId,
      ),
      _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'exam',
        entityId: _entityId,
      ),
      {
        ..._response(
          action: 'confirmation',
          outcome: 'confirmed',
          entityType: 'assignment',
          entityId: _entityId,
        ),
        'extra': true,
      },
      _response(
        action: 'confirmation',
        outcome: 'confirmed',
        entityType: 'assignment',
        entityId: _entityId,
        replayed: 'false',
      ),
    ]) {
      final gateway = _gateway((_) async => response);
      await expectLater(
        gateway.reconcile(_confirmationRequest()),
        throwsA(
          isA<EmailImportFailure>().having(
            (failure) => failure.errorCategory,
            'category',
            EmailErrorCategory.validationFailed,
          ),
        ),
      );
    }
  });

  test('stale dismissal acknowledgement cannot satisfy a later request',
      () async {
    final gateway = _gateway((_) async {
      return _response(
        action: 'dismissal',
        outcome: 'dismissed',
        idempotencyKey: 'earlier-dismissal-key',
      );
    });

    await expectLater(
      gateway.reconcile(_dismissalRequest()),
      throwsA(
        isA<EmailImportFailure>().having(
          (failure) => failure.errorCategory,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
  });

  test('malformed current connection envelopes still fail closed', () async {
    for (final response in [
      _response(
        action: 'dismissal',
        outcome: 'dismissed',
        connectionStatus: 'unknown',
      ),
      _response(
        action: 'dismissal',
        outcome: 'dismissed',
        connectionStatus: 'disconnected',
        connectionErrorCategory: 'provider_unavailable',
      ),
      _response(
        action: 'dismissal',
        outcome: 'dismissed',
        connectionStatus: 'disconnected',
        retryAfterSeconds: 5,
      ),
    ]) {
      final gateway = _gateway((_) async => response);
      await expectLater(
        gateway.reconcile(_dismissalRequest()),
        throwsA(
          isA<EmailImportFailure>().having(
            (failure) => failure.errorCategory,
            'category',
            EmailErrorCategory.validationFailed,
          ),
        ),
      );
    }
  });

  test('sequential updates to one entity require their own idempotency key',
      () async {
    final gateway = _gateway((_) async {
      return _response(
        action: 'update',
        outcome: 'rejected',
        entityType: 'assignment',
        entityId: _entityId,
        idempotencyKey: 'update-safe-key',
      );
    });

    await gateway.reconcile(_updateRequest());
    await expectLater(
      gateway.reconcile(
        _updateRequest(idempotencyKey: 'second-update-safe-key'),
      ),
      throwsA(
        isA<EmailImportFailure>().having(
          (failure) => failure.errorCategory,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
  });

  test('feature flag and authenticated session fail closed before invocation',
      () async {
    var calls = 0;
    final disabled = SupabaseEmailReconciliationGateway(
      emailImportEnabled: false,
      invokeOverride: (_) async {
        calls++;
        return null;
      },
      authenticatedUserIdOverride: () => 'owner-a',
    );
    await expectLater(
      disabled.reconcile(_dismissalRequest()),
      throwsA(isA<EmailImportFailure>()),
    );
    final signedOut = SupabaseEmailReconciliationGateway(
      emailImportEnabled: true,
      invokeOverride: (_) async {
        calls++;
        return null;
      },
      authenticatedUserIdOverride: () => null,
    );
    await expectLater(
      signedOut.reconcile(_dismissalRequest()),
      throwsA(isA<EmailImportFailure>()),
    );
    expect(calls, 0);
  });
}

SupabaseEmailReconciliationGateway _gateway(
  EmailReconciliationFunctionInvoker invoke,
) {
  return SupabaseEmailReconciliationGateway(
    emailImportEnabled: true,
    invokeOverride: invoke,
    authenticatedUserIdOverride: () => 'owner-a',
  );
}

EmailReconciliationRequest _confirmationRequest() {
  return EmailReconciliationRequest(
    action: EmailReconciliationAction.confirmation,
    connectionId: _connectionId,
    provider: 'gmail',
    providerAccountHash: 'a' * 64,
    providerMessageIdHash: 'b' * 64,
    providerThreadIdHash: 'c' * 64,
    sanitizedContentHash: 'd' * 64,
    reviewedPayload: _candidateJson(),
    entityType: 'assignment',
    entityId: _entityId,
    idempotencyKey: 'confirmation-safe-key',
  );
}

EmailReconciliationRequest _dismissalRequest() {
  return EmailReconciliationRequest(
    action: EmailReconciliationAction.dismissal,
    connectionId: _connectionId,
    provider: 'gmail',
    providerAccountHash: 'a' * 64,
    providerMessageIdHash: 'b' * 64,
    providerThreadIdHash: 'c' * 64,
    sanitizedContentHash: 'd' * 64,
    idempotencyKey: 'dismissal-safe-key',
  );
}

EmailReconciliationRequest _updateRequest({
  String idempotencyKey = 'update-safe-key',
}) {
  return EmailReconciliationRequest(
    action: EmailReconciliationAction.update,
    connectionId: _connectionId,
    provider: 'gmail',
    providerAccountHash: 'a' * 64,
    providerMessageIdHash: 'b' * 64,
    providerThreadIdHash: 'c' * 64,
    sanitizedContentHash: 'd' * 64,
    resolution: EmailReconciliationResolution.rejected,
    entityType: 'assignment',
    entityId: _entityId,
    idempotencyKey: idempotencyKey,
  );
}

Map<String, Object?> _response({
  required String action,
  required String outcome,
  String? entityType,
  String? entityId,
  String connectionId = _connectionId,
  String? idempotencyKey,
  Object replayed = false,
  String connectionStatus = 'connected',
  String? connectionErrorCategory,
  int? retryAfterSeconds,
  String? connectedAt = '2030-04-01T00:00:00Z',
}) {
  return {
    'connection': {
      'provider': 'gmail',
      'status': connectionStatus,
      'errorCategory': connectionErrorCategory,
      'retryAfterSeconds': retryAfterSeconds,
      'connectedAt': connectedAt,
    },
    'page': null,
    'reconciliation': {
      'connectionId': connectionId,
      'idempotencyKey': idempotencyKey ??
          switch (action) {
            'confirmation' => 'confirmation-safe-key',
            'dismissal' => 'dismissal-safe-key',
            _ => 'update-safe-key',
          },
      'action': action,
      'outcome': outcome,
      'entityType': entityType,
      'entityId': entityId,
      'replayed': replayed,
    },
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
      'at': '2030-04-10T14:59:00.000Z',
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

const _connectionId = '11111111-1111-4111-8111-111111111111';
const _otherConnectionId = '33333333-3333-4333-8333-333333333333';
const _entityId = '22222222-2222-4222-8222-222222222222';
