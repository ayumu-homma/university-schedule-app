import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/lifecycle/scoped_context_lease.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_reconciliation_service.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_reconciliation.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('confirmation waits for sync ack and resumes after database restart',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'email-reconciliation-restart-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}db.sqlite');
    var db = local.AppDatabase(NativeDatabase(file));
    final gateway = _RecordingGateway();
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    try {
      await _seedConnection(db, ownerUserId: 'owner-a');
      await _seedReceipt(
        db,
        ownerUserId: 'owner-a',
        action: 'confirmation',
        reviewedPayloadJson: jsonEncode(_candidateJson()),
        entityType: 'assignment',
        entityId: _entityId,
        requiredSyncMutationId: 'schedule-confirmation',
      );
      await _seedMutation(
        db,
        ownerUserId: 'owner-a',
        mutationId: 'schedule-confirmation',
        idempotencyKey: 'confirmation-key-owner-a-1',
        operation: 'create',
        status: 'pending',
      );
      var service = _service(db, gateway, clock, () => 'owner-a');

      final waiting = await service.synchronize(
        ownerUserId: 'owner-a',
        networkAvailable: true,
      );
      expect(waiting.waitingForScheduleSync, 1);
      expect(gateway.requests, isEmpty);
      await db.close();

      db = local.AppDatabase(NativeDatabase(file));
      final claimed = await db.syncQueueDao.claimNext('owner-a', clock.now);
      expect(claimed, isNotNull);
      expect(
        await db.syncQueueDao.markSynced(
          'owner-a',
          'schedule-confirmation',
          clock.now,
          attemptCount: claimed!.attemptCount,
          serverVersion: 1,
        ),
        isTrue,
      );
      service = _service(db, gateway, clock, () => 'owner-a');
      final completed = await service.synchronize(
        ownerUserId: 'owner-a',
        networkAvailable: true,
      );
      final receipt =
          (await db.select(db.emailReconciliationReceipts).get()).single;

      expect(completed.reconciled, 1);
      expect(gateway.requests, hasLength(1));
      expect(receipt.scheduleAckedAt!.toUtc(), clock.now);
      expect(receipt.state, 'succeeded');
      expect(receipt.replayed, isFalse);
    } finally {
      await db.close();
    }
  });

  test('offline execution makes no call and owner scopes remain isolated',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _RecordingGateway();
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    var activeOwner = 'owner-a';
    final service = _service(db, gateway, clock, () => activeOwner);
    addTearDown(db.close);
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedConnection(db, ownerUserId: 'owner-b', suffix: '2');
    await _seedReceipt(
      db,
      ownerUserId: 'owner-a',
      action: 'dismissal',
    );
    await _seedReceipt(
      db,
      ownerUserId: 'owner-b',
      action: 'dismissal',
      suffix: '2',
    );

    await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: false,
    );
    expect(gateway.requests, isEmpty);
    await expectLater(
      service.synchronize(
        ownerUserId: 'owner-b',
        networkAvailable: true,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    final rows = await db.select(db.emailReconciliationReceipts).get();
    expect(
      rows.singleWhere((row) => row.ownerUserId == 'owner-a').state,
      'succeeded',
    );
    expect(
      rows.singleWhere((row) => row.ownerUserId == 'owner-b').state,
      'pending',
    );
    expect(gateway.requests.single.connectionId, _connectionId);
    activeOwner = 'owner-b';
  });

  test('schedule acknowledgement survives a failed call and queue pruning',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _RecordingGateway()..failure = EmailImportFailure.timeout();
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    final service = _service(db, gateway, clock, () => 'owner-a');
    addTearDown(db.close);
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedReceipt(
      db,
      ownerUserId: 'owner-a',
      action: 'update',
      resolution: 'accepted',
      entityType: 'assignment',
      entityId: _entityId,
      requiredSyncMutationId: 'schedule-update',
    );
    await _seedMutation(
      db,
      ownerUserId: 'owner-a',
      mutationId: 'schedule-update',
      idempotencyKey: 'update-key-owner-a-1',
      operation: 'update',
      status: 'synced',
    );

    final failed = await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    var receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(failed.failed, 1);
    expect(receipt.scheduleAckedAt, isNotNull);
    expect(receipt.state, 'pending');
    await db.delete(db.syncQueueEntries).go();

    gateway.failure = null;
    clock.now = clock.now.add(const Duration(minutes: 1));
    final completed = await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    receipt = (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(completed.reconciled, 1);
    expect(receipt.state, 'succeeded');
    expect(gateway.requests, hasLength(2));
  });

  test('mismatched gateway result never marks a receipt successful', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _RecordingGateway()
      ..resultOverride = const EmailReconciliationResult(
        connectionId: _connectionId,
        idempotencyKey: 'wrong-reconciliation-key',
        action: EmailReconciliationAction.update,
        outcome: EmailReconciliationOutcome.accepted,
        entityType: 'assignment',
        entityId: _entityId,
        replayed: false,
      );
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    final service = _service(db, gateway, clock, () => 'owner-a');
    addTearDown(db.close);
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedReceipt(
      db,
      ownerUserId: 'owner-a',
      action: 'dismissal',
    );

    final result = await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    final receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(result.failed, 1);
    expect(receipt.state, 'pending');
    expect(receipt.attemptCount, 1);
    expect(receipt.errorCategory, 'validation_failed');
  });

  test('server-wins queue completion never acknowledges an accepted update',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _RecordingGateway();
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    final service = _service(db, gateway, clock, () => 'owner-a');
    addTearDown(db.close);
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedReceipt(
      db,
      ownerUserId: 'owner-a',
      action: 'update',
      resolution: 'accepted',
      entityType: 'assignment',
      entityId: _entityId,
      requiredSyncMutationId: 'schedule-update',
    );
    await _seedMutation(
      db,
      ownerUserId: 'owner-a',
      mutationId: 'schedule-update',
      idempotencyKey: 'update-key-owner-a-1',
      operation: 'update',
      status: 'synced',
      completionProvenance: local.scheduleSyncCompletionServerWins,
    );

    final result = await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    final receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(result.waitingForScheduleSync, 1);
    expect(result.reconciled, 0);
    expect(gateway.requests, isEmpty);
    expect(receipt.scheduleAckedAt, isNull);
    expect(receipt.state, 'pending');
  });

  test('remote provenance still requires exact mutation correlation', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final gateway = _RecordingGateway();
    final clock = _MutableClock(DateTime.utc(2026, 7, 22, 12));
    final service = _service(db, gateway, clock, () => 'owner-a');
    addTearDown(db.close);
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedReceipt(
      db,
      ownerUserId: 'owner-a',
      action: 'update',
      resolution: 'accepted',
      entityType: 'assignment',
      entityId: _entityId,
      requiredSyncMutationId: 'schedule-update',
    );
    await _seedMutation(
      db,
      ownerUserId: 'owner-a',
      mutationId: 'schedule-update',
      idempotencyKey: 'different-idempotency-key',
      operation: 'update',
      status: 'synced',
    );

    final result = await service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    final receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(result.failed, 1);
    expect(result.reconciled, 0);
    expect(gateway.requests, isEmpty);
    expect(receipt.scheduleAckedAt, isNull);
    expect(receipt.errorCategory, 'validation_failed');
  });

  test('revoked ABA lease leaves receipt pending and fresh DB runtime retries',
      () async {
    final db1 = local.AppDatabase(NativeDatabase.memory());
    final gateway = _DelayedReconciliationGateway();
    var activeOwner = 'owner-a';
    final lease1 = ScopedContextLease(ownerUserId: 'owner-a', database: db1);
    final service1 = _service(
      db1,
      gateway,
      _MutableClock(DateTime.utc(2026, 7, 22, 12)),
      () => activeOwner,
      lease: lease1,
    );
    addTearDown(db1.close);
    await _seedConnection(db1, ownerUserId: 'owner-a');
    await _seedReceipt(db1, ownerUserId: 'owner-a', action: 'dismissal');

    final first = service1.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    await gateway.started.future;
    activeOwner = 'owner-b';
    lease1.revoke();
    activeOwner = 'owner-a';
    gateway.release.complete();
    final staleResult = await first;
    final pending =
        (await db1.select(db1.emailReconciliationReceipts).get()).single;
    expect(staleResult.reconciled, 0);
    expect(staleResult.failed, 0);
    expect(pending.state, 'pending');
    expect(pending.attemptCount, 0);

    final lease2 = ScopedContextLease(ownerUserId: 'owner-a', database: db1);
    final fresh = _service(
      db1,
      gateway,
      _MutableClock(DateTime.utc(2026, 7, 22, 12, 1)),
      () => activeOwner,
      lease: lease2,
    );
    await fresh.synchronize(ownerUserId: 'owner-a', networkAvailable: true);
    expect(
      (await db1.select(db1.emailReconciliationReceipts).get()).single.state,
      'succeeded',
    );

    final db2 = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db2.close);
    await _seedConnection(db2, ownerUserId: 'owner-a');
    await _seedReceipt(db2, ownerUserId: 'owner-a', action: 'dismissal');
    final lease3 = ScopedContextLease(ownerUserId: 'owner-a', database: db2);
    final replacement = _service(
      db2,
      gateway,
      _MutableClock(DateTime.utc(2026, 7, 22, 12, 2)),
      () => activeOwner,
      lease: lease3,
    );
    await replacement.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    expect(
      (await db2.select(db2.emailReconciliationReceipts).get()).single.state,
      'succeeded',
    );
  });

  test('revoked lease suppresses delayed reconciliation failure bookkeeping',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _DelayedReconciliationGateway()
      ..failureAfterRelease = EmailImportFailure.rateLimited(
        const Duration(minutes: 1),
      );
    var activeOwner = 'owner-a';
    final lease = ScopedContextLease(ownerUserId: 'owner-a', database: db);
    final service = _service(
      db,
      gateway,
      _MutableClock(DateTime.utc(2026, 7, 22, 12)),
      () => activeOwner,
      lease: lease,
    );
    await _seedConnection(db, ownerUserId: 'owner-a');
    await _seedReceipt(db, ownerUserId: 'owner-a', action: 'dismissal');

    final operation = service.synchronize(
      ownerUserId: 'owner-a',
      networkAvailable: true,
    );
    await gateway.started.future;
    activeOwner = 'owner-b';
    lease.revoke();
    activeOwner = 'owner-a';
    gateway.release.complete();
    final result = await operation;
    expect(result.failed, 0);
    expect(result.reconciled, 0);
    final receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(receipt.state, 'pending');
    expect(receipt.attemptCount, 0);
    expect(receipt.errorCategory, isNull);
    expect(receipt.nextRetryAt, isNull);
  });
}

EmailReconciliationService _service(
    local.AppDatabase db,
    EmailReconciliationGateway gateway,
    _MutableClock clock,
    String? Function() owner,
    {ScopedContextLease? lease}) {
  return EmailReconciliationService(
    db: db,
    gateway: gateway,
    clock: () => clock.now,
    authenticatedUserId: owner,
    lease: lease,
  );
}

Future<void> _seedConnection(
  local.AppDatabase db, {
  required String ownerUserId,
  String suffix = '1',
}) {
  return db.into(db.emailConnections).insert(
        local.EmailConnectionsCompanion.insert(
          id: suffix == '1' ? _connectionId : _connectionId2,
          ownerUserId: ownerUserId,
          provider: 'gmail',
          providerAccountHash: suffix == '1' ? 'a' * 64 : 'f' * 64,
          state: const Value('connected'),
        ),
      );
}

Future<void> _seedReceipt(
  local.AppDatabase db, {
  required String ownerUserId,
  required String action,
  String suffix = '1',
  String? reviewedPayloadJson,
  String? resolution,
  String? entityType,
  String? entityId,
  String? requiredSyncMutationId,
}) {
  return db.into(db.emailReconciliationReceipts).insert(
        local.EmailReconciliationReceiptsCompanion.insert(
          id: '$action:$ownerUserId:$suffix',
          ownerUserId: ownerUserId,
          connectionId: suffix == '1' ? _connectionId : _connectionId2,
          action: action,
          localReferenceId: 'local-$action-$suffix',
          provider: 'gmail',
          providerAccountHash: suffix == '1' ? 'a' * 64 : 'f' * 64,
          providerMessageIdHash: 'b' * 64,
          providerThreadIdHash: 'c' * 64,
          sanitizedContentHash: 'd' * 64,
          reviewedPayloadJson: Value(reviewedPayloadJson),
          resolution: Value(resolution),
          entityType: Value(entityType),
          entityId: Value(entityId),
          idempotencyKey: '$action-key-$ownerUserId-$suffix',
          requiredSyncMutationId: Value(requiredSyncMutationId),
        ),
      );
}

Future<void> _seedMutation(
  local.AppDatabase db, {
  required String ownerUserId,
  required String mutationId,
  required String idempotencyKey,
  required String operation,
  required String status,
  String completionProvenance = local.scheduleSyncCompletionRemoteApplied,
}) {
  return db.into(db.syncQueueEntries).insert(
        local.SyncQueueEntriesCompanion.insert(
          clientMutationId: mutationId,
          ownerUserId: ownerUserId,
          idempotencyKey: Value(idempotencyKey),
          entityType: 'assignment',
          entityId: _entityId,
          operation: operation,
          payloadJson: status == 'synced' ? '{}' : '{"safe":true}',
          status: Value(status),
          serverVersion: Value(status == 'synced' ? 1 : null),
          syncedAt: Value(
            status == 'synced' ? DateTime.utc(2026, 7, 22, 12) : null,
          ),
          completionProvenance: Value(
            status == 'synced' ? completionProvenance : null,
          ),
        ),
      );
}

class _RecordingGateway implements EmailReconciliationGateway {
  final requests = <EmailReconciliationRequest>[];
  Object? failure;
  EmailReconciliationResult? resultOverride;

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    requests.add(request);
    final error = failure;
    if (error != null) throw error;
    final override = resultOverride;
    if (override != null) return override;
    final outcome = switch (request.action) {
      EmailReconciliationAction.confirmation =>
        EmailReconciliationOutcome.confirmed,
      EmailReconciliationAction.dismissal =>
        EmailReconciliationOutcome.dismissed,
      EmailReconciliationAction.update =>
        request.resolution == EmailReconciliationResolution.accepted
            ? EmailReconciliationOutcome.accepted
            : EmailReconciliationOutcome.rejected,
    };
    return EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: outcome,
      entityType: request.entityType,
      entityId: request.entityId,
      replayed: false,
    );
  }
}

class _DelayedReconciliationGateway implements EmailReconciliationGateway {
  final started = Completer<void>();
  final release = Completer<void>();
  final requests = <EmailReconciliationRequest>[];
  Object? failureAfterRelease;

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    await release.future;
    final failure = failureAfterRelease;
    if (failure != null) throw failure;
    final outcome = switch (request.action) {
      EmailReconciliationAction.confirmation =>
        EmailReconciliationOutcome.confirmed,
      EmailReconciliationAction.dismissal =>
        EmailReconciliationOutcome.dismissed,
      EmailReconciliationAction.update =>
        request.resolution == EmailReconciliationResolution.accepted
            ? EmailReconciliationOutcome.accepted
            : EmailReconciliationOutcome.rejected,
    };
    return EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: outcome,
      entityType: request.entityType,
      entityId: request.entityId,
      replayed: false,
    );
  }
}

class _MutableClock {
  _MutableClock(this.now);

  DateTime now;
}

Map<String, Object?> _candidateJson() {
  return {
    'schema_version': '1.0',
    'candidate_type': 'assignment',
    'title': 'レポート課題',
    'course_hint': <String, Object?>{'name': null, 'code': null},
    'due': <String, Object?>{
      'at': '2030-04-10T14:59:00.000Z',
      'all_day': false,
      'timezone': 'Asia/Tokyo',
      'raw_text': null,
    },
    'start_at': null,
    'end_at': null,
    'location': null,
    'submission_url': null,
    'summary': null,
    'suggested_reminders_minutes': <Object?>[],
    'confidence': <String, Object?>{
      'overall': 1.0,
      'title': 1.0,
      'course': 1.0,
      'date_time': 1.0,
    },
    'evidence': <Object?>[],
    'warnings': <Object?>[],
    'requires_user_confirmation': true,
  };
}

const _connectionId = '11111111-1111-4111-8111-111111111111';
const _connectionId2 = '22222222-2222-4222-8222-222222222222';
const _entityId = '33333333-3333-4333-8333-333333333333';
