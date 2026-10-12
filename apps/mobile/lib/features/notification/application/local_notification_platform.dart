import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/native/native_scope_bridge.dart';
import '../domain/local_notification_models.dart';

const localNotificationChannelName =
    'jp.universityschedule.app/local_notifications';

class LocalNotificationPlatformState {
  const LocalNotificationPlatformState({
    required this.permission,
    required this.exactAlarm,
    required this.scheduledCount,
    this.channel = 'unknown',
    this.blockedReason,
  });

  final String permission;
  final String exactAlarm;
  final int scheduledCount;
  final String channel;
  final String? blockedReason;

  factory LocalNotificationPlatformState.fromMap(Map<Object?, Object?> map) {
    return LocalNotificationPlatformState(
      permission: map['permission'] as String? ?? 'unknown',
      exactAlarm: map['exactAlarm'] as String? ?? 'unknown',
      scheduledCount: (map['scheduledCount'] as num?)?.toInt() ?? 0,
      channel: map['channel'] as String? ?? 'unknown',
      blockedReason: map['blockedReason'] as String?,
    );
  }
}

/// A complete inbox read was interrupted by the native SQLite writer. The
/// caller may retry the whole read after the native channel has unwound its
/// transaction and closed its handle.
final class LocalNotificationStorageBusyException implements Exception {
  const LocalNotificationStorageBusyException([this.detail]);

  final String? detail;

  @override
  String toString() => detail == null
      ? 'LocalNotificationStorageBusyException'
      : 'LocalNotificationStorageBusyException($detail)';
}

abstract interface class LocalNotificationPlatform {
  /// Publishes a complete canonical projection through the native guarded
  /// writer.  Dart does not write the projection before this call, including
  /// for foreground Android runs.
  Future<LocalNotificationPlatformState> publishProjection({
    required Map<String, Object?> payload,
  });

  Future<List<Map<String, Object?>>> readInbox({String? identity});

  /// Legacy foreground reconciliation entrypoint retained for compatibility
  /// with pre-7.1 callers and tests. New runtime code uses [publishProjection].
  Future<LocalNotificationPlatformState> reconcile({
    required String databasePath,
    required NativeScopeState scope,
    required List<LocalNotificationPlan> plans,
  });

  Future<void> openExactAlarmSettings();
  Future<void> openNotificationSettings();
}

final localNotificationPlatformProvider = Provider<LocalNotificationPlatform>(
  (ref) => localNotificationPlatformFor(defaultTargetPlatform),
);

LocalNotificationPlatform localNotificationPlatformFor(
    TargetPlatform platform) {
  if (platform == TargetPlatform.android) {
    return const MethodChannelLocalNotificationPlatform();
  }
  return const UnsupportedLocalNotificationPlatform();
}

class UnsupportedLocalNotificationPlatform
    implements LocalNotificationPlatform {
  const UnsupportedLocalNotificationPlatform();

  @override
  Future<LocalNotificationPlatformState> publishProjection({
    required Map<String, Object?> payload,
  }) async =>
      const LocalNotificationPlatformState(
        permission: 'unsupported',
        exactAlarm: 'unsupported',
        scheduledCount: 0,
      );

  @override
  Future<List<Map<String, Object?>>> readInbox({String? identity}) async =>
      const [];

  @override
  Future<LocalNotificationPlatformState> reconcile({
    required String databasePath,
    required NativeScopeState scope,
    required List<LocalNotificationPlan> plans,
  }) async =>
      const LocalNotificationPlatformState(
        permission: 'unsupported',
        exactAlarm: 'unsupported',
        scheduledCount: 0,
      );

  @override
  Future<void> openExactAlarmSettings() async {}

  @override
  Future<void> openNotificationSettings() async {}
}

class MethodChannelLocalNotificationPlatform
    implements LocalNotificationPlatform {
  const MethodChannelLocalNotificationPlatform({
    MethodChannel channel = const MethodChannel(localNotificationChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<LocalNotificationPlatformState> publishProjection({
    required Map<String, Object?> payload,
  }) async {
    final value =
        await _channel.invokeMethod<Object?>('publishProjection', payload);
    if (value is! Map) {
      throw const FormatException('Invalid notification publication state.');
    }
    return LocalNotificationPlatformState.fromMap(
      Map<Object?, Object?>.from(value),
    );
  }

  @override
  Future<List<Map<String, Object?>>> readInbox({String? identity}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final value = await _channel.invokeMethod<Object?>(
          'readInbox',
          identity == null ? null : {'identity': identity},
        );
        if (value is! List) {
          throw const FormatException('Invalid notification inbox.');
        }
        return value
            .whereType<Map>()
            .map(
              (row) => Map<String, Object?>.from(row),
            )
            .toList(growable: false);
      } on PlatformException catch (error) {
        if (error.code != 'storage_busy') rethrow;
        if (attempt == 1) {
          throw LocalNotificationStorageBusyException(error.message);
        }
        // The native read has already closed its handle. Retry the complete
        // operation instead of replaying an individual SQL statement.
        await Future<void>.value();
      }
    }
    throw StateError('Notification inbox retry exhausted.');
  }

  @override
  Future<LocalNotificationPlatformState> reconcile({
    required String databasePath,
    required NativeScopeState scope,
    required List<LocalNotificationPlan> plans,
  }) async {
    final value = await _channel.invokeMethod<Object?>('reconcile', {
      'databasePath': databasePath,
      'regionId': scope.regionId,
      'ownerHash': scope.ownerHash,
      'activationToken': scope.activationToken,
      'generation': scope.generation,
      'plans': plans.map((p) => p.toJson()).toList(),
    });
    if (value is! Map) {
      throw const FormatException('Invalid notification state.');
    }
    return LocalNotificationPlatformState.fromMap(
        Map<Object?, Object?>.from(value));
  }

  @override
  Future<void> openExactAlarmSettings() =>
      _channel.invokeMethod<void>('openExactAlarmSettings');

  @override
  Future<void> openNotificationSettings() =>
      _channel.invokeMethod<void>('openNotificationSettings');
}
