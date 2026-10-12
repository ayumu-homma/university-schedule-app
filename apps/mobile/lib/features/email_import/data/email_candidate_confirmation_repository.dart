import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:uuid/uuid.dart';

import '../../../core/sync/drift_sync_queue.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database.dart' as local;
import '../../../local_db/email_import_identity.dart';
import '../domain/email_review_models.dart';
import '../domain/email_timezone.dart';
import 'email_candidate_dedupe.dart';

class EmailCandidateConfirmationItem {
  const EmailCandidateConfirmationItem({
    required this.candidateId,
    this.courseId,
  });

  final String candidateId;
  final String? courseId;
}

class EmailCandidateConfirmationFailure {
  const EmailCandidateConfirmationFailure({
    required this.candidateId,
    required this.category,
  });

  final String candidateId;
  final domain.EmailErrorCategory category;
}

/// Bulk confirmation commits one transaction per candidate. A failed item is
/// rolled back completely while independent successful items remain durable.
class EmailCandidateBulkConfirmationResult {
  const EmailCandidateBulkConfirmationResult({
    required this.confirmed,
    required this.failed,
  });

  final List<EmailCandidateConfirmationResult> confirmed;
  final List<EmailCandidateConfirmationFailure> failed;

  bool get hasPartialSuccess => confirmed.isNotEmpty && failed.isNotEmpty;
}

/// Materializes a reviewed email proposal into the existing canonical local
/// schedule model. The canonical entity, its derived calendar visibility, the
/// notification request boundary, source link, durable schedule outbox row,
/// and confirmed candidate state share one Drift transaction.
class DriftEmailCandidateConfirmationGateway
    implements EmailCandidateConfirmationGateway {
  DriftEmailCandidateConfirmationGateway({
    required this.db,
    required this.clock,
    required this.authenticatedUserId,
    this.lease,
    Uuid uuid = const Uuid(),
    domain.EmailCandidatePayloadCodec candidateCodec =
        const domain.EmailCandidatePayloadCodec(),
  })  : _uuid = uuid,
        _candidateCodec = candidateCodec;

  final local.AppDatabase db;
  final DateTime Function() clock;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final Uuid _uuid;
  final domain.EmailCandidatePayloadCodec _candidateCodec;

  @override
  Future<EmailCandidateConfirmationResult> confirm({
    required String ownerUserId,
    required String candidateId,
    String? courseId,
  }) {
    _requireIdentifier(ownerUserId, 'ownerUserId');
    _requireIdentifier(candidateId, 'candidateId');
    if (courseId != null) {
      _requireIdentifier(courseId, 'courseId');
    }
    _requireActiveOwner(ownerUserId);

    return db.transaction(() async {
      _requireActiveOwner(ownerUserId);
      final candidate = await db.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      if (candidate == null) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
      }

      final expectedEntityId = _stableId(
        'email-confirmed-entity',
        ownerUserId,
        candidateId,
      );
      final expectedMutationId = _stableId(
        'email-confirmed-mutation',
        ownerUserId,
        candidateId,
      );
      final expectedLinkId = _stableId(
        'email-confirmed-link',
        ownerUserId,
        candidateId,
      );
      final expectedNotificationId = _stableId(
        'email-confirmed-notification',
        ownerUserId,
        candidateId,
      );

      if (candidate.reviewState ==
          domain.EmailCandidateReviewState.confirmed.wireName) {
        final confirmedAt = candidate.confirmedAt;
        if (confirmedAt == null ||
            candidate.linkedEntityType == null ||
            candidate.linkedEntityId == null ||
            candidate.confirmationIdempotencyKey == null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        final existingReceipt = await _confirmationReceipt(
          ownerUserId: ownerUserId,
          candidateId: candidate.id,
        );
        final originalPayloadJson = existingReceipt?.reviewedPayloadJson ??
            candidate.normalizedPayloadJson;
        final originalPayload = _decodePayloadJson(originalPayloadJson);
        _validateMaterializablePayload(originalPayload, courseId: courseId);
        final confirmationReceipt = await _ensureConfirmationReceipt(
          ownerUserId: ownerUserId,
          candidateId: candidate.id,
          sourceId: candidate.sourceId,
          reviewedPayloadJson: originalPayloadJson,
          entityType: candidate.linkedEntityType!,
          entityId: candidate.linkedEntityId!,
          idempotencyKey: candidate.confirmationIdempotencyKey!,
          requiredSyncMutationId: expectedMutationId,
          createdAt: confirmedAt,
        );
        final replay = await _verifyCommittedConfirmation(
          ownerUserId: ownerUserId,
          candidate: candidate,
          originalPayload: originalPayload,
          confirmationReceipt: confirmationReceipt,
          requestedCourseId: courseId,
          expectedConfirmationKey: candidate.confirmationIdempotencyKey!,
          expectedEntityId: expectedEntityId,
          expectedMutationId: expectedMutationId,
          expectedLinkId: expectedLinkId,
          expectedNotificationId: expectedNotificationId,
        );
        _requireActiveOwner(ownerUserId);
        return replay;
      }
      if (candidate.reviewState !=
              domain.EmailCandidateReviewState.needsReview.wireName &&
          candidate.reviewState !=
              domain.EmailCandidateReviewState.readyForReview.wireName) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
      }

      final decodedPayload = _decodeAndValidateCandidate(candidate);
      final source = await db.emailImportDao.sourceById(
        ownerUserId: ownerUserId,
        sourceId: candidate.sourceId,
      );
      if (source == null) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      final context = await _requireActiveScheduleContext(ownerUserId);
      final effectiveTimezone = decodedPayload.due.timezone ?? context.timezone;
      final payload = _normalizeConfiguredTimezone(
        decodedPayload,
        effectiveTimezone,
      );
      _validateMaterializablePayload(payload, courseId: courseId);
      await _requireOwnedCourseIfPresent(
        ownerUserId: ownerUserId,
        courseId: courseId,
        activeTermId: context.activeTermId,
      );
      final expectedConfirmationKey = _confirmationIdempotencyKey(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        entityType: payload.candidateType,
        containerId: payload.candidateType == domain.EmailCandidateType.event
            ? context.primaryCalendarId
            : courseId,
      );
      await _requireNoConfirmationArtifacts(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        confirmationKey: expectedConfirmationKey,
        entityId: expectedEntityId,
        mutationId: expectedMutationId,
        linkId: expectedLinkId,
        notificationId: expectedNotificationId,
      );

      final now = emailScheduleSqliteTimestamp(clock());
      final mutationPayload = await _insertCanonicalEntity(
        ownerUserId: ownerUserId,
        entityId: expectedEntityId,
        courseId: courseId,
        primaryCalendarId: context.primaryCalendarId,
        payload: payload,
        now: now,
      );

      final canonicalPayloadJson = _candidateCodec.encode(payload);
      final candidateChanged = await (db.update(db.emailCandidates)
            ..where(
              (row) =>
                  row.id.equals(candidateId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.reviewState.equals(candidate.reviewState),
            ))
          .write(
        local.EmailCandidatesCompanion(
          candidateType: Value(payload.candidateType.wireName),
          normalizedPayloadJson: Value(canonicalPayloadJson),
          reviewState: Value(
            domain.EmailCandidateReviewState.confirmed.wireName,
          ),
          linkedEntityType: Value(payload.candidateType.wireName),
          linkedEntityId: Value(expectedEntityId),
          confirmationIdempotencyKey: Value(expectedConfirmationKey),
          errorCategory: const Value(null),
          confirmedAt: Value(now),
          dismissedAt: const Value(null),
          updatedAt: Value(now),
        ),
      );
      if (candidateChanged != 1) {
        throw StateError('Email candidate changed during confirmation.');
      }

      await db.into(db.emailScheduleEntityLinks).insert(
            local.EmailScheduleEntityLinksCompanion.insert(
              id: expectedLinkId,
              ownerUserId: ownerUserId,
              sourceId: source.id,
              candidateId: candidateId,
              entityType: payload.candidateType.wireName,
              entityId: expectedEntityId,
              confirmationIdempotencyKey: expectedConfirmationKey,
              createdAt: Value(now),
            ),
          );
      await db.into(db.notificationScheduleRequests).insert(
            local.NotificationScheduleRequestsCompanion.insert(
              id: expectedNotificationId,
              ownerUserId: ownerUserId,
              entityType: payload.candidateType.wireName,
              entityId: expectedEntityId,
              sourceId: candidateId,
              idempotencyKey: expectedConfirmationKey,
              anchorAt: _notificationAnchor(payload),
              allDay: Value(_notificationAllDay(payload)),
              timezone: Value(_notificationTimezone(payload)),
              remindersMinutesJson: Value(
                jsonEncode(payload.suggestedRemindersMinutes),
              ),
              targetPath: _targetPath(
                payload.candidateType,
                expectedEntityId,
              ),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      await DriftSyncQueue(db, ownerUserId: ownerUserId).enqueue(
        PendingMutation(
          clientMutationId: expectedMutationId,
          ownerUserId: ownerUserId,
          idempotencyKey: expectedConfirmationKey,
          entityType: payload.candidateType.wireName,
          entityId: expectedEntityId,
          operation: SyncOperation.create,
          payload: mutationPayload,
          createdAt: now,
        ),
      );
      final confirmationEntityPayload = emailScheduleReplayPayload(
        entityType: payload.candidateType,
        payload: mutationPayload,
      );
      final confirmationEntityFingerprint =
          emailSchedulePayloadFingerprint(confirmationEntityPayload);
      await db.into(db.emailScheduleEditReceipts).insert(
            local.EmailScheduleEditReceiptsCompanion.insert(
              mutationId: expectedMutationId,
              ownerUserId: ownerUserId,
              candidateId: candidateId,
              linkId: expectedLinkId,
              entityType: payload.candidateType.wireName,
              entityId: expectedEntityId,
              provenance: 'confirmation',
              baseEntityVersion: 0,
              entityVersion: 1,
              basePayloadFingerprint: confirmationEntityFingerprint,
              payloadFingerprint: confirmationEntityFingerprint,
              candidatePayloadFingerprint:
                  emailCandidatePayloadFingerprint(payload),
              entityUpdatedAt: now,
              createdAt: now,
            ),
          );
      await _ensureConfirmationReceipt(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        sourceId: source.id,
        reviewedPayloadJson: canonicalPayloadJson,
        entityType: payload.candidateType.wireName,
        entityId: expectedEntityId,
        idempotencyKey: expectedConfirmationKey,
        requiredSyncMutationId: expectedMutationId,
        createdAt: now,
      );
      _requireActiveOwner(ownerUserId);

      return EmailCandidateConfirmationResult(
        candidateId: candidateId,
        entityType: payload.candidateType,
        entityId: expectedEntityId,
        replayed: false,
      );
    });
  }

  Future<local.EmailReconciliationReceipt> _ensureConfirmationReceipt({
    required String ownerUserId,
    required String candidateId,
    required String sourceId,
    required String reviewedPayloadJson,
    required String entityType,
    required String entityId,
    required String idempotencyKey,
    required String requiredSyncMutationId,
    required DateTime createdAt,
  }) async {
    final source = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: sourceId,
    );
    final connection = source == null
        ? null
        : await db.emailImportDao.connectionById(
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
          );
    if (source == null ||
        connection == null ||
        source.processingState != 'processed' ||
        source.errorCategory != null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final receiptId = 'confirmation:$candidateId';
    final messageHash = emailProviderIdentifierHash(
      kind: 'message',
      provider: connection.provider,
      providerAccountHash: connection.providerAccountHash,
      rawIdentifier: source.providerMessageId,
    );
    final threadHash = emailProviderIdentifierHash(
      kind: 'thread',
      provider: connection.provider,
      providerAccountHash: connection.providerAccountHash,
      rawIdentifier: source.providerThreadId,
    );
    await db.into(db.emailReconciliationReceipts).insert(
          local.EmailReconciliationReceiptsCompanion.insert(
            id: receiptId,
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
            action: 'confirmation',
            localReferenceId: candidateId,
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            providerMessageIdHash: messageHash,
            providerThreadIdHash: threadHash,
            sanitizedContentHash: source.sanitizedContentHash,
            reviewedPayloadJson: Value(reviewedPayloadJson),
            entityType: Value(entityType),
            entityId: Value(entityId),
            idempotencyKey: idempotencyKey,
            requiredSyncMutationId: Value(requiredSyncMutationId),
            createdAt: Value(createdAt.toUtc()),
            updatedAt: Value(createdAt.toUtc()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final receipt = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals(receiptId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (receipt == null ||
        receipt.connectionId != source.connectionId ||
        receipt.action != 'confirmation' ||
        receipt.localReferenceId != candidateId ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.providerMessageIdHash != messageHash ||
        receipt.providerThreadIdHash != threadHash ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
        receipt.reviewedPayloadJson != reviewedPayloadJson ||
        receipt.entityType != entityType ||
        receipt.entityId != entityId ||
        receipt.idempotencyKey != idempotencyKey ||
        receipt.requiredSyncMutationId != requiredSyncMutationId ||
        receipt.createdAt.toUtc() != createdAt.toUtc()) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return receipt;
  }

  Future<local.EmailReconciliationReceipt?> _confirmationReceipt({
    required String ownerUserId,
    required String candidateId,
  }) {
    return (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals('confirmation:$candidateId') &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<EmailCandidateBulkConfirmationResult> confirmEach({
    required String ownerUserId,
    required Iterable<EmailCandidateConfirmationItem> candidates,
  }) async {
    final confirmed = <EmailCandidateConfirmationResult>[];
    final failed = <EmailCandidateConfirmationFailure>[];
    for (final candidate in candidates) {
      try {
        confirmed.add(
          await confirm(
            ownerUserId: ownerUserId,
            candidateId: candidate.candidateId,
            courseId: candidate.courseId,
          ),
        );
      } on EmailReviewActionException catch (error) {
        failed.add(
          EmailCandidateConfirmationFailure(
            candidateId: candidate.candidateId,
            category: error.category,
          ),
        );
      } catch (_) {
        failed.add(
          EmailCandidateConfirmationFailure(
            candidateId: candidate.candidateId,
            category: domain.EmailErrorCategory.internalError,
          ),
        );
      }
    }
    return EmailCandidateBulkConfirmationResult(
      confirmed: List.unmodifiable(confirmed),
      failed: List.unmodifiable(failed),
    );
  }

  domain.EmailCandidatePayload _decodeAndValidateCandidate(
    local.EmailCandidate candidate,
  ) {
    final payload = _decodePayloadJson(candidate.normalizedPayloadJson);
    if (payload.schemaVersion != candidate.schemaVersion ||
        payload.candidateType.wireName != candidate.candidateType ||
        !payload.requiresUserConfirmation) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    return payload;
  }

  domain.EmailCandidatePayload _decodePayloadJson(String raw) {
    try {
      return _candidateCodec.decode(raw);
    } on domain.EmailCandidateValidationException catch (error) {
      throw EmailReviewActionException(error.errorCategory);
    }
  }

  void _validateMaterializablePayload(
    domain.EmailCandidatePayload payload, {
    required String? courseId,
  }) {
    if (payload.title == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    switch (payload.candidateType) {
      case domain.EmailCandidateType.assignment:
        if (payload.due.at == null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.validationFailed,
          );
        }
        break;
      case domain.EmailCandidateType.exam:
        if (payload.startAt == null || payload.endAt == null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.validationFailed,
          );
        }
        break;
      case domain.EmailCandidateType.event:
        if (payload.startAt == null ||
            payload.endAt == null ||
            courseId != null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.validationFailed,
          );
        }
        break;
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
    }
    if (payload.candidateType != domain.EmailCandidateType.assignment &&
        payload.submissionUrl != null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
  }

  Future<_ActiveConfirmationContext> _requireActiveScheduleContext(
    String ownerUserId,
  ) async {
    final profile = await (db.select(db.profiles)
          ..where((row) => row.userId.equals(ownerUserId)))
        .getSingleOrNull();
    if (profile == null ||
        profile.onboardingStatus != 'complete' ||
        profile.universityId == null ||
        profile.activeTermId == null ||
        profile.primaryCalendarId == null ||
        profile.primaryCalendarId!.trim().isEmpty) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final university = await (db.select(db.universities)
          ..where((row) => row.id.equals(profile.universityId!)))
        .getSingleOrNull();
    // The university catalog is a disposable search cache and is not
    // guaranteed to survive a retained-install/offline session. When it is
    // present, reject an explicitly inactive or deleted row; when absent,
    // the owner-bound profile plus its matching active term remain the
    // authoritative local schedule context.
    if (university != null &&
        (university.status != 'active' || university.deletedAt != null)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final timezone = university?.timezone ?? domain.JapanTime.timeZone;
    if (!isValidEmailTimezone(timezone)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final term = await (db.select(db.terms)
          ..where((row) => row.id.equals(profile.activeTermId!)))
        .getSingleOrNull();
    final isOwnedPersonalTerm =
        term?.ownerUserId == ownerUserId && term?.isTemplate == false;
    final isPermittedUniversityTemplate =
        term?.ownerUserId == null && term?.isTemplate == true;
    if (term == null ||
        term.universityId != profile.universityId ||
        term.status != 'active' ||
        term.deletedAt != null ||
        (!isOwnedPersonalTerm && !isPermittedUniversityTemplate)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final calendar = await (db.select(db.calendars)
          ..where(
            (row) =>
                row.id.equals(profile.primaryCalendarId!) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (calendar == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    return _ActiveConfirmationContext(
      primaryCalendarId: calendar.id,
      activeTermId: term.id,
      timezone: timezone,
    );
  }

  domain.EmailCandidatePayload _normalizeConfiguredTimezone(
    domain.EmailCandidatePayload payload,
    String timezone,
  ) {
    try {
      return _candidateCodec.decodeObject(
        _candidateCodec.toJson(payload.withConfiguredTimezone(timezone)),
      );
    } on domain.EmailCandidateValidationException catch (error) {
      throw EmailReviewActionException(error.errorCategory);
    }
  }

  Future<void> _requireOwnedCourseIfPresent({
    required String ownerUserId,
    required String? courseId,
    required String activeTermId,
  }) async {
    if (courseId == null) return;
    final course = await (db.select(db.userCourses)
          ..where(
            (row) =>
                row.id.equals(courseId) &
                row.ownerUserId.equals(ownerUserId) &
                row.termId.equals(activeTermId) &
                row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (course == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
  }

  Future<void> _requireNoConfirmationArtifacts({
    required String ownerUserId,
    required String candidateId,
    required String confirmationKey,
    required String entityId,
    required String mutationId,
    required String linkId,
    required String notificationId,
  }) async {
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final exam = await (db.select(db.exams)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final event = await (db.select(db.events)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final linkedCandidate = await (db.select(db.emailCandidates)
          ..where(
            (row) => row.confirmationIdempotencyKey.equals(confirmationKey),
          ))
        .getSingleOrNull();
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where(
            (row) =>
                row.id.equals(linkId) |
                row.candidateId.equals(candidateId) |
                row.confirmationIdempotencyKey.equals(confirmationKey),
          ))
        .getSingleOrNull();
    final notification = await (db.select(db.notificationScheduleRequests)
          ..where(
            (row) =>
                row.id.equals(notificationId) |
                row.idempotencyKey.equals(confirmationKey),
          ))
        .getSingleOrNull();
    final mutation = await (db.select(db.syncQueueEntries)
          ..where(
            (row) =>
                row.clientMutationId.equals(mutationId) |
                row.idempotencyKey.equals(confirmationKey),
          ))
        .getSingleOrNull();
    if (assignment != null ||
        exam != null ||
        event != null ||
        linkedCandidate != null ||
        link != null ||
        notification != null ||
        mutation != null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    _requireActiveOwner(ownerUserId);
  }

  Future<Map<String, Object?>> _insertCanonicalEntity({
    required String ownerUserId,
    required String entityId,
    required String? courseId,
    required String primaryCalendarId,
    required domain.EmailCandidatePayload payload,
    required DateTime now,
  }) async {
    final title = payload.title!;
    switch (payload.candidateType) {
      case domain.EmailCandidateType.assignment:
        final dueAt = payload.due.at!.toUtc();
        await db.into(db.assignments).insert(
              local.AssignmentsCompanion.insert(
                id: entityId,
                ownerUserId: ownerUserId,
                courseId: Value(courseId),
                title: title,
                description: Value(payload.summary),
                submissionUrl: Value(payload.submissionUrl),
                dueAt: dueAt,
                visibilityLevel: const Value('PRIVATE'),
                updatedAt: Value(now),
              ),
            );
        return {
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': title,
          'dueAt': dueAt,
          'submissionUrl': payload.submissionUrl,
          'memo': payload.summary,
          'priority': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': now,
          'version': 1,
        };
      case domain.EmailCandidateType.exam:
        final startAt = payload.startAt!.toUtc();
        final endAt = payload.endAt!.toUtc();
        await db.into(db.exams).insert(
              local.ExamsCompanion.insert(
                id: entityId,
                ownerUserId: ownerUserId,
                courseId: Value(courseId),
                title: title,
                startAt: startAt,
                endAt: endAt,
                room: Value(payload.location),
                memo: Value(payload.summary),
                visibilityLevel: const Value('PRIVATE'),
                updatedAt: Value(now),
              ),
            );
        return {
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': title,
          'startAt': startAt,
          'endAt': endAt,
          'room': payload.location,
          'memo': payload.summary,
          'examType': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': now,
          'version': 1,
        };
      case domain.EmailCandidateType.event:
        final startAt = payload.startAt!.toUtc();
        final endAt = payload.endAt!.toUtc();
        await db.into(db.events).insert(
              local.EventsCompanion.insert(
                id: entityId,
                ownerUserId: ownerUserId,
                calendarId: primaryCalendarId,
                title: title,
                kind: domain.EventKind.normal.name,
                startAt: startAt,
                endAt: endAt,
                location: Value(payload.location),
                description: Value(payload.summary),
                timezone: const Value(domain.japanTimeZone),
                visibilityLevel: const Value('PRIVATE'),
                updatedAt: Value(now),
              ),
            );
        return {
          'id': entityId,
          'ownerUserId': ownerUserId,
          'calendarId': primaryCalendarId,
          'title': title,
          'kind': domain.EventKind.normal.name,
          'startAt': startAt,
          'endAt': endAt,
          'location': payload.location,
          'description': payload.summary,
          'rrule': null,
          'timezone': domain.japanTimeZone,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': now,
          'version': 1,
        };
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
    }
  }

  Future<EmailCandidateConfirmationResult> _verifyCommittedConfirmation({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required domain.EmailCandidatePayload originalPayload,
    required local.EmailReconciliationReceipt confirmationReceipt,
    required String? requestedCourseId,
    required String expectedConfirmationKey,
    required String expectedEntityId,
    required String expectedMutationId,
    required String expectedLinkId,
    required String expectedNotificationId,
  }) async {
    final entityType = _supportedEntityType(candidate.linkedEntityType);
    final payload = _decodeAndValidateCandidate(candidate);
    final expectedTimezone = _notificationTimezone(payload);
    if (candidate.linkedEntityId != expectedEntityId ||
        candidate.confirmedAt == null ||
        payload.candidateType != entityType ||
        originalPayload.candidateType != entityType) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    await _verifyCurrentCandidateProvenance(
      ownerUserId: ownerUserId,
      candidate: candidate,
      currentPayload: payload,
      originalPayload: originalPayload,
      entityType: entityType,
      entityId: expectedEntityId,
    );

    late Map<String, Object?> currentEntityPayload;
    late DateTime expectedNotificationAnchor;
    late String? actualEntityContainerId;
    switch (entityType) {
      case domain.EmailCandidateType.assignment:
        final entity = await (db.select(db.assignments)
              ..where((row) => row.id.equals(expectedEntityId)))
            .getSingleOrNull();
        if (entity == null ||
            entity.ownerUserId != ownerUserId ||
            entity.deletedAt != null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        actualEntityContainerId = entity.courseId;
        currentEntityPayload = _assignmentEntityPayload(entity);
        expectedNotificationAnchor = entity.dueAt.toUtc();
        break;
      case domain.EmailCandidateType.exam:
        final entity = await (db.select(db.exams)
              ..where((row) => row.id.equals(expectedEntityId)))
            .getSingleOrNull();
        if (entity == null ||
            entity.ownerUserId != ownerUserId ||
            entity.deletedAt != null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        actualEntityContainerId = entity.courseId;
        currentEntityPayload = _examEntityPayload(entity);
        expectedNotificationAnchor = entity.startAt.toUtc();
        break;
      case domain.EmailCandidateType.event:
        final entity = await (db.select(db.events)
              ..where((row) => row.id.equals(expectedEntityId)))
            .getSingleOrNull();
        if (entity == null ||
            entity.ownerUserId != ownerUserId ||
            entity.deletedAt != null ||
            requestedCourseId != null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        actualEntityContainerId = entity.calendarId;
        currentEntityPayload = _eventEntityPayload(entity);
        expectedNotificationAnchor = entity.startAt.toUtc();
        break;
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
    }

    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) => row.id.equals(expectedLinkId)))
        .getSingleOrNull();
    final notification = await (db.select(db.notificationScheduleRequests)
          ..where((row) => row.id.equals(expectedNotificationId)))
        .getSingleOrNull();
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((row) => row.clientMutationId.equals(expectedMutationId)))
        .getSingleOrNull();
    final legacyConfirmationKey = _stableId(
      'email-confirmation',
      ownerUserId,
      candidate.id,
    );
    final usesLegacyConfirmationKey =
        expectedConfirmationKey == legacyConfirmationKey;
    if (candidate.confirmationIdempotencyKey != expectedConfirmationKey ||
        (!usesLegacyConfirmationKey &&
            entityType != domain.EmailCandidateType.event &&
            _confirmationIdempotencyKey(
                  ownerUserId: ownerUserId,
                  candidateId: candidate.id,
                  entityType: entityType,
                  containerId: requestedCourseId,
                ) !=
                expectedConfirmationKey)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (link == null ||
        link.ownerUserId != ownerUserId ||
        link.sourceId != candidate.sourceId ||
        link.candidateId != candidate.id ||
        link.entityType != entityType.wireName ||
        link.entityId != expectedEntityId ||
        link.confirmationIdempotencyKey != expectedConfirmationKey ||
        notification == null ||
        notification.ownerUserId != ownerUserId ||
        notification.entityType != entityType.wireName ||
        notification.entityId != expectedEntityId ||
        notification.sourceType != 'email_confirmation' ||
        notification.sourceId != candidate.id ||
        notification.idempotencyKey != expectedConfirmationKey ||
        !notification.anchorAt.isAtSameMomentAs(expectedNotificationAnchor) ||
        notification.allDay != _notificationAllDay(payload) ||
        notification.timezone != expectedTimezone ||
        notification.remindersMinutesJson !=
            jsonEncode(payload.suggestedRemindersMinutes) ||
        notification.targetPath != _targetPath(entityType, expectedEntityId)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final currentEntityFingerprint =
        emailSchedulePayloadFingerprint(currentEntityPayload);
    final hasConfirmationEnvelope =
        await (db.select(db.emailScheduleEditReceipts)
                  ..where((row) =>
                      row.mutationId.equals(expectedMutationId) &
                      row.ownerUserId.equals(ownerUserId) &
                      row.provenance.equals('confirmation')))
                .getSingleOrNull() !=
            null;
    final confirmationServerWinsEnvelope =
        await (db.select(db.emailScheduleEditReceipts)
              ..where((row) =>
                  row.mutationId.equals('server-wins:$expectedMutationId') &
                  row.ownerUserId.equals(ownerUserId) &
                  row.provenance.equals('server_wins')))
            .getSingleOrNull();
    if (!usesLegacyConfirmationKey || hasConfirmationEnvelope) {
      await _verifyEntityReceiptChain(
        ownerUserId: ownerUserId,
        candidate: candidate,
        link: link,
        entityType: entityType,
        entityId: expectedEntityId,
        currentEntityVersion: currentEntityPayload['version']! as int,
        currentEntityUpdatedAt: currentEntityPayload['updatedAt']! as DateTime,
        currentEntityFingerprint: currentEntityFingerprint,
        originalPayload: originalPayload,
        requestedCourseId: requestedCourseId,
        expectedConfirmationMutationId: expectedMutationId,
      );
    }
    if (mutation == null) {
      final hasDurableServerWins = confirmationServerWinsEnvelope != null &&
          confirmationServerWinsEnvelope.candidateId == candidate.id &&
          confirmationServerWinsEnvelope.linkId == link.id &&
          confirmationServerWinsEnvelope.entityType == entityType.wireName &&
          confirmationServerWinsEnvelope.entityId == expectedEntityId;
      if ((usesLegacyConfirmationKey && !hasConfirmationEnvelope) ||
          (!hasDurableServerWins &&
              confirmationReceipt.scheduleAckedAt == null) ||
          (hasDurableServerWins &&
              confirmationReceipt.scheduleAckedAt != null)) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
    } else {
      if (mutation.ownerUserId != ownerUserId ||
          mutation.idempotencyKey != expectedConfirmationKey ||
          mutation.entityType != entityType.wireName ||
          mutation.entityId != expectedEntityId ||
          mutation.operation != SyncOperation.create.name ||
          mutation.baseVersion != null ||
          !mutation.createdAt.isAtSameMomentAs(candidate.confirmedAt!)) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      final isScrubbedTerminal =
          mutation.status == SyncMutationStatus.synced.name &&
              mutation.payloadJson == '{}';
      if (usesLegacyConfirmationKey &&
          !hasConfirmationEnvelope &&
          isScrubbedTerminal) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      if (isScrubbedTerminal) {
        final isRemoteApplied = mutation.completionProvenance ==
            local.scheduleSyncCompletionRemoteApplied;
        final isServerWins = mutation.completionProvenance ==
            local.scheduleSyncCompletionServerWins;
        final validRemoteApplied = isRemoteApplied &&
            confirmationReceipt.scheduleAckedAt != null &&
            mutation.syncedAt != null &&
            mutation.serverVersion != null &&
            confirmationReceipt.scheduleAckedAt!
                .isAtSameMomentAs(mutation.syncedAt!);
        final validServerWins = isServerWins &&
            confirmationServerWinsEnvelope != null &&
            confirmationReceipt.scheduleAckedAt == null &&
            mutation.syncedAt != null &&
            mutation.serverVersion ==
                confirmationServerWinsEnvelope.entityVersion;
        if (!validRemoteApplied && !validServerWins) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
      } else {
        final isVerifiableNonterminal =
            mutation.status == SyncMutationStatus.pending.name ||
                mutation.status == SyncMutationStatus.processing.name ||
                mutation.status == SyncMutationStatus.failed.name ||
                mutation.status == SyncMutationStatus.conflict.name;
        if (!isVerifiableNonterminal ||
            mutation.payloadJson == '{}' ||
            mutation.completionProvenance != null ||
            mutation.syncedAt != null ||
            (mutation.status == SyncMutationStatus.conflict.name &&
                (mutation.serverVersion == null ||
                    mutation.serverPayloadJson == null ||
                    mutation.conflictCursor == null))) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        _verifyPendingCreatePayload(
          mutation.payloadJson,
          candidateId: candidate.id,
          entityType: entityType,
          entityId: expectedEntityId,
          ownerUserId: ownerUserId,
          expectedConfirmationKey: expectedConfirmationKey,
          requestedCourseId: requestedCourseId,
          actualEntityContainerId: actualEntityContainerId,
          requireActualEntityMatch:
              usesLegacyConfirmationKey && !hasConfirmationEnvelope,
          currentEntityFingerprint: currentEntityFingerprint,
          originalPayload: originalPayload,
          confirmedAt: candidate.confirmedAt!,
        );
      }
    }
    return EmailCandidateConfirmationResult(
      candidateId: candidate.id,
      entityType: entityType,
      entityId: expectedEntityId,
      replayed: true,
    );
  }

  Future<void> _verifyEntityReceiptChain({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required local.EmailScheduleEntityLink link,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required int currentEntityVersion,
    required DateTime currentEntityUpdatedAt,
    required String currentEntityFingerprint,
    required domain.EmailCandidatePayload originalPayload,
    required String? requestedCourseId,
    required String expectedConfirmationMutationId,
  }) async {
    final receipts = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.baseEntityVersion),
            (row) => OrderingTerm.asc(row.createdAt),
          ]))
        .get();
    final confirmations = receipts
        .where((receipt) => receipt.provenance == 'confirmation')
        .toList(growable: false);
    if (confirmations.length != 1) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final confirmation = confirmations.single;
    final initialPayload = _initialConfirmationEntityPayload(
      ownerUserId: ownerUserId,
      entityType: entityType,
      entityId: entityId,
      courseId: requestedCourseId,
      originalPayload: originalPayload,
      confirmedAt: candidate.confirmedAt!,
    );
    final expectedInitialFingerprint = initialPayload == null
        ? confirmation.payloadFingerprint
        : emailSchedulePayloadFingerprint(initialPayload);
    if (confirmation.mutationId != expectedConfirmationMutationId ||
        confirmation.linkId != link.id ||
        confirmation.baseEntityVersion != 0 ||
        confirmation.entityVersion != 1 ||
        confirmation.basePayloadFingerprint !=
            confirmation.payloadFingerprint ||
        confirmation.payloadFingerprint != expectedInitialFingerprint ||
        confirmation.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(originalPayload) ||
        !confirmation.entityUpdatedAt
            .isAtSameMomentAs(candidate.confirmedAt!)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }

    var version = confirmation.entityVersion;
    var fingerprint = confirmation.payloadFingerprint;
    var entityUpdatedAt = confirmation.entityUpdatedAt;
    final remaining = receipts
        .where((receipt) => receipt.provenance != 'confirmation')
        .toList(growable: true);
    while (remaining.isNotEmpty) {
      final matches = remaining
          .where((receipt) =>
              receipt.baseEntityVersion == version &&
              receipt.basePayloadFingerprint == fingerprint)
          .toList(growable: false);
      final local.EmailScheduleEditReceipt receipt;
      if (matches.length == 1) {
        receipt = matches.single;
      } else {
        final noOpAcknowledgements = matches
            .where((candidate) =>
                candidate.provenance == 'remote_ack' &&
                candidate.entityVersion == candidate.baseEntityVersion &&
                candidate.payloadFingerprint ==
                    candidate.basePayloadFingerprint &&
                candidate.entityUpdatedAt.isAtSameMomentAs(entityUpdatedAt))
            .toList(growable: false);
        if (noOpAcknowledgements.length != 1) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        receipt = noOpAcknowledgements.single;
      }
      remaining.remove(receipt);
      final singleVersionStep = receipt.provenance == 'user_edit' ||
          receipt.provenance == 'accepted_update';
      final sameVersionStep = receipt.provenance == 'remote_ack';
      final serverWinningStep = receipt.provenance == 'server_wins';
      final jumpingStep = receipt.provenance == 'remote_apply' ||
          receipt.provenance == 'legacy_trusted_tip';
      if (receipt.linkId != link.id ||
          receipt.baseEntityVersion != version ||
          receipt.basePayloadFingerprint != fingerprint ||
          (singleVersionStep && receipt.entityVersion != version + 1) ||
          (sameVersionStep && receipt.entityVersion != version) ||
          (serverWinningStep && receipt.entityVersion < version) ||
          (jumpingStep && receipt.entityVersion <= version) ||
          (!singleVersionStep &&
              !sameVersionStep &&
              !serverWinningStep &&
              !jumpingStep)) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      version = receipt.entityVersion;
      fingerprint = receipt.payloadFingerprint;
      entityUpdatedAt = receipt.entityUpdatedAt;
    }
    if (version != currentEntityVersion ||
        fingerprint != currentEntityFingerprint ||
        !entityUpdatedAt.isAtSameMomentAs(currentEntityUpdatedAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
  }

  Map<String, Object?>? _initialConfirmationEntityPayload({
    required String ownerUserId,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required String? courseId,
    required domain.EmailCandidatePayload originalPayload,
    required DateTime confirmedAt,
  }) {
    final payload = switch (entityType) {
      domain.EmailCandidateType.assignment => <String, Object?>{
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': originalPayload.title,
          'dueAt': originalPayload.due.at,
          'submissionUrl': originalPayload.submissionUrl,
          'memo': originalPayload.summary,
          'priority': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': confirmedAt.toUtc(),
          'version': 1,
        },
      domain.EmailCandidateType.exam => <String, Object?>{
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': originalPayload.title,
          'startAt': originalPayload.startAt,
          'endAt': originalPayload.endAt,
          'room': originalPayload.location,
          'scope': null,
          'memo': originalPayload.summary,
          'examType': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': confirmedAt.toUtc(),
          'version': 1,
        },
      domain.EmailCandidateType.event => null,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        null,
    };
    if (payload == null) return null;
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: payload,
    );
  }

  Future<_CandidateReplayBaseline> _verifyCurrentCandidateProvenance({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required domain.EmailCandidatePayload currentPayload,
    required domain.EmailCandidatePayload originalPayload,
    required domain.EmailCandidateType entityType,
    required String entityId,
  }) async {
    final canonicalCurrent = _candidateCodec.encode(currentPayload);
    final canonicalOriginal = _candidateCodec.encode(originalPayload);
    if (candidate.normalizedPayloadJson != canonicalCurrent ||
        candidate.semanticFingerprint !=
            emailCandidateSemanticFingerprint(currentPayload)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final accepted = await (db.select(db.emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.state.equals('accepted') &
              row.proposedPayloadJson.equals(canonicalCurrent)))
        .get();
    final causallyMatchingAccepted = accepted.where((proposal) {
      final resolvedAt = proposal.resolvedAt;
      return resolvedAt != null &&
          candidate.updatedAt.isAtSameMomentAs(resolvedAt) &&
          proposal.updatedAt.isAtSameMomentAs(resolvedAt);
    }).toList(growable: false);
    final supersededEvidence = await (db.select(db.emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.state.equals('superseded')))
        .get();
    final rejectionKeyEvidence = supersededEvidence.any(
      (proposal) =>
          proposal.resolvedAt != null &&
          proposal.resolvedAt!.isAtSameMomentAs(candidate.updatedAt) &&
          proposal.updatedAt.isAtSameMomentAs(candidate.updatedAt) &&
          proposal.resolutionIdempotencyKey ==
              'email-update-server-wins-reject:${proposal.id}',
    );
    final durableRejections = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.action.equals('update') &
              row.resolution.equals('rejected') &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId)))
        .get();
    final serverWinsReceipts = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId) &
              row.provenance.equals('server_wins')))
        .get();
    final durableRejectionEvidence = durableRejections.any(
      (receipt) {
        if (receipt.idempotencyKey !=
            'email-update-server-wins-reject:${receipt.localReferenceId}') {
          return false;
        }
        final acceptedMutationId = _stableId(
          'email-update-accept',
          ownerUserId,
          receipt.localReferenceId,
        );
        return receipt.updatedAt.isAtSameMomentAs(candidate.updatedAt) ||
            serverWinsReceipts.any(
              (winner) =>
                  (winner.mutationId == acceptedMutationId ||
                      winner.mutationId == 'server-wins:$acceptedMutationId') &&
                  winner.createdAt.isAtSameMomentAs(candidate.updatedAt),
            );
      },
    );
    if (rejectionKeyEvidence || durableRejectionEvidence) {
      // Whole-second SQLite timestamps can make an older accepted proposal
      // appear causal with a later A -> B -> A server-wins rejection. Durable
      // rejection evidence takes precedence over that ambiguous accepted row.
      return _verifyServerWinsCandidateProvenance(
        ownerUserId: ownerUserId,
        candidate: candidate,
        currentPayload: currentPayload,
        entityType: entityType,
        entityId: entityId,
      );
    }
    if (causallyMatchingAccepted.length > 1) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (causallyMatchingAccepted.isEmpty &&
        canonicalCurrent == canonicalOriginal &&
        candidate.updatedAt.isAtSameMomentAs(candidate.confirmedAt!)) {
      final confirmationEnvelope =
          await (db.select(db.emailScheduleEditReceipts)
                ..where((row) =>
                    row.ownerUserId.equals(ownerUserId) &
                    row.candidateId.equals(candidate.id) &
                    row.entityType.equals(entityType.wireName) &
                    row.entityId.equals(entityId) &
                    row.provenance.equals('confirmation')))
              .getSingleOrNull();
      if (confirmationEnvelope != null &&
          (confirmationEnvelope.entityVersion != 1 ||
              !confirmationEnvelope.entityUpdatedAt
                  .isAtSameMomentAs(candidate.confirmedAt!) ||
              confirmationEnvelope.candidatePayloadFingerprint !=
                  emailCandidatePayloadFingerprint(currentPayload))) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      return _CandidateReplayBaseline(
        entityVersion: 1,
        entityUpdatedAt: candidate.confirmedAt!,
        entityPayloadFingerprint: confirmationEnvelope?.payloadFingerprint,
      );
    }
    if (causallyMatchingAccepted.isEmpty) {
      return _verifyServerWinsCandidateProvenance(
        ownerUserId: ownerUserId,
        candidate: candidate,
        currentPayload: currentPayload,
        entityType: entityType,
        entityId: entityId,
      );
    }
    final proposal = causallyMatchingAccepted.single;
    final resolvedAt = proposal.resolvedAt;
    final expectedResolutionKey = _stableId(
      'email-update-accept',
      ownerUserId,
      proposal.id,
    );
    if (resolvedAt == null ||
        proposal.baseEntityVersion < 1 ||
        proposal.errorCategory != null ||
        proposal.resolutionIdempotencyKey != expectedResolutionKey ||
        proposal.semanticFingerprint !=
            emailCandidateUpdateFingerprint(currentPayload) ||
        !candidate.updatedAt.isAtSameMomentAs(resolvedAt) ||
        !proposal.updatedAt.isAtSameMomentAs(resolvedAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }

    final source = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: proposal.sourceId,
    );
    final connection = source == null
        ? null
        : await db.emailImportDao.connectionById(
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
          );
    final receipt = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals('update:${proposal.id}') &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final acceptedEnvelope = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(expectedResolutionKey) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final legacyTip = acceptedEnvelope == null
        ? await (db.select(db.emailScheduleEditReceipts)
              ..where((row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.candidateId.equals(candidate.id) &
                  row.entityType.equals(entityType.wireName) &
                  row.entityId.equals(entityId) &
                  row.provenance.equals('legacy_trusted_tip')))
            .getSingleOrNull()
        : null;
    final envelope = acceptedEnvelope ?? legacyTip;
    final isAcceptedEnvelope = envelope?.provenance == 'accepted_update';
    final isLegacyTip = envelope?.provenance == 'legacy_trusted_tip';
    if (source == null ||
        connection == null ||
        receipt == null ||
        source.processingState != 'processed' ||
        source.errorCategory != null ||
        receipt.connectionId != source.connectionId ||
        receipt.action != 'update' ||
        receipt.localReferenceId != proposal.id ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.providerMessageIdHash !=
            emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ) ||
        receipt.providerThreadIdHash !=
            emailProviderIdentifierHash(
              kind: 'thread',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerThreadId,
            ) ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
        receipt.reviewedPayloadJson != null ||
        receipt.resolution != 'accepted' ||
        receipt.entityType != entityType.wireName ||
        receipt.entityId != entityId ||
        receipt.idempotencyKey != expectedResolutionKey ||
        receipt.requiredSyncMutationId != expectedResolutionKey ||
        !receipt.createdAt.isAtSameMomentAs(resolvedAt) ||
        envelope == null ||
        envelope.candidateId != candidate.id ||
        envelope.entityType != entityType.wireName ||
        envelope.entityId != entityId ||
        (!isAcceptedEnvelope && !isLegacyTip) ||
        (isAcceptedEnvelope &&
            (envelope.baseEntityVersion != proposal.baseEntityVersion ||
                envelope.entityVersion != proposal.baseEntityVersion + 1)) ||
        (isLegacyTip &&
            envelope.entityVersion < proposal.baseEntityVersion + 1) ||
        envelope.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(currentPayload) ||
        (isAcceptedEnvelope &&
            !envelope.entityUpdatedAt.isAtSameMomentAs(resolvedAt))) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return _CandidateReplayBaseline(
      entityVersion: envelope.entityVersion,
      entityUpdatedAt: envelope.entityUpdatedAt,
      entityPayloadFingerprint: envelope.payloadFingerprint,
    );
  }

  Future<_CandidateReplayBaseline> _verifyServerWinsCandidateProvenance({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required domain.EmailCandidatePayload currentPayload,
    required domain.EmailCandidateType entityType,
    required String entityId,
  }) async {
    final superseded = await (db.select(db.emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.state.equals('superseded')))
        .get();
    final matching = superseded.where((proposal) {
      final resolvedAt = proposal.resolvedAt;
      return resolvedAt != null &&
          candidate.updatedAt.isAtSameMomentAs(resolvedAt) &&
          proposal.updatedAt.isAtSameMomentAs(resolvedAt) &&
          proposal.resolutionIdempotencyKey ==
              'email-update-server-wins-reject:${proposal.id}';
    }).toList(growable: false);
    if (matching.length != 1) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final proposal = matching.single;
    final resolvedAt = proposal.resolvedAt!;
    final proposedPayload = _decodePayloadJson(proposal.proposedPayloadJson);
    if (proposal.baseEntityVersion < 1 ||
        proposal.errorCategory != null ||
        proposedPayload.candidateType != entityType ||
        currentPayload.candidateType != entityType ||
        proposal.semanticFingerprint !=
            emailCandidateUpdateFingerprint(proposedPayload)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }

    final source = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: proposal.sourceId,
    );
    final connection = source == null
        ? null
        : await db.emailImportDao.connectionById(
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
          );
    final receipt = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals('update:${proposal.id}') &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final rejectionKey = 'email-update-server-wins-reject:${proposal.id}';
    if (source == null ||
        connection == null ||
        receipt == null ||
        source.processingState != 'processed' ||
        source.errorCategory != null ||
        receipt.connectionId != source.connectionId ||
        receipt.action != 'update' ||
        receipt.localReferenceId != proposal.id ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.providerMessageIdHash !=
            emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ) ||
        receipt.providerThreadIdHash !=
            emailProviderIdentifierHash(
              kind: 'thread',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerThreadId,
            ) ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
        receipt.reviewedPayloadJson != null ||
        receipt.resolution != 'rejected' ||
        receipt.entityType != entityType.wireName ||
        receipt.entityId != entityId ||
        receipt.idempotencyKey != rejectionKey ||
        receipt.requiredSyncMutationId != null ||
        receipt.scheduleAckedAt != null ||
        receipt.updatedAt.isBefore(resolvedAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }

    final acceptedMutationId = _stableId(
      'email-update-accept',
      ownerUserId,
      proposal.id,
    );
    final retainedMutation = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(acceptedMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final winningReceipt = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.isIn([
                acceptedMutationId,
                'server-wins:$acceptedMutationId',
              ]) &
              row.ownerUserId.equals(ownerUserId) &
              row.provenance.equals('server_wins')))
        .getSingleOrNull();
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId)))
        .getSingleOrNull();
    final appendedLegacyWinner =
        winningReceipt?.mutationId == 'server-wins:$acceptedMutationId';
    final legacyAncestor = appendedLegacyWinner
        ? await (db.select(db.emailScheduleEditReceipts)
              ..where((row) =>
                  row.mutationId.equals(acceptedMutationId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.provenance.equals('legacy_trusted_tip')))
            .getSingleOrNull()
        : null;
    if (winningReceipt == null ||
        link == null ||
        winningReceipt.candidateId != candidate.id ||
        winningReceipt.linkId != link.id ||
        winningReceipt.entityType != entityType.wireName ||
        winningReceipt.entityId != entityId ||
        winningReceipt.provenance != 'server_wins' ||
        (appendedLegacyWinner
            ? winningReceipt.baseEntityVersion < proposal.baseEntityVersion + 1
            : winningReceipt.baseEntityVersion != proposal.baseEntityVersion) ||
        (appendedLegacyWinner &&
            (legacyAncestor == null ||
                legacyAncestor.candidateId != candidate.id ||
                legacyAncestor.linkId != link.id ||
                legacyAncestor.entityVersion !=
                    winningReceipt.baseEntityVersion ||
                legacyAncestor.payloadFingerprint !=
                    winningReceipt.basePayloadFingerprint ||
                legacyAncestor.candidatePayloadFingerprint !=
                    emailCandidatePayloadFingerprint(proposedPayload))) ||
        winningReceipt.entityVersion < 1 ||
        winningReceipt.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(currentPayload) ||
        !winningReceipt.createdAt.isAtSameMomentAs(resolvedAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (retainedMutation != null &&
        (retainedMutation.idempotencyKey != acceptedMutationId ||
            retainedMutation.entityType != entityType.wireName ||
            retainedMutation.entityId != entityId ||
            retainedMutation.operation != SyncOperation.update.name ||
            retainedMutation.baseVersion != proposal.baseEntityVersion ||
            retainedMutation.status != SyncMutationStatus.synced.name ||
            retainedMutation.completionProvenance !=
                local.scheduleSyncCompletionServerWins ||
            retainedMutation.serverVersion != winningReceipt.entityVersion ||
            retainedMutation.payloadJson != '{}' ||
            retainedMutation.syncedAt == null ||
            !retainedMutation.syncedAt!.isAtSameMomentAs(resolvedAt))) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return _CandidateReplayBaseline(
      entityVersion: winningReceipt.entityVersion,
      entityUpdatedAt: winningReceipt.entityUpdatedAt,
      entityPayloadFingerprint: winningReceipt.payloadFingerprint,
      serverWins: true,
    );
  }

  Map<String, Object?> _assignmentEntityPayload(local.Assignment entity) {
    return emailScheduleReplayPayload(
      entityType: domain.EmailCandidateType.assignment,
      payload: {
        'id': entity.id,
        'ownerUserId': entity.ownerUserId,
        'courseId': entity.courseId,
        'title': entity.title,
        'dueAt': entity.dueAt.toUtc(),
        'submissionUrl': entity.submissionUrl,
        'memo': entity.description,
        'priority': entity.priority,
        'visibilityLevel': entity.visibilityLevel,
        'updatedAt': entity.updatedAt.toUtc(),
        'deletedAt': entity.deletedAt?.toUtc(),
        'version': entity.version,
      },
    );
  }

  Map<String, Object?> _examEntityPayload(local.Exam entity) {
    return emailScheduleReplayPayload(
      entityType: domain.EmailCandidateType.exam,
      payload: {
        'id': entity.id,
        'ownerUserId': entity.ownerUserId,
        'courseId': entity.courseId,
        'title': entity.title,
        'startAt': entity.startAt.toUtc(),
        'endAt': entity.endAt.toUtc(),
        'room': entity.room,
        'scope': entity.scope,
        'memo': entity.memo,
        'examType': entity.examType,
        'visibilityLevel': entity.visibilityLevel,
        'updatedAt': entity.updatedAt.toUtc(),
        'deletedAt': entity.deletedAt?.toUtc(),
        'version': entity.version,
      },
    );
  }

  Map<String, Object?> _eventEntityPayload(local.Event entity) {
    return emailScheduleReplayPayload(
      entityType: domain.EmailCandidateType.event,
      payload: {
        'id': entity.id,
        'ownerUserId': entity.ownerUserId,
        'calendarId': entity.calendarId,
        'groupId': entity.groupId,
        'title': entity.title,
        'kind': entity.kind,
        'startAt': entity.startAt.toUtc(),
        'endAt': entity.endAt.toUtc(),
        'location': entity.location,
        'description': entity.description,
        'rrule': entity.rrule,
        'timezone': entity.timezone,
        'visibilityLevel': entity.visibilityLevel,
        'updatedAt': entity.updatedAt.toUtc(),
        'deletedAt': entity.deletedAt?.toUtc(),
        'version': entity.version,
      },
    );
  }

  void _verifyPendingCreatePayload(
    String rawPayload, {
    required String candidateId,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required String ownerUserId,
    required String expectedConfirmationKey,
    required String? requestedCourseId,
    required String? actualEntityContainerId,
    required bool requireActualEntityMatch,
    required String currentEntityFingerprint,
    required domain.EmailCandidatePayload originalPayload,
    required DateTime confirmedAt,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawPayload);
    } on FormatException {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (decoded is! Map ||
        decoded['id'] != entityId ||
        decoded['ownerUserId'] != ownerUserId ||
        decoded['visibilityLevel'] != 'PRIVATE' ||
        decoded['version'] != 1 ||
        !_storedTimestampMatches(decoded['updatedAt'], confirmedAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final actualKeys = decoded.keys.map((key) => key.toString()).toSet();
    final expectedKeys = switch (entityType) {
      domain.EmailCandidateType.assignment => _assignmentMutationKeys,
      domain.EmailCandidateType.exam => _examMutationKeys,
      domain.EmailCandidateType.event => _eventMutationKeys,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        const <String>{},
    };
    if (actualKeys.length != expectedKeys.length ||
        !actualKeys.containsAll(expectedKeys)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final Object? containerValue = switch (entityType) {
      domain.EmailCandidateType.assignment ||
      domain.EmailCandidateType.exam =>
        decoded['courseId'],
      domain.EmailCandidateType.event => decoded['calendarId'],
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        null,
    };
    final containerId = containerValue == null
        ? null
        : containerValue is String && containerValue.trim().isNotEmpty
            ? containerValue
            : null;
    if ((containerValue != null && containerId == null) ||
        (entityType == domain.EmailCandidateType.event &&
            containerId == null) ||
        (requireActualEntityMatch && containerId != actualEntityContainerId) ||
        (entityType != domain.EmailCandidateType.event &&
            containerId != requestedCourseId) ||
        (_confirmationIdempotencyKey(
                  ownerUserId: ownerUserId,
                  candidateId: candidateId,
                  entityType: entityType,
                  containerId: containerId,
                ) !=
                expectedConfirmationKey &&
            _stableId('email-confirmation', ownerUserId, candidateId) !=
                expectedConfirmationKey)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final valuesMatch = switch (entityType) {
      domain.EmailCandidateType.assignment =>
        decoded['title'] == originalPayload.title &&
            _timestampMatches(decoded['dueAt'], originalPayload.due.at!) &&
            decoded['submissionUrl'] == originalPayload.submissionUrl &&
            decoded['memo'] == originalPayload.summary &&
            decoded['priority'] == null,
      domain.EmailCandidateType.exam =>
        decoded['title'] == originalPayload.title &&
            _timestampMatches(decoded['startAt'], originalPayload.startAt!) &&
            _timestampMatches(decoded['endAt'], originalPayload.endAt!) &&
            decoded['room'] == originalPayload.location &&
            decoded['memo'] == originalPayload.summary &&
            decoded['examType'] == null,
      domain.EmailCandidateType.event =>
        decoded['title'] == originalPayload.title &&
            decoded['kind'] == domain.EventKind.normal.name &&
            _timestampMatches(decoded['startAt'], originalPayload.startAt!) &&
            _timestampMatches(decoded['endAt'], originalPayload.endAt!) &&
            decoded['location'] == originalPayload.location &&
            decoded['description'] == originalPayload.summary &&
            decoded['rrule'] == null &&
            decoded['timezone'] == domain.japanTimeZone,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        false,
    };
    if (!valuesMatch) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (requireActualEntityMatch) {
      final canonicalMutationPayload = emailScheduleReplayPayload(
        entityType: entityType,
        payload: decoded.map<String, Object?>(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
      if (emailSchedulePayloadFingerprint(canonicalMutationPayload) !=
          currentEntityFingerprint) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
    }
  }

  bool _timestampMatches(Object? value, DateTime expected) {
    if (value is! String) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.isAtSameMomentAs(expected);
  }

  bool _storedTimestampMatches(Object? value, DateTime expected) {
    if (value is! String) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null &&
        emailScheduleSqliteTimestamp(parsed).isAtSameMomentAs(
          emailScheduleSqliteTimestamp(expected),
        );
  }

  domain.EmailCandidateType _supportedEntityType(String? value) {
    final domain.EmailCandidateType type;
    try {
      type = domain.EmailCandidateType.fromWire(value ?? '');
    } on FormatException {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (type == domain.EmailCandidateType.announcement ||
        type == domain.EmailCandidateType.unknown) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return type;
  }

  DateTime _notificationAnchor(domain.EmailCandidatePayload payload) {
    return switch (payload.candidateType) {
      domain.EmailCandidateType.assignment =>
        emailScheduleSqliteTimestamp(payload.due.at!),
      domain.EmailCandidateType.exam ||
      domain.EmailCandidateType.event =>
        emailScheduleSqliteTimestamp(payload.startAt!),
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        ),
    };
  }

  bool _notificationAllDay(domain.EmailCandidatePayload payload) {
    return payload.candidateType == domain.EmailCandidateType.assignment &&
        payload.due.allDay;
  }

  String _notificationTimezone(domain.EmailCandidatePayload payload) {
    return payload.due.timezone ?? domain.japanTimeZone;
  }

  String _targetPath(domain.EmailCandidateType type, String entityId) {
    return switch (type) {
      domain.EmailCandidateType.assignment => '/assignment/$entityId/edit',
      domain.EmailCandidateType.exam => '/exam/$entityId/edit',
      domain.EmailCandidateType.event => '/event/$entityId/edit',
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        ),
    };
  }

  String _stableId(String kind, String ownerUserId, String candidateId) {
    return _uuid.v5(
      Namespace.url.value,
      '$kind\u0000$ownerUserId\u0000$candidateId',
    );
  }

  String _confirmationIdempotencyKey({
    required String ownerUserId,
    required String candidateId,
    required domain.EmailCandidateType entityType,
    required String? containerId,
  }) {
    return _uuid.v5(
      Namespace.url.value,
      'email-confirmation\u0000$ownerUserId\u0000$candidateId\u0000'
      '${entityType.wireName}\u0000${containerId ?? '<standalone>'}',
    );
  }

  void _requireIdentifier(String value, String name) {
    if (value.isEmpty || value != value.trim() || value.length > 1024) {
      throw ArgumentError.value(
        value,
        name,
        'must be a normalized non-empty identifier',
      );
    }
  }

  void _requireActiveOwner(String ownerUserId) {
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
    } on ScopedContextLeaseException {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.authorizationRevoked,
      );
    }
    if (authenticatedUserId() != ownerUserId) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.authorizationRevoked,
      );
    }
  }
}

class _ActiveConfirmationContext {
  const _ActiveConfirmationContext({
    required this.primaryCalendarId,
    required this.activeTermId,
    required this.timezone,
  });

  final String primaryCalendarId;
  final String activeTermId;
  final String timezone;
}

class _CandidateReplayBaseline {
  const _CandidateReplayBaseline({
    required this.entityVersion,
    required this.entityUpdatedAt,
    this.entityPayloadFingerprint,
    this.serverWins = false,
  });

  final int entityVersion;
  final DateTime entityUpdatedAt;
  final String? entityPayloadFingerprint;
  final bool serverWins;
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

const _examMutationKeys = <String>{
  'id',
  'ownerUserId',
  'courseId',
  'title',
  'startAt',
  'endAt',
  'room',
  'memo',
  'examType',
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
