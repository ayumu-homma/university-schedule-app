import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../local_db/app_database.dart' as local;
import '../../../local_db/app_database_provider.dart';
import '../../auth/application/auth_providers.dart';
import 'document_import_controller.dart';
import '../data/drift_document_import_repository.dart';

final documentImportNetworkAvailableProvider =
    StreamProvider.autoDispose<bool>((ref) {
  final connectivity = Connectivity();
  late final StreamController<bool> controller;
  StreamSubscription<List<ConnectivityResult>>? subscription;
  controller = StreamController<bool>(
    onListen: () async {
      final initial = await connectivity.checkConnectivity();
      if (!controller.isClosed) controller.add(_hasNetwork(initial));
      subscription = connectivity.onConnectivityChanged.listen(
        (results) {
          if (!controller.isClosed) controller.add(_hasNetwork(results));
        },
        onError: (_) {
          if (!controller.isClosed) controller.add(false);
        },
      );
    },
    onCancel: () async {
      await subscription?.cancel();
      await controller.close();
    },
  );
  return controller.stream.distinct();
});

bool _hasNetwork(List<ConnectivityResult> results) {
  return results.any((result) => result != ConnectivityResult.none);
}

final documentImportPendingReviewReconcilerProvider =
    Provider<DocumentImportPendingReviewReconciler>((ref) {
  return ref.watch(documentImportRepositoryProvider);
});

final documentImportPendingReviewCountProvider =
    StreamProvider.autoDispose.family<int, String>((ref, ownerUserId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.documentCandidatesCache)
        ..where(
          (row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.remoteCandidateId.isNotNull() &
              row.remoteSyncState.isNotValue('synced'),
        ))
      .watch()
      .map((rows) => rows.length)
      .distinct();
});

enum DocumentImportReconciliationTrigger {
  startup,
  pendingReview,
  connectivity,
  appResume,
}

enum DocumentImportReconciliationPhase {
  disabled,
  offline,
  idle,
  running,
  synchronized,
  waitingToRetry,
  error,
}

class DocumentImportReconciliationState {
  const DocumentImportReconciliationState({
    required this.phase,
    this.ownerUserId,
    this.lastTrigger,
  });

  const DocumentImportReconciliationState.disabled()
      : this(phase: DocumentImportReconciliationPhase.disabled);

  final DocumentImportReconciliationPhase phase;
  final String? ownerUserId;
  final DocumentImportReconciliationTrigger? lastTrigger;
}

final documentImportReconciliationRuntimeProvider = AutoDisposeNotifierProvider<
    DocumentImportReconciliationRuntimeController,
    DocumentImportReconciliationState>(
  DocumentImportReconciliationRuntimeController.new,
);

/// Drains durable review actions without depending on the document screen.
/// Feature, auth, owner, connectivity, and lifecycle changes all invalidate a
/// generation so a late completion can never update another owner's runtime.
class DocumentImportReconciliationRuntimeController
    extends AutoDisposeNotifier<DocumentImportReconciliationState> {
  DocumentImportPendingReviewReconciler? _reconciler;
  local.AppDatabase? _db;
  String? _ownerUserId;
  bool _networkAvailable = false;
  bool _disposed = false;
  bool _disposeRegistered = false;
  int _generation = 0;
  Future<void>? _inFlight;
  bool _rerunRequested = false;

  @override
  DocumentImportReconciliationState build() {
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        _disposed = true;
        _generation++;
        _reconciler = null;
        _db = null;
        _ownerUserId = null;
        _networkAvailable = false;
        _inFlight = null;
        _rerunRequested = false;
      });
    }
    _disposed = false;
    final generation = ++_generation;
    _reconciler = null;
    _db = null;
    _ownerUserId = null;
    _networkAvailable = false;
    _inFlight = null;
    _rerunRequested = false;

    final config = ref.watch(appConfigProvider);
    if (config.demoMode || !config.documentImportEnabled) {
      return const DocumentImportReconciliationState.disabled();
    }

    final session = ref.watch(currentAuthSessionProvider);
    final ownerUserId = ref.watch(documentImportOwnerIdProvider);
    if (session == null ||
        ownerUserId == null ||
        ownerUserId != session.userId) {
      return const DocumentImportReconciliationState.disabled();
    }
    _ownerUserId = ownerUserId;

    final network =
        ref.watch(documentImportNetworkAvailableProvider).valueOrNull == true;
    _networkAvailable = network;
    if (!network) {
      return DocumentImportReconciliationState(
        phase: DocumentImportReconciliationPhase.offline,
        ownerUserId: ownerUserId,
      );
    }

    _db = ref.watch(appDatabaseProvider);
    _reconciler = ref.watch(documentImportPendingReviewReconcilerProvider);
    ref.listen<AsyncValue<int>>(
      documentImportPendingReviewCountProvider(ownerUserId),
      (previous, next) {
        if (!_isCurrent(ownerUserId, generation)) return;
        final previousCount = previous?.valueOrNull ?? 0;
        final nextCount = next.valueOrNull ?? 0;
        if (nextCount > 0 && nextCount > previousCount) {
          unawaited(trigger(DocumentImportReconciliationTrigger.pendingReview));
        }
      },
      fireImmediately: true,
    );
    Future<void>.microtask(() async {
      if (_isCurrent(ownerUserId, generation)) {
        await trigger(DocumentImportReconciliationTrigger.startup);
      }
    });
    return DocumentImportReconciliationState(
      phase: DocumentImportReconciliationPhase.idle,
      ownerUserId: ownerUserId,
    );
  }

  Future<void> trigger(DocumentImportReconciliationTrigger trigger) {
    final reconciler = _reconciler;
    final ownerUserId = _ownerUserId;
    if (_disposed ||
        reconciler == null ||
        ownerUserId == null ||
        !_networkAvailable) {
      return Future.value();
    }
    final existing = _inFlight;
    if (existing != null) {
      _rerunRequested = true;
      return existing;
    }
    final generation = _generation;
    final operation = _drain(
      reconciler: reconciler,
      ownerUserId: ownerUserId,
      generation: generation,
      initialTrigger: trigger,
    );
    _inFlight = operation;
    return operation;
  }

  Future<void> _drain({
    required DocumentImportPendingReviewReconciler reconciler,
    required String ownerUserId,
    required int generation,
    required DocumentImportReconciliationTrigger initialTrigger,
  }) async {
    var currentTrigger = initialTrigger;
    try {
      do {
        _rerunRequested = false;
        if (!_isCurrent(ownerUserId, generation)) return;
        state = DocumentImportReconciliationState(
          phase: DocumentImportReconciliationPhase.running,
          ownerUserId: ownerUserId,
          lastTrigger: currentTrigger,
        );
        try {
          await reconciler.reconcilePending(ownerUserId);
          if (!_isCurrent(ownerUserId, generation)) return;
          final pendingCount = await _pendingCount(ownerUserId);
          if (!_isCurrent(ownerUserId, generation)) return;
          state = DocumentImportReconciliationState(
            phase: pendingCount == 0
                ? DocumentImportReconciliationPhase.synchronized
                : DocumentImportReconciliationPhase.waitingToRetry,
            ownerUserId: ownerUserId,
            lastTrigger: currentTrigger,
          );
        } on Object {
          if (!_isCurrent(ownerUserId, generation)) return;
          state = DocumentImportReconciliationState(
            phase: DocumentImportReconciliationPhase.error,
            ownerUserId: ownerUserId,
            lastTrigger: currentTrigger,
          );
        }
        currentTrigger = DocumentImportReconciliationTrigger.pendingReview;
      } while (_rerunRequested && _isCurrent(ownerUserId, generation));
    } finally {
      // Clear before this Future completes. Since there is no asynchronous gap
      // between the final rerun check and this assignment, a lifecycle or
      // connectivity wake either joins this drain or starts a fresh one.
      if (_isCurrent(ownerUserId, generation)) {
        _inFlight = null;
      }
    }
  }

  bool _isCurrent(String ownerUserId, int generation) {
    return !_disposed &&
        generation == _generation &&
        _ownerUserId == ownerUserId &&
        _networkAvailable;
  }

  Future<int> _pendingCount(String ownerUserId) async {
    final db = _db;
    if (db == null) return 0;
    final pending = await (db.select(db.documentCandidatesCache)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.remoteCandidateId.isNotNull() &
                row.remoteSyncState.isNotValue('synced'),
          ))
        .get();
    return pending.length;
  }
}
