import 'dart:convert';

import 'package:drift/drift.dart';

import '../../local_db/app_database.dart' as local;
import 'sync_queue.dart';

class DriftSyncQueue implements SyncQueue {
  DriftSyncQueue(
    this.db, {
    required this.ownerUserId,
  }) {
    if (ownerUserId.trim().isEmpty ||
        ownerUserId != ownerUserId.trim() ||
        ownerUserId == local.legacyQuarantinedOwnerId) {
      throw ArgumentError.value(
        ownerUserId,
        'ownerUserId',
        'A real, normalized owner is required for the sync queue.',
      );
    }
  }

  final local.AppDatabase db;

  @override
  final String ownerUserId;

  /// Global maintenance is safe only because the DAO predicates on already
  /// redacted terminal/quarantined rows. No owner payload is read here.
  static Future<int> cleanupAcknowledgedGlobally(
    local.AppDatabase db, {
    required DateTime now,
    Duration retention = SyncQueue.acknowledgedRetention,
  }) {
    return db.syncQueueDao.deleteAcknowledgedBefore(now.subtract(retention));
  }

  @override
  Future<void> enqueue(PendingMutation mutation) {
    if (mutation.ownerUserId != ownerUserId) {
      throw ArgumentError.value(
        mutation.ownerUserId,
        'mutation.ownerUserId',
        'Mutation owner does not match this queue.',
      );
    }
    return db.syncQueueDao.enqueue(
      local.SyncQueueEntriesCompanion.insert(
        clientMutationId: mutation.clientMutationId,
        ownerUserId: mutation.ownerUserId,
        idempotencyKey: Value(mutation.idempotencyKey),
        entityType: mutation.entityType,
        entityId: mutation.entityId,
        operation: mutation.operation.name,
        payloadJson: jsonEncode(_jsonValue(mutation.payload)),
        baseVersion: Value(mutation.baseVersion),
        serverVersion: Value(mutation.serverVersion),
        serverPayloadJson: mutation.serverPayload.isEmpty
            ? const Value(null)
            : Value(jsonEncode(_jsonValue(mutation.serverPayload))),
        conflictCursor: Value(mutation.conflictCursor),
        createdAt: Value(mutation.createdAt),
        status: Value(mutation.status.name),
        attemptCount: Value(mutation.attemptCount),
        nextRetryAt: Value(mutation.nextRetryAt),
        lastAttemptAt: Value(mutation.lastAttemptAt),
        claimedAt: Value(mutation.claimedAt),
        syncedAt: Value(mutation.syncedAt),
        completionProvenance: const Value(null),
        errorMessage: Value(sanitizeSyncErrorMessage(mutation.errorMessage)),
      ),
    );
  }

  @override
  Future<List<PendingMutation>> pending() async {
    final rows = await db.syncQueueDao.pendingMutations(ownerUserId);
    return rows.map(_mutationFromRow).toList();
  }

  @override
  Future<List<PendingMutation>> all() async {
    final rows = await db.syncQueueDao.allMutations(ownerUserId);
    return rows.map(_mutationFromRow).toList();
  }

  @override
  Future<SyncQueueCounts> counts() async {
    final rows = await db.syncQueueDao.allMutations(ownerUserId);
    var pending = 0;
    var processing = 0;
    var failed = 0;
    var conflict = 0;
    var synced = 0;
    var quarantined = 0;
    for (final row in rows) {
      switch (_syncStatusFromWire(row.status)) {
        case SyncMutationStatus.pending:
          pending++;
        case SyncMutationStatus.processing:
          processing++;
        case SyncMutationStatus.failed:
          failed++;
        case SyncMutationStatus.conflict:
          conflict++;
        case SyncMutationStatus.synced:
          synced++;
        case SyncMutationStatus.quarantined:
          quarantined++;
      }
    }
    return SyncQueueCounts(
      pending: pending,
      processing: processing,
      failed: failed,
      conflict: conflict,
      synced: synced,
      quarantined: quarantined,
    );
  }

  @override
  Future<PendingMutation?> claimNext({required DateTime now}) async {
    final row = await db.syncQueueDao.claimNext(ownerUserId, now);
    return row == null ? null : _mutationFromRow(row);
  }

  @override
  Future<DateTime?> blockedUntil() {
    return db.syncQueueDao.blockedUntil(ownerUserId);
  }

  @override
  Future<int> recoverAbandoned({
    required DateTime now,
    Duration leaseTimeout = SyncQueue.defaultLeaseTimeout,
  }) {
    return db.syncQueueDao.recoverAbandoned(
      ownerUserId,
      now.subtract(leaseTimeout),
    );
  }

  @override
  Future<int> recoverAllProcessing() {
    return db.syncQueueDao.recoverAllProcessing(ownerUserId);
  }

  @override
  Future<bool> markSynced(
    String clientMutationId, {
    required DateTime acknowledgedAt,
    required int attemptCount,
    int? serverVersion,
  }) {
    return db.syncQueueDao.markSynced(
      ownerUserId,
      clientMutationId,
      acknowledgedAt,
      attemptCount: attemptCount,
      serverVersion: serverVersion,
    );
  }

  @override
  Future<bool> markFailed(
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    DateTime? nextRetryAt,
  }) {
    return db.syncQueueDao.markFailed(
      ownerUserId,
      clientMutationId,
      sanitizeSyncErrorMessage(errorMessage) ?? 'Sync failed.',
      attemptCount: attemptCount,
      nextRetryAt: nextRetryAt,
    );
  }

  @override
  Future<bool> markConflict(
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    int? serverVersion,
    Map<String, Object?> serverPayload = const {},
    int? conflictCursor,
  }) {
    return db.syncQueueDao.markConflict(
      ownerUserId,
      clientMutationId,
      sanitizeSyncErrorMessage(errorMessage) ?? 'Sync conflict.',
      attemptCount: attemptCount,
      serverVersion: serverVersion,
      serverPayloadJson:
          serverPayload.isEmpty ? null : jsonEncode(_jsonValue(serverPayload)),
      conflictCursor: conflictCursor,
    );
  }

  @override
  Future<int> cleanupAcknowledged({
    required DateTime now,
    Duration retention = SyncQueue.acknowledgedRetention,
  }) {
    return cleanupAcknowledgedGlobally(
      db,
      now: now,
      retention: retention,
    );
  }

  PendingMutation _mutationFromRow(local.SyncQueueEntry row) {
    return PendingMutation(
      clientMutationId: row.clientMutationId,
      ownerUserId: row.ownerUserId,
      idempotencyKey: row.idempotencyKey,
      entityType: row.entityType,
      entityId: row.entityId,
      operation: _syncOperationFromWire(row.operation),
      payload: _decodeJsonObject(row.payloadJson),
      baseVersion: row.baseVersion,
      serverVersion: row.serverVersion,
      serverPayload: row.serverPayloadJson == null
          ? const {}
          : _decodeJsonObject(row.serverPayloadJson!),
      conflictCursor: row.conflictCursor,
      createdAt: row.createdAt,
      status: _syncStatusFromWire(row.status),
      attemptCount: row.attemptCount,
      nextRetryAt: row.nextRetryAt,
      lastAttemptAt: row.lastAttemptAt,
      claimedAt: row.claimedAt,
      syncedAt: row.syncedAt,
      errorMessage: row.errorMessage,
    );
  }

  SyncOperation _syncOperationFromWire(String value) {
    return SyncOperation.values.firstWhere(
      (operation) => operation.name == value,
      orElse: () => SyncOperation.update,
    );
  }

  SyncMutationStatus _syncStatusFromWire(String value) {
    return SyncMutationStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => SyncMutationStatus.pending,
    );
  }

  Map<String, Object?> _decodeJsonObject(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  Object? _jsonValue(Object? value) {
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      return value
          .map((key, item) => MapEntry(key.toString(), _jsonValue(item)));
    }
    if (value is Iterable) {
      return value.map(_jsonValue).toList();
    }
    return value;
  }
}
