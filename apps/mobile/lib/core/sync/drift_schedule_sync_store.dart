import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart' as domain;

import '../../features/email_import/data/email_candidate_dedupe.dart';
import '../../features/email_import/data/email_update_conflict_resolver.dart';
import '../../local_db/app_database.dart' as local;
import 'drift_sync_queue.dart';
import 'remote_schedule_gateway.dart';
import 'sync_queue.dart';

class PendingLocalMutationException implements Exception {
  const PendingLocalMutationException({
    required this.entityType,
    required this.entityId,
  });

  final String entityType;
  final String entityId;

  @override
  String toString() =>
      'Pending local mutation blocks $entityType/$entityId reconciliation.';
}

class StaleSyncCursorException implements Exception {
  const StaleSyncCursorException({
    required this.expected,
    required this.actual,
  });

  final int expected;
  final int actual;

  @override
  String toString() => 'Expected sync cursor $expected but found $actual.';
}

class DriftScheduleSyncStore {
  DriftScheduleSyncStore(
    this.db, {
    required this.ownerUserId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (ownerUserId.trim().isEmpty ||
        ownerUserId != ownerUserId.trim() ||
        ownerUserId == local.legacyQuarantinedOwnerId) {
      throw ArgumentError.value(
        ownerUserId,
        'ownerUserId',
        'A real, normalized owner is required for schedule sync.',
      );
    }
  }

  final local.AppDatabase db;
  final String ownerUserId;
  final DateTime Function() _clock;

  static const maximumCanonicalPayloadBytes = 256 * 1024;

  Future<int> cursor() => db.syncQueueDao.readCursor(ownerUserId);

  Future<void> acknowledge(
    PendingMutation mutation,
    ScheduleMutationAck ack, {
    required DateTime acknowledgedAt,
  }) async {
    _validateAck(mutation, ack);
    final templateOperation =
        mutation.entityType == 'course_template_publish' ||
            mutation.entityType == 'course_template_update_apply';
    final normalizedAcknowledgedAt =
        emailScheduleSqliteTimestamp(acknowledgedAt);
    final queue = DriftSyncQueue(db, ownerUserId: ownerUserId);
    await db.transaction(() async {
      if (!templateOperation) {
        await _requirePersonalEmailEventCanonical(ack.change);
      }
      if (ack.isConflict) {
        final marked = await queue.markConflict(
          mutation.clientMutationId,
          'Remote version changed.',
          attemptCount: mutation.attemptCount,
          serverVersion: ack.serverVersion,
          serverPayload: ack.change.payload,
          conflictCursor: ack.changeCursor,
        );
        if (!marked) {
          throw StateError('The claimed mutation is no longer current.');
        }
        return;
      }

      final hasNewerLocalMutation = await _hasActiveLogicalMutation(
        entityType: mutation.entityType,
        entityId: mutation.entityId,
        excludingMutationId: mutation.clientMutationId,
      );
      final acknowledgement = templateOperation
          ? null
          : await _requireMatchingAcknowledgementEnvelope(
              mutation: mutation,
              change: ack.change,
            );
      if (!hasNewerLocalMutation) {
        await _applyChange(ack.change);
        if (acknowledgement != null) {
          final appliedEnvelope = await _recordRemoteAcknowledgement(
            acknowledgement,
            mutationId: mutation.clientMutationId,
            acknowledgedAt: normalizedAcknowledgedAt,
          );
          await _requireAppliedEnvelope(
            change: ack.change,
            envelope: appliedEnvelope,
          );
          await _refreshLinkedNotification(ack.change);
        }
      }
      final marked = await queue.markSynced(
        mutation.clientMutationId,
        acknowledgedAt: normalizedAcknowledgedAt,
        attemptCount: mutation.attemptCount,
        serverVersion: ack.serverVersion,
      );
      if (!marked) {
        throw StateError('The claimed mutation is no longer current.');
      }
    });
  }

  Future<void> applyDeltaPage(
    ScheduleDeltaPage page, {
    DateTime? appliedAt,
  }) async {
    _validatePage(page);
    final now = emailScheduleSqliteTimestamp(appliedAt ?? _clock());
    await db.transaction(() async {
      final persistedCursor = await cursor();
      if (persistedCursor != page.afterCursor) {
        throw StaleSyncCursorException(
          expected: page.afterCursor,
          actual: persistedCursor,
        );
      }

      for (final change in page.changes) {
        if (await _hasActiveLogicalMutation(
          entityType: change.entityType,
          entityId: change.entityId,
        )) {
          throw PendingLocalMutationException(
            entityType: change.entityType,
            entityId: change.entityId,
          );
        }
        await _applyRemoteChange(change, appliedAt: now);
      }

      await db.syncQueueDao.writeCursor(
        ownerUserId: ownerUserId,
        cursor: page.nextCursor,
        updatedAt: now,
      );
    });
  }

  Future<void> resolveConflictServerWins(
    String clientMutationId, {
    DateTime? resolvedAt,
  }) async {
    if (clientMutationId.trim().isEmpty) {
      throw ArgumentError.value(
        clientMutationId,
        'clientMutationId',
        'A conflict mutation ID is required.',
      );
    }
    final resolutionTime = emailScheduleSqliteTimestamp(
      resolvedAt ?? _clock(),
    );
    await db.transaction(() async {
      final row = await (db.select(db.syncQueueEntries)
            ..where(
              (entry) =>
                  entry.clientMutationId.equals(clientMutationId) &
                  entry.ownerUserId.equals(ownerUserId) &
                  entry.status.equals('conflict'),
            ))
          .getSingleOrNull();
      if (row == null ||
          row.serverVersion == null ||
          row.conflictCursor == null ||
          row.serverPayloadJson == null) {
        throw StateError('A canonical server conflict is unavailable.');
      }
      final payload = _decodePayload(row.serverPayloadJson!);
      final deletedAt = _nullableDateTime(payload['deletedAt']);
      final change = ScheduleDeltaChange(
        changeCursor: row.conflictCursor!,
        entityType: _canonicalEntityType(row.entityType),
        entityId: row.entityId,
        operation: deletedAt == null
            ? ScheduleDeltaOperation.upsert
            : ScheduleDeltaOperation.delete,
        serverVersion: row.serverVersion!,
        deletedAt: deletedAt,
        payload: payload,
      );
      _validateChange(change);
      await _requirePersonalEmailEventCanonical(change);
      // If this queue row came from accepting an email update, server-wins is
      // itself an explicit rejection of that proposal. Convert the dependent
      // private outbox before the generic queue row becomes terminal so an
      // `accepted` reconciliation can never be released by this resolution.
      final replacedEmailProvenance =
          await EmailUpdateConflictResolver(db).supersedeAcceptedUpdate(
        ownerUserId: ownerUserId,
        clientMutationId: row.clientMutationId,
        mutationIdempotencyKey: row.idempotencyKey,
        entityType: _canonicalEntityType(row.entityType),
        entityId: row.entityId,
        operation: row.operation,
        canonicalPayload: payload,
        canonicalDeleted: change.operation == ScheduleDeltaOperation.delete,
        resolvedAt: resolutionTime,
      );
      if (!replacedEmailProvenance &&
          await _emailLinkedContext(
                entityType: change.entityType,
                entityId: change.entityId,
              ) !=
              null) {
        throw const RemoteScheduleProtocolException(
          'Email-linked conflict has no immutable provenance.',
        );
      }
      await _applyChange(change);
      if (replacedEmailProvenance) {
        await _refreshLinkedNotification(change);
        final envelope = await (db.select(db.emailScheduleEditReceipts)
              ..where((proof) =>
                  proof.mutationId.isIn([
                    clientMutationId,
                    'server-wins:$clientMutationId',
                  ]) &
                  proof.provenance.equals('server_wins') &
                  proof.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (envelope == null) {
          throw StateError('Server-wins provenance replacement is missing.');
        }
        await _requireAppliedEnvelope(change: change, envelope: envelope);
      }
      final resolved = await db.syncQueueDao.resolveConflictServerWins(
        ownerUserId,
        clientMutationId,
        resolutionTime,
      );
      if (!resolved) {
        throw StateError('The conflict changed before it was resolved.');
      }
    });
  }

  Future<_AcknowledgementEnvelopeMatch?>
      _requireMatchingAcknowledgementEnvelope({
    required PendingMutation mutation,
    required ScheduleDeltaChange change,
  }) async {
    final envelope = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(mutation.clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (envelope == null) {
      final linked = await _emailLinkedContext(
        entityType: change.entityType,
        entityId: change.entityId,
      );
      if (linked != null) {
        throw const RemoteScheduleProtocolException(
          'Email-linked acknowledgement has no immutable provenance.',
        );
      }
      return null;
    }
    final canonicalPayload = _canonicalEmailPayload(change);
    final canonicalUpdatedAt = _requiredDateTime(canonicalPayload, 'updatedAt');
    final entityType = domain.EmailCandidateType.fromWire(change.entityType);
    final Map<String, Object?> outgoingPayload;
    if (mutation.operation == SyncOperation.delete) {
      final localTombstone = await _emailLinkedContext(
        entityType: change.entityType,
        entityId: change.entityId,
      );
      if (localTombstone == null ||
          mutation.payload['id'] != change.entityId ||
          mutation.payload['ownerUserId'] != ownerUserId ||
          mutation.payload['version'] != envelope.entityVersion ||
          _nullableDateTime(mutation.payload['deletedAt']) == null ||
          localTombstone.payload['deletedAt'] == null ||
          !_requiredDateTime(mutation.payload, 'deletedAt').isAtSameMomentAs(
            _requiredDateTime(localTombstone.payload, 'deletedAt'),
          ) ||
          !_requiredDateTime(mutation.payload, 'updatedAt').isAtSameMomentAs(
            _requiredDateTime(localTombstone.payload, 'updatedAt'),
          )) {
        throw const RemoteScheduleProtocolException(
          'Email-linked delete acknowledgement has no local tombstone.',
        );
      }
      outgoingPayload = localTombstone.payload;
    } else {
      outgoingPayload = emailScheduleReplayPayload(
        entityType: entityType,
        payload: mutation.payload,
      );
    }
    final projectedCanonicalPayload = _serverCanonicalProjection(
      entityType: entityType,
      outgoingPayload: outgoingPayload,
      canonicalUpdatedAt: canonicalUpdatedAt,
      canonicalDeletedAt: _nullableDateTime(canonicalPayload['deletedAt']),
      canonicalVersion: change.serverVersion,
      operation: mutation.operation,
    );
    final baseVersionMatches = envelope.provenance == 'legacy_trusted_tip'
        ? (mutation.operation == SyncOperation.update ||
                mutation.operation == SyncOperation.delete) &&
            mutation.baseVersion != null &&
            envelope.baseEntityVersion <= mutation.baseVersion!
        : envelope.baseEntityVersion == (mutation.baseVersion ?? 0);
    if (envelope.entityType != _canonicalEntityType(change.entityType) ||
        envelope.entityId != change.entityId ||
        envelope.provenance != 'confirmation' &&
            envelope.provenance != 'accepted_update' &&
            envelope.provenance != 'user_edit' &&
            envelope.provenance != 'legacy_trusted_tip' ||
        !baseVersionMatches ||
        envelope.entityVersion != change.serverVersion ||
        envelope.payloadFingerprint !=
            emailSchedulePayloadFingerprint(outgoingPayload) ||
        emailSchedulePayloadFingerprint(canonicalPayload) !=
            emailSchedulePayloadFingerprint(projectedCanonicalPayload)) {
      throw const RemoteScheduleProtocolException(
        'Canonical acknowledgement differs from local email provenance.',
      );
    }
    return _AcknowledgementEnvelopeMatch(
      envelope: envelope,
      canonicalFingerprint: emailSchedulePayloadFingerprint(canonicalPayload),
      canonicalUpdatedAt: canonicalUpdatedAt,
    );
  }

  Future<bool> _hasActiveLogicalMutation({
    required String entityType,
    required String entityId,
    String? excludingMutationId,
  }) async {
    for (final logicalType in _logicalEntityTypes(entityType)) {
      final active = await db.syncQueueDao.activeMutationsForEntity(
        ownerUserId: ownerUserId,
        entityType: logicalType,
        entityId: entityId,
      );
      if (active.any((row) => row.clientMutationId != excludingMutationId)) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> _serverCanonicalProjection({
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> outgoingPayload,
    required DateTime canonicalUpdatedAt,
    required DateTime? canonicalDeletedAt,
    required int canonicalVersion,
    required SyncOperation operation,
  }) {
    final projected = <String, Object?>{
      ...outgoingPayload,
      'updatedAt': canonicalUpdatedAt.toUtc(),
      'deletedAt': canonicalDeletedAt?.toUtc(),
      'version': canonicalVersion,
    };
    if (operation == SyncOperation.delete) {
      if (canonicalDeletedAt == null) {
        throw const RemoteScheduleProtocolException(
          'Canonical delete acknowledgement has no tombstone time.',
        );
      }
      return emailScheduleReplayPayload(
        entityType: entityType,
        payload: projected,
      );
    }
    if (canonicalDeletedAt != null) {
      throw const RemoteScheduleProtocolException(
        'Canonical upsert acknowledgement unexpectedly deleted the entity.',
      );
    }
    projected['title'] = _requiredString(outgoingPayload, 'title').trim();
    if ((projected['title']! as String).isEmpty) {
      throw const RemoteScheduleProtocolException(
        'Canonical acknowledgement has an empty title.',
      );
    }
    switch (entityType) {
      case domain.EmailCandidateType.assignment:
        projected
          ..['courseId'] = _serverNullifiedString(outgoingPayload['courseId'])
          ..['submissionUrl'] =
              _serverNullifiedString(outgoingPayload['submissionUrl'])
          ..['priority'] = _serverNullifiedString(outgoingPayload['priority'])
          ..['visibilityLevel'] = _serverDefaultedString(
              outgoingPayload['visibilityLevel'], 'PRIVATE');
      case domain.EmailCandidateType.exam:
        projected
          ..['courseId'] = _serverNullifiedString(outgoingPayload['courseId'])
          ..['room'] = _serverNullifiedString(outgoingPayload['room'])
          ..['scope'] = _serverNullifiedString(outgoingPayload['scope'])
          ..['memo'] = _serverNullifiedString(outgoingPayload['memo'])
          ..['examType'] = _serverNullifiedString(outgoingPayload['examType'])
          ..['visibilityLevel'] = _serverDefaultedString(
              outgoingPayload['visibilityLevel'], 'PRIVATE');
      case domain.EmailCandidateType.event:
        final groupId = _serverNullifiedString(outgoingPayload['groupId']);
        if (groupId != null) {
          throw const RemoteScheduleProtocolException(
            'Personal schedule sync cannot acknowledge a group event.',
          );
        }
        projected
          ..['groupId'] = null
          ..['kind'] = _serverDefaultedString(outgoingPayload['kind'], 'normal')
          ..['location'] = _serverNullifiedString(outgoingPayload['location'])
          ..['description'] =
              _serverNullifiedString(outgoingPayload['description'])
          ..['rrule'] = _serverNullifiedString(outgoingPayload['rrule'])
          ..['timezone'] = _serverDefaultedString(
            outgoingPayload['timezone'],
            domain.japanTimeZone,
          )
          ..['visibilityLevel'] = outgoingPayload.containsKey('visibilityLevel')
              ? _nullableString(outgoingPayload['visibilityLevel'])
              : 'PRIVATE';
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        throw const RemoteScheduleProtocolException(
          'Unsupported email acknowledgement entity type.',
        );
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: projected,
    );
  }

  Future<local.EmailScheduleEditReceipt> _recordRemoteAcknowledgement(
    _AcknowledgementEnvelopeMatch match, {
    required String mutationId,
    required DateTime acknowledgedAt,
  }) async {
    if (match.canonicalFingerprint == match.envelope.payloadFingerprint &&
        match.canonicalUpdatedAt
            .isAtSameMomentAs(match.envelope.entityUpdatedAt)) {
      return match.envelope;
    }
    final remoteAckId = 'remote-ack:$mutationId';
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId: remoteAckId,
            ownerUserId: match.envelope.ownerUserId,
            candidateId: match.envelope.candidateId,
            linkId: match.envelope.linkId,
            entityType: match.envelope.entityType,
            entityId: match.envelope.entityId,
            provenance: 'remote_ack',
            baseEntityVersion: match.envelope.entityVersion,
            entityVersion: match.envelope.entityVersion,
            basePayloadFingerprint: match.envelope.payloadFingerprint,
            payloadFingerprint: match.canonicalFingerprint,
            candidatePayloadFingerprint:
                match.envelope.candidatePayloadFingerprint,
            entityUpdatedAt: match.canonicalUpdatedAt,
            createdAt: emailScheduleSqliteTimestamp(acknowledgedAt),
          ),
        );
    return (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(remoteAckId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingle();
  }

  Future<void> _requireAppliedEnvelope({
    required ScheduleDeltaChange change,
    required local.EmailScheduleEditReceipt envelope,
  }) async {
    final context = await _emailLinkedContext(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (context == null ||
        context.link.id != envelope.linkId ||
        context.candidate.id != envelope.candidateId ||
        context.payload['version'] != envelope.entityVersion ||
        emailSchedulePayloadFingerprint(context.payload) !=
            envelope.payloadFingerprint ||
        !_requiredDateTime(context.payload, 'updatedAt')
            .isAtSameMomentAs(envelope.entityUpdatedAt)) {
      throw const RemoteScheduleProtocolException(
        'Canonical email-linked entity was not applied exactly.',
      );
    }
  }

  Future<void> _applyRemoteChange(
    ScheduleDeltaChange change, {
    required DateTime appliedAt,
  }) async {
    final before = await _emailLinkedContext(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (before == null) {
      await _applyChange(change);
      return;
    }
    if (_canonicalEntityType(change.entityType) == 'event' &&
        (change.payload['groupId'] != null ||
            change.payload.containsKey('isAllDay') &&
                change.payload['isAllDay'] != false)) {
      throw const RemoteScheduleProtocolException(
        'Email-linked events must remain timed personal events.',
      );
    }
    final beforeVersion = before.payload['version'];
    if (beforeVersion is! int) {
      throw const RemoteScheduleProtocolException(
        'Email-linked entity version is invalid.',
      );
    }
    if (beforeVersion > change.serverVersion) return;
    final expectedPayload = _expectedAppliedEmailPayload(
      change,
      beforePayload: before.payload,
    );
    final expectedFingerprint =
        emailSchedulePayloadFingerprint(expectedPayload);
    if (beforeVersion == change.serverVersion) {
      if (emailSchedulePayloadFingerprint(before.payload) !=
          expectedFingerprint) {
        throw const RemoteScheduleProtocolException(
          'Equal-version email delta differs from the authenticated entity.',
        );
      }
      return;
    }

    await _applyChange(change);
    final after = await _emailLinkedContext(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (after == null ||
        after.link.id != before.link.id ||
        after.candidate.id != before.candidate.id ||
        after.payload['version'] != change.serverVersion ||
        emailSchedulePayloadFingerprint(after.payload) != expectedFingerprint) {
      throw const RemoteScheduleProtocolException(
        'Remote email-linked entity was not applied exactly.',
      );
    }
    await _refreshLinkedNotification(change);
    final mutationId =
        'remote-apply:${emailSchedulePayloadFingerprint(<String, Object?>{
          'ownerUserId': ownerUserId,
          'entityType': change.entityType,
          'entityId': change.entityId,
          'changeCursor': change.changeCursor,
          'serverVersion': change.serverVersion,
        })}';
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId: mutationId,
            ownerUserId: ownerUserId,
            candidateId: after.candidate.id,
            linkId: after.link.id,
            entityType: change.entityType,
            entityId: change.entityId,
            provenance: 'remote_apply',
            baseEntityVersion: beforeVersion,
            entityVersion: change.serverVersion,
            basePayloadFingerprint:
                emailSchedulePayloadFingerprint(before.payload),
            payloadFingerprint: expectedFingerprint,
            candidatePayloadFingerprint:
                emailCandidatePayloadFingerprint(after.candidatePayload),
            entityUpdatedAt: _requiredDateTime(expectedPayload, 'updatedAt'),
            createdAt: emailScheduleSqliteTimestamp(appliedAt),
          ),
        );
  }

  Future<void> _requirePersonalEmailEventCanonical(
    ScheduleDeltaChange change,
  ) async {
    if (_canonicalEntityType(change.entityType) != 'event' ||
        change.payload['groupId'] == null &&
            (!change.payload.containsKey('isAllDay') ||
                change.payload['isAllDay'] == false)) {
      return;
    }
    final linked = await _emailLinkedContext(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (linked != null) {
      throw const RemoteScheduleProtocolException(
        'Email-linked events must remain timed personal events.',
      );
    }
  }

  Future<void> _refreshLinkedNotification(
    ScheduleDeltaChange change,
  ) async {
    final context = await _emailLinkedContext(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (context == null) return;
    final request = await (db.select(db.notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.sourceId.equals(context.candidate.id) &
              row.entityType.equals(change.entityType) &
              row.entityId.equals(change.entityId) &
              row.idempotencyKey.equals(
                context.candidate.confirmationIdempotencyKey!,
              )))
        .getSingleOrNull();
    final expectedAllDay = change.entityType == 'assignment' &&
        context.candidatePayload.due.allDay;
    final expectedTimezone =
        context.candidatePayload.due.timezone ?? domain.JapanTime.timeZone;
    final expectedReminders =
        jsonEncode(context.candidatePayload.suggestedRemindersMinutes);
    if (request == null ||
        request.allDay != expectedAllDay ||
        request.timezone != expectedTimezone ||
        request.remindersMinutesJson != expectedReminders) {
      throw const RemoteScheduleProtocolException(
        'Email notification policy differs from its candidate.',
      );
    }
    final companion = change.operation == ScheduleDeltaOperation.delete
        ? local.NotificationScheduleRequestsCompanion(
            state: const Value('cancelled'),
            updatedAt: Value(_requiredDateTime(context.payload, 'updatedAt')),
          )
        : local.NotificationScheduleRequestsCompanion(
            anchorAt: Value(
              _requiredDateTime(
                context.payload,
                change.entityType == 'assignment' ? 'dueAt' : 'startAt',
              ),
            ),
            state: const Value('pending'),
            updatedAt: Value(_requiredDateTime(context.payload, 'updatedAt')),
          );
    final changed = await (db.update(db.notificationScheduleRequests)
          ..where((row) =>
              row.id.equals(request.id) & row.ownerUserId.equals(ownerUserId)))
        .write(companion);
    if (changed != 1) {
      throw StateError('Email notification request changed during sync.');
    }
  }

  Future<_EmailLinkedScheduleContext?> _emailLinkedContext({
    required String entityType,
    required String entityId,
  }) async {
    if (entityType != 'assignment' &&
        entityType != 'exam' &&
        entityType != 'event') {
      return null;
    }
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.entityType.equals(entityType) &
              row.entityId.equals(entityId)))
        .getSingleOrNull();
    if (link == null) return null;
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: link.candidateId,
    );
    if (candidate == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityType != entityType ||
        candidate.linkedEntityId != entityId ||
        candidate.confirmationIdempotencyKey !=
            link.confirmationIdempotencyKey) {
      throw const RemoteScheduleProtocolException(
        'Email schedule provenance graph is inconsistent.',
      );
    }
    final domain.EmailCandidatePayload candidatePayload;
    try {
      candidatePayload = const domain.EmailCandidatePayloadCodec().decode(
        candidate.normalizedPayloadJson,
      );
    } on domain.EmailCandidateValidationException {
      throw const RemoteScheduleProtocolException(
        'Email candidate payload is invalid.',
      );
    }
    final payload = await _currentEmailEntityPayload(
      entityType: entityType,
      entityId: entityId,
    );
    return _EmailLinkedScheduleContext(
      link: link,
      candidate: candidate,
      candidatePayload: candidatePayload,
      payload: payload,
    );
  }

  Future<Map<String, Object?>> _currentEmailEntityPayload({
    required String entityType,
    required String entityId,
  }) async {
    final Map<String, Object?> payload;
    final domain.EmailCandidateType type;
    switch (entityType) {
      case 'assignment':
        type = domain.EmailCandidateType.assignment;
        final row = await (db.select(db.assignments)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) {
          throw const RemoteScheduleProtocolException(
            'Email-linked assignment is unavailable.',
          );
        }
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
      case 'exam':
        type = domain.EmailCandidateType.exam;
        final row = await (db.select(db.exams)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) {
          throw const RemoteScheduleProtocolException(
            'Email-linked exam is unavailable.',
          );
        }
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
      case 'event':
        type = domain.EmailCandidateType.event;
        final row = await (db.select(db.events)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) {
          throw const RemoteScheduleProtocolException(
            'Email-linked event is unavailable.',
          );
        }
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
      default:
        throw const RemoteScheduleProtocolException(
          'Unsupported email-linked entity type.',
        );
    }
    return emailScheduleReplayPayload(entityType: type, payload: payload);
  }

  Map<String, Object?> _canonicalEmailPayload(
    ScheduleDeltaChange change,
  ) {
    final type = domain.EmailCandidateType.fromWire(change.entityType);
    return emailScheduleReplayPayload(
      entityType: type,
      payload: change.payload,
    );
  }

  Map<String, Object?> _expectedAppliedEmailPayload(
    ScheduleDeltaChange change, {
    required Map<String, Object?> beforePayload,
  }) {
    if (change.operation != ScheduleDeltaOperation.delete) {
      return _canonicalEmailPayload(change);
    }
    final canonicalTransport = _canonicalEmailPayload(change);
    final merged = <String, Object?>{...beforePayload};
    for (final key in canonicalTransport.keys) {
      // A retained tombstone can be the compact identity/version envelope, or
      // a full entity snapshot after one or more remote edits. Authenticate
      // every canonical field the server actually supplied while retaining
      // prior values only for fields that are genuinely absent.
      if (change.payload.containsKey(key)) {
        merged[key] = canonicalTransport[key];
      }
    }
    return emailScheduleReplayPayload(
      entityType: domain.EmailCandidateType.fromWire(change.entityType),
      payload: {
        ...merged,
        'updatedAt': _requiredDateTime(change.payload, 'updatedAt'),
        'deletedAt': _requiredDateTime(change.payload, 'deletedAt'),
        'version': change.serverVersion,
      },
    );
  }

  void _validateAck(PendingMutation mutation, ScheduleMutationAck ack) {
    if (mutation.ownerUserId != ownerUserId ||
        ack.clientMutationId != mutation.clientMutationId ||
        _canonicalEntityType(ack.entityType) !=
            _canonicalEntityType(mutation.entityType) ||
        ack.entityId != mutation.entityId ||
        ack.operation != mutation.operation ||
        ack.change.entityType != _canonicalEntityType(mutation.entityType) ||
        ack.change.entityId != mutation.entityId) {
      throw const RemoteScheduleProtocolException(
        'Mutation acknowledgement escaped its owner or entity scope.',
      );
    }
    _validateChange(ack.change);
  }

  void _validatePage(ScheduleDeltaPage page) {
    if (page.afterCursor < 0 ||
        page.nextCursor < page.afterCursor ||
        (page.hasMore && page.nextCursor == page.afterCursor)) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta cursor envelope is invalid.',
      );
    }
    var previousCursor = page.afterCursor;
    for (final change in page.changes) {
      if (change.changeCursor <= previousCursor ||
          change.changeCursor > page.nextCursor) {
        throw const RemoteScheduleProtocolException(
          'Schedule delta changes are not strictly ordered.',
        );
      }
      _validateChange(change);
      previousCursor = change.changeCursor;
    }
    if (page.changes.isNotEmpty &&
        page.changes.last.changeCursor != page.nextCursor) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta next cursor does not match its last change.',
      );
    }
  }

  void _validateChange(ScheduleDeltaChange change) {
    if (!scheduleSyncEntityTypes.contains(change.entityType) ||
        change.entityId.trim().isEmpty ||
        change.serverVersion < 1) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta identity is invalid.',
      );
    }
    final payload = change.payload;
    if (utf8.encode(jsonEncode(payload)).length >
        maximumCanonicalPayloadBytes) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta payload exceeds the local safety bound.',
      );
    }
    final payloadId = change.entityType == 'assignment_user_state'
        ? payload['assignmentId']
        : payload['id'];
    final payloadOwner = change.entityType == 'assignment_user_state'
        ? payload['userId']
        : payload['ownerUserId'];
    if (payloadId != change.entityId || payloadOwner != ownerUserId) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta payload escaped its authenticated owner.',
      );
    }
    if (_requiredInt(payload, 'version') != change.serverVersion) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta version does not match its payload.',
      );
    }
    final payloadDeletedAt = _nullableDateTime(payload['deletedAt']);
    if (change.operation == ScheduleDeltaOperation.delete) {
      if (change.deletedAt == null || payloadDeletedAt == null) {
        throw const RemoteScheduleProtocolException(
          'A delete delta must contain a tombstone timestamp.',
        );
      }
    } else if (change.deletedAt != null || payloadDeletedAt != null) {
      throw const RemoteScheduleProtocolException(
        'An upsert delta cannot contain a tombstone timestamp.',
      );
    }
  }

  Future<void> _applyChange(ScheduleDeltaChange change) {
    if (change.operation == ScheduleDeltaOperation.delete) {
      return _applyTombstone(change);
    }
    return switch (change.entityType) {
      'user_course' => _upsertCourse(change),
      'course_template_publish' => Future<void>.value(),
      'course_template_update_apply' => _applyTemplateUpdate(change),
      'assignment' => _upsertAssignment(change),
      'assignment_user_state' => _upsertAssignmentState(change),
      'exam' => _upsertExam(change),
      'event' => _upsertEvent(change),
      'event_exception' => _upsertEventException(change),
      _ => throw RemoteScheduleProtocolException(
          'Unsupported schedule entity type: ${change.entityType}',
        ),
    };
  }

  Future<void> _upsertCourse(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final existing = await (db.select(db.userCourses)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.timetableDao.upsertCourse(
      local.UserCoursesCompanion.insert(
        id: change.entityId,
        ownerUserId: ownerUserId,
        termId: _requiredString(payload, 'termId'),
        sourceTemplateId: Value(_nullableString(payload['sourceTemplateId'])),
        title: _requiredString(payload, 'title'),
        normalizedTitle: _requiredString(payload, 'normalizedTitle'),
        instructorName: Value(_nullableString(payload['instructorName'])),
        normalizedInstructorName:
            Value(_nullableString(payload['normalizedInstructorName'])),
        dayOfWeek: Value(_nullableInt(payload['dayOfWeek'])),
        periodNo: Value(_nullableInt(payload['periodNo'])),
        room: Value(_nullableString(payload['room'])),
        color: Value(_nullableString(payload['color'])),
        visibilityLevel: Value(_requiredString(payload, 'visibilityLevel')),
        updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
        deletedAt: const Value(null),
        version: Value(change.serverVersion),
      ),
    );
  }

  Future<void> _applyTemplateUpdate(ScheduleDeltaChange change) async {
    final payload = change.payload;
    await (db.update(db.userCourses)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId) &
                row.version.isSmallerOrEqualValue(change.serverVersion),
          ))
        .write(
      local.UserCoursesCompanion(
        sourceTemplateId: Value(_nullableString(payload['sourceTemplateId'])),
        title: Value(_requiredString(payload, 'title')),
        normalizedTitle: Value(_requiredString(payload, 'normalizedTitle')),
        instructorName: Value(_nullableString(payload['instructorName'])),
        normalizedInstructorName:
            Value(_nullableString(payload['normalizedInstructorName'])),
        dayOfWeek: Value(_nullableInt(payload['dayOfWeek'])),
        periodNo: Value(_nullableInt(payload['periodNo'])),
        room: Value(_nullableString(payload['room'])),
        updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
        version: Value(change.serverVersion),
      ),
    );
  }

  Future<void> _upsertAssignment(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final existing = await (db.select(db.assignments)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.assignmentDao.upsertAssignment(
      local.AssignmentsCompanion.insert(
        id: change.entityId,
        ownerUserId: ownerUserId,
        courseId: Value(_nullableString(payload['courseId'])),
        title: _requiredString(payload, 'title'),
        description: Value(_nullableString(payload['memo'])),
        submissionUrl: Value(_nullableString(payload['submissionUrl'])),
        priority: Value(_nullableString(payload['priority'])),
        dueAt: _requiredDateTime(payload, 'dueAt'),
        visibilityLevel: Value(_requiredString(payload, 'visibilityLevel')),
        updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
        deletedAt: const Value(null),
        version: Value(change.serverVersion),
      ),
    );
  }

  Future<void> _upsertAssignmentState(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final existing = await (db.select(db.assignmentUserStates)
          ..where(
            (row) =>
                row.assignmentId.equals(change.entityId) &
                row.userId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.into(db.assignmentUserStates).insertOnConflictUpdate(
          local.AssignmentUserStatesCompanion.insert(
            assignmentId: change.entityId,
            userId: ownerUserId,
            status: Value(_requiredString(payload, 'status')),
            submittedAt: Value(_nullableDateTime(payload['submittedAt'])),
            note: Value(_nullableString(payload['note'])),
            updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
            deletedAt: const Value(null),
            version: Value(change.serverVersion),
          ),
        );
  }

  Future<void> _upsertExam(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final existing = await (db.select(db.exams)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.examDao.upsertExam(
      local.ExamsCompanion.insert(
        id: change.entityId,
        ownerUserId: ownerUserId,
        courseId: Value(_nullableString(payload['courseId'])),
        title: _requiredString(payload, 'title'),
        startAt: _requiredDateTime(payload, 'startAt'),
        endAt: _requiredDateTime(payload, 'endAt'),
        room: Value(_nullableString(payload['room'])),
        scope: Value(_nullableString(payload['scope'])),
        memo: Value(_nullableString(payload['memo'])),
        examType: Value(_nullableString(payload['examType'])),
        visibilityLevel: Value(_requiredString(payload, 'visibilityLevel')),
        updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
        deletedAt: const Value(null),
        version: Value(change.serverVersion),
      ),
    );
  }

  Future<void> _upsertEvent(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final groupId = _nullableString(payload['groupId']);
    final rawIsAllDay = payload['isAllDay'];
    if (rawIsAllDay != null && rawIsAllDay is! bool) {
      throw const RemoteScheduleProtocolException(
        'Event all-day state is invalid.',
      );
    }
    final isAllDay = rawIsAllDay == true;
    final timezone = _requiredString(payload, 'timezone');
    if (!domain.JapanTime.isSupportedTimeZone(timezone)) {
      throw const RemoteScheduleProtocolException(
        'This client supports only Asia/Tokyo schedule events.',
      );
    }
    final existing = await (db.select(db.events)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.eventDao.upsertEvent(
      local.EventsCompanion.insert(
        id: change.entityId,
        ownerUserId: ownerUserId,
        calendarId: _requiredString(payload, 'calendarId'),
        groupId: Value(groupId),
        title: _requiredString(payload, 'title'),
        kind: _requiredString(payload, 'kind'),
        startAt: _requiredDateTime(payload, 'startAt'),
        endAt: _requiredDateTime(payload, 'endAt'),
        isAllDay: Value(isAllDay),
        location: Value(_nullableString(payload['location'])),
        description: Value(_nullableString(payload['description'])),
        rrule: Value(_nullableString(payload['rrule'])),
        timezone: Value(timezone),
        visibilityLevel: payload.containsKey('visibilityLevel')
            ? Value(_nullableString(payload['visibilityLevel']))
            : existing == null
                ? const Value('PRIVATE')
                : Value(existing.visibilityLevel),
        updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
        deletedAt: const Value(null),
        version: Value(change.serverVersion),
      ),
    );
  }

  Future<void> _upsertEventException(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final existing = await (db.select(db.eventExceptions)
          ..where(
            (row) =>
                row.id.equals(change.entityId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (existing != null && existing.version > change.serverVersion) return;
    await db.into(db.eventExceptions).insertOnConflictUpdate(
          local.EventExceptionsCompanion.insert(
            id: change.entityId,
            ownerUserId: ownerUserId,
            eventId: _requiredString(payload, 'eventId'),
            recurrenceId: _requiredDateTime(payload, 'recurrenceId'),
            mode: _requiredString(payload, 'mode'),
            overrideStartAt: Value(
              _nullableDateTime(payload['overrideStartAt']),
            ),
            overrideEndAt: Value(
              _nullableDateTime(payload['overrideEndAt']),
            ),
            overridePayloadJson: Value(
              _encodeEventExceptionOverridePayload(payload),
            ),
            updatedAt: Value(_requiredDateTime(payload, 'updatedAt')),
            deletedAt: const Value(null),
            version: Value(change.serverVersion),
          ),
        );
  }

  Future<void> _applyTombstone(ScheduleDeltaChange change) async {
    final payload = change.payload;
    final deletedAt = _requiredDateTime(payload, 'deletedAt');
    final updatedAt = _requiredDateTime(payload, 'updatedAt');
    final changed = switch (change.entityType) {
      'user_course' => await (db.update(db.userCourses)
              ..where(
                (row) =>
                    row.id.equals(change.entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.UserCoursesCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      'assignment' => await (db.update(db.assignments)
              ..where(
                (row) =>
                    row.id.equals(change.entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.AssignmentsCompanion(
            courseId: payload.containsKey('courseId')
                ? Value(_nullableString(payload['courseId']))
                : const Value.absent(),
            title: payload.containsKey('title')
                ? Value(_requiredString(payload, 'title'))
                : const Value.absent(),
            description: payload.containsKey('memo')
                ? Value(_nullableString(payload['memo']))
                : const Value.absent(),
            submissionUrl: payload.containsKey('submissionUrl')
                ? Value(_nullableString(payload['submissionUrl']))
                : const Value.absent(),
            priority: payload.containsKey('priority')
                ? Value(_nullableString(payload['priority']))
                : const Value.absent(),
            dueAt: payload.containsKey('dueAt')
                ? Value(_requiredDateTime(payload, 'dueAt'))
                : const Value.absent(),
            visibilityLevel: payload.containsKey('visibilityLevel')
                ? Value(_requiredString(payload, 'visibilityLevel'))
                : const Value.absent(),
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      'assignment_user_state' => await (db.update(db.assignmentUserStates)
              ..where(
                (row) =>
                    row.assignmentId.equals(change.entityId) &
                    row.userId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.AssignmentUserStatesCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      'exam' => await (db.update(db.exams)
              ..where(
                (row) =>
                    row.id.equals(change.entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.ExamsCompanion(
            courseId: payload.containsKey('courseId')
                ? Value(_nullableString(payload['courseId']))
                : const Value.absent(),
            title: payload.containsKey('title')
                ? Value(_requiredString(payload, 'title'))
                : const Value.absent(),
            startAt: payload.containsKey('startAt')
                ? Value(_requiredDateTime(payload, 'startAt'))
                : const Value.absent(),
            endAt: payload.containsKey('endAt')
                ? Value(_requiredDateTime(payload, 'endAt'))
                : const Value.absent(),
            room: payload.containsKey('room')
                ? Value(_nullableString(payload['room']))
                : const Value.absent(),
            scope: payload.containsKey('scope')
                ? Value(_nullableString(payload['scope']))
                : const Value.absent(),
            memo: payload.containsKey('memo')
                ? Value(_nullableString(payload['memo']))
                : const Value.absent(),
            examType: payload.containsKey('examType')
                ? Value(_nullableString(payload['examType']))
                : const Value.absent(),
            visibilityLevel: payload.containsKey('visibilityLevel')
                ? Value(_requiredString(payload, 'visibilityLevel'))
                : const Value.absent(),
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      'event' => await (db.update(db.events)
              ..where(
                (row) =>
                    row.id.equals(change.entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.EventsCompanion(
            calendarId: payload.containsKey('calendarId')
                ? Value(_requiredString(payload, 'calendarId'))
                : const Value.absent(),
            groupId: payload.containsKey('groupId')
                ? Value(_nullableString(payload['groupId']))
                : const Value.absent(),
            title: payload.containsKey('title')
                ? Value(_requiredString(payload, 'title'))
                : const Value.absent(),
            kind: payload.containsKey('kind')
                ? Value(_requiredString(payload, 'kind'))
                : const Value.absent(),
            startAt: payload.containsKey('startAt')
                ? Value(_requiredDateTime(payload, 'startAt'))
                : const Value.absent(),
            endAt: payload.containsKey('endAt')
                ? Value(_requiredDateTime(payload, 'endAt'))
                : const Value.absent(),
            isAllDay: payload.containsKey('isAllDay')
                ? Value(_requiredEventAllDay(payload['isAllDay']))
                : const Value.absent(),
            location: payload.containsKey('location')
                ? Value(_nullableString(payload['location']))
                : const Value.absent(),
            description: payload.containsKey('description')
                ? Value(_nullableString(payload['description']))
                : const Value.absent(),
            rrule: payload.containsKey('rrule')
                ? Value(_nullableString(payload['rrule']))
                : const Value.absent(),
            timezone: payload.containsKey('timezone')
                ? Value(_requiredString(payload, 'timezone'))
                : const Value.absent(),
            visibilityLevel: payload.containsKey('visibilityLevel')
                ? Value(_nullableString(payload['visibilityLevel']))
                : const Value.absent(),
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      'event_exception' => await (db.update(db.eventExceptions)
              ..where(
                (row) =>
                    row.id.equals(change.entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.version.isSmallerOrEqualValue(change.serverVersion),
              ))
            .write(
          local.EventExceptionsCompanion(
            deletedAt: Value(deletedAt),
            updatedAt: Value(updatedAt),
            version: Value(change.serverVersion),
          ),
        ),
      _ => throw RemoteScheduleProtocolException(
          'Unsupported schedule entity type: ${change.entityType}',
        ),
    };
    if (changed == 0 && change.entityType == 'assignment_user_state') {
      final existing = await (db.select(db.assignmentUserStates)
            ..where(
              (row) =>
                  row.assignmentId.equals(change.entityId) &
                  row.userId.equals(ownerUserId),
            ))
          .getSingleOrNull();
      if (existing == null) {
        // Unlike an unknown entity tombstone, Assignment state is mutable again
        // through Submit. Preserve the canonical deleted version so a fresh
        // device can later send the exact resurrection baseVersion.
        await db.into(db.assignmentUserStates).insert(
              local.AssignmentUserStatesCompanion.insert(
                assignmentId: change.entityId,
                userId: ownerUserId,
                status: Value(_requiredString(payload, 'status')),
                submittedAt: Value(
                  _nullableDateTime(payload['submittedAt']),
                ),
                note: Value(_nullableString(payload['note'])),
                updatedAt: Value(updatedAt),
                deletedAt: Value(deletedAt),
                version: Value(change.serverVersion),
              ),
            );
      }
      return;
    }
    // A cursor-0 client can legitimately see a retained/backfilled tombstone
    // for an immutable/absent entity it never materialized. It is already
    // absent locally, so a zero-row update is an idempotent success.
    if (changed == 0) return;
  }
}

class _EmailLinkedScheduleContext {
  const _EmailLinkedScheduleContext({
    required this.link,
    required this.candidate,
    required this.candidatePayload,
    required this.payload,
  });

  final local.EmailScheduleEntityLink link;
  final local.EmailCandidate candidate;
  final domain.EmailCandidatePayload candidatePayload;
  final Map<String, Object?> payload;
}

class _AcknowledgementEnvelopeMatch {
  const _AcknowledgementEnvelopeMatch({
    required this.envelope,
    required this.canonicalFingerprint,
    required this.canonicalUpdatedAt,
  });

  final local.EmailScheduleEditReceipt envelope;
  final String canonicalFingerprint;
  final DateTime canonicalUpdatedAt;
}

Map<String, Object?> _decodePayload(String raw) {
  if (utf8.encode(raw).length >
      DriftScheduleSyncStore.maximumCanonicalPayloadBytes) {
    throw const RemoteScheduleProtocolException(
      'Stored conflict payload exceeds the local safety bound.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const RemoteScheduleProtocolException(
      'Stored conflict payload is malformed.',
    );
  }
  if (decoded is! Map) {
    throw const RemoteScheduleProtocolException(
      'Stored conflict payload must be an object.',
    );
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

String _canonicalEntityType(String value) {
  return value == 'assignment_state' ? 'assignment_user_state' : value;
}

Set<String> _logicalEntityTypes(String value) {
  if (value == 'user_course' ||
      value == 'course_template_publish' ||
      value == 'course_template_update_apply') {
    return const {
      'user_course',
      'course_template_publish',
      'course_template_update_apply',
    };
  }
  return {value};
}

String _requiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw RemoteScheduleProtocolException('$key is missing from sync payload.');
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  throw const RemoteScheduleProtocolException(
    'A sync payload string is malformed.',
  );
}

String? _serverNullifiedString(Object? value) {
  final text = _nullableString(value);
  return text == null || text.isEmpty ? null : text;
}

String _serverDefaultedString(Object? value, String fallback) {
  return _serverNullifiedString(value) ?? fallback;
}

String _encodeEventExceptionOverridePayload(Map<String, Object?> payload) {
  return jsonEncode({
    'title': _nullableString(payload['overrideTitle']),
    'location': _nullableString(payload['overrideLocation']),
    'description': _nullableString(payload['overrideDescription']),
    'visibilityLevel': _nullableString(payload['overrideVisibility']),
  });
}

int _requiredInt(Map<String, Object?> payload, String key) {
  final value = _nullableInt(payload[key]);
  if (value != null) return value;
  throw RemoteScheduleProtocolException('$key is missing from sync payload.');
}

int? _nullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  throw const RemoteScheduleProtocolException(
    'A sync payload integer is malformed.',
  );
}

DateTime _requiredDateTime(Map<String, Object?> payload, String key) {
  final value = _nullableDateTime(payload[key]);
  if (value != null) return value;
  throw RemoteScheduleProtocolException('$key is missing from sync payload.');
}

DateTime? _nullableDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return emailScheduleSqliteTimestamp(value);
  if (value is String) {
    final normalized = value.trim();
    if (!_hasExplicitUtcOffset(normalized)) {
      throw const RemoteScheduleProtocolException(
        'A sync payload timestamp must include an explicit UTC offset.',
      );
    }
    final parsed = DateTime.tryParse(normalized);
    if (parsed != null) return emailScheduleSqliteTimestamp(parsed);
  }
  throw const RemoteScheduleProtocolException(
    'A sync payload timestamp is malformed.',
  );
}

bool _requiredEventAllDay(Object? value) {
  if (value is bool) return value;
  throw const RemoteScheduleProtocolException(
    'Event all-day state is invalid.',
  );
}

bool _hasExplicitUtcOffset(String value) {
  return RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(value);
}
