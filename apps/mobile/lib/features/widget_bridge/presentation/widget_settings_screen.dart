import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/mvp_scaffold.dart';
import '../../timetable/application/demo_app_controller.dart';

class WidgetSettingsScreen extends ConsumerStatefulWidget {
  const WidgetSettingsScreen({super.key});

  @override
  ConsumerState<WidgetSettingsScreen> createState() =>
      _WidgetSettingsScreenState();
}

class _WidgetSettingsScreenState extends ConsumerState<WidgetSettingsScreen> {
  WidgetPrivacyMode _mode = WidgetPrivacyMode.titleAndRoom;

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) => _WidgetSettingsContent(
        snapshot: state.widgetSnapshot,
        mode: _mode,
        onModeChanged: (mode) => setState(() => _mode = mode),
        onRegenerate: () {
          ref.read(demoAppControllerProvider.notifier).regenerateWidgetSnapshot(
                WidgetSnapshotSettings(
                  privacyMode: _mode,
                ),
              );
        },
      ),
      loading: () => const MvpScaffold(
        title: 'ウィジェット',
        selectedIndex: 1,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: 'ウィジェット',
        selectedIndex: 1,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }
}

class _WidgetSettingsContent extends StatelessWidget {
  const _WidgetSettingsContent({
    required this.snapshot,
    required this.mode,
    required this.onModeChanged,
    required this.onRegenerate,
  });

  final WidgetSnapshot snapshot;
  final WidgetPrivacyMode mode;
  final ValueChanged<WidgetPrivacyMode> onModeChanged;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    return MvpScaffold(
      title: 'ウィジェット',
      selectedIndex: 1,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(
            leading: Icon(Icons.calendar_view_week_outlined),
            title: Text('月〜金・1〜5限'),
            subtitle: Text('発表用ウィジェットは固定の週間グリッドです'),
          ),
          SegmentedButton<WidgetPrivacyMode>(
            segments: const [
              ButtonSegment(
                  value: WidgetPrivacyMode.title, label: Text('タイトル')),
              ButtonSegment(
                  value: WidgetPrivacyMode.titleAndRoom, label: Text('教室')),
              ButtonSegment(
                  value: WidgetPrivacyMode.busyOnly, label: Text('非公開')),
            ],
            selected: {mode},
            onSelectionChanged: (value) => onModeChanged(value.first),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRegenerate,
            icon: const Icon(Icons.refresh),
            label: const Text('Androidウィジェットを更新'),
          ),
          const SizedBox(height: 16),
          Text('生成時刻: ${snapshot.generatedAt.toIso8601String()}'),
          const SizedBox(height: 8),
          for (final cell
              in snapshot.cells.where((cell) => cell.courseId != null))
            ListTile(
              leading: const Icon(Icons.widgets_outlined),
              title: Text(
                  '${_weekdayLabel(cell.weekday)} ${cell.periodNo}限 ${cell.title ?? ''}'),
              subtitle: Text(cell.deepLink ?? ''),
            ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.android),
            title: Text('ホーム画面に追加できます'),
            subtitle: Text('ホーム画面を長押しし、ウィジェットから「Uni Schedule」を選択してください'),
          ),
        ],
      ),
    );
  }

  String _weekdayLabel(int weekday) {
    return const {
          DateTime.monday: '月曜',
          DateTime.tuesday: '火曜',
          DateTime.wednesday: '水曜',
          DateTime.thursday: '木曜',
          DateTime.friday: '金曜',
        }[weekday] ??
        '$weekday曜';
  }
}
