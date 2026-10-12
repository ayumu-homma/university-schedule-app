import 'dart:collection';

import 'package:shared_domain/shared_domain.dart';

import '../../../core/native/native_scope_bridge.dart';

const morningAlarmContractVersion = 1;
const morningAlarmDeepLink = 'unischedule://today?source=morning-alarm';

enum AlarmPermissionStatus { granted, denied, notRequired, unknown }

enum AlarmSchedulePrecision { exact, inexact, unavailable }

class MorningAlarmSettings {
  MorningAlarmSettings({
    required this.ownerUserId,
    this.enabled = false,
    this.hour = 7,
    this.minute = 30,
    Set<int> weekdays = const {
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
    },
    this.soundEnabled = true,
    this.vibrationEnabled = true,
    this.snoozeMinutes = 10,
    this.openTodayOnStop = true,
    this.lockScreenPrivacy = true,
  }) : weekdays = UnmodifiableSetView(Set<int>.from(weekdays)) {
    _validate();
  }

  final String ownerUserId;
  final bool enabled;
  final int hour;
  final int minute;
  final Set<int> weekdays;
  final bool soundEnabled;
  final bool vibrationEnabled;
  final int snoozeMinutes;
  final bool openTodayOnStop;
  final bool lockScreenPrivacy;

  MorningAlarmSettings copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    Set<int>? weekdays,
    bool? soundEnabled,
    bool? vibrationEnabled,
    int? snoozeMinutes,
    bool? openTodayOnStop,
    bool? lockScreenPrivacy,
  }) {
    return MorningAlarmSettings(
      ownerUserId: ownerUserId,
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      weekdays: weekdays ?? this.weekdays,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      vibrationEnabled: vibrationEnabled ?? this.vibrationEnabled,
      snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
      openTodayOnStop: openTodayOnStop ?? this.openTodayOnStop,
      lockScreenPrivacy: lockScreenPrivacy ?? this.lockScreenPrivacy,
    );
  }

  Map<String, Object?> toPlatformMap() => {
        'version': morningAlarmContractVersion,
        'ownerId': ownerUserId,
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
        'weekdays': weekdays.toList()..sort(),
        'soundEnabled': soundEnabled,
        'vibrationEnabled': vibrationEnabled,
        'snoozeMinutes': snoozeMinutes,
        'openTodayOnStop': openTodayOnStop,
        'lockScreenPrivacy': lockScreenPrivacy,
      };

  factory MorningAlarmSettings.fromPlatformMap(
    String ownerUserId,
    Map<Object?, Object?> map,
  ) {
    final rawWeekdays = map['weekdays'];
    if (map['version'] != morningAlarmContractVersion || rawWeekdays is! List) {
      throw const FormatException('Unsupported morning alarm contract.');
    }
    return MorningAlarmSettings(
      ownerUserId: ownerUserId,
      enabled: _requiredBool(map, 'enabled'),
      hour: _requiredInt(map, 'hour'),
      minute: _requiredInt(map, 'minute'),
      weekdays: rawWeekdays.map((value) {
        if (value is! int) {
          throw const FormatException('Invalid morning alarm weekday.');
        }
        return value;
      }).toSet(),
      soundEnabled: _requiredBool(map, 'soundEnabled'),
      vibrationEnabled: _requiredBool(map, 'vibrationEnabled'),
      snoozeMinutes: _requiredInt(map, 'snoozeMinutes'),
      openTodayOnStop: _requiredBool(map, 'openTodayOnStop'),
      lockScreenPrivacy: _requiredBool(map, 'lockScreenPrivacy'),
    );
  }

  void _validate() {
    if (ownerUserId.trim().isEmpty || ownerUserId.length > 256) {
      throw const FormatException('Invalid morning alarm owner.');
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const FormatException('Invalid morning alarm time.');
    }
    if (weekdays.isEmpty ||
        weekdays.any(
          (weekday) => weekday < DateTime.monday || weekday > DateTime.sunday,
        )) {
      throw const FormatException('Invalid morning alarm weekdays.');
    }
    if (!const {5, 10, 15}.contains(snoozeMinutes)) {
      throw const FormatException('Invalid morning alarm snooze interval.');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MorningAlarmSettings &&
      other.ownerUserId == ownerUserId &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute &&
      other.weekdays.length == weekdays.length &&
      other.weekdays.containsAll(weekdays) &&
      other.soundEnabled == soundEnabled &&
      other.vibrationEnabled == vibrationEnabled &&
      other.snoozeMinutes == snoozeMinutes &&
      other.openTodayOnStop == openTodayOnStop &&
      other.lockScreenPrivacy == lockScreenPrivacy;

  @override
  int get hashCode => Object.hash(
        ownerUserId,
        enabled,
        hour,
        minute,
        Object.hashAll(weekdays.toList()..sort()),
        soundEnabled,
        vibrationEnabled,
        snoozeMinutes,
        openTodayOnStop,
        lockScreenPrivacy,
      );
}

class MorningAlarmCapabilities {
  const MorningAlarmCapabilities({
    required this.notificationPermission,
    required this.schedulePrecision,
    required this.fullScreenAllowed,
    required this.debugTestAllowed,
  });

  const MorningAlarmCapabilities.unavailable()
      : notificationPermission = AlarmPermissionStatus.unknown,
        schedulePrecision = AlarmSchedulePrecision.unavailable,
        fullScreenAllowed = false,
        debugTestAllowed = false;

  final AlarmPermissionStatus notificationPermission;
  final AlarmSchedulePrecision schedulePrecision;
  final bool fullScreenAllowed;
  final bool debugTestAllowed;

  factory MorningAlarmCapabilities.fromPlatformMap(
    Map<Object?, Object?> map,
  ) {
    return MorningAlarmCapabilities(
      notificationPermission: _permissionStatus(map['notificationPermission']),
      schedulePrecision: _schedulePrecision(map['schedulePrecision']),
      fullScreenAllowed: _requiredBool(map, 'fullScreenAllowed'),
      debugTestAllowed: _requiredBool(map, 'debugTestAllowed'),
    );
  }
}

class MorningAlarmPlatformState {
  const MorningAlarmPlatformState({
    required this.ownerUserId,
    required this.settings,
    required this.capabilities,
    required this.nextOccurrence,
    this.scope,
  });

  const MorningAlarmPlatformState.signedOut()
      : ownerUserId = null,
        settings = null,
        capabilities = const MorningAlarmCapabilities.unavailable(),
        nextOccurrence = null,
        scope = null;

  final String? ownerUserId;
  final MorningAlarmSettings? settings;
  final MorningAlarmCapabilities capabilities;
  final DateTime? nextOccurrence;
  final NativeScopeState? scope;

  factory MorningAlarmPlatformState.fromPlatformMap(
    String ownerUserId,
    Map<Object?, Object?> map,
  ) {
    final rawSettings = map['settings'];
    final rawCapabilities = map['capabilities'];
    if (rawSettings is! Map || rawCapabilities is! Map) {
      throw const FormatException('Invalid morning alarm platform state.');
    }
    final rawNextEpochMillis = map['nextOccurrenceEpochMillis'];
    if (rawNextEpochMillis != null && rawNextEpochMillis is! int) {
      throw const FormatException('Invalid morning alarm next occurrence.');
    }
    final nextEpochMillis = rawNextEpochMillis as int?;
    final scope = _scopeFromPlatformMap(map);
    return MorningAlarmPlatformState(
      ownerUserId: ownerUserId,
      settings: MorningAlarmSettings.fromPlatformMap(
        ownerUserId,
        Map<Object?, Object?>.from(rawSettings),
      ),
      capabilities: MorningAlarmCapabilities.fromPlatformMap(
        Map<Object?, Object?>.from(rawCapabilities),
      ),
      nextOccurrence: nextEpochMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              nextEpochMillis,
              isUtc: true,
            ),
      scope: scope,
    );
  }
}

NativeScopeState? _scopeFromPlatformMap(Map<Object?, Object?> map) {
  final hasScope = <String>[
    'scopeRegionId',
    'scopeOwnerHash',
    'scopeGeneration',
    'scopeActivationToken',
    'scopeActive',
  ].any(map.containsKey);
  if (!hasScope) return null;
  final generation = map['scopeGeneration'];
  final active = map['scopeActive'];
  if (generation is! int || active is! bool) {
    throw const FormatException('Invalid morning alarm scope.');
  }
  return NativeScopeState(
    regionId: map['scopeRegionId'] as String?,
    ownerHash: map['scopeOwnerHash'] as String?,
    activationToken: map['scopeActivationToken'] as String?,
    generation: generation,
    active: active,
  );
}

class MorningAlarmSchedule {
  const MorningAlarmSchedule._();

  /// Returns the first selected Asia/Tokyo wall-clock occurrence strictly
  /// after [now]. The result is a UTC instant suitable for persistence.
  static DateTime nextOccurrence({
    required DateTime now,
    required int hour,
    required int minute,
    required Set<int> weekdays,
  }) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const FormatException('Invalid morning alarm time.');
    }
    if (weekdays.isEmpty ||
        weekdays.any(
          (weekday) => weekday < DateTime.monday || weekday > DateTime.sunday,
        )) {
      throw const FormatException('Invalid morning alarm weekdays.');
    }

    final civilNow = JapanTime.civil(now);
    final baseDate = DateTime.utc(
      civilNow.year,
      civilNow.month,
      civilNow.day,
    );
    for (var dayOffset = 0; dayOffset <= 7; dayOffset += 1) {
      final date = baseDate.add(Duration(days: dayOffset));
      if (!weekdays.contains(date.weekday)) continue;
      final candidate = JapanTime.at(
        year: date.year,
        month: date.month,
        day: date.day,
        hour: hour,
        minute: minute,
      );
      if (candidate.isAfter(now.toUtc())) return candidate;
    }
    throw StateError('No morning alarm occurrence could be calculated.');
  }
}

bool _requiredBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

int _requiredInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! int) throw FormatException('Invalid $key.');
  return value;
}

AlarmPermissionStatus _permissionStatus(Object? value) => switch (value) {
      'granted' => AlarmPermissionStatus.granted,
      'denied' => AlarmPermissionStatus.denied,
      'notRequired' => AlarmPermissionStatus.notRequired,
      _ => AlarmPermissionStatus.unknown,
    };

AlarmSchedulePrecision _schedulePrecision(Object? value) => switch (value) {
      'exact' => AlarmSchedulePrecision.exact,
      'inexact' => AlarmSchedulePrecision.inexact,
      _ => AlarmSchedulePrecision.unavailable,
    };
