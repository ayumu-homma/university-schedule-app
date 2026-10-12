enum EmailReconciliationAction {
  confirmation('confirmation'),
  dismissal('dismissal'),
  update('update');

  const EmailReconciliationAction(this.wireName);

  final String wireName;
}

enum EmailReconciliationResolution {
  accepted('accepted'),
  rejected('rejected');

  const EmailReconciliationResolution(this.wireName);

  final String wireName;
}

enum EmailReconciliationOutcome {
  confirmed('confirmed'),
  dismissed('dismissed'),
  accepted('accepted'),
  rejected('rejected');

  const EmailReconciliationOutcome(this.wireName);

  final String wireName;
}

class EmailReconciliationRequest {
  const EmailReconciliationRequest({
    required this.action,
    required this.connectionId,
    required this.provider,
    required this.providerAccountHash,
    required this.providerMessageIdHash,
    required this.providerThreadIdHash,
    required this.sanitizedContentHash,
    required this.idempotencyKey,
    this.reviewedPayload,
    this.resolution,
    this.entityType,
    this.entityId,
  });

  final EmailReconciliationAction action;
  final String connectionId;
  final String provider;
  final String providerAccountHash;
  final String providerMessageIdHash;
  final String providerThreadIdHash;
  final String sanitizedContentHash;
  final Map<String, Object?>? reviewedPayload;
  final EmailReconciliationResolution? resolution;
  final String? entityType;
  final String? entityId;
  final String idempotencyKey;
}

class EmailReconciliationResult {
  const EmailReconciliationResult({
    required this.connectionId,
    required this.idempotencyKey,
    required this.action,
    required this.outcome,
    required this.entityType,
    required this.entityId,
    required this.replayed,
  });

  final String connectionId;
  final String idempotencyKey;
  final EmailReconciliationAction action;
  final EmailReconciliationOutcome outcome;
  final String? entityType;
  final String? entityId;
  final bool replayed;
}

abstract interface class EmailReconciliationGateway {
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  );
}
