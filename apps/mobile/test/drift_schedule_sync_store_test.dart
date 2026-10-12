import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
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

  test('successful ack atomically applies canonical row and clears outbox',
      () async {
    await _insertCourse(db, title: 'optimistic');
    await queue.enqueue(_courseMutation());
    final claimed = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    final acknowledgement = ScheduleMutationAck(
      clientMutationId: claimed!.clientMutationId,
      outcome: ScheduleMutationOutcome.applied,
      entityType: 'user_course',
      entityId: 'course-1',
      operation: SyncOperation.create,
      change: _courseChange(
        cursor: 10,
        title: 'canonical',
        version: 1,
      ),
      replayed: false,
    );

    await store.acknowledge(
      claimed,
      acknowledgement,
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 1),
    );

    final course = await db.timetableDao.courseById('course-1', owner);
    final mutation = (await queue.all()).single;
    expect(course?.title, 'canonical');
    expect(course?.version, 1);
    expect(mutation.status, SyncMutationStatus.synced);
    expect(mutation.serverVersion, 1);
    expect(mutation.payload, isEmpty);
    final storedMutation = (await db.syncQueueDao.allMutations(owner)).single;
    expect(
      storedMutation.completionProvenance,
      local.scheduleSyncCompletionRemoteApplied,
    );
    expect(await store.cursor(), 0, reason: 'an ack cannot skip delta rows');
  });

  test(
      'template update ack is fenced by a later personal edit and ignore reconciles',
      () async {
    await _insertCourse(db, title: 'personal', version: 1);
    final templatePayload = <String, Object?>{
      'id': 'course-1',
      'ownerUserId': owner,
      'termId': 'term-1',
      'sourceTemplateId': 'template-1',
      'title': 'template title',
      'normalizedTitle': 'template title',
      'instructorName': 'teacher',
      'normalizedInstructorName': 'teacher',
      'dayOfWeek': 2,
      'periodNo': 2,
      'room': 'B-2',
      'color': null,
      'visibilityLevel': 'PRIVATE',
      'updatedAt': '2026-07-10T00:01:00Z',
      'deletedAt': null,
      'version': 2,
    };
    await queue.enqueue(PendingMutation(
      clientMutationId: 'template-apply',
      ownerUserId: owner,
      entityType: 'course_template_update_apply',
      entityId: 'course-1',
      operation: SyncOperation.submit,
      baseVersion: 1,
      payload: {...templatePayload, 'action': 'apply'},
      createdAt: DateTime.utc(2026, 7, 10),
    ));
    await queue.enqueue(_courseMutation(
      operation: SyncOperation.update,
      baseVersion: 1,
      version: 2,
      title: 'newer personal edit',
    ));
    final claimed = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    await store.acknowledge(
      claimed!,
      ScheduleMutationAck(
        clientMutationId: claimed.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: claimed.entityType,
        entityId: claimed.entityId,
        operation: claimed.operation,
        change: ScheduleDeltaChange(
          changeCursor: 0,
          entityType: claimed.entityType,
          entityId: claimed.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 2,
          payload: templatePayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 2),
    );
    expect((await db.timetableDao.courseById('course-1', owner))?.title,
        'personal');

    final personal = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    await store.acknowledge(
      personal!,
      ScheduleMutationAck(
        clientMutationId: personal.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: 'user_course',
        entityId: 'course-1',
        operation: personal.operation,
        change: _courseChange(
          cursor: 0,
          title: 'newer personal edit',
          version: 2,
        ),
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 3),
    );

    final ignorePayload = {
      ...templatePayload,
      'title': 'newer personal edit',
      'normalizedTitle': 'newer personal edit',
      'action': 'ignore',
    };
    final ignoreMutation = PendingMutation(
      clientMutationId: 'template-ignore',
      ownerUserId: owner,
      entityType: 'course_template_update_apply',
      entityId: 'course-1',
      operation: SyncOperation.submit,
      baseVersion: 1,
      payload: ignorePayload,
      createdAt: DateTime.utc(2026, 7, 10, 0, 4),
    );
    await queue.enqueue(ignoreMutation);
    final ignored = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    await store.acknowledge(
      ignored!,
      ScheduleMutationAck(
        clientMutationId: ignored.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: ignored.entityType,
        entityId: ignored.entityId,
        operation: ignored.operation,
        change: ScheduleDeltaChange(
          changeCursor: 0,
          entityType: ignored.entityType,
          entityId: ignored.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 2,
          payload: ignorePayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 5),
    );
    expect((await db.timetableDao.courseById('course-1', owner))?.title,
        'newer personal edit');
    expect((await db.timetableDao.courseById('course-1', owner))?.version, 2);
  });

  test('conflict retains local row and durable canonical server snapshot',
      () async {
    await _insertCourse(db, title: 'local edit', version: 2);
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
          cursor: 11,
          title: 'remote edit',
          version: 2,
        ),
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 1),
    );

    final course = await db.timetableDao.courseById('course-1', owner);
    final conflict = (await queue.all()).single;
    expect(course?.title, 'local edit');
    expect(conflict.status, SyncMutationStatus.conflict);
    expect(conflict.serverVersion, 2);
    expect(conflict.conflictCursor, 11);
    expect(conflict.serverPayload['title'], 'remote edit');
    expect(conflict.payload['title'], 'local edit');
  });

  test('server-wins applies canonical conflict without remote provenance',
      () async {
    await _insertCourse(db, title: 'local edit', version: 2);
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

    await store.resolveConflictServerWins(
      claimed.clientMutationId,
      resolvedAt: DateTime.utc(2026, 7, 10, 0, 2),
    );

    final course = await db.timetableDao.courseById('course-1', owner);
    final resolved = (await queue.all()).single;
    expect(course?.title, 'remote canonical');
    expect(resolved.status, SyncMutationStatus.synced);
    expect(resolved.payload, isEmpty);
    expect(resolved.serverPayload, isEmpty);
    expect(resolved.errorMessage, isNull);
    expect(resolved.conflictCursor, isNull);
    expect(resolved.syncedAt?.toUtc(), DateTime.utc(2026, 7, 10, 0, 2));
    final storedResolution = (await db.syncQueueDao.allMutations(owner)).single;
    expect(
      storedResolution.completionProvenance,
      local.scheduleSyncCompletionServerWins,
    );
    await expectLater(
      (db.update(db.syncQueueEntries)
            ..where(
                (row) => row.clientMutationId.equals(claimed.clientMutationId)))
          .write(
        const local.SyncQueueEntriesCompanion(serverVersion: Value(null)),
      ),
      throwsA(anything),
    );
    expect(await store.cursor(), 0, reason: 'resolution cannot skip deltas');
  });

  test('delta upsert and tombstone commit with cursor in one transaction',
      () async {
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 2,
        hasMore: false,
        changes: [
          _courseChange(cursor: 1, title: 'remote', version: 1),
          _courseDelete(cursor: 2, version: 2),
        ],
      ),
      appliedAt: DateTime.utc(2026, 7, 10),
    );

    final row = await (db.select(db.userCourses)
          ..where((course) => course.id.equals('course-1')))
        .getSingle();
    expect(row.deletedAt?.toUtc(), DateTime.utc(2026, 7, 10, 2));
    expect(row.version, 2);
    expect(await db.timetableDao.courseById('course-1', owner), isNull);
    expect(await store.cursor(), 2);
  });

  test('active local mutation rolls back every change and cursor advance',
      () async {
    await _insertCourse(db, title: 'local', version: 1);
    await queue.enqueue(
      _courseMutation(
        operation: SyncOperation.update,
        baseVersion: 1,
        version: 2,
      ),
    );

    final page = ScheduleDeltaPage(
      afterCursor: 0,
      nextCursor: 2,
      hasMore: false,
      changes: [
        _assignmentChange(cursor: 1),
        _courseChange(cursor: 2, title: 'remote', version: 2),
      ],
    );

    await expectLater(
      store.applyDeltaPage(page),
      throwsA(isA<PendingLocalMutationException>()),
    );
    expect(await db.assignmentDao.assignmentsForUser(owner), isEmpty);
    expect(
        (await db.timetableDao.courseById('course-1', owner))?.title, 'local');
    expect(await store.cursor(), 0);
  });

  test('unknown retained tombstone is an idempotent cursor-advancing no-op',
      () async {
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [_courseDelete(cursor: 1, version: 4)],
      ),
    );

    expect(await db.select(db.userCourses).get(), isEmpty);
    expect(await store.cursor(), 1);
  });

  test('non-JST personal event deltas fail closed before local persistence',
      () async {
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [_eventChange(cursor: 1, timezone: 'UTC')],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );

    expect(await db.select(db.events).get(), isEmpty);
    expect(await store.cursor(), 0);
  });

  test('non-JST group event deltas fail closed before local persistence',
      () async {
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [
            _eventChange(
              cursor: 1,
              timezone: 'UTC',
              groupId: 'group-1',
            ),
          ],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );

    expect(await db.select(db.events).get(), isEmpty);
    expect(await store.cursor(), 0);
  });

  test('offsetless event timestamps fail closed before local persistence',
      () async {
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [
            _eventChange(
              cursor: 1,
              timezone: 'Asia/Tokyo',
              startAt: '2026-07-13T00:00:00',
            ),
          ],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );

    expect(await db.select(db.events).get(), isEmpty);
    expect(await store.cursor(), 0);
  });

  test('all-day event deltas persist the canonical all-day state', () async {
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [
          _eventChange(
            cursor: 1,
            timezone: 'Asia/Tokyo',
            isAllDay: true,
          ),
        ],
      ),
    );

    final event = await db.select(db.events).getSingle();
    expect(event.isAllDay, isTrue);
    expect(await store.cursor(), 1);
  });

  test('non-boolean event all-day state fails closed', () async {
    final valid = _eventChange(cursor: 1, timezone: 'Asia/Tokyo');
    final malformed = ScheduleDeltaChange(
      changeCursor: valid.changeCursor,
      entityType: valid.entityType,
      entityId: valid.entityId,
      operation: valid.operation,
      serverVersion: valid.serverVersion,
      payload: {...valid.payload, 'isAllDay': 'true'},
    );

    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [malformed],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );

    expect(await db.select(db.events).get(), isEmpty);
    expect(await store.cursor(), 0);
  });

  test('fresh assignment-state tombstone remains hidden but can be resubmitted',
      () async {
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 2,
        hasMore: false,
        changes: [
          _assignmentChange(cursor: 1),
          _assignmentStateDelete(cursor: 2, version: 2),
        ],
      ),
    );

    final retained = await db.assignmentDao.stateForAssignment(
      assignmentId: 'assignment-1',
      userId: owner,
    );
    expect(retained?.version, 2);
    expect(retained?.deletedAt, isNotNull);
    expect(await db.assignmentDao.statesForUser(owner), isEmpty);

    await DriftScheduleRepository(db).submitAssignment(
      assignmentId: 'assignment-1',
      userId: owner,
      submittedAt: DateTime.utc(2026, 7, 11),
    );

    final resubmitted = await db.assignmentDao.stateForAssignment(
      assignmentId: 'assignment-1',
      userId: owner,
    );
    final mutation = (await queue.all()).single;
    expect(resubmitted?.deletedAt, isNull);
    expect(resubmitted?.version, 3);
    expect(mutation.operation, SyncOperation.submit);
    expect(mutation.baseVersion, 2);
    expect(mutation.payload['version'], 3);
    expect(await store.cursor(), 2);
  });

  test('owner mismatch rejects the whole page without advancing cursor',
      () async {
    final change = _courseChange(cursor: 1, title: 'remote', version: 1);
    final escaped = ScheduleDeltaChange(
      changeCursor: change.changeCursor,
      entityType: change.entityType,
      entityId: change.entityId,
      operation: change.operation,
      serverVersion: change.serverVersion,
      payload: {...change.payload, 'ownerUserId': 'owner-b'},
    );

    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [escaped],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
    expect(await store.cursor(), 0);
  });

  test('event-exception ack and delta tombstone preserve canonical metadata',
      () async {
    await _insertEventException(db, title: 'optimistic', version: 1);
    await queue.enqueue(_eventExceptionMutation());
    final claimed = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    final canonical = _eventExceptionChange(
      cursor: 1,
      title: 'canonical',
      version: 1,
    );

    await store.acknowledge(
      claimed!,
      ScheduleMutationAck(
        clientMutationId: claimed.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: 'event_exception',
        entityId: 'exception-1',
        operation: SyncOperation.create,
        change: canonical,
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 1),
    );

    var row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals('exception-1')))
        .getSingle();
    expect(row.ownerUserId, owner);
    expect(row.version, 1);
    expect(row.deletedAt, isNull);
    expect(row.overridePayloadJson, contains('canonical'));
    expect((await queue.all()).single.status, SyncMutationStatus.synced);

    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 2,
        hasMore: false,
        changes: [
          canonical,
          _eventExceptionDelete(cursor: 2, version: 2),
        ],
      ),
      appliedAt: DateTime.utc(2026, 7, 10, 0, 2),
    );

    row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals('exception-1')))
        .getSingle();
    expect(row.version, 2);
    expect(row.deletedAt?.toUtc(), DateTime.utc(2026, 7, 10, 2));
    expect(await db.eventDao.exceptionsForEvents(['routine-1']), isEmpty);
    expect(await store.cursor(), 2);
  });

  test(
      'duplicate routine occurrence conflict server-wins tombstones optimistic create without retrying',
      () async {
    await _insertEventException(db,
        title: 'optimistic losing exception', version: 1);
    await queue.enqueue(_eventExceptionMutation());
    final claimed = await queue.claimNext(now: DateTime.utc(2026, 7, 10));
    final canonicalTombstone = _eventExceptionDelete(cursor: 9, version: 2);

    await store.acknowledge(
      claimed!,
      ScheduleMutationAck(
        clientMutationId: claimed.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'event_exception',
        entityId: 'exception-1',
        operation: SyncOperation.create,
        change: canonicalTombstone,
        replayed: false,
      ),
      acknowledgedAt: DateTime.utc(2026, 7, 10, 0, 1),
    );

    var row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals('exception-1')))
        .getSingle();
    var mutation = (await queue.all()).single;
    expect(row.deletedAt, isNull,
        reason: 'the local choice remains inspectable');
    expect(row.overridePayloadJson, contains('optimistic losing exception'));
    expect(mutation.status, SyncMutationStatus.conflict);
    expect(mutation.serverVersion, 2);
    expect(mutation.conflictCursor, 9);
    expect(
      mutation.serverPayload['deletedAt'],
      '2026-07-10T02:00:00Z',
    );

    await store.resolveConflictServerWins(
      claimed.clientMutationId,
      resolvedAt: DateTime.utc(2026, 7, 10, 0, 2),
    );

    row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals('exception-1')))
        .getSingle();
    mutation = (await queue.all()).single;
    expect(row.version, 2);
    expect(row.deletedAt?.toUtc(), DateTime.utc(2026, 7, 10, 2));
    expect(await db.eventDao.exceptionsForEvents(['routine-1']), isEmpty);
    expect(mutation.status, SyncMutationStatus.synced);
    expect(mutation.payload, isEmpty);
    expect(mutation.serverPayload, isEmpty);
    expect(mutation.errorMessage, isNull);
    expect(mutation.conflictCursor, isNull);
    expect(mutation.syncedAt?.toUtc(), DateTime.utc(2026, 7, 10, 0, 2));
    expect(
      await queue.claimNext(now: DateTime.utc(2026, 7, 10, 0, 3)),
      isNull,
      reason: 'a server-wins duplicate conflict must not re-enter retry',
    );
  });

  test('a second device does not overwrite an offline routine exception edit',
      () async {
    // This local database represents device B. The first delta was emitted
    // by device A; the queued write below is device B's offline edit.
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [
          _eventExceptionChange(cursor: 1, title: 'device A', version: 1),
        ],
      ),
    );
    await _insertEventException(db, title: 'device B offline', version: 2);
    await queue.enqueue(
      _eventExceptionMutation(
        operation: SyncOperation.update,
        baseVersion: 1,
        version: 2,
        title: 'device B offline',
      ),
    );

    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 1,
          nextCursor: 2,
          hasMore: false,
          changes: [
            _eventExceptionChange(
                cursor: 2, title: 'device A later', version: 2),
          ],
        ),
      ),
      throwsA(isA<PendingLocalMutationException>()),
    );

    final row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals('exception-1')))
        .getSingle();
    expect(row.version, 2);
    expect(row.overridePayloadJson, contains('device B offline'));
    expect(await store.cursor(), 1);
  });
}

Future<void> _insertCourse(
  local.AppDatabase db, {
  required String title,
  int version = 1,
}) {
  return db.timetableDao.upsertCourse(
    local.UserCoursesCompanion.insert(
      id: 'course-1',
      ownerUserId: 'owner-a',
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
  SyncOperation operation = SyncOperation.create,
  int? baseVersion,
  int version = 1,
  String title = 'optimistic',
}) {
  return PendingMutation(
    clientMutationId: 'mutation-$version',
    ownerUserId: 'owner-a',
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
    'ownerUserId': 'owner-a',
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

ScheduleDeltaChange _courseDelete({
  required int cursor,
  required int version,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'user_course',
    entityId: 'course-1',
    operation: ScheduleDeltaOperation.delete,
    serverVersion: version,
    deletedAt: DateTime.utc(2026, 7, 10, 2),
    payload: {
      'id': 'course-1',
      'ownerUserId': 'owner-a',
      'deletedAt': '2026-07-10T02:00:00Z',
      'updatedAt': '2026-07-10T02:00:00Z',
      'version': version,
    },
  );
}

ScheduleDeltaChange _assignmentChange({required int cursor}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'assignment',
    entityId: 'assignment-1',
    operation: ScheduleDeltaOperation.upsert,
    serverVersion: 1,
    payload: const {
      'id': 'assignment-1',
      'ownerUserId': 'owner-a',
      'courseId': null,
      'title': 'Assignment',
      'memo': null,
      'submissionUrl': null,
      'priority': null,
      'dueAt': '2026-07-11T00:00:00Z',
      'visibilityLevel': 'PRIVATE',
      'updatedAt': '2026-07-10T00:00:00Z',
      'deletedAt': null,
      'version': 1,
    },
  );
}

ScheduleDeltaChange _assignmentStateDelete({
  required int cursor,
  required int version,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'assignment_user_state',
    entityId: 'assignment-1',
    operation: ScheduleDeltaOperation.delete,
    serverVersion: version,
    deletedAt: DateTime.utc(2026, 7, 10, 2),
    payload: {
      'assignmentId': 'assignment-1',
      'userId': 'owner-a',
      'status': 'submitted',
      'submittedAt': '2026-07-10T01:00:00Z',
      'note': null,
      'updatedAt': '2026-07-10T02:00:00Z',
      'deletedAt': '2026-07-10T02:00:00Z',
      'version': version,
    },
  );
}

ScheduleDeltaChange _eventChange({
  required int cursor,
  required String timezone,
  String? groupId,
  String startAt = '2026-07-13T00:00:00Z',
  bool isAllDay = false,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'event',
    entityId: 'event-1',
    operation: ScheduleDeltaOperation.upsert,
    serverVersion: 1,
    payload: {
      'id': 'event-1',
      'ownerUserId': 'owner-a',
      'calendarId': 'calendar-1',
      'groupId': groupId,
      'title': 'Remote event',
      'kind': 'normal',
      'startAt': startAt,
      'endAt': '2026-07-13T01:00:00Z',
      'isAllDay': isAllDay,
      'location': null,
      'description': null,
      'rrule': null,
      'timezone': timezone,
      'visibilityLevel': 'PRIVATE',
      'updatedAt': '2026-07-10T00:00:00Z',
      'deletedAt': null,
      'version': 1,
    },
  );
}

Future<void> _insertEventException(
  local.AppDatabase db, {
  required String title,
  required int version,
}) {
  return db.into(db.eventExceptions).insertOnConflictUpdate(
        local.EventExceptionsCompanion.insert(
          id: 'exception-1',
          ownerUserId: 'owner-a',
          eventId: 'routine-1',
          recurrenceId: DateTime.utc(2026, 7, 13),
          mode: 'modified',
          overrideStartAt: Value(DateTime.utc(2026, 7, 13, 1)),
          overrideEndAt: Value(DateTime.utc(2026, 7, 13, 2)),
          overridePayloadJson: Value('''
            {"title":"$title","location":null,"description":null,"visibilityLevel":null}
          '''),
          updatedAt: Value(DateTime.utc(2026, 7, 10)),
          version: Value(version),
        ),
      );
}

PendingMutation _eventExceptionMutation({
  SyncOperation operation = SyncOperation.create,
  int? baseVersion,
  int version = 1,
  String title = 'optimistic',
}) {
  return PendingMutation(
    clientMutationId: 'event-exception-mutation-$version',
    ownerUserId: 'owner-a',
    entityType: 'event_exception',
    entityId: 'exception-1',
    operation: operation,
    payload: _eventExceptionPayload(title: title, version: version),
    baseVersion: baseVersion,
    createdAt: DateTime.utc(2026, 7, 10),
  );
}

ScheduleDeltaChange _eventExceptionChange({
  required int cursor,
  required String title,
  required int version,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'event_exception',
    entityId: 'exception-1',
    operation: ScheduleDeltaOperation.upsert,
    serverVersion: version,
    payload: _eventExceptionPayload(title: title, version: version),
  );
}

ScheduleDeltaChange _eventExceptionDelete({
  required int cursor,
  required int version,
}) {
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'event_exception',
    entityId: 'exception-1',
    operation: ScheduleDeltaOperation.delete,
    serverVersion: version,
    deletedAt: DateTime.utc(2026, 7, 10, 2),
    payload: {
      ..._eventExceptionPayload(title: 'canonical', version: version),
      'deletedAt': '2026-07-10T02:00:00Z',
      'updatedAt': '2026-07-10T02:00:00Z',
    },
  );
}

Map<String, Object?> _eventExceptionPayload({
  required String title,
  required int version,
}) {
  return {
    'id': 'exception-1',
    'ownerUserId': 'owner-a',
    'eventId': 'routine-1',
    'recurrenceId': '2026-07-13T00:00:00Z',
    'mode': 'modified',
    'overrideStartAt': '2026-07-13T01:00:00Z',
    'overrideEndAt': '2026-07-13T02:00:00Z',
    'overrideTitle': title,
    'overrideLocation': null,
    'overrideDescription': null,
    'overrideVisibility': null,
    'updatedAt': '2026-07-10T00:00:00Z',
    'deletedAt': null,
    'version': version,
  };
}
