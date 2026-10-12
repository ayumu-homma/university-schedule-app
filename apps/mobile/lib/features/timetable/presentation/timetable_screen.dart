import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../application/demo_app_controller.dart';

enum _TimetableView { day, week }

class TimetableScreen extends ConsumerWidget {
  const TimetableScreen({super.key});

  static const weekdays = [1, 2, 3, 4, 5];
  static const periods = [1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(demoAppControllerProvider);
    final initialWeekday = _initialTimetableWeekday(
      ref.watch(appClockProvider).now(),
    );
    return asyncState.when(
      data: (state) => _TimetableContent(
        state: state,
        initialWeekday: initialWeekday,
      ),
      loading: () => const MvpScaffold(
        title: '時間割',
        selectedIndex: 1,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const MvpScaffold(
        title: '時間割',
        selectedIndex: 1,
        child: EmptyState(
          key: Key('timetable-load-error'),
          icon: Icons.error_outline,
          title: '時間割を読み込めませんでした',
          message: '時間をおいてもう一度お試しください。',
        ),
      ),
    );
  }
}

class _TimetableContent extends ConsumerStatefulWidget {
  const _TimetableContent({
    required this.state,
    required this.initialWeekday,
  });

  final DemoAppState state;
  final int initialWeekday;

  @override
  ConsumerState<_TimetableContent> createState() => _TimetableContentState();
}

class _TimetableContentState extends ConsumerState<_TimetableContent> {
  _TimetableView _view = _TimetableView.day;
  late int _selectedWeekday;

  @override
  void initState() {
    super.initState();
    _selectedWeekday = widget.initialWeekday;
  }

  DemoAppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return MvpScaffold(
      title: '時間割',
      selectedIndex: 1,
      actions: [
        IconButton(
          tooltip: '時限・学期設定',
          onPressed: () => context.go('/university/term-periods'),
          icon: const Icon(Icons.schedule_outlined),
        ),
        IconButton(
          tooltip: 'ウィジェット設定',
          onPressed: () => context.go('/widgets'),
          icon: const Icon(Icons.widgets_outlined),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontalPadding = constraints.maxWidth >= 840 ? 32.0 : 16.0;
          return ListView(
            key: const Key('timetable-vertical-scroll'),
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              16,
              horizontalPadding,
              160,
            ),
            children: [
              _TimetableViewControl(
                value: _view,
                onChanged: (value) => setState(() => _view = value),
              ),
              const SizedBox(height: 16),
              if (_view == _TimetableView.day) ...[
                _WeekdayPicker(
                  selectedWeekday: _selectedWeekday,
                  onChanged: (weekday) =>
                      setState(() => _selectedWeekday = weekday),
                ),
                const SizedBox(height: 16),
                _DayTimetable(
                  state: state,
                  weekday: _selectedWeekday,
                  onManage: (course) => _showCourseActions(course),
                ),
              ] else
                _WeekTimetable(
                  state: state,
                  onManage: (course) => _showCourseActions(course),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showCourseActions(UserCourse course) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.open_in_new_outlined),
              title: const Text('詳細を見る'),
              onTap: () => Navigator.pop(context, 'detail'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('編集'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '削除',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'detail') {
      context.go('/course/${course.id}');
      return;
    }
    if (action == 'edit') {
      context.go('/course/${course.id}/edit');
      return;
    }
    if (action != 'delete') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('授業を削除しますか？'),
        content: const Text('紐づく課題・テストの履歴は残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(demoAppControllerProvider.notifier)
        .deleteUserCourse(course.id, course.version);
  }
}

int _initialTimetableWeekday(DateTime now) {
  final weekday = JapanTime.civil(now).weekday;
  return weekday >= DateTime.monday && weekday <= DateTime.friday
      ? weekday
      : DateTime.monday;
}

class _TimetableViewControl extends StatelessWidget {
  const _TimetableViewControl({
    required this.value,
    required this.onChanged,
  });

  final _TimetableView value;
  final ValueChanged<_TimetableView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_TimetableView>(
        key: const Key('timetable-view-control'),
        segments: const [
          ButtonSegment(
            value: _TimetableView.day,
            icon: Icon(Icons.view_day_outlined),
            label: Text('日ごと'),
          ),
          ButtonSegment(
            value: _TimetableView.week,
            icon: Icon(Icons.calendar_view_week_outlined),
            label: Text('週全体'),
          ),
        ],
        selected: {value},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onChanged(selection.single),
      ),
    );
  }
}

class _WeekdayPicker extends StatelessWidget {
  const _WeekdayPicker({
    required this.selectedWeekday,
    required this.onChanged,
  });

  final int selectedWeekday;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '表示する曜日',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final weekday in TimetableScreen.weekdays)
            ChoiceChip(
              key: ValueKey('timetable-day-$weekday'),
              label: Text(_weekdayLabel(weekday)),
              selected: weekday == selectedWeekday,
              onSelected: (_) => onChanged(weekday),
            ),
        ],
      ),
    );
  }
}

class _DayTimetable extends StatelessWidget {
  const _DayTimetable({
    required this.state,
    required this.weekday,
    required this.onManage,
  });

  final DemoAppState state;
  final int weekday;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('timetable-day-view'),
      children: [
        for (final period in TimetableScreen.periods) ...[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 76,
                  child: _PeriodLabel(
                    period: period,
                    setting: _periodSetting(state, weekday, period),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DayCourseCell(
                    weekday: weekday,
                    period: period,
                    course: _courseAt(state.courses, weekday, period),
                    counts: _countsAt(state, weekday, period),
                    onManage: onManage,
                  ),
                ),
              ],
            ),
          ),
          if (period != TimetableScreen.periods.last)
            const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _WeekTimetable extends StatelessWidget {
  const _WeekTimetable({required this.state, required this.onManage});

  final DemoAppState state;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const periodWidth = 54.0;
        const gap = 4.0;
        final cellWidth = (constraints.maxWidth - periodWidth - (gap * 5)) / 5;
        return Column(
          key: const Key('timetable-week-view'),
          children: [
            Row(
              children: [
                const SizedBox(width: periodWidth),
                for (final weekday in TimetableScreen.weekdays) ...[
                  const SizedBox(width: gap),
                  SizedBox(
                    width: cellWidth,
                    height: 48,
                    child: Center(
                      child: Text(
                        _weekdayLabel(weekday),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            for (final period in TimetableScreen.periods) ...[
              const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: periodWidth,
                      child: _PeriodLabel(
                        period: period,
                        setting: _periodSetting(state, null, period),
                        compact: true,
                      ),
                    ),
                    for (final weekday in TimetableScreen.weekdays) ...[
                      const SizedBox(width: gap),
                      SizedBox(
                        width: cellWidth,
                        child: _WeekCourseCell(
                          cellWidth: cellWidth,
                          weekday: weekday,
                          period: period,
                          course: _courseAt(state.courses, weekday, period),
                          counts: _countsAt(state, weekday, period),
                          onManage: onManage,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PeriodLabel extends StatelessWidget {
  const _PeriodLabel({
    required this.period,
    required this.setting,
    this.compact = false,
  });

  final int period;
  final PeriodSetting? setting;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final times = setting == null
        ? _fallbackPeriodTimes[period]!
        : (
            _formatMinutes(setting!.startTimeMinutes),
            _formatMinutes(setting!.endTimeMinutes),
          );
    return Semantics(
      label: '$period限 ${times.$1}から${times.$2}',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$period限', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              compact
                  ? '${times.$1}\n${times.$2}'
                  : '${times.$1}\n〜 ${times.$2}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCourseCell extends StatelessWidget {
  const _DayCourseCell({
    required this.weekday,
    required this.period,
    required this.course,
    required this.counts,
    required this.onManage,
  });

  final int weekday;
  final int period;
  final UserCourse? course;
  final _CourseCounts counts;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    final current = course;
    if (current == null) {
      return _EmptyCourseCell(weekday: weekday, period: period, minHeight: 96);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        key: ValueKey('course-cell-${current.id}'),
        onTap: () => context.go('/course/${current.id}'),
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 112),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: current.title,
                        child: Text(
                          current.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if ((current.room ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          current.room!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (counts.assignments > 0)
                            _CountBadge(
                              icon: Icons.assignment_outlined,
                              label: '課題 ${counts.assignments}',
                            ),
                          if (counts.exams > 0)
                            _CountBadge(
                              icon: Icons.quiz_outlined,
                              label: '試験 ${counts.exams}',
                            ),
                          PrivacyBadge(level: current.visibilityLevel),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '${current.title}の操作',
                  onPressed: () => onManage(current),
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WeekCourseCell extends StatelessWidget {
  const _WeekCourseCell({
    required this.cellWidth,
    required this.weekday,
    required this.period,
    required this.course,
    required this.counts,
    required this.onManage,
  });

  final double cellWidth;
  final int weekday;
  final int period;
  final UserCourse? course;
  final _CourseCounts counts;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    final current = course;
    if (current == null) {
      return _EmptyCourseCell(weekday: weekday, period: period, minHeight: 124);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = colorScheme.onPrimaryContainer;
    final room = current.room?.trim();

    Widget countLabel({TextAlign textAlign = TextAlign.start}) => Semantics(
          label: '課題${counts.assignments}件、試験${counts.exams}件',
          child: Text(
            '● ${counts.total}',
            textAlign: textAlign,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: foreground),
          ),
        );

    Widget menuButton() => IconButton(
          tooltip: '${current.title}の操作',
          onPressed: () => onManage(current),
          constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
          style: IconButton.styleFrom(foregroundColor: foreground),
          icon: const Icon(Icons.more_horiz, size: 20),
        );

    final roomLabel = Text(
      room ?? '',
      key: ValueKey('week-course-room-${current.id}'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontSize: 11,
            letterSpacing: 0,
          ),
    );
    final compactRoomNumber =
        room != null && RegExp(r'^[0-9A-Za-z・.\-\s]{1,8}$').hasMatch(room);

    return Material(
      color: colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('week-course-cell-${current.id}'),
        onTap: () => context.go('/course/${current.id}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 124),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Tooltip(
                  message: current.title,
                  child: Text(
                    current.title,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: foreground,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                const Spacer(),
                if (cellWidth - 8 < 88)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (counts.total > 0)
                        countLabel(textAlign: TextAlign.center),
                      Center(child: menuButton()),
                    ],
                  )
                else
                  Row(
                    children: [
                      if (counts.total > 0)
                        Expanded(child: countLabel())
                      else
                        const Spacer(),
                      menuButton(),
                    ],
                  ),
                if (room != null && room.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  DecoratedBox(
                    key: ValueKey('week-course-room-pill-${current.id}'),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 3,
                      ),
                      child: compactRoomNumber
                          ? FittedBox(fit: BoxFit.scaleDown, child: roomLabel)
                          : roomLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyCourseCell extends StatelessWidget {
  const _EmptyCourseCell({
    required this.weekday,
    required this.period,
    required this.minHeight,
  });

  final int weekday;
  final int period;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final label = '${_weekdayLabel(weekday)}曜日 $period限に授業を追加';
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('empty-course-cell-$weekday-$period'),
          onTap: () =>
              context.go('/courses/search?weekday=$weekday&period=$period'),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight, minWidth: 48),
            child: const Center(child: Icon(Icons.add, size: 24)),
          ),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _CourseCounts {
  const _CourseCounts({required this.assignments, required this.exams});

  final int assignments;
  final int exams;

  int get total => assignments + exams;
}

UserCourse? _courseAt(
  List<UserCourse> courses,
  int weekday,
  int period,
) {
  for (final course in courses) {
    if (course.dayOfWeek == weekday && course.periodNo == period) {
      return course;
    }
  }
  return null;
}

_CourseCounts _countsAt(DemoAppState state, int weekday, int period) {
  final course = _courseAt(state.courses, weekday, period);
  if (course == null) return const _CourseCounts(assignments: 0, exams: 0);
  return _CourseCounts(
    assignments:
        state.assignments.where((item) => item.courseId == course.id).length,
    exams: state.exams.where((item) => item.courseId == course.id).length,
  );
}

PeriodSetting? _periodSetting(
  DemoAppState state,
  int? weekday,
  int period,
) {
  for (final setting in state.periodSettings) {
    if (setting.periodNo == period &&
        (weekday == null || setting.dayOfWeek == weekday)) {
      return setting;
    }
  }
  return null;
}

const _fallbackPeriodTimes = <int, (String, String)>{
  1: ('09:00', '10:30'),
  2: ('10:40', '12:10'),
  3: ('13:00', '14:30'),
  4: ('14:40', '16:10'),
  5: ('16:20', '17:50'),
};

String _formatMinutes(int value) {
  final hours = value ~/ 60;
  final minutes = value % 60;
  return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
}

String _weekdayLabel(int weekday) {
  return const {
    DateTime.monday: '月',
    DateTime.tuesday: '火',
    DateTime.wednesday: '水',
    DateTime.thursday: '木',
    DateTime.friday: '金',
  }[weekday]!;
}
