import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_confirmation_repository.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_dedupe.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/local_db/email_import_identity.dart';
import 'package:uuid/uuid.dart';

const _ownerA = 'owner-a';
const _ownerB = 'owner-b';
const _calendarA = 'calendar-a';
const _calendarB = 'calendar-b';
const _courseA = 'course-a';
final _now = DateTime.utc(2026, 7, 22, 12);

Future<void> _ackAppliedMutation(
  local.AppDatabase db,
  PendingMutation mutation, {
  required DateTime acknowledgedAt,
  required int changeCursor,
}) async {
  final version = mutation.payload['version']! as int;
  final canonicalPayload = <String, Object?>{
    ...mutation.payload,
    if (mutation.entityType == 'event') 'isAllDay': false,
    'updatedAt': acknowledgedAt.toUtc().toIso8601String(),
    'deletedAt': mutation.operation == SyncOperation.delete
        ? acknowledgedAt.toUtc().toIso8601String()
        : null,
    'version': version,
  };
  await DriftScheduleSyncStore(db, ownerUserId: mutation.ownerUserId)
      .acknowledge(
    mutation,
    ScheduleMutationAck(
      clientMutationId: mutation.clientMutationId,
      outcome: ScheduleMutationOutcome.applied,
      entityType: mutation.entityType,
      entityId: mutation.entityId,
      operation: mutation.operation,
      change: ScheduleDeltaChange(
        changeCursor: changeCursor,
        entityType: mutation.entityType,
        entityId: mutation.entityId,
        operation: mutation.operation == SyncOperation.delete
            ? ScheduleDeltaOperation.delete
            : ScheduleDeltaOperation.upsert,
        serverVersion: version,
        deletedAt: mutation.operation == SyncOperation.delete
            ? acknowledgedAt.toUtc()
            : null,
        payload: canonicalPayload,
      ),
      replayed: false,
    ),
    acknowledgedAt: acknowledgedAt.toUtc(),
  );
}

void main() {
  late local.AppDatabase db;
  late String activeOwner;
  late DriftEmailCandidateConfirmationGateway gateway;

  setUp(() async {
    db = local.AppDatabase(NativeDatabase.memory());
    activeOwner = _ownerA;
    gateway = DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => _now,
      authenticatedUserId: () => activeOwner,
    );
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
      courseId: _courseA,
    );
  });

  tearDown(() => db.close());

  test(
    'edited assignment confirms privately with projection, source, reminder policy and exactly one mutation',
    () async {
      final payload = _payload(
        type: EmailCandidateType.assignment,
        title: '編集済みレポート',
        dueAt: DateTime.utc(2026, 7, 30, 8),
        dueAllDay: true,
        dueTimezone: 'Asia/Tokyo',
        submissionUrl: 'https://lms.example.edu/tasks/42',
        summary: '第3章まで',
        reminders: const [1440, 180],
      );
      await _insertCandidate(
        db,
        ownerUserId: _ownerA,
        candidateId: 'assignment-candidate',
        payload: payload,
      );

      expect(await db.select(db.assignments).get(), isEmpty);
      expect(await db.select(db.syncQueueEntries).get(), isEmpty);

      final result = await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'assignment-candidate',
        courseId: _courseA,
      );

      expect(result.entityType, EmailCandidateType.assignment);
      expect(result.replayed, isFalse);
      final assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(result.entityId)))
          .getSingle();
      expect(assignment.ownerUserId, _ownerA);
      expect(assignment.courseId, _courseA);
      expect(assignment.title, '編集済みレポート');
      expect(assignment.description, '第3章まで');
      expect(assignment.submissionUrl, 'https://lms.example.edu/tasks/42');
      expect(assignment.dueAt.toUtc(), DateTime.utc(2026, 7, 30, 8));
      expect(assignment.visibilityLevel, 'PRIVATE');

      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: 'assignment-candidate',
      );
      expect(candidate!.reviewState, 'confirmed');
      expect(candidate.linkedEntityType, 'assignment');
      expect(candidate.linkedEntityId, result.entityId);
      expect(candidate.requiresUserConfirmation, isTrue);

      final link = (await db.select(db.emailScheduleEntityLinks).get()).single;
      expect(link.ownerUserId, _ownerA);
      expect(link.candidateId, 'assignment-candidate');
      expect(link.sourceId, candidate.sourceId);
      expect(link.entityId, result.entityId);

      final request =
          (await db.select(db.notificationScheduleRequests).get()).single;
      expect(request.state, 'pending');
      expect(request.anchorAt.toUtc(), DateTime.utc(2026, 7, 30, 8));
      expect(request.allDay, isTrue);
      expect(request.timezone, 'Asia/Tokyo');
      expect(jsonDecode(request.remindersMinutesJson), [1440, 180]);
      expect(request.targetPath, '/assignment/${result.entityId}/edit');

      final mutations = await db.syncQueueDao.allMutations(_ownerA);
      expect(mutations, hasLength(1));
      final mutation = mutations.single;
      expect(mutation.entityType, 'assignment');
      expect(mutation.entityId, result.entityId);
      expect(mutation.operation, 'create');
      expect(mutation.idempotencyKey, candidate.confirmationIdempotencyKey);
      final reconciliation =
          (await db.select(db.emailReconciliationReceipts).get()).single;
      expect(reconciliation.ownerUserId, _ownerA);
      expect(reconciliation.action, 'confirmation');
      expect(reconciliation.localReferenceId, candidate.id);
      expect(
          reconciliation.reviewedPayloadJson, candidate.normalizedPayloadJson);
      expect(reconciliation.entityType, 'assignment');
      expect(reconciliation.entityId, result.entityId);
      expect(
          reconciliation.idempotencyKey, candidate.confirmationIdempotencyKey);
      expect(reconciliation.requiredSyncMutationId, mutation.clientMutationId);
      expect(reconciliation.providerMessageIdHash, hasLength(64));
      expect(reconciliation.providerThreadIdHash, hasLength(64));
      expect(reconciliation.state, 'pending');
      expect(
        (jsonDecode(mutation.payloadJson) as Map<String, dynamic>).keys.toSet(),
        _assignmentMutationKeys,
      );

      final projection = await DriftScheduleRepository(db).calendarProjection(
        ownerUserId: _ownerA,
        universityId: 'university-a',
        termId: 'term-a',
        rangeStart: DateTime.utc(2026, 7, 29),
        rangeEnd: DateTime.utc(2026, 7, 31),
      );
      expect(
        projection.any(
          (item) =>
              item.sourceId == result.entityId &&
              item.kind == EventKind.assignmentDeadline,
        ),
        isTrue,
      );

      final replay = await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'assignment-candidate',
        courseId: _courseA,
      );
      expect(replay.entityId, result.entityId);
      expect(replay.replayed, isTrue);
      expect(await db.select(db.assignments).get(), hasLength(1));
      expect(
          await db.select(db.emailReconciliationReceipts).get(), hasLength(1));
      expect(await db.select(db.emailScheduleEntityLinks).get(), hasLength(1));
      expect(
        await db.select(db.notificationScheduleRequests).get(),
        hasLength(1),
      );
      expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(1));

      final editedAt = _now.add(const Duration(minutes: 10));
      await DriftScheduleRepository(
        db,
        clock: () => editedAt,
        createId: () => 'ordinary-user-edit-mutation',
      ).updateAssignment(
        assignmentId: result.entityId,
        ownerUserId: _ownerA,
        expectedVersion: 1,
        input: AssignmentInput(
          courseId: null,
          title: 'User-edited title',
          dueAt: DateTime.utc(2026, 8, 1, 8),
          submissionUrl: payload.submissionUrl,
          memo: payload.summary,
        ),
      );
      final replayAfterUserEdit = await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'assignment-candidate',
        courseId: _courseA,
      );
      expect(replayAfterUserEdit.replayed, isTrue);
      expect(replayAfterUserEdit.entityId, result.entityId);
      final editReceipt =
          (await db.select(db.emailScheduleEditReceipts).get()).singleWhere(
        (row) => row.provenance == 'user_edit',
      );
      expect(editReceipt.provenance, 'user_edit');
      expect(editReceipt.mutationId, 'ordinary-user-edit-mutation');
      expect(editReceipt.baseEntityVersion, 1);
      expect(editReceipt.entityVersion, 2);
      expect(editReceipt.payloadFingerprint, hasLength(43));
    },
  );

  test('exam scope survives canonical ACK after a normalized ordinary edit',
      () async {
    const candidateId = 'exam-scope-ack-candidate';
    final startAt = DateTime.utc(2026, 8, 2, 1);
    final endAt = DateTime.utc(2026, 8, 2, 2);
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.exam,
        title: 'Scoped exam origin',
        startAt: startAt,
        endAt: endAt,
        location: 'Room A',
        summary: 'Bring a pencil',
      ),
    );
    final confirmed = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final create = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    expect(create, isNotNull);
    await _ackAppliedMutation(
      db,
      create!,
      acknowledgedAt: _now.add(const Duration(minutes: 2)),
      changeCursor: 1,
    );

    final remoteAt = _now.add(const Duration(minutes: 3));
    await DriftScheduleSyncStore(db, ownerUserId: _ownerA).applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 2,
        hasMore: false,
        changes: [
          ScheduleDeltaChange(
            changeCursor: 2,
            entityType: 'exam',
            entityId: confirmed.entityId,
            operation: ScheduleDeltaOperation.upsert,
            serverVersion: 2,
            payload: {
              'id': confirmed.entityId,
              'ownerUserId': _ownerA,
              'courseId': _courseA,
              'title': 'Scoped exam origin',
              'startAt': startAt.toIso8601String(),
              'endAt': endAt.toIso8601String(),
              'room': 'Room A',
              'scope': 'closed-book',
              'memo': 'Bring a pencil',
              'examType': null,
              'visibilityLevel': 'PRIVATE',
              'updatedAt': remoteAt.toIso8601String(),
              'deletedAt': null,
              'version': 2,
            },
          ),
        ],
      ),
      appliedAt: remoteAt,
    );
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 4)),
      createId: () => 'exam-scope-user-edit',
    ).updateExam(
      examId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 2,
      input: ExamInput(
        courseId: _courseA,
        title: '  Normalized scoped exam  ',
        startAt: startAt.add(const Duration(hours: 1)),
        endAt: endAt.add(const Duration(hours: 1)),
        room: '',
        memo: '',
        examType: '',
      ),
    );
    final update = await queue.claimNext(
      now: _now.add(const Duration(minutes: 5)),
    );
    expect(update, isNotNull);
    expect(update!.operation, SyncOperation.update);
    expect(update.payload['scope'], 'closed-book');
    expect(update.payload['title'], 'Normalized scoped exam');
    expect(update.payload['room'], isNull);
    expect(update.payload['memo'], isNull);
    expect(update.payload['examType'], isNull);
    await _ackAppliedMutation(
      db,
      update,
      acknowledgedAt: _now.add(const Duration(minutes: 6)),
      changeCursor: 3,
    );
    final exam = await (db.select(db.exams)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(exam.scope, 'closed-book');
    expect(exam.title, 'Normalized scoped exam');
    expect(exam.room, isNull);
    expect(exam.memo, isNull);
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
  });

  test(
      'payload IANA timezone overrides the Tokyo university while canonical Event metadata stays Tokyo',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'new-york-assignment-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'New York assignment',
        dueAt: DateTime.utc(2026, 8, 1, 3),
        dueTimezone: 'America/New_York',
        reminders: const [60],
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'new-york-exam-candidate',
      payload: _payload(
        type: EmailCandidateType.exam,
        title: 'New York source exam',
        startAt: DateTime.utc(2026, 8, 2, 12),
        endAt: DateTime.utc(2026, 8, 2, 13),
        dueTimezone: 'America/New_York',
        reminders: const [45],
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'new-york-event-candidate',
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'New York source event',
        startAt: DateTime.utc(2026, 8, 2, 14),
        endAt: DateTime.utc(2026, 8, 2, 15),
        dueTimezone: 'America/New_York',
        reminders: const [30],
      ),
    );

    final assignment = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'new-york-assignment-candidate',
      courseId: _courseA,
    );
    final exam = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'new-york-exam-candidate',
      courseId: _courseA,
    );
    final event = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'new-york-event-candidate',
    );

    for (final candidateId in [
      'new-york-assignment-candidate',
      'new-york-exam-candidate',
      'new-york-event-candidate',
    ]) {
      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      );
      expect(
        const EmailCandidatePayloadCodec()
            .decode(candidate!.normalizedPayloadJson)
            .due
            .timezone,
        'America/New_York',
      );
    }
    final notifications =
        await db.select(db.notificationScheduleRequests).get();
    expect(
      notifications
          .singleWhere((request) => request.entityId == assignment.entityId)
          .timezone,
      'America/New_York',
    );
    expect(
      notifications
          .singleWhere((request) => request.entityId == exam.entityId)
          .timezone,
      'America/New_York',
    );
    expect(
      notifications
          .singleWhere((request) => request.entityId == event.entityId)
          .timezone,
      'America/New_York',
    );
    final eventRow = await (db.select(db.events)
          ..where((row) => row.id.equals(event.entityId)))
        .getSingle();
    expect(eventRow.timezone, JapanTime.timeZone);
    final examRow = await (db.select(db.exams)
          ..where((row) => row.id.equals(exam.entityId)))
        .getSingle();
    expect(examRow.startAt.toUtc(), DateTime.utc(2026, 8, 2, 12));
    expect(examRow.endAt.toUtc(), DateTime.utc(2026, 8, 2, 13));
    final eventMutation = (await db.syncQueueDao.allMutations(_ownerA))
        .singleWhere((mutation) => mutation.entityId == event.entityId);
    expect(
      (jsonDecode(eventMutation.payloadJson)
          as Map<String, dynamic>)['timezone'],
      JapanTime.timeZone,
    );

    final replay = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'new-york-event-candidate',
    );
    expect(replay.replayed, isTrue);
    expect(await db.select(db.events).get(), hasLength(1));
  });

  test(
      'event replay rejects entity, notification and every create mutation value tamper',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'event-replay-integrity-candidate',
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'Replay integrity event',
        startAt: DateTime.utc(2026, 11, 3, 15),
        endAt: DateTime.utc(2026, 11, 3, 16),
        dueTimezone: 'America/New_York',
        reminders: const [60, 15],
      ),
    );
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'event-replay-integrity-candidate',
    );
    final notification =
        (await db.select(db.notificationScheduleRequests).get()).single;
    final mutation = (await db.syncQueueDao.allMutations(_ownerA)).single;
    final event = (await db.select(db.events).get()).single;

    Future<void> expectReplayRejected() => expectLater(
          gateway.confirm(
            ownerUserId: _ownerA,
            candidateId: 'event-replay-integrity-candidate',
          ),
          throwsA(
            isA<EmailReviewActionException>().having(
              (error) => error.category,
              'category',
              EmailErrorCategory.internalError,
            ),
          ),
        );

    await (db.update(db.events)..where((row) => row.id.equals(event.id))).write(
      const local.EventsCompanion(title: Value('Tampered title')),
    );
    await expectReplayRejected();
    await (db.update(db.events)..where((row) => row.id.equals(event.id))).write(
      local.EventsCompanion(title: Value(event.title)),
    );

    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            anchorAt: Value(
              notification.anchorAt.add(const Duration(minutes: 1)),
            ),
          ),
        );
    await expectReplayRejected();
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            anchorAt: Value(notification.anchorAt),
            allDay: const Value(true),
          ),
        );
    await expectReplayRejected();
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            allDay: Value(notification.allDay),
            remindersMinutesJson: const Value('[30]'),
          ),
        );
    await expectReplayRejected();
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            remindersMinutesJson: Value(notification.remindersMinutesJson),
            timezone: const Value('UTC'),
          ),
        );
    await expectReplayRejected();
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            timezone: Value(notification.timezone),
          ),
        );

    final originalMutation =
        Map<String, dynamic>.from(jsonDecode(mutation.payloadJson) as Map);
    final mutationTampers = <String, Object?>{
      'id': 'tampered-id',
      'ownerUserId': _ownerB,
      'calendarId': _calendarB,
      'title': 'Tampered title',
      'kind': EventKind.course.name,
      'startAt': DateTime.utc(2026, 11, 3, 15, 1).toIso8601String(),
      'endAt': DateTime.utc(2026, 11, 3, 16, 1).toIso8601String(),
      'location': 'Tampered room',
      'description': 'Tampered description',
      'rrule': 'FREQ=DAILY',
      'timezone': 'America/New_York',
      'visibilityLevel': 'PUBLIC',
      'updatedAt': _now.add(const Duration(minutes: 1)).toIso8601String(),
      'version': 2,
    };
    for (final tamper in mutationTampers.entries) {
      final tamperedMutation = Map<String, dynamic>.from(originalMutation)
        ..[tamper.key] = tamper.value;
      await (db.update(db.syncQueueEntries)
            ..where(
              (row) => row.clientMutationId.equals(mutation.clientMutationId),
            ))
          .write(
        local.SyncQueueEntriesCompanion(
          payloadJson: Value(jsonEncode(tamperedMutation)),
        ),
      );
      await expectReplayRejected();
    }
  });

  test(
      'coordinated candidate and entity tampering needs durable accepted-update provenance',
      () async {
    const candidateId = 'coordinated-replay-tamper-candidate';
    final original = _payload(
      type: EmailCandidateType.event,
      title: 'Original event',
      startAt: DateTime.utc(2026, 11, 4, 15),
      endAt: DateTime.utc(2026, 11, 4, 16),
      dueTimezone: 'America/New_York',
      reminders: const [30],
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: original,
    );
    final confirmed = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
    );
    final tampered = _payload(
      type: EmailCandidateType.event,
      title: 'Coordinated tamper',
      startAt: original.startAt,
      endAt: original.endAt,
      dueTimezone: original.due.timezone,
      reminders: original.suggestedRemindersMinutes,
    );
    final tamperedAt = _now.add(const Duration(minutes: 5));
    await (db.update(db.emailCandidates)
          ..where((row) => row.id.equals(candidateId)))
        .write(
      local.EmailCandidatesCompanion(
        normalizedPayloadJson: Value(
          const EmailCandidatePayloadCodec().encode(tampered),
        ),
        semanticFingerprint: Value(
          emailCandidateSemanticFingerprint(tampered),
        ),
        updatedAt: Value(tamperedAt),
      ),
    );
    await (db.update(db.events)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .write(
      local.EventsCompanion(
        title: const Value('Coordinated tamper'),
        version: const Value(2),
        updatedAt: Value(tamperedAt),
      ),
    );

    await expectLater(
      gateway.confirm(ownerUserId: _ownerA, candidateId: candidateId),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
    );
  });

  test('confirmation replay requires an error-free processed source', () async {
    const candidateId = 'source-state-replay-candidate';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Source state replay assignment',
        dueAt: DateTime.utc(2026, 11, 5, 10),
      ),
    );
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: candidateId,
    );

    for (final state in const ['pending', 'processing', 'ignored']) {
      await (db.update(db.emailSources)
            ..where((row) => row.id.equals(candidate!.sourceId)))
          .write(
        local.EmailSourcesCompanion(
          processingState: Value(state),
          errorCategory: const Value(null),
          updatedAt: Value(_now.add(const Duration(minutes: 1))),
        ),
      );
      await expectLater(
        gateway.confirm(
          ownerUserId: _ownerA,
          candidateId: candidateId,
          courseId: _courseA,
        ),
        throwsA(
          isA<EmailReviewActionException>().having(
            (error) => error.category,
            'category',
            EmailErrorCategory.internalError,
          ),
        ),
        reason: 'source state $state is not completed provenance',
      );
    }
  });

  test(
      'scrubbed create replay requires remote-applied acknowledgement and survives queue retention',
      () async {
    const candidateId = 'remote-applied-replay-candidate';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Remote applied assignment',
        dueAt: DateTime.utc(2026, 11, 6, 10),
      ),
    );
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final mutation = (await db.syncQueueDao.allMutations(_ownerA)).single;
    await (db.update(db.syncQueueEntries)
          ..where(
            (row) => row.clientMutationId.equals(mutation.clientMutationId),
          ))
        .write(
      const local.SyncQueueEntriesCompanion(baseVersion: Value(1)),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'create replay never accepts an update-style base version',
    );
    await (db.update(db.syncQueueEntries)
          ..where(
            (row) => row.clientMutationId.equals(mutation.clientMutationId),
          ))
        .write(
      const local.SyncQueueEntriesCompanion(baseVersion: Value(null)),
    );
    await (db.update(db.syncQueueEntries)
          ..where(
            (row) => row.clientMutationId.equals(mutation.clientMutationId),
          ))
        .write(
      const local.SyncQueueEntriesCompanion(payloadJson: Value('{}')),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
    );
    await (db.update(db.syncQueueEntries)
          ..where(
            (row) => row.clientMutationId.equals(mutation.clientMutationId),
          ))
        .write(
      local.SyncQueueEntriesCompanion(
        payloadJson: Value(mutation.payloadJson),
      ),
    );

    final acknowledgedAt = _now.add(const Duration(minutes: 2));
    final claimed = await db.syncQueueDao.claimNext(_ownerA, _now);
    expect(claimed, isNotNull);
    expect(
      await db.syncQueueDao.markSynced(
        _ownerA,
        mutation.clientMutationId,
        acknowledgedAt,
        attemptCount: claimed!.attemptCount,
        serverVersion: 1,
      ),
      isTrue,
    );
    var receipt =
        (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(receipt.scheduleAckedAt?.toUtc(), acknowledgedAt);
    expect(
      (await db.select(db.syncQueueEntries).get()).single.completionProvenance,
      local.scheduleSyncCompletionRemoteApplied,
    );
    await db.update(db.syncQueueEntries).write(
          local.SyncQueueEntriesCompanion(
            payloadJson: Value(mutation.payloadJson),
          ),
        );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'a terminal create must already be scrubbed',
    );
    await db.update(db.syncQueueEntries).write(
          const local.SyncQueueEntriesCompanion(payloadJson: Value('{}')),
        );
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );

    await db.delete(db.syncQueueEntries).go();
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
    receipt = (await db.select(db.emailReconciliationReceipts).get()).single;
    expect(receipt.scheduleAckedAt?.toUtc(), acknowledgedAt);
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
    await db.update(db.assignments).write(
          const local.AssignmentsCompanion(priority: Value('high')),
        );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'the v1 envelope covers nullable/default-only fields',
    );
    await db.update(db.assignments).write(
          const local.AssignmentsCompanion(priority: Value(null)),
        );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: null,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
      reason: 'the original requested container survives outbox pruning',
    );
    final assignment = (await db.select(db.assignments).get()).single;
    await (db.update(db.assignments)
          ..where((row) => row.id.equals(assignment.id)))
        .write(
      const local.AssignmentsCompanion(courseId: Value(null)),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
      reason: 'queue pruning cannot hide canonical container tampering',
    );
  });

  test('pruned Event replay authenticates its actual calendar container',
      () async {
    const candidateId = 'pruned-event-container-candidate';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'Calendar-bound event',
        startAt: DateTime.utc(2026, 11, 7, 10),
        endAt: DateTime.utc(2026, 11, 7, 11),
      ),
    );
    final confirmed = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
    );
    final mutation = (await db.syncQueueDao.allMutations(_ownerA)).single;
    final claimed = await db.syncQueueDao.claimNext(_ownerA, _now);
    expect(claimed, isNotNull);
    expect(
      await db.syncQueueDao.markSynced(
        _ownerA,
        mutation.clientMutationId,
        _now.add(const Duration(minutes: 1)),
        attemptCount: claimed!.attemptCount,
        serverVersion: 1,
      ),
      isTrue,
    );
    await db.delete(db.syncQueueEntries).go();
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      ))
          .replayed,
      isTrue,
    );

    await db.into(db.calendars).insert(
          local.CalendarsCompanion.insert(
            id: _calendarB,
            ownerUserId: _ownerA,
            name: 'Other calendar',
            defaultVisibility: const Value('PRIVATE'),
            updatedAt: Value(_now),
          ),
        );
    await (db.update(db.events)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .write(
      const local.EventsCompanion(calendarId: Value(_calendarB)),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
      reason: 'the key must be recomputed from the actual Event calendar',
    );
  });

  test(
      'email Event accepts timed transport but rejects group canonical data at remote and server-wins boundaries',
      () async {
    const candidateId = 'personal-event-protocol-candidate';
    final startAt = DateTime.utc(2026, 11, 8, 10);
    final endAt = startAt.add(const Duration(hours: 1));
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'Personal email event',
        startAt: startAt,
        endAt: endAt,
      ),
    );
    final confirmed = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final create = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    expect(create, isNotNull);
    await _ackAppliedMutation(
      db,
      create!,
      acknowledgedAt: _now.add(const Duration(minutes: 2)),
      changeCursor: 1,
    );
    var event = (await db.select(db.events).get()).single;
    expect(event.groupId, isNull);
    expect(event.version, 1);

    final canonicalAt = _now.add(const Duration(minutes: 3));
    final groupPayload = <String, Object?>{
      'id': confirmed.entityId,
      'ownerUserId': _ownerA,
      'calendarId': _calendarA,
      'groupId': 'forbidden-group',
      'title': 'Forbidden group canonical',
      'kind': EventKind.normal.name,
      'startAt': startAt.toIso8601String(),
      'endAt': endAt.toIso8601String(),
      'location': null,
      'description': null,
      'rrule': null,
      'timezone': japanTimeZone,
      'visibilityLevel': 'PRIVATE',
      'isAllDay': false,
      'updatedAt': canonicalAt.toIso8601String(),
      'deletedAt': null,
      'version': 2,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [
            ScheduleDeltaChange(
              changeCursor: 1,
              entityType: 'event',
              entityId: confirmed.entityId,
              operation: ScheduleDeltaOperation.upsert,
              serverVersion: 2,
              payload: groupPayload,
            ),
          ],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
    expect(await store.cursor(), 0);
    event = (await db.select(db.events).get()).single;
    expect(event.groupId, isNull);
    expect(event.version, 1);
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 0,
          nextCursor: 1,
          hasMore: false,
          changes: [
            ScheduleDeltaChange(
              changeCursor: 1,
              entityType: 'event',
              entityId: confirmed.entityId,
              operation: ScheduleDeltaOperation.upsert,
              serverVersion: 2,
              payload: {
                ...groupPayload,
                'groupId': null,
                'isAllDay': true,
              },
            ),
          ],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
      reason: 'email Events must stay timed at the transport boundary',
    );
    expect(await store.cursor(), 0);

    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 4)),
      createId: () => 'personal-event-local-edit',
    ).updateEvent(
      eventId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: EventInput(
        calendarId: _calendarA,
        title: 'Local personal edit',
        startAt: startAt,
        endAt: endAt,
      ),
    );
    final edit = await queue.claimNext(
      now: _now.add(const Duration(minutes: 5)),
    );
    expect(edit?.clientMutationId, 'personal-event-local-edit');
    expect(
      await db.syncQueueDao.markConflict(
        _ownerA,
        edit!.clientMutationId,
        'Forbidden group conflict',
        attemptCount: edit.attemptCount,
        serverVersion: 2,
        serverPayloadJson: jsonEncode(groupPayload),
        conflictCursor: 2,
      ),
      isTrue,
    );
    await expectLater(
      store.resolveConflictServerWins(edit.clientMutationId),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
    event = (await db.select(db.events).get()).single;
    expect(event.groupId, isNull);
    expect(event.title, 'Local personal edit');
    expect(event.version, 2);
  });

  test('full create payload remains replayable in durable conflict state',
      () async {
    const candidateId = 'create-conflict-replay-candidate';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Create conflict assignment',
        dueAt: DateTime.utc(2026, 11, 8, 10),
      ),
    );
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final mutation = (await db.syncQueueDao.allMutations(_ownerA)).single;
    final claimed = await db.syncQueueDao.claimNext(_ownerA, _now);
    expect(claimed, isNotNull);
    final serverPayload =
        Map<String, Object?>.from(jsonDecode(mutation.payloadJson) as Map)
          ..['version'] = 2
          ..['updatedAt'] =
              _now.add(const Duration(minutes: 1)).toIso8601String();
    expect(
      await db.syncQueueDao.markConflict(
        _ownerA,
        mutation.clientMutationId,
        'Create conflict',
        attemptCount: claimed!.attemptCount,
        serverVersion: 2,
        serverPayloadJson: jsonEncode(serverPayload),
        conflictCursor: 8,
      ),
      isTrue,
    );
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
    expect(
      (await db.syncQueueDao.allMutations(_ownerA)).single.status,
      'conflict',
    );
  });

  test('standalone and explicitly linked exams each use one private mutation',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'standalone-exam-candidate',
      payload: _payload(
        type: EmailCandidateType.exam,
        title: 'TOEIC',
        startAt: DateTime.utc(2026, 8, 1, 1),
        endAt: DateTime.utc(2026, 8, 1, 3),
        location: '試験会場A',
        summary: '受験票を持参',
        reminders: const [10080, 1440],
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'linked-exam-candidate',
      payload: _payload(
        type: EmailCandidateType.exam,
        title: '情報工学 中間試験',
        startAt: DateTime.utc(2026, 8, 2, 1),
        endAt: DateTime.utc(2026, 8, 2, 2),
        location: 'B201',
        reminders: const [1440],
      ),
    );

    final standalone = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'standalone-exam-candidate',
    );
    final linked = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'linked-exam-candidate',
      courseId: _courseA,
    );

    final exams = await db.select(db.exams).get();
    expect(exams, hasLength(2));
    expect(
      exams.singleWhere((row) => row.id == standalone.entityId).courseId,
      isNull,
    );
    final linkedExam = exams.singleWhere((row) => row.id == linked.entityId);
    expect(linkedExam.courseId, _courseA);
    expect(linkedExam.room, 'B201');
    expect(linkedExam.visibilityLevel, 'PRIVATE');
    expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(2));
    expect(await db.select(db.emailScheduleEntityLinks).get(), hasLength(2));
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(2),
    );

    final projection = await DriftScheduleRepository(db).calendarProjection(
      ownerUserId: _ownerA,
      universityId: 'university-a',
      termId: 'term-a',
      rangeStart: DateTime.utc(2026, 8, 1),
      rangeEnd: DateTime.utc(2026, 8, 3),
    );
    expect(
      projection.where((item) => item.kind == EventKind.exam),
      hasLength(2),
    );
  });

  test('personal event uses the authenticated primary calendar and projection',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'event-candidate',
      payload: _payload(
        type: EmailCandidateType.event,
        title: '研究室見学',
        startAt: DateTime.utc(2026, 8, 5, 4),
        endAt: DateTime.utc(2026, 8, 5, 5, 30),
        location: '研究棟3階',
        summary: '受付で学生証を提示',
        reminders: const [60],
      ),
    );

    final result = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'event-candidate',
    );

    final event = await (db.select(db.events)
          ..where((row) => row.id.equals(result.entityId)))
        .getSingle();
    expect(event.calendarId, _calendarA);
    expect(event.ownerUserId, _ownerA);
    expect(event.kind, EventKind.normal.name);
    expect(event.location, '研究棟3階');
    expect(event.description, '受付で学生証を提示');
    expect(event.timezone, japanTimeZone);
    expect(event.visibilityLevel, 'PRIVATE');

    final mutation = (await db.syncQueueDao.allMutations(_ownerA)).single;
    expect(
      (jsonDecode(mutation.payloadJson) as Map<String, dynamic>).keys.toSet(),
      _eventMutationKeys,
    );
    final request =
        (await db.select(db.notificationScheduleRequests).get()).single;
    expect(request.anchorAt.toUtc(), DateTime.utc(2026, 8, 5, 4));
    expect(request.allDay, isFalse);
    expect(request.timezone, japanTimeZone);

    final projection = await DriftScheduleRepository(db).calendarProjection(
      ownerUserId: _ownerA,
      universityId: 'university-a',
      termId: 'term-a',
      rangeStart: DateTime.utc(2026, 8, 5),
      rangeEnd: DateTime.utc(2026, 8, 6),
    );
    expect(
      projection.any(
        (item) =>
            item.sourceId == result.entityId && item.kind == EventKind.normal,
      ),
      isTrue,
    );
  });

  test('forced outbox failure after entity insert rolls back every artifact',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'rollback-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Rollback assignment',
        dueAt: DateTime.utc(2026, 8, 10),
      ),
    );
    await db.customStatement('''
      CREATE TRIGGER force_confirmation_outbox_failure
      BEFORE INSERT ON sync_queue_entries
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'forced outbox failure');
      END
    ''');

    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'rollback-candidate',
      ),
      throwsA(anything),
    );

    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: 'rollback-candidate',
    );
    expect(candidate!.reviewState, 'ready_for_review');
    expect(candidate.linkedEntityId, isNull);

    await db.customStatement('DROP TRIGGER force_confirmation_outbox_failure');
    final retry = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'rollback-candidate',
    );
    expect(retry.replayed, isFalse);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
  });

  test(
      'fractional confirmation and canonical ACK survive restart without duplication',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-confirmation-restart-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'restart-candidate',
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'Restart event',
        startAt: DateTime.utc(2026, 8, 12, 1, 0, 0, 123),
        endAt: DateTime.utc(2026, 8, 12, 2, 0, 0, 456),
      ),
    );
    final confirmedAt = _now.add(const Duration(milliseconds: 321));
    gateway = DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => confirmedAt,
      authenticatedUserId: () => activeOwner,
    );
    final first = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'restart-candidate',
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase(file));
    gateway = _gateway(db, () => activeOwner);
    final replay = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'restart-candidate',
    );

    expect(replay.replayed, isTrue);
    expect(replay.entityId, first.entityId);
    expect(await db.select(db.events).get(), hasLength(1));
    expect(await db.select(db.emailScheduleEntityLinks).get(), hasLength(1));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(1));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));

    final eventBeforeAck = (await db.select(db.events).get()).single;
    expect(
      eventBeforeAck.startAt.toUtc(),
      emailScheduleSqliteTimestamp(
        DateTime.utc(2026, 8, 12, 1, 0, 0, 123),
      ),
    );
    expect(
      eventBeforeAck.updatedAt.toUtc(),
      emailScheduleSqliteTimestamp(confirmedAt),
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final mutation = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    expect(mutation, isNotNull);
    final acknowledgedAt =
        _now.add(const Duration(minutes: 2, milliseconds: 789));
    await _ackAppliedMutation(
      db,
      mutation!,
      acknowledgedAt: acknowledgedAt,
      changeCursor: 1,
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase(file));
    gateway = _gateway(db, () => activeOwner);
    final replayAfterAck = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'restart-candidate',
    );
    expect(replayAfterAck.replayed, isTrue);
    expect(replayAfterAck.entityId, first.entityId);
    final eventAfterAck = (await db.select(db.events).get()).single;
    expect(
      eventAfterAck.updatedAt.toUtc(),
      emailScheduleSqliteTimestamp(acknowledgedAt),
    );
    final remoteAck = (await db.select(db.emailScheduleEditReceipts).get())
        .singleWhere((row) => row.provenance == 'remote_ack');
    expect(
      remoteAck.entityUpdatedAt.toUtc(),
      emailScheduleSqliteTimestamp(acknowledgedAt),
    );
    expect(
      remoteAck.createdAt.toUtc(),
      emailScheduleSqliteTimestamp(acknowledgedAt),
    );
    expect(await db.select(db.events).get(), hasLength(1));
    expect(await db.select(db.emailScheduleEntityLinks).get(), hasLength(1));
    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test('retained v14 pending legacy confirmation key replays exactly',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-confirmation-legacy-v14-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
      courseId: _courseA,
    );
    const candidateId = 'legacy-retained-candidate';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Legacy retained assignment',
        dueAt: DateTime.utc(2026, 8, 13, 8, 0, 0, 123),
      ),
    );
    final legacyConfirmedAt = _now.add(const Duration(milliseconds: 321));
    gateway = DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => legacyConfirmedAt,
      authenticatedUserId: () => activeOwner,
    );
    final first = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final legacyKey = const Uuid().v5(
      Namespace.url.value,
      'email-confirmation\u0000$_ownerA\u0000$candidateId',
    );
    final originalMutation =
        (await db.syncQueueDao.allMutations(_ownerA)).single;
    expect(originalMutation.status, 'pending');
    expect(originalMutation.payloadJson, isNot('{}'));

    await db.customStatement(
      'DROP TRIGGER email_schedule_links_immutable',
    );
    await db.customStatement(
      'DROP TRIGGER notification_requests_guard_update',
    );
    await db.customStatement(
      'DROP TRIGGER email_reconciliation_values_guard_update',
    );
    await (db.update(db.emailCandidates)
          ..where((row) => row.id.equals(candidateId)))
        .write(
      local.EmailCandidatesCompanion(
        confirmationIdempotencyKey: Value(legacyKey),
      ),
    );
    await db.update(db.emailScheduleEntityLinks).write(
          local.EmailScheduleEntityLinksCompanion(
            confirmationIdempotencyKey: Value(legacyKey),
          ),
        );
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            idempotencyKey: Value(legacyKey),
          ),
        );
    await db.update(db.syncQueueEntries).write(
          local.SyncQueueEntriesCompanion(
            idempotencyKey: Value(legacyKey),
          ),
        );
    await db.update(db.emailReconciliationReceipts).write(
          local.EmailReconciliationReceiptsCompanion(
            idempotencyKey: Value(legacyKey),
          ),
        );
    await db.customStatement('DROP TABLE email_schedule_edit_receipts');
    await db.customStatement('PRAGMA user_version = 14');
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    gateway = _gateway(db, () => activeOwner);
    final replay = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    expect(replay.replayed, isTrue);
    expect(replay.entityId, first.entityId);
    final retainedMutation =
        (await db.syncQueueDao.allMutations(_ownerA)).single;
    expect(retainedMutation.status, 'pending');
    expect(retainedMutation.idempotencyKey, legacyKey);
    expect(retainedMutation.payloadJson, originalMutation.payloadJson);
    expect(
      (await db.select(db.emailCandidates).get())
          .single
          .confirmationIdempotencyKey,
      legacyKey,
    );
    final migratedReceipts =
        await db.select(db.emailScheduleEditReceipts).get();
    expect(migratedReceipts, hasLength(1));
    expect(migratedReceipts.single.provenance, 'confirmation');
    expect(
      migratedReceipts.single.entityUpdatedAt.toUtc(),
      emailScheduleSqliteTimestamp(legacyConfirmedAt),
    );
    expect(
      (await db.select(db.assignments).get()).single.dueAt.toUtc(),
      emailScheduleSqliteTimestamp(
        DateTime.utc(2026, 8, 13, 8, 0, 0, 123),
      ),
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final claimed = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    expect(claimed, isNotNull);
    await _ackAppliedMutation(
      db,
      claimed!,
      acknowledgedAt: _now.add(const Duration(minutes: 2, milliseconds: 789)),
      changeCursor: 1,
    );
    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    await db.close();
    db = local.AppDatabase(NativeDatabase(file));
    gateway = _gateway(db, () => activeOwner);
    expect(
      (await gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
      reason: 'legacy replay still authenticates its original course',
    );
    await db.update(db.assignments).write(
          const local.AssignmentsCompanion(courseId: Value(null)),
        );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
      reason: 'legacy create payload authenticates the actual entity course',
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test(
      'retained v14 reconciled scrubbed create migrates a container-bound v1 chain after pruning',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-confirmation-synced-v14-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
      courseId: _courseA,
    );
    const candidateId = 'retained-synced-v1-candidate';
    final dueAt = DateTime.utc(2026, 8, 14, 8);
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Legacy acknowledged assignment',
        dueAt: dueAt,
      ),
    );
    gateway = _gateway(db, () => activeOwner);
    final first = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final confirmationKey = (await db.select(db.emailCandidates).get())
        .single
        .confirmationIdempotencyKey;
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final claimed = await queue.claimNext(
      now: _now.add(const Duration(milliseconds: 100)),
    );
    expect(claimed, isNotNull);
    final acknowledgedAt = _now.add(const Duration(milliseconds: 789));
    await _ackAppliedMutation(
      db,
      claimed!,
      acknowledgedAt: acknowledgedAt,
      changeCursor: 1,
    );
    final scrubbed = (await db.syncQueueDao.allMutations(_ownerA)).single;
    expect(scrubbed.status, 'synced');
    expect(scrubbed.payloadJson, '{}');
    expect(scrubbed.serverVersion, 1);
    expect(
      scrubbed.completionProvenance,
      local.scheduleSyncCompletionRemoteApplied,
    );
    expect(
      scrubbed.syncedAt?.toUtc(),
      emailScheduleSqliteTimestamp(acknowledgedAt),
    );
    expect(
      (await db.select(db.emailReconciliationReceipts).get())
          .single
          .scheduleAckedAt
          ?.toUtc(),
      emailScheduleSqliteTimestamp(acknowledgedAt),
    );
    final reconciledAt = acknowledgedAt.add(const Duration(minutes: 1));
    await db.update(db.emailReconciliationReceipts).write(
          local.EmailReconciliationReceiptsCompanion(
            state: const Value('succeeded'),
            attemptCount: const Value(1),
            nextRetryAt: const Value(null),
            lastAttemptAt: Value(reconciledAt),
            reconciledAt: Value(reconciledAt),
            replayed: const Value(false),
            errorCategory: const Value(null),
            updatedAt: Value(reconciledAt),
          ),
        );
    await db.customStatement(
      'DROP TRIGGER notification_requests_guard_update',
    );
    await db.update(db.notificationScheduleRequests).write(
          local.NotificationScheduleRequestsCompanion(
            updatedAt: Value(_now),
          ),
        );
    await db.customStatement('DROP TABLE email_schedule_edit_receipts');
    await db.customStatement('PRAGMA user_version = 14');
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    final migrated = await db.select(db.emailScheduleEditReceipts).get();
    expect(migrated.map((row) => row.provenance).toSet(), {
      'confirmation',
      'remote_ack',
    });
    expect(
      migrated
          .singleWhere((row) => row.provenance == 'confirmation')
          .mutationId,
      scrubbed.clientMutationId,
    );
    expect(
      migrated.singleWhere((row) => row.provenance == 'remote_ack').mutationId,
      'remote-ack:${scrubbed.clientMutationId}',
    );
    final migratedConfirmation = migrated.singleWhere(
      (row) => row.provenance == 'confirmation',
    );
    final migratedRemoteAck = migrated.singleWhere(
      (row) => row.provenance == 'remote_ack',
    );
    expect(migratedRemoteAck.entityVersion, migratedConfirmation.entityVersion);
    expect(
      migratedRemoteAck.payloadFingerprint,
      migratedConfirmation.payloadFingerprint,
      reason: 'same-second scrubbed ACK is an authenticated no-op edge',
    );
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 2)),
      createId: () => 'post-scrubbed-noop-edit',
    ).updateAssignment(
      assignmentId: first.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Edited after same-second scrubbed ACK',
        dueAt: dueAt.add(const Duration(days: 1)),
      ),
    );
    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    await db.close();
    db = local.AppDatabase(NativeDatabase(file));
    gateway = _gateway(db, () => activeOwner);
    final replay = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    expect(replay.replayed, isTrue);
    expect(replay.entityId, first.entityId);
    final edited = (await db.select(db.assignments).get()).single;
    expect(edited.version, 2);
    expect(edited.title, 'Edited after same-second scrubbed ACK');
    await db.customStatement(
      'DROP TRIGGER email_schedule_edit_receipts_guard_insert',
    );
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId: 'ambiguous-non-noop-remote-ack',
            ownerUserId: migratedRemoteAck.ownerUserId,
            candidateId: migratedRemoteAck.candidateId,
            linkId: migratedRemoteAck.linkId,
            entityType: migratedRemoteAck.entityType,
            entityId: migratedRemoteAck.entityId,
            provenance: 'remote_ack',
            baseEntityVersion: migratedRemoteAck.baseEntityVersion,
            entityVersion: migratedRemoteAck.entityVersion,
            basePayloadFingerprint: migratedRemoteAck.basePayloadFingerprint,
            payloadFingerprint: migratedRemoteAck.payloadFingerprint,
            candidatePayloadFingerprint:
                migratedRemoteAck.candidatePayloadFingerprint,
            entityUpdatedAt: migratedRemoteAck.entityUpdatedAt
                .add(const Duration(seconds: 1)),
            createdAt: migratedRemoteAck.createdAt,
          ),
        );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'a non-identical remote ACK cannot resolve tuple ambiguity',
    );
    await (db.delete(db.emailScheduleEditReceipts)
          ..where(
              (row) => row.mutationId.equals('ambiguous-non-noop-remote-ack')))
        .go();
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'the migrated root remains bound to its original course',
    );
    expect(
      (await db.select(db.emailCandidates).get())
          .single
          .confirmationIdempotencyKey,
      confirmationKey,
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test(
      'retained v14 scrubbed v1 create rejects a current assignment container mismatch',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-confirmation-synced-v14-container-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
      courseId: _courseA,
    );
    const candidateId = 'retained-synced-wrong-container';
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Container-bound assignment',
        dueAt: DateTime.utc(2026, 8, 15, 8),
      ),
    );
    gateway = _gateway(db, () => activeOwner);
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final claimed = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    await _ackAppliedMutation(
      db,
      claimed!,
      acknowledgedAt: _now.add(const Duration(minutes: 2)),
      changeCursor: 1,
    );
    await db.update(db.assignments).write(
          const local.AssignmentsCompanion(courseId: Value(null)),
        );
    await db.customStatement('DROP TABLE email_schedule_edit_receipts');
    await db.customStatement('PRAGMA user_version = 14');
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    expect(await db.select(db.emailScheduleEditReceipts).get(), isEmpty);
    gateway = _gateway(db, () => activeOwner);
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test('retained v14 scrubbed create cannot mint a root for a v2 entity',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-confirmation-synced-v14-v2-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerA,
      calendarId: _calendarA,
      courseId: _courseA,
    );
    const candidateId = 'legacy-synced-v2-candidate';
    final payload = _payload(
      type: EmailCandidateType.assignment,
      title: 'Legacy version two assignment',
      dueAt: DateTime.utc(2026, 8, 15, 8),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: candidateId,
      payload: payload,
    );
    gateway = _gateway(db, () => activeOwner);
    final first = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: candidateId,
      courseId: _courseA,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final claimed = await queue.claimNext(
      now: _now.add(const Duration(minutes: 1)),
    );
    await _ackAppliedMutation(
      db,
      claimed!,
      acknowledgedAt: _now.add(const Duration(minutes: 2)),
      changeCursor: 1,
    );
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 3)),
      createId: () => 'legacy-v2-edit',
    ).updateAssignment(
      assignmentId: first.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Legacy version two assignment edited',
        dueAt: payload.due.at!.add(const Duration(days: 1)),
      ),
    );
    await db.customStatement('DROP TABLE email_schedule_edit_receipts');
    await db.customStatement('PRAGMA user_version = 14');
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    expect(await db.select(db.emailScheduleEditReceipts).get(), isEmpty);
    gateway = _gateway(db, () => activeOwner);
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: candidateId,
        courseId: _courseA,
      ),
      throwsA(isA<EmailReviewActionException>()),
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test('derived email deletion removes provenance but keeps confirmed schedule',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'disconnect-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Keep after disconnect',
        dueAt: DateTime.utc(2026, 8, 12),
        reminders: const [60],
      ),
    );
    final result = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'disconnect-candidate',
    );

    expect(
      await db.emailImportDao.deleteDerivedDataForConnection(
        ownerUserId: _ownerA,
        connectionId: 'connection-disconnect-candidate',
      ),
      1,
    );

    expect(
      await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: 'disconnect-candidate',
      ),
      isNull,
    );
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(result.entityId)))
        .getSingleOrNull();
    expect(assignment, isNotNull);
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(1),
    );
    expect(
      await db.update(db.notificationScheduleRequests).write(
            local.NotificationScheduleRequestsCompanion(
              state: const Value('scheduled'),
              updatedAt: Value(_now.add(const Duration(minutes: 10))),
            ),
          ),
      1,
      reason: 'retained notification work remains actionable after cleanup',
    );
    expect(
      (await db.select(db.notificationScheduleRequests).get()).single.state,
      'scheduled',
    );
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
  });

  test('mismatched replay artifacts are rejected rather than recreated',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'mismatch-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Mismatch task',
        dueAt: DateTime.utc(2026, 8, 14),
      ),
    );
    await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'mismatch-candidate',
    );
    final committedLink =
        (await db.select(db.emailScheduleEntityLinks).get()).single;
    await db.delete(db.emailScheduleEntityLinks).go();

    await expectLater(
      db.into(db.emailScheduleEntityLinks).insert(
            local.EmailScheduleEntityLinksCompanion.insert(
              id: 'forged-owner-link',
              ownerUserId: _ownerB,
              sourceId: committedLink.sourceId,
              candidateId: committedLink.candidateId,
              entityType: committedLink.entityType,
              entityId: committedLink.entityId,
              confirmationIdempotencyKey:
                  committedLink.confirmationIdempotencyKey,
            ),
          ),
      throwsA(anything),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'other-source-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Other source',
        dueAt: DateTime.utc(2026, 8, 15),
      ),
    );
    await expectLater(
      db.into(db.emailScheduleEntityLinks).insert(
            local.EmailScheduleEntityLinksCompanion.insert(
              id: 'forged-source-link',
              ownerUserId: _ownerA,
              sourceId: 'source-other-source-candidate',
              candidateId: committedLink.candidateId,
              entityType: committedLink.entityType,
              entityId: committedLink.entityId,
              confirmationIdempotencyKey:
                  committedLink.confirmationIdempotencyKey,
            ),
          ),
      throwsA(anything),
    );

    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'mismatch-candidate',
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.internalError,
        ),
      ),
    );
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
  });

  test(
      'unsupported, dismissed, unsafe URL and invalid timezone stay review-only',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'announcement-candidate',
      payload: _payload(
        type: EmailCandidateType.announcement,
        title: 'お知らせ',
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'unknown-candidate',
      payload: _payload(type: EmailCandidateType.unknown, title: 'Unknown'),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'dismissed-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Dismissed',
        dueAt: DateTime.utc(2026, 8, 15),
      ),
      reviewState: EmailCandidateReviewState.dismissed,
    );
    final validJson = const EmailCandidatePayloadCodec().encode(
      _payload(
        type: EmailCandidateType.assignment,
        title: 'Unsafe',
        dueAt: DateTime.utc(2026, 8, 16),
        dueTimezone: 'Asia/Tokyo',
        submissionUrl: 'https://safe.example.edu/task',
      ),
    );
    await _insertCandidateJson(
      db,
      ownerUserId: _ownerA,
      candidateId: 'unsafe-url-candidate',
      candidateType: EmailCandidateType.assignment,
      normalizedPayloadJson: validJson.replaceFirst(
        'https://safe.example.edu/task',
        'http://unsafe.example.edu/task',
      ),
    );
    await _insertCandidateJson(
      db,
      ownerUserId: _ownerA,
      candidateId: 'invalid-timezone-candidate',
      candidateType: EmailCandidateType.assignment,
      normalizedPayloadJson: validJson.replaceFirst(
        'Asia/Tokyo',
        'Mars/Olympus',
      ),
    );

    for (final candidateId in [
      'announcement-candidate',
      'unknown-candidate',
      'dismissed-candidate',
      'unsafe-url-candidate',
      'invalid-timezone-candidate',
    ]) {
      await expectLater(
        gateway.confirm(ownerUserId: _ownerA, candidateId: candidateId),
        throwsA(isA<EmailReviewActionException>()),
      );
    }
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.events).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
  });

  test('active account boundary isolates confirmation ownership', () async {
    await _seedScheduleContext(
      db,
      ownerUserId: _ownerB,
      calendarId: _calendarB,
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'owner-a-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Owner A',
        dueAt: DateTime.utc(2026, 8, 18),
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerB,
      candidateId: 'owner-b-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Owner B',
        dueAt: DateTime.utc(2026, 8, 19),
      ),
    );

    expect(
      () => gateway.confirm(
        ownerUserId: _ownerB,
        candidateId: 'owner-b-candidate',
      ),
      throwsA(isA<EmailReviewActionException>()),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'owner-b-candidate',
      ),
      throwsA(isA<EmailReviewActionException>()),
    );
    expect(await db.select(db.assignments).get(), isEmpty);

    activeOwner = _ownerB;
    final result = await gateway.confirm(
      ownerUserId: _ownerB,
      candidateId: 'owner-b-candidate',
    );
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(result.entityId)))
        .getSingle();
    expect(assignment.ownerUserId, _ownerB);
    expect(await db.syncQueueDao.allMutations(_ownerA), isEmpty);
    expect(await db.syncQueueDao.allMutations(_ownerB), hasLength(1));
  });

  test('mid-transaction account switch rolls back every confirmation artifact',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'account-switch-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Account switch',
        dueAt: DateTime.utc(2026, 8, 19),
      ),
    );

    var ownerChecks = 0;
    final switchingGateway = _gateway(db, () {
      ownerChecks += 1;
      // The fourth check runs after the canonical entity, candidate linkage,
      // notification request, and outbox mutation have all been written.
      return ownerChecks < 4 ? _ownerA : _ownerB;
    });

    await expectLater(
      switchingGateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'account-switch-candidate',
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.authorizationRevoked,
        ),
      ),
    );

    expect(ownerChecks, 4);
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: 'account-switch-candidate',
    );
    expect(candidate!.reviewState, 'ready_for_review');
    expect(candidate.linkedEntityType, isNull);
    expect(candidate.linkedEntityId, isNull);
    expect(candidate.confirmationIdempotencyKey, isNull);
    expect(candidate.confirmedAt, isNull);
  });

  test('invalid active-term context blocks confirmation before any writes',
      () async {
    for (final candidateId in [
      'inactive-term-candidate',
      'deleted-term-candidate',
      'cross-owner-term-candidate',
    ]) {
      await _insertCandidate(
        db,
        ownerUserId: _ownerA,
        candidateId: candidateId,
        payload: _payload(
          type: EmailCandidateType.assignment,
          title: candidateId,
          dueAt: DateTime.utc(2026, 8, 20),
        ),
      );
    }

    await (db.update(db.terms)..where((row) => row.id.equals('term-a')))
        .write(const local.TermsCompanion(status: Value('inactive')));
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'inactive-term-candidate',
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );

    await (db.update(db.terms)..where((row) => row.id.equals('term-a'))).write(
      local.TermsCompanion(
        status: const Value('active'),
        deletedAt: Value(_now),
      ),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'deleted-term-candidate',
      ),
      throwsA(isA<EmailReviewActionException>()),
    );

    await _seedScheduleContext(
      db,
      ownerUserId: _ownerB,
      calendarId: _calendarB,
    );
    await (db.update(db.profiles)..where((row) => row.userId.equals(_ownerA)))
        .write(
      const local.ProfilesCompanion(activeTermId: Value('term-b')),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'cross-owner-term-candidate',
      ),
      throwsA(isA<EmailReviewActionException>()),
    );

    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
    for (final candidateId in [
      'inactive-term-candidate',
      'deleted-term-candidate',
      'cross-owner-term-candidate',
    ]) {
      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      );
      expect(candidate!.reviewState, 'ready_for_review');
    }
  });

  test(
      'inactive or deleted cached university blocks while an absent catalog cache remains offline-safe',
      () async {
    for (final candidateId in [
      'inactive-university-candidate',
      'deleted-university-candidate',
      'missing-university-candidate',
    ]) {
      await _insertCandidate(
        db,
        ownerUserId: _ownerA,
        candidateId: candidateId,
        payload: _payload(
          type: EmailCandidateType.assignment,
          title: candidateId,
          dueAt: DateTime.utc(2026, 8, 21),
        ),
      );
    }

    await (db.update(db.universities)
          ..where((row) => row.id.equals('university-a')))
        .write(
      const local.UniversitiesCompanion(status: Value('inactive')),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'inactive-university-candidate',
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );

    await (db.update(db.universities)
          ..where((row) => row.id.equals('university-a')))
        .write(
      local.UniversitiesCompanion(
        status: const Value('active'),
        deletedAt: Value(_now),
      ),
    );
    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'deleted-university-candidate',
      ),
      throwsA(isA<EmailReviewActionException>()),
    );

    await (db.delete(db.universities)
          ..where((row) => row.id.equals('university-a')))
        .go();
    final offlineSafe = await gateway.confirm(
      ownerUserId: _ownerA,
      candidateId: 'missing-university-candidate',
    );

    expect(offlineSafe.entityType, EmailCandidateType.assignment);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.events).get(), isEmpty);
    expect(await db.select(db.emailScheduleEntityLinks).get(), hasLength(1));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(1));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
    for (final candidateId in [
      'inactive-university-candidate',
      'deleted-university-candidate',
      'missing-university-candidate',
    ]) {
      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: candidateId,
      );
      if (candidateId == 'missing-university-candidate') {
        expect(candidate!.reviewState, 'confirmed');
        expect(candidate.linkedEntityId, offlineSafe.entityId);
      } else {
        expect(candidate!.reviewState, 'ready_for_review');
        expect(candidate.linkedEntityId, isNull);
      }
    }
  });

  test('course from a non-active term blocks all confirmation writes',
      () async {
    await db.into(db.terms).insert(
          local.TermsCompanion.insert(
            id: 'term-a-other',
            universityId: 'university-a',
            ownerUserId: const Value(_ownerA),
            name: '2026 Fall',
            academicYear: 2026,
            startDate: DateTime.utc(2026, 10, 1),
            endDate: DateTime.utc(2027, 3, 31),
            termType: 'semester',
            isTemplate: const Value(false),
            status: const Value('active'),
            updatedAt: Value(_now),
          ),
        );
    await db.into(db.userCourses).insert(
          local.UserCoursesCompanion.insert(
            id: 'other-term-course',
            ownerUserId: _ownerA,
            termId: 'term-a-other',
            title: 'Other-term course',
            normalizedTitle: 'other-term course',
            dayOfWeek: const Value(DateTime.tuesday),
            periodNo: const Value(2),
            visibilityLevel: const Value('PRIVATE'),
            updatedAt: Value(_now),
          ),
        );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'other-term-course-candidate',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Wrong term',
        dueAt: DateTime.utc(2026, 8, 22),
      ),
    );

    await expectLater(
      gateway.confirm(
        ownerUserId: _ownerA,
        candidateId: 'other-term-course-candidate',
        courseId: 'other-term-course',
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );

    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.emailScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: 'other-term-course-candidate',
    );
    expect(candidate!.reviewState, 'ready_for_review');
    expect(candidate.linkedEntityId, isNull);
  });

  test('bulk confirmation is atomic per candidate with explicit partial result',
      () async {
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'bulk-assignment',
      payload: _payload(
        type: EmailCandidateType.assignment,
        title: 'Bulk assignment',
        dueAt: DateTime.utc(2026, 8, 20),
      ),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'bulk-unknown',
      payload:
          _payload(type: EmailCandidateType.unknown, title: 'Bulk unknown'),
    );
    await _insertCandidate(
      db,
      ownerUserId: _ownerA,
      candidateId: 'bulk-event',
      payload: _payload(
        type: EmailCandidateType.event,
        title: 'Bulk event',
        startAt: DateTime.utc(2026, 8, 21, 1),
        endAt: DateTime.utc(2026, 8, 21, 2),
      ),
    );

    final result = await gateway.confirmEach(
      ownerUserId: _ownerA,
      candidates: const [
        EmailCandidateConfirmationItem(candidateId: 'bulk-assignment'),
        EmailCandidateConfirmationItem(candidateId: 'bulk-unknown'),
        EmailCandidateConfirmationItem(candidateId: 'bulk-event'),
      ],
    );

    expect(result.hasPartialSuccess, isTrue);
    expect(result.confirmed, hasLength(2));
    expect(result.failed, hasLength(1));
    expect(result.failed.single.candidateId, 'bulk-unknown');
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.events).get(), hasLength(1));
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), hasLength(2));
    final failedCandidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: 'bulk-unknown',
    );
    expect(failedCandidate!.reviewState, 'ready_for_review');
  });
}

DriftEmailCandidateConfirmationGateway _gateway(
  local.AppDatabase database,
  String? Function() authenticatedUserId,
) {
  return DriftEmailCandidateConfirmationGateway(
    db: database,
    clock: () => _now,
    authenticatedUserId: authenticatedUserId,
  );
}

Future<void> _seedScheduleContext(
  local.AppDatabase database, {
  required String ownerUserId,
  required String calendarId,
  String? courseId,
}) async {
  final termId = ownerUserId == _ownerA ? 'term-a' : 'term-b';
  await database.into(database.universities).insert(
        local.UniversitiesCompanion.insert(
          id: 'university-a',
          name: 'Test University',
          normalizedName: 'test university',
          status: const Value('active'),
          updatedAt: Value(_now),
        ),
        mode: InsertMode.insertOrIgnore,
      );
  await database.into(database.terms).insert(
        local.TermsCompanion.insert(
          id: termId,
          universityId: 'university-a',
          ownerUserId: Value(ownerUserId),
          name: '2026 Spring',
          academicYear: 2026,
          startDate: DateTime.utc(2026, 4, 1),
          endDate: DateTime.utc(2026, 9, 30),
          termType: 'semester',
          isTemplate: const Value(false),
          status: const Value('active'),
          updatedAt: Value(_now),
        ),
      );
  await database.into(database.profiles).insert(
        local.ProfilesCompanion.insert(
          userId: ownerUserId,
          displayName: 'Test owner',
          universityId: const Value('university-a'),
          activeTermId: Value(termId),
          primaryCalendarId: Value(calendarId),
          onboardingStatus: const Value('complete'),
          onboardingStep: const Value('complete'),
          onboardingCompletedAt: Value(_now),
          updatedAt: Value(_now),
        ),
      );
  await database.into(database.calendars).insert(
        local.CalendarsCompanion.insert(
          id: calendarId,
          ownerUserId: ownerUserId,
          name: 'Personal',
          defaultVisibility: const Value('PRIVATE'),
          updatedAt: Value(_now),
        ),
      );
  if (courseId != null) {
    await database.into(database.userCourses).insert(
          local.UserCoursesCompanion.insert(
            id: courseId,
            ownerUserId: ownerUserId,
            termId: termId,
            title: '情報工学',
            normalizedTitle: '情報工学',
            dayOfWeek: const Value(DateTime.monday),
            periodNo: const Value(1),
            visibilityLevel: const Value('PRIVATE'),
            updatedAt: Value(_now),
          ),
        );
  }
}

Future<void> _insertCandidate(
  local.AppDatabase database, {
  required String ownerUserId,
  required String candidateId,
  required EmailCandidatePayload payload,
  EmailCandidateReviewState reviewState =
      EmailCandidateReviewState.readyForReview,
}) {
  return _insertCandidateJson(
    database,
    ownerUserId: ownerUserId,
    candidateId: candidateId,
    candidateType: payload.candidateType,
    normalizedPayloadJson: const EmailCandidatePayloadCodec().encode(payload),
    reviewState: reviewState,
  );
}

Future<void> _insertCandidateJson(
  local.AppDatabase database, {
  required String ownerUserId,
  required String candidateId,
  required EmailCandidateType candidateType,
  required String normalizedPayloadJson,
  EmailCandidateReviewState reviewState =
      EmailCandidateReviewState.readyForReview,
}) async {
  final connectionId = 'connection-$candidateId';
  final sourceId = 'source-$candidateId';
  var semanticFingerprint = 'fingerprint-$candidateId';
  try {
    semanticFingerprint = emailCandidateSemanticFingerprint(
      const EmailCandidatePayloadCodec().decode(normalizedPayloadJson),
    );
  } on EmailCandidateValidationException {
    // Invalid payload fixtures must still reach the confirmation validator.
  }
  await database.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: local.EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: ownerUserId,
      provider: 'gmail',
      providerAccountHash: emailProviderIdentifierHash(
        kind: 'account',
        provider: 'gmail',
        providerAccountHash: ownerUserId,
        rawIdentifier: candidateId,
      ),
      state: const Value('connected'),
      updatedAt: Value(_now),
    ),
  );
  await database.emailImportDao.upsertSource(
    ownerUserId: ownerUserId,
    source: local.EmailSourcesCompanion.insert(
      id: sourceId,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerMessageId: 'message-$candidateId',
      providerThreadId: 'thread-$candidateId',
      receivedAt: _now,
      sanitizedContentHash: emailProviderIdentifierHash(
        kind: 'content',
        provider: 'gmail',
        providerAccountHash: ownerUserId,
        rawIdentifier: candidateId,
      ),
      processingState: const Value('processed'),
      updatedAt: Value(_now),
    ),
  );
  await database.emailImportDao.upsertCandidate(
    ownerUserId: ownerUserId,
    candidate: local.EmailCandidatesCompanion.insert(
      id: candidateId,
      ownerUserId: ownerUserId,
      sourceId: sourceId,
      schemaVersion: '1.0',
      candidateType: candidateType.wireName,
      normalizedPayloadJson: normalizedPayloadJson,
      reviewState: Value(reviewState.wireName),
      semanticFingerprint: semanticFingerprint,
      dismissedAt: Value(
        reviewState == EmailCandidateReviewState.dismissed ? _now : null,
      ),
      updatedAt: Value(_now),
    ),
  );
}

EmailCandidatePayload _payload({
  required EmailCandidateType type,
  required String title,
  DateTime? dueAt,
  bool dueAllDay = false,
  String? dueTimezone,
  DateTime? startAt,
  DateTime? endAt,
  String? location,
  String? submissionUrl,
  String? summary,
  List<int> reminders = const [],
}) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: type,
    title: title,
    courseHint: const EmailCourseHint(),
    due: EmailDueCandidate(
      at: dueAt,
      allDay: dueAllDay,
      timezone: dueTimezone,
    ),
    startAt: startAt,
    endAt: endAt,
    location: location,
    submissionUrl: submissionUrl,
    summary: summary,
    suggestedRemindersMinutes: reminders,
    confidence: const EmailCandidateConfidence(
      overall: 1,
      title: 1,
      course: 1,
      dateTime: 1,
    ),
    requiresUserConfirmation: true,
  );
}

const _assignmentMutationKeys = <String>{
  'id',
  'ownerUserId',
  'courseId',
  'title',
  'dueAt',
  'submissionUrl',
  'memo',
  'priority',
  'visibilityLevel',
  'updatedAt',
  'version',
};

const _eventMutationKeys = <String>{
  'id',
  'ownerUserId',
  'calendarId',
  'title',
  'kind',
  'startAt',
  'endAt',
  'location',
  'description',
  'rrule',
  'timezone',
  'visibilityLevel',
  'updatedAt',
  'version',
};
