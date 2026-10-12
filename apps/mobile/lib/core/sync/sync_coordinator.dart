import 'drift_schedule_sync_store.dart';
import 'remote_schedule_gateway.dart';
import 'sync_worker.dart';

enum SyncTrigger {
  startup,
  appResume,
  connectivity,
  realtime,
  localMutation,
  manual,
  retryTimer,
}

class SyncCoordinatorRunResult {
  const SyncCoordinatorRunResult({
    required this.push,
    required this.pulledPages,
    required this.pulledChanges,
    required this.cursor,
    this.blockedByLocalMutation = false,
  });

  final SyncWorkerRunResult push;
  final int pulledPages;
  final int pulledChanges;
  final int cursor;
  final bool blockedByLocalMutation;
}

class SyncCoordinator {
  SyncCoordinator({
    required this.ownerUserId,
    required SyncWorker worker,
    required RemoteScheduleGateway gateway,
    required DriftScheduleSyncStore store,
    bool Function()? isOwnerActive,
    bool Function()? isContextCurrent,
    this.pageSize = 200,
  })  : _worker = worker,
        _gateway = gateway,
        _store = store,
        _isOwnerActive = isOwnerActive ?? (() => true),
        _isContextCurrent = isContextCurrent ?? isOwnerActive ?? (() => true) {
    if (ownerUserId.trim().isEmpty || ownerUserId != ownerUserId.trim()) {
      throw ArgumentError.value(
        ownerUserId,
        'ownerUserId',
        'A normalized owner is required.',
      );
    }
    if (store.ownerUserId != ownerUserId) {
      throw ArgumentError.value(
        store.ownerUserId,
        'store.ownerUserId',
        'The sync store owner must match the coordinator.',
      );
    }
    if (pageSize < 1 || pageSize > 500) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be 1..500.');
    }
  }

  final String ownerUserId;
  final int pageSize;
  final SyncWorker _worker;
  final RemoteScheduleGateway _gateway;
  final DriftScheduleSyncStore _store;
  final bool Function() _isOwnerActive;
  final bool Function() _isContextCurrent;

  Future<void>? _startupRecovery;
  Future<SyncCoordinatorRunResult>? _inFlight;
  bool _rerunRequested = false;
  bool _disposed = false;

  bool get isRunning => _inFlight != null;

  Future<SyncCoordinatorRunResult> start() async {
    _ensureUsable();
    _startupRecovery ??= _worker.recoverAfterRestart();
    await _startupRecovery;
    return synchronize(SyncTrigger.startup);
  }

  Future<SyncCoordinatorRunResult> synchronize([
    SyncTrigger trigger = SyncTrigger.manual,
  ]) {
    _ensureUsable();
    _assertOwnerActive();
    _rerunRequested = true;
    final existing = _inFlight;
    if (existing != null) return existing;
    final operation = _drain();
    _inFlight = operation;
    operation.then<void>(
      (_) {
        if (identical(_inFlight, operation)) _inFlight = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_inFlight, operation)) _inFlight = null;
      },
    );
    return operation;
  }

  void dispose() {
    _disposed = true;
    _rerunRequested = false;
  }

  Future<SyncCoordinatorRunResult> _drain() async {
    SyncCoordinatorRunResult? latest;
    do {
      _rerunRequested = false;
      latest = await _runOnce();
    } while (_rerunRequested && !_disposed && _contextIsCurrent());
    return latest;
  }

  Future<SyncCoordinatorRunResult> _runOnce() async {
    _assertOwnerActive();
    final push = await _worker.processPending();
    if (push.contextCancelled || !_contextIsCurrent()) {
      return SyncCoordinatorRunResult(
        push: push,
        pulledPages: 0,
        pulledChanges: 0,
        cursor: 0,
      );
    }
    _assertOwnerActive();
    var currentCursor = await _store.cursor();
    if (!_contextIsCurrent() || push.stoppedBeforeDrain) {
      return SyncCoordinatorRunResult(
        push: push,
        pulledPages: 0,
        pulledChanges: 0,
        cursor: currentCursor,
      );
    }

    var pulledPages = 0;
    var pulledChanges = 0;
    while (true) {
      final page = await _gateway.pullDelta(
        ownerUserId: ownerUserId,
        afterCursor: currentCursor,
        limit: pageSize,
      );
      if (!_contextIsCurrent()) {
        _assertOwnerActive();
      }
      try {
        await _store.applyDeltaPage(page);
        if (!_contextIsCurrent()) {
          _assertOwnerActive();
        }
      } on PendingLocalMutationException {
        return SyncCoordinatorRunResult(
          push: push,
          pulledPages: pulledPages,
          pulledChanges: pulledChanges,
          cursor: currentCursor,
          blockedByLocalMutation: true,
        );
      }
      pulledPages++;
      pulledChanges += page.changes.length;
      currentCursor = page.nextCursor;
      if (!page.hasMore) break;
    }
    return SyncCoordinatorRunResult(
      push: push,
      pulledPages: pulledPages,
      pulledChanges: pulledChanges,
      cursor: currentCursor,
    );
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('SyncCoordinator is disposed.');
  }

  void _assertOwnerActive() {
    if (!_contextIsCurrent() || !_isOwnerActive()) {
      throw const RemoteScheduleAuthenticationException(
        'The authenticated schedule owner changed during sync.',
      );
    }
  }

  bool _contextIsCurrent() {
    if (_disposed) return false;
    try {
      return _isContextCurrent();
    } on Object {
      return false;
    }
  }
}
