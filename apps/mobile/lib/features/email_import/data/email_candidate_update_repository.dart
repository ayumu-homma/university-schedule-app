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

class EmailCandidateUpdateProposal {
  const EmailCandidateUpdateProposal({
    required this.id,
    required this.candidateId,
    required this.entityType,
    required this.entityId,
    required this.fieldDiff,
    required this.proposedPayload,
    required this.baseEntityVersion,
    required this.createdAt,
    this.timezone = domain.JapanTime.timeZone,
  });

  final String id;
  final String candidateId;
  final domain.EmailCandidateType entityType;
  final String entityId;
  final Map<String, Object?> fieldDiff;
  final domain.EmailCandidatePayload proposedPayload;
  final int baseEntityVersion;
  final DateTime createdAt;
  final String timezone;
}

class EmailCandidateUpdateResolutionResult {
  const EmailCandidateUpdateResolutionResult({
    required this.updateId,
    required this.entityType,
    required this.entityId,
    required this.accepted,
    required this.replayed,
  });

  final String updateId;
  final domain.EmailCandidateType entityType;
  final String entityId;
  final bool accepted;
  final bool replayed;
}

abstract interface class EmailCandidateUpdateRepository {
  Future<List<EmailCandidateUpdateProposal>> pending({
    required String ownerUserId,
  });

  Future<EmailCandidateUpdateResolutionResult> accept({
    required String ownerUserId,
    required String updateId,
  });

  Future<EmailCandidateUpdateResolutionResult> reject({
    required String ownerUserId,
    required String updateId,
  });
}

/// Owner-scoped explicit resolution for email update proposals. Accepting a
/// proposal updates only its reviewed field diff, advances the canonical
/// entity version once, and enqueues one deterministic update mutation in the
/// same Drift transaction.
class DriftEmailCandidateUpdateRepository
    implements EmailCandidateUpdateRepository {
  DriftEmailCandidateUpdateRepository({
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
  Future<List<EmailCandidateUpdateProposal>> pending({
    required String ownerUserId,
  }) async {
    _requireOwner(ownerUserId);
    final rows = await (db.select(db.emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.state.equals('pending'))
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.createdAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
    final timezone = await _ownerTimezone(ownerUserId);
    final proposals = <EmailCandidateUpdateProposal>[];
    for (final row in rows) {
      proposals.add(await _proposalFromRow(ownerUserId, row, timezone));
    }
    _requireOwner(ownerUserId);
    return List.unmodifiable(proposals);
  }

  @override
  Future<EmailCandidateUpdateResolutionResult> accept({
    required String ownerUserId,
    required String updateId,
  }) {
    _requireIdentifier(updateId, 'updateId');
    _requireOwner(ownerUserId);
    return db.transaction(() async {
      _requireOwner(ownerUserId);
      final row = await _requireUpdate(ownerUserId, updateId);
      final candidate = await _requireConfirmedCandidate(
        ownerUserId,
        row.candidateId,
      );
      final entityType = _entityType(candidate.linkedEntityType);
      final entityId = candidate.linkedEntityId!;
      final resolutionKey = _stableId(
        'email-update-accept',
        ownerUserId,
        updateId,
      );

      if (row.state == 'accepted') {
        await _verifyAcceptedReplay(
          ownerUserId: ownerUserId,
          row: row,
          entityType: entityType,
          entityId: entityId,
          expectedResolutionKey: resolutionKey,
        );
        await _ensureResolutionReceipt(
          ownerUserId: ownerUserId,
          row: row,
          entityType: entityType,
          entityId: entityId,
          resolution: 'accepted',
          resolutionKey: resolutionKey,
          createdAt: row.resolvedAt!,
        );
        _requireOwner(ownerUserId);
        return EmailCandidateUpdateResolutionResult(
          updateId: updateId,
          entityType: entityType,
          entityId: entityId,
          accepted: true,
          replayed: true,
        );
      }
      if (row.state != 'pending') {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
      }

      final proposed = _decodePayload(row.proposedPayloadJson);
      if (proposed.candidateType != entityType ||
          emailCandidateUpdateFingerprint(proposed) !=
              row.semanticFingerprint) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      final baseline = _decodePayload(candidate.normalizedPayloadJson);
      final expectedDiff = emailScheduleFieldDiff(
        baseline: baseline,
        proposed: proposed,
      );
      final storedDiff = _decodeDiff(row.fieldDiffJson);
      if (expectedDiff.isEmpty || !_jsonEqual(storedDiff, expectedDiff)) {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.internalError,
        );
      }
      final link = await _requireLink(
        ownerUserId: ownerUserId,
        candidate: candidate,
        entityType: entityType,
        entityId: entityId,
      );
      await _requireNoResolutionMutation(
        ownerUserId: ownerUserId,
        mutationId: resolutionKey,
      );

      final now = emailScheduleSqliteTimestamp(clock());
      final baseEntityPayload = await _currentEntityPayload(
        ownerUserId: ownerUserId,
        entityType: entityType,
        entityId: entityId,
      );
      final mutationPayload = await _applyCanonicalUpdate(
        ownerUserId: ownerUserId,
        entityType: entityType,
        entityId: entityId,
        expectedVersion: row.baseEntityVersion,
        proposed: proposed,
        diff: storedDiff,
        now: now,
      );
      final acceptedEntityPayload = await _currentEntityPayload(
        ownerUserId: ownerUserId,
        entityType: entityType,
        entityId: entityId,
      );
      final candidateChanged = await (db.update(db.emailCandidates)
            ..where((candidateRow) =>
                candidateRow.id.equals(candidate.id) &
                candidateRow.ownerUserId.equals(ownerUserId) &
                candidateRow.reviewState.equals('confirmed')))
          .write(
        local.EmailCandidatesCompanion(
          normalizedPayloadJson: Value(_candidateCodec.encode(proposed)),
          semanticFingerprint: Value(
            emailCandidateSemanticFingerprint(proposed),
          ),
          updatedAt: Value(now),
        ),
      );
      if (candidateChanged != 1) {
        throw StateError('Confirmed email candidate changed during update.');
      }
      await _refreshNotificationRequest(
        ownerUserId: ownerUserId,
        candidateId: candidate.id,
        confirmationIdempotencyKey: candidate.confirmationIdempotencyKey!,
        entityType: entityType,
        entityId: entityId,
        proposed: proposed,
        now: now,
      );
      await DriftSyncQueue(db, ownerUserId: ownerUserId).enqueue(
        PendingMutation(
          clientMutationId: resolutionKey,
          ownerUserId: ownerUserId,
          idempotencyKey: resolutionKey,
          entityType: entityType.wireName,
          entityId: entityId,
          operation: SyncOperation.update,
          payload: mutationPayload,
          baseVersion: row.baseEntityVersion,
          createdAt: now,
        ),
      );
      await db.into(db.emailScheduleEditReceipts).insert(
            local.EmailScheduleEditReceiptsCompanion.insert(
              mutationId: resolutionKey,
              ownerUserId: ownerUserId,
              candidateId: candidate.id,
              linkId: link.id,
              entityType: entityType.wireName,
              entityId: entityId,
              provenance: 'accepted_update',
              baseEntityVersion: row.baseEntityVersion,
              entityVersion: row.baseEntityVersion + 1,
              basePayloadFingerprint:
                  emailSchedulePayloadFingerprint(baseEntityPayload),
              payloadFingerprint:
                  emailSchedulePayloadFingerprint(acceptedEntityPayload),
              candidatePayloadFingerprint:
                  emailCandidatePayloadFingerprint(proposed),
              entityUpdatedAt: now,
              createdAt: now,
            ),
          );
      final resolved = await (db.update(db.emailCandidateUpdates)
            ..where((proposalRow) =>
                proposalRow.id.equals(updateId) &
                proposalRow.ownerUserId.equals(ownerUserId) &
                proposalRow.state.equals('pending')))
          .write(
        local.EmailCandidateUpdatesCompanion(
          state: const Value('accepted'),
          resolutionIdempotencyKey: Value(resolutionKey),
          resolvedAt: Value(now),
          errorCategory: const Value(null),
          updatedAt: Value(now),
        ),
      );
      if (resolved != 1) {
        throw StateError('Email update proposal changed during acceptance.');
      }
      await _ensureResolutionReceipt(
        ownerUserId: ownerUserId,
        row: row,
        entityType: entityType,
        entityId: entityId,
        resolution: 'accepted',
        resolutionKey: resolutionKey,
        createdAt: now,
      );
      _requireOwner(ownerUserId);
      return EmailCandidateUpdateResolutionResult(
        updateId: updateId,
        entityType: entityType,
        entityId: entityId,
        accepted: true,
        replayed: false,
      );
    });
  }

  @override
  Future<EmailCandidateUpdateResolutionResult> reject({
    required String ownerUserId,
    required String updateId,
  }) {
    _requireIdentifier(updateId, 'updateId');
    _requireOwner(ownerUserId);
    return db.transaction(() async {
      _requireOwner(ownerUserId);
      final row = await _requireUpdate(ownerUserId, updateId);
      final candidate = await _requireConfirmedCandidate(
        ownerUserId,
        row.candidateId,
      );
      final entityType = _entityType(candidate.linkedEntityType);
      final entityId = candidate.linkedEntityId!;
      final resolutionKey = _stableId(
        'email-update-reject',
        ownerUserId,
        updateId,
      );
      if (row.state == 'rejected') {
        if (row.resolutionIdempotencyKey != resolutionKey ||
            row.resolvedAt == null) {
          throw const EmailReviewActionException(
            domain.EmailErrorCategory.internalError,
          );
        }
        await _ensureResolutionReceipt(
          ownerUserId: ownerUserId,
          row: row,
          entityType: entityType,
          entityId: entityId,
          resolution: 'rejected',
          resolutionKey: resolutionKey,
          createdAt: row.resolvedAt!,
        );
        _requireOwner(ownerUserId);
        return EmailCandidateUpdateResolutionResult(
          updateId: updateId,
          entityType: entityType,
          entityId: entityId,
          accepted: false,
          replayed: true,
        );
      }
      if (row.state != 'pending') {
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        );
      }
      final now = emailScheduleSqliteTimestamp(clock());
      final changed = await (db.update(db.emailCandidateUpdates)
            ..where((proposalRow) =>
                proposalRow.id.equals(updateId) &
                proposalRow.ownerUserId.equals(ownerUserId) &
                proposalRow.state.equals('pending')))
          .write(
        local.EmailCandidateUpdatesCompanion(
          state: const Value('rejected'),
          resolutionIdempotencyKey: Value(resolutionKey),
          resolvedAt: Value(now),
          errorCategory: const Value(null),
          updatedAt: Value(now),
        ),
      );
      if (changed != 1) {
        throw StateError('Email update proposal changed during rejection.');
      }
      await _ensureResolutionReceipt(
        ownerUserId: ownerUserId,
        row: row,
        entityType: entityType,
        entityId: entityId,
        resolution: 'rejected',
        resolutionKey: resolutionKey,
        createdAt: now,
      );
      _requireOwner(ownerUserId);
      return EmailCandidateUpdateResolutionResult(
        updateId: updateId,
        entityType: entityType,
        entityId: entityId,
        accepted: false,
        replayed: false,
      );
    });
  }

  Future<void> _ensureResolutionReceipt({
    required String ownerUserId,
    required local.EmailCandidateUpdate row,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required String resolution,
    required String resolutionKey,
    required DateTime createdAt,
  }) async {
    final source = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: row.sourceId,
    );
    final connection = source == null
        ? null
        : await db.emailImportDao.connectionById(
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
          );
    if (source == null || connection == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final receiptId = 'update:${row.id}';
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
    final requiredMutationId = resolution == 'accepted' ? resolutionKey : null;
    await db.into(db.emailReconciliationReceipts).insert(
          local.EmailReconciliationReceiptsCompanion.insert(
            id: receiptId,
            ownerUserId: ownerUserId,
            connectionId: source.connectionId,
            action: 'update',
            localReferenceId: row.id,
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            providerMessageIdHash: messageHash,
            providerThreadIdHash: threadHash,
            sanitizedContentHash: source.sanitizedContentHash,
            resolution: Value(resolution),
            entityType: Value(entityType.wireName),
            entityId: Value(entityId),
            idempotencyKey: resolutionKey,
            requiredSyncMutationId: Value(requiredMutationId),
            createdAt: Value(createdAt.toUtc()),
            updatedAt: Value(createdAt.toUtc()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    final receipt = await (db.select(db.emailReconciliationReceipts)
          ..where((receiptRow) =>
              receiptRow.id.equals(receiptId) &
              receiptRow.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (receipt == null ||
        receipt.connectionId != source.connectionId ||
        receipt.action != 'update' ||
        receipt.localReferenceId != row.id ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.providerMessageIdHash != messageHash ||
        receipt.providerThreadIdHash != threadHash ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
        receipt.resolution != resolution ||
        receipt.entityType != entityType.wireName ||
        receipt.entityId != entityId ||
        receipt.idempotencyKey != resolutionKey ||
        receipt.requiredSyncMutationId != requiredMutationId) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
  }

  Future<EmailCandidateUpdateProposal> _proposalFromRow(
    String ownerUserId,
    local.EmailCandidateUpdate row,
    String? ownerTimezone,
  ) async {
    final candidate = await _requireConfirmedCandidate(
      ownerUserId,
      row.candidateId,
    );
    final proposedPayload = _decodePayload(row.proposedPayloadJson);
    final payloadTimezone = proposedPayload.due.timezone;
    final timezone =
        payloadTimezone != null && isValidEmailTimezone(payloadTimezone)
            ? payloadTimezone
            : ownerTimezone ?? domain.JapanTime.timeZone;
    return EmailCandidateUpdateProposal(
      id: row.id,
      candidateId: row.candidateId,
      entityType: _entityType(candidate.linkedEntityType),
      entityId: candidate.linkedEntityId!,
      fieldDiff: _decodeDiff(row.fieldDiffJson),
      proposedPayload: proposedPayload,
      baseEntityVersion: row.baseEntityVersion,
      createdAt: row.createdAt,
      timezone: timezone,
    );
  }

  Future<String?> _ownerTimezone(String ownerUserId) async {
    final profile = await (db.select(db.profiles)
          ..where((row) => row.userId.equals(ownerUserId)))
        .getSingleOrNull();
    if (profile?.universityId == null) return null;
    final university = await (db.select(db.universities)
          ..where((row) => row.id.equals(profile!.universityId!)))
        .getSingleOrNull();
    if (university == null ||
        university.status != 'active' ||
        university.deletedAt != null ||
        !isValidEmailTimezone(university.timezone)) {
      return null;
    }
    return university.timezone;
  }

  Future<local.EmailCandidateUpdate> _requireUpdate(
    String ownerUserId,
    String updateId,
  ) async {
    final row = await db.emailImportDao.candidateUpdateById(
      ownerUserId: ownerUserId,
      updateId: updateId,
    );
    if (row == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    return row;
  }

  Future<local.EmailCandidate> _requireConfirmedCandidate(
    String ownerUserId,
    String candidateId,
  ) async {
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: candidateId,
    );
    if (candidate == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityId == null ||
        candidate.confirmationIdempotencyKey == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return candidate;
  }

  Future<Map<String, Object?>> _currentEntityPayload({
    required String ownerUserId,
    required domain.EmailCandidateType entityType,
    required String entityId,
  }) async {
    final Map<String, Object?> payload;
    switch (entityType) {
      case domain.EmailCandidateType.assignment:
        final row = await (db.select(db.assignments)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) throw StateError('Assignment is unavailable.');
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'courseId': row.courseId,
          'title': row.title,
          'dueAt': row.dueAt,
          'submissionUrl': row.submissionUrl,
          'memo': row.description,
          'priority': row.priority,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.exam:
        final row = await (db.select(db.exams)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) throw StateError('Exam is unavailable.');
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'courseId': row.courseId,
          'title': row.title,
          'startAt': row.startAt,
          'endAt': row.endAt,
          'room': row.room,
          'scope': row.scope,
          'memo': row.memo,
          'examType': row.examType,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.event:
        final row = await (db.select(db.events)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) throw StateError('Event is unavailable.');
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'calendarId': row.calendarId,
          'groupId': row.groupId,
          'title': row.title,
          'kind': row.kind,
          'startAt': row.startAt,
          'endAt': row.endAt,
          'location': row.location,
          'description': row.description,
          'rrule': row.rrule,
          'timezone': row.timezone,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        throw StateError('Unsupported email update entity type.');
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: payload,
    );
  }

  Future<local.EmailScheduleEntityLink> _requireLink({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required domain.EmailCandidateType entityType,
    required String entityId,
  }) async {
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId)))
        .getSingleOrNull();
    if (link == null ||
        link.confirmationIdempotencyKey !=
            candidate.confirmationIdempotencyKey) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return link;
  }

  Future<void> _requireNoResolutionMutation({
    required String ownerUserId,
    required String mutationId,
  }) async {
    final collision = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(mutationId) |
              row.idempotencyKey.equals(mutationId)))
        .getSingleOrNull();
    if (collision != null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    _requireOwner(ownerUserId);
  }

  Future<Map<String, Object?>> _applyCanonicalUpdate({
    required String ownerUserId,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required int expectedVersion,
    required domain.EmailCandidatePayload proposed,
    required Map<String, Object?> diff,
    required DateTime now,
  }) {
    return switch (entityType) {
      domain.EmailCandidateType.assignment => _updateAssignment(
          ownerUserId: ownerUserId,
          entityId: entityId,
          expectedVersion: expectedVersion,
          proposed: proposed,
          diff: diff,
          now: now,
        ),
      domain.EmailCandidateType.exam => _updateExam(
          ownerUserId: ownerUserId,
          entityId: entityId,
          expectedVersion: expectedVersion,
          proposed: proposed,
          diff: diff,
          now: now,
        ),
      domain.EmailCandidateType.event => _updateEvent(
          ownerUserId: ownerUserId,
          entityId: entityId,
          expectedVersion: expectedVersion,
          proposed: proposed,
          diff: diff,
          now: now,
        ),
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        throw const EmailReviewActionException(
          domain.EmailErrorCategory.validationFailed,
        ),
    };
  }

  Future<Map<String, Object?>> _updateAssignment({
    required String ownerUserId,
    required String entityId,
    required int expectedVersion,
    required domain.EmailCandidatePayload proposed,
    required Map<String, Object?> diff,
    required DateTime now,
  }) async {
    final existing = await (db.select(db.assignments)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
    if (existing == null || existing.version != expectedVersion) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final title =
        (diff.containsKey('title') ? proposed.title : existing.title)?.trim();
    final dueAt = diff.containsKey('due_at')
        ? proposed.due.at?.toUtc()
        : existing.dueAt.toUtc();
    if (title == null || title.trim().isEmpty || dueAt == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final description = _serverNullifiedText(
      diff.containsKey('summary') ? proposed.summary : existing.description,
    );
    final submissionUrl = _serverNullifiedText(
      diff.containsKey('submission_url')
          ? proposed.submissionUrl
          : existing.submissionUrl,
    );
    final priority = _serverNullifiedText(existing.priority);
    final nextVersion = existing.version + 1;
    final changed = await (db.update(db.assignments)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull() &
              row.version.equals(expectedVersion)))
        .write(
      local.AssignmentsCompanion(
        title: Value(title),
        description: Value(description),
        submissionUrl: Value(submissionUrl),
        priority: Value(priority),
        dueAt: Value(dueAt),
        updatedAt: Value(now),
        version: Value(nextVersion),
      ),
    );
    _requireOne(changed);
    return {
      'id': entityId,
      'ownerUserId': ownerUserId,
      'courseId': existing.courseId,
      'title': title,
      'dueAt': dueAt,
      'submissionUrl': submissionUrl,
      'memo': description,
      'priority': priority,
      'visibilityLevel': existing.visibilityLevel,
      'updatedAt': now,
      'version': nextVersion,
    };
  }

  Future<Map<String, Object?>> _updateExam({
    required String ownerUserId,
    required String entityId,
    required int expectedVersion,
    required domain.EmailCandidatePayload proposed,
    required Map<String, Object?> diff,
    required DateTime now,
  }) async {
    final existing = await (db.select(db.exams)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
    if (existing == null || existing.version != expectedVersion) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final title =
        (diff.containsKey('title') ? proposed.title : existing.title)?.trim();
    final startAt = diff.containsKey('start_at')
        ? proposed.startAt?.toUtc()
        : existing.startAt.toUtc();
    final endAt = diff.containsKey('end_at')
        ? proposed.endAt?.toUtc()
        : existing.endAt.toUtc();
    if (title == null ||
        title.trim().isEmpty ||
        startAt == null ||
        endAt == null ||
        !endAt.isAfter(startAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final room = _serverNullifiedText(
      diff.containsKey('location') ? proposed.location : existing.room,
    );
    final memo = _serverNullifiedText(
      diff.containsKey('summary') ? proposed.summary : existing.memo,
    );
    final scope = _serverNullifiedText(existing.scope);
    final examType = _serverNullifiedText(existing.examType);
    final nextVersion = existing.version + 1;
    final changed = await (db.update(db.exams)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull() &
              row.version.equals(expectedVersion)))
        .write(
      local.ExamsCompanion(
        title: Value(title),
        startAt: Value(startAt),
        endAt: Value(endAt),
        room: Value(room),
        scope: Value(scope),
        memo: Value(memo),
        examType: Value(examType),
        updatedAt: Value(now),
        version: Value(nextVersion),
      ),
    );
    _requireOne(changed);
    return {
      'id': entityId,
      'ownerUserId': ownerUserId,
      'courseId': existing.courseId,
      'title': title,
      'startAt': startAt,
      'endAt': endAt,
      'room': room,
      'scope': scope,
      'memo': memo,
      'examType': examType,
      'visibilityLevel': existing.visibilityLevel,
      'updatedAt': now,
      'version': nextVersion,
    };
  }

  Future<Map<String, Object?>> _updateEvent({
    required String ownerUserId,
    required String entityId,
    required int expectedVersion,
    required domain.EmailCandidatePayload proposed,
    required Map<String, Object?> diff,
    required DateTime now,
  }) async {
    final existing = await (db.select(db.events)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
    if (existing == null ||
        existing.version != expectedVersion ||
        existing.kind != domain.EventKind.normal.name) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final title =
        (diff.containsKey('title') ? proposed.title : existing.title)?.trim();
    final startAt = diff.containsKey('start_at')
        ? proposed.startAt?.toUtc()
        : existing.startAt.toUtc();
    final endAt = diff.containsKey('end_at')
        ? proposed.endAt?.toUtc()
        : existing.endAt.toUtc();
    if (title == null ||
        title.trim().isEmpty ||
        startAt == null ||
        endAt == null ||
        !endAt.isAfter(startAt)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.validationFailed,
      );
    }
    final location = _serverNullifiedText(
      diff.containsKey('location') ? proposed.location : existing.location,
    );
    final description = _serverNullifiedText(
      diff.containsKey('summary') ? proposed.summary : existing.description,
    );
    final rrule = _serverNullifiedText(existing.rrule);
    final nextVersion = existing.version + 1;
    final changed = await (db.update(db.events)
          ..where((row) =>
              row.id.equals(entityId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull() &
              row.version.equals(expectedVersion)))
        .write(
      local.EventsCompanion(
        title: Value(title),
        startAt: Value(startAt),
        endAt: Value(endAt),
        location: Value(location),
        description: Value(description),
        rrule: Value(rrule),
        timezone: const Value(domain.japanTimeZone),
        updatedAt: Value(now),
        version: Value(nextVersion),
      ),
    );
    _requireOne(changed);
    return {
      'id': entityId,
      'ownerUserId': ownerUserId,
      'calendarId': existing.calendarId,
      'groupId': null,
      'title': title,
      'kind': existing.kind,
      'startAt': startAt,
      'endAt': endAt,
      'location': location,
      'description': description,
      'rrule': rrule,
      'timezone': domain.japanTimeZone,
      'visibilityLevel': existing.visibilityLevel,
      'updatedAt': now,
      'version': nextVersion,
    };
  }

  String? _serverNullifiedText(String? value) {
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _verifyAcceptedReplay({
    required String ownerUserId,
    required local.EmailCandidateUpdate row,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required String expectedResolutionKey,
  }) async {
    final proposed = _decodePayload(row.proposedPayloadJson);
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((queueRow) =>
              queueRow.clientMutationId.equals(expectedResolutionKey) &
              queueRow.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final candidate = await _requireConfirmedCandidate(
      ownerUserId,
      row.candidateId,
    );
    final link = await _requireLink(
      ownerUserId: ownerUserId,
      candidate: candidate,
      entityType: entityType,
      entityId: entityId,
    );
    final envelope = await (db.select(db.emailScheduleEditReceipts)
          ..where((proof) =>
              proof.mutationId.equals(expectedResolutionKey) &
              proof.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final currentEntityPayload = await _currentEntityPayload(
      ownerUserId: ownerUserId,
      entityType: entityType,
      entityId: entityId,
    );
    final notification = await (db.select(db.notificationScheduleRequests)
          ..where((request) =>
              request.ownerUserId.equals(ownerUserId) &
              request.sourceId.equals(row.candidateId) &
              request.entityType.equals(entityType.wireName) &
              request.entityId.equals(entityId)))
        .getSingleOrNull();
    final envelopeReachesCurrent = envelope != null &&
        await _receiptReachesCurrent(
          envelope: envelope,
          currentPayload: currentEntityPayload,
        );
    if (row.resolutionIdempotencyKey != expectedResolutionKey ||
        row.resolvedAt == null ||
        candidate.normalizedPayloadJson != _candidateCodec.encode(proposed) ||
        candidate.semanticFingerprint !=
            emailCandidateSemanticFingerprint(proposed) ||
        envelope == null ||
        envelope.candidateId != candidate.id ||
        envelope.linkId != link.id ||
        envelope.entityType != entityType.wireName ||
        envelope.entityId != entityId ||
        envelope.provenance != 'accepted_update' ||
        envelope.baseEntityVersion != row.baseEntityVersion ||
        envelope.entityVersion != row.baseEntityVersion + 1 ||
        !envelopeReachesCurrent ||
        envelope.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(proposed) ||
        !envelope.entityUpdatedAt.isAtSameMomentAs(row.resolvedAt!) ||
        notification == null ||
        notification.idempotencyKey != candidate.confirmationIdempotencyKey ||
        notification.anchorAt.toUtc() != _notificationAnchor(proposed) ||
        notification.allDay != _notificationAllDay(proposed) ||
        notification.timezone != _notificationTimezone(proposed) ||
        notification.remindersMinutesJson !=
            jsonEncode(proposed.suggestedRemindersMinutes)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    // Synced queue rows are intentionally pruned after the retention window.
    // The accepted proposal row, candidate baseline and notification request
    // are the durable atomic receipt; validate the queue row as an additional
    // invariant only while it is still retained.
    if (mutation != null &&
        (mutation.idempotencyKey != expectedResolutionKey ||
            mutation.entityType != entityType.wireName ||
            mutation.entityId != entityId ||
            mutation.operation != SyncOperation.update.name ||
            mutation.baseVersion != row.baseEntityVersion)) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
  }

  Future<bool> _receiptReachesCurrent({
    required local.EmailScheduleEditReceipt envelope,
    required Map<String, Object?> currentPayload,
  }) async {
    final currentVersion = currentPayload['version'];
    final currentUpdatedAt = currentPayload['updatedAt'];
    if (currentVersion is! int || currentUpdatedAt is! DateTime) return false;
    var version = envelope.entityVersion;
    var fingerprint = envelope.payloadFingerprint;
    var updatedAt = envelope.entityUpdatedAt;
    final receipts = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.ownerUserId.equals(envelope.ownerUserId) &
              row.candidateId.equals(envelope.candidateId) &
              row.entityType.equals(envelope.entityType) &
              row.entityId.equals(envelope.entityId) &
              row.mutationId.equals(envelope.mutationId).not()))
        .get();
    while (version != currentVersion ||
        fingerprint != emailSchedulePayloadFingerprint(currentPayload) ||
        !updatedAt.isAtSameMomentAs(currentUpdatedAt)) {
      final matches = receipts
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
                candidate.entityUpdatedAt.isAtSameMomentAs(updatedAt))
            .toList(growable: false);
        if (noOpAcknowledgements.length != 1) return false;
        receipt = noOpAcknowledgements.single;
      }
      receipts.remove(receipt);
      final plusOne = receipt.provenance == 'accepted_update' ||
          receipt.provenance == 'user_edit';
      final sameVersion = receipt.provenance == 'remote_ack';
      final serverWins = receipt.provenance == 'server_wins';
      final jump = receipt.provenance == 'remote_apply' ||
          receipt.provenance == 'legacy_trusted_tip';
      if ((plusOne && receipt.entityVersion != version + 1) ||
          (sameVersion && receipt.entityVersion != version) ||
          (serverWins && receipt.entityVersion < version) ||
          (jump && receipt.entityVersion <= version) ||
          (!plusOne && !sameVersion && !serverWins && !jump)) {
        return false;
      }
      version = receipt.entityVersion;
      fingerprint = receipt.payloadFingerprint;
      updatedAt = receipt.entityUpdatedAt;
    }
    return true;
  }

  Future<void> _refreshNotificationRequest({
    required String ownerUserId,
    required String candidateId,
    required String confirmationIdempotencyKey,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required domain.EmailCandidatePayload proposed,
    required DateTime now,
  }) async {
    final request = await (db.select(db.notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.sourceId.equals(candidateId) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId) &
              row.idempotencyKey.equals(confirmationIdempotencyKey)))
        .getSingleOrNull();
    if (request == null) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    final changed = await (db.update(db.notificationScheduleRequests)
          ..where((row) =>
              row.id.equals(request.id) & row.ownerUserId.equals(ownerUserId)))
        .write(
      local.NotificationScheduleRequestsCompanion(
        anchorAt: Value(_notificationAnchor(proposed)),
        allDay: Value(_notificationAllDay(proposed)),
        timezone: Value(_notificationTimezone(proposed)),
        remindersMinutesJson: Value(
          jsonEncode(proposed.suggestedRemindersMinutes),
        ),
        state: const Value('pending'),
        updatedAt: Value(now),
      ),
    );
    _requireOne(changed);
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

  domain.EmailCandidatePayload _decodePayload(String raw) {
    try {
      return _candidateCodec.decode(raw);
    } on domain.EmailCandidateValidationException catch (error) {
      throw EmailReviewActionException(error.errorCategory);
    }
  }

  Map<String, Object?> _decodeDiff(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    if (decoded is! Map || decoded.isEmpty) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.internalError,
      );
    }
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  domain.EmailCandidateType _entityType(String? value) {
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

  bool _jsonEqual(Object? left, Object? right) {
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final key in left.keys) {
        if (!right.containsKey(key) || !_jsonEqual(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index += 1) {
        if (!_jsonEqual(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

  void _requireOne(int changed) {
    if (changed != 1) {
      throw StateError('Canonical email update lost its version race.');
    }
  }

  String _stableId(String kind, String ownerUserId, String updateId) {
    return _uuid.v5(
      Namespace.url.value,
      '$kind\u0000$ownerUserId\u0000$updateId',
    );
  }

  void _requireIdentifier(String value, String name) {
    if (value.isEmpty || value != value.trim() || value.length > 1024) {
      throw ArgumentError.value(value, name, 'must be a normalized id');
    }
  }

  void _requireOwner(String ownerUserId) {
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
    } on ScopedContextLeaseException {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.authorizationRevoked,
      );
    }
    if (ownerUserId.isEmpty ||
        ownerUserId != ownerUserId.trim() ||
        authenticatedUserId() != ownerUserId) {
      throw const EmailReviewActionException(
        domain.EmailErrorCategory.authorizationRevoked,
      );
    }
  }
}
