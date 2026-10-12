import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/mvp_scaffold.dart';
import '../application/morning_alarm_controller.dart';
import '../application/local_notification_runtime.dart';
import '../application/local_notification_settings_controller.dart';
import '../application/local_notification_platform.dart';
import '../domain/local_notification_models.dart';
import '../domain/morning_alarm_models.dart';

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(morningAlarmControllerProvider.notifier).refresh(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final alarmState = ref.watch(morningAlarmControllerProvider);
    ref.listen(morningAlarmControllerProvider, (previous, next) {
      if (!next.hasError || previous?.error == next.error) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('朝の確認アラームを更新できませんでした。設定をご確認ください。'),
        ),
      );
    });
    return MvpScaffold(
      title: '通知',
      selectedIndex: 0,
      child: alarmState.when(
        skipLoadingOnReload: true,
        data: (state) => _AlarmSettingsContent(
          state: state,
          busy: alarmState.isLoading,
        ),
        loading: () => Center(
          child: Semantics(
            container: true,
            liveRegion: true,
            label: '朝の確認アラーム設定を読み込み中',
            child: const CircularProgressIndicator(),
          ),
        ),
        error: (_, __) => _AlarmLoadError(
          onRetry: () =>
              ref.read(morningAlarmControllerProvider.notifier).refresh(),
        ),
      ),
    );
  }
}

class _AlarmSettingsContent extends ConsumerWidget {
  const _AlarmSettingsContent({required this.state, required this.busy});

  final MorningAlarmPlatformState state;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = state.settings;
    if (settings == null) {
      return const Center(child: Text('ログインすると朝の確認アラームを設定できます。'));
    }
    final controller = ref.read(morningAlarmControllerProvider.notifier);
    return ListView(
      key: const Key('morning-alarm-settings-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            '朝の確認',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'その日の授業・課題・テストを、端末内の予定から確認します。'
          'アラームは初期状態ではOFFです。',
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                key: const Key('morning-alarm-enabled-switch'),
                value: settings.enabled,
                onChanged: busy
                    ? null
                    : (value) async {
                        if (value &&
                            state.capabilities.notificationPermission !=
                                AlarmPermissionStatus.granted &&
                            state.capabilities.notificationPermission !=
                                AlarmPermissionStatus.notRequired) {
                          final explained =
                              await _explainNotificationPermission(
                            context,
                          );
                          if (!explained || !context.mounted) return;
                          await controller.requestNotificationPermission();
                          if (!context.mounted) return;
                          final permission = ref
                              .read(morningAlarmControllerProvider)
                              .valueOrNull
                              ?.capabilities
                              .notificationPermission;
                          if (permission != AlarmPermissionStatus.granted &&
                              permission != AlarmPermissionStatus.notRequired) {
                            return;
                          }
                        }
                        await controller.updateSettings(
                          settings.copyWith(enabled: value),
                        );
                      },
                secondary: const Icon(Icons.alarm_outlined),
                title: const Text('朝の確認アラーム'),
                subtitle: Text(
                  settings.enabled
                      ? _nextOccurrenceLabel(state.nextOccurrence)
                      : 'OFF（端末のアラームは登録されていません）',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('morning-alarm-time-tile'),
                enabled: !busy,
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('時刻'),
                subtitle: Text(_timeLabel(settings.hour, settings.minute)),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () async {
                        final selected = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay(
                            hour: settings.hour,
                            minute: settings.minute,
                          ),
                          helpText: '朝の確認時刻',
                          cancelText: 'キャンセル',
                          confirmText: '設定',
                        );
                        if (selected == null || !context.mounted) return;
                        await controller.updateSettings(
                          settings.copyWith(
                            hour: selected.hour,
                            minute: selected.minute,
                          ),
                        );
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('曜日', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var weekday = DateTime.monday;
                weekday <= DateTime.sunday;
                weekday += 1)
              FilterChip(
                key: Key('morning-alarm-weekday-$weekday'),
                selected: settings.weekdays.contains(weekday),
                label: Text(_weekdayLabel(weekday)),
                onSelected: busy
                    ? null
                    : (selected) {
                        final weekdays = Set<int>.from(settings.weekdays);
                        selected
                            ? weekdays.add(weekday)
                            : weekdays.remove(weekday);
                        if (weekdays.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('曜日を1つ以上選んでください')),
                          );
                          return;
                        }
                        controller.updateSettings(
                          settings.copyWith(weekdays: weekdays),
                        );
                      },
              ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                value: settings.soundEnabled,
                onChanged: busy
                    ? null
                    : (value) => controller.updateSettings(
                          settings.copyWith(soundEnabled: value),
                        ),
                secondary: const Icon(Icons.volume_up_outlined),
                title: const Text('音'),
                subtitle: const Text('端末のアラーム音量は変更しません'),
              ),
              SwitchListTile(
                value: settings.vibrationEnabled,
                onChanged: busy
                    ? null
                    : (value) => controller.updateSettings(
                          settings.copyWith(vibrationEnabled: value),
                        ),
                secondary: const Icon(Icons.vibration_outlined),
                title: const Text('バイブレーション'),
              ),
              ListTile(
                leading: const Icon(Icons.snooze_outlined),
                title: const Text('スヌーズ'),
                trailing: DropdownButton<int>(
                  key: const Key('morning-alarm-snooze-dropdown'),
                  value: settings.snoozeMinutes,
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          controller.updateSettings(
                            settings.copyWith(snoozeMinutes: value),
                          );
                        },
                  items: const [
                    DropdownMenuItem(value: 5, child: Text('5分')),
                    DropdownMenuItem(value: 10, child: Text('10分')),
                    DropdownMenuItem(value: 15, child: Text('15分')),
                  ],
                ),
              ),
              SwitchListTile(
                value: settings.openTodayOnStop,
                onChanged: busy
                    ? null
                    : (value) => controller.updateSettings(
                          settings.copyWith(openTodayOnStop: value),
                        ),
                secondary: const Icon(Icons.today_outlined),
                title: const Text('停止後にTodayを開く'),
              ),
              SwitchListTile(
                value: settings.lockScreenPrivacy,
                onChanged: busy
                    ? null
                    : (value) => controller.updateSettings(
                          settings.copyWith(lockScreenPrivacy: value),
                        ),
                secondary: const Icon(Icons.lock_outline),
                title: const Text('ロック画面で詳細を隠す'),
                subtitle: const Text('通知には予定名や授業名を表示しません'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _CapabilityCard(
          state: state,
          busy: busy,
          onRequestNotifications: () async {
            final explained = await _explainNotificationPermission(context);
            if (explained) await controller.requestNotificationPermission();
          },
          onOpenExactSettings: () async {
            final explained = await _explainExactAlarmAccess(context);
            if (explained) await controller.openExactAlarmSettings();
          },
          onOpenFullScreenSettings: () async {
            final explained = await _explainFullScreenAccess(context);
            if (explained) await controller.openFullScreenSettings();
          },
        ),
        const SizedBox(height: 16),
        const _OrdinaryNotificationSettingsCard(),
        if (kDebugMode && state.capabilities.debugTestAllowed) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('morning-alarm-debug-test-button'),
            onPressed: busy
                ? null
                : () async {
                    await controller.scheduleDebugTest();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('約10秒後のテストを登録しました')),
                    );
                  },
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('10秒後にテスト（Debugのみ）'),
          ),
        ],
      ],
    );
  }
}

class _OrdinaryNotificationSettingsCard extends ConsumerWidget {
  const _OrdinaryNotificationSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localNotificationSettingsProvider);
    final platformState = ref.watch(localNotificationRuntimeProvider);
    return state.when(
      loading: () => const Card(child: ListTile(title: Text('予定通知を読み込み中'))),
      error: (_, __) =>
          const Card(child: ListTile(title: Text('予定通知を読み込めません'))),
      data: (settings) => Card(
        child: Column(
          children: [
            SwitchListTile(
              key: const Key('ordinary-notification-enabled-switch'),
              value: settings.enabled,
              onChanged: (value) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(enabled: value)),
              title: const Text('予定の通知'),
              subtitle: const Text('授業・課題・試験・予定を45日先まで登録します'),
              secondary: const Icon(Icons.notifications_outlined),
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('notification-inbox-tile'),
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('通知の受信箱'),
              subtitle: const Text('まとめて通知された予定も確認できます'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/notifications/inbox'),
            ),
            const Divider(height: 1),
            _OrdinaryToggle(
              label: '授業',
              value: settings.courseEnabled,
              onChanged: (value) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(courseEnabled: value)),
            ),
            _OrdinaryToggle(
              label: '課題',
              value: settings.assignmentEnabled,
              onChanged: (value) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(assignmentEnabled: value)),
            ),
            _OrdinaryToggle(
              label: '試験',
              value: settings.examEnabled,
              onChanged: (value) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(examEnabled: value)),
            ),
            _OrdinaryToggle(
              label: '予定・ルーティン',
              value: settings.eventEnabled || settings.routineEnabled,
              onChanged: (value) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(
                      eventEnabled: value, routineEnabled: value)),
            ),
            const Divider(height: 1),
            _OrdinaryReminderMinutesTile(
              key: const Key('ordinary-course-reminder'),
              label: '授業の通知時刻',
              minutes: settings.courseReminderMinutes,
              onChanged: (minutes) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(courseReminderMinutes: minutes)),
            ),
            _OrdinaryReminderMinutesTile(
              key: const Key('ordinary-assignment-reminder'),
              label: '課題の通知時刻',
              minutes: settings.assignmentReminderMinutes,
              onChanged: (minutes) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(assignmentReminderMinutes: minutes)),
            ),
            _OrdinaryReminderMinutesTile(
              key: const Key('ordinary-exam-reminder'),
              label: '試験の通知時刻',
              minutes: settings.examReminderMinutes,
              onChanged: (minutes) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(examReminderMinutes: minutes)),
            ),
            _OrdinaryReminderMinutesTile(
              key: const Key('ordinary-event-reminder'),
              label: '予定の通知時刻',
              minutes: settings.eventReminderMinutes,
              onChanged: (minutes) => ref
                  .read(localNotificationSettingsProvider.notifier)
                  .save(settings.copyWith(eventReminderMinutes: minutes)),
            ),
            ListTile(
              key: const Key('ordinary-exam-day-time'),
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text('試験当日の朝'),
              subtitle: Text(_ordinaryTimeLabel(
                settings.examDayHour,
                settings.examDayMinute,
              )),
              onTap: () async {
                final selected = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(
                    hour: settings.examDayHour,
                    minute: settings.examDayMinute,
                  ),
                  helpText: '試験当日の通知時刻',
                  cancelText: 'キャンセル',
                  confirmText: '設定',
                );
                if (selected == null || !context.mounted) return;
                await ref.read(localNotificationSettingsProvider.notifier).save(
                      settings.copyWith(
                        examDayHour: selected.hour,
                        examDayMinute: selected.minute,
                      ),
                    );
              },
            ),
            ListTile(
              key: const Key('ordinary-quiet-hours'),
              leading: const Icon(Icons.nights_stay_outlined),
              title: const Text('通知しない時間帯'),
              subtitle: Text(_quietHoursLabel(settings)),
              trailing: settings.quietStartMinutes == null &&
                      settings.quietEndMinutes == null
                  ? null
                  : IconButton(
                      tooltip: '解除',
                      icon: const Icon(Icons.clear),
                      onPressed: () => ref
                          .read(localNotificationSettingsProvider.notifier)
                          .save(settings.copyWith(clearQuietHours: true)),
                    ),
              onTap: () async {
                final start = await showTimePicker(
                  context: context,
                  initialTime: _timeOfDayFromMinutes(
                    settings.quietStartMinutes ?? (22 * 60),
                  ),
                  helpText: '通知停止の開始',
                  cancelText: 'キャンセル',
                  confirmText: '次へ',
                );
                if (start == null || !context.mounted) return;
                final end = await showTimePicker(
                  context: context,
                  initialTime: _timeOfDayFromMinutes(
                    settings.quietEndMinutes ?? (7 * 60),
                  ),
                  helpText: '通知停止の終了',
                  cancelText: 'キャンセル',
                  confirmText: '設定',
                );
                if (end == null || !context.mounted) return;
                await ref.read(localNotificationSettingsProvider.notifier).save(
                      settings.copyWith(
                        quietStartMinutes: start.hour * 60 + start.minute,
                        quietEndMinutes: end.hour * 60 + end.minute,
                      ),
                    );
              },
            ),
            _OrdinaryPlatformStatus(state: platformState),
            ListTile(
              leading: const Icon(Icons.lock_clock_outlined),
              title: const Text('正確なアラームの許可'),
              subtitle: const Text('許可がない場合は通知を登録せず、端末設定から再開できます'),
              onTap: () => ref
                  .read(localNotificationPlatformProvider)
                  .openExactAlarmSettings(),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('通知チャンネル・権限'),
              subtitle: const Text('通知を拒否した後やチャンネルを無効にした後に開きます'),
              onTap: () => ref
                  .read(localNotificationPlatformProvider)
                  .openNotificationSettings(),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrdinaryToggle extends StatelessWidget {
  const _OrdinaryToggle(
      {required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        value: value,
        onChanged: onChanged,
        title: Text(label),
      );
}

class _OrdinaryReminderMinutesTile extends StatelessWidget {
  const _OrdinaryReminderMinutesTile({
    required this.label,
    required this.minutes,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(label),
        subtitle: Text(_reminderMinutesLabel(minutes)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final value = await _showReminderMinutesDialog(context, minutes);
          if (value != null) onChanged(value);
        },
      );
}

class _OrdinaryPlatformStatus extends StatelessWidget {
  const _OrdinaryPlatformStatus({required this.state});

  final AsyncValue<LocalNotificationPlatformState> state;

  @override
  Widget build(BuildContext context) => state.when(
        loading: () => const ListTile(
          leading: Icon(Icons.sync),
          title: Text('予定通知の状態'),
          subtitle: Text('確認中'),
        ),
        error: (_, __) => const ListTile(
          leading: Icon(Icons.warning_amber_outlined),
          title: Text('予定通知の状態'),
          subtitle: Text('確認できません'),
        ),
        data: (value) {
          final blocked = value.blockedReason;
          final reason = blocked == null ? '登録可能' : _blockedLabel(blocked);
          return ListTile(
            key: const Key('ordinary-notification-platform-status'),
            leading: Icon(
              blocked == null
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
            ),
            title: const Text('端末の予定通知'),
            subtitle: Text(
              '$reason · 通知 ${_statusLabel(value.permission)} · '
              'チャンネル ${_statusLabel(value.channel)} · '
              '正確な時刻 ${_statusLabel(value.exactAlarm)} · '
              '予約時刻 ${value.scheduledCount}件',
            ),
          );
        },
      );
}

Future<int?> _showReminderMinutesDialog(BuildContext context, int current) {
  final controller = TextEditingController(text: '$current');
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('通知時刻（分）'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        decoration: const InputDecoration(
          hintText: '例: -10（10分前）',
          helperText: '0以下、最大7日前まで',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            final value = int.tryParse(controller.text.trim());
            if (value == null || value > 0 || value < -10080) return;
            Navigator.pop(dialogContext, value);
          },
          child: const Text('設定'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

String _reminderMinutesLabel(int value) {
  if (value == 0) return '開始時刻';
  final absolute = value.abs();
  if (absolute % (24 * 60) == 0) {
    return '${absolute ~/ (24 * 60)}日前';
  }
  if (absolute % 60 == 0) return '${absolute ~/ 60}時間前';
  return '$absolute分前';
}

String _quietHoursLabel(LocalNotificationSettingsValue settings) {
  final start = settings.quietStartMinutes;
  final end = settings.quietEndMinutes;
  if (start == null || end == null) return '設定なし';
  return '${_ordinaryTimeLabel(start ~/ 60, start % 60)}〜'
      '${_ordinaryTimeLabel(end ~/ 60, end % 60)}';
}

String _ordinaryTimeLabel(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

TimeOfDay _timeOfDayFromMinutes(int minutes) =>
    TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60);

String _statusLabel(String value) => switch (value) {
      'granted' || 'enabled' => '許可済み',
      'denied' || 'disabled' => '拒否/無効',
      'not_required' => '不要',
      'unsupported' => '非対応',
      _ => value,
    };

String _blockedLabel(String reason) => switch (reason) {
      'notification_permission' => '通知権限が必要',
      'notification_channel' => '通知チャンネルが無効',
      'exact_alarm_permission' => '正確なアラーム権限が必要',
      'scope_inactive' => 'アカウント切替中',
      'stale_projection' => '予定を再確認中',
      'source_busy' => '予定の更新が競合しています。再試行します',
      'storage_busy' => '予定データが使用中です。再試行します',
      _ => reason,
    };

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({
    required this.state,
    required this.busy,
    required this.onRequestNotifications,
    required this.onOpenExactSettings,
    required this.onOpenFullScreenSettings,
  });

  final MorningAlarmPlatformState state;
  final bool busy;
  final Future<void> Function() onRequestNotifications;
  final Future<void> Function() onOpenExactSettings;
  final Future<void> Function() onOpenFullScreenSettings;

  @override
  Widget build(BuildContext context) {
    final capabilities = state.capabilities;
    final notificationAllowed =
        capabilities.notificationPermission == AlarmPermissionStatus.granted ||
            capabilities.notificationPermission ==
                AlarmPermissionStatus.notRequired;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('端末の許可状態', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _CapabilityRow(
              key: const Key('morning-alarm-notification-capability'),
              icon: notificationAllowed
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              label: '通知',
              value: notificationAllowed ? '許可済み' : '許可が必要',
            ),
            if (!notificationAllowed)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : onRequestNotifications,
                  child: const Text('通知を許可'),
                ),
              ),
            _CapabilityRow(
              key: const Key('morning-alarm-precision-capability'),
              icon:
                  capabilities.schedulePrecision == AlarmSchedulePrecision.exact
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
              label: '時刻精度',
              value:
                  capabilities.schedulePrecision == AlarmSchedulePrecision.exact
                      ? '正確なアラーム'
                      : 'おおよその時刻（通知フォールバック）',
            ),
            if (capabilities.schedulePrecision ==
                AlarmSchedulePrecision.inexact)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : onOpenExactSettings,
                  child: const Text('正確なアラーム設定を開く'),
                ),
              ),
            _CapabilityRow(
              key: const Key('morning-alarm-full-screen-capability'),
              icon: capabilities.fullScreenAllowed
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
              label: '全画面表示',
              value: capabilities.fullScreenAllowed ? '利用可能' : '通常の高優先度通知を使用',
            ),
            if (!capabilities.fullScreenAllowed)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : onOpenFullScreenSettings,
                  child: const Text('全画面通知設定を開く'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
            Flexible(child: Text(value, textAlign: TextAlign.end)),
          ],
        ),
      ),
    );
  }
}

class _AlarmLoadError extends StatelessWidget {
  const _AlarmLoadError({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            const Text('朝の確認アラーム設定を読み込めませんでした'),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('再試行')),
          ],
        ),
      ),
    );
  }
}

Future<bool> _explainNotificationPermission(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('朝の予定を知らせるために'),
          content: const Text(
            '選んだ曜日と時刻に、停止・スヌーズ・Today確認ができる通知を表示します。'
            '予定の詳細は通知に含めません。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('あとで'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('続ける'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<bool> _explainExactAlarmAccess(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('指定時刻に近づけるために'),
          content: const Text(
            '「アラームとリマインダー」を許可すると、選んだ時刻により正確に通知できます。'
            '許可しなくても、おおよその時刻の通知は利用できます。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('このまま使う'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('端末設定へ'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<bool> _explainFullScreenAccess(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('ロック画面から操作するために'),
          content: const Text(
            '全画面通知を許可すると、設定した朝のアラームで停止・スヌーズをすぐ操作できます。'
            '許可しなくても、高優先度通知から同じ操作ができます。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('通常通知を使う'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('端末設定へ'),
            ),
          ],
        ),
      ) ??
      false;
}

String _timeLabel(int hour, int minute) => '${hour.toString().padLeft(2, '0')}:'
    '${minute.toString().padLeft(2, '0')}';

String _weekdayLabel(int weekday) => switch (weekday) {
      DateTime.monday => '月',
      DateTime.tuesday => '火',
      DateTime.wednesday => '水',
      DateTime.thursday => '木',
      DateTime.friday => '金',
      DateTime.saturday => '土',
      DateTime.sunday => '日',
      _ => '?',
    };

String _nextOccurrenceLabel(DateTime? occurrence) {
  if (occurrence == null) return '次回時刻を計算できません';
  final civil = JapanTime.civil(occurrence);
  return '次回 ${civil.month}/${civil.day}（${_weekdayLabel(civil.weekday)}） '
      '${_timeLabel(civil.hour, civil.minute)}';
}
