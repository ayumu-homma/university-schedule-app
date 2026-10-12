import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../local_db/app_database.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../domain/email_review_models.dart';
import '../domain/email_timezone.dart';
import 'email_candidate_dedupe.dart';

class DriftEmailReviewStore implements EmailReviewStore {
  DriftEmailReviewStore({
    required this.db,
    required this.authenticatedUserId,
    this.lease,
    DateTime Function()? clock,
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
    CourseNormalizer? courseNormalizer,
  })  : _clock = clock ?? DateTime.now,
        _candidateCodec = candidateCodec,
        _courseNormalizer = courseNormalizer ?? CourseNormalizer();

  final AppDatabase db;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final DateTime Function() _clock;
  final EmailCandidatePayloadCodec _candidateCodec;
  final CourseNormalizer _courseNormalizer;

  @override
  Stream<List<EmailConnectionSummary>> watchConnections(String ownerUserId) {
    _requireOwner(ownerUserId);
    return db.emailImportDao.watchConnections(ownerUserId).map(
      (rows) {
        _requireOwner(ownerUserId);
        return rows.map(_connectionSummary).toList(growable: false);
      },
    );
  }

  @override
  Stream<List<EmailReviewCandidate>> watchCandidates(String ownerUserId) {
    _requireOwner(ownerUserId);
    final changes = db.customSelect(
      'SELECT 1 AS email_review_change',
      readsFrom: {
        db.emailCandidates,
        db.emailDismissalTombstones,
        db.profiles,
        db.universities,
      },
    ).watch();
    return changes.asyncMap((_) async {
      _requireOwner(ownerUserId);
      final ownerTimezone = await _ownerTimezone(ownerUserId);
      final candidateQuery = db.select(db.emailCandidates)
        ..where((row) => row.ownerUserId.equals(ownerUserId));
      final tombstoneQuery = db.select(db.emailDismissalTombstones)
        ..where((row) => row.ownerUserId.equals(ownerUserId));
      final candidates = await candidateQuery.get();
      final tombstones = await tombstoneQuery.get();
      _requireOwner(ownerUserId);
      final items = <EmailReviewCandidate>[
        ...candidates.map((row) => _reviewCandidate(row, ownerTimezone)),
        ...tombstones.map((row) => _dismissedCandidate(row, ownerTimezone)),
      ]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
      return List.unmodifiable(items);
    });
  }

  @override
  Future<EmailReviewCandidate?> loadCandidate({
    required String ownerUserId,
    required String candidateId,
  }) async {
    _requireOwner(ownerUserId);
    final ownerTimezone = await _ownerTimezone(ownerUserId);
    final row = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: candidateId,
    );
    _requireOwner(ownerUserId);
    if (row != null) return _reviewCandidate(row, ownerTimezone);
    final tombstone = await db.emailImportDao.dismissalById(
      ownerUserId: ownerUserId,
      tombstoneId: candidateId,
    );
    _requireOwner(ownerUserId);
    return tombstone == null
        ? null
        : _dismissedCandidate(tombstone, ownerTimezone);
  }

  @override
  Future<void> saveDraft({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
  }) async {
    _requireOwner(ownerUserId);
    final ownerTimezone = await _ownerTimezone(ownerUserId);
    final timezone =
        payload.due.timezone ?? ownerTimezone ?? JapanTime.timeZone;
    final normalizedPayload = payload.withConfiguredTimezone(timezone);
    final canonicalPayload = _candidateCodec.encode(normalizedPayload);
    final now = _clock().toUtc();
    await db.transaction(() async {
      _requireOwner(ownerUserId);
      final existing = await db.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      if (existing == null) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final state = _reviewState(existing.reviewState);
      if (state == EmailCandidateReviewState.confirmed ||
          state == EmailCandidateReviewState.dismissed) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final updated = await (db.update(db.emailCandidates)
            ..where(
              (row) =>
                  row.id.equals(candidateId) &
                  row.ownerUserId.equals(ownerUserId),
            ))
          .write(
        EmailCandidatesCompanion(
          schemaVersion: Value(normalizedPayload.schemaVersion),
          candidateType: Value(normalizedPayload.candidateType.wireName),
          normalizedPayloadJson: Value(canonicalPayload),
          reviewState: Value(
            state == EmailCandidateReviewState.updateAvailable
                ? state.wireName
                : _draftState(normalizedPayload).wireName,
          ),
          semanticFingerprint: Value(
            emailCandidateSemanticFingerprint(
              normalizedPayload,
              normalizer: _courseNormalizer,
            ),
          ),
          errorCategory: const Value(null),
          requiresUserConfirmation: const Value(true),
          updatedAt: Value(now),
        ),
      );
      _requireOwner(ownerUserId);
      if (updated != 1) {
        throw const EmailReviewActionException(
          EmailErrorCategory.internalError,
        );
      }
    });
  }

  @override
  Future<void> dismiss({
    required String ownerUserId,
    required String candidateId,
  }) async {
    _requireOwner(ownerUserId);
    final now = _clock().toUtc();
    await db.transaction(() async {
      _requireOwner(ownerUserId);
      final existing = await db.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      if (existing == null) {
        final replay = await db.emailImportDao.dismissalById(
          ownerUserId: ownerUserId,
          tombstoneId: candidateId,
        );
        if (replay != null) return;
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final state = _reviewState(existing.reviewState);
      if (state == EmailCandidateReviewState.confirmed) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      if (state == EmailCandidateReviewState.dismissed) {
        await db.emailImportDao.dismissAndPruneCandidate(
          ownerUserId: ownerUserId,
          candidateId: candidateId,
          dismissedAt: existing.dismissedAt ?? now,
        );
        return;
      }
      final pruned = await db.emailImportDao.dismissAndPruneCandidate(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        dismissedAt: now,
      );
      _requireOwner(ownerUserId);
      if (!pruned) {
        throw const EmailReviewActionException(
          EmailErrorCategory.internalError,
        );
      }
    });
  }

  EmailConnectionSummary _connectionSummary(EmailConnection row) {
    EmailProvider provider;
    EmailConnectionStatus status;
    EmailErrorCategory? errorCategory;
    try {
      provider = EmailProvider.fromWire(row.provider);
      status = EmailConnectionStatus.fromWire(row.state);
      errorCategory = row.errorCategory == null
          ? null
          : EmailErrorCategory.fromWire(row.errorCategory!);
    } on FormatException {
      provider = EmailProvider.gmail;
      status = EmailConnectionStatus.failed;
      errorCategory = EmailErrorCategory.validationFailed;
    }
    return EmailConnectionSummary(
      id: row.id,
      provider: provider,
      status: status,
      errorCategory: errorCategory,
      retryAfter: row.retryAfter,
      lastSyncedAt: row.lastSyncedAt,
      updatedAt: row.updatedAt,
    );
  }

  EmailReviewCandidate _reviewCandidate(
    EmailCandidate row,
    String? ownerTimezone,
  ) {
    EmailCandidateReviewState state;
    EmailCandidatePayload? payload;
    EmailErrorCategory? errorCategory;
    try {
      state = EmailCandidateReviewState.fromWire(row.reviewState);
    } on FormatException {
      state = EmailCandidateReviewState.failed;
      errorCategory = EmailErrorCategory.validationFailed;
    }
    if (state == EmailCandidateReviewState.failed) {
      if (errorCategory == null) {
        final storedCategory = row.errorCategory;
        if (storedCategory == null) {
          errorCategory = EmailErrorCategory.internalError;
        } else {
          try {
            errorCategory = EmailErrorCategory.fromWire(storedCategory);
          } on FormatException {
            errorCategory = EmailErrorCategory.internalError;
          }
        }
      }
    } else {
      try {
        payload = _candidateCodec.decode(row.normalizedPayloadJson);
      } on EmailCandidateValidationException catch (error) {
        state = EmailCandidateReviewState.failed;
        errorCategory = error.errorCategory;
      }
      if (errorCategory == null && row.errorCategory != null) {
        try {
          errorCategory = EmailErrorCategory.fromWire(row.errorCategory!);
        } on FormatException {
          errorCategory = EmailErrorCategory.internalError;
        }
      }
    }
    final payloadTimezone = payload?.due.timezone;
    final timezone =
        payloadTimezone != null && isValidEmailTimezone(payloadTimezone)
            ? payloadTimezone
            : ownerTimezone ?? JapanTime.timeZone;
    return EmailReviewCandidate(
      id: row.id,
      state: state,
      payload: payload,
      errorCategory: errorCategory,
      updatedAt: row.updatedAt,
      timezone: timezone,
    );
  }

  EmailReviewCandidate _dismissedCandidate(
    EmailDismissalTombstone row,
    String? ownerTimezone,
  ) {
    return EmailReviewCandidate(
      id: row.id,
      state: EmailCandidateReviewState.dismissed,
      payload: null,
      updatedAt: row.dismissedAt,
      timezone: ownerTimezone ?? JapanTime.timeZone,
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
    final configured = university?.status == 'active' &&
            university?.deletedAt == null &&
            isValidEmailTimezone(university!.timezone)
        ? university.timezone
        : null;
    return configured;
  }

  EmailCandidateReviewState _reviewState(String value) {
    try {
      return EmailCandidateReviewState.fromWire(value);
    } on FormatException {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
  }

  EmailCandidateReviewState _draftState(EmailCandidatePayload payload) {
    final hasTitle = payload.title?.trim().isNotEmpty == true;
    final complete = switch (payload.candidateType) {
      EmailCandidateType.assignment => hasTitle && payload.due.at != null,
      EmailCandidateType.exam => hasTitle &&
          payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.event => hasTitle &&
          payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.announcement || EmailCandidateType.unknown => false,
    };
    return complete && payload.warnings.isEmpty
        ? EmailCandidateReviewState.readyForReview
        : EmailCandidateReviewState.needsReview;
  }

  void _requireOwner(String ownerUserId) {
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
    } on ScopedContextLeaseException {
      throw const EmailReviewActionException(
        EmailErrorCategory.authorizationRevoked,
      );
    }
    if (ownerUserId.trim().isEmpty || authenticatedUserId() != ownerUserId) {
      throw const EmailReviewActionException(
        EmailErrorCategory.authorizationRevoked,
      );
    }
  }
}
