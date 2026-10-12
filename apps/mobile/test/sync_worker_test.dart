import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  late local.AppDatabase db;
  late DriftSyncQueue queue;
  late FakeRemoteScheduleGateway gateway;
  late SyncWorker worker;

  setUp(() {
    db = local.AppDatabase(NativeDatabase.memory());
    queue = DriftSyncQueue(db, ownerUserId: 'owner-a');
    gateway = FakeRemoteScheduleGateway();
    worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('retry policy grows exponentially and remains bounded', () {
    const policy = SyncRetryPolicy();

    expect(policy.delayForAttempt(1), const Duration(seconds: 5));
    expect(policy.delayForAttempt(2), const Duration(seconds: 10));
    expect(policy.delayForAttempt(9), const Duration(minutes: 15));
    expect(policy.delayForAttempt(30), const Duration(minutes: 15));
  });

  test('pending mutations are processed in durable enqueue order', () async {
    final base = DateTime(2026, 6, 29, 9);
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-3',
      entityId: 'course-3',
      entityType: 'user_course',
      operation: SyncOperation.create,
      createdAt: base.add(const Duration(minutes: 3)),
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-1',
      entityId: 'course-1',
      entityType: 'user_course',
      operation: SyncOperation.create,
      createdAt: base.add(const Duration(minutes: 1)),
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-2',
      entityId: 'course-2',
      entityType: 'user_course',
      operation: SyncOperation.create,
      createdAt: base.add(const Duration(minutes: 2)),
    ));

    final result = await worker.processPending();

    expect(result.processed, 3);
    expect(gateway.calls.map((call) => call.entityId), [
      'course-3',
      'course-1',
      'course-2',
    ]);
  });

  test('successful gateway calls mark mutations synced', () async {
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-1',
      entityId: 'assignment-1',
      entityType: 'assignment',
      operation: SyncOperation.create,
    ));

    final result = await worker.processPending();
    final rows = await queue.all();
    final counts = await queue.counts();

    expect(result.synced, 1);
    expect(result.failed, 0);
    expect(rows.single.status, SyncMutationStatus.synced);
    expect(rows.single.syncedAt, isNotNull);
    expect(rows.single.errorMessage, isNull);
    expect(counts.pending, 0);
    expect(counts.synced, 1);
    expect(counts.failed, 0);
  });

  test('failed gateway calls mark mutations failed with an error message',
      () async {
    gateway = FakeRemoteScheduleGateway(
      shouldFail: (call) => call.entityId == 'exam-1',
    );
    worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
    );
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-1',
      entityId: 'exam-1',
      entityType: 'exam',
      operation: SyncOperation.update,
    ));

    final result = await worker.processPending();
    final rows = await queue.all();
    final counts = await queue.counts();

    expect(result.synced, 0);
    expect(result.failed, 1);
    expect(rows.single.status, SyncMutationStatus.failed);
    expect(rows.single.errorMessage, contains('Fake gateway failed'));
    expect(counts.pending, 0);
    expect(counts.failed, 1);
  });

  test('fake gateway receives expected payloads for supported entities',
      () async {
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-course',
      entityId: 'course-1',
      entityType: 'user_course',
      operation: SyncOperation.create,
      payload: const {'title': '同期論', 'dayOfWeek': 1},
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-assignment',
      entityId: 'assignment-1',
      entityType: 'assignment',
      operation: SyncOperation.update,
      payload: const {'title': 'レポート', 'priority': 'high'},
      createdAt: DateTime(2026, 6, 29, 9, 1),
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-state',
      entityId: 'assignment-1',
      entityType: 'assignment_state',
      operation: SyncOperation.submit,
      payload: const {'assignmentId': 'assignment-1', 'status': 'submitted'},
      createdAt: DateTime(2026, 6, 29, 9, 2),
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-exam',
      entityId: 'exam-1',
      entityType: 'exam',
      operation: SyncOperation.create,
      payload: const {'title': '中間試験', 'room': 'B203'},
      createdAt: DateTime(2026, 6, 29, 9, 3),
    ));

    await worker.processPending();

    expect(gateway.calls.map((call) => call.table), [
      'user_courses',
      'assignments',
      'assignment_user_states',
      'exams',
    ]);
    expect(gateway.calls.map((call) => call.operation), [
      SyncOperation.create,
      SyncOperation.update,
      SyncOperation.submit,
      SyncOperation.create,
    ]);
    expect(gateway.calls[0].payload['title'], '同期論');
    expect(gateway.calls[1].payload['priority'], 'high');
    expect(gateway.calls[2].payload['status'], 'submitted');
    expect(gateway.calls[3].payload['room'], 'B203');
  });

  test('already-synced mutations are not reprocessed', () async {
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-synced',
      entityId: 'course-1',
      entityType: 'user_course',
      operation: SyncOperation.create,
      status: SyncMutationStatus.synced,
      syncedAt: DateTime(2026, 6, 29, 10),
    ));

    final result = await worker.processPending();
    final rows = await queue.all();

    expect(result.processed, 0);
    expect(gateway.calls, isEmpty);
    expect(rows.single.status, SyncMutationStatus.synced);
  });

  test(
      'context switch stops after an in-flight dispatch and preserves its lease',
      () async {
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-1',
      entityId: 'course-1',
      entityType: 'user_course',
      operation: SyncOperation.create,
    ));
    await queue.enqueue(_mutation(
      clientMutationId: 'mutation-2',
      entityId: 'course-2',
      entityType: 'user_course',
      operation: SyncOperation.create,
    ));

    final gateway = _DelayedMutationGateway();
    final oldLease = Object();
    var activeLease = oldLease;
    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      isContextCurrent: () => identical(activeLease, oldLease),
    );

    final run = worker.processPending();
    await gateway.firstDispatchStarted.future;
    // Simulate A -> B -> A. The old worker lease stays invalid even though
    // the active context later has the same identity as A again.
    activeLease = Object();
    gateway.releaseFirstDispatch.complete();

    final result = await run;
    final rows = await queue.all();
    expect(result.processed, 1);
    expect(result.synced, 0);
    expect(gateway.calls.map((call) => call.entityId), ['course-1']);
    expect(rows[0].status, SyncMutationStatus.processing);
    expect(rows[1].status, SyncMutationStatus.pending);

    final resumedWorker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
    );
    expect(await resumedWorker.recoverAfterRestart(), 1);
    final resumed = await resumedWorker.processPending();
    expect(resumed.synced, 2);
    expect(gateway.calls.map((call) => call.entityId), [
      'course-1',
      'course-1',
      'course-2',
    ]);
  });

  test('inactive worker does not recover an expired processing lease',
      () async {
    await queue.enqueue(_mutation(
      clientMutationId: 'expired-processing',
      entityId: 'course-1',
      entityType: 'user_course',
      operation: SyncOperation.create,
    ));
    final claimed = await queue.claimNext(now: DateTime(2026, 6, 29, 9));
    expect(claimed?.status, SyncMutationStatus.processing);

    final worker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(FakeRemoteScheduleGateway()),
      clock: () => DateTime(2026, 6, 29, 10),
      isContextCurrent: () => false,
    );
    final result = await worker.processPending();
    final row = (await queue.all()).single;

    expect(result.processed, 0);
    expect(result.recovered, 0);
    expect(row.status, SyncMutationStatus.processing);
  });
}

class _DelayedMutationGateway implements RemoteScheduleGateway {
  final firstDispatchStarted = Completer<void>();
  final releaseFirstDispatch = Completer<void>();
  final calls = <RemoteScheduleCall>[];

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    final call = RemoteScheduleCall.fromMutation(mutation);
    calls.add(call);
    if (calls.length == 1) {
      firstDispatchStarted.complete();
      await releaseFirstDispatch.future;
    }
    return ScheduleMutationAck(
      clientMutationId: mutation.clientMutationId,
      outcome: ScheduleMutationOutcome.applied,
      entityType: mutation.entityType,
      entityId: mutation.entityId,
      operation: mutation.operation,
      change: ScheduleDeltaChange(
        changeCursor: calls.length,
        entityType: mutation.entityType,
        entityId: mutation.entityId,
        operation: ScheduleDeltaOperation.upsert,
        serverVersion: 1,
        payload: mutation.payload,
      ),
      replayed: calls.length > 1,
    );
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async {
    return ScheduleDeltaPage(
      afterCursor: afterCursor,
      nextCursor: afterCursor,
      hasMore: false,
      changes: const [],
    );
  }
}

PendingMutation _mutation({
  required String clientMutationId,
  required String entityId,
  required String entityType,
  required SyncOperation operation,
  DateTime? createdAt,
  Map<String, Object?> payload = const {'id': 'payload-id'},
  SyncMutationStatus status = SyncMutationStatus.pending,
  DateTime? syncedAt,
}) {
  return PendingMutation(
    clientMutationId: clientMutationId,
    ownerUserId: 'owner-a',
    entityType: entityType,
    entityId: entityId,
    operation: operation,
    payload: payload,
    createdAt: createdAt ?? DateTime(2026, 6, 29, 9),
    status: status,
    syncedAt: syncedAt,
  );
}
