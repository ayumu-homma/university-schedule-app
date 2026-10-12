import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_platform.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('in-memory platform cancels the old owner and isolates persisted state',
      () async {
    final platform = InMemoryMorningAlarmPlatform(
      now: () => JapanTime.at(
        year: 2026,
        month: 8,
        day: 10,
        hour: 6,
      ),
    );
    final ownerA = await platform.synchronizeOwner('owner-a');
    await platform.save(ownerA.settings!.copyWith(enabled: true, hour: 8));

    final ownerB = await platform.synchronizeOwner('owner-b');

    expect(platform.ownerCancellationCount, 1);
    expect(ownerB.settings!.enabled, isFalse);
    expect(ownerB.settings!.hour, 7);

    final restoredA = await platform.synchronizeOwner('owner-a');
    expect(platform.ownerCancellationCount, 2);
    expect(restoredA.settings!.enabled, isTrue);
    expect(restoredA.settings!.hour, 8);

    final signedOut = await platform.synchronizeOwner(null);
    expect(platform.ownerCancellationCount, 3);
    expect(signedOut.ownerUserId, isNull);
  });

  test('permission denial remains explicit until the request succeeds',
      () async {
    final platform = InMemoryMorningAlarmPlatform(
      capabilities: const MorningAlarmCapabilities(
        notificationPermission: AlarmPermissionStatus.denied,
        schedulePrecision: AlarmSchedulePrecision.inexact,
        fullScreenAllowed: false,
        debugTestAllowed: false,
      ),
    );
    final initial = await platform.synchronizeOwner('owner-a');
    expect(
      initial.capabilities.notificationPermission,
      AlarmPermissionStatus.denied,
    );

    final requested = await platform.requestNotificationPermission('owner-a');
    expect(
      requested.capabilities.notificationPermission,
      AlarmPermissionStatus.granted,
    );
    expect(
      requested.capabilities.schedulePrecision,
      AlarmSchedulePrecision.inexact,
    );
  });

  test('method channel sends strict owner-scoped settings and decodes state',
      () async {
    const channel = MethodChannel('morning_alarm_platform_test');
    const platform = MethodChannelMorningAlarmPlatform(channel: channel);
    const scope = NativeScopeState(
      regionId: 'region-a',
      ownerHash: 'owner-hash',
      activationToken: 'activation-7',
      generation: 7,
      active: true,
    );
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final ownerId = arguments['ownerId'] as String?;
      if (ownerId == null) return <String, Object?>{};
      return <String, Object?>{
        'settings': <String, Object?>{
          'version': 1,
          'enabled': arguments['enabled'] as bool? ?? false,
          'hour': arguments['hour'] as int? ?? 7,
          'minute': arguments['minute'] as int? ?? 30,
          'weekdays':
              arguments['weekdays'] as List<Object?>? ?? [1, 2, 3, 4, 5],
          'soundEnabled': arguments['soundEnabled'] as bool? ?? true,
          'vibrationEnabled': arguments['vibrationEnabled'] as bool? ?? true,
          'snoozeMinutes': arguments['snoozeMinutes'] as int? ?? 10,
          'openTodayOnStop': arguments['openTodayOnStop'] as bool? ?? true,
          'lockScreenPrivacy': arguments['lockScreenPrivacy'] as bool? ?? true,
        },
        'capabilities': <String, Object?>{
          'notificationPermission': 'granted',
          'schedulePrecision': 'exact',
          'fullScreenAllowed': true,
          'debugTestAllowed': true,
        },
        'nextOccurrenceEpochMillis': null,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await platform.synchronizeOwner('owner-a', expectedScope: scope);
    final saved = await platform.save(
      MorningAlarmSettings(ownerUserId: 'owner-a').copyWith(
        enabled: true,
        weekdays: {DateTime.saturday},
      ),
      expectedScope: scope,
    );

    expect(calls.map((call) => call.method), [
      'synchronizeOwner',
      'saveSettings',
    ]);
    expect(saved.settings!.enabled, isTrue);
    expect(saved.settings!.weekdays, {DateTime.saturday});
    for (final call in calls) {
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['expectedScopeRegionId'], scope.regionId);
      expect(arguments['expectedScopeOwnerHash'], scope.ownerHash);
      expect(arguments['expectedScopeActivationToken'], scope.activationToken);
      expect(arguments['expectedScopeGeneration'], scope.generation);
      expect(arguments['expectedScopeActive'], isTrue);
    }
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['ownerId'],
      'owner-a',
    );
  });
}
