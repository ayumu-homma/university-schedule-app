import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/time/app_clock.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database.dart' as local;
import '../../../local_db/app_database_provider.dart';
import '../../auth/application/auth_providers.dart';
import '../../timetable/application/schedule_sync_runtime.dart';
import '../data/email_reconciliation_service.dart';
import '../data/supabase_email_reconciliation_gateway.dart';
import '../domain/email_reconciliation.dart';
import 'email_review_providers.dart';

final emailReconciliationGatewayProvider =
    Provider<EmailReconciliationGateway>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (!config.emailImportEnabled || client == null) {
    throw StateError('Email reconciliation is unavailable.');
  }
  return SupabaseEmailReconciliationGateway(
    emailImportEnabled: true,
    client: client,
  );
});

final emailReconciliationServiceProvider =
    Provider<EmailReconciliationService>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  if (session == null) {
    throw StateError('Email reconciliation requires an authenticated owner.');
  }
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(ownerUserId: session.userId, database: db);
  ref.onDispose(lease.revoke);
  return EmailReconciliationService(
    db: db,
    gateway: ref.watch(emailReconciliationGatewayProvider),
    clock: () => ref.read(appClockProvider).now(),
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    lease: lease,
  );
});

final _pendingEmailReconciliationReceiptsProvider = StreamProvider.autoDispose
    .family<List<local.EmailReconciliationReceipt>, String>(
  (ref, ownerUserId) {
    final db = ref.watch(appDatabaseProvider);
    return (db.select(db.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.state.equals('pending'))
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
          ]))
        .watch();
  },
);

enum EmailReconciliationRuntimePhase {
  disabled,
  offline,
  idle,
  running,
  synchronized,
  waitingForScheduleSync,
  error,
}

class EmailReconciliationRuntimeState {
  const EmailReconciliationRuntimeState({
    required this.phase,
    this.ownerUserId,
    this.lastResult,
  });

  const EmailReconciliationRuntimeState.disabled()
      : this(phase: EmailReconciliationRuntimePhase.disabled);

  final EmailReconciliationRuntimePhase phase;
  final String? ownerUserId;
  final EmailReconciliationRunResult? lastResult;
}

final emailReconciliationRuntimeProvider = AutoDisposeNotifierProvider<
    EmailReconciliationRuntimeController, EmailReconciliationRuntimeState>(
  EmailReconciliationRuntimeController.new,
);

/// Feature-flagged application runtime. Auth, connectivity and every schedule
/// sync or receipt change rebuilds this controller. A bounded timer wakes the
/// earliest transient retry even when the app otherwise remains idle.
class EmailReconciliationRuntimeController
    extends AutoDisposeNotifier<EmailReconciliationRuntimeState> {
  EmailReconciliationService? _service;
  String? _ownerUserId;
  bool _networkAvailable = false;
  int _generation = 0;
  Future<EmailReconciliationRunResult?>? _inFlight;
  bool _rerunRequested = false;
  Timer? _retryTimer;
  bool _disposeRegistered = false;

  @override
  EmailReconciliationRuntimeState build() {
    final config = ref.watch(appConfigProvider);
    final session = ref.watch(currentAuthSessionProvider);
    final generation = ++_generation;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() => _retryTimer?.cancel());
    }
    _service = null;
    _ownerUserId = null;
    _networkAvailable = false;
    _inFlight = null;
    _rerunRequested = false;

    if (!config.emailImportEnabled || session == null) {
      return const EmailReconciliationRuntimeState.disabled();
    }
    final network =
        ref.watch(emailNetworkAvailableProvider).valueOrNull == true;
    // This dependency is intentionally observed even though receipt gating is
    // verified from Drift; a completed schedule sync becomes a wake-up signal.
    ref.watch(scheduleSyncRuntimeProvider);
    final client = ref.watch(supabaseClientProvider);
    if (client == null) {
      return EmailReconciliationRuntimeState(
        phase: EmailReconciliationRuntimePhase.error,
        ownerUserId: session.userId,
      );
    }
    _service = ref.watch(emailReconciliationServiceProvider);
    _ownerUserId = session.userId;
    _networkAvailable = network;
    ref.listen<AsyncValue<List<local.EmailReconciliationReceipt>>>(
      _pendingEmailReconciliationReceiptsProvider(session.userId),
      (_, next) {
        if (generation != _generation) return;
        final receipts = next.valueOrNull;
        if (receipts == null) return;
        _scheduleNextRetry(receipts, generation);
        if (_networkAvailable) {
          Future<void>.microtask(() async {
            if (generation == _generation) await trigger();
          });
        }
      },
      fireImmediately: true,
    );
    if (!network) {
      return EmailReconciliationRuntimeState(
        phase: EmailReconciliationRuntimePhase.offline,
        ownerUserId: session.userId,
      );
    }
    Future<void>.microtask(() async {
      if (generation == _generation) await trigger();
    });
    return EmailReconciliationRuntimeState(
      phase: EmailReconciliationRuntimePhase.idle,
      ownerUserId: session.userId,
    );
  }

  Future<EmailReconciliationRunResult?> trigger() {
    final service = _service;
    final ownerUserId = _ownerUserId;
    if (service == null || ownerUserId == null || !_networkAvailable) {
      return Future.value(null);
    }
    final existing = _inFlight;
    if (existing != null) {
      _rerunRequested = true;
      return existing;
    }
    final generation = _generation;
    final operation = _drain(
      service: service,
      ownerUserId: ownerUserId,
      generation: generation,
    );
    _inFlight = operation;
    return operation;
  }

  Future<EmailReconciliationRunResult?> _drain({
    required EmailReconciliationService service,
    required String ownerUserId,
    required int generation,
  }) async {
    EmailReconciliationRunResult? latest;
    try {
      do {
        _rerunRequested = false;
        if (!_isCurrent(ownerUserId, generation)) return latest;
        state = EmailReconciliationRuntimeState(
          phase: EmailReconciliationRuntimePhase.running,
          ownerUserId: ownerUserId,
          lastResult: state.lastResult,
        );
        latest = await service.synchronize(
          ownerUserId: ownerUserId,
          networkAvailable: true,
        );
        if (!_isCurrent(ownerUserId, generation)) return latest;
        state = EmailReconciliationRuntimeState(
          phase: latest.waitingForScheduleSync > 0
              ? EmailReconciliationRuntimePhase.waitingForScheduleSync
              : EmailReconciliationRuntimePhase.synchronized,
          ownerUserId: ownerUserId,
          lastResult: latest,
        );
      } while (_rerunRequested && _isCurrent(ownerUserId, generation));
      return latest;
    } on Object {
      if (_isCurrent(ownerUserId, generation)) {
        state = EmailReconciliationRuntimeState(
          phase: EmailReconciliationRuntimePhase.error,
          ownerUserId: ownerUserId,
          lastResult: latest,
        );
      }
      return latest;
    } finally {
      if (_isCurrent(ownerUserId, generation)) _inFlight = null;
    }
  }

  bool _isCurrent(String ownerUserId, int generation) {
    return generation == _generation && _ownerUserId == ownerUserId;
  }

  void _scheduleNextRetry(
    List<local.EmailReconciliationReceipt> receipts,
    int generation,
  ) {
    _retryTimer?.cancel();
    _retryTimer = null;
    final now = ref.read(appClockProvider).now().toUtc();
    DateTime? earliest;
    for (final receipt in receipts) {
      final retryAt = receipt.nextRetryAt?.toUtc();
      if (retryAt == null || !retryAt.isAfter(now)) {
        continue;
      }
      if (earliest == null || retryAt.isBefore(earliest)) {
        earliest = retryAt;
      }
    }
    if (earliest == null) return;
    _retryTimer = Timer(earliest.difference(now), () {
      if (generation != _generation) return;
      unawaited(trigger());
    });
  }
}
