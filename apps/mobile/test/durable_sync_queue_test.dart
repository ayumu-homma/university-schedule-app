import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const ownerUserId = 'owner-a';
  late local.AppDatabase db;
  late DriftSyncQueue queue;

  setUp(() {
    db = local.AppDatabase(NativeDatabase.memory());
    queue = DriftSyncQueue(db, ownerUserId: ownerUserId);
  });

  tearDown(() async {
    await db.close();
  });

  test('acknowledgement clears sensitive data and expires after 30 days',
      () async {
    final now = DateTime.utc(2026, 7, 10, 9);
    await queue.enqueue(
      _mutation(
        payload: const {
          'title': 'private appointment',
          'description': 'sensitive detail',
        },
        baseVersion: 4,
      ),
    );
    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(FakeRemoteScheduleGateway()),
      clock: () => now,
    );

    final result = await worker.processPending();
    final acknowledged = (await queue.all()).single;

    expect(result.synced, 1);
    expect(acknowledged.status, SyncMutationStatus.synced);
    expect(acknowledged.payload, isEmpty);
    expect(acknowledged.errorMessage, isNull);
    expect(acknowledged.attemptCount, 1);
    expect(acknowledged.idempotencyKey, 'mutation-1');
    expect(acknowledged.baseVersion, 4);
    expect(acknowledged.syncedAt?.toUtc(), now);

    expect(
      await queue.cleanupAcknowledged(
        now: now.add(SyncQueue.acknowledgedRetention),
      ),
      0,
    );
    expect(
      await queue.cleanupAcknowledged(
        now: now
            .add(SyncQueue.acknowledgedRetention)
            .add(const Duration(seconds: 1)),
      ),
      1,
    );
    expect(await queue.all(), isEmpty);
  });

  test('failed mutation retries only when due and stores a redacted error',
      () async {
    var now = DateTime.utc(2026, 7, 10, 9);
    var failureCount = 0;
    final gateway = FakeRemoteScheduleGateway(
      failureFor: (_) {
        if (failureCount++ > 0) return null;
        return const RemoteScheduleException(
          'user student@example.com token=abcdefghijklmnopqrstuvwx '
          'Bearer abcdefghijklmnopqrstuvwxyz '
          'https://example.test/private?id=42',
        );
      },
    );
    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      clock: () => now,
      retryPolicy: const SyncRetryPolicy(
        baseDelay: Duration(seconds: 10),
        maximumDelay: Duration(minutes: 1),
      ),
    );
    await queue.enqueue(_mutation());

    final first = await worker.processPending();
    final failed = (await queue.all()).single;

    expect(first.failed, 1);
    expect(failed.status, SyncMutationStatus.failed);
    expect(failed.attemptCount, 1);
    expect(
      failed.nextRetryAt?.toUtc(),
      now.add(const Duration(seconds: 10)),
    );
    expect(failed.errorMessage, isNot(contains('student@example.com')));
    expect(failed.errorMessage, isNot(contains('abcdefghijklmnopqrstuvwx')));
    expect(failed.errorMessage, isNot(contains('example.test')));

    now = now.add(const Duration(seconds: 9));
    final earlyWake = await worker.processPending();
    expect(earlyWake.processed, 0);
    expect(
      earlyWake.nextRetryAt?.toUtc(),
      now.add(const Duration(seconds: 1)),
    );
    expect(gateway.calls, hasLength(1));

    now = now.add(const Duration(seconds: 1));
    final retried = await worker.processPending();
    final synced = (await queue.all()).single;

    expect(retried.synced, 1);
    expect(synced.status, SyncMutationStatus.synced);
    expect(synced.attemptCount, 2);
    expect(synced.nextRetryAt, isNull);
    expect(synced.errorMessage, isNull);
    expect(gateway.calls, hasLength(2));
  });

  test('version conflict is durable and is not automatically retried',
      () async {
    final now = DateTime.utc(2026, 7, 10, 9);
    final gateway = FakeRemoteScheduleGateway(
      failureFor: (_) => const RemoteScheduleConflictException(
        'Remote version changed.',
        serverVersion: 8,
      ),
    );
    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      clock: () => now,
    );
    await queue.enqueue(_mutation(baseVersion: 7));

    final first = await worker.processPending();
    final conflict = (await queue.all()).single;
    final counts = await queue.counts();

    expect(first.conflicts, 1);
    expect(conflict.status, SyncMutationStatus.conflict);
    expect(conflict.baseVersion, 7);
    expect(conflict.serverVersion, 8);
    expect(conflict.payload, isNotEmpty);
    expect(conflict.nextRetryAt, isNull);
    expect(counts.conflict, 1);
    final earlyWake = await worker.processPending();
    expect(earlyWake.processed, 0);
    expect(earlyWake.nextRetryAt, isNull);
    expect(gateway.calls, hasLength(1));
  });

  test('an abandoned processing lease is recovered after a restart', () async {
    await db.close();
    final temp = await Directory.systemTemp.createTemp('durable-outbox-test-');
    final file = File('${temp.path}${Platform.pathSeparator}outbox.sqlite');
    final startedAt = DateTime.utc(2026, 7, 10, 9);

    try {
      var persistentDb = local.AppDatabase(NativeDatabase(file));
      var persistentQueue = DriftSyncQueue(
        persistentDb,
        ownerUserId: ownerUserId,
      );
      await persistentQueue.enqueue(_mutation());
      final claimed = await persistentQueue.claimNext(now: startedAt);
      expect(claimed?.status, SyncMutationStatus.processing);
      expect(claimed?.attemptCount, 1);
      await persistentDb.close();

      persistentDb = local.AppDatabase(NativeDatabase(file));
      persistentQueue = DriftSyncQueue(
        persistentDb,
        ownerUserId: ownerUserId,
      );
      final gateway = FakeRemoteScheduleGateway();
      final worker = SyncWorker(
        queue: persistentQueue,
        dispatcher: SyncMutationDispatcher(gateway),
        clock: () => startedAt.add(const Duration(minutes: 6)),
      );

      final result = await worker.processPending();
      final row = (await persistentQueue.all()).single;

      expect(result.recovered, 1);
      expect(result.synced, 1);
      expect(row.status, SyncMutationStatus.synced);
      expect(row.attemptCount, 2);
      expect(row.claimedAt, isNull);
      expect(gateway.calls, hasLength(1));
      await persistentDb.close();
    } finally {
      db = local.AppDatabase(NativeDatabase.memory());
      queue = DriftSyncQueue(db, ownerUserId: ownerUserId);
      await temp.delete(recursive: true);
    }
  });

  test(
      'offline routine and exception reconnect in durable enqueue order after restart',
      () async {
    await db.close();
    final temp = await Directory.systemTemp.createTemp('routine-outbox-order-');
    final file = File('${temp.path}${Platform.pathSeparator}outbox.sqlite');
    var persistentDb = local.AppDatabase(NativeDatabase(file));

    try {
      var persistentQueue = DriftSyncQueue(
        persistentDb,
        ownerUserId: ownerUserId,
      );
      final offlineAt = DateTime.utc(2026, 7, 18, 9);
      await persistentQueue.enqueue(
        _mutation(
          clientMutationId: 'routine-create-z',
          entityType: 'event',
          entityId: 'routine-1',
          payload: const {
            'id': 'routine-1',
            'title': '同期順序ルーティン',
            'ownerUserId': ownerUserId,
          },
          createdAt: offlineAt,
        ),
      );
      await persistentQueue.enqueue(
        _mutation(
          clientMutationId: 'exception-create-a',
          entityType: 'event_exception',
          entityId: 'exception-1',
          payload: const {
            'id': 'exception-1',
            'eventId': 'routine-1',
            'ownerUserId': ownerUserId,
            'mode': 'cancelled',
          },
          createdAt: offlineAt,
        ),
      );

      final beforeRestart =
          await persistentDb.syncQueueDao.allMutations(ownerUserId);
      expect(
        beforeRestart.map((row) => row.clientMutationId),
        ['routine-create-z', 'exception-create-a'],
      );
      expect(
        beforeRestart.map((row) => row.enqueueSequence),
        [1, 2],
      );

      await persistentDb.close();
      persistentDb = local.AppDatabase(NativeDatabase(file));
      persistentQueue = DriftSyncQueue(
        persistentDb,
        ownerUserId: ownerUserId,
      );
      final afterRestart =
          await persistentDb.syncQueueDao.allMutations(ownerUserId);
      expect(
        afterRestart.map((row) => row.clientMutationId),
        ['routine-create-z', 'exception-create-a'],
      );
      expect(
        afterRestart.map((row) => row.enqueueSequence),
        [1, 2],
      );

      final syncedRemoteEntityIds = <String>{};
      final gateway = FakeRemoteScheduleGateway(
        failureFor: (call) {
          if (call.entityType == 'event') {
            syncedRemoteEntityIds.add(call.entityId);
            return null;
          }
          if (call.entityType == 'event_exception' &&
              !syncedRemoteEntityIds.contains('routine-1')) {
            return const RemoteScheduleTransientException(
              'The parent routine must be synced before its exception.',
            );
          }
          return null;
        },
      );
      final worker = SyncWorker(
        queue: persistentQueue,
        dispatcher: SyncMutationDispatcher(gateway),
        clock: () => offlineAt.add(const Duration(minutes: 5)),
      );

      final result = await worker.processPending();
      final rows = await persistentQueue.all();

      expect(result.processed, 2);
      expect(result.synced, 2);
      expect(result.failed, 0);
      expect(gateway.calls.map((call) => call.entityType), [
        'event',
        'event_exception',
      ]);
      expect(
        rows.map((row) => row.status),
        [SyncMutationStatus.synced, SyncMutationStatus.synced],
      );
    } finally {
      await persistentDb.close();
      db = local.AppDatabase(NativeDatabase.memory());
      queue = DriftSyncQueue(db, ownerUserId: ownerUserId);
      await temp.delete(recursive: true);
    }
  });

  test('a stale lease cannot overwrite a newer terminal result', () async {
    final firstClaimAt = DateTime.utc(2026, 7, 10, 9);
    await queue.enqueue(_mutation());

    final staleClaim = await queue.claimNext(now: firstClaimAt);
    expect(staleClaim?.attemptCount, 1);
    expect(
      await queue.recoverAbandoned(
        now: firstClaimAt.add(const Duration(minutes: 6)),
      ),
      1,
    );
    final currentClaim = await queue.claimNext(
      now: firstClaimAt.add(const Duration(minutes: 6)),
    );
    expect(currentClaim?.attemptCount, 2);

    expect(
      await queue.markConflict(
        currentClaim!.clientMutationId,
        'Remote version changed.',
        attemptCount: currentClaim.attemptCount,
        serverVersion: 9,
      ),
      isTrue,
    );
    expect(
      await queue.markSynced(
        staleClaim!.clientMutationId,
        acknowledgedAt: firstClaimAt.add(const Duration(minutes: 7)),
        attemptCount: staleClaim.attemptCount,
      ),
      isFalse,
    );

    final row = (await queue.all()).single;
    expect(row.status, SyncMutationStatus.conflict);
    expect(row.serverVersion, 9);
    expect(row.payload, isNotEmpty);
  });

  test('claim, read, recovery, counts, and terminal writes isolate owners',
      () async {
    final queueA = queue;
    final queueB = DriftSyncQueue(db, ownerUserId: 'owner-b');
    final startedAt = DateTime.utc(2026, 7, 10, 9);
    await queueA.enqueue(_mutation(clientMutationId: 'mutation-a'));
    await queueB.enqueue(
      _mutation(
        clientMutationId: 'mutation-b',
        ownerUserId: 'owner-b',
      ),
    );

    expect((await queueA.all()).map((row) => row.clientMutationId), [
      'mutation-a',
    ]);
    expect((await queueB.all()).map((row) => row.clientMutationId), [
      'mutation-b',
    ]);
    expect((await queueA.counts()).pending, 1);
    expect((await queueB.counts()).pending, 1);

    final claimA = await queueA.claimNext(now: startedAt);
    expect(claimA?.clientMutationId, 'mutation-a');
    expect(await queueB.claimNext(now: startedAt), isNotNull);
    expect(
      await queueB.markSynced(
        'mutation-a',
        acknowledgedAt: startedAt,
        attemptCount: claimA!.attemptCount,
      ),
      isFalse,
    );
    expect(
      await queueB.recoverAbandoned(
        now: startedAt.add(const Duration(minutes: 6)),
      ),
      1,
    );
    expect((await queueA.all()).single.status, SyncMutationStatus.processing);

    expect(
      () => queueA.enqueue(
        _mutation(
          clientMutationId: 'wrong-owner',
          ownerUserId: 'owner-b',
        ),
      ),
      throwsArgumentError,
    );
  });

  test('transient failure never overtakes a later mutation', () async {
    final now = DateTime.utc(2026, 7, 10, 9);
    final gateway = FakeRemoteScheduleGateway(
      failureFor: (call) => call.clientMutationId == 'mutation-1'
          ? const RemoteScheduleTransientException('offline')
          : null,
    );
    await queue.enqueue(_mutation(clientMutationId: 'mutation-1'));
    await queue.enqueue(_mutation(clientMutationId: 'mutation-2'));
    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      clock: () => now,
      retryPolicy: const SyncRetryPolicy(baseDelay: Duration(minutes: 1)),
    );

    final result = await worker.processPending();
    final rows = await queue.all();

    expect(result.processed, 1);
    expect(result.failed, 1);
    expect(gateway.calls.map((call) => call.clientMutationId), ['mutation-1']);
    expect(rows[0].status, SyncMutationStatus.failed);
    expect(rows[1].status, SyncMutationStatus.pending);
    final earlyWake = await worker.processPending();
    expect(earlyWake.processed, 0);
    expect(
      earlyWake.nextRetryAt?.toUtc(),
      now.add(const Duration(minutes: 1)),
    );
    expect(gateway.calls, hasLength(1));
  });

  test('actionable Drift streams are owner-scoped and enqueue deterministic',
      () async {
    final queueB = DriftSyncQueue(db, ownerUserId: 'owner-b');
    expect(await db.syncQueueDao.watchActionableCount(ownerUserId).first, 0);
    await queue.enqueue(_mutation(clientMutationId: 'mutation-b'));
    await queue.enqueue(_mutation(clientMutationId: 'mutation-a'));
    await queueB.enqueue(
      _mutation(clientMutationId: 'mutation-owner-b', ownerUserId: 'owner-b'),
    );

    final rows =
        await db.syncQueueDao.watchActionableMutations(ownerUserId).first;
    expect(rows.map((row) => row.clientMutationId), [
      'mutation-b',
      'mutation-a',
    ]);
    expect(await db.syncQueueDao.watchActionableCount(ownerUserId).first, 2);
    expect(await db.syncQueueDao.watchActionableCount('owner-b').first, 1);
  });

  test('serializes payload timestamps as explicit UTC instants', () async {
    final deviceLocalValue = DateTime.utc(2026, 7, 13).toLocal();
    await queue.enqueue(
      _mutation(
        payload: {
          'startAt': deviceLocalValue,
          'nested': {'recurrenceId': deviceLocalValue},
        },
      ),
    );

    final payload = (await queue.pending()).single.payload;
    final expected = deviceLocalValue.toUtc().toIso8601String();

    expect(payload['startAt'], expected);
    expect(
        (payload['nested'] as Map<String, Object?>)['recurrenceId'], expected);
  });
}

PendingMutation _mutation({
  String clientMutationId = 'mutation-1',
  String ownerUserId = 'owner-a',
  String entityType = 'user_course',
  String entityId = 'entity-1',
  SyncOperation operation = SyncOperation.create,
  Map<String, Object?> payload = const {'id': 'entity-1', 'title': 'Schedule'},
  int? baseVersion,
  DateTime? createdAt,
}) {
  return PendingMutation(
    clientMutationId: clientMutationId,
    ownerUserId: ownerUserId,
    entityType: entityType,
    entityId: entityId,
    operation: operation,
    payload: payload,
    baseVersion: baseVersion,
    createdAt: createdAt ?? DateTime.utc(2026, 7, 10, 8),
  );
}
