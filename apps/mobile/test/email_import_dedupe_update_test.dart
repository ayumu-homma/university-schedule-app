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
import 'package:university_schedule_mobile/features/email_import/data/drift_email_review_store.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_confirmation_repository.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_dedupe.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_update_repository.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_sync_service.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_reconciliation_service.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_reconciliation.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:uuid/uuid.dart';

const _ownerA = '11111111-1111-4111-8111-111111111111';
const _ownerB = '99999999-9999-4999-8999-999999999999';
const _connectionA = '22222222-2222-4222-8222-222222222222';
const _connectionB = '88888888-8888-4888-8888-888888888888';
const _calendarA = 'calendar-a';
const _courseA = 'course-a';
final _now = DateTime.utc(2030, 4, 5, 6, 7, 8);

void main() {
  late local.AppDatabase db;
  late String activeOwner;

  setUp(() async {
    db = local.AppDatabase(NativeDatabase.memory());
    activeOwner = _ownerA;
    await _seedScheduleContext(db);
    await _seedConnection(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
  });

  tearDown(() => db.close());

  test(
    'same-thread deadline change survives restart and accepts exactly once',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'email-update-restart-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}schedule.sqlite',
      );
      db = local.AppDatabase(NativeDatabase(file));
      await _seedScheduleContext(db);
      await _seedConnection(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
      );

      final original = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 10, 14, 59),
        summary: 'Original memo',
        reminders: const [1440, 180],
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-original',
          threadId: 'thread-assignment',
          contentHashCharacter: 'a',
          payload: original,
        ),
        cursor: 'cursor-original',
      );
      final candidate = (await db.select(db.emailCandidates).get()).single;
      final confirmation = DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 1)),
        authenticatedUserId: () => activeOwner,
      );
      final confirmed = await confirmation.confirm(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
        courseId: _courseA,
      );
      await DriftScheduleRepository(
        db,
        clock: () => _now.add(const Duration(minutes: 2)),
        createId: () => 'pre-provider-user-edit',
      ).updateAssignment(
        assignmentId: confirmed.entityId,
        ownerUserId: _ownerA,
        expectedVersion: 1,
        input: AssignmentInput(
          courseId: _courseA,
          title: original.title!,
          dueAt: original.due.at!,
          submissionUrl: original.submissionUrl,
          memo: original.summary,
          priority: 'high',
          visibilityLevel: VisibilityLevel.private,
        ),
      );
      await db.update(db.notificationScheduleRequests).write(
            local.NotificationScheduleRequestsCompanion(
              state: const Value('scheduled'),
              updatedAt: Value(_now.add(const Duration(minutes: 2))),
            ),
          );

      final changed = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 12, 14, 59),
        summary: 'Provider changed the deadline',
        reminders: const [60],
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-update',
          threadId: 'thread-assignment',
          contentHashCharacter: 'b',
          payload: changed,
        ),
        cursor: 'cursor-update',
      );
      // Re-fetching the same provider item cannot create another source or
      // another proposal.
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-update',
          threadId: 'thread-assignment',
          contentHashCharacter: 'b',
          payload: changed,
        ),
        cursor: 'cursor-update-replay',
      );

      final proposalBeforeRestart =
          (await db.select(db.emailCandidateUpdates).get()).single;
      expect(proposalBeforeRestart.state, 'pending');
      final diff = jsonDecode(proposalBeforeRestart.fieldDiffJson)
          as Map<String, dynamic>;
      expect(
        diff.keys,
        containsAll(<String>[
          'due_at',
          'summary',
          'suggested_reminders_minutes',
        ]),
      );
      expect(
        (await db.emailImportDao.candidateById(
          ownerUserId: _ownerA,
          candidateId: candidate.id,
        ))
            ?.reviewState,
        'confirmed',
      );
      var assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.dueAt.toUtc(), original.due.at);
      expect(assignment.description, 'Original memo');
      expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(2));

      await db.close();
      db = local.AppDatabase(NativeDatabase(file));
      final repository = DriftEmailCandidateUpdateRepository(
        db: db,
        clock: () => _now.add(const Duration(minutes: 3)),
        authenticatedUserId: () => activeOwner,
      );
      final pending = await repository.pending(ownerUserId: _ownerA);
      expect(pending, hasLength(1));
      expect(pending.single.id, proposalBeforeRestart.id);
      expect(pending.single.entityId, confirmed.entityId);
      expect(pending.single.baseEntityVersion, 2);
      await expectLater(
        repository.pending(ownerUserId: _ownerB),
        throwsA(
          isA<EmailReviewActionException>().having(
            (error) => error.category,
            'category',
            EmailErrorCategory.authorizationRevoked,
          ),
        ),
      );

      final accepted = await repository.accept(
        ownerUserId: _ownerA,
        updateId: pending.single.id,
      );
      expect(accepted.accepted, isTrue);
      expect(accepted.replayed, isFalse);
      assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.dueAt.toUtc(), changed.due.at);
      expect(assignment.description, 'Provider changed the deadline');
      expect(assignment.courseId, _courseA);
      expect(assignment.priority, 'high');
      expect(assignment.visibilityLevel, 'PRIVATE');
      expect(assignment.version, 3);

      final request =
          (await db.select(db.notificationScheduleRequests).get()).single;
      expect(request.anchorAt.toUtc(), changed.due.at);
      expect(jsonDecode(request.remindersMinutesJson), [60]);
      expect(request.state, 'pending');

      final mutations = await db.syncQueueDao.allMutations(_ownerA);
      expect(mutations, hasLength(3));
      final update = mutations.singleWhere(
        (mutation) =>
            mutation.operation == 'update' &&
            mutation.clientMutationId != 'pre-provider-user-edit',
      );
      expect(update.entityId, confirmed.entityId);
      expect(update.baseVersion, 2);
      expect(
        (jsonDecode(update.payloadJson) as Map<String, dynamic>).keys.toSet(),
        _assignmentMutationKeys,
      );
      expect(
        (jsonDecode(update.payloadJson) as Map<String, dynamic>)['version'],
        3,
      );
      final updateReceipt = (await (db.select(db.emailReconciliationReceipts)
                ..where((row) => row.action.equals('update')))
              .get())
          .single;
      expect(updateReceipt.ownerUserId, _ownerA);
      expect(updateReceipt.resolution, 'accepted');
      expect(updateReceipt.entityId, confirmed.entityId);
      expect(updateReceipt.idempotencyKey, update.idempotencyKey);
      expect(updateReceipt.requiredSyncMutationId, update.clientMutationId);
      expect(updateReceipt.reviewedPayloadJson, isNull);
      expect(updateReceipt.providerMessageIdHash, hasLength(64));

      final confirmationReplay = await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 4)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
        courseId: _courseA,
      );
      expect(confirmationReplay.replayed, isTrue);
      expect(confirmationReplay.entityId, confirmed.entityId);
      expect(
        (await db.select(db.assignments).get()).single.priority,
        'high',
      );
      await (db.update(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .write(
        const local.AssignmentsCompanion(
          visibilityLevel: Value('PUBLIC'),
        ),
      );
      await expectLater(
        DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 4)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: candidate.id,
          courseId: _courseA,
        ),
        throwsA(isA<EmailReviewActionException>()),
        reason: 'accepted-update envelope covers preserved fields',
      );
      await (db.update(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .write(
        const local.AssignmentsCompanion(
          visibilityLevel: Value('PRIVATE'),
        ),
      );

      final replay = await repository.accept(
        ownerUserId: _ownerA,
        updateId: pending.single.id,
      );
      expect(replay.replayed, isTrue);
      expect(await db.select(db.assignments).get(), hasLength(1));
      expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(3));

      // Acknowledged outbox rows are pruned after retention. The accepted
      // proposal remains the durable idempotency receipt after that cleanup.
      await (db.delete(db.syncQueueEntries)
            ..where((row) => row.operation.equals('update')))
          .go();
      final replayAfterOutboxRetention = await repository.accept(
        ownerUserId: _ownerA,
        updateId: pending.single.id,
      );
      expect(replayAfterOutboxRetention.replayed, isTrue);
      expect(await db.select(db.assignments).get(), hasLength(1));
      expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(1));

      // A later provider message can legitimately return the candidate from B
      // to its original A payload. Replay must select that latest accepted
      // proposal, not mistake the equal payload for the original confirmation.
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-return-to-original',
          threadId: 'thread-assignment',
          contentHashCharacter: 'c',
          payload: original,
          receivedAt: _now.add(const Duration(minutes: 5)),
        ),
        cursor: 'cursor-return-to-original',
      );
      final returnToOriginal = (await repository.pending(
        ownerUserId: _ownerA,
      ))
          .single;
      await repository.accept(
        ownerUserId: _ownerA,
        updateId: returnToOriginal.id,
      );
      assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.dueAt.toUtc(), original.due.at);
      expect(assignment.description, original.summary);
      expect(assignment.version, 4);
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 6)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: candidate.id,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
      );
      await db.close();
      db = local.AppDatabase(NativeDatabase.memory());
      await directory.delete(recursive: true);
    },
  );

  test(
    'timezone-only Event update is reviewable while canonical metadata stays Tokyo',
    () async {
      final original = _eventPayload(timezone: 'America/New_York');
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'event-original',
          threadId: 'thread-timezone-only-event',
          contentHashCharacter: 'a',
          payload: original,
        ),
        cursor: 'cursor-event-original',
      );
      final candidate = (await db.select(db.emailCandidates).get()).single;
      final confirmed = await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 1)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
      );
      expect((await db.select(db.events).get()).single.timezone, japanTimeZone);
      expect(
        (await db.select(db.notificationScheduleRequests).get())
            .single
            .timezone,
        'America/New_York',
      );

      final changed = _eventPayload(timezone: 'America/Chicago');
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'event-timezone-change',
          threadId: 'thread-timezone-only-event',
          contentHashCharacter: 'b',
          payload: changed,
        ),
        cursor: 'cursor-event-timezone-change',
      );

      final proposal = (await db.select(db.emailCandidateUpdates).get()).single;
      final diff = jsonDecode(proposal.fieldDiffJson) as Map<String, dynamic>;
      expect(diff.keys, ['due_timezone']);
      expect(
        diff['due_timezone'],
        {
          'before': 'America/New_York',
          'after': 'America/Chicago',
        },
      );

      await DriftEmailCandidateUpdateRepository(
        db: db,
        clock: () => _now.add(const Duration(minutes: 3)),
        authenticatedUserId: () => activeOwner,
      ).accept(ownerUserId: _ownerA, updateId: proposal.id);

      final event = (await db.select(db.events).get()).single;
      expect(event.id, confirmed.entityId);
      expect(event.startAt.toUtc(), original.startAt);
      expect(event.endAt.toUtc(), original.endAt);
      expect(event.timezone, japanTimeZone);
      final notification =
          (await db.select(db.notificationScheduleRequests).get()).single;
      expect(notification.anchorAt.toUtc(), original.startAt);
      expect(notification.timezone, 'America/Chicago');
      final updateMutation = (await db.syncQueueDao.allMutations(_ownerA))
          .singleWhere((mutation) => mutation.operation == 'update');
      expect(
        (jsonDecode(updateMutation.payloadJson)
            as Map<String, dynamic>)['timezone'],
        japanTimeZone,
      );
      final confirmationReplay = await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 4)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
      );
      expect(confirmationReplay.replayed, isTrue);
      expect(confirmationReplay.entityId, confirmed.entityId);
    },
  );

  test(
    'non-semantic field change is proposed, reject is durable, and reversion supersedes pending',
    () async {
      final original = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 10, 14, 59),
        summary: 'Original memo',
      );
      final confirmed = await _syncAndConfirm(
        db,
        activeOwner: () => activeOwner,
        payload: original,
      );
      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );

      final memoOnly = _assignmentPayload(
        dueAt: original.due.at!,
        summary: 'Changed memo only',
      );
      expect(
        emailCandidateSemanticFingerprint(memoOnly),
        emailCandidateSemanticFingerprint(original),
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-memo-only',
          threadId: 'thread-assignment',
          contentHashCharacter: 'b',
          payload: memoOnly,
        ),
        cursor: 'cursor-memo',
      );
      var pending = await db.emailImportDao.pendingUpdates(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );
      expect(pending, hasLength(1));
      expect(pending.single.semanticFingerprint,
          isNot(candidate!.semanticFingerprint));
      expect(
        (jsonDecode(pending.single.fieldDiffJson) as Map).keys,
        ['summary'],
      );

      final repository = DriftEmailCandidateUpdateRepository(
        db: db,
        clock: () => _now.add(const Duration(minutes: 3)),
        authenticatedUserId: () => activeOwner,
      );
      final rejected = await repository.reject(
        ownerUserId: _ownerA,
        updateId: pending.single.id,
      );
      expect(rejected.accepted, isFalse);
      expect(rejected.replayed, isFalse);
      expect(
        (await repository.reject(
          ownerUserId: _ownerA,
          updateId: pending.single.id,
        ))
            .replayed,
        isTrue,
      );
      expect(
        (await db.select(db.assignments).get()).single.description,
        'Original memo',
      );
      expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(1));

      final deadlineChange = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 11, 14, 59),
        summary: 'Original memo',
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-deadline',
          threadId: 'thread-assignment',
          contentHashCharacter: 'c',
          payload: deadlineChange,
        ),
        cursor: 'cursor-deadline',
      );
      pending = await db.emailImportDao.pendingUpdates(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );
      expect(pending, hasLength(1));

      // The newest message returning to a previously resolved proposal must
      // still supersede a different active proposal. Otherwise the stale
      // deadline change could remain accept-able after the thread moved on.
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-historical-replay',
          threadId: 'thread-assignment',
          contentHashCharacter: 'd',
          payload: memoOnly,
        ),
        cursor: 'cursor-historical-replay',
      );
      expect(
        await db.emailImportDao.pendingUpdates(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
        ),
        isEmpty,
      );

      final laterDeadlineChange = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 12, 14, 59),
        summary: 'Original memo',
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-later-deadline',
          threadId: 'thread-assignment',
          contentHashCharacter: 'e',
          payload: laterDeadlineChange,
        ),
        cursor: 'cursor-later-deadline',
      );
      expect(
        await db.emailImportDao.pendingUpdates(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
        ),
        hasLength(1),
      );

      // A newest message that returns to the confirmed schedule values
      // cancels the stale pending proposal; the confirmed candidate and entity
      // remain untouched.
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-reversion',
          threadId: 'thread-assignment',
          contentHashCharacter: 'f',
          payload: original,
        ),
        cursor: 'cursor-reversion',
      );
      expect(
        await db.emailImportDao.pendingUpdates(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
        ),
        isEmpty,
      );
      final updates = await db.emailImportDao.updatesForCandidate(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );
      expect(updates.map((row) => row.state),
          containsAll(['rejected', 'superseded']));
      expect(
        (await db.emailImportDao.candidateById(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
        ))
            ?.reviewState,
        'confirmed',
      );
      expect(
        (await db.select(db.assignments).get()).single.dueAt.toUtc(),
        original.due.at,
      );
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 8)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
        reason: 'ordinary superseded proposals are not server-wins evidence',
      );
    },
  );

  test('newest received message wins regardless of page or fetch order',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      summary: 'Original memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final older = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 11, 14, 59),
      summary: 'Older provider change',
    );
    final newer = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 13, 14, 59),
      summary: 'Newest provider change',
    );
    final service = EmailImportSyncService(
      db: db,
      connector: _ManyItemPageConnector(
        [
          _item(
            messageId: 'message-newest-first',
            threadId: 'thread-assignment',
            contentHashCharacter: 'c',
            payload: newer,
            receivedAt: _now.add(const Duration(minutes: 2)),
          ),
          _item(
            messageId: 'message-older-second',
            threadId: 'thread-assignment',
            contentHashCharacter: 'b',
            payload: older,
            receivedAt: _now.add(const Duration(minutes: 1)),
          ),
        ],
        'cursor-out-of-order-page',
      ),
      clock: () => _now.add(const Duration(minutes: 3)),
      authenticatedUserId: () => activeOwner,
    );
    await service.synchronize(
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );

    var pending = await db.emailImportDao.pendingUpdates(
      ownerUserId: _ownerA,
      candidateId: confirmed.candidateId,
    );
    expect(pending, hasLength(1));
    expect(
      pending.single.proposedPayloadJson,
      const EmailCandidatePayloadCodec().encode(newer),
    );

    // A later fetch can contain an older message. It must not displace the
    // already observed newest proposal or regress the canonical entity.
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-late-fetch-old',
        threadId: 'thread-assignment',
        contentHashCharacter: 'd',
        payload: _assignmentPayload(
          dueAt: DateTime.utc(2030, 4, 12, 14, 59),
          summary: 'Late fetch but old message',
        ),
        receivedAt: _now.add(const Duration(seconds: 30)),
      ),
      cursor: 'cursor-late-fetch-old',
    );
    pending = await db.emailImportDao.pendingUpdates(
      ownerUserId: _ownerA,
      candidateId: confirmed.candidateId,
    );
    expect(pending, hasLength(1));
    expect(
      pending.single.proposedPayloadJson,
      const EmailCandidatePayloadCodec().encode(newer),
    );
    expect(
      (await db.select(db.assignments).get()).single.dueAt.toUtc(),
      original.due.at,
    );
  });

  test('cached same-thread sibling converts to an update after confirmation',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      summary: 'Original memo',
    );
    final correction = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 12, 14, 59),
      summary: 'Cached correction',
    );
    final editedCorrection = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 14, 14, 59),
      title: 'User-corrected cached title',
      summary: 'Offline user edit must survive replay',
    );
    final originalItem = _item(
      messageId: 'message-cached-original',
      threadId: 'thread-cached-before-confirmation',
      contentHashCharacter: 'a',
      payload: original,
      receivedAt: _now,
    );
    final correctionItem = _item(
      messageId: 'message-cached-correction',
      threadId: 'thread-cached-before-confirmation',
      contentHashCharacter: 'b',
      payload: correction,
      receivedAt: _now.add(const Duration(minutes: 1)),
    );
    await EmailImportSyncService(
      db: db,
      connector: _ManyItemPageConnector(
        [correctionItem, originalItem],
        'cursor-cached-siblings',
      ),
      clock: () => _now.add(const Duration(minutes: 2)),
      authenticatedUserId: () => activeOwner,
    ).synchronize(
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
    final sources = await db.select(db.emailSources).get();
    final originalSource = sources.singleWhere(
      (source) => source.providerMessageId == 'message-cached-original',
    );
    final correctionSource = sources.singleWhere(
      (source) => source.providerMessageId == 'message-cached-correction',
    );
    final candidatesBefore = await db.select(db.emailCandidates).get();
    expect(candidatesBefore, hasLength(2));
    final originalCandidate = candidatesBefore.singleWhere(
      (candidate) => candidate.sourceId == originalSource.id,
    );
    final correctionCandidate = candidatesBefore.singleWhere(
      (candidate) => candidate.sourceId == correctionSource.id,
    );
    await DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => activeOwner,
      clock: () => _now.add(const Duration(minutes: 2, seconds: 30)),
    ).saveDraft(
      ownerUserId: _ownerA,
      candidateId: correctionCandidate.id,
      payload: editedCorrection,
    );
    final confirmed = await DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => _now.add(const Duration(minutes: 3)),
      authenticatedUserId: () => activeOwner,
    ).confirm(
      ownerUserId: _ownerA,
      candidateId: originalCandidate.id,
      courseId: _courseA,
    );

    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: correctionItem,
      cursor: 'cursor-cached-correction-replay',
    );

    final candidatesAfter = await db.select(db.emailCandidates).get();
    expect(candidatesAfter, hasLength(1));
    expect(candidatesAfter.single.id, originalCandidate.id);
    expect(candidatesAfter.single.reviewState, 'confirmed');
    final pending = await db.emailImportDao.pendingUpdates(
      ownerUserId: _ownerA,
      candidateId: originalCandidate.id,
    );
    expect(pending, hasLength(1));
    expect(
      pending.single.proposedPayloadJson,
      const EmailCandidatePayloadCodec().encode(editedCorrection),
    );
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.dueAt.toUtc(), original.due.at);
    expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(1));
  });

  test(
      'ordinary success converts a failed same-thread sibling into one update proposal',
      () async {
    await _exerciseFailedSiblingUpdateConversion(
      db: db,
      activeOwner: () => activeOwner,
      targeted: false,
    );
  });

  test(
      'targeted success converts a failed same-thread sibling into one update proposal without advancing cursor',
      () async {
    await _exerciseFailedSiblingUpdateConversion(
      db: db,
      activeOwner: () => activeOwner,
      targeted: true,
    );
  });

  test(
    'dismissal prunes payload, survives reconnect, and stays owner/thread scoped',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'email-dismissal-restart-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}schedule.sqlite',
      );
      db = local.AppDatabase(NativeDatabase(file));
      await _seedConnection(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
      );
      final payload = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 10, 14, 59),
        summary: 'Sensitive proposal memo',
      );
      final originalItem = _item(
        messageId: 'raw-provider-message',
        threadId: 'raw-provider-thread',
        contentHashCharacter: 'a',
        payload: payload,
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: originalItem,
        cursor: 'cursor-dismiss',
      );
      final candidate = (await db.select(db.emailCandidates).get()).single;
      final store = DriftEmailReviewStore(
        db: db,
        authenticatedUserId: () => activeOwner,
        clock: () => _now.add(const Duration(minutes: 1)),
      );
      await store.dismiss(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
      );
      await store.dismiss(
        ownerUserId: _ownerA,
        candidateId: candidate.id,
      );

      expect(await db.select(db.emailSources).get(), isEmpty);
      expect(await db.select(db.emailCandidates).get(), isEmpty);
      final tombstone =
          (await db.select(db.emailDismissalTombstones).get()).single;
      final retained = <String>[
        tombstone.providerAccountHash,
        tombstone.providerMessageIdHash,
        tombstone.providerThreadIdHash,
        tombstone.sanitizedContentHash,
        tombstone.semanticFingerprint,
      ].join('|');
      expect(retained, isNot(contains('raw-provider-message')));
      expect(retained, isNot(contains('raw-provider-thread')));
      expect(retained, isNot(contains('Sensitive proposal memo')));
      expect(tombstone.providerMessageIdHash, hasLength(64));
      expect(tombstone.providerThreadIdHash, hasLength(64));
      final dismissalReceipt = (await (db.select(db.emailReconciliationReceipts)
                ..where((row) => row.action.equals('dismissal')))
              .get())
          .single;
      expect(dismissalReceipt.ownerUserId, _ownerA);
      expect(dismissalReceipt.localReferenceId, candidate.id);
      expect(dismissalReceipt.providerMessageIdHash, hasLength(64));
      expect(dismissalReceipt.providerThreadIdHash, hasLength(64));
      expect(dismissalReceipt.reviewedPayloadJson, isNull);
      expect(dismissalReceipt.entityId, isNull);
      expect(dismissalReceipt.requiredSyncMutationId, isNull);
      expect(
        await db.emailImportDao.deleteDerivedDataForConnection(
          ownerUserId: _ownerA,
          connectionId: _connectionA,
        ),
        1,
      );
      expect(await db.select(db.emailReconciliationReceipts).get(), isEmpty);
      expect(await db.select(db.emailDismissalTombstones).get(), hasLength(1));

      await db.close();
      db = local.AppDatabase(NativeDatabase(file));
      await _seedConnection(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: originalItem,
        cursor: 'cursor-exact-replay',
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'new-message-same-thread',
          threadId: 'raw-provider-thread',
          contentHashCharacter: 'b',
          payload: payload,
        ),
        cursor: 'cursor-semantic-replay',
      );
      expect(await db.select(db.emailSources).get(), isEmpty);
      expect(await db.select(db.emailCandidates).get(), isEmpty);

      // Similar content in another thread is a distinct candidate.
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'other-thread-message',
          threadId: 'unrelated-thread',
          contentHashCharacter: 'a',
          payload: payload,
        ),
        cursor: 'cursor-other-thread',
      );
      expect(await db.select(db.emailCandidates).get(), hasLength(1));

      await _seedConnection(
        db,
        ownerUserId: _ownerB,
        connectionId: _connectionB,
      );
      activeOwner = _ownerB;
      await _sync(
        db,
        ownerUserId: _ownerB,
        connectionId: _connectionB,
        activeOwner: () => activeOwner,
        item: originalItem,
        cursor: 'cursor-other-owner',
      );
      expect(await db.select(db.emailCandidates).get(), hasLength(2));
      expect(
        (await db.select(db.emailCandidates).get())
            .map((row) => row.ownerUserId)
            .toSet(),
        {_ownerA, _ownerB},
      );
      await db.close();
      db = local.AppDatabase(NativeDatabase.memory());
      await directory.delete(recursive: true);
    },
  );

  test(
    'derived deletion removes connection receipts without crossing owners',
    () async {
      await _seedConnection(
        db,
        ownerUserId: _ownerB,
        connectionId: _connectionB,
      );
      for (final ownerConnection in <(String, String)>[
        (_ownerA, _connectionA),
        (_ownerB, _connectionB),
      ]) {
        final owner = ownerConnection.$1;
        final connection = ownerConnection.$2;
        await db.into(db.emailDismissalTombstones).insert(
              local.EmailDismissalTombstonesCompanion.insert(
                id: 'tombstone-$owner',
                ownerUserId: owner,
                provider: 'gmail',
                providerAccountHash: 'b' * 64,
                providerMessageIdHash: 'c' * 64,
                providerThreadIdHash: 'd' * 64,
                sanitizedContentHash: 'e' * 64,
                semanticFingerprint: 'f' * 64,
                dismissedAt: _now,
              ),
            );
        await db.into(db.emailReconciliationReceipts).insert(
              local.EmailReconciliationReceiptsCompanion.insert(
                id: 'dismissal:$owner',
                ownerUserId: owner,
                connectionId: connection,
                action: 'dismissal',
                localReferenceId: 'tombstone-$owner',
                provider: 'gmail',
                providerAccountHash: 'b' * 64,
                providerMessageIdHash: 'c' * 64,
                providerThreadIdHash: 'd' * 64,
                sanitizedContentHash: 'e' * 64,
                idempotencyKey: 'dismissal-key-$owner',
                createdAt: Value(_now),
                updatedAt: Value(_now),
              ),
            );
      }

      expect(
        await db.emailImportDao.deleteDerivedDataForConnection(
          ownerUserId: _ownerA,
          connectionId: _connectionB,
        ),
        0,
      );
      expect(await db.select(db.emailConnections).get(), hasLength(2));
      expect(
          await db.select(db.emailReconciliationReceipts).get(), hasLength(2));

      expect(
        await db.emailImportDao.deleteDerivedDataForConnection(
          ownerUserId: _ownerA,
          connectionId: _connectionA,
        ),
        1,
      );
      final remainingConnections = await db.select(db.emailConnections).get();
      expect(remainingConnections, hasLength(1));
      expect(remainingConnections.single.ownerUserId, _ownerB);
      final remainingReceipts =
          await db.select(db.emailReconciliationReceipts).get();
      expect(remainingReceipts, hasLength(1));
      expect(remainingReceipts.single.ownerUserId, _ownerB);
      expect(await db.select(db.emailDismissalTombstones).get(), hasLength(2));
      expect(await db.select(db.userCourses).get(), hasLength(1));
      expect(
          (await db.select(db.userCourses).get()).single.ownerUserId, _ownerA);
    },
  );

  test('similar messages in unrelated threads remain distinct', () async {
    final payload = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      summary: 'Same schedule fields',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'unrelated-message-a',
        threadId: 'unrelated-thread-a',
        contentHashCharacter: 'a',
        payload: payload,
      ),
      cursor: 'cursor-unrelated-a',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'unrelated-message-b',
        threadId: 'unrelated-thread-b',
        contentHashCharacter: 'a',
        payload: payload,
      ),
      cursor: 'cursor-unrelated-b',
    );

    expect(await db.select(db.emailSources).get(), hasLength(2));
    expect(await db.select(db.emailCandidates).get(), hasLength(2));
  });

  test(
    'server-wins leaves a confirmation receipt pending instead of treating it as an update',
    () async {
      final confirmed = await _syncAndConfirm(
        db,
        activeOwner: () => activeOwner,
        payload: _assignmentPayload(
          dueAt: DateTime.utc(2030, 4, 10, 14, 59),
          title: 'Locally confirmed assignment',
        ),
      );
      final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
      final mutation = await queue.claimNext(
        now: _now.add(const Duration(minutes: 1)),
      );
      expect(mutation, isNotNull);
      expect(mutation!.operation, SyncOperation.create);

      final canonicalDueAt = DateTime.utc(2030, 4, 10, 14, 59);
      final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
      await store.acknowledge(
        mutation,
        ScheduleMutationAck(
          clientMutationId: mutation.clientMutationId,
          outcome: ScheduleMutationOutcome.conflict,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: SyncOperation.create,
          change: ScheduleDeltaChange(
            changeCursor: 76,
            entityType: 'assignment',
            entityId: confirmed.entityId,
            operation: ScheduleDeltaOperation.upsert,
            serverVersion: 1,
            payload: {
              'id': confirmed.entityId,
              'ownerUserId': _ownerA,
              'courseId': _courseA,
              'title': 'Remote canonical assignment',
              'dueAt': canonicalDueAt.toIso8601String(),
              'submissionUrl': null,
              'memo': null,
              'priority': null,
              'visibilityLevel': 'PRIVATE',
              'updatedAt':
                  _now.add(const Duration(minutes: 1)).toIso8601String(),
              'deletedAt': null,
              'version': 1,
            },
          ),
          replayed: false,
        ),
        acknowledgedAt: _now.add(const Duration(minutes: 1)),
      );

      await store.resolveConflictServerWins(
        mutation.clientMutationId,
        resolvedAt: _now.add(const Duration(minutes: 2)),
      );

      final assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.title, 'Remote canonical assignment');
      expect(assignment.dueAt.toUtc(), canonicalDueAt);
      final receipt = (await db.select(db.emailReconciliationReceipts).get())
          .singleWhere((row) => row.action == 'confirmation');
      expect(receipt.state, 'pending');
      expect(receipt.scheduleAckedAt, isNull);
      expect(receipt.requiredSyncMutationId, mutation.clientMutationId);
      final terminalMutation =
          (await db.syncQueueDao.allMutations(_ownerA)).singleWhere(
        (row) => row.clientMutationId == mutation.clientMutationId,
      );
      expect(
        terminalMutation.completionProvenance,
        local.scheduleSyncCompletionServerWins,
      );
      final serverWins =
          (await db.select(db.emailScheduleEditReceipts).get()).singleWhere(
        (row) => row.provenance == 'server_wins',
      );
      expect(serverWins.baseEntityVersion, 1);
      expect(serverWins.entityVersion, 1);
      expect(
        (await db.select(db.notificationScheduleRequests).get())
            .single
            .anchorAt
            .toUtc(),
        canonicalDueAt,
      );
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 3)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
      );
    },
  );

  test(
    'accepted update conflict server-wins becomes a durable rejected review',
    () async {
      await db.close();
      final directory = await Directory.systemTemp.createTemp(
        'email-update-server-wins-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}schedule.sqlite',
      );
      db = local.AppDatabase(NativeDatabase(file));
      await _seedScheduleContext(db);
      await _seedConnection(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
      );
      final original = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 10, 14, 59),
        title: 'Original assignment',
        summary: 'Original memo',
        reminders: const [1440, 180],
      );
      final confirmed = await _syncAndConfirm(
        db,
        activeOwner: () => activeOwner,
        payload: original,
      );
      final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
      final confirmationMutation = await queue.claimNext(
        now: _now.add(const Duration(minutes: 2)),
      );
      expect(confirmationMutation, isNotNull);
      expect(confirmationMutation!.operation, SyncOperation.create);
      expect(
        await queue.markSynced(
          confirmationMutation.clientMutationId,
          acknowledgedAt: _now.add(const Duration(minutes: 2)),
          attemptCount: confirmationMutation.attemptCount,
          serverVersion: 1,
        ),
        isTrue,
      );
      final gateway = _EmailReconciliationGateway();
      var reconciliation = EmailReconciliationService(
        db: db,
        gateway: gateway,
        clock: () => _now.add(const Duration(minutes: 2)),
        authenticatedUserId: () => activeOwner,
      );
      expect(
        (await reconciliation.synchronize(
          ownerUserId: _ownerA,
          networkAvailable: true,
        ))
            .reconciled,
        1,
      );
      expect(gateway.requests.single.action,
          EmailReconciliationAction.confirmation);
      gateway.requests.clear();

      final proposed = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 12, 14, 59),
        title: 'Accepted local proposal',
        summary: 'Accepted provider memo',
        reminders: const [60],
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-conflicting-update',
          threadId: 'thread-assignment',
          contentHashCharacter: 'b',
          payload: proposed,
          receivedAt: _now.add(const Duration(minutes: 3)),
        ),
        cursor: 'cursor-conflicting-update',
      );
      final repository = DriftEmailCandidateUpdateRepository(
        db: db,
        clock: () => _now.add(const Duration(minutes: 4)),
        authenticatedUserId: () => activeOwner,
      );
      final proposal = (await repository.pending(ownerUserId: _ownerA)).single;
      await repository.accept(ownerUserId: _ownerA, updateId: proposal.id);
      final acceptedReceipt = (await (db.select(db.emailReconciliationReceipts)
                ..where((row) => row.action.equals('update')))
              .get())
          .single;
      expect(acceptedReceipt.resolution, 'accepted');
      expect(acceptedReceipt.scheduleAckedAt, isNull);
      await expectLater(
        (db.update(db.emailCandidateUpdates)
              ..where((row) => row.id.equals(proposal.id)))
            .write(
          local.EmailCandidateUpdatesCompanion(
            state: const Value('superseded'),
            resolutionIdempotencyKey:
                Value('email-update-server-wins-reject:${proposal.id}'),
            resolvedAt: Value(_now.add(const Duration(minutes: 4))),
            updatedAt: Value(_now.add(const Duration(minutes: 4))),
          ),
        ),
        throwsA(anything),
        reason: 'accepted proposals require a real conflict before discard',
      );
      expect(
        (await db.emailImportDao.candidateUpdateById(
          ownerUserId: _ownerA,
          updateId: proposal.id,
        ))
            ?.state,
        'accepted',
      );

      final updateMutation = await queue.claimNext(
        now: _now.add(const Duration(minutes: 5)),
      );
      expect(updateMutation, isNotNull);
      expect(updateMutation!.operation, SyncOperation.update);
      final canonicalDueAt = original.due.at!;
      final canonicalChange = ScheduleDeltaChange(
        changeCursor: 77,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: ScheduleDeltaOperation.upsert,
        serverVersion: 2,
        payload: {
          'id': confirmed.entityId,
          'ownerUserId': _ownerA,
          'courseId': _courseA,
          'title': original.title,
          'dueAt': canonicalDueAt.toIso8601String(),
          'submissionUrl': original.submissionUrl,
          'memo': original.summary,
          'priority': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': _now.add(const Duration(minutes: 5)).toIso8601String(),
          'deletedAt': null,
          'version': 2,
        },
      );
      final store = DriftScheduleSyncStore(
        db,
        ownerUserId: _ownerA,
        clock: () => _now.add(const Duration(minutes: 6)),
      );
      await store.acknowledge(
        updateMutation,
        ScheduleMutationAck(
          clientMutationId: updateMutation.clientMutationId,
          outcome: ScheduleMutationOutcome.conflict,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: SyncOperation.update,
          change: canonicalChange,
          replayed: false,
        ),
        acknowledgedAt: _now.add(const Duration(minutes: 5)),
      );
      expect(
        (await db.select(db.emailReconciliationReceipts).get())
            .singleWhere((row) => row.action == 'update')
            .scheduleAckedAt,
        isNull,
      );

      await store.resolveConflictServerWins(
        updateMutation.clientMutationId,
        resolvedAt: _now.add(const Duration(minutes: 6)),
      );
      var assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.title, original.title);
      expect(assignment.dueAt.toUtc(), canonicalDueAt);
      expect(assignment.description, original.summary);
      expect(assignment.version, 2);
      var candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );
      final aligned = const EmailCandidatePayloadCodec().decode(
        candidate!.normalizedPayloadJson,
      );
      expect(aligned.title, assignment.title);
      expect(aligned.due.at, assignment.dueAt.toUtc());
      expect(aligned.summary, assignment.description);
      expect(aligned.submissionUrl, assignment.submissionUrl);
      expect(aligned.suggestedRemindersMinutes,
          original.suggestedRemindersMinutes);
      expect(
        candidate.semanticFingerprint,
        emailCandidateSemanticFingerprint(aligned),
      );
      var resolvedProposal = await db.emailImportDao.candidateUpdateById(
        ownerUserId: _ownerA,
        updateId: proposal.id,
      );
      expect(resolvedProposal!.state, 'superseded');
      expect(
        resolvedProposal.resolutionIdempotencyKey,
        isNot(acceptedReceipt.idempotencyKey),
      );
      var rejectedReceipt = (await (db.select(db.emailReconciliationReceipts)
                ..where((row) => row.action.equals('update')))
              .get())
          .single;
      expect(rejectedReceipt.resolution, 'rejected');
      expect(rejectedReceipt.idempotencyKey,
          resolvedProposal.resolutionIdempotencyKey);
      expect(rejectedReceipt.requiredSyncMutationId, isNull);
      expect(rejectedReceipt.scheduleAckedAt, isNull);
      final terminalMutation = (await db.syncQueueDao.allMutations(_ownerA))
          .singleWhere(
              (row) => row.clientMutationId == updateMutation.clientMutationId);
      expect(terminalMutation.status, 'synced');
      expect(
        terminalMutation.completionProvenance,
        local.scheduleSyncCompletionServerWins,
      );
      final collisionPayload = _assignmentPayload(
        dueAt: original.due.at!.add(const Duration(days: 30)),
        title: 'Collision proposal placeholder',
      );
      await _sync(
        db,
        ownerUserId: _ownerA,
        connectionId: _connectionA,
        activeOwner: () => activeOwner,
        item: _item(
          messageId: 'message-accepted-same-second-collision',
          threadId: 'thread-assignment',
          contentHashCharacter: 'c',
          payload: collisionPayload,
          receivedAt: _now.add(const Duration(minutes: 6)),
        ),
        cursor: 'cursor-accepted-same-second-collision',
      );
      final collisionProposal = (await (db.select(db.emailCandidateUpdates)
                ..where((row) => row.state.equals('pending')))
              .get())
          .single;
      final collisionId = collisionProposal.id;
      final collisionResolutionKey = const Uuid().v5(
        Namespace.url.value,
        'email-update-accept\u0000$_ownerA\u0000$collisionId',
      );
      await db.customStatement(
        'DROP TRIGGER IF EXISTS email_candidate_updates_v12_guard_update',
      );
      await (db.update(db.emailCandidateUpdates)
            ..where((row) => row.id.equals(collisionId)))
          .write(
        local.EmailCandidateUpdatesCompanion(
          proposedPayloadJson: Value(candidate.normalizedPayloadJson),
          semanticFingerprint: Value(emailCandidateUpdateFingerprint(aligned)),
          state: const Value('accepted'),
          resolutionIdempotencyKey: Value(collisionResolutionKey),
          resolvedAt: Value(candidate.updatedAt),
          updatedAt: Value(candidate.updatedAt),
        ),
      );
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 7)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
        reason: 'same-second rejection outranks an accepted payload collision',
      );

      await (db.delete(db.emailCandidateUpdates)
            ..where((row) => row.id.equals(proposal.id)))
          .go();
      await expectLater(
        DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 7)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ),
        throwsA(isA<EmailReviewActionException>()),
        reason: 'a retained rejection receipt cannot hide a missing proposal',
      );
      await db.customStatement(
        'DROP TRIGGER IF EXISTS email_candidate_updates_v12_guard_insert',
      );
      await db.into(db.emailCandidateUpdates).insert(resolvedProposal);

      final winningReceipt =
          (await db.select(db.emailScheduleEditReceipts).get()).singleWhere(
        (row) => row.provenance == 'server_wins',
      );
      expect(winningReceipt.provenance, 'server_wins');
      expect(winningReceipt.mutationId, updateMutation.clientMutationId);
      expect(winningReceipt.baseEntityVersion, 1);
      expect(winningReceipt.entityVersion, 2);
      expect(winningReceipt.payloadFingerprint, hasLength(43));
      expect(winningReceipt.candidatePayloadFingerprint, hasLength(43));
      await expectLater(
        (db.update(db.emailScheduleEditReceipts)
              ..where(
                (row) => row.mutationId.equals(winningReceipt.mutationId),
              ))
            .write(
          local.EmailScheduleEditReceiptsCompanion(
            payloadFingerprint: Value('x' * 43),
          ),
        ),
        throwsA(anything),
        reason: 'the authenticated server-winning payload is immutable',
      );

      await (db.update(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .write(
        const local.AssignmentsCompanion(
          title: Value('Coordinated server-wins payload tamper'),
        ),
      );
      await expectLater(
        DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 7)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ),
        throwsA(
          isA<EmailReviewActionException>().having(
            (error) => error.category,
            'category',
            EmailErrorCategory.internalError,
          ),
        ),
      );
      await (db.update(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .write(
        local.AssignmentsCompanion(
          title: Value(assignment.title),
        ),
      );

      await db.close();
      db = local.AppDatabase(NativeDatabase(file));
      reconciliation = EmailReconciliationService(
        db: db,
        gateway: gateway,
        clock: () => _now.add(const Duration(minutes: 7)),
        authenticatedUserId: () => activeOwner,
      );
      final reconciled = await reconciliation.synchronize(
        ownerUserId: _ownerA,
        networkAvailable: true,
      );
      expect(reconciled.reconciled, 1);
      expect(gateway.requests, hasLength(1));
      expect(gateway.requests.single.action, EmailReconciliationAction.update);
      expect(
        gateway.requests.single.resolution,
        EmailReconciliationResolution.rejected,
      );
      expect(
        gateway.requests.where((request) =>
            request.resolution == EmailReconciliationResolution.accepted),
        isEmpty,
      );
      rejectedReceipt = (await (db.select(db.emailReconciliationReceipts)
                ..where((row) => row.action.equals('update')))
              .get())
          .single;
      expect(rejectedReceipt.state, 'succeeded');
      expect(rejectedReceipt.scheduleAckedAt, isNull);
      expect(
        (await reconciliation.synchronize(
          ownerUserId: _ownerA,
          networkAvailable: true,
        ))
            .examined,
        0,
      );
      expect(gateway.requests, hasLength(1));

      final userEditedAt = _now.add(const Duration(minutes: 8));
      assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      await DriftScheduleRepository(
        db,
        clock: () => userEditedAt,
        createId: () => 'post-server-wins-user-edit',
      ).updateAssignment(
        assignmentId: assignment.id,
        ownerUserId: _ownerA,
        expectedVersion: assignment.version,
        input: AssignmentInput(
          courseId: assignment.courseId,
          title: 'Post-conflict user edit',
          dueAt: canonicalDueAt.add(const Duration(days: 1)),
          submissionUrl: assignment.submissionUrl,
          memo: assignment.description,
          priority: assignment.priority,
          visibilityLevel: VisibilityLevel.private,
        ),
      );
      final editReceipts = await db.select(db.emailScheduleEditReceipts).get();
      expect(editReceipts, hasLength(3));
      final userEditReceipt = editReceipts.singleWhere(
        (row) => row.provenance == 'user_edit',
      );
      expect(userEditReceipt.mutationId, 'post-server-wins-user-edit');
      expect(
        userEditReceipt.basePayloadFingerprint,
        winningReceipt.payloadFingerprint,
      );
      expect(userEditReceipt.baseEntityVersion, 2);
      expect(userEditReceipt.entityVersion, 3);
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(minutes: 9)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
      );
      final reopenedQueue = DriftSyncQueue(db, ownerUserId: _ownerA);
      final userEditMutation = await reopenedQueue.claimNext(
        now: _now.add(const Duration(minutes: 10)),
      );
      expect(userEditMutation?.clientMutationId, 'post-server-wins-user-edit');
      expect(
        await reopenedQueue.markSynced(
          userEditMutation!.clientMutationId,
          acknowledgedAt: _now.add(const Duration(minutes: 10)),
          attemptCount: userEditMutation.attemptCount,
          serverVersion: 3,
        ),
        isTrue,
      );

      expect(
        await DriftSyncQueue.cleanupAcknowledgedGlobally(
          db,
          now: _now.add(const Duration(days: 90)),
        ),
        3,
      );
      await db.close();
      db = local.AppDatabase(NativeDatabase(file));
      expect(await db.syncQueueDao.allMutations(_ownerA), isEmpty);
      assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      candidate = await db.emailImportDao.candidateById(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      );
      resolvedProposal = await db.emailImportDao.candidateUpdateById(
        ownerUserId: _ownerA,
        updateId: proposal.id,
      );
      expect(assignment.title, 'Post-conflict user edit');
      expect(assignment.version, 3);
      expect(candidate, isNotNull);
      expect(resolvedProposal?.state, 'superseded');
      expect(
        (await db.select(db.emailReconciliationReceipts).get())
            .singleWhere((row) => row.action == 'update')
            .state,
        'succeeded',
      );
      expect(
        (await DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(days: 91)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ))
            .replayed,
        isTrue,
      );
      final confirmedAt = candidate!.confirmedAt!;
      for (final trigger in const [
        'email_candidate_updates_v12_guard_update',
        'email_candidate_updates_owner_guard_update',
        'email_candidates_owner_guard_update',
        'email_candidates_confirmation_guard_update',
        'email_candidates_confirmed_state_guard_update',
        'email_candidates_v12_source_exclusive_update',
      ]) {
        await db.customStatement('DROP TRIGGER IF EXISTS $trigger');
      }
      await (db.update(db.emailCandidateUpdates)
            ..where((row) => row.id.equals(proposal.id)))
          .write(
        local.EmailCandidateUpdatesCompanion(
          resolvedAt: Value(confirmedAt),
          updatedAt: Value(confirmedAt),
        ),
      );
      await (db.update(db.emailCandidates)
            ..where((row) => row.id.equals(confirmed.candidateId)))
          .write(
        local.EmailCandidatesCompanion(updatedAt: Value(confirmedAt)),
      );
      await expectLater(
        DriftEmailCandidateConfirmationGateway(
          db: db,
          clock: () => _now.add(const Duration(days: 91)),
          authenticatedUserId: () => activeOwner,
        ).confirm(
          ownerUserId: _ownerA,
          candidateId: confirmed.candidateId,
          courseId: _courseA,
        ),
        throwsA(isA<EmailReviewActionException>()),
        reason: 'same-timestamp rejection corruption cannot use initial state',
      );
      await db.close();
      db = local.AppDatabase(NativeDatabase.memory());
      await directory.delete(recursive: true);
    },
  );

  test(
      'ordinary email-linked edit server-wins replaces the tip and later edits chain',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Original generic conflict assignment',
      summary: 'Original generic memo',
      reminders: const [60],
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final confirmationSecond = _now.add(const Duration(minutes: 1));
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final createMutation = await queue.claimNext(
      now: confirmationSecond.add(const Duration(milliseconds: 100)),
    );
    expect(createMutation, isNotNull);
    expect(
      await queue.markSynced(
        createMutation!.clientMutationId,
        acknowledgedAt:
            confirmationSecond.add(const Duration(milliseconds: 100)),
        attemptCount: createMutation.attemptCount,
        serverVersion: 1,
      ),
      isTrue,
    );

    await DriftScheduleRepository(
      db,
      clock: () => confirmationSecond.add(const Duration(milliseconds: 200)),
      createId: () => 'generic-user-edit-conflict',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Losing local edit',
        dueAt: original.due.at!.add(const Duration(days: 1)),
        submissionUrl: original.submissionUrl,
        memo: 'Losing local memo',
      ),
    );
    final editMutation = await queue.claimNext(
      now: confirmationSecond.add(const Duration(milliseconds: 300)),
    );
    expect(editMutation?.clientMutationId, 'generic-user-edit-conflict');
    final canonicalDueAt = original.due.at!.add(const Duration(days: 2));
    final canonicalChange = ScheduleDeltaChange(
      changeCursor: 91,
      entityType: 'assignment',
      entityId: confirmed.entityId,
      operation: ScheduleDeltaOperation.upsert,
      serverVersion: 2,
      payload: {
        'id': confirmed.entityId,
        'ownerUserId': _ownerA,
        'courseId': _courseA,
        'title': 'Canonical generic winner',
        'dueAt': canonicalDueAt.toIso8601String(),
        'submissionUrl': original.submissionUrl,
        'memo': 'Canonical generic memo',
        'priority': null,
        'visibilityLevel': 'PRIVATE',
        'updatedAt': confirmationSecond
            .add(const Duration(milliseconds: 400))
            .toIso8601String(),
        'deletedAt': null,
        'version': 2,
      },
    );
    final store = DriftScheduleSyncStore(
      db,
      ownerUserId: _ownerA,
      clock: () => confirmationSecond.add(const Duration(milliseconds: 600)),
    );
    await store.acknowledge(
      editMutation!,
      ScheduleMutationAck(
        clientMutationId: editMutation.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: SyncOperation.update,
        change: canonicalChange,
        replayed: false,
      ),
      acknowledgedAt: confirmationSecond.add(const Duration(milliseconds: 500)),
    );
    await store.resolveConflictServerWins(
      editMutation.clientMutationId,
      resolvedAt: confirmationSecond.add(const Duration(milliseconds: 600)),
    );
    var assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.title, 'Canonical generic winner');
    expect(assignment.dueAt.toUtc(), canonicalDueAt);
    final winner = (await db.select(db.emailScheduleEditReceipts).get())
        .singleWhere((row) => row.mutationId == editMutation.clientMutationId);
    expect(winner.provenance, 'server_wins');
    expect(winner.baseEntityVersion, 1);
    expect(winner.entityVersion, 2);
    expect(
      winner.createdAt.toUtc(),
      emailScheduleSqliteTimestamp(confirmationSecond),
      reason: 'ordinary server-wins may share the confirmation second',
    );
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 6)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );

    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 7)),
      createId: () => 'after-generic-server-wins-edit',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 2,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Later user edit',
        dueAt: canonicalDueAt.add(const Duration(days: 1)),
        submissionUrl: assignment.submissionUrl,
        memo: assignment.description,
      ),
    );
    assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.version, 3);
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 8)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
  });

  test(
      'email-linked server-wins with missing edit provenance rolls back unchanged',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Missing provenance origin',
      reminders: const [60],
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await _ackAllPendingEmailMutations(db);
    final localDueAt = original.due.at!.add(const Duration(days: 1));
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 20)),
      createId: () => 'missing-provenance-edit',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Local missing-provenance edit',
        dueAt: localDueAt,
        memo: original.summary,
      ),
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final edit = await queue.claimNext(
      now: _now.add(const Duration(minutes: 21)),
    );
    expect(edit?.clientMutationId, 'missing-provenance-edit');
    final canonicalAt = _now.add(const Duration(minutes: 22));
    final canonicalPayload = <String, Object?>{
      ...edit!.payload,
      'title': 'Canonical must not apply',
      'updatedAt': canonicalAt.toIso8601String(),
      'deletedAt': null,
      'version': 2,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.acknowledge(
      edit,
      ScheduleMutationAck(
        clientMutationId: edit.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: SyncOperation.update,
        change: ScheduleDeltaChange(
          changeCursor: 40,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 2,
          payload: canonicalPayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: canonicalAt,
    );
    expect(
      await (db.delete(db.emailScheduleEditReceipts)
            ..where((row) => row.mutationId.equals(edit.clientMutationId)))
          .go(),
      1,
    );
    final before = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    final notificationBefore =
        (await db.select(db.notificationScheduleRequests).get()).single;
    await expectLater(
      store.resolveConflictServerWins(
        edit.clientMutationId,
        resolvedAt: canonicalAt.add(const Duration(minutes: 1)),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
    final after = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    final notificationAfter =
        (await db.select(db.notificationScheduleRequests).get()).single;
    expect(after.title, before.title);
    expect(after.dueAt, before.dueAt);
    expect(after.updatedAt, before.updatedAt);
    expect(after.version, before.version);
    expect(notificationAfter.anchorAt, notificationBefore.anchorAt);
    expect(notificationAfter.state, notificationBefore.state);
    expect(notificationAfter.updatedAt, notificationBefore.updatedAt);
    final retained = (await db.syncQueueDao.allMutations(_ownerA))
        .singleWhere((row) => row.clientMutationId == edit.clientMutationId);
    expect(retained.status, 'conflict');
    expect(retained.completionProvenance, isNull);
  });

  test('trusted remote delta advances the hash chain across a course move',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Original remote-delta assignment',
      reminders: const [30],
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final createMutation = await queue.claimNext(
      now: _now.add(const Duration(minutes: 2)),
    );
    expect(createMutation, isNotNull);
    expect(
      await queue.markSynced(
        createMutation!.clientMutationId,
        acknowledgedAt: _now.add(const Duration(minutes: 2)),
        attemptCount: createMutation.attemptCount,
        serverVersion: 1,
      ),
      isTrue,
    );
    final remoteDueAt = original.due.at!.add(const Duration(days: 3));
    final remoteUpdatedAt = _now.add(const Duration(minutes: 3));
    final remoteChange = ScheduleDeltaChange(
      changeCursor: 1,
      entityType: 'assignment',
      entityId: confirmed.entityId,
      operation: ScheduleDeltaOperation.upsert,
      serverVersion: 2,
      payload: {
        'id': confirmed.entityId,
        'ownerUserId': _ownerA,
        'courseId': null,
        'title': 'Remote device assignment',
        'dueAt': remoteDueAt.toIso8601String(),
        'submissionUrl': original.submissionUrl,
        'memo': original.summary,
        'priority': 'low',
        'visibilityLevel': 'PRIVATE',
        'updatedAt': remoteUpdatedAt.toIso8601String(),
        'deletedAt': null,
        'version': 2,
      },
    );
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [remoteChange],
      ),
      appliedAt: _now.add(const Duration(minutes: 4)),
    );
    final remoteReceipt = (await db.select(db.emailScheduleEditReceipts).get())
        .singleWhere((row) => row.provenance == 'remote_apply');
    expect(remoteReceipt.baseEntityVersion, 1);
    expect(remoteReceipt.entityVersion, 2);
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 5)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
    expect(
      (await db.select(db.notificationScheduleRequests).get())
          .single
          .anchorAt
          .toUtc(),
      remoteDueAt,
    );

    final equalVersionTamper = ScheduleDeltaChange(
      changeCursor: 2,
      entityType: 'assignment',
      entityId: confirmed.entityId,
      operation: ScheduleDeltaOperation.upsert,
      serverVersion: 2,
      payload: {...remoteChange.payload, 'title': 'Equal-version tamper'},
    );
    await expectLater(
      store.applyDeltaPage(
        ScheduleDeltaPage(
          afterCursor: 1,
          nextCursor: 2,
          hasMore: false,
          changes: [equalVersionTamper],
        ),
      ),
      throwsA(isA<RemoteScheduleProtocolException>()),
    );
    expect(await store.cursor(), 1);
  });

  test(
      'retained v14 ordinary edits each drain by real mutation id and replay after pruning',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-edit-legacy-v14-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(db);
    await _seedConnection(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Legacy ordinary edit origin',
      reminders: const [30],
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final intermediateDueAt = original.due.at!.add(const Duration(days: 1));
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 2)),
      createId: () => 'legacy-v14-user-edit-1',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: null,
        title: 'Legacy ordinary edit intermediate',
        dueAt: intermediateDueAt,
        submissionUrl: original.submissionUrl,
        memo: original.summary,
      ),
    );
    final editedDueAt = original.due.at!.add(const Duration(days: 2));
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 3)),
      createId: () => 'legacy-v14-user-edit-2',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 2,
      input: AssignmentInput(
        courseId: null,
        title: 'Legacy ordinary edit tip',
        dueAt: editedDueAt,
        submissionUrl: original.submissionUrl,
        memo: original.summary,
      ),
    );
    await _downgradeEmailProvenanceFixture(
      db,
      candidateId: confirmed.candidateId,
      schemaVersion: 14,
    );
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    final migrated = await db.select(db.emailScheduleEditReceipts).get();
    expect(migrated.map((row) => row.provenance).toSet(), {
      'confirmation',
      'user_edit',
    });
    final migratedEdits = migrated
        .where((row) => row.provenance == 'user_edit')
        .toList()
      ..sort(
          (left, right) => left.entityVersion.compareTo(right.entityVersion));
    expect(
      migratedEdits.map((row) => row.mutationId),
      ['legacy-v14-user-edit-1', 'legacy-v14-user-edit-2'],
    );
    expect(
      migratedEdits.map((row) => (row.baseEntityVersion, row.entityVersion)),
      [(1, 2), (2, 3)],
    );
    await _ackAllPendingEmailMutations(db);
    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    final replay = await DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => _now.add(const Duration(minutes: 10)),
      authenticatedUserId: () => activeOwner,
    ).confirm(
      ownerUserId: _ownerA,
      candidateId: confirmed.candidateId,
      courseId: _courseA,
    );
    expect(replay.replayed, isTrue);
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.courseId, isNull);
    expect(assignment.title, 'Legacy ordinary edit tip');
    expect(assignment.dueAt.toUtc(), editedDueAt);
    await expectLater(
      DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => _now.add(const Duration(minutes: 10)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
      ),
      throwsA(isA<EmailReviewActionException>()),
      reason: 'the pruned legacy chain remains bound to original course A',
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test(
      'retained v14 gap tip appends server-wins and replays after queue pruning',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-edit-legacy-gap-conflict-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(db);
    await _seedConnection(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Legacy gap origin',
      summary: 'Legacy gap memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 2)),
      createId: () => 'legacy-gap-pruned-edit',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Legacy gap intermediate',
        dueAt: original.due.at!.add(const Duration(days: 1)),
        memo: original.summary,
      ),
    );
    final localTipDueAt = original.due.at!.add(const Duration(days: 2));
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 3)),
      createId: () => 'legacy-gap-retained-tip',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 2,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Legacy gap retained local tip',
        dueAt: localTipDueAt,
        memo: original.summary,
      ),
    );
    await (db.delete(db.syncQueueEntries)
          ..where(
              (row) => row.clientMutationId.equals('legacy-gap-pruned-edit')))
        .go();
    await _downgradeEmailProvenanceFixture(
      db,
      candidateId: confirmed.candidateId,
      schemaVersion: 14,
    );
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    var receipts = await db.select(db.emailScheduleEditReceipts).get();
    final legacyTip = receipts.singleWhere(
      (row) => row.provenance == 'legacy_trusted_tip',
    );
    expect(legacyTip.mutationId, 'legacy-gap-retained-tip');
    expect((legacyTip.baseEntityVersion, legacyTip.entityVersion), (1, 3));
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final create = await queue.claimNext(
      now: _now.add(const Duration(minutes: 10)),
    );
    expect(create?.operation, SyncOperation.create);
    await _ackPendingEmailMutation(
      db,
      create!,
      cursor: 1,
      acknowledgedAt: _now.add(const Duration(minutes: 10)),
    );
    final tip = await queue.claimNext(
      now: _now.add(const Duration(minutes: 11)),
    );
    expect(tip?.clientMutationId, 'legacy-gap-retained-tip');
    final canonicalAt = _now.add(const Duration(minutes: 12));
    final canonicalDueAt = original.due.at!.add(const Duration(days: 4));
    final canonicalPayload = <String, Object?>{
      ...tip!.payload,
      'title': 'Canonical legacy gap winner',
      'dueAt': canonicalDueAt.toIso8601String(),
      'updatedAt': canonicalAt.toIso8601String(),
      'deletedAt': null,
      'version': 3,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.acknowledge(
      tip,
      ScheduleMutationAck(
        clientMutationId: tip.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: SyncOperation.update,
        change: ScheduleDeltaChange(
          changeCursor: 2,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 3,
          payload: canonicalPayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: canonicalAt,
    );
    await store.resolveConflictServerWins(
      tip.clientMutationId,
      resolvedAt: canonicalAt,
    );
    receipts = await db.select(db.emailScheduleEditReceipts).get();
    expect(
      receipts
          .singleWhere((row) => row.mutationId == tip.clientMutationId)
          .provenance,
      'legacy_trusted_tip',
    );
    final winner = receipts.singleWhere(
      (row) => row.mutationId == 'server-wins:${tip.clientMutationId}',
    );
    expect(winner.provenance, 'server_wins');
    expect(
      (winner.baseEntityVersion, winner.entityVersion),
      (legacyTip.entityVersion, 3),
    );
    expect(winner.basePayloadFingerprint, legacyTip.payloadFingerprint);
    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.title, 'Canonical legacy gap winner');
    expect(assignment.dueAt.toUtc(), canonicalDueAt);
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => canonicalAt.add(const Duration(minutes: 1)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test(
      'retained v14 accepted gap tip appends server-wins and replays after pruning',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-accepted-legacy-gap-conflict-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(db);
    await _seedConnection(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Accepted legacy gap origin',
      summary: 'Accepted legacy gap memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 2)),
      createId: () => 'accepted-gap-pruned-edit',
    ).updateAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
      input: AssignmentInput(
        courseId: _courseA,
        title: 'Accepted gap intermediate edit',
        dueAt: original.due.at!.add(const Duration(days: 1)),
        memo: original.summary,
      ),
    );
    final proposed = _assignmentPayload(
      dueAt: original.due.at!.add(const Duration(days: 2)),
      title: 'Accepted legacy gap proposal',
      summary: 'Accepted proposal memo',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-accepted-legacy-gap',
        threadId: 'thread-assignment',
        contentHashCharacter: 'b',
        payload: proposed,
        receivedAt: _now.add(const Duration(minutes: 3)),
      ),
      cursor: 'cursor-accepted-legacy-gap',
    );
    final proposal = (await DriftEmailCandidateUpdateRepository(
      db: db,
      clock: () => _now.add(const Duration(minutes: 4)),
      authenticatedUserId: () => activeOwner,
    ).pending(ownerUserId: _ownerA))
        .single;
    final accepted = await DriftEmailCandidateUpdateRepository(
      db: db,
      clock: () => _now.add(const Duration(minutes: 4)),
      authenticatedUserId: () => activeOwner,
    ).accept(ownerUserId: _ownerA, updateId: proposal.id);
    expect(accepted.accepted, isTrue);
    final acceptedMutationId = const Uuid().v5(
      Namespace.url.value,
      'email-update-accept\u0000$_ownerA\u0000${proposal.id}',
    );
    await (db.delete(db.syncQueueEntries)
          ..where(
              (row) => row.clientMutationId.equals('accepted-gap-pruned-edit')))
        .go();
    await _downgradeEmailProvenanceFixture(
      db,
      candidateId: confirmed.candidateId,
      schemaVersion: 14,
    );
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    var receipts = await db.select(db.emailScheduleEditReceipts).get();
    final legacyTip = receipts.singleWhere(
      (row) => row.provenance == 'legacy_trusted_tip',
    );
    expect(legacyTip.mutationId, acceptedMutationId);
    expect((legacyTip.baseEntityVersion, legacyTip.entityVersion), (1, 3));
    expect(
      legacyTip.candidatePayloadFingerprint,
      emailCandidatePayloadFingerprint(proposed),
    );

    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final create = await queue.claimNext(
      now: _now.add(const Duration(minutes: 10)),
    );
    expect(create?.operation, SyncOperation.create);
    await _ackPendingEmailMutation(
      db,
      create!,
      cursor: 1,
      acknowledgedAt: _now.add(const Duration(minutes: 10)),
    );
    final tip = await queue.claimNext(
      now: _now.add(const Duration(minutes: 11)),
    );
    expect(tip?.clientMutationId, acceptedMutationId);
    final canonicalAt = _now.add(const Duration(minutes: 12));
    final canonicalDueAt = original.due.at!.add(const Duration(days: 4));
    final canonicalPayload = <String, Object?>{
      ...tip!.payload,
      'title': 'Canonical accepted legacy gap winner',
      'dueAt': canonicalDueAt.toIso8601String(),
      'memo': 'Canonical accepted winner memo',
      'updatedAt': canonicalAt.toIso8601String(),
      'deletedAt': null,
      'version': 3,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.acknowledge(
      tip,
      ScheduleMutationAck(
        clientMutationId: tip.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: SyncOperation.update,
        change: ScheduleDeltaChange(
          changeCursor: 2,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 3,
          payload: canonicalPayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: canonicalAt,
    );
    await store.resolveConflictServerWins(
      tip.clientMutationId,
      resolvedAt: canonicalAt,
    );

    receipts = await db.select(db.emailScheduleEditReceipts).get();
    expect(
      receipts
          .singleWhere((row) => row.mutationId == acceptedMutationId)
          .provenance,
      'legacy_trusted_tip',
    );
    final winner = receipts.singleWhere(
      (row) => row.mutationId == 'server-wins:$acceptedMutationId',
    );
    expect(winner.provenance, 'server_wins');
    expect(
      (winner.baseEntityVersion, winner.entityVersion),
      (legacyTip.entityVersion, 3),
    );
    expect(winner.basePayloadFingerprint, legacyTip.payloadFingerprint);
    final superseded = await db.emailImportDao.candidateUpdateById(
      ownerUserId: _ownerA,
      updateId: proposal.id,
    );
    expect(superseded?.state, 'superseded');
    expect(
      superseded?.resolutionIdempotencyKey,
      'email-update-server-wins-reject:${proposal.id}',
    );
    final rejection = (await (db.select(db.emailReconciliationReceipts)
              ..where((row) => row.action.equals('update')))
            .get())
        .single;
    expect(rejection.resolution, 'rejected');
    expect(rejection.requiredSyncMutationId, isNull);

    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.title, 'Canonical accepted legacy gap winner');
    expect(assignment.dueAt.toUtc(), canonicalDueAt);
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: _ownerA,
      candidateId: confirmed.candidateId,
    );
    final aligned = const EmailCandidatePayloadCodec().decode(
      candidate!.normalizedPayloadJson,
    );
    expect(aligned.title, assignment.title);
    expect(aligned.due.at, assignment.dueAt.toUtc());
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => canonicalAt.add(const Duration(minutes: 1)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test(
      'retained schema12 accepted A-to-B update reconstructs origin and drains after upgrade',
      () async {
    await db.close();
    final directory = await Directory.systemTemp.createTemp(
      'email-edit-legacy-v12-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    db = local.AppDatabase(NativeDatabase(file));
    await _seedScheduleContext(db);
    await _seedConnection(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Schema12 original A',
      summary: 'Original memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final proposed = _assignmentPayload(
      dueAt: original.due.at!.add(const Duration(days: 4)),
      title: 'Schema12 accepted B',
      summary: 'Accepted memo',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-schema12-b',
        threadId: 'thread-assignment',
        contentHashCharacter: 'b',
        payload: proposed,
      ),
      cursor: 'cursor-schema12-b',
    );
    final proposal = (await db.select(db.emailCandidateUpdates).get()).single;
    final accepted = await DriftEmailCandidateUpdateRepository(
      db: db,
      clock: () => _now.add(const Duration(minutes: 3)),
      authenticatedUserId: () => activeOwner,
    ).accept(ownerUserId: _ownerA, updateId: proposal.id);
    expect(accepted.accepted, isTrue);
    await _downgradeEmailProvenanceFixture(
      db,
      candidateId: confirmed.candidateId,
      schemaVersion: 12,
      dropReconciliationReceipts: true,
    );
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    final migrated = await db.select(db.emailScheduleEditReceipts).get();
    expect(migrated.map((row) => row.provenance).toSet(), {
      'confirmation',
      'accepted_update',
    });
    final reviewed = (await (db.select(db.emailReconciliationReceipts)
              ..where((row) => row.action.equals('confirmation')))
            .getSingle())
        .reviewedPayloadJson;
    expect(
      const EmailCandidatePayloadCodec().decode(reviewed!).title,
      original.title,
      reason: 'v15 reverses the accepted diff instead of trusting current B',
    );
    await _ackAllPendingEmailMutations(db);
    await (db.delete(db.syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(_ownerA)))
        .go();
    final replay = await DriftEmailCandidateConfirmationGateway(
      db: db,
      clock: () => _now.add(const Duration(minutes: 10)),
      authenticatedUserId: () => activeOwner,
    ).confirm(
      ownerUserId: _ownerA,
      candidateId: confirmed.candidateId,
      courseId: _courseA,
    );
    expect(replay.replayed, isTrue);
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.title, proposed.title);
    expect(assignment.dueAt.toUtc(), proposed.due.at);

    await db.close();
    db = local.AppDatabase(NativeDatabase.memory());
    await directory.delete(recursive: true);
  });

  test('accepted replay follows a canonical timestamp ACK descendant',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Accepted ACK origin',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final proposed = _assignmentPayload(
      dueAt: original.due.at!.add(const Duration(days: 1)),
      title: 'Accepted ACK proposal',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-accepted-ack',
        threadId: 'thread-assignment',
        contentHashCharacter: 'b',
        payload: proposed,
      ),
      cursor: 'cursor-accepted-ack',
    );
    final proposal = (await db.select(db.emailCandidateUpdates).get()).single;
    final repository = DriftEmailCandidateUpdateRepository(
      db: db,
      clock: () => _now.add(const Duration(minutes: 3)),
      authenticatedUserId: () => activeOwner,
    );
    await repository.accept(ownerUserId: _ownerA, updateId: proposal.id);
    await _ackAllPendingEmailMutations(db);
    expect(
      (await db.select(db.emailScheduleEditReceipts).get())
          .where((row) => row.provenance == 'remote_ack'),
      isNotEmpty,
    );
    final replay = await repository.accept(
      ownerUserId: _ownerA,
      updateId: proposal.id,
    );
    expect(replay.replayed, isTrue);
    expect(replay.entityId, confirmed.entityId);
  });

  test('email-linked local delete ACK authenticates the full tombstone',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Delete ACK origin',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await _ackAllPendingEmailMutations(db);
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 20)),
      createId: () => 'email-delete-ack',
    ).deleteAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
    );
    await _ackAllPendingEmailMutations(db);
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.version, 2);
    expect(assignment.deletedAt, isNotNull);
    expect(
      (await db.select(db.notificationScheduleRequests).get()).single.state,
      'cancelled',
    );
    final receipts = await db.select(db.emailScheduleEditReceipts).get();
    expect(
      receipts
          .singleWhere((row) => row.mutationId == 'email-delete-ack')
          .provenance,
      'user_edit',
    );
    expect(
      receipts.where((row) => row.mutationId == 'remote-ack:email-delete-ack'),
      hasLength(1),
    );
  });

  test('local delete conflict server-wins restores the active chain tip',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Delete conflict origin',
      summary: 'Still active remotely',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await _ackAllPendingEmailMutations(db);
    await DriftScheduleRepository(
      db,
      clock: () => _now.add(const Duration(minutes: 20)),
      createId: () => 'email-delete-conflict',
    ).deleteAssignment(
      assignmentId: confirmed.entityId,
      ownerUserId: _ownerA,
      expectedVersion: 1,
    );
    final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
    final deletion = await queue.claimNext(
      now: _now.add(const Duration(minutes: 21)),
    );
    expect(deletion, isNotNull);
    final canonicalAt = _now.add(const Duration(minutes: 22));
    final canonicalPayload = {
      'id': confirmed.entityId,
      'ownerUserId': _ownerA,
      'courseId': _courseA,
      'title': original.title,
      'dueAt': original.due.at!.toIso8601String(),
      'submissionUrl': original.submissionUrl,
      'memo': original.summary,
      'priority': null,
      'visibilityLevel': 'PRIVATE',
      'updatedAt': canonicalAt.toIso8601String(),
      'deletedAt': null,
      'version': 2,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.acknowledge(
      deletion!,
      ScheduleMutationAck(
        clientMutationId: deletion.clientMutationId,
        outcome: ScheduleMutationOutcome.conflict,
        entityType: 'assignment',
        entityId: confirmed.entityId,
        operation: SyncOperation.delete,
        change: ScheduleDeltaChange(
          changeCursor: 20,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: ScheduleDeltaOperation.upsert,
          serverVersion: 2,
          payload: canonicalPayload,
        ),
        replayed: false,
      ),
      acknowledgedAt: canonicalAt,
    );
    await store.resolveConflictServerWins(
      deletion.clientMutationId,
      resolvedAt: canonicalAt.add(const Duration(minutes: 1)),
    );
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.deletedAt, isNull);
    expect(assignment.version, 2);
    expect(assignment.title, original.title);
    expect(
      (await db.select(db.notificationScheduleRequests).get()).single.state,
      'pending',
    );
    expect(
      (await db.select(db.emailScheduleEditReceipts).get())
          .singleWhere((row) => row.mutationId == 'email-delete-conflict')
          .provenance,
      'server_wins',
    );
    expect(
      (await DriftEmailCandidateConfirmationGateway(
        db: db,
        clock: () => canonicalAt.add(const Duration(minutes: 2)),
        authenticatedUserId: () => activeOwner,
      ).confirm(
        ownerUserId: _ownerA,
        candidateId: confirmed.candidateId,
        courseId: _courseA,
      ))
          .replayed,
      isTrue,
    );
  });

  test(
      'remote full tombstone jump applies changed fields and sparse replay retains them',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      title: 'Remote tombstone origin',
      summary: 'Original memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    await _ackAllPendingEmailMutations(db);
    final deletedAt = _now.add(const Duration(minutes: 30));
    final changedDueAt = original.due.at!.add(const Duration(days: 4));
    final fullTombstone = <String, Object?>{
      'id': confirmed.entityId,
      'ownerUserId': _ownerA,
      'courseId': null,
      'title': 'Remote v2 title retained by v3 tombstone',
      'dueAt': changedDueAt.toIso8601String(),
      'submissionUrl': null,
      'memo': 'Remote v2 memo',
      'priority': 'HIGH',
      'visibilityLevel': 'PRIVATE',
      'updatedAt': deletedAt.toIso8601String(),
      'deletedAt': deletedAt.toIso8601String(),
      'version': 3,
    };
    final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 0,
        nextCursor: 1,
        hasMore: false,
        changes: [
          ScheduleDeltaChange(
            changeCursor: 1,
            entityType: 'assignment',
            entityId: confirmed.entityId,
            operation: ScheduleDeltaOperation.delete,
            serverVersion: 3,
            deletedAt: deletedAt,
            payload: fullTombstone,
          ),
        ],
      ),
    );
    var assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.version, 3);
    expect(assignment.deletedAt?.toUtc(), deletedAt);
    expect(assignment.courseId, isNull);
    expect(assignment.title, 'Remote v2 title retained by v3 tombstone');
    expect(assignment.dueAt.toUtc(), changedDueAt);
    expect(assignment.description, 'Remote v2 memo');
    expect(assignment.priority, 'HIGH');
    expect(
      (await db.select(db.emailScheduleEditReceipts).get())
          .singleWhere((row) => row.provenance == 'remote_apply')
          .payloadFingerprint,
      emailSchedulePayloadFingerprint(fullTombstone),
    );

    final sparseReplay = <String, Object?>{
      'id': confirmed.entityId,
      'ownerUserId': _ownerA,
      'updatedAt': deletedAt.toIso8601String(),
      'deletedAt': deletedAt.toIso8601String(),
      'version': 3,
    };
    await store.applyDeltaPage(
      ScheduleDeltaPage(
        afterCursor: 1,
        nextCursor: 2,
        hasMore: false,
        changes: [
          ScheduleDeltaChange(
            changeCursor: 2,
            entityType: 'assignment',
            entityId: confirmed.entityId,
            operation: ScheduleDeltaOperation.delete,
            serverVersion: 3,
            deletedAt: deletedAt,
            payload: sparseReplay,
          ),
        ],
      ),
    );
    assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    expect(assignment.title, 'Remote v2 title retained by v3 tombstone');
    expect(assignment.courseId, isNull);
    expect(assignment.description, 'Remote v2 memo');
    expect(await store.cursor(), 2);
  });

  for (final fullTombstone in [true, false]) {
    test(
        'server-wins ${fullTombstone ? 'full tombstone applies remote changed fields' : 'sparse tombstone retains authenticated local fields'}',
        () async {
      final original = _assignmentPayload(
        dueAt: DateTime.utc(2030, 4, 10, 14, 59),
        title: 'Server-wins tombstone origin',
        summary: 'Original memo',
      );
      final confirmed = await _syncAndConfirm(
        db,
        activeOwner: () => activeOwner,
        payload: original,
      );
      await _ackAllPendingEmailMutations(db);
      final localDueAt = original.due.at!.add(const Duration(days: 1));
      final mutationId = fullTombstone
          ? 'server-wins-full-tombstone'
          : 'server-wins-sparse-tombstone';
      await DriftScheduleRepository(
        db,
        clock: () => _now.add(const Duration(minutes: 20)),
        createId: () => mutationId,
      ).updateAssignment(
        assignmentId: confirmed.entityId,
        ownerUserId: _ownerA,
        expectedVersion: 1,
        input: AssignmentInput(
          courseId: _courseA,
          title: 'Local v2 title',
          dueAt: localDueAt,
          submissionUrl: original.submissionUrl,
          memo: 'Local v2 memo',
        ),
      );
      final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
      final mutation = await queue.claimNext(
        now: _now.add(const Duration(minutes: 21)),
      );
      expect(mutation?.clientMutationId, mutationId);
      final deletedAt = _now.add(const Duration(minutes: 22));
      final remoteDueAt = original.due.at!.add(const Duration(days: 5));
      final payload = <String, Object?>{
        'id': confirmed.entityId,
        'ownerUserId': _ownerA,
        if (fullTombstone) ...{
          'courseId': null,
          'title': 'Remote changed title',
          'dueAt': remoteDueAt.toIso8601String(),
          'submissionUrl': null,
          'memo': 'Remote changed memo',
          'priority': 'LOW',
          'visibilityLevel': 'PRIVATE',
        },
        'updatedAt': deletedAt.toIso8601String(),
        'deletedAt': deletedAt.toIso8601String(),
        'version': 3,
      };
      final store = DriftScheduleSyncStore(db, ownerUserId: _ownerA);
      await store.acknowledge(
        mutation!,
        ScheduleMutationAck(
          clientMutationId: mutation.clientMutationId,
          outcome: ScheduleMutationOutcome.conflict,
          entityType: 'assignment',
          entityId: confirmed.entityId,
          operation: SyncOperation.update,
          change: ScheduleDeltaChange(
            changeCursor: 30,
            entityType: 'assignment',
            entityId: confirmed.entityId,
            operation: ScheduleDeltaOperation.delete,
            serverVersion: 3,
            deletedAt: deletedAt,
            payload: payload,
          ),
          replayed: false,
        ),
        acknowledgedAt: deletedAt,
      );
      await store.resolveConflictServerWins(
        mutation.clientMutationId,
        resolvedAt: deletedAt.add(const Duration(minutes: 1)),
      );
      final assignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(confirmed.entityId)))
          .getSingle();
      expect(assignment.version, 3);
      expect(assignment.deletedAt?.toUtc(), deletedAt);
      expect(
        assignment.title,
        fullTombstone ? 'Remote changed title' : 'Local v2 title',
      );
      expect(assignment.courseId, fullTombstone ? isNull : _courseA);
      expect(
        assignment.dueAt.toUtc(),
        fullTombstone ? remoteDueAt : localDueAt,
      );
      expect(
        assignment.description,
        fullTombstone ? 'Remote changed memo' : 'Local v2 memo',
      );
      final actualPayload = <String, Object?>{
        'id': assignment.id,
        'ownerUserId': assignment.ownerUserId,
        'courseId': assignment.courseId,
        'title': assignment.title,
        'dueAt': assignment.dueAt,
        'submissionUrl': assignment.submissionUrl,
        'memo': assignment.description,
        'priority': assignment.priority,
        'visibilityLevel': assignment.visibilityLevel,
        'updatedAt': assignment.updatedAt,
        'deletedAt': assignment.deletedAt,
        'version': assignment.version,
      };
      expect(
        (await db.select(db.emailScheduleEditReceipts).get())
            .singleWhere((row) => row.mutationId == mutationId)
            .payloadFingerprint,
        emailSchedulePayloadFingerprint(actualPayload),
      );
      expect(
        (await db.select(db.notificationScheduleRequests).get()).single.state,
        'cancelled',
      );
    });
  }

  test('outbox failure rolls back acceptance and stale base never overwrites',
      () async {
    final original = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 10, 14, 59),
      summary: 'Original memo',
    );
    final confirmed = await _syncAndConfirm(
      db,
      activeOwner: () => activeOwner,
      payload: original,
    );
    final firstChange = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 12, 14, 59),
      summary: 'First change',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-first-change',
        threadId: 'thread-assignment',
        contentHashCharacter: 'b',
        payload: firstChange,
      ),
      cursor: 'cursor-first-change',
    );
    var pending = (await db.select(db.emailCandidateUpdates).get()).single;
    final repository = DriftEmailCandidateUpdateRepository(
      db: db,
      clock: () => _now.add(const Duration(minutes: 3)),
      authenticatedUserId: () => activeOwner,
    );
    await db.customStatement('''
      CREATE TRIGGER force_email_update_outbox_failure
      BEFORE INSERT ON sync_queue_entries
      FOR EACH ROW
      WHEN NEW.operation = 'update'
      BEGIN
        SELECT RAISE(ABORT, 'forced update outbox failure');
      END
    ''');
    await expectLater(
      repository.accept(ownerUserId: _ownerA, updateId: pending.id),
      throwsA(anything),
    );
    expect(
      (await db.select(db.assignments).get()).single.dueAt.toUtc(),
      original.due.at,
    );
    expect(
      (await db.select(db.emailCandidates).get()).single.normalizedPayloadJson,
      const EmailCandidatePayloadCodec().encode(original),
    );
    expect(
      (await db.select(db.emailCandidateUpdates).get()).single.state,
      'pending',
    );
    expect(
      (await db.select(db.notificationScheduleRequests).get())
          .single
          .anchorAt
          .toUtc(),
      original.due.at,
    );
    expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(1));

    await db.customStatement('DROP TRIGGER force_email_update_outbox_failure');
    await repository.accept(ownerUserId: _ownerA, updateId: pending.id);
    expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(2));

    final secondChange = _assignmentPayload(
      dueAt: DateTime.utc(2030, 4, 14, 14, 59),
      summary: 'Second change',
    );
    await _sync(
      db,
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      activeOwner: () => activeOwner,
      item: _item(
        messageId: 'message-second-change',
        threadId: 'thread-assignment',
        contentHashCharacter: 'c',
        payload: secondChange,
      ),
      cursor: 'cursor-second-change',
    );
    pending = (await db.select(db.emailCandidateUpdates).get())
        .singleWhere((row) => row.state == 'pending');
    final entity = await (db.select(db.assignments)
          ..where((row) => row.id.equals(confirmed.entityId)))
        .getSingle();
    await (db.update(db.assignments)..where((row) => row.id.equals(entity.id)))
        .write(
      local.AssignmentsCompanion(
        title: const Value('Manual edit wins'),
        version: Value(entity.version + 1),
        updatedAt: Value(_now.add(const Duration(minutes: 4))),
      ),
    );

    await expectLater(
      repository.accept(ownerUserId: _ownerA, updateId: pending.id),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
    final afterRace = await (db.select(db.assignments)
          ..where((row) => row.id.equals(entity.id)))
        .getSingle();
    expect(afterRace.title, 'Manual edit wins');
    expect(afterRace.dueAt.toUtc(), firstChange.due.at);
    expect(afterRace.version, 3);
    expect(await db.syncQueueDao.allMutations(_ownerA), hasLength(2));
    expect(
      (await db.select(db.emailCandidateUpdates).get())
          .singleWhere((row) => row.id == pending.id)
          .state,
      'pending',
    );
  });
}

Future<_ConfirmedAssignment> _syncAndConfirm(
  local.AppDatabase db, {
  required String Function() activeOwner,
  required EmailCandidatePayload payload,
}) async {
  await _sync(
    db,
    ownerUserId: _ownerA,
    connectionId: _connectionA,
    activeOwner: activeOwner,
    item: _item(
      messageId: 'message-original',
      threadId: 'thread-assignment',
      contentHashCharacter: 'a',
      payload: payload,
    ),
    cursor: 'cursor-original',
  );
  final candidate = (await db.select(db.emailCandidates).get()).single;
  final result = await DriftEmailCandidateConfirmationGateway(
    db: db,
    clock: () => _now.add(const Duration(minutes: 1)),
    authenticatedUserId: activeOwner,
  ).confirm(
    ownerUserId: _ownerA,
    candidateId: candidate.id,
    courseId: _courseA,
  );
  return _ConfirmedAssignment(
    candidateId: candidate.id,
    entityId: result.entityId,
  );
}

Future<void> _downgradeEmailProvenanceFixture(
  local.AppDatabase db, {
  required String candidateId,
  required int schemaVersion,
  bool dropReconciliationReceipts = false,
}) async {
  final legacyKey = const Uuid().v5(
    Namespace.url.value,
    'email-confirmation\u0000$_ownerA\u0000$candidateId',
  );
  await db
      .customStatement('DROP TRIGGER IF EXISTS email_schedule_links_immutable');
  await db.customStatement(
    'DROP TRIGGER IF EXISTS notification_requests_guard_update',
  );
  await db.customStatement(
    'DROP TRIGGER IF EXISTS email_reconciliation_values_guard_update',
  );
  await (db.update(db.emailCandidates)
        ..where((row) => row.id.equals(candidateId)))
      .write(
    local.EmailCandidatesCompanion(
      confirmationIdempotencyKey: Value(legacyKey),
    ),
  );
  await (db.update(db.emailScheduleEntityLinks)
        ..where((row) => row.candidateId.equals(candidateId)))
      .write(
    local.EmailScheduleEntityLinksCompanion(
      confirmationIdempotencyKey: Value(legacyKey),
    ),
  );
  await (db.update(db.notificationScheduleRequests)
        ..where((row) => row.sourceId.equals(candidateId)))
      .write(
    local.NotificationScheduleRequestsCompanion(
      idempotencyKey: Value(legacyKey),
    ),
  );
  await (db.update(db.syncQueueEntries)
        ..where((row) =>
            row.ownerUserId.equals(_ownerA) & row.operation.equals('create')))
      .write(
    local.SyncQueueEntriesCompanion(idempotencyKey: Value(legacyKey)),
  );
  if (!dropReconciliationReceipts) {
    await (db.update(db.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(_ownerA) &
              row.action.equals('confirmation')))
        .write(
      local.EmailReconciliationReceiptsCompanion(
        idempotencyKey: Value(legacyKey),
      ),
    );
  }
  await db.customStatement('DROP TABLE email_schedule_edit_receipts');
  if (dropReconciliationReceipts) {
    await db.customStatement('DROP TABLE email_reconciliation_receipts');
  }
  await db.customStatement('PRAGMA user_version = $schemaVersion');
}

Future<void> _ackAllPendingEmailMutations(local.AppDatabase db) async {
  final queue = DriftSyncQueue(db, ownerUserId: _ownerA);
  var cursor = 1;
  while (true) {
    final acknowledgedAt = _now.add(Duration(minutes: 10 + cursor));
    final mutation = await queue.claimNext(now: acknowledgedAt);
    if (mutation == null) return;
    await _ackPendingEmailMutation(
      db,
      mutation,
      cursor: cursor,
      acknowledgedAt: acknowledgedAt,
    );
    cursor += 1;
  }
}

Future<void> _ackPendingEmailMutation(
  local.AppDatabase db,
  PendingMutation mutation, {
  required int cursor,
  required DateTime acknowledgedAt,
}) async {
  final version = mutation.payload['version']! as int;
  final canonicalPayload = <String, Object?>{
    ...mutation.payload,
    'updatedAt': acknowledgedAt.toUtc().toIso8601String(),
    'deletedAt': mutation.operation == SyncOperation.delete
        ? acknowledgedAt.toUtc().toIso8601String()
        : null,
    'version': version,
  };
  await DriftScheduleSyncStore(db, ownerUserId: _ownerA).acknowledge(
    mutation,
    ScheduleMutationAck(
      clientMutationId: mutation.clientMutationId,
      outcome: ScheduleMutationOutcome.applied,
      entityType: mutation.entityType,
      entityId: mutation.entityId,
      operation: mutation.operation,
      change: ScheduleDeltaChange(
        changeCursor: cursor,
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
    acknowledgedAt: acknowledgedAt,
  );
}

Future<void> _exerciseFailedSiblingUpdateConversion({
  required local.AppDatabase db,
  required String Function() activeOwner,
  required bool targeted,
}) async {
  final original = _assignmentPayload(
    dueAt: DateTime.utc(2030, 4, 10, 14, 59),
    summary: 'Original confirmed memo',
  );
  final confirmed = await _syncAndConfirm(
    db,
    activeOwner: activeOwner,
    payload: original,
  );
  final failed = _failedItem(
    messageId: 'message-failed-update',
    contentHashCharacter: 'f',
    receivedAt: _now.add(const Duration(minutes: 2)),
  );
  await _sync(
    db,
    ownerUserId: _ownerA,
    connectionId: _connectionA,
    activeOwner: activeOwner,
    item: failed,
    cursor: 'cursor-after-failed-update',
  );
  expect(
    (await db.select(db.emailCandidates).get())
        .where((candidate) => candidate.reviewState == 'failed'),
    hasLength(1),
  );

  final correction = _assignmentPayload(
    dueAt: DateTime.utc(2030, 4, 12, 14, 59),
    summary: 'Successful retry correction',
  );
  final success = _item(
    messageId: 'message-failed-update',
    threadId: 'thread-assignment',
    contentHashCharacter: 'f',
    payload: correction,
    receivedAt: failed.receivedAt,
  );
  final service = EmailImportSyncService(
    db: db,
    connector: _OnePageConnector(
      success,
      'cursor-after-successful-update',
    ),
    clock: () => _now.add(const Duration(minutes: 3)),
    authenticatedUserId: activeOwner,
  );
  if (targeted) {
    await service.persistTargetedRetryItem(
      ownerUserId: _ownerA,
      connectionId: _connectionA,
      item: success,
    );
  } else {
    await service.synchronize(
      ownerUserId: _ownerA,
      connectionId: _connectionA,
    );
  }

  final candidates = await db.select(db.emailCandidates).get();
  expect(candidates, hasLength(1));
  expect(candidates.single.id, confirmed.candidateId);
  expect(candidates.single.reviewState, 'confirmed');
  final pending = await db.emailImportDao.pendingUpdates(
    ownerUserId: _ownerA,
    candidateId: confirmed.candidateId,
  );
  expect(pending, hasLength(1));
  expect(
    pending.single.proposedPayloadJson,
    const EmailCandidatePayloadCodec().encode(correction),
  );
  expect((await db.select(db.assignments).get()).single.dueAt.toUtc(),
      original.due.at);
  final connection = await db.emailImportDao.connectionById(
    ownerUserId: _ownerA,
    connectionId: _connectionA,
  );
  expect(
    connection?.cursor,
    targeted ? 'cursor-after-failed-update' : 'cursor-after-successful-update',
  );
}

Future<void> _sync(
  local.AppDatabase db, {
  required String ownerUserId,
  required String connectionId,
  required String? Function() activeOwner,
  required EmailFetchItem item,
  required String cursor,
}) async {
  await EmailImportSyncService(
    db: db,
    connector: _OnePageConnector(item, cursor),
    clock: () => _now,
    authenticatedUserId: activeOwner,
  ).synchronize(
    ownerUserId: ownerUserId,
    connectionId: connectionId,
  );
}

Future<void> _seedConnection(
  local.AppDatabase db, {
  required String ownerUserId,
  required String connectionId,
}) {
  return db.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: local.EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: ownerUserId,
      provider: EmailProvider.gmail.wireName,
      providerAccountHash: 'b' * 64,
      state: const Value('connected'),
      createdAt: Value(_now),
      updatedAt: Value(_now),
    ),
  );
}

Future<void> _seedScheduleContext(local.AppDatabase db) async {
  await db.into(db.universities).insert(
        local.UniversitiesCompanion.insert(
          id: 'university-a',
          name: 'Test University',
          normalizedName: 'test university',
          status: const Value('active'),
          updatedAt: Value(_now),
        ),
        mode: InsertMode.insertOrIgnore,
      );
  await db.into(db.terms).insert(
        local.TermsCompanion.insert(
          id: 'term-a',
          universityId: 'university-a',
          ownerUserId: const Value(_ownerA),
          name: '2030 Spring',
          academicYear: 2030,
          startDate: DateTime.utc(2030, 4, 1),
          endDate: DateTime.utc(2030, 9, 30),
          termType: 'semester',
          isTemplate: const Value(false),
          status: const Value('active'),
          updatedAt: Value(_now),
        ),
      );
  await db.into(db.profiles).insert(
        local.ProfilesCompanion.insert(
          userId: _ownerA,
          displayName: 'Owner A',
          universityId: const Value('university-a'),
          activeTermId: const Value('term-a'),
          primaryCalendarId: const Value(_calendarA),
          onboardingStatus: const Value('complete'),
          onboardingStep: const Value('complete'),
          onboardingCompletedAt: Value(_now),
          updatedAt: Value(_now),
        ),
      );
  await db.into(db.calendars).insert(
        local.CalendarsCompanion.insert(
          id: _calendarA,
          ownerUserId: _ownerA,
          name: 'Personal',
          defaultVisibility: const Value('PRIVATE'),
          updatedAt: Value(_now),
        ),
      );
  await db.into(db.userCourses).insert(
        local.UserCoursesCompanion.insert(
          id: _courseA,
          ownerUserId: _ownerA,
          termId: 'term-a',
          title: 'Information Mathematics',
          normalizedTitle: 'information mathematics',
          dayOfWeek: const Value(DateTime.monday),
          periodNo: const Value(1),
          visibilityLevel: const Value('PRIVATE'),
          updatedAt: Value(_now),
        ),
      );
}

EmailFetchItem _item({
  required String messageId,
  required String threadId,
  required String contentHashCharacter,
  required EmailCandidatePayload payload,
  DateTime? receivedAt,
}) {
  return EmailFetchItem(
    providerMessageId: messageId,
    providerThreadId: threadId,
    receivedAt: receivedAt ?? _now,
    sanitizedContentHash: contentHashCharacter * 64,
    evidenceExcerpts: const ['Sanitized deadline excerpt'],
    candidate: payload,
  );
}

EmailFetchItem _failedItem({
  required String messageId,
  required String contentHashCharacter,
  required DateTime receivedAt,
}) {
  return EmailFetchItem(
    providerMessageId: messageId,
    providerThreadId: 'failed:${'d' * 64}',
    receivedAt: receivedAt,
    sanitizedContentHash: contentHashCharacter * 64,
    evidenceExcerpts: const [],
    candidate: null,
    errorCategory: EmailErrorCategory.timeout,
  );
}

EmailCandidatePayload _assignmentPayload({
  required DateTime dueAt,
  String title = 'Report assignment',
  String? summary,
  List<int> reminders = const [180],
}) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: EmailCandidateType.assignment,
    title: title,
    courseHint: const EmailCourseHint(
      name: 'Information Mathematics',
      code: 'CS101',
    ),
    due: EmailDueCandidate(
      at: dueAt,
      timezone: japanTimeZone,
      rawText: 'sanitized deadline',
    ),
    submissionUrl: 'https://lms.example.edu/assignments/1',
    summary: summary,
    suggestedRemindersMinutes: reminders,
    confidence: const EmailCandidateConfidence(
      overall: 0.95,
      title: 0.95,
      course: 0.9,
      dateTime: 0.95,
    ),
    requiresUserConfirmation: true,
  );
}

EmailCandidatePayload _eventPayload({required String timezone}) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: EmailCandidateType.event,
    title: 'Imported seminar',
    courseHint: const EmailCourseHint(),
    due: EmailDueCandidate(
      timezone: timezone,
      rawText: 'sanitized event time',
    ),
    startAt: DateTime.utc(2030, 5, 10, 14),
    endAt: DateTime.utc(2030, 5, 10, 15),
    location: 'Online',
    summary: 'Guest seminar',
    suggestedRemindersMinutes: const [60],
    confidence: const EmailCandidateConfidence(
      overall: 0.95,
      title: 0.95,
      course: 0.9,
      dateTime: 0.95,
    ),
    requiresUserConfirmation: true,
  );
}

final class _OnePageConnector implements EmailConnector {
  _OnePageConnector(this.item, this.cursor);

  final EmailFetchItem item;
  final String cursor;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async => const EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.connected,
      );

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {}

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async => EmailFetchPage(
        items: [item],
        nextCursor: this.cursor,
        hasMore: false,
      );
}

final class _ManyItemPageConnector implements EmailConnector {
  _ManyItemPageConnector(this.items, this.cursor);

  final List<EmailFetchItem> items;
  final String cursor;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async => const EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.connected,
      );

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {}

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async => EmailFetchPage(
        items: items,
        nextCursor: this.cursor,
        hasMore: false,
      );
}

final class _EmailReconciliationGateway implements EmailReconciliationGateway {
  final requests = <EmailReconciliationRequest>[];

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    requests.add(request);
    return EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: switch (request.action) {
        EmailReconciliationAction.confirmation =>
          EmailReconciliationOutcome.confirmed,
        EmailReconciliationAction.dismissal =>
          EmailReconciliationOutcome.dismissed,
        EmailReconciliationAction.update =>
          request.resolution == EmailReconciliationResolution.accepted
              ? EmailReconciliationOutcome.accepted
              : EmailReconciliationOutcome.rejected,
      },
      entityType: request.entityType,
      entityId: request.entityId,
      replayed: false,
    );
  }
}

class _ConfirmedAssignment {
  const _ConfirmedAssignment({
    required this.candidateId,
    required this.entityId,
  });

  final String candidateId;
  final String entityId;
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
