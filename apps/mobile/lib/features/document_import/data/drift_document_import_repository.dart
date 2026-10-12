import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:uuid/uuid.dart';

import '../../../core/sync/drift_sync_queue.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database.dart' as local;
import '../domain/document_import_models.dart';
import 'document_import_gateway.dart';

abstract interface class DocumentImportPendingReviewReconciler {
  Future<void> reconcilePending(String ownerUserId);
}

class DriftDocumentImportRepository
    implements DocumentImportPendingReviewReconciler {
  DriftDocumentImportRepository({
    required this.db,
    required this.gateway,
    required this.clock,
    required this.authenticatedUserId,
    this.lease,
    Uuid uuid = const Uuid(),
  }) : _uuid = uuid;

  final local.AppDatabase db;
  final DocumentImportGateway gateway;
  final DateTime Function() clock;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final Uuid _uuid;
  final Map<String, Future<void>> _reviewSyncInFlight = {};
  final Set<String> _reviewSyncRerunRequested = {};

  Future<DocumentReviewBatch> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    final ownerUserId = _requireOwner();
    cancellation?.throwIfCancelled();
    final result = await gateway.analyze(
      file,
      onState: onState,
      cancellation: cancellation,
    );
    _requireOwner(ownerUserId);
    cancellation?.throwIfCancelled();
    await _cacheAnalysis(
      ownerUserId,
      file,
      result,
      cancellation: cancellation,
    );
    cancellation?.throwIfCancelled();
    final batch = await loadSource(
      ownerUserId: ownerUserId,
      sourceId: result.batch.sourceId,
    );
    cancellation?.throwIfCancelled();
    return batch;
  }

  Future<void> _cacheAnalysis(
    String ownerUserId,
    DocumentSelectedFile file,
    DocumentAnalysisResult result, {
    DocumentImportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final batch = const DocumentCandidateBatchCodec().decodeObject(
      const DocumentCandidateBatchCodec().toJson(result.batch),
    );
    if (batch.contentHash != file.contentHash ||
        batch.timezone != DocumentCandidateBatchCodec.timezone ||
        batch.candidates
            .any((candidate) => !candidate.requiresUserConfirmation)) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    final now = clock().toUtc();
    await db.transaction(() async {
      cancellation?.throwIfCancelled();
      _requireOwner(ownerUserId);
      await db.into(db.documentSourcesCache).insertOnConflictUpdate(
            local.DocumentSourcesCacheCompanion.insert(
              id: batch.sourceId,
              ownerUserId: ownerUserId,
              storagePath: Value(result.storagePath),
              mediaType: file.mediaType.mimeType,
              byteSize: file.byteLength,
              contentHash: file.contentHash,
              processingState: Value(
                DocumentImportState.readyForReview.wireName,
              ),
              candidateCount: Value(batch.candidates.length),
              remoteVersion: Value(result.remoteSourceVersion),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      for (final candidate in batch.candidates) {
        cancellation?.throwIfCancelled();
        final localId = _candidateCacheId(
          ownerUserId,
          batch.sourceId,
          candidate.candidateId,
        );
        final remote = result.remoteCandidates[candidate.candidateId];
        final existing = await (db.select(db.documentCandidatesCache)
              ..where(
                (row) =>
                    row.id.equals(localId) &
                    row.ownerUserId.equals(ownerUserId),
              ))
            .getSingleOrNull();
        if (existing == null) {
          await db.into(db.documentCandidatesCache).insert(
                local.DocumentCandidatesCacheCompanion.insert(
                  id: localId,
                  ownerUserId: ownerUserId,
                  sourceId: batch.sourceId,
                  candidateKey: candidate.candidateId,
                  remoteCandidateId: Value(remote?.id),
                  schemaVersion: batch.schemaVersion,
                  candidateType: candidate.type.wireName,
                  normalizedPayloadJson: jsonEncode(
                    documentCandidateToJson(
                      candidate,
                      sourceId: batch.sourceId,
                      contentHash: batch.contentHash,
                    ),
                  ),
                  remoteVersion: Value(remote?.version),
                  remoteSyncState: const Value('synced'),
                  updatedAt: Value(now),
                ),
              );
        } else {
          await (db.update(db.documentCandidatesCache)
                ..where(
                  (row) =>
                      row.id.equals(localId) &
                      row.ownerUserId.equals(ownerUserId),
                ))
              .write(
            local.DocumentCandidatesCacheCompanion(
              remoteCandidateId: Value(remote?.id),
              remoteVersion: Value(remote?.version),
              updatedAt: Value(now),
            ),
          );
        }
      }
      cancellation?.throwIfCancelled();
    });
  }

  Future<DocumentReviewBatch?> loadLatest(String ownerUserId) async {
    _requireOwner(ownerUserId);
    final source = await (db.select(db.documentSourcesCache)
          ..where((row) => row.ownerUserId.equals(ownerUserId))
          ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)])
          ..limit(1))
        .getSingleOrNull();
    if (source == null) return null;
    return loadSource(ownerUserId: ownerUserId, sourceId: source.id);
  }

  Future<DocumentReviewBatch> loadSource({
    required String ownerUserId,
    required String sourceId,
  }) async {
    _requireOwner(ownerUserId);
    final source = await (db.select(db.documentSourcesCache)
          ..where(
            (row) =>
                row.id.equals(sourceId) & row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (source == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    final rows = await (db.select(db.documentCandidatesCache)
          ..where(
            (row) =>
                row.sourceId.equals(sourceId) &
                row.ownerUserId.equals(ownerUserId),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.updatedAt)]))
        .get();
    return DocumentReviewBatch(
      sourceId: source.id,
      contentHash: source.contentHash,
      mediaType: DocumentMediaType.fromMimeType(source.mediaType),
      processingState: DocumentImportState.fromWire(source.processingState),
      candidates: List.unmodifiable(
        rows.map((row) => _reviewFromRow(source, row)),
      ),
    );
  }

  Future<DocumentCandidateReview> updateCandidate({
    required String ownerUserId,
    required String candidateLocalId,
    required DocumentCandidateEdit edit,
    String action = 'edit',
  }) async {
    _requireOwner(ownerUserId);
    final row = await _candidateRow(ownerUserId, candidateLocalId);
    if (row == null ||
        row.reviewState == DocumentCandidateReviewState.confirmed.wireName) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    if (row.candidateKey != edit.candidate.candidateId) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    final source = await _sourceRow(ownerUserId, row.sourceId);
    final normalized = _normalizeCandidate(source, edit.candidate);
    final nextState = switch (action) {
      'exclude' => DocumentCandidateReviewState.excluded,
      'restore' ||
      'edit' ||
      'select' ||
      'deselect' =>
        DocumentCandidateReviewState.needsReview,
      _ => throw ArgumentError.value(action, 'action'),
    };
    final selected = switch (action) {
      'exclude' || 'deselect' => false,
      'restore' || 'select' => true,
      _ => row.isSelected,
    };
    final pendingState =
        row.remoteCandidateId == null ? 'synced' : 'pending_$action';
    final now = clock().toUtc();
    _requireOwner(ownerUserId);
    final changed = await (db.update(db.documentCandidatesCache)
          ..where(
            (candidate) =>
                candidate.id.equals(candidateLocalId) &
                candidate.ownerUserId.equals(ownerUserId) &
                candidate.reviewState.equals(row.reviewState),
          ))
        .write(
      local.DocumentCandidatesCacheCompanion(
        candidateType: Value(normalized.type.wireName),
        normalizedPayloadJson: Value(
          jsonEncode(
            documentCandidateToJson(
              normalized,
              sourceId: source.id,
              contentHash: source.contentHash,
            ),
          ),
        ),
        reviewState: Value(nextState.wireName),
        isSelected: Value(selected),
        courseId: Value(_normalizedOptionalId(edit.courseId)),
        remoteSyncState: Value(pendingState),
        updatedAt: Value(now),
      ),
    );
    if (changed != 1) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
    _requireOwner(ownerUserId);
    await _trySyncReview(ownerUserId, candidateLocalId);
    return (await loadSource(ownerUserId: ownerUserId, sourceId: row.sourceId))
        .candidates
        .singleWhere((candidate) => candidate.localId == candidateLocalId);
  }

  @override
  Future<void> reconcilePending(String ownerUserId) async {
    _requireOwner(ownerUserId);
    final pending = await (db.select(db.documentCandidatesCache)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.remoteCandidateId.isNotNull() &
                row.remoteSyncState.isNotValue('synced'),
          ))
        .get();
    for (final candidate in pending) {
      await _trySyncReview(ownerUserId, candidate.id);
    }
  }

  Future<void> _trySyncReview(
    String ownerUserId,
    String candidateLocalId,
  ) {
    _requireOwner(ownerUserId);
    final key = '$ownerUserId\u0000$candidateLocalId';
    final existing = _reviewSyncInFlight[key];
    if (existing != null) {
      _reviewSyncRerunRequested.add(key);
      return existing;
    }
    var restartAfterCompletionGap = false;
    late final Future<void> operation;
    operation = _drainReviewSync(
      ownerUserId: ownerUserId,
      candidateLocalId: candidateLocalId,
      key: key,
    ).then<void>((quiescent) {
      restartAfterCompletionGap = quiescent;
    }).whenComplete(() async {
      if (identical(_reviewSyncInFlight[key], operation)) {
        _reviewSyncInFlight.remove(key);
        final rerunRequested = _reviewSyncRerunRequested.remove(key);
        try {
          _requireOwner(ownerUserId);
        } on DocumentImportFailure {
          // The old owner's durable action remains pending for that owner's
          // next authenticated runtime. Never restart it after an account
          // switch.
          return;
        }
        final latest = await _candidateRow(ownerUserId, candidateLocalId);
        try {
          _requireOwner(ownerUserId);
        } on DocumentImportFailure {
          return;
        }
        final stillPending = latest != null &&
            latest.remoteCandidateId != null &&
            latest.remoteVersion != null &&
            latest.remoteSyncState != 'synced';
        if (restartAfterCompletionGap &&
            (rerunRequested || stillPending) &&
            !_reviewSyncInFlight.containsKey(key)) {
          await _trySyncReview(ownerUserId, candidateLocalId);
        }
      }
    });
    _reviewSyncInFlight[key] = operation;
    return operation;
  }

  Future<bool> _drainReviewSync({
    required String ownerUserId,
    required String candidateLocalId,
    required String key,
  }) async {
    while (true) {
      _requireOwner(ownerUserId);
      _reviewSyncRerunRequested.remove(key);
      final row = await _candidateRow(ownerUserId, candidateLocalId);
      _requireOwner(ownerUserId);
      if (row == null ||
          row.remoteCandidateId == null ||
          row.remoteVersion == null ||
          row.remoteSyncState == 'synced') {
        if (_reviewSyncRerunRequested.remove(key)) continue;
        return true;
      }
      if (!row.remoteSyncState.startsWith('pending_')) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      final source = await _sourceRow(ownerUserId, row.sourceId);
      _requireOwner(ownerUserId);
      final review = _reviewFromRow(source, row);
      final action = row.remoteSyncState.substring('pending_'.length);
      int? nextVersion;
      try {
        nextVersion = await gateway.updateCandidate(
          identity: RemoteDocumentCandidateIdentity(
            id: row.remoteCandidateId!,
            version: row.remoteVersion!,
          ),
          candidate: review.candidate,
          action: action,
        );
        _requireOwner(ownerUserId);
      } on DocumentImportFailure catch (error) {
        if (!error.category.isRetryable) rethrow;
        return false;
      }
      // The response is accepted only while this provider's owner/database
      // lease is still live; a stale response leaves the durable action
      // pending for the next authenticated runtime.
      if (nextVersion != null && nextVersion <= row.remoteVersion!) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      final effectiveVersion = nextVersion ?? row.remoteVersion!;
      final synchronized = await (db.update(db.documentCandidatesCache)
            ..where((candidate) {
              var matches = candidate.id.equals(candidateLocalId) &
                  candidate.ownerUserId.equals(ownerUserId) &
                  candidate.remoteCandidateId.equals(row.remoteCandidateId!) &
                  candidate.remoteVersion.equals(row.remoteVersion!) &
                  candidate.remoteSyncState.equals(row.remoteSyncState) &
                  candidate.reviewState.equals(row.reviewState) &
                  candidate.isSelected.equals(row.isSelected) &
                  candidate.candidateType.equals(row.candidateType) &
                  candidate.normalizedPayloadJson
                      .equals(row.normalizedPayloadJson);
              matches = matches &
                  (row.courseId == null
                      ? candidate.courseId.isNull()
                      : candidate.courseId.equals(row.courseId!));
              return matches;
            }))
          .write(
        local.DocumentCandidatesCacheCompanion(
          remoteVersion: Value(effectiveVersion),
          remoteSyncState: const Value('synced'),
          updatedAt: Value(clock().toUtc()),
        ),
      );
      if (synchronized == 1) {
        if (!_isAuthenticatedOwner(ownerUserId)) return false;
        continue;
      }

      // The acknowledged action was an older snapshot. Preserve the latest
      // durable pending action, but advance its expected server version before
      // the next drain iteration. It must never be mislabeled as synchronized.
      if (nextVersion == null) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      _requireOwner(ownerUserId);
      await (db.update(db.documentCandidatesCache)
            ..where(
              (candidate) =>
                  candidate.id.equals(candidateLocalId) &
                  candidate.ownerUserId.equals(ownerUserId) &
                  candidate.remoteCandidateId.equals(row.remoteCandidateId!) &
                  candidate.remoteVersion.equals(row.remoteVersion!) &
                  candidate.remoteSyncState.isNotValue('synced'),
            ))
          .write(
        local.DocumentCandidatesCacheCompanion(
          remoteVersion: Value(nextVersion),
        ),
      );
      if (!_isAuthenticatedOwner(ownerUserId)) return false;
    }
  }

  Future<DocumentBulkConfirmationResult> confirmEach({
    required String ownerUserId,
    required Iterable<DocumentConfirmationItem> items,
  }) async {
    _requireOwner(ownerUserId);
    final confirmed = <DocumentConfirmationSuccess>[];
    final failed = <DocumentConfirmationFailure>[];
    for (final item in items) {
      try {
        confirmed.add(
          await confirm(
            ownerUserId: ownerUserId,
            candidateLocalId: item.candidateId,
            courseId: item.courseId,
          ),
        );
      } on DocumentImportFailure catch (error) {
        failed.add(
          DocumentConfirmationFailure(
            candidateId: item.candidateId,
            errorCategory: error.category,
          ),
        );
      } on Object {
        failed.add(
          DocumentConfirmationFailure(
            candidateId: item.candidateId,
            errorCategory: DocumentImportErrorCategory.internalError,
          ),
        );
      }
    }
    return DocumentBulkConfirmationResult(
      confirmed: List.unmodifiable(confirmed),
      failed: List.unmodifiable(failed),
    );
  }

  Future<DocumentConfirmationSuccess> confirm({
    required String ownerUserId,
    required String candidateLocalId,
    String? courseId,
  }) async {
    _requireOwner(ownerUserId);
    final initial = await _candidateRow(ownerUserId, candidateLocalId);
    if (initial == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    if (initial.reviewState ==
        DocumentCandidateReviewState.confirmed.wireName) {
      return _verifyReplay(ownerUserId, initial);
    }
    if (initial.reviewState !=
            DocumentCandidateReviewState.needsReview.wireName ||
        !initial.isSelected) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    final source = await _sourceRow(ownerUserId, initial.sourceId);
    final candidate = _reviewFromRow(source, initial).candidate;
    _validateMaterializable(candidate);
    final normalizedCourseId =
        _normalizedOptionalId(courseId ?? initial.courseId);
    await _requireOwnedCourse(ownerUserId, normalizedCourseId);
    final confirmationScope = gateway.confirmsOnServer
        ? candidateLocalId
        : '$candidateLocalId\u0000${_localSemanticIdentity(
            candidate,
            normalizedCourseId,
          )}';

    final expectedEntityId = _stableId(
      'document-confirmed-entity',
      ownerUserId,
      confirmationScope,
    );
    final idempotencyKey = _stableId(
      'document-confirmation',
      ownerUserId,
      confirmationScope,
    );
    var entityId = expectedEntityId;
    var remoteReplayed = false;
    if (gateway.confirmsOnServer) {
      if (initial.remoteCandidateId == null || initial.remoteVersion == null) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.configurationMissing,
        );
      }
      final remote = await gateway.confirmCandidate(
        identity: RemoteDocumentCandidateIdentity(
          id: initial.remoteCandidateId!,
          version: initial.remoteVersion!,
        ),
        candidate: candidate,
        entityId: expectedEntityId,
        idempotencyKey: idempotencyKey,
        courseId: normalizedCourseId,
      );
      _requireOwner(ownerUserId);
      if (remote.entityType != candidate.type) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      entityId = remote.entityId;
      remoteReplayed = remote.replayed;
    }

    return db.transaction(() async {
      _requireOwner(ownerUserId);
      final row = await _candidateRow(ownerUserId, candidateLocalId);
      if (row == null) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      if (row.reviewState == DocumentCandidateReviewState.confirmed.wireName) {
        return _verifyReplay(ownerUserId, row);
      }
      if (row.reviewState !=
              DocumentCandidateReviewState.needsReview.wireName ||
          !row.isSelected) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.invalidExtraction,
        );
      }
      if (!gateway.confirmsOnServer) {
        final reusableEntityId = await _findReusableLocalCanonicalEntity(
          ownerUserId: ownerUserId,
          courseId: normalizedCourseId,
          candidate: candidate,
        );
        if (reusableEntityId != null) {
          entityId = reusableEntityId;
          remoteReplayed = true;
        }
      }
      final now = clock().toUtc();
      final mutationId = _stableId(
        'document-confirmed-mutation',
        ownerUserId,
        confirmationScope,
      );
      final linkId = _stableId(
        'document-confirmed-link',
        ownerUserId,
        confirmationScope,
      );
      final notificationId = _stableId(
        'document-confirmed-notification',
        ownerUserId,
        confirmationScope,
      );
      final canonicalAlreadyExists = await _verifyExistingCanonicalEntity(
        ownerUserId: ownerUserId,
        entityId: entityId,
        courseId: normalizedCourseId,
        candidate: candidate,
      );
      await _requireNoArtifacts(
        entityId: entityId,
        mutationId: mutationId,
        linkId: linkId,
        notificationId: notificationId,
        idempotencyKey: idempotencyKey,
        allowExistingCanonical: canonicalAlreadyExists,
        ownerUserId: ownerUserId,
        candidateLocalId: candidateLocalId,
        candidate: candidate,
      );
      final mutationPayload = canonicalAlreadyExists
          ? null
          : await _insertCanonicalEntity(
              ownerUserId: ownerUserId,
              entityId: entityId,
              courseId: normalizedCourseId,
              candidate: candidate,
              now: now,
            );
      final changed = await (db.update(db.documentCandidatesCache)
            ..where(
              (cached) =>
                  cached.id.equals(candidateLocalId) &
                  cached.ownerUserId.equals(ownerUserId) &
                  cached.reviewState.equals(row.reviewState),
            ))
          .write(
        local.DocumentCandidatesCacheCompanion(
          reviewState: Value(DocumentCandidateReviewState.confirmed.wireName),
          isSelected: const Value(false),
          courseId: Value(normalizedCourseId),
          remoteSyncState: Value(
            gateway.confirmsOnServer ? 'synced' : row.remoteSyncState,
          ),
          linkedEntityType: Value(candidate.type.wireName),
          linkedEntityId: Value(entityId),
          confirmedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      if (changed != 1) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.networkUnavailable,
        );
      }
      await db.into(db.documentScheduleEntityLinks).insert(
            local.DocumentScheduleEntityLinksCompanion.insert(
              id: linkId,
              ownerUserId: ownerUserId,
              sourceId: row.sourceId,
              candidateCacheId: candidateLocalId,
              entityType: candidate.type.wireName,
              entityId: entityId,
              confirmationIdempotencyKey: idempotencyKey,
              createdAt: Value(now),
            ),
          );
      final existingNotification = await _notificationForEntity(
        ownerUserId,
        candidate.type,
        entityId,
      );
      if (existingNotification == null) {
        await db.into(db.notificationScheduleRequests).insert(
              local.NotificationScheduleRequestsCompanion.insert(
                id: notificationId,
                ownerUserId: ownerUserId,
                entityType: candidate.type.wireName,
                entityId: entityId,
                sourceType: const Value('document_confirmation'),
                sourceId: candidateLocalId,
                idempotencyKey: idempotencyKey,
                anchorAt: _notificationAnchor(candidate),
                allDay: Value(candidate.allDay),
                timezone: Value(candidate.timezone),
                remindersMinutesJson: Value(
                  jsonEncode(
                    candidate.type == DocumentCandidateType.assignment
                        ? const [1440, 60]
                        : const [1440, 120],
                  ),
                ),
                targetPath: _targetPath(candidate.type, entityId),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      } else {
        _verifyExistingNotification(existingNotification, candidate, entityId);
      }
      final existingMutation = await _createMutationForEntity(
        ownerUserId,
        candidate.type,
        entityId,
      );
      if (existingMutation == null) {
        if (gateway.confirmsOnServer) {
          await db.into(db.syncQueueEntries).insert(
                local.SyncQueueEntriesCompanion.insert(
                  clientMutationId: mutationId,
                  ownerUserId: ownerUserId,
                  idempotencyKey: Value(idempotencyKey),
                  entityType: candidate.type.wireName,
                  entityId: entityId,
                  operation: SyncOperation.create.name,
                  payloadJson: '{}',
                  serverVersion: const Value(1),
                  createdAt: Value(now),
                  status: const Value('synced'),
                  syncedAt: Value(now),
                  completionProvenance: const Value(
                    local.scheduleSyncCompletionRemoteApplied,
                  ),
                ),
              );
        } else {
          if (mutationPayload == null) {
            throw const DocumentImportFailure(
              DocumentImportErrorCategory.internalError,
            );
          }
          await DriftSyncQueue(db, ownerUserId: ownerUserId).enqueue(
            PendingMutation(
              clientMutationId: mutationId,
              ownerUserId: ownerUserId,
              idempotencyKey: idempotencyKey,
              entityType: candidate.type.wireName,
              entityId: entityId,
              operation: SyncOperation.create,
              payload: mutationPayload,
              createdAt: now,
            ),
          );
        }
      } else {
        _verifyExistingCreateMutation(
          existingMutation,
          ownerUserId: ownerUserId,
          type: candidate.type,
          entityId: entityId,
          requireRemoteApplied: gateway.confirmsOnServer,
        );
      }
      return DocumentConfirmationSuccess(
        candidateId: candidateLocalId,
        entityType: candidate.type,
        entityId: entityId,
        replayed: remoteReplayed || canonicalAlreadyExists,
      );
    });
  }

  Future<void> deleteSource({
    required String ownerUserId,
    required String sourceId,
  }) async {
    _requireOwner(ownerUserId);
    final source = await _sourceRow(ownerUserId, sourceId);
    await gateway.deleteSource(
      sourceId: source.id,
      storagePath: source.storagePath,
    );
    _requireOwner(ownerUserId);
    await (db.delete(db.documentSourcesCache)
          ..where(
            (row) =>
                row.id.equals(sourceId) & row.ownerUserId.equals(ownerUserId),
          ))
        .go();
  }

  Future<DocumentConfirmationSuccess> _verifyReplay(
    String ownerUserId,
    local.DocumentCandidatesCacheData row,
  ) async {
    final entityType = row.linkedEntityType;
    final entityId = row.linkedEntityId;
    if (entityType == null || entityId == null || row.confirmedAt == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.internalError,
      );
    }
    final link = await (db.select(db.documentScheduleEntityLinks)
          ..where(
            (item) =>
                item.candidateCacheId.equals(row.id) &
                item.ownerUserId.equals(ownerUserId) &
                item.entityType.equals(entityType) &
                item.entityId.equals(entityId),
          ))
        .getSingleOrNull();
    final notification = await (db.select(db.notificationScheduleRequests)
          ..where(
            (item) =>
                item.ownerUserId.equals(ownerUserId) &
                item.entityType.equals(entityType) &
                item.entityId.equals(entityId),
          ))
        .getSingleOrNull();
    final mutation = await (db.select(db.syncQueueEntries)
          ..where(
            (item) =>
                item.ownerUserId.equals(ownerUserId) &
                item.entityType.equals(entityType) &
                item.entityId.equals(entityId),
          ))
        .getSingleOrNull();
    final entityExists = entityType == DocumentCandidateType.assignment.wireName
        ? await (db.select(db.assignments)
                  ..where(
                    (item) =>
                        item.id.equals(entityId) &
                        item.ownerUserId.equals(ownerUserId),
                  ))
                .getSingleOrNull() !=
            null
        : await (db.select(db.exams)
                  ..where(
                    (item) =>
                        item.id.equals(entityId) &
                        item.ownerUserId.equals(ownerUserId),
                  ))
                .getSingleOrNull() !=
            null;
    if (!entityExists ||
        link == null ||
        notification == null ||
        mutation == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.internalError,
      );
    }
    return DocumentConfirmationSuccess(
      candidateId: row.id,
      entityType: DocumentCandidateType.fromWire(entityType),
      entityId: entityId,
      replayed: true,
    );
  }

  Future<Map<String, Object?>> _insertCanonicalEntity({
    required String ownerUserId,
    required String entityId,
    required String? courseId,
    required DocumentScheduleCandidate candidate,
    required DateTime now,
  }) async {
    switch (candidate.type) {
      case DocumentCandidateType.assignment:
        final dueAt = candidate.dueAt!.toUtc();
        await db.into(db.assignments).insert(
              local.AssignmentsCompanion.insert(
                id: entityId,
                ownerUserId: ownerUserId,
                courseId: Value(courseId),
                title: candidate.title,
                description: Value(candidate.notes),
                submissionUrl: Value(candidate.submissionUrl),
                dueAt: dueAt,
                visibilityLevel: const Value('PRIVATE'),
                updatedAt: Value(now),
              ),
            );
        return {
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': candidate.title,
          'description': candidate.notes,
          'submissionUrl': candidate.submissionUrl,
          'priority': null,
          'dueAt': dueAt,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': now,
          'version': 1,
        };
      case DocumentCandidateType.exam:
        final startAt = candidate.startAt!.toUtc();
        final endAt = candidate.endAt!.toUtc();
        await db.into(db.exams).insert(
              local.ExamsCompanion.insert(
                id: entityId,
                ownerUserId: ownerUserId,
                courseId: Value(courseId),
                title: candidate.title,
                startAt: startAt,
                endAt: endAt,
                room: Value(candidate.location),
                memo: Value(candidate.notes),
                visibilityLevel: const Value('PRIVATE'),
                updatedAt: Value(now),
              ),
            );
        return {
          'id': entityId,
          'ownerUserId': ownerUserId,
          'courseId': courseId,
          'title': candidate.title,
          'startAt': startAt,
          'endAt': endAt,
          'room': candidate.location,
          'memo': candidate.notes,
          'examType': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': now,
          'version': 1,
        };
    }
  }

  Future<bool> _verifyExistingCanonicalEntity({
    required String ownerUserId,
    required String entityId,
    required String? courseId,
    required DocumentScheduleCandidate candidate,
  }) async {
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final exam = await (db.select(db.exams)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    if (assignment == null && exam == null) return false;
    switch (candidate.type) {
      case DocumentCandidateType.assignment:
        if (exam != null ||
            assignment == null ||
            assignment.ownerUserId != ownerUserId ||
            assignment.deletedAt != null ||
            assignment.courseId != courseId ||
            assignment.title != candidate.title ||
            assignment.description != candidate.notes ||
            assignment.submissionUrl != candidate.submissionUrl ||
            assignment.dueAt.toUtc() != candidate.dueAt!.toUtc() ||
            assignment.visibilityLevel != 'PRIVATE') {
          throw const DocumentImportFailure(
            DocumentImportErrorCategory.internalError,
          );
        }
      case DocumentCandidateType.exam:
        if (assignment != null ||
            exam == null ||
            exam.ownerUserId != ownerUserId ||
            exam.deletedAt != null ||
            exam.courseId != courseId ||
            exam.title != candidate.title ||
            exam.startAt.toUtc() != candidate.startAt!.toUtc() ||
            exam.endAt.toUtc() != candidate.endAt!.toUtc() ||
            exam.room != candidate.location ||
            exam.memo != candidate.notes ||
            exam.visibilityLevel != 'PRIVATE') {
          throw const DocumentImportFailure(
            DocumentImportErrorCategory.internalError,
          );
        }
    }
    return true;
  }

  Future<String?> _findReusableLocalCanonicalEntity({
    required String ownerUserId,
    required String? courseId,
    required DocumentScheduleCandidate candidate,
  }) async {
    final entityIds = switch (candidate.type) {
      DocumentCandidateType.assignment => await (db.select(db.assignments)
            ..where((row) {
              var predicate = row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.title.equals(candidate.title) &
                  row.dueAt.equals(candidate.dueAt!.toUtc()) &
                  row.visibilityLevel.equals('PRIVATE');
              predicate = predicate &
                  (courseId == null
                      ? row.courseId.isNull()
                      : row.courseId.equals(courseId));
              predicate = predicate &
                  (candidate.notes == null
                      ? row.description.isNull()
                      : row.description.equals(candidate.notes!));
              predicate = predicate &
                  (candidate.submissionUrl == null
                      ? row.submissionUrl.isNull()
                      : row.submissionUrl.equals(candidate.submissionUrl!));
              return predicate;
            })
            ..orderBy([(row) => OrderingTerm.asc(row.id)]))
          .map((row) => row.id)
          .get(),
      DocumentCandidateType.exam => await (db.select(db.exams)
            ..where((row) {
              var predicate = row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.title.equals(candidate.title) &
                  row.startAt.equals(candidate.startAt!.toUtc()) &
                  row.endAt.equals(candidate.endAt!.toUtc()) &
                  row.visibilityLevel.equals('PRIVATE');
              predicate = predicate &
                  (courseId == null
                      ? row.courseId.isNull()
                      : row.courseId.equals(courseId));
              predicate = predicate &
                  (candidate.location == null
                      ? row.room.isNull()
                      : row.room.equals(candidate.location!));
              predicate = predicate &
                  (candidate.notes == null
                      ? row.memo.isNull()
                      : row.memo.equals(candidate.notes!));
              return predicate;
            })
            ..orderBy([(row) => OrderingTerm.asc(row.id)]))
          .map((row) => row.id)
          .get(),
    };
    for (final entityId in entityIds) {
      final notification = await _notificationForEntity(
        ownerUserId,
        candidate.type,
        entityId,
      );
      if (notification == null ||
          notification.sourceType != 'document_confirmation' ||
          !_matchesExistingNotification(notification, candidate, entityId)) {
        continue;
      }
      final mutation = await _createMutationForEntity(
        ownerUserId,
        candidate.type,
        entityId,
      );
      if (mutation == null) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      _verifyExistingCreateMutation(
        mutation,
        ownerUserId: ownerUserId,
        type: candidate.type,
        entityId: entityId,
        requireRemoteApplied: false,
      );
      return entityId;
    }
    return null;
  }

  Future<local.NotificationScheduleRequest?> _notificationForEntity(
    String ownerUserId,
    DocumentCandidateType type,
    String entityId,
  ) {
    return (db.select(db.notificationScheduleRequests)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.entityType.equals(type.wireName) &
                row.entityId.equals(entityId),
          ))
        .getSingleOrNull();
  }

  void _verifyExistingNotification(
    local.NotificationScheduleRequest notification,
    DocumentScheduleCandidate candidate,
    String entityId,
  ) {
    if (!_matchesExistingNotification(notification, candidate, entityId)) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.internalError,
      );
    }
  }

  bool _matchesExistingNotification(
    local.NotificationScheduleRequest notification,
    DocumentScheduleCandidate candidate,
    String entityId,
  ) {
    return notification.entityType == candidate.type.wireName &&
        notification.entityId == entityId &&
        notification.anchorAt.toUtc() ==
            _notificationAnchor(candidate).toUtc() &&
        notification.allDay == candidate.allDay &&
        notification.timezone == candidate.timezone &&
        notification.targetPath == _targetPath(candidate.type, entityId);
  }

  Future<local.SyncQueueEntry?> _createMutationForEntity(
    String ownerUserId,
    DocumentCandidateType type,
    String entityId,
  ) {
    return (db.select(db.syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.entityType.equals(type.wireName) &
                row.entityId.equals(entityId) &
                row.operation.equals(SyncOperation.create.name),
          )
          ..orderBy([(row) => OrderingTerm.asc(row.createdAt)])
          ..limit(1))
        .getSingleOrNull();
  }

  void _verifyExistingCreateMutation(
    local.SyncQueueEntry mutation, {
    required String ownerUserId,
    required DocumentCandidateType type,
    required String entityId,
    required bool requireRemoteApplied,
  }) {
    if (mutation.ownerUserId != ownerUserId ||
        mutation.entityType != type.wireName ||
        mutation.entityId != entityId ||
        mutation.operation != SyncOperation.create.name ||
        (requireRemoteApplied &&
            (mutation.status != 'synced' ||
                mutation.syncedAt == null ||
                mutation.serverVersion == null ||
                mutation.completionProvenance !=
                    local.scheduleSyncCompletionRemoteApplied))) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.internalError,
      );
    }
  }

  Future<void> _requireNoArtifacts({
    required String entityId,
    required String mutationId,
    required String linkId,
    required String notificationId,
    required String idempotencyKey,
    required bool allowExistingCanonical,
    required String ownerUserId,
    required String candidateLocalId,
    required DocumentScheduleCandidate candidate,
  }) async {
    final assignment = await (db.select(db.assignments)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final exam = await (db.select(db.exams)
          ..where((row) => row.id.equals(entityId)))
        .getSingleOrNull();
    final link = await (db.select(db.documentScheduleEntityLinks)
          ..where(
            (row) =>
                row.id.equals(linkId) |
                row.confirmationIdempotencyKey.equals(idempotencyKey),
          ))
        .getSingleOrNull();
    final notification = await (db.select(db.notificationScheduleRequests)
          ..where(
            (row) =>
                row.id.equals(notificationId) |
                row.idempotencyKey.equals(idempotencyKey),
          ))
        .getSingleOrNull();
    final mutation = await (db.select(db.syncQueueEntries)
          ..where(
            (row) =>
                row.clientMutationId.equals(mutationId) |
                row.idempotencyKey.equals(idempotencyKey),
          ))
        .getSingleOrNull();
    if ((!allowExistingCanonical && (assignment != null || exam != null)) ||
        link != null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.internalError,
      );
    }
    if (notification != null) {
      if (!allowExistingCanonical ||
          notification.id != notificationId ||
          notification.ownerUserId != ownerUserId ||
          notification.entityType != candidate.type.wireName ||
          notification.entityId != entityId ||
          notification.sourceType != 'document_confirmation' ||
          notification.sourceId != candidateLocalId ||
          notification.idempotencyKey != idempotencyKey) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      _verifyExistingNotification(notification, candidate, entityId);
    }
    if (mutation != null) {
      if (!allowExistingCanonical ||
          mutation.clientMutationId != mutationId ||
          mutation.idempotencyKey != idempotencyKey) {
        throw const DocumentImportFailure(
          DocumentImportErrorCategory.internalError,
        );
      }
      _verifyExistingCreateMutation(
        mutation,
        ownerUserId: ownerUserId,
        type: candidate.type,
        entityId: entityId,
        requireRemoteApplied: gateway.confirmsOnServer,
      );
    }
  }

  Future<void> _requireOwnedCourse(
    String ownerUserId,
    String? courseId,
  ) async {
    if (courseId == null) return;
    final course = await (db.select(db.userCourses)
          ..where(
            (row) =>
                row.id.equals(courseId) &
                row.ownerUserId.equals(ownerUserId) &
                row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (course == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
  }

  void _validateMaterializable(DocumentScheduleCandidate candidate) {
    if (candidate.title.trim().isEmpty || !candidate.requiresUserConfirmation) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    switch (candidate.type) {
      case DocumentCandidateType.assignment:
        if (candidate.dueAt == null) {
          throw const DocumentImportFailure(
            DocumentImportErrorCategory.invalidExtraction,
          );
        }
      case DocumentCandidateType.exam:
        if (candidate.startAt == null ||
            candidate.endAt == null ||
            !candidate.endAt!.isAfter(candidate.startAt!)) {
          throw const DocumentImportFailure(
            DocumentImportErrorCategory.invalidExtraction,
          );
        }
    }
  }

  DocumentScheduleCandidate _normalizeCandidate(
    local.DocumentSourcesCacheData source,
    DocumentScheduleCandidate candidate,
  ) {
    try {
      final batch = const DocumentCandidateBatchCodec().decodeObject({
        'schema_version': DocumentCandidateBatchCodec.schemaVersion,
        'source_id': source.id,
        'content_hash': source.contentHash,
        'timezone': DocumentCandidateBatchCodec.timezone,
        'candidates': [
          documentCandidateToJson(
            candidate,
            sourceId: source.id,
            contentHash: source.contentHash,
          ),
        ],
      });
      return batch.candidates.single;
    } on DocumentCandidateValidationException {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
  }

  DocumentCandidateReview _reviewFromRow(
    local.DocumentSourcesCacheData source,
    local.DocumentCandidatesCacheData row,
  ) {
    Object? payload;
    try {
      payload = jsonDecode(row.normalizedPayloadJson);
    } on FormatException {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    final candidate = const DocumentCandidateBatchCodec()
        .decodeObject({
          'schema_version': row.schemaVersion,
          'source_id': source.id,
          'content_hash': source.contentHash,
          'timezone': DocumentCandidateBatchCodec.timezone,
          'candidates': [payload],
        })
        .candidates
        .single;
    return DocumentCandidateReview(
      localId: row.id,
      sourceId: row.sourceId,
      candidate: candidate,
      reviewState: DocumentCandidateReviewState.fromWire(row.reviewState),
      isSelected: row.isSelected,
      remoteSyncPending: row.remoteSyncState != 'synced',
      courseId: row.courseId,
      remoteCandidateId: row.remoteCandidateId,
      remoteVersion: row.remoteVersion,
      linkedEntityType: row.linkedEntityType,
      linkedEntityId: row.linkedEntityId,
    );
  }

  Future<local.DocumentCandidatesCacheData?> _candidateRow(
    String ownerUserId,
    String candidateLocalId,
  ) {
    return (db.select(db.documentCandidatesCache)
          ..where(
            (row) =>
                row.id.equals(candidateLocalId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
  }

  Future<local.DocumentSourcesCacheData> _sourceRow(
    String ownerUserId,
    String sourceId,
  ) async {
    final source = await (db.select(db.documentSourcesCache)
          ..where(
            (row) =>
                row.id.equals(sourceId) & row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
    if (source == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.invalidExtraction,
      );
    }
    return source;
  }

  DateTime _notificationAnchor(DocumentScheduleCandidate candidate) {
    return (candidate.type == DocumentCandidateType.assignment
            ? candidate.dueAt!
            : candidate.startAt!)
        .toUtc();
  }

  String _targetPath(DocumentCandidateType type, String entityId) {
    return switch (type) {
      DocumentCandidateType.assignment => '/assignment/$entityId/edit',
      DocumentCandidateType.exam => '/exam/$entityId/edit',
    };
  }

  String _candidateCacheId(
    String ownerUserId,
    String sourceId,
    String candidateKey,
  ) {
    return _uuid.v5(
      Namespace.url.value,
      'document-candidate-cache\u0000$ownerUserId\u0000$sourceId\u0000$candidateKey',
    );
  }

  String _localSemanticIdentity(
    DocumentScheduleCandidate candidate,
    String? courseId,
  ) {
    return jsonEncode({
      'type': candidate.type.wireName,
      'title': candidate.title,
      'course_hint': {
        'name': candidate.courseHint.name,
        'code': candidate.courseHint.code,
      },
      'course_id': courseId,
      'due_at': candidate.dueAt?.toUtc().toIso8601String(),
      'all_day': candidate.allDay,
      'start_at': candidate.startAt?.toUtc().toIso8601String(),
      'end_at': candidate.endAt?.toUtc().toIso8601String(),
      'location': candidate.location,
      'submission_url': candidate.submissionUrl,
      'notes': candidate.notes,
      'timezone': candidate.timezone,
      'requires_user_confirmation': candidate.requiresUserConfirmation,
    });
  }

  String _stableId(String kind, String ownerUserId, String candidateId) {
    return _uuid.v5(
      Namespace.url.value,
      '$kind\u0000$ownerUserId\u0000$candidateId',
    );
  }

  String _requireOwner([String? expected]) {
    try {
      lease?.check(
        ownerUserId: expected ?? authenticatedUserId() ?? '',
        database: db,
      );
    } on ScopedContextLeaseException {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.configurationMissing,
      );
    }
    final ownerUserId = authenticatedUserId();
    if (ownerUserId == null ||
        ownerUserId.isEmpty ||
        ownerUserId != ownerUserId.trim() ||
        (expected != null && ownerUserId != expected)) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.configurationMissing,
      );
    }
    return ownerUserId;
  }

  bool _isAuthenticatedOwner(String expected) {
    try {
      lease?.check(ownerUserId: expected, database: db);
    } on ScopedContextLeaseException {
      return false;
    }
    final ownerUserId = authenticatedUserId();
    return ownerUserId != null &&
        ownerUserId.isNotEmpty &&
        ownerUserId == ownerUserId.trim() &&
        ownerUserId == expected;
  }

  String? _normalizedOptionalId(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
