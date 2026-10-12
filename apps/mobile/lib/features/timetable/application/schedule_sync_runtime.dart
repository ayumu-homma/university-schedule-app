import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/sync/remote_schedule_gateway.dart';
import '../../../core/sync/sync_coordinator.dart';
import '../../../core/sync/sync_worker.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database.dart' as local;
import '../../auth/application/auth_providers.dart';
import '../../friends/application/friend_providers.dart';
import '../../onboarding/application/onboarding_providers.dart';
import '../data/local_schedule_repository.dart';

enum ScheduleSyncPhase {
  disabled,
  idle,
  running,
  synchronized,
  waitingToRetry,
  conflict,
  blockedByLocalMutation,
  error,
}

class ScheduleSyncStatus {
  const ScheduleSyncStatus({
    required this.phase,
    this.ownerUserId,
    this.cursor = 0,
    this.lastCompletedAt,
    this.nextRetryAt,
    this.lastError,
    this.lastResult,
  });

  const ScheduleSyncStatus.disabled() : this(phase: ScheduleSyncPhase.disabled);

  final ScheduleSyncPhase phase;
  final String? ownerUserId;
  final int cursor;
  final DateTime? lastCompletedAt;
  final DateTime? nextRetryAt;
  final String? lastError;
  final SyncCoordinatorRunResult? lastResult;

  bool get isRunning => phase == ScheduleSyncPhase.running;
}

final scheduleSyncRuntimeProvider = AutoDisposeNotifierProvider<
    ScheduleSyncRuntimeController, ScheduleSyncStatus>(
  ScheduleSyncRuntimeController.new,
);

final actionableScheduleMutationCountProvider =
    StreamProvider.autoDispose<int>((ref) {
  final config = ref.watch(appConfigProvider);
  final session = ref.watch(currentAuthSessionProvider);
  final profile = ref.watch(onboardingControllerProvider).valueOrNull;
  if (config.demoMode ||
      session == null ||
      profile == null ||
      profile.userId != session.userId ||
      !profile.hasActiveSchedule) {
    return Stream.value(0);
  }
  return ref
      .watch(appDatabaseProvider)
      .syncQueueDao
      .watchActionableCount(session.userId);
});

final actionableScheduleMutationsProvider =
    StreamProvider.autoDispose<List<local.SyncQueueEntry>>((ref) {
  final config = ref.watch(appConfigProvider);
  final session = ref.watch(currentAuthSessionProvider);
  final profile = ref.watch(onboardingControllerProvider).valueOrNull;
  if (config.demoMode ||
      session == null ||
      profile == null ||
      profile.userId != session.userId ||
      !profile.hasActiveSchedule) {
    return Stream.value(const <local.SyncQueueEntry>[]);
  }
  return ref
      .watch(appDatabaseProvider)
      .syncQueueDao
      .watchActionableMutations(session.userId);
});

class ScheduleSyncRuntimeController
    extends AutoDisposeNotifier<ScheduleSyncStatus> {
  SyncCoordinator? _coordinator;
  SupabaseClient? _client;
  RealtimeChannel? _channel;
  Timer? _retryTimer;
  Future<SyncCoordinatorRunResult?>? _runtimeInFlight;
  String? _ownerUserId;
  int _generation = 0;
  int _transientFailureCount = 0;
  bool _runtimeRerunRequested = false;
  bool _disposed = false;
  bool _disposeRegistered = false;

  @override
  ScheduleSyncStatus build() {
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        _disposed = true;
        _teardown();
      });
    }

    final config = ref.watch(appConfigProvider);
    final session = ref.watch(currentAuthSessionProvider);
    final profile = ref.watch(onboardingControllerProvider).valueOrNull;
    if (config.demoMode ||
        session == null ||
        profile == null ||
        profile.userId != session.userId ||
        !profile.hasActiveSchedule) {
      _teardown();
      return const ScheduleSyncStatus.disabled();
    }

    final client = ref.watch(supabaseClientProvider);
    if (client == null) {
      _teardown();
      return ScheduleSyncStatus(
        phase: ScheduleSyncPhase.error,
        ownerUserId: session.userId,
        lastError: 'Supabase schedule sync is unavailable.',
      );
    }

    final coordinator = ref.watch(syncCoordinatorProvider);
    _teardown();
    _disposed = false;
    _coordinator = coordinator;
    _client = client;
    _ownerUserId = session.userId;
    final generation = ++_generation;
    ref.listen<AsyncValue<int>>(
      actionableScheduleMutationCountProvider,
      (previous, next) {
        final previousCount = previous?.valueOrNull ?? 0;
        final nextCount = next.valueOrNull ?? 0;
        if (nextCount > previousCount &&
            _isCurrent(generation, session.userId)) {
          unawaited(
            _run(SyncTrigger.localMutation, generation: generation),
          );
        }
      },
    );
    _subscribeToInvalidations(
      client: client,
      ownerUserId: session.userId,
      generation: generation,
    );
    Future<void>.microtask(() async {
      await _run(SyncTrigger.startup, generation: generation);
    });
    return ScheduleSyncStatus(
      phase: ScheduleSyncPhase.idle,
      ownerUserId: session.userId,
    );
  }

  Future<SyncCoordinatorRunResult?> trigger(SyncTrigger trigger) {
    return _run(trigger, generation: _generation);
  }

  Future<SyncCoordinatorRunResult?> _run(
    SyncTrigger trigger, {
    required int generation,
  }) {
    final coordinator = _coordinator;
    final ownerUserId = _ownerUserId;
    if (_disposed ||
        coordinator == null ||
        ownerUserId == null ||
        generation != _generation) {
      return Future.value(null);
    }
    final existing = _runtimeInFlight;
    if (existing != null) {
      _runtimeRerunRequested = true;
      return existing;
    }
    final operation = _drainRuntime(
      trigger,
      generation: generation,
      ownerUserId: ownerUserId,
    );
    _runtimeInFlight = operation;
    return operation;
  }

  Future<SyncCoordinatorRunResult?> _drainRuntime(
    SyncTrigger trigger, {
    required int generation,
    required String ownerUserId,
  }) async {
    try {
      SyncCoordinatorRunResult? latest;
      var nextTrigger = trigger;
      do {
        _runtimeRerunRequested = false;
        latest = await _runOnce(nextTrigger, generation: generation);
        nextTrigger = SyncTrigger.manual;
      } while (_runtimeRerunRequested && _isCurrent(generation, ownerUserId));
      return latest;
    } finally {
      // Clear before this Future completes. No event can enter between the
      // final rerun check and this synchronous assignment, so a wakeup either
      // joins the drain or starts a new operation; it cannot be stranded.
      if (_isCurrent(generation, ownerUserId)) {
        _runtimeInFlight = null;
      }
    }
  }

  Future<SyncCoordinatorRunResult?> _runOnce(
    SyncTrigger trigger, {
    required int generation,
  }) async {
    final coordinator = _coordinator;
    final ownerUserId = _ownerUserId;
    if (_disposed ||
        coordinator == null ||
        ownerUserId == null ||
        generation != _generation) {
      return null;
    }
    state = ScheduleSyncStatus(
      phase: ScheduleSyncPhase.running,
      ownerUserId: ownerUserId,
      cursor: state.ownerUserId == ownerUserId ? state.cursor : 0,
      lastCompletedAt: state.lastCompletedAt,
      lastResult: state.lastResult,
    );
    try {
      final result = trigger == SyncTrigger.startup
          ? await coordinator.start()
          : await coordinator.synchronize(trigger);
      if (!_isCurrent(generation, ownerUserId)) return result;
      _transientFailureCount = 0;
      _scheduleRetry(result.push.nextRetryAt, generation);
      final phase = result.push.conflicts > 0
          ? ScheduleSyncPhase.conflict
          : result.blockedByLocalMutation
              ? ScheduleSyncPhase.blockedByLocalMutation
              : result.push.nextRetryAt != null
                  ? ScheduleSyncPhase.waitingToRetry
                  : ScheduleSyncPhase.synchronized;
      state = ScheduleSyncStatus(
        phase: phase,
        ownerUserId: ownerUserId,
        cursor: result.cursor,
        lastCompletedAt: ref.read(appClockProvider).now().toUtc(),
        nextRetryAt: result.push.nextRetryAt,
        lastResult: result,
      );
      return result;
    } on Object catch (error) {
      if (!_isCurrent(generation, ownerUserId)) return null;
      final isTransient = error is RemoteScheduleTransientException;
      DateTime? nextRetryAt;
      if (isTransient) {
        _transientFailureCount++;
        final delay = const SyncRetryPolicy().delayForAttempt(
          _transientFailureCount,
        );
        nextRetryAt = ref.read(appClockProvider).now().toUtc().add(delay);
        _scheduleRetry(nextRetryAt, generation);
      } else {
        _scheduleRetry(null, generation);
      }
      state = ScheduleSyncStatus(
        phase: isTransient
            ? ScheduleSyncPhase.waitingToRetry
            : ScheduleSyncPhase.error,
        ownerUserId: ownerUserId,
        cursor: state.cursor,
        lastCompletedAt: state.lastCompletedAt,
        nextRetryAt: nextRetryAt,
        lastError: _safeError(error),
        lastResult: state.lastResult,
      );
      return null;
    }
  }

  void _subscribeToInvalidations({
    required SupabaseClient client,
    required String ownerUserId,
    required int generation,
  }) {
    final channel = client.channel(
      'schedule-sync:$ownerUserId',
      opts: const RealtimeChannelConfig(private: true),
    );
    _channel = channel
        .onBroadcast(
          event: 'invalidate',
          callback: (_) {
            if (_isCurrent(generation, ownerUserId)) {
              unawaited(_run(SyncTrigger.realtime, generation: generation));
            }
          },
        )
        .onBroadcast(
          event: 'friend-invalidate',
          callback: (_) {
            if (_isCurrent(generation, ownerUserId)) {
              // Friend sharing has its own cache and state gate.  Keep this
              // payload-free event separate from personal schedule sync while
              // retaining the channel's existing lifecycle and callbacks.
              unawaited(
                ref
                    .read(friendsControllerProvider.notifier)
                    .onFriendInvalidated(),
              );
            }
          },
        )
        .subscribe((status, _) {
      if (status == RealtimeSubscribeStatus.subscribed &&
          _isCurrent(generation, ownerUserId)) {
        unawaited(_run(SyncTrigger.realtime, generation: generation));
        unawaited(
          ref.read(friendsControllerProvider.notifier).onConnectionRestored(),
        );
      } else if (status != RealtimeSubscribeStatus.subscribed &&
          _isCurrent(generation, ownerUserId)) {
        unawaited(
          ref.read(friendsControllerProvider.notifier).onConnectionLost(),
        );
      }
    });
  }

  void _scheduleRetry(DateTime? retryAt, int generation) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (retryAt == null) return;
    final delay = retryAt.difference(ref.read(appClockProvider).now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (!_disposed && generation == _generation) {
        unawaited(_run(SyncTrigger.retryTimer, generation: generation));
      }
    });
  }

  bool _isCurrent(int generation, String ownerUserId) {
    return !_disposed &&
        generation == _generation &&
        _ownerUserId == ownerUserId;
  }

  String _safeError(Object error) {
    if (error is RemoteScheduleAuthenticationException) {
      return 'Schedule sync authentication changed.';
    }
    if (error is RemoteScheduleTransientException) {
      return 'Schedule sync will retry when the connection is available.';
    }
    if (error is RemoteScheduleProtocolException) {
      return 'Schedule sync received an invalid response.';
    }
    return 'Schedule sync failed safely.';
  }

  void _teardown() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _runtimeInFlight = null;
    _runtimeRerunRequested = false;
    _coordinator = null;
    _transientFailureCount = 0;
    _ownerUserId = null;
    final client = _client;
    final channel = _channel;
    _client = null;
    _channel = null;
    if (client != null && channel != null) {
      unawaited(client.removeChannel(channel));
    }
  }
}
