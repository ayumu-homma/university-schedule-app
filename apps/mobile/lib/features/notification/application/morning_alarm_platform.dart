import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/native/native_scope_bridge.dart';
import '../domain/morning_alarm_models.dart';

const morningAlarmChannelName = 'jp.universityschedule.app/morning_alarm';

abstract interface class MorningAlarmPlatform {
  Future<MorningAlarmPlatformState> synchronizeOwner(String? ownerUserId);

  Future<MorningAlarmPlatformState> refresh(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  });

  Future<MorningAlarmPlatformState> save(
    MorningAlarmSettings settings, {
    NativeScopeState? expectedScope,
  });

  Future<MorningAlarmPlatformState> requestNotificationPermission(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  });

  Future<MorningAlarmPlatformState> openExactAlarmSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  });

  Future<MorningAlarmPlatformState> openFullScreenSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  });

  Future<MorningAlarmPlatformState> scheduleDebugTest(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  });
}

final morningAlarmPlatformProvider = Provider<MorningAlarmPlatform>((ref) {
  return morningAlarmPlatformFor(defaultTargetPlatform);
});

MorningAlarmPlatform morningAlarmPlatformFor(
  TargetPlatform platform, {
  bool allowDesktopTestFallback = kDebugMode,
}) {
  if (platform == TargetPlatform.android) {
    return const MethodChannelMorningAlarmPlatform();
  }
  if (platform != TargetPlatform.iOS && allowDesktopTestFallback) {
    return InMemoryMorningAlarmPlatform();
  }
  return const UnsupportedMorningAlarmPlatform();
}

class UnsupportedMorningAlarmPlatform implements MorningAlarmPlatform {
  const UnsupportedMorningAlarmPlatform();

  static UnsupportedError _unavailable() => UnsupportedError(
        'Morning alarm native integration is unavailable on this platform.',
      );

  @override
  Future<MorningAlarmPlatformState> synchronizeOwner(
    String? ownerUserId,
  ) async {
    if (ownerUserId == null) {
      return const MorningAlarmPlatformState.signedOut();
    }
    throw _unavailable();
  }

  @override
  Future<MorningAlarmPlatformState> refresh(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());

  @override
  Future<MorningAlarmPlatformState> save(
    MorningAlarmSettings settings, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());

  @override
  Future<MorningAlarmPlatformState> requestNotificationPermission(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());

  @override
  Future<MorningAlarmPlatformState> openExactAlarmSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());

  @override
  Future<MorningAlarmPlatformState> openFullScreenSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());

  @override
  Future<MorningAlarmPlatformState> scheduleDebugTest(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) =>
      Future.error(_unavailable());
}

class MethodChannelMorningAlarmPlatform implements MorningAlarmPlatform {
  const MethodChannelMorningAlarmPlatform({
    MethodChannel channel = const MethodChannel(morningAlarmChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<MorningAlarmPlatformState> synchronizeOwner(
    String? ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'synchronizeOwner',
      _withScope({'ownerId': ownerUserId}, expectedScope),
    );
    if (ownerUserId == null) {
      return const MorningAlarmPlatformState.signedOut();
    }
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  @override
  Future<MorningAlarmPlatformState> refresh(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'readState',
      _withScope({'ownerId': ownerUserId}, expectedScope),
    );
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  @override
  Future<MorningAlarmPlatformState> save(
    MorningAlarmSettings settings, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'saveSettings',
      _withScope(settings.toPlatformMap(), expectedScope),
    );
    return MorningAlarmPlatformState.fromPlatformMap(
      settings.ownerUserId,
      result,
    );
  }

  @override
  Future<MorningAlarmPlatformState> requestNotificationPermission(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'requestNotificationPermission',
      _withScope({'ownerId': ownerUserId}, expectedScope),
    );
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  @override
  Future<MorningAlarmPlatformState> openExactAlarmSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'openExactAlarmSettings',
      _withScope({'ownerId': ownerUserId}, expectedScope),
    );
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  @override
  Future<MorningAlarmPlatformState> openFullScreenSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'openFullScreenSettings',
      _withScope({'ownerId': ownerUserId}, expectedScope),
    );
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  @override
  Future<MorningAlarmPlatformState> scheduleDebugTest(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    final result = await _invoke(
      'scheduleDebugTest',
      _withScope(
        {'ownerId': ownerUserId, 'delaySeconds': 10},
        expectedScope,
      ),
    );
    return MorningAlarmPlatformState.fromPlatformMap(ownerUserId, result);
  }

  Future<Map<Object?, Object?>> _invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      method,
      arguments,
    );
    if (result == null) {
      throw const FormatException('Morning alarm platform returned no state.');
    }
    return result;
  }

  Map<String, Object?> _withScope(
    Map<String, Object?> arguments,
    NativeScopeState? scope,
  ) {
    final expected = scope ?? const NativeScopeState.inactive();
    return <String, Object?>{
      ...arguments,
      'expectedScopeRegionId': expected.regionId,
      'expectedScopeOwnerHash': expected.ownerHash,
      'expectedScopeGeneration': expected.generation,
      'expectedScopeActivationToken': expected.activationToken,
      'expectedScopeActive': expected.active,
    };
  }
}

/// Deterministic explicitly injected desktop/test implementation. It mirrors the
/// owner-switch cancellation semantics of the Android preferences boundary.
class InMemoryMorningAlarmPlatform implements MorningAlarmPlatform {
  InMemoryMorningAlarmPlatform({
    DateTime Function()? now,
    MorningAlarmCapabilities capabilities = const MorningAlarmCapabilities(
      notificationPermission: AlarmPermissionStatus.granted,
      schedulePrecision: AlarmSchedulePrecision.exact,
      fullScreenAllowed: true,
      debugTestAllowed: true,
    ),
  })  : _now = now ?? DateTime.now,
        _capabilities = capabilities;

  final DateTime Function() _now;
  MorningAlarmCapabilities _capabilities;
  final Map<String, MorningAlarmSettings> _settingsByOwner = {};
  String? _activeOwner;

  String? get activeOwner => _activeOwner;
  int ownerCancellationCount = 0;
  int debugScheduleCount = 0;

  @override
  Future<MorningAlarmPlatformState> synchronizeOwner(
    String? ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    if (_activeOwner != ownerUserId && _activeOwner != null) {
      ownerCancellationCount += 1;
    }
    _activeOwner = ownerUserId;
    if (ownerUserId == null) {
      return const MorningAlarmPlatformState.signedOut();
    }
    _settingsByOwner.putIfAbsent(
      ownerUserId,
      () => MorningAlarmSettings(ownerUserId: ownerUserId),
    );
    return _state(ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> refresh(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(ownerUserId);
    return _state(ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> save(
    MorningAlarmSettings settings, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(settings.ownerUserId);
    _settingsByOwner[settings.ownerUserId] = settings;
    return _state(settings.ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> requestNotificationPermission(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(ownerUserId);
    _capabilities = MorningAlarmCapabilities(
      notificationPermission: AlarmPermissionStatus.granted,
      schedulePrecision: _capabilities.schedulePrecision,
      fullScreenAllowed: _capabilities.fullScreenAllowed,
      debugTestAllowed: _capabilities.debugTestAllowed,
    );
    return _state(ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> openExactAlarmSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(ownerUserId);
    return _state(ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> openFullScreenSettings(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(ownerUserId);
    return _state(ownerUserId);
  }

  @override
  Future<MorningAlarmPlatformState> scheduleDebugTest(
    String ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    _requireActive(ownerUserId);
    if (!_capabilities.debugTestAllowed) {
      throw StateError('Debug alarm testing is unavailable.');
    }
    debugScheduleCount += 1;
    return _state(ownerUserId);
  }

  MorningAlarmPlatformState _state(String ownerUserId) {
    final settings = _settingsByOwner[ownerUserId] ??
        MorningAlarmSettings(ownerUserId: ownerUserId);
    return MorningAlarmPlatformState(
      ownerUserId: ownerUserId,
      settings: settings,
      capabilities: _capabilities,
      nextOccurrence: settings.enabled
          ? MorningAlarmSchedule.nextOccurrence(
              now: _now(),
              hour: settings.hour,
              minute: settings.minute,
              weekdays: settings.weekdays,
            )
          : null,
    );
  }

  void _requireActive(String ownerUserId) {
    if (_activeOwner != ownerUserId) {
      throw StateError('Morning alarm owner is not active.');
    }
  }
}
