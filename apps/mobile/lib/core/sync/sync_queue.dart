enum SyncOperation { create, update, submit, delete }

enum SyncMutationStatus {
  pending,
  processing,
  failed,
  conflict,
  synced,
  quarantined,
}

String? sanitizeSyncErrorMessage(String? rawMessage) {
  if (rawMessage == null) return null;
  var message = rawMessage;
  message = message.replaceAll(
    RegExp(
      r'\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b',
      caseSensitive: false,
    ),
    '[redacted-email]',
  );
  message = message.replaceAll(
    RegExp(
      r'\b(?:api[_-]?key|token|authorization|secret)\s*[:=]\s*\S+',
      caseSensitive: false,
    ),
    '[redacted-credential]',
  );
  message = message.replaceAll(
    RegExp(r'\bBearer\s+\S+', caseSensitive: false),
    'Bearer [redacted]',
  );
  message = message.replaceAll(
    RegExp(r'https?://\S+', caseSensitive: false),
    '[redacted-url]',
  );
  message = message.replaceAll(
    RegExp(r'\b[A-Za-z0-9_-]{24,}\b'),
    '[redacted-value]',
  );
  message = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (message.isEmpty) return null;
  if (message.length <= 240) return message;
  return '${message.substring(0, 237)}...';
}

class SyncQueueCounts {
  const SyncQueueCounts({
    required this.pending,
    required this.synced,
    required this.failed,
    this.processing = 0,
    this.conflict = 0,
    this.quarantined = 0,
  });

  final int pending;
  final int processing;
  final int failed;
  final int conflict;
  final int synced;
  final int quarantined;

  int get total =>
      pending + processing + failed + conflict + synced + quarantined;

  int get actionable => pending + failed + conflict;
}

class PendingMutation {
  const PendingMutation({
    required this.clientMutationId,
    required this.ownerUserId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.createdAt,
    String? idempotencyKey,
    this.baseVersion,
    this.serverVersion,
    this.serverPayload = const {},
    this.conflictCursor,
    this.status = SyncMutationStatus.pending,
    this.attemptCount = 0,
    this.nextRetryAt,
    this.lastAttemptAt,
    this.claimedAt,
    this.syncedAt,
    this.errorMessage,
  }) : idempotencyKey = idempotencyKey ?? clientMutationId;

  final String clientMutationId;
  final String ownerUserId;
  final String idempotencyKey;
  final String entityType;
  final String entityId;
  final SyncOperation operation;
  final Map<String, Object?> payload;
  final int? baseVersion;
  final int? serverVersion;
  final Map<String, Object?> serverPayload;
  final int? conflictCursor;
  final DateTime createdAt;
  final SyncMutationStatus status;
  final int attemptCount;
  final DateTime? nextRetryAt;
  final DateTime? lastAttemptAt;
  final DateTime? claimedAt;
  final DateTime? syncedAt;
  final String? errorMessage;
}

abstract interface class SyncQueue {
  static const defaultLeaseTimeout = Duration(minutes: 5);
  static const acknowledgedRetention = Duration(days: 30);

  String get ownerUserId;

  Future<void> enqueue(PendingMutation mutation);

  Future<List<PendingMutation>> pending();

  Future<List<PendingMutation>> all();

  Future<SyncQueueCounts> counts();

  Future<PendingMutation?> claimNext({required DateTime now});

  /// Returns the retry time of the strict queue head when that failed head is
  /// not due yet. Later rows must not overtake it.
  Future<DateTime?> blockedUntil();

  Future<int> recoverAbandoned({
    required DateTime now,
    Duration leaseTimeout = defaultLeaseTimeout,
  });

  Future<int> recoverAllProcessing();

  Future<bool> markSynced(
    String clientMutationId, {
    required DateTime acknowledgedAt,
    required int attemptCount,
    int? serverVersion,
  });

  Future<bool> markFailed(
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    DateTime? nextRetryAt,
  });

  Future<bool> markConflict(
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    int? serverVersion,
    Map<String, Object?> serverPayload = const {},
    int? conflictCursor,
  });

  Future<int> cleanupAcknowledged({
    required DateTime now,
    Duration retention = acknowledgedRetention,
  });
}
