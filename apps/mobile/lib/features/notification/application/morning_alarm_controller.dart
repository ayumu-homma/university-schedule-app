import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_providers.dart';
import '../../../core/native/native_scope_bridge.dart';
import '../domain/morning_alarm_models.dart';
import 'morning_alarm_platform.dart';

final morningAlarmControllerProvider =
    AsyncNotifierProvider<MorningAlarmController, MorningAlarmPlatformState>(
  MorningAlarmController.new,
);

/// Watching this provider at the app boundary keeps native ownership aligned
/// even when the notification settings screen has not been opened this run.
final morningAlarmOwnershipRuntimeProvider = Provider<void>((ref) {
  ref.watch(morningAlarmControllerProvider);
});

class MorningAlarmController extends AsyncNotifier<MorningAlarmPlatformState> {
  var _operationGeneration = 0;
  var _disposed = false;
  var _ownerBuildGeneration = 0;
  Future<void> _ownerTransition = Future<void>.value();

  @override
  Future<MorningAlarmPlatformState> build() async {
    _disposed = false;
    _operationGeneration += 1;
    final buildGeneration = ++_ownerBuildGeneration;
    ref.onDispose(() {
      _disposed = true;
      _operationGeneration += 1;
      _ownerBuildGeneration += 1;
    });
    final ownerUserId = ref.watch(
      currentAuthSessionProvider.select((session) => session?.userId),
    );
    final transition = _ownerTransition.then((_) async {
      if (_disposed || buildGeneration != _ownerBuildGeneration) {
        throw StateError('Morning alarm owner transition was superseded.');
      }
      final platform = ref.read(morningAlarmPlatformProvider);
      if (platform is MethodChannelMorningAlarmPlatform) {
        final expectedScope =
            await ref.read(nativeScopeBridgeProvider).current();
        if (_disposed || buildGeneration != _ownerBuildGeneration) {
          throw StateError('Morning alarm owner transition was superseded.');
        }
        final next = await platform.synchronizeOwner(
          ownerUserId,
          expectedScope: expectedScope,
        );
        if (_disposed || buildGeneration != _ownerBuildGeneration) {
          throw StateError('Morning alarm owner transition was superseded.');
        }
        return next;
      }
      final next = await platform.synchronizeOwner(ownerUserId);
      if (_disposed || buildGeneration != _ownerBuildGeneration) {
        throw StateError('Morning alarm owner transition was superseded.');
      }
      return next;
    });
    _ownerTransition = transition.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return transition;
  }

  Future<void> refresh() async {
    if (state.valueOrNull?.ownerUserId == null) return;
    await _run((platform, current, expectedScope) {
      final ownerUserId = _requiredOwner(current);
      return platform.refresh(ownerUserId, expectedScope: expectedScope);
    });
  }

  Future<void> updateSettings(MorningAlarmSettings settings) =>
      _run((platform, current, expectedScope) {
        final ownerUserId = _requiredOwner(current);
        if (settings.ownerUserId != ownerUserId) {
          throw StateError('Morning alarm owner changed.');
        }
        return platform.save(settings, expectedScope: expectedScope);
      });

  Future<void> requestNotificationPermission() =>
      _run((platform, current, expectedScope) {
        return platform.requestNotificationPermission(
          _requiredOwner(current),
          expectedScope: expectedScope,
        );
      });

  Future<void> openExactAlarmSettings() =>
      _run((platform, current, expectedScope) {
        return platform.openExactAlarmSettings(
          _requiredOwner(current),
          expectedScope: expectedScope,
        );
      });

  Future<void> openFullScreenSettings() =>
      _run((platform, current, expectedScope) {
        return platform.openFullScreenSettings(
          _requiredOwner(current),
          expectedScope: expectedScope,
        );
      });

  Future<void> scheduleDebugTest() => _run((platform, current, expectedScope) {
        return platform.scheduleDebugTest(
          _requiredOwner(current),
          expectedScope: expectedScope,
        );
      });

  Future<void> _run(
    Future<MorningAlarmPlatformState> Function(
      MorningAlarmPlatform platform,
      MorningAlarmPlatformState current,
      NativeScopeState? expectedScope,
    ) action,
  ) async {
    if (state.isLoading) return;
    final current = state.valueOrNull;
    if (current == null) return;
    final operation = ++_operationGeneration;
    final ownerAtStart = current.ownerUserId;
    final expectedScope = current.scope;
    final buildGeneration = _ownerBuildGeneration;
    state = const AsyncLoading<MorningAlarmPlatformState>().copyWithPrevious(
      state,
    );
    try {
      final next = await action(
        ref.read(morningAlarmPlatformProvider),
        current,
        expectedScope,
      );
      if (!_isCurrent(operation, ownerAtStart, buildGeneration)) return;
      state = AsyncData(next);
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(operation, ownerAtStart, buildGeneration)) return;
      state = AsyncError<MorningAlarmPlatformState>(
        error,
        stackTrace,
      ).copyWithPrevious(state);
    }
  }

  String _requiredOwner(MorningAlarmPlatformState current) {
    final ownerUserId = current.ownerUserId;
    if (ownerUserId == null || ownerUserId.isEmpty) {
      throw StateError('Morning alarm requires an authenticated owner.');
    }
    return ownerUserId;
  }

  bool _isCurrent(
    int operation,
    String? ownerAtStart,
    int buildGeneration,
  ) {
    if (_disposed || operation != _operationGeneration) return false;
    if (buildGeneration != _ownerBuildGeneration) return false;
    return ref.read(currentAuthSessionProvider)?.userId == ownerAtStart;
  }
}
