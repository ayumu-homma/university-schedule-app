import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_controller.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/widget_bridge/application/widget_snapshot_repository.dart';
import 'package:university_schedule_mobile/features/widget_bridge/application/widget_snapshot_runtime.dart';

class _Schedule extends DemoAppController {
  @override
  Stream<DemoAppState> build() =>
      Stream.value(DemoAppState.empty(now: DateTime.utc(2026, 9, 19)));
}

class _Alarm extends MorningAlarmController {
  @override
  Future<MorningAlarmPlatformState> build() async => _value('other', 1);

  void publish(String owner, int generation) =>
      state = AsyncData(_value(owner, generation));

  void loading() => state =
      const AsyncLoading<MorningAlarmPlatformState>().copyWithPrevious(state);
}

MorningAlarmPlatformState _value(String owner, int generation) =>
    MorningAlarmPlatformState(
      ownerUserId: owner,
      settings: MorningAlarmSettings(ownerUserId: owner),
      capabilities: const MorningAlarmCapabilities.unavailable(),
      nextOccurrence: null,
      scope: NativeScopeState(
        regionId: 'test-region',
        ownerHash: sha256.convert(utf8.encode(owner)).toString(),
        activationToken: 'activation-$generation',
        generation: generation,
        active: true,
      ),
    );

class _Snapshots implements WidgetSnapshotRepository {
  final scopes = <NativeScopeState>[];
  @override
  Future<WidgetSnapshot?> readLatestSnapshot() async => null;
  @override
  Future<void> saveSnapshot(WidgetSnapshot snapshot,
          {NativeScopeState? scope}) async =>
      scopes.add(scope!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('widget waits for matching activation and skips loading previous scope',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final snapshots = _Snapshots();
    final container = ProviderContainer(overrides: [
      demoAppControllerProvider.overrideWith(_Schedule.new),
      morningAlarmControllerProvider.overrideWith(_Alarm.new),
      activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
      widgetSnapshotRepositoryProvider.overrideWithValue(snapshots),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(
        widgetSnapshotRuntimeProvider, (_, __) {},
        fireImmediately: true);
    addTearDown(subscription.close);
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    await settle();
    expect(snapshots.scopes, isEmpty);
    final alarm =
        container.read(morningAlarmControllerProvider.notifier) as _Alarm;
    alarm.publish(demoUserId, 2);
    await settle();
    expect(snapshots.scopes.map((s) => s.activationToken), ['activation-2']);
    alarm.loading();
    await settle();
    alarm.publish('other', 3);
    await settle();
    expect(snapshots.scopes, hasLength(1));
    alarm.publish(demoUserId, 4);
    await settle();
    expect(snapshots.scopes.map((s) => s.activationToken),
        ['activation-2', 'activation-4']);
  });
}
