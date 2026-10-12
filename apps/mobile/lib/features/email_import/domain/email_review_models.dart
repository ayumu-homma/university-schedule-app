import 'package:shared_domain/shared_domain.dart';

/// Presentation-safe connection metadata. Provider account identifiers and
/// addresses intentionally do not cross this boundary.
class EmailConnectionSummary {
  const EmailConnectionSummary({
    required this.id,
    required this.provider,
    required this.status,
    required this.updatedAt,
    this.errorCategory,
    this.retryAfter,
    this.lastSyncedAt,
  });

  final String id;
  final EmailProvider provider;
  final EmailConnectionStatus status;
  final EmailErrorCategory? errorCategory;
  final DateTime? retryAfter;
  final DateTime? lastSyncedAt;
  final DateTime updatedAt;
}

/// A locally cached, normalized proposal ready for private review.
///
/// [payload] is null when persisted data fails the current schema validator.
/// The UI must never render the rejected JSON or surface decoder diagnostics.
class EmailReviewCandidate {
  const EmailReviewCandidate({
    required this.id,
    required this.state,
    required this.updatedAt,
    this.timezone = JapanTime.timeZone,
    this.payload,
    this.errorCategory,
  });

  final String id;
  final EmailCandidateReviewState state;
  final EmailCandidatePayload? payload;
  final EmailErrorCategory? errorCategory;
  final DateTime updatedAt;
  final String timezone;

  bool get isHistory =>
      state == EmailCandidateReviewState.confirmed ||
      state == EmailCandidateReviewState.dismissed;

  bool get isActionable => !isHistory;

  bool get canRetry =>
      state == EmailCandidateReviewState.failed &&
      errorCategory?.isCandidateRetryable == true;
}

abstract interface class EmailReviewStore {
  Stream<List<EmailConnectionSummary>> watchConnections(String ownerUserId);

  Stream<List<EmailReviewCandidate>> watchCandidates(String ownerUserId);

  Future<EmailReviewCandidate?> loadCandidate({
    required String ownerUserId,
    required String candidateId,
  });

  Future<void> saveDraft({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
  });

  Future<void> dismiss({
    required String ownerUserId,
    required String candidateId,
  });
}

/// Network-required operations are kept separate from the offline review
/// store. Test fakes can implement this boundary, but production composition
/// never selects a fake connector.
abstract interface class EmailReviewRemoteActions {
  Future<EmailConnectionState> connect({required String ownerUserId});

  /// Re-reads trusted, non-sensitive metadata after the browser returns from
  /// OAuth. This never accepts or forwards callback query parameters.
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  });

  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  });

  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  });

  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  });

  /// Deletes all Gmail connection and derived review data for this account.
  /// Canonical schedule entities are intentionally outside this boundary.
  Future<void> deleteAccountData({required String ownerUserId});
}

/// Optional production capability for resolving an OAuth browser callback.
///
/// Test fakes need only [EmailReviewRemoteActions]. The production adapter
/// implements this stricter boundary so a duplicate provider-account callback
/// can be resolved only by its authenticated server receipt, never by choosing
/// an owner-global "latest" connection row.
abstract interface class CorrelatedEmailAuthorizationActions {
  Future<EmailConnectionState> checkCorrelatedAuthorization({
    required String ownerUserId,
    required String requestedConnectionId,
    required String callbackCorrelationId,
  });
}

/// Phase 5E supplies the implementation that performs the one atomic private
/// entity transaction. This UI boundary never creates schedule entities.
abstract interface class EmailCandidateConfirmationGateway {
  Future<EmailCandidateConfirmationResult> confirm({
    required String ownerUserId,
    required String candidateId,
    String? courseId,
  });
}

/// Stable identity returned by an explicit confirmation. [replayed] is true
/// when a retry found and verified the already-committed transaction.
class EmailCandidateConfirmationResult {
  const EmailCandidateConfirmationResult({
    required this.candidateId,
    required this.entityType,
    required this.entityId,
    required this.replayed,
  });

  final String candidateId;
  final EmailCandidateType entityType;
  final String entityId;
  final bool replayed;
}

class EmailReviewActionException implements Exception {
  const EmailReviewActionException(this.category);

  final EmailErrorCategory category;

  @override
  String toString() => 'EmailReviewActionException(${category.wireName})';
}
