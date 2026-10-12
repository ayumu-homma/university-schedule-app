import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../../../shared/widgets/responsive_content.dart';
import '../../spatial_week/application/spatial_week_flag.dart';
import '../application/demo_app_controller.dart';
import '../data/local_schedule_repository.dart';

enum _TimetableView { day, week }

class TimetableScreen extends ConsumerWidget {
  const TimetableScreen({super.key});

  static const weekdays = [1, 2, 3, 4, 5];
  static const periods = [1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduleContext = ref.watch(activeScheduleContextProvider);
    if (scheduleContext == null) {
      return Scaffold(
        key: const Key('timetable-auth-transition'),
        body: SafeArea(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: '認証状態を確認中',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      );
    }
    final asyncState = ref.watch(demoAppControllerProvider);
    final initialWeekday = _initialTimetableWeekday(
      ref.watch(appClockProvider).now(),
    );
    return asyncState.when(
      data: (state) => _TimetableContent(
        state: state,
        scheduleContext: scheduleContext,
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
    required this.scheduleContext,
    required this.initialWeekday,
  });

  final DemoAppState state;
  final ActiveScheduleContext scheduleContext;
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

  DemoAppState get state {
    final ownerUserId = widget.scheduleContext.ownerUserId;
    final termId = widget.scheduleContext.termId;
    return widget.state.copyWith(
      courses: widget.state.courses
          .where((course) =>
              course.ownerUserId == ownerUserId && course.termId == termId)
          .toList(growable: false),
      periodSettings: widget.state.periodSettings
          .where((setting) => setting.ownerUserId == ownerUserId)
          .toList(growable: false),
      assignments: widget.state.assignments
          .where((assignment) => assignment.ownerUserId == ownerUserId)
          .toList(growable: false),
      exams: widget.state.exams
          .where((exam) => exam.ownerUserId == ownerUserId)
          .toList(growable: false),
    );
  }

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
      child: ResponsiveContent(
        compactPadding: EdgeInsets.zero,
        expandedPadding: EdgeInsets.zero,
        child: ListView(
          key: const Key('timetable-vertical-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
          children: [
            if (ref.watch(spatialWeekEnabledProvider)) ...[
              OutlinedButton.icon(
                key: const Key('open-spatial-week'),
                onPressed: () => context.go('/spatial-week'),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: const Text('立体週間ビュー（実験）'),
              ),
              const SizedBox(height: 16),
            ],
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
                onSelect: _showCourseDetails,
                onManage: _showCourseActions,
              ),
            ] else
              _WeekTimetable(
                state: state,
                onSelect: _showCourseDetails,
                onManage: _showCourseActions,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCourseDetails(UserCourse course) async {
    final capturedContext = widget.scheduleContext;
    if (course.ownerUserId != capturedContext.ownerUserId) return;
    final timeRange = _courseTimeRange(state, course);
    final counts = _countsForCourse(state, course);
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: _sheetAnimationStyle(context),
      builder: (_) => Consumer(
        builder: (sheetContext, sheetRef, _) {
          if (!_sameScheduleContext(
            sheetRef.watch(activeScheduleContextProvider),
            capturedContext,
          )) {
            _dismissStaleCourseSheet(sheetContext);
            return const SizedBox.shrink();
          }
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _availableSheetHeight(sheetContext),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      course.title,
                      key: const Key('course-selection-title'),
                      style: Theme.of(sheetContext).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    _CourseSummaryRow(
                      icon: Icons.calendar_today_outlined,
                      label: _courseDayPeriodLabel(course),
                    ),
                    _CourseSummaryRow(
                      icon: Icons.schedule_outlined,
                      label: timeRange,
                      key: const Key('course-selection-time'),
                    ),
                    if ((course.room ?? '').trim().isNotEmpty)
                      _CourseSummaryRow(
                        icon: Icons.place_outlined,
                        label: course.room!.trim(),
                        key: const Key('course-selection-room'),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _CountBadge(
                          icon: Icons.assignment_outlined,
                          label: '課題 ${counts.assignments}件',
                        ),
                        _CountBadge(
                          icon: Icons.quiz_outlined,
                          label: '試験 ${counts.exams}件',
                        ),
                        PrivacyBadge(level: course.visibilityLevel),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('course-selection-detail'),
                        onPressed: () {
                          if (_sameScheduleContext(
                            sheetRef.read(activeScheduleContextProvider),
                            capturedContext,
                          )) {
                            Navigator.pop(sheetContext, 'detail');
                          }
                        },
                        icon: const Icon(Icons.open_in_new_outlined),
                        label: const Text('授業の詳細を開く'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || !_isCurrentScheduleContext(capturedContext)) return;
    if (action == 'detail') context.go('/course/${course.id}');
  }

  Future<void> _showCourseActions(UserCourse course) async {
    final capturedContext = widget.scheduleContext;
    if (course.ownerUserId != capturedContext.ownerUserId) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      sheetAnimationStyle: _sheetAnimationStyle(context),
      builder: (_) => Consumer(
        builder: (sheetContext, sheetRef, _) {
          if (!_sameScheduleContext(
            sheetRef.watch(activeScheduleContextProvider),
            capturedContext,
          )) {
            _dismissStaleCourseSheet(sheetContext);
            return const SizedBox.shrink();
          }
          final timeRange = _courseTimeRange(state, course);
          final counts = _countsForCourse(state, course);
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _availableSheetHeight(sheetContext),
              ),
              child: ListView(
                key: const Key('course-actions-scroll'),
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course.title,
                          key: const Key('course-actions-title'),
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_courseDayPeriodLabel(course)}　$timeRange',
                          key: const Key('course-actions-schedule'),
                          style: Theme.of(sheetContext).textTheme.bodyMedium,
                        ),
                        if ((course.room ?? '').trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              course.room!.trim(),
                              key: const Key('course-actions-room'),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _CountBadge(
                              icon: Icons.assignment_outlined,
                              label: '課題 ${counts.assignments}件',
                            ),
                            _CountBadge(
                              icon: Icons.quiz_outlined,
                              label: '試験 ${counts.exams}件',
                            ),
                            PrivacyBadge(level: course.visibilityLevel),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    minTileHeight: 56,
                    leading: const Icon(Icons.open_in_new_outlined),
                    title: const Text('詳細を見る'),
                    onTap: () {
                      if (_sameScheduleContext(
                        sheetRef.read(activeScheduleContextProvider),
                        capturedContext,
                      )) {
                        Navigator.pop(sheetContext, 'detail');
                      }
                    },
                  ),
                  ListTile(
                    minTileHeight: 56,
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('編集'),
                    onTap: () {
                      if (_sameScheduleContext(
                        sheetRef.read(activeScheduleContextProvider),
                        capturedContext,
                      )) {
                        Navigator.pop(sheetContext, 'edit');
                      }
                    },
                  ),
                  ListTile(
                    minTileHeight: 56,
                    leading: Icon(
                      Icons.delete_outline,
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                    title: Text(
                      '削除',
                      style: TextStyle(
                        color: Theme.of(sheetContext).colorScheme.error,
                      ),
                    ),
                    onTap: () {
                      if (_sameScheduleContext(
                        sheetRef.read(activeScheduleContextProvider),
                        capturedContext,
                      )) {
                        Navigator.pop(sheetContext, 'delete');
                      }
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || !_isCurrentScheduleContext(capturedContext)) return;
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
    if (confirmed != true ||
        !mounted ||
        !_isCurrentScheduleContext(capturedContext)) {
      return;
    }
    await ref
        .read(demoAppControllerProvider.notifier)
        .deleteUserCourse(course.id, course.version);
  }

  bool _isCurrentScheduleContext(ActiveScheduleContext capturedContext) {
    return _sameScheduleContext(
      ref.read(activeScheduleContextProvider),
      capturedContext,
    );
  }
}

bool _sameScheduleContext(
  ActiveScheduleContext? active,
  ActiveScheduleContext captured,
) {
  return active != null &&
      active.ownerUserId == captured.ownerUserId &&
      active.universityId == captured.universityId &&
      active.termId == captured.termId &&
      active.academicYear == captured.academicYear &&
      active.primaryCalendarId == captured.primaryCalendarId;
}

void _dismissStaleCourseSheet(BuildContext context) {
  final route = ModalRoute.of(context);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || route?.isCurrent != true) return;
    Navigator.of(context).pop();
  });
}

int _initialTimetableWeekday(DateTime now) {
  final weekday = JapanTime.civil(now).weekday;
  return weekday >= DateTime.monday && weekday <= DateTime.friday
      ? weekday
      : DateTime.monday;
}

AnimationStyle _sheetAnimationStyle(BuildContext context) {
  return AnimationStyle(
    duration: AppMotion.forContext(context, AppMotion.standard),
    reverseDuration: AppMotion.forContext(context, AppMotion.quick),
  );
}

double _availableSheetHeight(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  final availableHeight =
      (mediaQuery.size.height - mediaQuery.viewInsets.bottom).clamp(
    0.0,
    mediaQuery.size.height,
  );
  return availableHeight * .82;
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
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(minHeight: AppSizes.minimumTouchTarget),
        child: SegmentedButton<_TimetableView>(
          key: const Key('timetable-view-control'),
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(
              Size(AppSizes.minimumTouchTarget, AppSizes.minimumTouchTarget),
            ),
          ),
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
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: AppSizes.minimumTouchTarget,
                minHeight: AppSizes.minimumTouchTarget,
              ),
              child: ChoiceChip(
                key: ValueKey('timetable-day-$weekday'),
                label: Text(_weekdayLabel(weekday)),
                selected: weekday == selectedWeekday,
                onSelected: (_) => onChanged(weekday),
              ),
            ),
        ],
      ),
    );
  }
}

class _CourseSummaryRow extends StatelessWidget {
  const _CourseSummaryRow({
    required this.icon,
    required this.label,
    super.key,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
        ],
      ),
    );
  }
}

class _DayTimetable extends StatelessWidget {
  const _DayTimetable({
    required this.state,
    required this.weekday,
    required this.onSelect,
    required this.onManage,
  });

  final DemoAppState state;
  final int weekday;
  final ValueChanged<UserCourse> onSelect;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final showTimes = constraints.maxWidth >= 280;
        final gutterWidth = showTimes && scale >= 1.5 ? 104.0 : 76.0;
        return Column(
          key: const Key('timetable-day-view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!showTimes)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '時刻は授業をタップして詳細で確認できます。',
                  key: Key('timetable-day-time-fallback'),
                ),
              ),
            for (final period in TimetableScreen.periods) ...[
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: gutterWidth,
                      child: _PeriodLabel(
                        period: period,
                        setting: _periodSetting(state, weekday, period),
                        showTimes: showTimes,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DayCourseCell(
                        weekday: weekday,
                        period: period,
                        course: _courseAt(state.courses, weekday, period),
                        counts: _countsAt(state, weekday, period),
                        onSelect: onSelect,
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
      },
    );
  }
}

class _WeekTimetable extends StatelessWidget {
  const _WeekTimetable({
    required this.state,
    required this.onSelect,
    required this.onManage,
  });

  final DemoAppState state;
  final ValueChanged<UserCourse> onSelect;
  final ValueChanged<UserCourse> onManage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
        final periodWidth = compact ? 36.0 : 44.0;
        const gap = 2.0;
        final cellWidth = (constraints.maxWidth - periodWidth - (gap * 5)) / 5;
        return Column(
          key: const Key('timetable-week-view'),
          children: [
            if (compact)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '拡大表示では時限のみ表示します。授業をタップすると時刻を確認できます。',
                  key: Key('timetable-week-time-fallback'),
                ),
              ),
            Row(
              children: [
                SizedBox(width: periodWidth),
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
                        setting:
                            _commonWeekPeriodSetting(state, period).setting,
                        timeHint: _commonWeekPeriodSetting(state, period)
                                .hasMixedSettings
                            ? '時刻は授業詳細'
                            : null,
                        compact: true,
                        showTimes: !compact,
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
                          onSelect: onSelect,
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
    this.timeHint,
    this.compact = false,
    this.showTimes = true,
  });

  final int period;
  final PeriodSetting? setting;
  final String? timeHint;
  final bool compact;
  final bool showTimes;

  @override
  Widget build(BuildContext context) {
    final currentSetting = setting;
    final times = currentSetting == null
        ? null
        : (
            _formatMinutes(currentSetting.startTimeMinutes),
            _formatMinutes(currentSetting.endTimeMinutes),
          );
    final timeLabel =
        timeHint ?? (times == null ? '時刻未設定' : '${times.$1}から${times.$2}');
    return Semantics(
      container: true,
      label: '$period限 $timeLabel',
      key: ValueKey(
        'timetable-period-label-$period-${compact ? 'week' : 'day'}',
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 8 : 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$period限', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 2),
            if (showTimes)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  timeHint != null
                      ? '詳細'
                      : times == null
                          ? '時刻未設定'
                          : compact
                              ? '${times.$1}\n${times.$2}'
                              : '${times.$1}\n〜 ${times.$2}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
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
    required this.onSelect,
    required this.onManage,
  });

  final int weekday;
  final int period;
  final UserCourse? course;
  final _CourseCounts counts;
  final ValueChanged<UserCourse> onSelect;
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
        onTap: () => onSelect(current),
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
    required this.onSelect,
    required this.onManage,
  });

  final double cellWidth;
  final int weekday;
  final int period;
  final UserCourse? course;
  final _CourseCounts counts;
  final ValueChanged<UserCourse> onSelect;
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
          constraints: const BoxConstraints(
            minWidth: AppSizes.minimumTouchTarget,
            minHeight: AppSizes.minimumTouchTarget,
          ),
          padding: EdgeInsets.zero,
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
        onTap: () => onSelect(current),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 124),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 2),
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

_CourseCounts _countsForCourse(DemoAppState state, UserCourse course) {
  return _CourseCounts(
    assignments:
        state.assignments.where((item) => item.courseId == course.id).length,
    exams: state.exams.where((item) => item.courseId == course.id).length,
  );
}

String _courseDayPeriodLabel(UserCourse course) {
  final weekday = course.dayOfWeek;
  final period = course.periodNo;
  final weekdayLabel =
      weekday != null && TimetableScreen.weekdays.contains(weekday)
          ? '${_weekdayLabel(weekday)}曜日'
          : '曜日未設定';
  final periodLabel = period != null && TimetableScreen.periods.contains(period)
      ? '$period限'
      : '時限未設定';
  return '$weekdayLabel・$periodLabel';
}

String _courseTimeRange(DemoAppState state, UserCourse course) {
  final weekday = course.dayOfWeek;
  final period = course.periodNo;
  if (weekday == null ||
      !TimetableScreen.weekdays.contains(weekday) ||
      period == null ||
      !TimetableScreen.periods.contains(period)) {
    return '時刻未設定';
  }

  final setting = _periodSetting(state, weekday, period);
  if (setting == null) return '時刻未設定';
  return '${_formatMinutes(setting.startTimeMinutes)} – '
      '${_formatMinutes(setting.endTimeMinutes)}';
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

({PeriodSetting? setting, bool hasMixedSettings}) _commonWeekPeriodSetting(
  DemoAppState state,
  int period,
) {
  final settings = TimetableScreen.weekdays
      .map((weekday) => _periodSetting(state, weekday, period))
      .toList(growable: false);
  if (settings.every((setting) => setting == null)) {
    return (setting: null, hasMixedSettings: false);
  }

  final first = settings.first;
  final allMatch = first != null &&
      settings.every(
        (setting) =>
            setting != null &&
            setting.startTimeMinutes == first.startTimeMinutes &&
            setting.endTimeMinutes == first.endTimeMinutes,
      );
  return allMatch
      ? (setting: first, hasMixedSettings: false)
      : (setting: null, hasMixedSettings: true);
}

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
