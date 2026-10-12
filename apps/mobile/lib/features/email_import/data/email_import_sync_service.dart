import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:uuid/uuid.dart';

import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database.dart';
import '../../../local_db/email_import_identity.dart';
import 'email_candidate_dedupe.dart';
import 'email_connector_binding.dart';
import 'email_import_failure.dart';

class EmailImportSyncResult {
  const EmailImportSyncResult({
    required this.pageCount,
    required this.itemCount,
    required this.recoveredExpiredCursor,
  });

  final int pageCount;
  final int itemCount;
  final bool recoveredExpiredCursor;
}

/// Applies validated, provider-independent fetch pages to the private cache.
///
/// Fetching and each page commit are deliberately separate: a page's sources,
/// candidates and cursor advance are written in one transaction, so a crash
/// cannot acknowledge a cursor while dropping its candidates. This service
/// never creates an Assignment, Exam, Event, projection or notification.
class EmailImportSyncService {
  EmailImportSyncService({
    required this.db,
    required this.connector,
    required this.clock,
    required this.authenticatedUserId,
    this.lease,
    Uuid uuid = const Uuid(),
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
    CourseNormalizer? courseNormalizer,
  })  : _uuid = uuid,
        _candidateCodec = candidateCodec,
        _courseNormalizer = courseNormalizer ?? CourseNormalizer();

  static const int maximumPagesPerRun = 20;
  static const int maximumItemsPerRun = 1000;
  static const int maximumEvidenceExcerpts = 8;
  static const int maximumEvidenceExcerptCharacters = 512;

  final AppDatabase db;
  final EmailConnector connector;
  final DateTime Function() clock;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final Uuid _uuid;
  final EmailCandidatePayloadCodec _candidateCodec;
  final CourseNormalizer _courseNormalizer;

  /// Applies a single targeted retry result without reading or advancing the
  /// connection cursor. The trusted endpoint owns provider reprocessing; this
  /// method only performs the same validated, owner-scoped cache upsert used
  /// by incremental pages.
  Future<void> persistTargetedRetryItem({
    required String ownerUserId,
    required String connectionId,
    required EmailFetchItem item,
  }) async {
    _requireIdentifier(ownerUserId, 'ownerUserId');
    _requireIdentifier(connectionId, 'connectionId');
    _requireActiveOwner(ownerUserId);
    if (connector is ConnectionBoundEmailConnector &&
        (connector as ConnectionBoundEmailConnector).connectionId !=
            connectionId) {
      throw StateError('Email connector is bound to another connection.');
    }
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    if (connection == null ||
        connection.provider != connector.provider.wireName ||
        !const {'connected', 'rate_limited', 'failed'}
            .contains(connection.state) ||
        connection.disconnectedAt != null) {
      throw StateError('Email connection is unavailable for this owner.');
    }
    final committedAt = clock().toUtc();
    await db.transaction(() async {
      _requireActiveOwner(ownerUserId);
      final currentConnection = await _requireTargetedConnectionUnchanged(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        expectedConnection: connection,
      );
      await _persistItem(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        provider: currentConnection.provider,
        providerAccountHash: currentConnection.providerAccountHash,
        item: item,
        committedAt: committedAt,
      );
      _requireActiveOwner(ownerUserId);
    });
  }

  /// Applies a trusted targeted-retry suppression acknowledgement without
  /// moving the incremental cursor or creating a reconciliation outbox row.
  Future<void> persistTargetedRetrySuppression({
    required String ownerUserId,
    required String connectionId,
    required EmailFetchSuppression suppression,
  }) async {
    _requireIdentifier(ownerUserId, 'ownerUserId');
    _requireIdentifier(connectionId, 'connectionId');
    _validateSuppression(suppression);
    _requireActiveOwner(ownerUserId);
    if (connector is ConnectionBoundEmailConnector &&
        (connector as ConnectionBoundEmailConnector).connectionId !=
            connectionId) {
      throw StateError('Email connector is bound to another connection.');
    }
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    if (connection == null ||
        connection.provider != connector.provider.wireName ||
        !const {'connected', 'rate_limited', 'failed'}
            .contains(connection.state) ||
        connection.disconnectedAt != null) {
      throw StateError('Email connection is unavailable for this owner.');
    }
    final committedAt = clock().toUtc();
    await db.transaction(() async {
      _requireActiveOwner(ownerUserId);
      await _requireTargetedConnectionUnchanged(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        expectedConnection: connection,
      );
      final pruned = await _persistSuppression(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        suppression: suppression,
        committedAt: committedAt,
      );
      if (!pruned) {
        throw StateError('Targeted email suppression did not match a failure.');
      }
      _requireActiveOwner(ownerUserId);
    });
  }

  Future<EmailConnection> _requireTargetedConnectionUnchanged({
    required String ownerUserId,
    required String connectionId,
    required EmailConnection expectedConnection,
  }) async {
    final currentConnection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    if (currentConnection == null ||
        currentConnection.provider != connector.provider.wireName ||
        currentConnection.provider != expectedConnection.provider ||
        currentConnection.providerAccountHash !=
            expectedConnection.providerAccountHash ||
        !const {'connected', 'rate_limited', 'failed'}
            .contains(currentConnection.state) ||
        currentConnection.disconnectedAt != null) {
      throw StateError('Email connection is unavailable for this owner.');
    }
    return currentConnection;
  }

  Future<EmailImportSyncResult> synchronize({
    required String ownerUserId,
    required String connectionId,
  }) async {
    _requireIdentifier(ownerUserId, 'ownerUserId');
    _requireIdentifier(connectionId, 'connectionId');
    _requireActiveOwner(ownerUserId);
    if (connector is ConnectionBoundEmailConnector) {
      final boundConnector = connector as ConnectionBoundEmailConnector;
      if (boundConnector.connectionId != connectionId) {
        throw StateError('Email connector is bound to another connection.');
      }
    }
    final initialConnection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    if (initialConnection == null ||
        initialConnection.provider != connector.provider.wireName ||
        !const {
          'connected',
          'rate_limited',
          'failed',
        }.contains(initialConnection.state) ||
        initialConnection.disconnectedAt != null) {
      throw StateError('Email connection is unavailable for this owner.');
    }

    var cursor = initialConnection.cursor;
    var expectedStoredCursor = initialConnection.cursor;
    var expectedConnectionState = initialConnection.state;
    var expectedConnectionUpdatedAt = initialConnection.updatedAt;
    var expectedLastSyncedAt = initialConnection.lastSyncedAt;
    var pageCount = 0;
    var itemCount = 0;
    var processedCount = 0;
    var recoveredExpiredCursor = false;

    while (pageCount < maximumPagesPerRun) {
      late final EmailFetchPage page;
      try {
        _requireActiveOwner(ownerUserId);
        page = await connector.fetchDelta(cursor: cursor);
      } on EmailImportFailure catch (failure) {
        if (failure.errorCategory == EmailErrorCategory.cursorExpired &&
            cursor != null &&
            !recoveredExpiredCursor) {
          cursor = null;
          recoveredExpiredCursor = true;
          continue;
        }
        if (_isActiveOwner(ownerUserId)) {
          await _recordFailure(
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            failure: failure,
            provider: initialConnection.provider,
            providerAccountHash: initialConnection.providerAccountHash,
            expectedCursor: expectedStoredCursor,
            expectedState: expectedConnectionState,
            expectedUpdatedAt: expectedConnectionUpdatedAt,
            expectedLastSyncedAt: expectedLastSyncedAt,
          );
        }
        rethrow;
      }

      try {
        _validatePage(
          page,
          previousCursor: cursor,
          provider: initialConnection.provider,
          providerAccountHash: initialConnection.providerAccountHash,
        );
        if (processedCount + page.items.length + page.suppressions.length >
            maximumItemsPerRun) {
          throw const EmailImportFailure(
            connectionStatus: EmailConnectionStatus.failed,
            errorCategory: EmailErrorCategory.oversizedContent,
          );
        }
        final committedAt = clock().toUtc();
        await db.transaction(() async {
          _requireActiveOwner(ownerUserId);
          final chronologicalItems = page.items.toList(growable: false)
            ..sort((left, right) {
              final byReceivedAt = left.receivedAt.compareTo(right.receivedAt);
              if (byReceivedAt != 0) return byReceivedAt;
              return left.providerMessageId.compareTo(right.providerMessageId);
            });
          for (final item in chronologicalItems) {
            await _persistItem(
              ownerUserId: ownerUserId,
              connectionId: connectionId,
              provider: initialConnection.provider,
              providerAccountHash: initialConnection.providerAccountHash,
              item: item,
              committedAt: committedAt,
            );
          }
          for (final suppression in page.suppressions) {
            await _persistSuppression(
              ownerUserId: ownerUserId,
              connectionId: connectionId,
              suppression: suppression,
              committedAt: committedAt,
            );
          }
          _requireActiveOwner(ownerUserId);
          final advanced = await _updateConnectionIfUnchanged(
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            provider: initialConnection.provider,
            providerAccountHash: initialConnection.providerAccountHash,
            expectedCursor: expectedStoredCursor,
            expectedState: expectedConnectionState,
            expectedUpdatedAt: expectedConnectionUpdatedAt,
            cursor: page.nextCursor,
            status: EmailConnectionStatus.connected,
            errorCategory: null,
            retryAfter: null,
            lastSyncedAt: committedAt,
            updatedAt: committedAt,
          );
          if (!advanced) {
            throw StateError('Email connection changed during sync.');
          }
          _requireActiveOwner(ownerUserId);
        });
        expectedStoredCursor = page.nextCursor;
        expectedConnectionState = EmailConnectionStatus.connected.wireName;
        expectedConnectionUpdatedAt = committedAt;
        expectedLastSyncedAt = committedAt;
      } on EmailImportFailure catch (failure) {
        if (_isActiveOwner(ownerUserId)) {
          await _recordFailure(
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            failure: failure,
            provider: initialConnection.provider,
            providerAccountHash: initialConnection.providerAccountHash,
            expectedCursor: expectedStoredCursor,
            expectedState: expectedConnectionState,
            expectedUpdatedAt: expectedConnectionUpdatedAt,
            expectedLastSyncedAt: expectedLastSyncedAt,
          );
        }
        rethrow;
      }

      pageCount += 1;
      itemCount += page.items.length;
      processedCount += page.items.length + page.suppressions.length;
      cursor = page.nextCursor;
      if (!page.hasMore) {
        return EmailImportSyncResult(
          pageCount: pageCount,
          itemCount: itemCount,
          recoveredExpiredCursor: recoveredExpiredCursor,
        );
      }
    }

    const failure = EmailImportFailure(
      connectionStatus: EmailConnectionStatus.failed,
      errorCategory: EmailErrorCategory.internalError,
    );
    await _recordFailure(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      failure: failure,
      provider: initialConnection.provider,
      providerAccountHash: initialConnection.providerAccountHash,
      expectedCursor: expectedStoredCursor,
      expectedState: expectedConnectionState,
      expectedUpdatedAt: expectedConnectionUpdatedAt,
      expectedLastSyncedAt: expectedLastSyncedAt,
    );
    throw failure;
  }

  Future<void> _persistItem({
    required String ownerUserId,
    required String connectionId,
    required String provider,
    required String providerAccountHash,
    required EmailFetchItem item,
    required DateTime committedAt,
  }) async {
    _validateItem(item);
    final candidate = item.candidate;
    final errorCategory = item.errorCategory;
    final providerThreadId = item.providerThreadId ??
        _failedThreadIdentity(
          provider: provider,
          providerAccountHash: providerAccountHash,
          providerMessageId: item.providerMessageId,
        );
    final semanticFingerprint = candidate == null
        ? _failedCandidateFingerprint(
            provider: provider,
            providerAccountHash: providerAccountHash,
            providerMessageId: item.providerMessageId,
            sanitizedContentHash: item.sanitizedContentHash,
          )
        : emailCandidateSemanticFingerprint(
            candidate,
            normalizer: _courseNormalizer,
          );
    final providerMessageIdHash = emailProviderIdentifierHash(
      kind: 'message',
      provider: provider,
      providerAccountHash: providerAccountHash,
      rawIdentifier: item.providerMessageId,
    );
    final providerThreadIdHash = emailProviderIdentifierHash(
      kind: 'thread',
      provider: provider,
      providerAccountHash: providerAccountHash,
      rawIdentifier: providerThreadId,
    );
    final sourceId = _stableId(
      'source',
      ownerUserId,
      connectionId,
      item.providerMessageId,
    );
    final candidateId = _stableId('candidate', ownerUserId, sourceId);
    final existingSource = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: sourceId,
    );
    if (existingSource != null) {
      if (existingSource.connectionId != connectionId ||
          existingSource.providerMessageId != item.providerMessageId) {
        throw StateError('Stable email source identity collision.');
      }
      if (existingSource.processingState != 'failed' && candidate == null) {
        // A transient retry response must never downgrade an already validated
        // proposal or reintroduce a failure after it was successfully parsed.
        return;
      }
      if (existingSource.processingState != 'failed' &&
          (existingSource.providerThreadId != providerThreadId ||
              existingSource.receivedAt.toUtc() != item.receivedAt.toUtc() ||
              existingSource.sanitizedContentHash !=
                  item.sanitizedContentHash)) {
        throw StateError('Stable email source identity collision.');
      }
    }
    var existingCandidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: candidateId,
    );
    if (await db.emailImportDao.isDismissedDuplicate(
      ownerUserId: ownerUserId,
      provider: provider,
      providerAccountHash: providerAccountHash,
      providerMessageIdHash: providerMessageIdHash,
      providerThreadIdHash: providerThreadIdHash,
      sanitizedContentHash: item.sanitizedContentHash,
      semanticFingerprint: semanticFingerprint,
    )) {
      if (existingSource?.processingState == 'failed') {
        final pruned = await db.emailImportDao.pruneSuppressedFailedSource(
          ownerUserId: ownerUserId,
          connectionId: connectionId,
          providerMessageIdHash: providerMessageIdHash,
          retainDismissalTombstone: true,
          suppressedAt: committedAt,
        );
        if (!pruned) {
          throw StateError(
            'Dismissed email retry did not prune its stale failure.',
          );
        }
      }
      return;
    }
    if (candidate == null) {
      if (await _removeFailedCandidateForSourceTransition(
        ownerUserId: ownerUserId,
        candidate: existingCandidate,
      )) {
        existingCandidate = null;
      }
      await db.emailImportDao.upsertSource(
        ownerUserId: ownerUserId,
        source: EmailSourcesCompanion.insert(
          id: sourceId,
          ownerUserId: ownerUserId,
          connectionId: connectionId,
          providerMessageId: item.providerMessageId,
          providerThreadId: providerThreadId,
          receivedAt: item.receivedAt.toUtc(),
          sanitizedContentHash: item.sanitizedContentHash,
          evidenceExcerptsJson: const Value('[]'),
          processingState: const Value('failed'),
          errorCategory: Value(errorCategory!.wireName),
          createdAt: Value(existingSource?.createdAt ?? committedAt),
          updatedAt: Value(committedAt),
        ),
      );
      if (existingCandidate?.reviewState ==
              EmailCandidateReviewState.confirmed.wireName ||
          existingCandidate?.reviewState ==
              EmailCandidateReviewState.dismissed.wireName) {
        return;
      }
      await db.emailImportDao.upsertCandidate(
        ownerUserId: ownerUserId,
        candidate: EmailCandidatesCompanion.insert(
          id: candidateId,
          ownerUserId: ownerUserId,
          sourceId: sourceId,
          schemaVersion: '1.0',
          candidateType: EmailCandidateType.unknown.wireName,
          normalizedPayloadJson: '{}',
          reviewState: Value(EmailCandidateReviewState.failed.wireName),
          semanticFingerprint: semanticFingerprint,
          errorCategory: Value(errorCategory.wireName),
          requiresUserConfirmation: const Value(true),
          createdAt: Value(existingCandidate?.createdAt ?? committedAt),
          updatedAt: Value(committedAt),
        ),
      );
      return;
    }

    final duplicateContent = await db.emailImportDao.sourceByThreadContentHash(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerThreadId: providerThreadId,
      sanitizedContentHash: item.sanitizedContentHash,
      excludingSourceId: sourceId,
    );
    if (duplicateContent != null) {
      if (await _removeFailedCandidateForSourceTransition(
        ownerUserId: ownerUserId,
        candidate: existingCandidate,
      )) {
        existingCandidate = null;
      }
      await db.emailImportDao.upsertSource(
        ownerUserId: ownerUserId,
        source: EmailSourcesCompanion.insert(
          id: sourceId,
          ownerUserId: ownerUserId,
          connectionId: connectionId,
          providerMessageId: item.providerMessageId,
          providerThreadId: providerThreadId,
          receivedAt: item.receivedAt.toUtc(),
          sanitizedContentHash: item.sanitizedContentHash,
          evidenceExcerptsJson: const Value('[]'),
          processingState: const Value('ignored'),
          errorCategory: const Value(null),
          createdAt: Value(existingSource?.createdAt ?? committedAt),
          updatedAt: Value(committedAt),
        ),
      );
      return;
    }

    if (await _removeFailedCandidateForSourceTransition(
      ownerUserId: ownerUserId,
      candidate: existingCandidate,
    )) {
      existingCandidate = null;
    }
    await db.emailImportDao.upsertSource(
      ownerUserId: ownerUserId,
      source: EmailSourcesCompanion.insert(
        id: sourceId,
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        providerMessageId: item.providerMessageId,
        providerThreadId: providerThreadId,
        receivedAt: item.receivedAt.toUtc(),
        sanitizedContentHash: item.sanitizedContentHash,
        evidenceExcerptsJson: Value(jsonEncode(item.evidenceExcerpts)),
        processingState: const Value('processed'),
        errorCategory: const Value(null),
        createdAt: Value(existingSource?.createdAt ?? committedAt),
        updatedAt: Value(committedAt),
      ),
    );

    if (existingCandidate?.reviewState ==
        EmailCandidateReviewState.confirmed.wireName) {
      if (existingSource?.sanitizedContentHash == item.sanitizedContentHash) {
        return;
      }
      await _persistUpdateProposal(
        ownerUserId: ownerUserId,
        confirmedCandidate: existingCandidate!,
        proposedSourceId: sourceId,
        proposedPayload: candidate,
        committedAt: committedAt,
      );
      return;
    }
    if (existingCandidate?.reviewState ==
        EmailCandidateReviewState.dismissed.wireName) {
      return;
    }

    var proposalPayload = candidate;
    var existingDraftIsConvertible = existingCandidate == null ||
        existingCandidate.reviewState ==
            EmailCandidateReviewState.failed.wireName;
    if (existingCandidate != null &&
        existingCandidate.reviewState !=
            EmailCandidateReviewState.failed.wireName) {
      try {
        proposalPayload = _candidateCodec.decode(
          existingCandidate.normalizedPayloadJson,
        );
        existingDraftIsConvertible = true;
      } on EmailCandidateValidationException {
        existingDraftIsConvertible = false;
      }
    }

    final confirmedInThread = (await db.emailImportDao
            .confirmedCandidatesForThread(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerThreadId: providerThreadId,
    ))
        .where(
          (candidate) =>
              candidate.candidateType == proposalPayload.candidateType.wireName,
        )
        .toList(growable: false);
    if (confirmedInThread.length == 1 && existingDraftIsConvertible) {
      final draftCandidate = existingCandidate;
      if (draftCandidate != null) {
        final removed = await (db.delete(db.emailCandidates)
              ..where((row) =>
                  row.id.equals(draftCandidate.id) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.reviewState.isIn(const [
                    'needs_review',
                    'ready_for_review',
                    'update_available',
                    'failed',
                  ])))
            .go();
        if (removed != 1) {
          throw StateError(
            'Cached email sibling changed during update conversion.',
          );
        }
      }
      await _persistUpdateProposal(
        ownerUserId: ownerUserId,
        confirmedCandidate: confirmedInThread.single,
        proposedSourceId: sourceId,
        proposedPayload: proposalPayload,
        committedAt: committedAt,
      );
      return;
    }
    if (existingCandidate != null &&
        existingCandidate.reviewState !=
            EmailCandidateReviewState.failed.wireName &&
        existingSource?.sanitizedContentHash == item.sanitizedContentHash) {
      return;
    }

    final payloadJson = _candidateCodec.encode(candidate);
    await db.emailImportDao.upsertCandidate(
      ownerUserId: ownerUserId,
      candidate: EmailCandidatesCompanion.insert(
        id: candidateId,
        ownerUserId: ownerUserId,
        sourceId: sourceId,
        schemaVersion: candidate.schemaVersion,
        candidateType: candidate.candidateType.wireName,
        normalizedPayloadJson: payloadJson,
        reviewState: Value(_initialReviewState(candidate).wireName),
        semanticFingerprint: semanticFingerprint,
        errorCategory: const Value(null),
        requiresUserConfirmation: const Value(true),
        createdAt: Value(existingCandidate?.createdAt ?? committedAt),
        updatedAt: Value(committedAt),
      ),
    );
  }

  Future<bool> _removeFailedCandidateForSourceTransition({
    required String ownerUserId,
    required EmailCandidate? candidate,
  }) async {
    if (candidate?.reviewState != EmailCandidateReviewState.failed.wireName) {
      return false;
    }
    final removed = await (db.delete(db.emailCandidates)
          ..where((row) =>
              row.id.equals(candidate!.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.reviewState.equals(
                EmailCandidateReviewState.failed.wireName,
              )))
        .go();
    if (removed != 1) {
      throw StateError('Failed email candidate changed during replacement.');
    }
    return true;
  }

  Future<void> _persistUpdateProposal({
    required String ownerUserId,
    required EmailCandidate confirmedCandidate,
    required String proposedSourceId,
    required EmailCandidatePayload proposedPayload,
    required DateTime committedAt,
  }) async {
    final EmailCandidatePayload baseline;
    try {
      baseline = _candidateCodec.decode(
        confirmedCandidate.normalizedPayloadJson,
      );
    } on EmailCandidateValidationException catch (error) {
      throw EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: error.errorCategory,
      );
    }
    final existingUpdates = await db.emailImportDao.updatesForCandidate(
      ownerUserId: ownerUserId,
      candidateId: confirmedCandidate.id,
    );
    final active = existingUpdates
        .where((proposal) => proposal.state == 'pending')
        .firstOrNull;
    final proposedSource = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: proposedSourceId,
    );
    final confirmedSource = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: confirmedCandidate.sourceId,
    );
    if (proposedSource == null || confirmedSource == null) {
      throw StateError('Email update source is unavailable.');
    }
    var newestKnownSource = confirmedSource;
    for (final proposal in existingUpdates) {
      final source = await db.emailImportDao.sourceById(
        ownerUserId: ownerUserId,
        sourceId: proposal.sourceId,
      );
      if (source == null) {
        throw StateError('Historical email update source is unavailable.');
      }
      if (source.receivedAt.isAfter(newestKnownSource.receivedAt)) {
        newestKnownSource = source;
      }
    }
    if (newestKnownSource.receivedAt.isAfter(proposedSource.receivedAt)) {
      if (active != null && active.sourceId != newestKnownSource.id) {
        await _supersedePendingUpdate(
          ownerUserId: ownerUserId,
          active: active,
          replacementIdentity: proposedSourceId,
          committedAt: committedAt,
        );
      }
      await _ignoreProposedSource(
        ownerUserId: ownerUserId,
        sourceId: proposedSourceId,
        committedAt: committedAt,
      );
      return;
    }
    final diff = emailScheduleFieldDiff(
      baseline: baseline,
      proposed: proposedPayload,
    );
    if (diff.isEmpty) {
      await _ignoreProposedSource(
        ownerUserId: ownerUserId,
        sourceId: proposedSourceId,
        committedAt: committedAt,
      );
      if (active != null) {
        await _supersedePendingUpdate(
          ownerUserId: ownerUserId,
          active: active,
          replacementIdentity: proposedSourceId,
          committedAt: committedAt,
        );
      }
      return;
    }

    final proposalFingerprint =
        emailCandidateUpdateFingerprint(proposedPayload);
    final matchingExistingUpdate = existingUpdates.where(
      (proposal) => proposal.semanticFingerprint == proposalFingerprint,
    );
    if (matchingExistingUpdate.isNotEmpty) {
      if (active != null && active.semanticFingerprint != proposalFingerprint) {
        await _supersedePendingUpdate(
          ownerUserId: ownerUserId,
          active: active,
          replacementIdentity: proposedSourceId,
          committedAt: committedAt,
        );
      }
      // A provider replay resolves to the same durable source row. Keep that
      // row processed while an existing proposal authenticates against it;
      // only a genuinely redundant sibling source is content-pruned/ignored.
      if (!matchingExistingUpdate.any(
        (proposal) => proposal.sourceId == proposedSourceId,
      )) {
        await _ignoreProposedSource(
          ownerUserId: ownerUserId,
          sourceId: proposedSourceId,
          committedAt: committedAt,
        );
      }
      return;
    }

    final baseVersion = await _canonicalEntityVersion(
      ownerUserId: ownerUserId,
      candidate: confirmedCandidate,
    );
    final updateId = _stableId(
      'candidate-update',
      ownerUserId,
      confirmedCandidate.id,
      proposalFingerprint,
    );
    if (active != null) {
      await _supersedePendingUpdate(
        ownerUserId: ownerUserId,
        active: active,
        replacementIdentity: updateId,
        committedAt: committedAt,
      );
    }

    await db.emailImportDao.insertCandidateUpdate(
      ownerUserId: ownerUserId,
      update: EmailCandidateUpdatesCompanion.insert(
        id: updateId,
        ownerUserId: ownerUserId,
        candidateId: confirmedCandidate.id,
        sourceId: proposedSourceId,
        fieldDiffJson: jsonEncode(diff),
        proposedPayloadJson: _candidateCodec.encode(proposedPayload),
        semanticFingerprint: proposalFingerprint,
        baseEntityVersion: Value(baseVersion),
        state: const Value('pending'),
        createdAt: Value(committedAt),
        updatedAt: Value(committedAt),
      ),
    );
  }

  Future<void> _ignoreProposedSource({
    required String ownerUserId,
    required String sourceId,
    required DateTime committedAt,
  }) async {
    final changed = await (db.update(db.emailSources)
          ..where((row) =>
              row.id.equals(sourceId) & row.ownerUserId.equals(ownerUserId)))
        .write(
      EmailSourcesCompanion(
        evidenceExcerptsJson: const Value('[]'),
        processingState: const Value('ignored'),
        updatedAt: Value(committedAt),
      ),
    );
    if (changed != 1) {
      throw StateError('Ignored email source is unavailable.');
    }
  }

  Future<void> _supersedePendingUpdate({
    required String ownerUserId,
    required EmailCandidateUpdate active,
    required String replacementIdentity,
    required DateTime committedAt,
  }) async {
    final supersededKey = _stableId(
      'candidate-update-superseded',
      ownerUserId,
      active.id,
      replacementIdentity,
    );
    final changed = await (db.update(db.emailCandidateUpdates)
          ..where((row) =>
              row.id.equals(active.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.state.equals('pending')))
        .write(
      EmailCandidateUpdatesCompanion(
        state: const Value('superseded'),
        resolutionIdempotencyKey: Value(supersededKey),
        resolvedAt: Value(committedAt),
        updatedAt: Value(committedAt),
      ),
    );
    if (changed != 1) {
      throw StateError('Active email update proposal changed during sync.');
    }
  }

  Future<int> _canonicalEntityVersion({
    required String ownerUserId,
    required EmailCandidate candidate,
  }) async {
    final entityId = candidate.linkedEntityId;
    if (entityId == null) {
      throw StateError('Confirmed email candidate has no linked entity.');
    }
    final version = switch (candidate.linkedEntityType) {
      'assignment' => (await (db.select(db.assignments)
                ..where((row) =>
                    row.id.equals(entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.deletedAt.isNull()))
              .getSingleOrNull())
          ?.version,
      'exam' => (await (db.select(db.exams)
                ..where((row) =>
                    row.id.equals(entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.deletedAt.isNull()))
              .getSingleOrNull())
          ?.version,
      'event' => (await (db.select(db.events)
                ..where((row) =>
                    row.id.equals(entityId) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.deletedAt.isNull()))
              .getSingleOrNull())
          ?.version,
      _ => null,
    };
    if (version == null || version < 1) {
      throw StateError('Confirmed email candidate entity is unavailable.');
    }
    return version;
  }

  Future<void> _recordFailure({
    required String ownerUserId,
    required String connectionId,
    required EmailImportFailure failure,
    required String provider,
    required String providerAccountHash,
    required String? expectedCursor,
    required String expectedState,
    required DateTime expectedUpdatedAt,
    required DateTime? expectedLastSyncedAt,
  }) async {
    final now = clock().toUtc();
    await _updateConnectionIfUnchanged(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      provider: provider,
      providerAccountHash: providerAccountHash,
      expectedCursor: expectedCursor,
      expectedState: expectedState,
      expectedUpdatedAt: expectedUpdatedAt,
      cursor: expectedCursor,
      status: failure.connectionStatus,
      errorCategory: failure.errorCategory,
      retryAfter:
          failure.retryAfter == null ? null : now.add(failure.retryAfter!),
      lastSyncedAt: expectedLastSyncedAt,
      updatedAt: now,
    );
  }

  Future<bool> _updateConnectionIfUnchanged({
    required String ownerUserId,
    required String connectionId,
    required String provider,
    required String providerAccountHash,
    required String? expectedCursor,
    required String expectedState,
    required DateTime expectedUpdatedAt,
    required String? cursor,
    required EmailConnectionStatus status,
    required EmailErrorCategory? errorCategory,
    required DateTime? retryAfter,
    required DateTime? lastSyncedAt,
    required DateTime updatedAt,
  }) async {
    final changed = await (db.update(db.emailConnections)
          ..where((row) {
            final cursorMatches = expectedCursor == null
                ? row.cursor.isNull()
                : row.cursor.equals(expectedCursor);
            return row.id.equals(connectionId) &
                row.ownerUserId.equals(ownerUserId) &
                row.provider.equals(provider) &
                row.providerAccountHash.equals(providerAccountHash) &
                row.state.equals(expectedState) &
                row.disconnectedAt.isNull() &
                row.updatedAt.equals(expectedUpdatedAt) &
                cursorMatches;
          }))
        .write(
      EmailConnectionsCompanion(
        cursor: Value(cursor),
        state: Value(status.wireName),
        errorCategory: Value(errorCategory?.wireName),
        retryAfter: Value(retryAfter),
        lastSyncedAt: Value(lastSyncedAt),
        updatedAt: Value(updatedAt),
      ),
    );
    return changed == 1;
  }

  void _validatePage(
    EmailFetchPage page, {
    required String? previousCursor,
    required String provider,
    required String providerAccountHash,
  }) {
    final nextCursor = page.nextCursor;
    if (nextCursor != null &&
        (nextCursor.isEmpty ||
            nextCursor != nextCursor.trim() ||
            nextCursor.length > 4096)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    if (page.hasMore && (nextCursor == null || nextCursor == previousCursor)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    if (page.items.length + page.suppressions.length > 100) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.oversizedContent,
      );
    }
    if ((page.items.isNotEmpty || page.suppressions.isNotEmpty) &&
        (nextCursor == null || nextCursor == previousCursor)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    final itemIds = page.items.map((item) => item.providerMessageId).toSet();
    final itemHashes = page.items
        .map(
          (item) => emailProviderIdentifierHash(
            kind: 'message',
            provider: provider,
            providerAccountHash: providerAccountHash,
            rawIdentifier: item.providerMessageId,
          ),
        )
        .toSet();
    final suppressionHashes =
        page.suppressions.map((item) => item.providerMessageIdHash).toSet();
    if (itemIds.length != page.items.length ||
        suppressionHashes.length != page.suppressions.length ||
        itemHashes.intersection(suppressionHashes).isNotEmpty) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    for (final suppression in page.suppressions) {
      _validateSuppression(suppression);
    }
  }

  Future<bool> _persistSuppression({
    required String ownerUserId,
    required String connectionId,
    required EmailFetchSuppression suppression,
    required DateTime committedAt,
  }) {
    _validateSuppression(suppression);
    return db.emailImportDao.pruneSuppressedFailedSource(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerMessageIdHash: suppression.providerMessageIdHash,
      retainDismissalTombstone:
          suppression.reason == EmailFetchSuppressionReason.dismissed,
      suppressedAt: committedAt,
    );
  }

  void _validateSuppression(EmailFetchSuppression suppression) {
    if (!RegExp(r'^[0-9a-f]{64}$')
        .hasMatch(suppression.providerMessageIdHash)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
  }

  void _validateItem(EmailFetchItem item) {
    _requireBoundedProviderIdentifier(
      item.providerMessageId,
      'providerMessageId',
    );
    final providerThreadId = item.providerThreadId;
    if (providerThreadId != null) {
      _requireBoundedProviderIdentifier(
        providerThreadId,
        'providerThreadId',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(item.sanitizedContentHash)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    final candidate = item.candidate;
    final errorCategory = item.errorCategory;
    if (item.receivedAt.isUtc == false ||
        item.evidenceExcerpts.length > maximumEvidenceExcerpts ||
        item.evidenceExcerpts.any(
          (excerpt) =>
              excerpt.isEmpty ||
              excerpt.length > maximumEvidenceExcerptCharacters,
        ) ||
        (candidate == null) == (errorCategory == null) ||
        (candidate == null && item.evidenceExcerpts.isNotEmpty) ||
        (candidate != null && providerThreadId == null) ||
        (candidate != null &&
            (!candidate.requiresUserConfirmation ||
                candidate.schemaVersion != '1.0'))) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    if (candidate != null) {
      try {
        _candidateCodec.toJson(candidate);
      } on EmailCandidateValidationException catch (error) {
        throw EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: error.errorCategory,
        );
      }
    }
  }

  String _failedThreadIdentity({
    required String provider,
    required String providerAccountHash,
    required String providerMessageId,
  }) {
    final hash = emailProviderIdentifierHash(
      kind: 'failed-thread-placeholder',
      provider: provider,
      providerAccountHash: providerAccountHash,
      rawIdentifier: providerMessageId,
    );
    return 'failed:$hash';
  }

  String _failedCandidateFingerprint({
    required String provider,
    required String providerAccountHash,
    required String providerMessageId,
    required String sanitizedContentHash,
  }) {
    return emailProviderIdentifierHash(
      kind: 'failed-candidate',
      provider: provider,
      providerAccountHash: providerAccountHash,
      rawIdentifier: '$providerMessageId\u0000$sanitizedContentHash',
    );
  }

  void _requireBoundedProviderIdentifier(String value, String name) {
    if (value.isEmpty || value != value.trim() || value.length > 1024) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
  }

  void _requireIdentifier(String value, String name) {
    if (value.isEmpty || value != value.trim() || value.length > 1024) {
      throw ArgumentError.value(value, name, 'must be a non-empty identifier');
    }
  }

  bool _isActiveOwner(String ownerUserId) {
    if (authenticatedUserId() != ownerUserId) return false;
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
      return true;
    } on ScopedContextLeaseException {
      return false;
    }
  }

  void _requireActiveOwner(String ownerUserId) {
    if (!_isActiveOwner(ownerUserId)) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.reauthRequired,
      );
    }
  }

  String _stableId(String kind, String first, String second, [String? third]) {
    final parts = [kind, first, second, if (third != null) third];
    return _uuid.v5(Namespace.url.value, parts.join('\u0000'));
  }

  EmailCandidateReviewState _initialReviewState(EmailCandidatePayload payload) {
    if (payload.warnings.isNotEmpty || payload.title == null) {
      return EmailCandidateReviewState.needsReview;
    }
    final complete = switch (payload.candidateType) {
      EmailCandidateType.assignment => payload.due.at != null,
      EmailCandidateType.exam => payload.startAt != null,
      EmailCandidateType.event =>
        payload.startAt != null && payload.endAt != null,
      EmailCandidateType.announcement || EmailCandidateType.unknown => false,
    };
    return complete
        ? EmailCandidateReviewState.readyForReview
        : EmailCandidateReviewState.needsReview;
  }
}
