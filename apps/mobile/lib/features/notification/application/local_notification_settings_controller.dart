import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../timetable/data/local_schedule_repository.dart';
import '../data/local_notification_store.dart';
import '../domain/local_notification_models.dart';
import 'local_notification_runtime.dart';

final localNotificationSettingsProvider = AsyncNotifierProvider<
    LocalNotificationSettingsController, LocalNotificationSettingsValue>(
  LocalNotificationSettingsController.new,
);

class LocalNotificationSettingsController
    extends AsyncNotifier<LocalNotificationSettingsValue> {
  @override
  Future<LocalNotificationSettingsValue> build() async {
    final context = ref.watch(activeScheduleContextProvider);
    if (context == null) return const LocalNotificationSettingsValue();
    return LocalNotificationStore(ref.read(appDatabaseProvider))
        .settingsFor(context.ownerUserId);
  }

  Future<void> save(LocalNotificationSettingsValue value) async {
    final context = ref.read(activeScheduleContextProvider);
    if (context == null) return;
    state = AsyncData(value);
    await LocalNotificationStore(ref.read(appDatabaseProvider))
        .saveSettings(context.ownerUserId, value);
    ref.invalidate(localNotificationRuntimeProvider);
  }
}
