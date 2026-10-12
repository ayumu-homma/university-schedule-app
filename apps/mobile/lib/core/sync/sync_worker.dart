import 'drift_schedule_sync_store.dart';
import 'remote_schedule_gateway.dart';
import 'sync_queue.dart';

class SyncWorkerRunResult {
  const SyncWorkerRunResult({
    required this.processed,
    required this.synced,
    required this.failed,
    this.conflicts = 0,
    this.recovered = 0,
    this.contextCancelled = false,
    this.nextRetryAt,
  });

  final int processed;
  final int synced;
  final int failed;
  final int conflicts;
  final int recovered;
  final bool contextCancelled;
  final DateTime? nextRetryAt;

  bool get stoppedBeforeDrain =>
      contextCancelled || failed > 0 || conflicts > 0;
}

class SyncRetryPolicy {
  const SyncRetryPolicy({
    this.baseDelay = const Duration(seconds: 5),
    this.maximumDelay = const Duration(minutes: 15),
  });

  final Duration baseDelay;
  final Duration maximumDelay;

  Duration delayForAttempt(int attemptCount) {
    final exponent = (attemptCount - 1).clamp(0, 20);
    final delay = baseDelay * (1 << exponent);
    return delay > maximumDelay ? maximumDelay : delay;
  }
}

typedef AfterRemoteMutationAck = Future<void> Function(
  PendingMutation mutation,
  ScheduleMutationAck acknowledgement,
);

class SyncWorker {
  SyncWorker({
    required SyncQueue queue,
    required SyncMutationDispatcher dispatcher,
    DriftScheduleSyncStore? store,
    DateTime Function()? clock,
    SyncRetryPolicy retryPolicy = const SyncRetryPolicy(),
    Duration leaseTimeout = SyncQueue.defaultLeaseTimeout,
    AfterRemoteMutationAck? afterRemoteAck,
    bool Function()? isContextCurrent,
  })  : _queue = queue,
        _dispatcher = dispatcher,
        _store = store,
        _clock = clock ?? DateTime.now,
        _retryPolicy = retryPolicy,
        _leaseTimeout = leaseTimeout,
        _afterRemoteAck = afterRemoteAck,
        _isContextCurrent = isContextCurrent ?? (() => true);

  final SyncQueue _queue;
  final SyncMutationDispatcher _dispatcher;
  final DriftScheduleSyncStore? _store;
  final DateTime Function() _clock;
  final SyncRetryPolicy _retryPolicy;
  final Duration _leaseTimeout;
  final AfterRemoteMutationAck? _afterRemoteAck;
  final bool Function() _isContextCurrent;

  Future<int> recoverAfterRestart() async {
    if (!_contextIsCurrent()) return 0;
    final recovered = await _queue.recoverAllProcessing();
    return _contextIsCurrent() ? recovered : 0;
  }

  Future<SyncWorkerRunResult> processPending() async {
    // A disposed worker must not even recover leases from its former scope.
    // This entry check closes the gap before the first queue mutation.
    if (!_contextIsCurrent()) {
      return const SyncWorkerRunResult(
        processed: 0,
        synced: 0,
        failed: 0,
        conflicts: 0,
        recovered: 0,
        contextCancelled: true,
      );
    }
    final recovered = await _queue.recoverAbandoned(
      now: _clock(),
      leaseTimeout: _leaseTimeout,
    );
    var processed = 0;
    var synced = 0;
    var failed = 0;
    var conflicts = 0;
    DateTime? nextRetryAt;

    SyncWorkerRunResult stopForContextChange() => SyncWorkerRunResult(
          processed: processed,
          synced: synced,
          failed: failed,
          conflicts: conflicts,
          recovered: recovered,
          contextCancelled: true,
          nextRetryAt: nextRetryAt,
        );

    if (!_contextIsCurrent()) return stopForContextChange();

    while (true) {
      if (!_contextIsCurrent()) return stopForContextChange();
      final mutation = await _queue.claimNext(now: _clock());
      if (!_contextIsCurrent()) return stopForContextChange();
      if (mutation == null) {
        nextRetryAt ??= await _queue.blockedUntil();
        if (!_contextIsCurrent()) return stopForContextChange();
        break;
      }
      processed++;

      final ScheduleMutationAck acknowledgement;
      try {
        if (!_contextIsCurrent()) return stopForContextChange();
        acknowledgement = await _dispatcher.dispatch(mutation);
        // Keep a processing lease when the owner or active database changes;
        // the next active context can recover and replay it safely.
        if (!_contextIsCurrent()) return stopForContextChange();
      } on RemoteScheduleConflictException catch (error) {
        if (!_contextIsCurrent()) return stopForContextChange();
        final applied = await _queue.markConflict(
          mutation.clientMutationId,
          _safeErrorMessage(error),
          attemptCount: mutation.attemptCount,
          serverVersion: error.serverVersion,
          conflictCursor: error.changeCursor,
        );
        if (!_contextIsCurrent()) return stopForContextChange();
        if (applied) conflicts++;
        break;
      } catch (error) {
        if (!_contextIsCurrent()) return stopForContextChange();
        nextRetryAt = _clock().add(
          _retryPolicy.delayForAttempt(mutation.attemptCount),
        );
        final applied = await _queue.markFailed(
          mutation.clientMutationId,
          _safeErrorMessage(error),
          attemptCount: mutation.attemptCount,
          nextRetryAt: nextRetryAt,
        );
        if (!_contextIsCurrent()) return stopForContextChange();
        if (applied) failed++;
        // Never overtake a transiently failed mutation. Later mutations may
        // depend on the server state produced by this one.
        break;
      }

      // Deliberately outside the transport catch. Tests use this seam to model
      // a process death after the server committed but before the local ack;
      // the processing lease must remain recoverable on restart.
      if (!_contextIsCurrent()) return stopForContextChange();
      await _afterRemoteAck?.call(mutation, acknowledgement);
      if (!_contextIsCurrent()) return stopForContextChange();

      final store = _store;
      if (store != null) {
        if (!_contextIsCurrent()) return stopForContextChange();
        await store.acknowledge(
          mutation,
          acknowledgement,
          acknowledgedAt: _clock(),
        );
        if (!_contextIsCurrent()) return stopForContextChange();
      } else if (acknowledgement.isConflict) {
        if (!_contextIsCurrent()) return stopForContextChange();
        final applied = await _queue.markConflict(
          mutation.clientMutationId,
          'Remote version changed.',
          attemptCount: mutation.attemptCount,
          serverVersion: acknowledgement.serverVersion,
          serverPayload: acknowledgement.change.payload,
          conflictCursor: acknowledgement.changeCursor,
        );
        if (!_contextIsCurrent()) return stopForContextChange();
        if (!applied) {
          throw StateError('The claimed mutation is no longer current.');
        }
      } else {
        if (!_contextIsCurrent()) return stopForContextChange();
        final applied = await _queue.markSynced(
          mutation.clientMutationId,
          acknowledgedAt: _clock(),
          attemptCount: mutation.attemptCount,
          serverVersion: acknowledgement.serverVersion,
        );
        if (!_contextIsCurrent()) return stopForContextChange();
        if (!applied) {
          throw StateError('The claimed mutation is no longer current.');
        }
      }

      if (acknowledgement.isConflict) {
        conflicts++;
        break;
      }
      synced++;
    }

    return SyncWorkerRunResult(
      processed: processed,
      synced: synced,
      failed: failed,
      conflicts: conflicts,
      recovered: recovered,
      nextRetryAt: nextRetryAt,
    );
  }

  String _safeErrorMessage(Object error) {
    final message = switch (error) {
      RemoteScheduleException() => error.message,
      _ => error.runtimeType.toString(),
    };
    return sanitizeSyncErrorMessage(message) ?? 'Sync failed.';
  }

  bool _contextIsCurrent() {
    try {
      return _isContextCurrent();
    } on Object {
      return false;
    }
  }
}

class SyncMutationDispatcher {
  SyncMutationDispatcher(this.gateway);

  final RemoteScheduleGateway gateway;

  Future<ScheduleMutationAck> dispatch(PendingMutation mutation) {
    return gateway.applyMutation(mutation);
  }
}
