import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_coordinator.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const owner = 'owner-a';
  late local.AppDatabase db;
  late DriftSyncQueue queue;
  late DriftScheduleSyncStore store;

  setUp(() {
    db = local.AppDatabase(NativeDatabase.memory());
    queue = DriftSyncQueue(db, ownerUserId: owner);
    store = DriftScheduleSyncStore(db, ownerUserId: owner);
  });

  tearDown(() => db.close());

  test('startup immediately recovers and replays a processing lease', () async {
    await _insertCourse(db);
    await queue.enqueue(_mutation());
    final firstClaim = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    expect(firstClaim?.status, SyncMutationStatus.processing);
    final gateway = FakeRemoteScheduleGateway();
    final coordinator = SyncCoordinator(
      ownerUserId: owner,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(gateway),
        store: store,
      ),
      gateway: gateway,
      store: store,
    );

    final result = await coordinator.start();

    final row = (await queue.all()).single;
    expect(result.push.synced, 1);
    expect(row.status, SyncMutationStatus.synced);
    expect(row.attemptCount, 2);
    expect(gateway.calls, hasLength(1));
    expect(gateway.pullCalls, hasLength(1));
  });

  test('concurrent wakeups coalesce into one in-flight run plus one rerun',
      () async {
    final gateway = _BlockingPullGateway();
    final coordinator = SyncCoordinator(
      ownerUserId: owner,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(gateway),
        store: store,
      ),
      gateway: gateway,
      store: store,
    );

    final first = coordinator.synchronize(SyncTrigger.connectivity);
    await gateway.firstPullStarted.future;
    final realtime = coordinator.synchronize(SyncTrigger.realtime);
    final resume = coordinator.synchronize(SyncTrigger.appResume);
    expect(identical(first, realtime), isTrue);
    expect(identical(first, resume), isTrue);
    gateway.releaseFirstPull.complete();

    final result = await first;

    expect(gateway.pullCount, 2);
    expect(result.pulledPages, 1, reason: 'the returned result is the rerun');
    expect(coordinator.isRunning, isFalse);
  });

  test('owner switch after network await rejects page without cursor advance',
      () async {
    var ownerActive = true;
    final gateway = _OwnerSwitchGateway(() => ownerActive = false);
    final coordinator = SyncCoordinator(
      ownerUserId: owner,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(gateway),
        store: store,
      ),
      gateway: gateway,
      store: store,
      isOwnerActive: () => ownerActive,
    );

    await expectLater(
      coordinator.synchronize(),
      throwsA(isA<RemoteScheduleAuthenticationException>()),
    );
    expect(await store.cursor(), 0);
    expect(coordinator.isRunning, isFalse);
  });

  test('post-ack interruption leaves a restart-recoverable processing row',
      () async {
    await _insertCourse(db);
    await queue.enqueue(_mutation());
    final gateway = FakeRemoteScheduleGateway(
      ackFor: (mutation, callNumber) => ScheduleMutationAck(
        clientMutationId: mutation.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: mutation.entityType,
        entityId: mutation.entityId,
        operation: mutation.operation,
        change: ScheduleDeltaChange(
          changeCursor: 1,
          entityType: mutation.entityType,
          entityId: mutation.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 1,
          payload: mutation.payload,
        ),
        replayed: callNumber > 1,
      ),
    );
    final interrupted = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      store: store,
      afterRemoteAck: (_, __) => Future<void>.error(_SimulatedProcessDeath()),
    );

    await expectLater(
      interrupted.processPending(),
      throwsA(isA<_SimulatedProcessDeath>()),
    );
    expect((await queue.all()).single.status, SyncMutationStatus.processing);

    final restarted = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(gateway),
      store: store,
    );
    expect(await restarted.recoverAfterRestart(), 1);
    final result = await restarted.processPending();

    expect(result.synced, 1);
    expect((await queue.all()).single.attemptCount, 2);
    expect(gateway.calls, hasLength(2));
  });

  test(
      'A to B to A disposal stops delayed dispatch before pull and preserves lease',
      () async {
    await _insertCourse(db);
    await queue.enqueue(_mutation());

    var activeLease = 'owner-a-activation-1';
    final oldLease = activeLease;
    final delayedGateway = _DelayedDispatchGateway();
    final staleCoordinator = SyncCoordinator(
      ownerUserId: owner,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(delayedGateway),
        store: store,
        isContextCurrent: () => activeLease == oldLease,
      ),
      gateway: delayedGateway,
      store: store,
      isOwnerActive: () => activeLease == oldLease,
      isContextCurrent: () => activeLease == oldLease,
    );

    final staleRun = staleCoordinator.synchronize();
    await delayedGateway.dispatchStarted.future;

    // A -> B -> A still invalidates the old lease. Returning to the same
    // owner must not revive an already-disposed worker or coordinator.
    activeLease = 'owner-b-activation-1';
    activeLease = 'owner-a-activation-2';
    staleCoordinator.dispose();
    delayedGateway.releaseDispatch.complete();

    final staleResult = await staleRun;
    final retained = (await queue.all()).single;
    expect(staleResult.push.contextCancelled, isTrue);
    expect(staleResult.push.stoppedBeforeDrain, isTrue);
    expect(staleResult.pulledPages, 0);
    expect(delayedGateway.pullCalls, isEmpty);
    expect(retained.status, SyncMutationStatus.processing);
    expect(await store.cursor(), 0);
    expect(
      (await db.timetableDao.courseById('course-1', owner))?.title,
      'Local',
    );

    final freshGateway = FakeRemoteScheduleGateway();
    final freshWorker = SyncWorker(
      queue: queue,
      dispatcher: SyncMutationDispatcher(freshGateway),
      store: store,
      isContextCurrent: () => activeLease == 'owner-a-activation-2',
    );
    expect(await freshWorker.recoverAfterRestart(), 1);
    final freshCoordinator = SyncCoordinator(
      ownerUserId: owner,
      worker: freshWorker,
      gateway: freshGateway,
      store: store,
      isOwnerActive: () => activeLease == 'owner-a-activation-2',
      isContextCurrent: () => activeLease == 'owner-a-activation-2',
    );

    final freshResult = await freshCoordinator.synchronize();
    final replayed = (await queue.all()).single;
    expect(freshResult.push.synced, 1);
    expect(freshGateway.calls, hasLength(1));
    expect(freshGateway.pullCalls, hasLength(1));
    expect(replayed.status, SyncMutationStatus.synced);
    expect(
      (await db.timetableDao.courseById('course-1', owner))?.title,
      'Canonical',
    );
  });
}

class _BlockingPullGateway implements RemoteScheduleGateway {
  final firstPullStarted = Completer<void>();
  final releaseFirstPull = Completer<void>();
  int pullCount = 0;

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) {
    throw UnimplementedError();
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async {
    pullCount++;
    if (pullCount == 1) {
      firstPullStarted.complete();
      await releaseFirstPull.future;
    }
    return ScheduleDeltaPage(
      afterCursor: afterCursor,
      nextCursor: afterCursor,
      hasMore: false,
      changes: const [],
    );
  }
}

class _OwnerSwitchGateway implements RemoteScheduleGateway {
  _OwnerSwitchGateway(this.onPull);

  final void Function() onPull;

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) {
    throw UnimplementedError();
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async {
    onPull();
    return ScheduleDeltaPage(
      afterCursor: afterCursor,
      nextCursor: afterCursor,
      hasMore: false,
      changes: const [],
    );
  }
}

class _SimulatedProcessDeath implements Exception {}

class _DelayedDispatchGateway implements RemoteScheduleGateway {
  final dispatchStarted = Completer<void>();
  final releaseDispatch = Completer<void>();
  final _delegate = FakeRemoteScheduleGateway();

  List<RemoteScheduleCall> get calls => _delegate.calls;

  List<RemoteSchedulePullCall> get pullCalls => _delegate.pullCalls;

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    dispatchStarted.complete();
    await releaseDispatch.future;
    return _delegate.applyMutation(mutation);
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) {
    return _delegate.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: afterCursor,
      limit: limit,
    );
  }
}

Future<void> _insertCourse(local.AppDatabase db) {
  return db.timetableDao.upsertCourse(
    local.UserCoursesCompanion.insert(
      id: 'course-1',
      ownerUserId: 'owner-a',
      termId: 'term-1',
      title: 'Local',
      normalizedTitle: 'local',
      dayOfWeek: const Value(1),
      periodNo: const Value(1),
      visibilityLevel: const Value('PRIVATE'),
      updatedAt: Value(DateTime.utc(2026, 7, 10)),
    ),
  );
}

PendingMutation _mutation() {
  return PendingMutation(
    clientMutationId: 'mutation-1',
    ownerUserId: 'owner-a',
    entityType: 'user_course',
    entityId: 'course-1',
    operation: SyncOperation.create,
    payload: const {
      'id': 'course-1',
      'ownerUserId': 'owner-a',
      'termId': 'term-1',
      'sourceTemplateId': null,
      'title': 'Canonical',
      'normalizedTitle': 'canonical',
      'instructorName': null,
      'normalizedInstructorName': null,
      'dayOfWeek': 1,
      'periodNo': 1,
      'room': null,
      'color': null,
      'visibilityLevel': 'PRIVATE',
      'updatedAt': '2026-07-10T00:00:00Z',
      'deletedAt': null,
      'version': 1,
    },
    createdAt: DateTime.utc(2026, 7, 10),
  );
}
