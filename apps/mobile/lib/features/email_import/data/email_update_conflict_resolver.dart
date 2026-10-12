import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart' as domain;

import '../../../local_db/app_database.dart' as local;
import '../../../local_db/email_import_identity.dart';
import 'email_candidate_dedupe.dart';

/// Converts an accepted email update into an explicit rejection when the user
/// chooses the canonical server copy for its schedule mutation conflict.
///
/// This runs inside [DriftScheduleSyncStore]'s transaction before the generic
/// queue row becomes terminal. That ordering prevents a server-wins queue
/// completion from ever releasing the old `accepted` reconciliation receipt.
class EmailUpdateConflictResolver {
  EmailUpdateConflictResolver(
    this.db, {
    domain.EmailCandidatePayloadCodec candidateCodec =
        const domain.EmailCandidatePayloadCodec(),
  }) : _candidateCodec = candidateCodec;

  final local.AppDatabase db;
  final domain.EmailCandidatePayloadCodec _candidateCodec;

  Future<bool> supersedeAcceptedUpdate({
    required String ownerUserId,
    required String clientMutationId,
    required String? mutationIdempotencyKey,
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> canonicalPayload,
    required bool canonicalDeleted,
    required DateTime resolvedAt,
  }) async {
    final receipts = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.requiredSyncMutationId.equals(clientMutationId)))
        .get();
    final acceptedUpdateReceipts = receipts
        .where(
          (receipt) =>
              receipt.action == 'update' && receipt.resolution == 'accepted',
        )
        .toList(growable: false);
    // Confirmation receipts can also depend on schedule mutations. A generic
    // server-wins decision must not reinterpret those as update rejections.
    if (acceptedUpdateReceipts.isEmpty) {
      if (operation == 'create') {
        if (receipts.isEmpty) return false;
        return _appendConfirmationConflict(
          ownerUserId: ownerUserId,
          clientMutationId: clientMutationId,
          entityType: entityType,
          entityId: entityId,
          canonicalPayload: canonicalPayload,
          canonicalDeleted: canonicalDeleted,
          resolvedAt: resolvedAt,
          receipts: receipts,
        );
      }
      return _replaceOrdinaryEditConflict(
        ownerUserId: ownerUserId,
        clientMutationId: clientMutationId,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        canonicalPayload: canonicalPayload,
        canonicalDeleted: canonicalDeleted,
        resolvedAt: resolvedAt,
      );
    }
    if (receipts.length != 1 || acceptedUpdateReceipts.length != 1) {
      throw StateError('Email update conflict receipt is ambiguous.');
    }
    final receipt = acceptedUpdateReceipts.single;
    if (operation != 'update' ||
        receipt.action != 'update' ||
        receipt.resolution != 'accepted' ||
        receipt.state != 'pending' ||
        receipt.scheduleAckedAt != null ||
        receipt.entityType != entityType ||
        receipt.entityId != entityId ||
        mutationIdempotencyKey == null ||
        receipt.idempotencyKey != mutationIdempotencyKey ||
        receipt.requiredSyncMutationId != clientMutationId) {
      throw StateError('Email update conflict receipt is not resolvable.');
    }

    final proposal = await db.emailImportDao.candidateUpdateById(
      ownerUserId: ownerUserId,
      updateId: receipt.localReferenceId,
    );
    if (proposal == null ||
        proposal.state != 'accepted' ||
        proposal.resolutionIdempotencyKey != receipt.idempotencyKey ||
        proposal.resolvedAt == null) {
      throw StateError('Accepted email update proposal is unavailable.');
    }
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: proposal.candidateId,
    );
    if (candidate == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityType != entityType ||
        candidate.linkedEntityId != entityId ||
        candidate.confirmationIdempotencyKey == null) {
      throw StateError('Linked email candidate is unavailable.');
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
    if (source == null ||
        connection == null ||
        receipt.connectionId != source.connectionId ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
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
            )) {
      throw StateError('Email update conflict source is unavailable.');
    }
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidate.id) &
              row.entityType.equals(entityType) &
              row.entityId.equals(entityId) &
              row.confirmationIdempotencyKey
                  .equals(candidate.confirmationIdempotencyKey!)))
        .getSingleOrNull();
    if (link == null) {
      throw StateError('Email update conflict link is unavailable.');
    }

    final acceptedPayload = _decodeCandidate(candidate.normalizedPayloadJson);
    final proposedPayload = _decodeCandidate(proposal.proposedPayloadJson);
    if (_candidateCodec.encode(acceptedPayload) !=
            _candidateCodec.encode(proposedPayload) ||
        emailCandidateUpdateFingerprint(proposedPayload) !=
            proposal.semanticFingerprint ||
        proposedPayload.candidateType.wireName != entityType) {
      throw StateError('Accepted email update payload is inconsistent.');
    }
    final alignedPayload = _alignedPayload(
      proposedPayload: proposedPayload,
      fieldDiffJson: proposal.fieldDiffJson,
      canonicalPayload: canonicalPayload,
      canonicalDeleted: canonicalDeleted,
    );
    final now = emailScheduleSqliteTimestamp(resolvedAt);
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final serverVersion = canonicalPayload['version'];
    final serverUpdatedAt = _dateTime(canonicalPayload['updatedAt']);
    final outgoingPayload =
        mutation == null ? null : _decodeCanonicalPayload(mutation.payloadJson);
    if (mutation == null ||
        mutation.status != 'conflict' ||
        mutation.operation != 'update' ||
        mutation.entityType != entityType ||
        mutation.entityId != entityId ||
        mutation.baseVersion != proposal.baseEntityVersion ||
        serverVersion is! int ||
        serverVersion < 1 ||
        serverUpdatedAt == null ||
        outgoingPayload == null) {
      throw StateError('Email update conflict mutation is unavailable.');
    }
    final receiptEntityType = domain.EmailCandidateType.fromWire(entityType);
    final canonicalOutgoingPayload = await _currentEntityPayload(
      ownerUserId: ownerUserId,
      entityType: receiptEntityType,
      entityId: entityId,
    );
    final canonicalWinningPayload = _canonicalConflictPayload(
      entityType: receiptEntityType,
      currentPayload: canonicalOutgoingPayload,
      transportPayload: canonicalPayload,
      canonicalDeleted: canonicalDeleted,
    );
    final losingEnvelope = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final currentVersion = canonicalOutgoingPayload['version'];
    final currentUpdatedAt = _dateTime(canonicalOutgoingPayload['updatedAt']);
    final legacyTip = losingEnvelope?.provenance == 'legacy_trusted_tip';
    if (losingEnvelope == null ||
        losingEnvelope.candidateId != candidate.id ||
        losingEnvelope.linkId != link.id ||
        losingEnvelope.entityType != entityType ||
        losingEnvelope.entityId != entityId ||
        losingEnvelope.provenance != 'accepted_update' && !legacyTip ||
        (legacyTip
            ? losingEnvelope.baseEntityVersion > proposal.baseEntityVersion
            : losingEnvelope.baseEntityVersion != proposal.baseEntityVersion) ||
        losingEnvelope.entityVersion != currentVersion ||
        losingEnvelope.payloadFingerprint !=
            emailSchedulePayloadFingerprint(canonicalOutgoingPayload) ||
        losingEnvelope.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(proposedPayload) ||
        currentUpdatedAt == null ||
        !losingEnvelope.entityUpdatedAt.isAtSameMomentAs(currentUpdatedAt) ||
        (legacyTip
            ? serverVersion < losingEnvelope.entityVersion
            : serverVersion <= losingEnvelope.baseEntityVersion)) {
      throw StateError('Accepted email update provenance is not the tip.');
    }
    final rejectionKey = 'email-update-server-wins-reject:${proposal.id}';
    if (rejectionKey.length > 200 || rejectionKey == receipt.idempotencyKey) {
      throw StateError('Email update rejection identity is invalid.');
    }

    final candidateChanged = await (db.update(db.emailCandidates)
          ..where((row) =>
              row.id.equals(candidate.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.reviewState.equals('confirmed') &
              row.linkedEntityType.equals(entityType) &
              row.linkedEntityId.equals(entityId)))
        .write(
      local.EmailCandidatesCompanion(
        normalizedPayloadJson: Value(_candidateCodec.encode(alignedPayload)),
        semanticFingerprint:
            Value(emailCandidateSemanticFingerprint(alignedPayload)),
        updatedAt: Value(now),
      ),
    );
    _requireOne(candidateChanged, 'email candidate');
    await _restoreNotification(
      ownerUserId: ownerUserId,
      candidate: candidate,
      entityType: entityType,
      entityId: entityId,
      payload: alignedPayload,
      canonicalDeleted: canonicalDeleted,
      now: now,
    );
    if (!legacyTip) {
      final removedEnvelope = await (db.delete(db.emailScheduleEditReceipts)
            ..where((row) =>
                row.mutationId.equals(clientMutationId) &
                row.ownerUserId.equals(ownerUserId) &
                row.provenance.equals('accepted_update') &
                row.payloadFingerprint
                    .equals(losingEnvelope.payloadFingerprint)))
          .go();
      _requireOne(removedEnvelope, 'accepted update provenance');
    }
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId:
                legacyTip ? 'server-wins:$clientMutationId' : clientMutationId,
            ownerUserId: ownerUserId,
            candidateId: candidate.id,
            linkId: link.id,
            entityType: entityType,
            entityId: entityId,
            provenance: 'server_wins',
            baseEntityVersion: legacyTip
                ? losingEnvelope.entityVersion
                : losingEnvelope.baseEntityVersion,
            entityVersion: serverVersion,
            basePayloadFingerprint: legacyTip
                ? losingEnvelope.payloadFingerprint
                : losingEnvelope.basePayloadFingerprint,
            payloadFingerprint:
                emailSchedulePayloadFingerprint(canonicalWinningPayload),
            candidatePayloadFingerprint:
                emailCandidatePayloadFingerprint(alignedPayload),
            entityUpdatedAt: serverUpdatedAt,
            createdAt: now,
          ),
        );

    final proposalChanged = await (db.update(db.emailCandidateUpdates)
          ..where((row) =>
              row.id.equals(proposal.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.state.equals('accepted') &
              row.resolutionIdempotencyKey.equals(receipt.idempotencyKey)))
        .write(
      local.EmailCandidateUpdatesCompanion(
        state: const Value('superseded'),
        resolutionIdempotencyKey: Value(rejectionKey),
        resolvedAt: Value(now),
        errorCategory: const Value(null),
        updatedAt: Value(now),
      ),
    );
    _requireOne(proposalChanged, 'email update proposal');

    final removed = await (db.delete(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals(receipt.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.state.equals('pending') &
              row.resolution.equals('accepted') &
              row.scheduleAckedAt.isNull() &
              row.requiredSyncMutationId.equals(clientMutationId)))
        .go();
    _requireOne(removed, 'accepted reconciliation receipt');
    await db.into(db.emailReconciliationReceipts).insert(
          local.EmailReconciliationReceiptsCompanion.insert(
            id: receipt.id,
            ownerUserId: ownerUserId,
            connectionId: receipt.connectionId,
            action: 'update',
            localReferenceId: proposal.id,
            provider: receipt.provider,
            providerAccountHash: receipt.providerAccountHash,
            providerMessageIdHash: receipt.providerMessageIdHash,
            providerThreadIdHash: receipt.providerThreadIdHash,
            sanitizedContentHash: receipt.sanitizedContentHash,
            resolution: const Value('rejected'),
            entityType: Value(entityType),
            entityId: Value(entityId),
            idempotencyKey: rejectionKey,
            requiredSyncMutationId: const Value(null),
            scheduleAckedAt: const Value(null),
            createdAt: Value(receipt.createdAt),
            updatedAt: Value(now),
          ),
        );
    return true;
  }

  Future<bool> _appendConfirmationConflict({
    required String ownerUserId,
    required String clientMutationId,
    required String entityType,
    required String entityId,
    required Map<String, Object?> canonicalPayload,
    required bool canonicalDeleted,
    required DateTime resolvedAt,
    required List<local.EmailReconciliationReceipt> receipts,
  }) async {
    if (receipts.length != 1) {
      throw StateError('Email confirmation conflict receipt is ambiguous.');
    }
    final receipt = receipts.single;
    final confirmation = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId) &
              row.provenance.equals('confirmation')))
        .getSingleOrNull();
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (confirmation == null ||
        receipt.action != 'confirmation' ||
        receipt.resolution != null ||
        receipt.state != 'pending' ||
        receipt.scheduleAckedAt != null ||
        receipt.entityType != entityType ||
        receipt.entityId != entityId ||
        receipt.requiredSyncMutationId != clientMutationId ||
        mutation == null ||
        mutation.status != 'conflict' ||
        mutation.operation != 'create' ||
        mutation.baseVersion != null ||
        mutation.entityType != entityType ||
        mutation.entityId != entityId) {
      throw StateError('Email confirmation conflict is not resolvable.');
    }
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: confirmation.candidateId,
    );
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.id.equals(confirmation.linkId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (candidate == null ||
        link == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityType != entityType ||
        candidate.linkedEntityId != entityId ||
        link.candidateId != candidate.id ||
        link.entityType != entityType ||
        link.entityId != entityId) {
      throw StateError('Email confirmation conflict link is unavailable.');
    }
    final type = domain.EmailCandidateType.fromWire(entityType);
    final currentPayload = await _currentEntityPayload(
      ownerUserId: ownerUserId,
      entityType: type,
      entityId: entityId,
    );
    final canonicalWinningPayload = _canonicalConflictPayload(
      entityType: type,
      currentPayload: currentPayload,
      transportPayload: canonicalPayload,
      canonicalDeleted: canonicalDeleted,
    );
    final serverVersion = canonicalWinningPayload['version'];
    final serverUpdatedAt = _dateTime(canonicalWinningPayload['updatedAt']);
    final candidatePayload = _decodeCandidate(candidate.normalizedPayloadJson);
    if (confirmation.entityVersion != 1 ||
        currentPayload['version'] != confirmation.entityVersion ||
        emailSchedulePayloadFingerprint(currentPayload) !=
            confirmation.payloadFingerprint ||
        serverVersion is! int ||
        serverVersion < confirmation.entityVersion ||
        serverUpdatedAt == null) {
      throw StateError('Email confirmation provenance is not the current tip.');
    }
    final canonicalFingerprint =
        emailSchedulePayloadFingerprint(canonicalWinningPayload);
    await _restoreNotificationFromCanonical(
      ownerUserId: ownerUserId,
      candidate: candidate,
      entityType: type,
      entityId: entityId,
      candidatePayload: candidatePayload,
      canonicalPayload: canonicalWinningPayload,
      canonicalDeleted: canonicalDeleted,
      now: emailScheduleSqliteTimestamp(resolvedAt),
    );
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId: 'server-wins:$clientMutationId',
            ownerUserId: ownerUserId,
            candidateId: candidate.id,
            linkId: link.id,
            entityType: entityType,
            entityId: entityId,
            provenance: 'server_wins',
            baseEntityVersion: confirmation.entityVersion,
            entityVersion: serverVersion,
            basePayloadFingerprint: confirmation.payloadFingerprint,
            payloadFingerprint: canonicalFingerprint,
            candidatePayloadFingerprint:
                emailCandidatePayloadFingerprint(candidatePayload),
            entityUpdatedAt: serverUpdatedAt,
            createdAt: emailScheduleSqliteTimestamp(resolvedAt),
          ),
        );
    return true;
  }

  Future<bool> _replaceOrdinaryEditConflict({
    required String ownerUserId,
    required String clientMutationId,
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> canonicalPayload,
    required bool canonicalDeleted,
    required DateTime resolvedAt,
  }) async {
    if (operation != 'update' && operation != 'delete') return false;
    final losingEnvelope = await (db.select(db.emailScheduleEditReceipts)
          ..where((row) =>
              row.mutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (losingEnvelope == null) return false;
    final legacyTip = losingEnvelope.provenance == 'legacy_trusted_tip';
    if (losingEnvelope.provenance != 'user_edit' && !legacyTip ||
        losingEnvelope.entityType != entityType ||
        losingEnvelope.entityId != entityId) {
      throw StateError('Ordinary email edit provenance is not resolvable.');
    }
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: losingEnvelope.candidateId,
    );
    final link = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.id.equals(losingEnvelope.linkId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    final candidatePayload = candidate == null
        ? null
        : _decodeCandidate(candidate.normalizedPayloadJson);
    final receiptEntityType = domain.EmailCandidateType.fromWire(entityType);
    final currentPayload = await _currentEntityPayload(
      ownerUserId: ownerUserId,
      entityType: receiptEntityType,
      entityId: entityId,
    );
    final currentVersion = currentPayload['version'];
    final currentUpdatedAt = _dateTime(currentPayload['updatedAt']);
    final serverVersion = canonicalPayload['version'];
    final serverUpdatedAt = _dateTime(canonicalPayload['updatedAt']);
    final canonicalWinningPayload = _canonicalConflictPayload(
      entityType: receiptEntityType,
      currentPayload: currentPayload,
      transportPayload: canonicalPayload,
      canonicalDeleted: canonicalDeleted,
    );
    if (mutation == null ||
        mutation.status != 'conflict' ||
        mutation.operation != operation ||
        mutation.entityType != entityType ||
        mutation.entityId != entityId ||
        (legacyTip
            ? mutation.baseVersion == null ||
                losingEnvelope.baseEntityVersion > mutation.baseVersion!
            : mutation.baseVersion != losingEnvelope.baseEntityVersion) ||
        candidate == null ||
        candidatePayload == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityType != entityType ||
        candidate.linkedEntityId != entityId ||
        candidate.confirmationIdempotencyKey == null ||
        link == null ||
        link.candidateId != candidate.id ||
        link.entityType != entityType ||
        link.entityId != entityId ||
        link.confirmationIdempotencyKey !=
            candidate.confirmationIdempotencyKey ||
        currentVersion != losingEnvelope.entityVersion ||
        currentUpdatedAt == null ||
        !currentUpdatedAt.isAtSameMomentAs(losingEnvelope.entityUpdatedAt) ||
        losingEnvelope.payloadFingerprint !=
            emailSchedulePayloadFingerprint(currentPayload) ||
        losingEnvelope.candidatePayloadFingerprint !=
            emailCandidatePayloadFingerprint(candidatePayload) ||
        serverVersion is! int ||
        (legacyTip
            ? serverVersion < losingEnvelope.entityVersion
            : serverVersion <= losingEnvelope.baseEntityVersion) ||
        serverUpdatedAt == null) {
      throw StateError(
          'Ordinary email edit provenance is not the current tip.');
    }

    final now = emailScheduleSqliteTimestamp(resolvedAt);
    await _restoreNotificationFromCanonical(
      ownerUserId: ownerUserId,
      candidate: candidate,
      entityType: receiptEntityType,
      entityId: entityId,
      candidatePayload: candidatePayload,
      canonicalPayload: canonicalWinningPayload,
      canonicalDeleted: canonicalDeleted || operation == 'delete',
      now: now,
    );
    if (!legacyTip) {
      final removed = await (db.delete(db.emailScheduleEditReceipts)
            ..where((row) =>
                row.mutationId.equals(clientMutationId) &
                row.ownerUserId.equals(ownerUserId) &
                row.provenance.equals('user_edit') &
                row.payloadFingerprint
                    .equals(losingEnvelope.payloadFingerprint)))
          .go();
      _requireOne(removed, 'ordinary edit provenance');
    }
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId:
                legacyTip ? 'server-wins:$clientMutationId' : clientMutationId,
            ownerUserId: ownerUserId,
            candidateId: candidate.id,
            linkId: link.id,
            entityType: entityType,
            entityId: entityId,
            provenance: 'server_wins',
            baseEntityVersion: legacyTip
                ? losingEnvelope.entityVersion
                : losingEnvelope.baseEntityVersion,
            entityVersion: serverVersion,
            basePayloadFingerprint: legacyTip
                ? losingEnvelope.payloadFingerprint
                : losingEnvelope.basePayloadFingerprint,
            payloadFingerprint:
                emailSchedulePayloadFingerprint(canonicalWinningPayload),
            candidatePayloadFingerprint:
                emailCandidatePayloadFingerprint(candidatePayload),
            entityUpdatedAt: serverUpdatedAt,
            createdAt: now,
          ),
        );
    return true;
  }

  domain.EmailCandidatePayload _alignedPayload({
    required domain.EmailCandidatePayload proposedPayload,
    required String fieldDiffJson,
    required Map<String, Object?> canonicalPayload,
    required bool canonicalDeleted,
  }) {
    final value = _candidateCodec.toJson(proposedPayload);
    final diff = _decodeDiff(fieldDiffJson);
    for (final entry in diff.entries) {
      final change = entry.value;
      if (change is! Map || !change.containsKey('before')) {
        throw StateError('Email update conflict diff is malformed.');
      }
      _writeCandidateField(value, entry.key, change['before']);
    }
    if (!canonicalDeleted) {
      switch (proposedPayload.candidateType) {
        case domain.EmailCandidateType.assignment:
          _writeCandidateField(value, 'title', canonicalPayload['title']);
          _writeCandidateField(value, 'due_at', canonicalPayload['dueAt']);
          _writeCandidateField(
            value,
            'submission_url',
            canonicalPayload['submissionUrl'],
          );
          _writeCandidateField(value, 'summary', canonicalPayload['memo']);
        case domain.EmailCandidateType.exam:
          _writeCandidateField(value, 'title', canonicalPayload['title']);
          _writeCandidateField(
            value,
            'start_at',
            canonicalPayload['startAt'],
          );
          _writeCandidateField(value, 'end_at', canonicalPayload['endAt']);
          _writeCandidateField(value, 'location', canonicalPayload['room']);
          _writeCandidateField(value, 'summary', canonicalPayload['memo']);
        case domain.EmailCandidateType.event:
          _writeCandidateField(value, 'title', canonicalPayload['title']);
          _writeCandidateField(
            value,
            'start_at',
            canonicalPayload['startAt'],
          );
          _writeCandidateField(value, 'end_at', canonicalPayload['endAt']);
          _writeCandidateField(
            value,
            'location',
            canonicalPayload['location'],
          );
          _writeCandidateField(
            value,
            'summary',
            canonicalPayload['description'],
          );
        case domain.EmailCandidateType.announcement:
        case domain.EmailCandidateType.unknown:
          throw StateError('Unsupported email update conflict entity.');
      }
    }
    try {
      final aligned = _candidateCodec.decodeObject(value);
      if (aligned.candidateType != proposedPayload.candidateType) {
        throw StateError('Email update conflict changed candidate type.');
      }
      return aligned;
    } on domain.EmailCandidateValidationException catch (error) {
      throw StateError(
        'Canonical email update conflict payload is invalid: '
        '${error.errorCategory.wireName}.',
      );
    }
  }

  Map<String, Object?> _decodeDiff(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw StateError('Email update conflict diff is invalid JSON.');
    }
    if (decoded is! Map || decoded.isEmpty) {
      throw StateError('Email update conflict diff is empty.');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Map<String, Object?>? _decodeCanonicalPayload(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded.isEmpty) return null;
    return decoded.map((key, value) => MapEntry(key.toString(), value));
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
        if (row == null) {
          throw StateError('Conflict assignment is unavailable.');
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
      case domain.EmailCandidateType.exam:
        final row = await (db.select(db.exams)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) throw StateError('Conflict exam is unavailable.');
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
        if (row == null) throw StateError('Conflict event is unavailable.');
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
        throw StateError('Unsupported conflict entity type.');
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: payload,
    );
  }

  Map<String, Object?> _canonicalConflictPayload({
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> currentPayload,
    required Map<String, Object?> transportPayload,
    required bool canonicalDeleted,
  }) {
    if (!canonicalDeleted) {
      return emailScheduleReplayPayload(
        entityType: entityType,
        payload: transportPayload,
      );
    }
    final canonicalTransport = emailScheduleReplayPayload(
      entityType: entityType,
      payload: transportPayload,
    );
    final merged = <String, Object?>{...currentPayload};
    for (final key in canonicalTransport.keys) {
      if (transportPayload.containsKey(key)) {
        merged[key] = canonicalTransport[key];
      }
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: merged,
    );
  }

  DateTime? _dateTime(Object? value) {
    if (value is DateTime) return emailScheduleSqliteTimestamp(value);
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    return parsed == null ? null : emailScheduleSqliteTimestamp(parsed);
  }

  void _writeCandidateField(
    Map<String, Object?> payload,
    String field,
    Object? value,
  ) {
    switch (field) {
      case 'due_at':
      case 'due_all_day':
      case 'due_timezone':
        final dueValue = payload['due'];
        if (dueValue is! Map) {
          throw StateError('Email assignment due payload is unavailable.');
        }
        final due = dueValue.map<String, Object?>(
          (key, item) => MapEntry(key.toString(), item),
        );
        due[switch (field) {
          'due_at' => 'at',
          'due_all_day' => 'all_day',
          _ => 'timezone',
        }] = value;
        payload['due'] = due;
      case 'title':
        payload['title'] = value;
      case 'start_at':
        payload['start_at'] = value;
      case 'end_at':
        payload['end_at'] = value;
      case 'location':
        payload['location'] = value;
      case 'submission_url':
        payload['submission_url'] = value;
      case 'summary':
        payload['summary'] = value;
      case 'suggested_reminders_minutes':
        payload['suggested_reminders_minutes'] = value;
      default:
        throw StateError('Unsupported email update conflict field.');
    }
  }

  Future<void> _restoreNotification({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required String entityType,
    required String entityId,
    required domain.EmailCandidatePayload payload,
    required bool canonicalDeleted,
    required DateTime now,
  }) async {
    final request = await (db.select(db.notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.sourceId.equals(candidate.id) &
              row.entityType.equals(entityType) &
              row.entityId.equals(entityId) &
              row.idempotencyKey.equals(candidate.confirmationIdempotencyKey!)))
        .getSingleOrNull();
    if (request == null) {
      throw StateError('Email update notification request is unavailable.');
    }
    final companion = canonicalDeleted
        ? local.NotificationScheduleRequestsCompanion(
            state: const Value('cancelled'),
            updatedAt: Value(now),
          )
        : local.NotificationScheduleRequestsCompanion(
            anchorAt: Value(_notificationAnchor(payload)),
            allDay: Value(
              payload.candidateType == domain.EmailCandidateType.assignment &&
                  payload.due.allDay,
            ),
            timezone: Value(
              payload.due.timezone ?? domain.japanTimeZone,
            ),
            remindersMinutesJson:
                Value(jsonEncode(payload.suggestedRemindersMinutes)),
            state: const Value('pending'),
            updatedAt: Value(now),
          );
    final changed = await (db.update(db.notificationScheduleRequests)
          ..where((row) =>
              row.id.equals(request.id) & row.ownerUserId.equals(ownerUserId)))
        .write(companion);
    _requireOne(changed, 'email notification request');
  }

  Future<void> _restoreNotificationFromCanonical({
    required String ownerUserId,
    required local.EmailCandidate candidate,
    required domain.EmailCandidateType entityType,
    required String entityId,
    required domain.EmailCandidatePayload candidatePayload,
    required Map<String, Object?> canonicalPayload,
    required bool canonicalDeleted,
    required DateTime now,
  }) async {
    final request = await (db.select(db.notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.sourceId.equals(candidate.id) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(entityId) &
              row.idempotencyKey.equals(candidate.confirmationIdempotencyKey!)))
        .getSingleOrNull();
    final expectedAllDay = entityType == domain.EmailCandidateType.assignment &&
        candidatePayload.due.allDay;
    final expectedTimezone =
        candidatePayload.due.timezone ?? domain.japanTimeZone;
    final expectedReminders =
        jsonEncode(candidatePayload.suggestedRemindersMinutes);
    if (request == null ||
        request.allDay != expectedAllDay ||
        request.timezone != expectedTimezone ||
        request.remindersMinutesJson != expectedReminders) {
      throw StateError('Email notification policy is inconsistent.');
    }
    final local.NotificationScheduleRequestsCompanion companion;
    if (canonicalDeleted) {
      companion = local.NotificationScheduleRequestsCompanion(
        state: const Value('cancelled'),
        updatedAt: Value(now),
      );
    } else {
      final anchor = _dateTime(
        canonicalPayload[entityType == domain.EmailCandidateType.assignment
            ? 'dueAt'
            : 'startAt'],
      );
      if (anchor == null) {
        throw StateError('Canonical notification anchor is unavailable.');
      }
      companion = local.NotificationScheduleRequestsCompanion(
        anchorAt: Value(anchor),
        state: const Value('pending'),
        updatedAt: Value(now),
      );
    }
    final changed = await (db.update(db.notificationScheduleRequests)
          ..where((row) =>
              row.id.equals(request.id) & row.ownerUserId.equals(ownerUserId)))
        .write(companion);
    _requireOne(changed, 'email notification request');
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
        throw StateError('Unsupported email notification candidate.'),
    };
  }

  domain.EmailCandidatePayload _decodeCandidate(String raw) {
    try {
      return _candidateCodec.decode(raw);
    } on domain.EmailCandidateValidationException catch (error) {
      throw StateError(
        'Stored email update payload is invalid: '
        '${error.errorCategory.wireName}.',
      );
    }
  }

  void _requireOne(int changed, String artifact) {
    if (changed != 1) {
      throw StateError('The $artifact changed during conflict resolution.');
    }
  }
}
