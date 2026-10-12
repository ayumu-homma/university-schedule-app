import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database.dart' as local;
import '../../../local_db/app_database_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart'
    show activeScheduleContextProvider;

enum CalendarViewMode { month, week, day, list }

enum CalendarFilterStatus { loading, ready, error }

class CalendarFilterPreferences {
  const CalendarFilterPreferences({
    this.showCourses = true,
    this.showAssignmentDeadlines = true,
    this.showExams = true,
    this.showPersonalEvents = true,
  });

  factory CalendarFilterPreferences.fromDatabase(
    local.CalendarDisplayPreference? preference,
  ) {
    if (preference == null) return const CalendarFilterPreferences();
    return CalendarFilterPreferences(
      showCourses: preference.showCourses,
      showAssignmentDeadlines: preference.showAssignmentDeadlines,
      showExams: preference.showExams,
      showPersonalEvents: preference.showPersonalEvents,
    );
  }

  final bool showCourses;
  final bool showAssignmentDeadlines;
  final bool showExams;
  final bool showPersonalEvents;

  CalendarFilterPreferences copyWith({
    bool? showCourses,
    bool? showAssignmentDeadlines,
    bool? showExams,
    bool? showPersonalEvents,
  }) {
    return CalendarFilterPreferences(
      showCourses: showCourses ?? this.showCourses,
      showAssignmentDeadlines:
          showAssignmentDeadlines ?? this.showAssignmentDeadlines,
      showExams: showExams ?? this.showExams,
      showPersonalEvents: showPersonalEvents ?? this.showPersonalEvents,
    );
  }

  bool includes(EventKind kind) {
    return switch (kind) {
      EventKind.course => showCourses,
      EventKind.assignmentDeadline => showAssignmentDeadlines,
      EventKind.exam => showExams,
      EventKind.normal || EventKind.routine => showPersonalEvents,
      // Group schedules are outside the four personal display categories and
      // must remain visible when a user changes those filters.
      EventKind.group => true,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is CalendarFilterPreferences &&
        other.showCourses == showCourses &&
        other.showAssignmentDeadlines == showAssignmentDeadlines &&
        other.showExams == showExams &&
        other.showPersonalEvents == showPersonalEvents;
  }

  @override
  int get hashCode => Object.hash(
        showCourses,
        showAssignmentDeadlines,
        showExams,
        showPersonalEvents,
      );
}

final calendarFilterPreferencesProvider =
    StreamProvider.autoDispose<CalendarFilterPreferencesSnapshot>((ref) {
  final scheduleContext = ref.watch(activeScheduleContextProvider);
  if (scheduleContext == null) {
    return const Stream<CalendarFilterPreferencesSnapshot>.empty();
  }
  final ownerUserId = scheduleContext.ownerUserId;
  return ref
      .watch(appDatabaseProvider)
      .calendarDisplayPreferencesDao
      .watchForOwner(ownerUserId)
      .map(
        (preference) => CalendarFilterPreferencesSnapshot(
          ownerUserId: ownerUserId,
          preferences: preference == null
              ? null
              : CalendarFilterPreferences.fromDatabase(preference),
        ),
      );
});

class CalendarFilterPreferencesSnapshot {
  const CalendarFilterPreferencesSnapshot({
    required this.ownerUserId,
    required this.preferences,
  });

  final String ownerUserId;
  final CalendarFilterPreferences? preferences;
}

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  CalendarViewMode _mode = CalendarViewMode.list;
  CalendarFilterPreferences? _optimisticFilterPreferences;
  String? _optimisticPreferencesOwnerId;

  @override
  Widget build(BuildContext context) {
    final scheduleContext = ref.watch(activeScheduleContextProvider);
    if (scheduleContext == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final asyncState = ref.watch(demoAppControllerProvider);
    final now =
        JapanTime.civil(ref.watch(appClockProvider).now()).pickerDateTime;
    final storedPreferences = ref.watch(calendarFilterPreferencesProvider);
    final snapshot = storedPreferences.valueOrNull;
    final filtersReady =
        storedPreferences is AsyncData<CalendarFilterPreferencesSnapshot> &&
            snapshot?.ownerUserId == scheduleContext.ownerUserId;
    final storedFilters = filtersReady
        ? snapshot!.preferences ?? const CalendarFilterPreferences()
        : const CalendarFilterPreferences();
    final filters = _optimisticPreferencesOwnerId == scheduleContext.ownerUserId
        ? _optimisticFilterPreferences ?? storedFilters
        : storedFilters;
    return asyncState.when(
      data: (state) => _CalendarContent(
        items: state.calendarItems,
        now: now,
        mode: _mode,
        filters: filters,
        onModeChanged: (mode) => setState(() => _mode = mode),
        onFiltersChanged: filtersReady
            ? (filters) => _saveCalendarFilterPreferences(
                  ownerUserId: scheduleContext.ownerUserId,
                  filters: filters,
                )
            : null,
        filterStatus: !filtersReady
            ? storedPreferences is AsyncError
                ? CalendarFilterStatus.error
                : CalendarFilterStatus.loading
            : CalendarFilterStatus.ready,
      ),
      loading: () => const MvpScaffold(
        title: 'カレンダー',
        selectedIndex: 3,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: 'カレンダー',
        selectedIndex: 3,
        child: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: '予定を読み込めませんでした',
          message: '通信状態を確認して、もう一度お試しください。',
          action: FilledButton.icon(
            onPressed: () => ref.invalidate(demoAppControllerProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('再読み込み'),
          ),
        ),
      ),
    );
  }

  Future<void> _saveCalendarFilterPreferences({
    required String ownerUserId,
    required CalendarFilterPreferences filters,
  }) async {
    if (ref.read(activeScheduleContextProvider)?.ownerUserId != ownerUserId) {
      return;
    }
    setState(() {
      _optimisticPreferencesOwnerId = ownerUserId;
      _optimisticFilterPreferences = filters;
    });
    try {
      await ref
          .read(appDatabaseProvider)
          .calendarDisplayPreferencesDao
          .savePreferences(
            ownerUserId: ownerUserId,
            showCourses: filters.showCourses,
            showAssignmentDeadlines: filters.showAssignmentDeadlines,
            showExams: filters.showExams,
            showPersonalEvents: filters.showPersonalEvents,
            updatedAt: ref.read(appClockProvider).now().toUtc(),
          );
    } on Object {
      if (!mounted) return;
      setState(() {
        if (_optimisticPreferencesOwnerId == ownerUserId) {
          _optimisticPreferencesOwnerId = null;
          _optimisticFilterPreferences = null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('表示設定を保存できませんでした。')),
      );
    }
  }
}

class _CalendarContent extends StatelessWidget {
  const _CalendarContent({
    required this.items,
    required this.now,
    required this.mode,
    required this.filters,
    required this.onModeChanged,
    required this.onFiltersChanged,
    required this.filterStatus,
  });

  final List<CalendarProjectionItem> items;
  final DateTime now;
  final CalendarViewMode mode;
  final CalendarFilterPreferences filters;
  final ValueChanged<CalendarViewMode> onModeChanged;
  final ValueChanged<CalendarFilterPreferences>? onFiltersChanged;
  final CalendarFilterStatus filterStatus;

  @override
  Widget build(BuildContext context) {
    final visibleItems = items
        .where((item) => filters.includes(item.kind) && _isVisible(item))
        .toList()
      ..sort((left, right) {
        final timeComparison = left.startAt.compareTo(right.startAt);
        if (timeComparison != 0) return timeComparison;
        return left.title.compareTo(right.title);
      });

    return MvpScaffold(
      title: 'カレンダー',
      selectedIndex: 3,
      actions: [
        IconButton(
          tooltip: 'カレンダーの公開範囲',
          onPressed: () => context.go('/calendar/visibility'),
          icon: const Icon(Icons.shield_outlined),
        ),
        IconButton(
          tooltip: '予定を追加',
          onPressed: () => context.go('/events/new'),
          icon: const Icon(Icons.add),
        ),
      ],
      child: ListView(
        key: const Key('calendar-scroll-list'),
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<CalendarViewMode>(
            segments: const [
              ButtonSegment(
                value: CalendarViewMode.month,
                label: Text('月'),
                icon: Icon(Icons.calendar_month),
              ),
              ButtonSegment(
                value: CalendarViewMode.week,
                label: Text('週'),
                icon: Icon(Icons.view_week),
              ),
              ButtonSegment(
                value: CalendarViewMode.day,
                label: Text('日'),
                icon: Icon(Icons.today),
              ),
              ButtonSegment(
                value: CalendarViewMode.list,
                label: Text('リスト'),
                icon: Icon(Icons.list),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selection) {
              onModeChanged(selection.single);
            },
          ),
          const SizedBox(height: 16),
          Text(
            '表示する予定',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          if (filterStatus != CalendarFilterStatus.ready)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  if (filterStatus == CalendarFilterStatus.loading)
                    const Icon(Icons.hourglass_top, size: 16)
                  else
                    const Icon(Icons.error_outline, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    filterStatus == CalendarFilterStatus.loading
                        ? '表示設定を読み込み中です'
                        : '表示設定を読み込めませんでした',
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('授業'),
                selected: filters.showCourses,
                onSelected: onFiltersChanged == null
                    ? null
                    : (selected) => onFiltersChanged!(
                          filters.copyWith(showCourses: selected),
                        ),
              ),
              FilterChip(
                label: const Text('課題'),
                selected: filters.showAssignmentDeadlines,
                onSelected: onFiltersChanged == null
                    ? null
                    : (selected) => onFiltersChanged!(
                          filters.copyWith(showAssignmentDeadlines: selected),
                        ),
              ),
              FilterChip(
                label: const Text('テスト'),
                selected: filters.showExams,
                onSelected: onFiltersChanged == null
                    ? null
                    : (selected) => onFiltersChanged!(
                          filters.copyWith(showExams: selected),
                        ),
              ),
              FilterChip(
                label: const Text('個人予定'),
                selected: filters.showPersonalEvents,
                onSelected: onFiltersChanged == null
                    ? null
                    : (selected) => onFiltersChanged!(
                          filters.copyWith(showPersonalEvents: selected),
                        ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  _rangeLabel(),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${visibleItems.length}件',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (visibleItems.isEmpty)
            _CalendarEmptyState(mode: mode)
          else
            ..._buildDatedItems(context, visibleItems),
        ],
      ),
    );
  }

  Iterable<Widget> _buildDatedItems(
    BuildContext context,
    List<CalendarProjectionItem> visibleItems,
  ) sync* {
    DateTime? previousDate;
    for (final item in visibleItems) {
      final itemDate = _dateOnly(
        JapanTime.civil(item.startAt).pickerDateTime,
      );
      if (previousDate == null || !_isSameDate(previousDate, itemDate)) {
        yield Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            _dateLabel(itemDate),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        );
        previousDate = itemDate;
      }
      final editable =
          item.kind == EventKind.normal || item.kind == EventKind.routine;
      yield Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: Icon(_iconFor(item.kind)),
          title: Text(item.title),
          subtitle: Text(_subtitleFor(item)),
          trailing: editable ? const Icon(Icons.edit_outlined) : null,
          onTap: !editable
              ? null
              : () => switch (item.kind) {
                    EventKind.normal =>
                      context.go('/event/${item.sourceId}/edit'),
                    EventKind.routine =>
                      context.go('/routine/${item.sourceId}/edit'),
                    _ => null,
                  },
        ),
      );
    }
  }

  bool _isVisible(CalendarProjectionItem item) {
    final itemStart = JapanTime.civil(item.startAt).pickerDateTime;
    final itemEnd = JapanTime.civil(item.endAt).pickerDateTime;
    final today = _dateOnly(now);
    final (rangeStart, rangeEnd) = switch (mode) {
      CalendarViewMode.month => (
          DateTime.utc(now.year, now.month),
          DateTime.utc(now.year, now.month + 1),
        ),
      CalendarViewMode.week => (
          today.subtract(Duration(days: now.weekday - DateTime.monday)),
          today
              .subtract(Duration(days: now.weekday - DateTime.monday))
              .add(const Duration(days: DateTime.daysPerWeek)),
        ),
      CalendarViewMode.day => (
          today,
          today.add(const Duration(days: 1)),
        ),
      CalendarViewMode.list => (
          now,
          DateTime.utc(9999, 12, 31),
        ),
    };
    return itemStart.isBefore(rangeEnd) && itemEnd.isAfter(rangeStart);
  }

  String _rangeLabel() {
    final today = _dateOnly(now);
    return switch (mode) {
      CalendarViewMode.month => '${now.year}年${now.month}月の予定',
      CalendarViewMode.week => _weekLabel(today),
      CalendarViewMode.day => '${_dateLabel(today)}の予定',
      CalendarViewMode.list => '今後90日間の予定',
    };
  }

  String _weekLabel(DateTime today) {
    final start =
        today.subtract(Duration(days: today.weekday - DateTime.monday));
    final end = start.add(const Duration(days: 6));
    return '${start.month}/${start.day} - ${end.month}/${end.day}の予定';
  }

  IconData _iconFor(EventKind kind) {
    return switch (kind) {
      EventKind.course => Icons.school_outlined,
      EventKind.assignmentDeadline => Icons.assignment_outlined,
      EventKind.exam => Icons.quiz_outlined,
      EventKind.routine => Icons.repeat_outlined,
      EventKind.group => Icons.groups_outlined,
      EventKind.normal => Icons.event_outlined,
    };
  }

  String _subtitleFor(CalendarProjectionItem item) {
    final startAt = JapanTime.civil(item.startAt);
    final endAt = JapanTime.civil(item.endAt);
    final startMinute = startAt.minute.toString().padLeft(2, '0');
    final endMinute = endAt.minute.toString().padLeft(2, '0');
    final location = item.location == null ? '' : ' · ${item.location}';
    return '${startAt.hour}:$startMinute - '
        '${endAt.hour}:$endMinute$location';
  }
}

class _CalendarEmptyState extends StatelessWidget {
  const _CalendarEmptyState({required this.mode});

  final CalendarViewMode mode;

  @override
  Widget build(BuildContext context) {
    final (title, message, icon) = switch (mode) {
      CalendarViewMode.month => (
          '今月の予定はありません',
          '授業や個人予定を追加すると、ここでまとめて確認できます。',
          Icons.calendar_month_outlined,
        ),
      CalendarViewMode.week => (
          '今週の予定はありません',
          '新しい予定を追加して、一週間の見通しを立てましょう。',
          Icons.event_available_outlined,
        ),
      CalendarViewMode.day => (
          '今日の予定はありません',
          '週表示やリスト表示でこれからの予定も確認できます。',
          Icons.today_outlined,
        ),
      CalendarViewMode.list => (
          '今後90日間の予定はありません',
          '次の予定が決まったら登録しましょう。',
          Icons.event_note_outlined,
        ),
    };
    return EmptyState(
      icon: icon,
      title: title,
      message: message,
      action: OutlinedButton.icon(
        onPressed: () => context.go('/events/new'),
        icon: const Icon(Icons.add),
        label: const Text('予定を追加'),
      ),
    );
  }
}

const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

String _dateLabel(DateTime date) =>
    '${date.month}月${date.day}日（${_weekdays[date.weekday - 1]}）';

bool _isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
