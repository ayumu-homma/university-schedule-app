import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const owner = 'owner-a';
  late local.AppDatabase db;
  late LocalNotificationStore notifications;

  setUp(() {
    db = local.AppDatabase(NativeDatabase.memory());
    notifications = LocalNotificationStore(db);
  });

  tearDown(() => db.close());

  test('source epoch advances for assignment, submit, and Undo mutations',
      () async {
    final repository = DriftScheduleRepository(
      db,
      createId: () => 'assignment-epoch',
    );
    final before = await notifications.sourceEpoch();

    final assignmentId = await repository.createAssignment(
      ownerUserId: owner,
      input: AssignmentInput(
        title: 'Epoch guarded assignment',
        dueAt: DateTime.utc(2026, 9, 25, 12),
      ),
    );
    final afterCreate = await notifications.sourceEpoch();
    expect(assignmentId, 'assignment-epoch');
    expect(afterCreate, greaterThan(before));

    final receipt = await repository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: owner,
      submittedAt: DateTime.utc(2026, 9, 20, 1),
    );
    final afterSubmit = await notifications.sourceEpoch();
    expect(afterSubmit, greaterThan(afterCreate));

    await repository.undoAssignmentSubmission(
      receipt: receipt,
      updatedAt: DateTime.utc(2026, 9, 20, 2),
    );
    expect(await notifications.sourceEpoch(), greaterThan(afterSubmit));
  });

  test('remote schedule application advances the same local source epoch',
      () async {
    final sync = DriftScheduleSyncStore(db, ownerUserId: owner);
    final before = await notifications.sourceEpoch();

    await sync.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [
          ScheduleDeltaChange(
            changeCursor: 1,
            entityType: 'assignment',
            entityId: 'remote-assignment',
            operation: ScheduleDeltaOperation.upsert,
            serverVersion: 1,
            payload: _assignmentPayload(
              id: 'remote-assignment',
              ownerUserId: owner,
              title: 'Remote assignment',
            ),
          ),
        ],
      ),
      appliedAt: DateTime.utc(2026, 9, 20),
    );

    final after = await notifications.sourceEpoch();
    expect(after, greaterThan(before));
    expect(await sync.cursor(), 1);
    final row = await (db.select(db.assignments)
          ..where((item) => item.id.equals('remote-assignment')))
        .getSingle();
    expect(row.ownerUserId, owner);
    expect(row.title, 'Remote assignment');
  });

  test(
      'projection writes do not bump source epoch and stale CAS preserves rows',
      () async {
    final sourceEpoch = await notifications.sourceEpoch();
    final firstPlan = _plan(
      id: 'notification-first',
      sourceEpoch: sourceEpoch,
      projectionEpoch: 1,
      sourceEntityId: 'assignment-first',
    );
    await notifications.replaceProjection(
      owner: owner,
      sourceEpoch: sourceEpoch,
      projectionEpoch: 1,
      capped: false,
      plans: [firstPlan],
    );
    expect(await notifications.sourceEpoch(), sourceEpoch);
    expect(await notifications.projectionEpoch(owner), 1);
    final currentRows = await notifications.desiredRows(owner);
    expect(currentRows, hasLength(1));
    expect(currentRows.single['id'], 'notification-first');

    await notifications.saveSettings(
      owner,
      const LocalNotificationSettingsValue(enabled: false),
    );
    final currentSourceEpoch = await notifications.sourceEpoch();
    expect(currentSourceEpoch, greaterThan(sourceEpoch));

    await expectLater(
      notifications.replaceProjection(
        owner: owner,
        sourceEpoch: sourceEpoch,
        projectionEpoch: 2,
        capped: false,
        plans: [
          _plan(
            id: 'notification-stale',
            sourceEpoch: sourceEpoch,
            projectionEpoch: 2,
            sourceEntityId: 'assignment-stale',
          ),
        ],
      ),
      throwsA(isA<StateError>()),
    );

    expect(await notifications.projectionEpoch(owner), 1);
    final rowsAfterReject = await notifications.desiredRows(owner);
    expect(rowsAfterReject, hasLength(1));
    expect(rowsAfterReject.single['id'], 'notification-first');
  });

  test('empty and verified imported reminder rules exclude cancelled rows',
      () async {
    expect(await notifications.importedReminderRules(owner), isEmpty);

    await _insertVerifiedEmailNotification(
      db,
      ownerUserId: owner,
      entityId: 'assignment-valid',
      requestId: 'valid-request',
      state: 'pending',
    );
    await _insertVerifiedEmailNotification(
      db,
      ownerUserId: owner,
      entityId: 'assignment-cancelled',
      requestId: 'cancelled-request',
      state: 'cancelled',
    );

    expect(
      await notifications.importedReminderRules(owner),
      <String, List<int>>{
        'assignment-valid': [180, 20]
      },
    );
  });

  test('malformed legacy reminder JSON is ignored by the store', () async {
    // Current databases reject this row through notification_requests_guard_insert.
    // A separate in-memory fixture with that production guard removed models a
    // pre-guard/corrupt local database and verifies the reader fails closed.
    final legacyDb = local.AppDatabase(NativeDatabase.memory());
    addTearDown(() => legacyDb.close());
    final legacyStore = LocalNotificationStore(legacyDb);
    await legacyDb.customStatement(
      'DROP TRIGGER notification_requests_guard_insert',
    );
    await legacyDb.into(legacyDb.notificationScheduleRequests).insert(
          local.NotificationScheduleRequestsCompanion.insert(
            id: 'legacy-corrupt-request',
            ownerUserId: owner,
            entityType: 'assignment',
            entityId: 'assignment-corrupt',
            sourceId: 'legacy-source',
            idempotencyKey: 'legacy-idempotency',
            anchorAt: DateTime.utc(2026, 9, 25, 12),
            remindersMinutesJson: const Value('{not-json'),
            targetPath: '/assignment/assignment-corrupt/edit',
          ),
        );

    expect(await legacyStore.importedReminderRules(owner), isEmpty);
  });

  test(
      'schema 17 upgrade creates notification tables without losing assignments',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('notification-v17-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    final legacy = local.AppDatabase(NativeDatabase(file));
    final repository = DriftScheduleRepository(
      legacy,
      createId: () => 'schema17-assignment',
    );
    await repository.createAssignment(
      ownerUserId: owner,
      input: AssignmentInput(
        title: 'Preserved schema 17 assignment',
        dueAt: DateTime.utc(2026, 9, 25, 12),
      ),
    );

    // Model the committed v17 file: notification tables and their phase-7
    // triggers did not exist yet, while all prior business rows did.
    for (final table in <String>[
      'terms',
      'period_settings',
      'user_courses',
      'assignments',
      'assignment_user_states',
      'exams',
      'events',
      'event_exceptions',
      'notification_schedule_requests',
      'local_notification_settings',
    ]) {
      for (final action in <String>['insert', 'update', 'delete']) {
        await legacy.customStatement(
          'DROP TRIGGER IF EXISTS local_notification_epoch_${table}_$action',
        );
      }
    }
    await legacy.customStatement(
      'DROP TABLE local_notification_source_revisions',
    );
    await legacy
        .customStatement('DROP TABLE local_notification_projection_states');
    await legacy.customStatement('DROP TABLE local_notification_occurrences');
    await legacy.customStatement('DROP TABLE local_notification_settings');
    await legacy.customStatement('PRAGMA user_version = 17');
    await legacy.close();

    final upgraded = local.AppDatabase(NativeDatabase(file));
    addTearDown(() => upgraded.close());
    final assignment = await (upgraded.select(upgraded.assignments)
          ..where((row) => row.id.equals('schema17-assignment')))
        .getSingle();
    expect(assignment.title, 'Preserved schema 17 assignment');
    expect(await LocalNotificationStore(upgraded).sourceEpoch(), 0);
    expect(
      await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'local_notification_occurrences'",
          )
          .getSingleOrNull(),
      isNotNull,
    );
  });
}

Future<void> _insertVerifiedEmailNotification(
  local.AppDatabase database, {
  required String ownerUserId,
  required String entityId,
  required String requestId,
  required String state,
}) async {
  final now = DateTime.utc(2026, 9, 20, 12);
  final connectionId = 'connection-$entityId';
  final sourceId = 'source-$entityId';
  final candidateId = 'candidate-$entityId';
  final linkId = 'link-$entityId';
  final idempotencyKey = 'idempotency-$entityId';

  await database.into(database.assignments).insert(
        local.AssignmentsCompanion.insert(
          id: entityId,
          ownerUserId: ownerUserId,
          title: 'Verified imported assignment',
          dueAt: now,
        ),
      );
  await database.into(database.emailConnections).insert(
        local.EmailConnectionsCompanion.insert(
          id: connectionId,
          ownerUserId: ownerUserId,
          provider: 'gmail',
          providerAccountHash: 'account-$entityId',
        ),
      );
  await database.into(database.emailSources).insert(
        local.EmailSourcesCompanion.insert(
          id: sourceId,
          ownerUserId: ownerUserId,
          connectionId: connectionId,
          providerMessageId: 'message-$entityId',
          providerThreadId: 'thread-$entityId',
          receivedAt: now,
          sanitizedContentHash: 'content-$entityId',
          processingState: const Value('processed'),
        ),
      );
  await database.into(database.emailCandidates).insert(
        local.EmailCandidatesCompanion.insert(
          id: candidateId,
          ownerUserId: ownerUserId,
          sourceId: sourceId,
          schemaVersion: '1.0',
          candidateType: 'assignment',
          normalizedPayloadJson: '{"schema_version":"1.0"}',
          reviewState: const Value('confirmed'),
          semanticFingerprint: 'fingerprint-$entityId',
          linkedEntityType: const Value('assignment'),
          linkedEntityId: Value(entityId),
          confirmationIdempotencyKey: Value(idempotencyKey),
          confirmedAt: Value(now),
        ),
      );
  await database.into(database.emailScheduleEntityLinks).insert(
        local.EmailScheduleEntityLinksCompanion.insert(
          id: linkId,
          ownerUserId: ownerUserId,
          sourceId: sourceId,
          candidateId: candidateId,
          entityType: 'assignment',
          entityId: entityId,
          confirmationIdempotencyKey: idempotencyKey,
        ),
      );
  await database.into(database.notificationScheduleRequests).insert(
        local.NotificationScheduleRequestsCompanion.insert(
          id: requestId,
          ownerUserId: ownerUserId,
          entityType: 'assignment',
          entityId: entityId,
          sourceId: candidateId,
          idempotencyKey: idempotencyKey,
          anchorAt: now,
          remindersMinutesJson: Value(jsonEncode(<int>[180, 20])),
          targetPath: '/assignment/$entityId/edit',
          state: Value(state),
        ),
      );
}

LocalNotificationPlan _plan({
  required String id,
  required int sourceEpoch,
  required int projectionEpoch,
  required String sourceEntityId,
}) {
  final occurrence = DateTime.utc(2026, 9, 25, 12);
  return LocalNotificationPlan(
    id: id,
    ownerUserId: 'owner-a',
    kind: 'assignment',
    sourceEntityId: sourceEntityId,
    occurrenceAt: occurrence,
    triggerAt: occurrence.subtract(const Duration(minutes: 180)),
    targetPath: '/assignments/$sourceEntityId',
    title: 'Assignment',
    body: 'Due soon',
    rule: 'absolute_180m',
    fingerprint: 'fingerprint-$id',
    sourceEpoch: sourceEpoch,
    projectionEpoch: projectionEpoch,
  );
}

Map<String, Object?> _assignmentPayload({
  required String id,
  required String ownerUserId,
  required String title,
}) {
  return {
    'id': id,
    'ownerUserId': ownerUserId,
    'courseId': null,
    'title': title,
    'memo': null,
    'submissionUrl': null,
    'priority': null,
    'dueAt': '2026-09-25T12:00:00Z',
    'visibilityLevel': 'PRIVATE',
    'updatedAt': '2026-09-20T00:00:00Z',
    'deletedAt': null,
    'version': 1,
  };
}
