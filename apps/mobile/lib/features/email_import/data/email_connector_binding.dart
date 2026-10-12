import 'package:shared_domain/shared_domain.dart';

/// Marks a production connector as bound to one server-side email connection.
///
/// The trusted endpoint derives the owner from the JWT and verifies that this
/// opaque connection ID belongs to that owner. It never accepts an owner ID
/// from the mobile request body.
abstract interface class ConnectionBoundEmailConnector {
  String get connectionId;
}

enum TargetedEmailRetryOutcome { persisted, suppressed }

class TargetedEmailRetryResult {
  const TargetedEmailRetryResult.persisted(EmailFetchItem persistedItem)
      : outcome = TargetedEmailRetryOutcome.persisted,
        item = persistedItem,
        suppression = null;

  const TargetedEmailRetryResult.suppressed(
    EmailFetchSuppression suppressionAck,
  )   : outcome = TargetedEmailRetryOutcome.suppressed,
        item = null,
        suppression = suppressionAck;

  final TargetedEmailRetryOutcome outcome;
  final EmailFetchItem? item;
  final EmailFetchSuppression? suppression;
}

/// Optional production capability for reprocessing one previously fetched
/// provider message without moving the connection's incremental cursor.
abstract interface class TargetedEmailRetryConnector {
  Future<TargetedEmailRetryResult> retryCandidate({
    required String providerMessageId,
    required String expectedProviderMessageIdHash,
    required String expectedSanitizedContentHash,
    required String retryIdempotencyKey,
  });
}
