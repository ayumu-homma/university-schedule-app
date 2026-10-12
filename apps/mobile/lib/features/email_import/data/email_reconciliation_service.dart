import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../local_db/app_database.dart' as local;
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../domain/email_reconciliation.dart';
import 'email_import_failure.dart';

class EmailReconciliationRunResult {
  const EmailReconciliationRunResult({
    required this.examined,
    required this.reconciled,
    required this.waitingForScheduleSync,
    required this.failed,
  });

  const EmailReconciliationRunResult.empty()
      : this(
          examined: 0,
          reconciled: 0,
          waitingForScheduleSync: 0,
          failed: 0,
        );

  final int examined;
  final int reconciled;
  final int waitingForScheduleSync;
  final int failed;
}

/// Drains the durable review-decision outbox for one authenticated owner.
/// Confirmation and accepted-update receipts are released only after their
/// corresponding schedule mutation has a durable `synced` acknowledgement.
class EmailReconciliationService {
  EmailReconciliationService({
    required this.db,
    required this.gateway,
    required this.clock,
    required this.authenticatedUserId,
    this.lease,
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
  }) : _candidateCodec = candidateCodec;

  final local.AppDatabase db;
  final EmailReconciliationGateway gateway;
  final DateTime Function() clock;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final EmailCandidatePayloadCodec _candidateCodec;

  Future<EmailReconciliationRunResult> synchronize({
    required String ownerUserId,
    required bool networkAvailable,
  }) async {
    _requireOwner(ownerUserId);
    if (!networkAvailable) {
      return const EmailReconciliationRunResult.empty();
    }
    final now = clock().toUtc();
    final receipts = await (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.state.equals('pending'))
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
          ]))
        .get();
    var examined = 0;
    var reconciled = 0;
    var waitingForScheduleSync = 0;
    var failed = 0;
    for (var receipt in receipts) {
      if (!_isCurrent(ownerUserId)) break;
      if (receipt.nextRetryAt?.isAfter(now) == true) continue;
      examined++;
      try {
        await _validateConnection(ownerUserId, receipt);
        if (receipt.requiredSyncMutationId != null &&
            receipt.scheduleAckedAt == null) {
          final acknowledged = await _acknowledgeScheduleMutation(
            ownerUserId,
            receipt,
            now,
          );
          if (!acknowledged) {
            waitingForScheduleSync++;
            continue;
          }
          receipt = (await _ownedReceipt(ownerUserId, receipt.id))!;
        }
        _requireOwner(ownerUserId);
        final request = _request(receipt);
        final result = await gateway.reconcile(request);
        _requireOwner(ownerUserId);
        if (!_matches(request, result)) {
          throw const EmailImportFailure(
            connectionStatus: EmailConnectionStatus.failed,
            errorCategory: EmailErrorCategory.validationFailed,
          );
        }
        final changed = await (db.update(db.emailReconciliationReceipts)
              ..where((row) =>
                  row.id.equals(receipt.id) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.state.equals('pending')))
            .write(
          local.EmailReconciliationReceiptsCompanion(
            state: const Value('succeeded'),
            attemptCount: Value(receipt.attemptCount + 1),
            nextRetryAt: const Value(null),
            lastAttemptAt: Value(now),
            reconciledAt: Value(now),
            replayed: Value(result.replayed),
            errorCategory: const Value(null),
            updatedAt: Value(now),
          ),
        );
        if (changed != 1) {
          throw const EmailImportFailure(
            connectionStatus: EmailConnectionStatus.failed,
            errorCategory: EmailErrorCategory.internalError,
          );
        }
        reconciled++;
      } on Object catch (error) {
        // A revoked lease must leave the receipt untouched for a fresh
        // runtime. This check also closes the A->B->A case.
        if (!_isCurrent(ownerUserId)) break;
        failed++;
        await _recordFailure(ownerUserId, receipt, error, now);
      }
    }
    return EmailReconciliationRunResult(
      examined: examined,
      reconciled: reconciled,
      waitingForScheduleSync: waitingForScheduleSync,
      failed: failed,
    );
  }

  Future<void> _validateConnection(
    String ownerUserId,
    local.EmailReconciliationReceipt receipt,
  ) async {
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: receipt.connectionId,
    );
    if (connection == null ||
        connection.provider != receipt.provider ||
        connection.providerAccountHash != receipt.providerAccountHash) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
  }

  Future<bool> _acknowledgeScheduleMutation(
    String ownerUserId,
    local.EmailReconciliationReceipt receipt,
    DateTime now,
  ) async {
    final mutation = await (db.select(db.syncQueueEntries)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.clientMutationId.equals(receipt.requiredSyncMutationId!))
          ..limit(1))
        .getSingleOrNull();
    if (mutation == null ||
        mutation.status != 'synced' ||
        mutation.completionProvenance !=
            local.scheduleSyncCompletionRemoteApplied) {
      return false;
    }
    final expectedOperation = switch ((receipt.action, receipt.resolution)) {
      ('confirmation', null) => 'create',
      ('update', 'accepted') => 'update',
      _ => null,
    };
    if (expectedOperation == null ||
        mutation.syncedAt == null ||
        mutation.serverVersion == null ||
        mutation.idempotencyKey != receipt.idempotencyKey ||
        mutation.entityType != receipt.entityType ||
        mutation.entityId != receipt.entityId ||
        mutation.operation != expectedOperation) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.validationFailed,
      );
    }
    _requireOwner(ownerUserId);
    final changed = await (db.update(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals(receipt.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.state.equals('pending') &
              row.idempotencyKey.equals(receipt.idempotencyKey) &
              row.requiredSyncMutationId
                  .equals(receipt.requiredSyncMutationId!) &
              row.entityType.equals(receipt.entityType!) &
              row.entityId.equals(receipt.entityId!) &
              row.scheduleAckedAt.isNull()))
        .write(
      local.EmailReconciliationReceiptsCompanion(
        scheduleAckedAt: Value(mutation.syncedAt!.toUtc()),
        updatedAt: Value(now),
      ),
    );
    return changed == 1;
  }

  EmailReconciliationRequest _request(
    local.EmailReconciliationReceipt receipt,
  ) {
    final action = switch (receipt.action) {
      'confirmation' => EmailReconciliationAction.confirmation,
      'dismissal' => EmailReconciliationAction.dismissal,
      'update' => EmailReconciliationAction.update,
      _ => throw const EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: EmailErrorCategory.validationFailed,
        ),
    };
    Map<String, Object?>? payload;
    if (receipt.reviewedPayloadJson != null) {
      try {
        final decoded = jsonDecode(receipt.reviewedPayloadJson!);
        final candidate = _candidateCodec.decodeObject(decoded);
        final canonical = jsonDecode(_candidateCodec.encode(candidate));
        if (canonical is! Map) throw const FormatException();
        payload = canonical.map<String, Object?>(
          (key, value) => MapEntry(key.toString(), value),
        );
      } on Object {
        throw const EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: EmailErrorCategory.validationFailed,
        );
      }
    }
    final resolution = switch (receipt.resolution) {
      'accepted' => EmailReconciliationResolution.accepted,
      'rejected' => EmailReconciliationResolution.rejected,
      null => null,
      _ => throw const EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: EmailErrorCategory.validationFailed,
        ),
    };
    return EmailReconciliationRequest(
      action: action,
      connectionId: receipt.connectionId,
      provider: receipt.provider,
      providerAccountHash: receipt.providerAccountHash,
      providerMessageIdHash: receipt.providerMessageIdHash,
      providerThreadIdHash: receipt.providerThreadIdHash,
      sanitizedContentHash: receipt.sanitizedContentHash,
      reviewedPayload: payload,
      resolution: resolution,
      entityType: receipt.entityType,
      entityId: receipt.entityId,
      idempotencyKey: receipt.idempotencyKey,
    );
  }

  bool _matches(
    EmailReconciliationRequest request,
    EmailReconciliationResult result,
  ) {
    final expectedOutcome = switch (request.action) {
      EmailReconciliationAction.confirmation =>
        EmailReconciliationOutcome.confirmed,
      EmailReconciliationAction.dismissal =>
        EmailReconciliationOutcome.dismissed,
      EmailReconciliationAction.update =>
        request.resolution == EmailReconciliationResolution.accepted
            ? EmailReconciliationOutcome.accepted
            : EmailReconciliationOutcome.rejected,
    };
    return result.connectionId == request.connectionId &&
        result.idempotencyKey == request.idempotencyKey &&
        result.action == request.action &&
        result.outcome == expectedOutcome &&
        result.entityType == request.entityType &&
        result.entityId == request.entityId;
  }

  Future<local.EmailReconciliationReceipt?> _ownedReceipt(
    String ownerUserId,
    String receiptId,
  ) {
    return (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals(receiptId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<void> _recordFailure(
    String ownerUserId,
    local.EmailReconciliationReceipt receipt,
    Object error,
    DateTime now,
  ) async {
    final category = _safeCategory(error);
    final attempt = receipt.attemptCount + 1;
    final retryAfter = error is EmailImportFailure && error.retryAfter != null
        ? error.retryAfter!
        : Duration(seconds: math.min(3600, 1 << math.min(attempt, 10)));
    await (db.update(db.emailReconciliationReceipts)
          ..where((row) =>
              row.id.equals(receipt.id) &
              row.ownerUserId.equals(ownerUserId) &
              row.state.equals('pending')))
        .write(
      local.EmailReconciliationReceiptsCompanion(
        attemptCount: Value(attempt),
        nextRetryAt: Value(now.add(retryAfter)),
        lastAttemptAt: Value(now),
        errorCategory: Value(category.wireName),
        updatedAt: Value(now),
      ),
    );
  }

  EmailErrorCategory _safeCategory(Object error) {
    if (error is EmailImportFailure) {
      if (error.errorCategory != null) return error.errorCategory!;
      return switch (error.connectionStatus) {
        EmailConnectionStatus.reauthRequired =>
          EmailErrorCategory.authorizationRevoked,
        EmailConnectionStatus.rateLimited => EmailErrorCategory.rateLimited,
        _ => EmailErrorCategory.providerUnavailable,
      };
    }
    return EmailErrorCategory.internalError;
  }

  void _requireOwner(String ownerUserId) {
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
    } on ScopedContextLeaseException {
      throw EmailImportFailure.authorizationRevoked();
    }
    if (ownerUserId.trim().isEmpty || authenticatedUserId() != ownerUserId) {
      throw EmailImportFailure.authorizationRevoked();
    }
  }

  bool _isCurrent(String ownerUserId) {
    try {
      _requireOwner(ownerUserId);
      return true;
    } on EmailImportFailure {
      return false;
    }
  }
}
