import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

import '../../../core/native/native_scope_bridge.dart';
import '../../notification/application/morning_alarm_controller.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import 'widget_snapshot_repository.dart';

final widgetSnapshotRuntimeProvider =
    AsyncNotifierProvider<WidgetSnapshotRuntime, void>(
  WidgetSnapshotRuntime.new,
);

class WidgetSnapshotRuntime extends AsyncNotifier<void> {
  int _generation = 0;

  @override
  Future<void> build() async {
    final generation = ++_generation;
    ref.onDispose(() => _generation += 1);
    final schedule = ref.watch(demoAppControllerProvider);
    final alarmState = ref.watch(morningAlarmControllerProvider);
    if (schedule.isLoading || schedule.hasError || !schedule.hasValue) return;
    final snapshot = schedule.value?.widgetSnapshot;
    if (snapshot == null) return;
    final context = ref.watch(activeScheduleContextProvider);
    if (context == null) return;
    NativeScopeState? scope;
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (alarmState.isLoading || alarmState.hasError) return;
      scope = alarmState.valueOrNull?.scope ??
          await ref.read(nativeScopeBridgeProvider).current();
      if (!scope.matchesOwner(context.ownerUserId)) return;
    }
    if (generation != _generation) return;
    await ref.watch(widgetSnapshotRepositoryProvider).saveSnapshot(
          snapshot,
          scope: scope,
        );
  }
}
