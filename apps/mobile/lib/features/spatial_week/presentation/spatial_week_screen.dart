import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../application/spatial_week_flag.dart';
import '../application/spatial_week_projection.dart';
import '../domain/spatial_week_models.dart';
import 'spatial_week_canvas.dart';
import 'spatial_week_geometry.dart';

/// Read-only, opt-in 2.5D view over the same local schedule projection.
class SpatialWeekScreen extends ConsumerWidget {
  const SpatialWeekScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep ordinary builds entirely outside the experimental providers.
    if (!ref.watch(spatialWeekEnabledProvider)) {
      return MvpScaffold(
        title: '今週の空間ビュー',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('この実験ビューは現在利用できません。'),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('spatial-disabled-return'),
                  onPressed: () => context.go('/timetable'),
                  child: const Text('時間割へ戻る'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const _SpatialWeekRoute();
  }
}

class _SpatialWeekRoute extends ConsumerWidget {
  const _SpatialWeekRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduleContext = ref.watch(activeScheduleContextProvider);
    if (scheduleContext == null) {
      return MvpScaffold(
        title: '今週の空間ビュー',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: '認証状態を確認中',
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    final contextKey = spatialContextKey(scheduleContext);
    return _SpatialWeekContent(
      key: ValueKey<String>(contextKey),
      scheduleContext: scheduleContext,
    );
  }
}

class _SpatialWeekContent extends ConsumerStatefulWidget {
  const _SpatialWeekContent({required this.scheduleContext, super.key});

  final ActiveScheduleContext scheduleContext;

  @override
  ConsumerState<_SpatialWeekContent> createState() =>
      _SpatialWeekContentState();
}

class _SpatialWeekContentState extends ConsumerState<_SpatialWeekContent> {
  SpatialCamera _camera = const SpatialCamera();
  String? _selectedEntryKey;
  bool _flat = true;
  bool _listOnly = false;

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    final now = ref.watch(appClockProvider).now();

    if (asyncState.isLoading) {
      return MvpScaffold(
        title: '今週の空間ビュー',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: '時間割を読み込み中',
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (asyncState.hasError) {
      return MvpScaffold(
        title: '今週の空間ビュー',
        selectedIndex: 1,
        showQuickAdd: false,
        child: EmptyState(
          key: const Key('spatial-week-load-error'),
          icon: Icons.error_outline,
          title: '時間割を読み込めませんでした',
          message: '時間をおいてもう一度お試しください。',
          action: FilledButton.icon(
            onPressed: () => ref.invalidate(demoAppControllerProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('再読み込み'),
          ),
        ),
      );
    }
    final state = asyncState.valueOrNull;
    if (state == null) {
      return const MvpScaffold(
        title: '今週の空間ビュー',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final snapshot = buildSpatialWeekSnapshot(
      state: state,
      context: widget.scheduleContext,
      now: now,
    );
    final selected = _entryForKey(snapshot.entries, _selectedEntryKey);
    if (_selectedEntryKey != null && selected == null) {
      final staleKey = _selectedEntryKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedEntryKey == staleKey) {
          setState(() => _selectedEntryKey = null);
        }
      });
    }

    return MvpScaffold(
      title: '今週の空間ビュー',
      selectedIndex: 1,
      showQuickAdd: false,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: const Key('spatial-page-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      '2.5D 空間ビュー（実験）',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '今週の予定を曜日と時刻で表示します。奥行きは情報を表しません。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        key: const Key('spatial-mode-2d'),
                        label: const Text('2D'),
                        selected: _flat,
                        onSelected: (_) => setState(() => _flat = true),
                      ),
                      ChoiceChip(
                        key: const Key('spatial-mode-depth'),
                        label: const Text('空間'),
                        selected: !_flat,
                        onSelected: (_) => setState(() => _flat = false),
                      ),
                      FilterChip(
                        key: const Key('spatial-list-only'),
                        label: const Text('リストのみ（軽量表示）'),
                        selected: _listOnly,
                        onSelected: (value) =>
                            setState(() => _listOnly = value),
                      ),
                    ],
                  ),
                  if (!_listOnly) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _cameraButton(
                          key: const Key('spatial-turn-left'),
                          label: '左に回転',
                          icon: Icons.rotate_left,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(yaw: _camera.yaw - 0.18),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-turn-right'),
                          label: '右に回転',
                          icon: Icons.rotate_right,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(yaw: _camera.yaw + 0.18),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-tilt-up'),
                          label: '上に傾ける',
                          icon: Icons.keyboard_arrow_up,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(pitch: _camera.pitch - 0.1),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-tilt-down'),
                          label: '下に傾ける',
                          icon: Icons.keyboard_arrow_down,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(pitch: _camera.pitch + 0.1),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-zoom-out'),
                          label: '縮小',
                          icon: Icons.zoom_out,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(zoom: _camera.zoom * 0.88),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-zoom-in'),
                          label: '拡大',
                          icon: Icons.zoom_in,
                          onPressed: () => _changeCamera(
                            _camera.copyWith(zoom: _camera.zoom * 1.14),
                          ),
                        ),
                        _cameraButton(
                          key: const Key('spatial-reset'),
                          label: '視点をリセット',
                          icon: Icons.restart_alt,
                          onPressed: () => _changeCamera(const SpatialCamera()),
                        ),
                        OutlinedButton.icon(
                          key: const Key('spatial-return-2d'),
                          onPressed: () => setState(() => _flat = true),
                          icon: const Icon(Icons.view_agenda_outlined),
                          label: const Text('2Dに戻る'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: constraints.maxWidth < 400 ? 300 : 360,
                      child: SpatialWeekCanvas(
                        key: const Key('spatial-week-canvas'),
                        entries: snapshot.entries,
                        camera: _camera,
                        onCameraChanged: _onCanvasCameraChanged,
                        onSelectEntry: _onCanvasSelect,
                        selectedEntryKey: selected?.key,
                        flat: _flat,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _WeekSummary(snapshot: snapshot),
                  const SizedBox(height: 12),
                  if (selected != null) ...[
                    _SelectedEntryCard(
                      entry: selected,
                      onOpen: () => _openEntry(selected),
                      onClear: () => _clearSelection(selected.key),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (snapshot.entries.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('今週の予定はありません。'),
                      ),
                    )
                  else
                    ...snapshot.entries.map(
                      (entry) => _SpatialEntryTile(
                        semanticsKey:
                            ValueKey<String>('spatial-entry-${entry.key}'),
                        entry: entry,
                        selected: selected?.key == entry.key,
                        onTap: () => _selectEntry(entry.key),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cameraButton({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) =>
      SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          key: key,
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );

  void _changeCamera(SpatialCamera camera) {
    if (!_contextIsCurrent()) return;
    setState(() => _camera = camera);
  }

  void _onCanvasCameraChanged(SpatialCamera camera) {
    if (!_contextIsCurrent()) return;
    setState(() => _camera = camera);
  }

  void _onCanvasSelect(String? key) {
    if (key == null || !_contextIsCurrent()) return;
    final latest = _freshSnapshot();
    if (latest == null || _entryForKey(latest.entries, key) == null) return;
    setState(() => _selectedEntryKey = key);
  }

  void _selectEntry(String key) {
    if (!_contextIsCurrent()) return;
    final latest = _freshSnapshot();
    if (latest == null || _entryForKey(latest.entries, key) == null) return;
    setState(() => _selectedEntryKey = key);
  }

  void _openEntry(SpatialWeekEntry entry) {
    if (!_contextIsCurrent()) return;
    final latest = _freshSnapshot();
    if (latest == null || _entryForKey(latest.entries, entry.key) == null) {
      return;
    }
    context.push(entry.detailRoute);
  }

  void _clearSelection(String entryKey) {
    if (!_contextIsCurrent()) return;
    final latest = _freshSnapshot();
    if (latest == null || _entryForKey(latest.entries, entryKey) == null) {
      return;
    }
    setState(() => _selectedEntryKey = null);
  }

  bool _contextIsCurrent() => _sameContext(
        mounted ? ref.read(activeScheduleContextProvider) : null,
        widget.scheduleContext,
      );

  SpatialWeekSnapshot? _freshSnapshot() {
    if (!mounted) return null;
    if (!_contextIsCurrent()) return null;
    final latestState = ref.read(demoAppControllerProvider);
    if (latestState.isLoading || latestState.hasError) return null;
    final state = latestState.valueOrNull;
    if (state == null) return null;
    final snapshot = buildSpatialWeekSnapshot(
      state: state,
      context: widget.scheduleContext,
      now: ref.read(appClockProvider).now(),
    );
    return snapshot.contextKey == spatialContextKey(widget.scheduleContext)
        ? snapshot
        : null;
  }
}

class _WeekSummary extends StatelessWidget {
  const _WeekSummary({required this.snapshot});

  final SpatialWeekSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final monday = JapanTime.civil(snapshot.weekStart);
    final sunday = DateTime.utc(monday.year, monday.month, monday.day)
        .add(const Duration(days: 6));
    return Semantics(
      label: '今週。配置済み${snapshot.placedCount}件、リストのみ${snapshot.unplacedCount}件',
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          Chip(
              label: Text(
                  '${monday.month}/${monday.day}–${sunday.month}/${sunday.day}')),
          Chip(label: Text('配置済み ${snapshot.placedCount}件')),
          Chip(label: Text('リストのみ ${snapshot.unplacedCount}件')),
        ],
      ),
    );
  }
}

class _SelectedEntryCard extends StatelessWidget {
  const _SelectedEntryCard({
    required this.entry,
    required this.onOpen,
    required this.onClear,
  });

  final SpatialWeekEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('spatial-selected-detail'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_kindLabel(entry.kind),
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(entry.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_entryTimeLabel(entry)),
            if ((entry.location ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('場所: ${entry.location!.trim()}'),
            ],
            if (entry.unplacedReason != null) ...[
              const SizedBox(height: 4),
              Text(_unplacedLabel(entry.unplacedReason!)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('spatial-open-detail'),
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('詳細を開く'),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: TextButton.icon(
                key: const Key('spatial-clear-selection'),
                onPressed: onClear,
                icon: const Icon(Icons.close),
                label: const Text('選択を解除'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpatialEntryTile extends StatelessWidget {
  const _SpatialEntryTile({
    required this.semanticsKey,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final Key semanticsKey;
  final SpatialWeekEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = entry.isDeadline
        ? '締切'
        : entry.isPlaced
            ? '配置済み'
            : 'リストのみ';
    return Card(
      color: selected ? theme.colorScheme.secondaryContainer : null,
      child: Semantics(
        key: semanticsKey,
        selected: selected,
        button: true,
        onTap: onTap,
        label: _entrySemanticsLabel(entry, status),
        child: ExcludeSemantics(
          child: ListTile(
            onTap: onTap,
            title: Text(entry.title),
            subtitle: Text(_entryTileDetail(entry)),
            trailing: Icon(_kindIcon(entry.kind),
                semanticLabel: _kindLabel(entry.kind)),
          ),
        ),
      ),
    );
  }
}

SpatialWeekEntry? _entryForKey(List<SpatialWeekEntry> entries, String? key) {
  if (key == null) return null;
  for (final entry in entries) {
    if (entry.key == key) return entry;
  }
  return null;
}

bool _sameContext(
  ActiveScheduleContext? active,
  ActiveScheduleContext captured,
) =>
    active?.ownerUserId == captured.ownerUserId &&
    active?.universityId == captured.universityId &&
    active?.termId == captured.termId &&
    active?.academicYear == captured.academicYear &&
    active?.primaryCalendarId == captured.primaryCalendarId;

String _entryTileDetail(SpatialWeekEntry entry) {
  final details = <String>[_kindLabel(entry.kind), _entryTimeLabel(entry)];
  if ((entry.location ?? '').trim().isNotEmpty) {
    details.add(entry.location!.trim());
  }
  if (entry.unplacedReason != null) {
    details.add(_unplacedLabel(entry.unplacedReason!));
  }
  return details.join(' · ');
}

String _entrySemanticsLabel(SpatialWeekEntry entry, String status) {
  final details = <String>[
    _kindLabel(entry.kind),
    status,
    entry.title,
    _entryTimeLabel(entry),
  ];
  if ((entry.location ?? '').trim().isNotEmpty) {
    details.add('場所: ${entry.location!.trim()}');
  }
  if (entry.unplacedReason != null) {
    details.add(_unplacedLabel(entry.unplacedReason!));
  }
  return details.join('、');
}

String _entryTimeLabel(SpatialWeekEntry entry) {
  if (entry.isAllDay && entry.startAt != null) {
    final startCivil = JapanTime.civil(entry.startAt!);
    final end = entry.endAt;
    if (end == null || !end.isAfter(entry.startAt!)) {
      return '終日 · ${_dateLabel(startCivil.month, startCivil.day)}';
    }
    final lastCivil =
        JapanTime.civil(end.subtract(const Duration(microseconds: 1)));
    final startLabel = _dateLabel(startCivil.month, startCivil.day);
    final endLabel = _dateLabel(lastCivil.month, lastCivil.day);
    final sameCivilDay = startCivil.year == lastCivil.year &&
        startCivil.month == lastCivil.month &&
        startCivil.day == lastCivil.day;
    return '終日 · $startLabel${sameCivilDay ? '' : '–$endLabel（終了日を含む）'}';
  }
  final start = entry.startAt;
  if (start == null) return entry.isDeadline ? '締切時刻なし' : '時刻未設定';
  final localStart = JapanTime.civil(start);
  final date = '${localStart.month}/${localStart.day}';
  if (entry.isDeadline) {
    return '$date ${_clockLabel(localStart.hour, localStart.minute)} · 締切';
  }
  final end = entry.endAt;
  if (end == null) {
    return '$date ${_clockLabel(localStart.hour, localStart.minute)}';
  }
  final localEnd = JapanTime.civil(end);
  final endDate = localEnd.year == localStart.year &&
          localEnd.month == localStart.month &&
          localEnd.day == localStart.day
      ? ''
      : '${localEnd.month}/${localEnd.day} ';
  return '$date ${_clockLabel(localStart.hour, localStart.minute)}–$endDate${_clockLabel(localEnd.hour, localEnd.minute)}';
}

String _dateLabel(int month, int day) => '$month/$day';

String _clockLabel(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

String _unplacedLabel(String reason) => switch (reason) {
      'all_day' => '終日のため一覧で表示',
      'missing_period_time' => '時限の時刻が未設定のため一覧で表示',
      'unknown_weekday' => '曜日が未設定のため一覧で表示',
      'unknown_period' => '時限が未設定のため一覧で表示',
      'invalid_period_time' => '時刻を確認できないため一覧で表示',
      _ => '時間軸に配置せず一覧で表示',
    };

String _kindLabel(SpatialEntryKind kind) => switch (kind) {
      SpatialEntryKind.course => '授業',
      SpatialEntryKind.event => '予定',
      SpatialEntryKind.routine => 'ルーティン',
      SpatialEntryKind.assignment => '課題',
      SpatialEntryKind.exam => '試験',
    };

IconData _kindIcon(SpatialEntryKind kind) => switch (kind) {
      SpatialEntryKind.course => Icons.school_outlined,
      SpatialEntryKind.event => Icons.event_outlined,
      SpatialEntryKind.routine => Icons.repeat,
      SpatialEntryKind.assignment => Icons.assignment_outlined,
      SpatialEntryKind.exam => Icons.quiz_outlined,
    };
