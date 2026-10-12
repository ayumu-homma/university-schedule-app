import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_coordinator.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/application/schedule_sync_runtime.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('server-wins conflict resolution re-enters the sync runtime', () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final queue = DriftSyncQueue(database, ownerUserId: _ownerUserId);
    final store = DriftScheduleSyncStore(
      database,
      ownerUserId: _ownerUserId,
    );
    await _insertCourse(database, title: 'local edit', version: 2);
    await queue.enqueue(
      _courseMutation(
        operation: SyncOperation.update,
        baseVersion: 1,
        version: 2,
        title: 'local edit',
      ),
    );
    final claimed = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    await store.acknowledge(
      claimed!,
      ScheduleMutationAck(
        clientMutationId: claimed.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'user_course',
        entityId: 'course-1',
        operation: SyncOperation.update,
        change: _courseChange(
          cursor: 12,
          title: 'remote canonical',
          version: 2,
        ),
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 1),
    );

    final runtimeControllers = <_RecordingSyncRuntimeController>[];
    final container = ProviderContainer(
      overrides: [
        scheduleSyncStoreProvider.overrideWithValue(store),
        scheduleSyncRuntimeProvider.overrideWith(() {
          final controller = _RecordingSyncRuntimeController();
          runtimeControllers.add(controller);
          return controller;
        }),
        demoAppControllerProvider.overrideWith(_ControllerUnderTest.new),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(scheduleSyncRuntimeProvider).phase,
      ScheduleSyncPhase.conflict,
    );

    await container
        .read(demoAppControllerProvider.notifier)
        .resolveSyncConflictServerWins(claimed.clientMutationId);

    final resolvedCourse =
        await database.timetableDao.courseById('course-1', _ownerUserId);
    expect(resolvedCourse?.title, 'remote canonical');
    expect(runtimeControllers.single.triggers, [SyncTrigger.localMutation]);
    expect(
      container.read(scheduleSyncRuntimeProvider).phase,
      ScheduleSyncPhase.synchronized,
    );
  });
}

class _ControllerUnderTest extends DemoAppController {
  @override
  Stream<DemoAppState> build() => const Stream.empty();
}

class _RecordingSyncRuntimeController extends ScheduleSyncRuntimeController {
  final triggers = <SyncTrigger>[];

  @override
  ScheduleSyncStatus build() {
    return const ScheduleSyncStatus(
      phase: ScheduleSyncPhase.conflict,
      ownerUserId: _ownerUserId,
    );
  }

  @override
  Future<SyncCoordinatorRunResult?> trigger(SyncTrigger trigger) async {
    triggers.add(trigger);
    state = const ScheduleSyncStatus(
      phase: ScheduleSyncPhase.synchronized,
      ownerUserId: _ownerUserId,
    );
    return null;
  }
}

const _ownerUserId = 'sync-controller-owner';

Future<void> _insertCourse(
  local.AppDatabase database, {
  required String title,
  required int version,
}) {
  return database.timetableDao.upsertCourse(
    local.UserCoursesCompanion.insert(
      id: 'course-1',
      ownerUserId: _ownerUserId,
      termId: 'term-1',
      title: title,
      normalizedTitle: title,
      dayOfWeek: const Value(1),
      periodNo: const Value(1),
      visibilityLevel: const Value('PRIVATE'),
      updatedAt: Value(DateTime.utc(2026, 7, 10)),
      version: Value(version),
    ),
  );
}

PendingMutation _courseMutation({
  required SyncOperation operation,
  required int? baseVersion,
  required int version,
  required String title,
}) {
  return PendingMutation(
    clientMutationId: 'conflict-mutation',
    ownerUserId: _ownerUserId,
    entityType: 'user_course',
    entityId: 'course-1',
    operation: operation,
    payload: _coursePayload(title: title, version: version),
    baseVersion: baseVersion,
    createdAt: DateTime.utc(2026, 7, 10),
  );
}

ScheduleDeltaChange _courseChange({
  required int cursor,
  required String title,
  required int version,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'user_course',
    entityId: 'course-1',
    operation: ScheduleDeltaOperation.upsert,
    serverVersion: version,
    payload: _coursePayload(title: title, version: version),
  );
}

Map<String, Object?> _coursePayload({
  required String title,
  required int version,
}) {
  return {
    'id': 'course-1',
    'ownerUserId': _ownerUserId,
    'termId': 'term-1',
    'sourceTemplateId': null,
    'title': title,
    'normalizedTitle': title,
    'instructorName': null,
    'normalizedInstructorName': null,
    'dayOfWeek': 1,
    'periodNo': 1,
    'room': null,
    'color': null,
    'visibilityLevel': 'PRIVATE',
    'updatedAt': '2026-07-10T00:00:00Z',
    'deletedAt': null,
    'version': version,
  };
}
