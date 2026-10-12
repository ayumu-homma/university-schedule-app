import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../assignment/presentation/assignment_undo_feedback.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../application/today_briefing_provider.dart';
import '../domain/today_briefing.dart';
import 'today_group_events_section.dart';

class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  final Set<String> _submittingAssignmentIds = {};
  late final TodayRefreshTimer _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = TodayRefreshTimer()
      ..start(
        clock: ref.read(appClockProvider),
        onRefresh: () {
          if (mounted) ref.invalidate(todayTimeProvider);
        },
      );
  }

  @override
  void dispose() {
    _refreshTimer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(activeScheduleContextProvider) == null) {
      return Scaffold(
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
    final briefing = ref.watch(todayBriefingProvider);
    return briefing.when(
      data: (value) => MvpScaffold(
        title: '今日',
        selectedIndex: 0,
        child: _TodayBriefingContent(
          briefing: value,
          submittingAssignmentIds: _submittingAssignmentIds,
          onSubmit: _submitAssignment,
        ),
      ),
      loading: () => MvpScaffold(
        title: '今日',
        selectedIndex: 0,
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: '今日の予定を読み込み中',
            child: const CircularProgressIndicator(),
          ),
        ),
      ),
      error: (_, __) => const MvpScaffold(
        title: '今日',
        selectedIndex: 0,
        child: EmptyState(
          key: Key('today-load-error'),
          icon: Icons.error_outline,
          title: '今日の予定を読み込めませんでした',
          message: '時間をおいてもう一度お試しください。',
        ),
      ),
    );
  }

  Future<void> _submitAssignment(TodayAssignmentItem item) async {
    final assignmentId = item.assignment.id;
    if (_submittingAssignmentIds.contains(assignmentId)) return;
    final controller = ref.read(demoAppControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submittingAssignmentIds.add(assignmentId));
    try {
      final undoOperation =
          await controller.submitAssignmentWithUndo(assignmentId);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          content: Text('「${item.assignment.title}」を提出済みにしました。'),
          action: SnackBarAction(
            label: '元に戻す',
            onPressed: () {
              unawaited(
                runAssignmentUndoWithFeedback(undoOperation, messenger),
              );
            },
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('提出状態を更新できませんでした。もう一度お試しください。')),
      );
    } finally {
      if (mounted) {
        setState(() => _submittingAssignmentIds.remove(assignmentId));
      }
    }
  }
}

class _TodayBriefingContent extends StatelessWidget {
  const _TodayBriefingContent({
    required this.briefing,
    required this.submittingAssignmentIds,
    required this.onSubmit,
  });

  final TodayBriefing briefing;
  final Set<String> submittingAssignmentIds;
  final ValueChanged<TodayAssignmentItem> onSubmit;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('today-briefing-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        Semantics(
          header: true,
          child: Text(
            _dateLabel(briefing.generatedAt),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '個人予定は端末に保存された内容を表示し、グループ予定は接続時に読み込みます',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        _DeadlineSection(
          dueToday: briefing.dueTodayAssignments,
          overdue: briefing.overdueAssignments,
          submittingAssignmentIds: submittingAssignmentIds,
          onSubmit: onSubmit,
        ),
        _ProjectionSection(
          title: '今日の授業',
          icon: Icons.school_outlined,
          items: briefing.courses,
          emptyMessage: '今日の授業はありません',
          highlightItem: briefing.currentCourse,
        ),
        _ProjectionSection(
          title: '今日のテスト',
          icon: Icons.quiz_outlined,
          items: briefing.exams,
          emptyMessage: '今日のテストはありません',
        ),
        _ProjectionSection(
          title: '個人予定',
          icon: Icons.event_outlined,
          items: briefing.personalEvents,
          emptyMessage: '今日の個人予定はありません',
        ),
        TodayGroupEventsSection(
          rangeStart: briefing.dayStart,
          rangeEnd: briefing.dayEnd,
        ),
        _ProjectionSection(
          title: 'ルーティン',
          icon: Icons.repeat_outlined,
          items: briefing.routines,
          emptyMessage: '今日のルーティンはありません',
        ),
        if (briefing.otherCalendarOccurrences.isNotEmpty)
          _ProjectionSection(
            title: '共有予定',
            icon: Icons.groups_outlined,
            items: briefing.otherCalendarOccurrences,
            emptyMessage: '今日の共有予定はありません',
          ),
      ],
    );
  }
}

class _DeadlineSection extends StatelessWidget {
  const _DeadlineSection({
    required this.dueToday,
    required this.overdue,
    required this.submittingAssignmentIds,
    required this.onSubmit,
  });

  final List<TodayAssignmentItem> dueToday;
  final List<TodayAssignmentItem> overdue;
  final Set<String> submittingAssignmentIds;
  final ValueChanged<TodayAssignmentItem> onSubmit;

  @override
  Widget build(BuildContext context) {
    return _TodaySection(
      title: '締切',
      icon: Icons.assignment_outlined,
      child: dueToday.isEmpty && overdue.isEmpty
          ? const _EmptySectionMessage('今日が締切、または期限を過ぎた未提出課題はありません')
          : Column(
              children: [
                for (final item in dueToday) ...[
                  _AssignmentCard(
                    item: item,
                    isOverdue: false,
                    isSubmitting:
                        submittingAssignmentIds.contains(item.assignment.id),
                    onSubmit: () => onSubmit(item),
                  ),
                  const SizedBox(height: 16),
                ],
                if (overdue.isNotEmpty) ...[
                  for (final item in overdue) ...[
                    _AssignmentCard(
                      item: item,
                      isOverdue: true,
                      isSubmitting:
                          submittingAssignmentIds.contains(item.assignment.id),
                      onSubmit: () => onSubmit(item),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ],
            ),
    );
  }
}

class _ProjectionSection extends StatelessWidget {
  const _ProjectionSection({
    required this.title,
    required this.icon,
    required this.items,
    required this.emptyMessage,
    this.highlightItem,
  });

  final String title;
  final IconData icon;
  final List<CalendarProjectionItem> items;
  final String emptyMessage;
  final CalendarProjectionItem? highlightItem;

  @override
  Widget build(BuildContext context) {
    return _TodaySection(
      title: title,
      icon: icon,
      child: items.isEmpty
          ? _EmptySectionMessage(emptyMessage)
          : Column(
              children: [
                if (highlightItem != null)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('現在の授業'),
                  ),
                for (final item in items)
                  Card(
                    child: ListTile(
                      minVerticalPadding: 12,
                      leading: item.kind == EventKind.course
                          ? _CourseTimeColumn(item: item)
                          : Icon(_itemIcon(item.kind)),
                      title: Text(
                        item.title,
                        key: item == highlightItem
                            ? const Key('today-current-course')
                            : null,
                        style: item.kind == EventKind.course
                            ? Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: item == highlightItem
                                      ? Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer
                                      : null,
                                )
                            : item == highlightItem
                                ? TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  )
                                : null,
                      ),
                      subtitle: item.kind == EventKind.course
                          ? Text(
                              item.location?.trim().isNotEmpty == true
                                  ? '教室 ${item.location!.trim()}'
                                  : '教室 未設定',
                            )
                          : Text(
                              '${_timeRange(item)}${_locationSuffix(item)}',
                            ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openProjection(context, item),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _CourseTimeColumn extends StatelessWidget {
  const _CourseTimeColumn({required this.item});

  final CalendarProjectionItem item;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final width = (64 * scale).clamp(64.0, 96.0);
    if (item.isAllDay) {
      return SizedBox(
        width: width,
        child: const Text('終日', maxLines: 1, softWrap: false),
      );
    }
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_time(item.startAt), maxLines: 1, softWrap: false),
          Text(_time(item.endAt), maxLines: 1, softWrap: false),
        ],
      ),
    );
  }
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({
    required this.item,
    required this.isOverdue,
    required this.isSubmitting,
    required this.onSubmit,
  });

  final TodayAssignmentItem item;
  final bool isOverdue;
  final bool isSubmitting;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final assignment = item.assignment;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              assignment.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${isOverdue ? '期限超過・' : ''}締切 ${_dateTime(assignment.dueAt)}',
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => context.go('/assignment/${assignment.id}'),
                  child: const Text('詳細'),
                ),
                OutlinedButton.icon(
                  key: Key('today-submit-${assignment.id}'),
                  onPressed: isSubmitting ? null : onSubmit,
                  icon: isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(isSubmitting ? '更新中' : '提出済みを記録'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TodaySection extends StatelessWidget {
  const _TodaySection({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _EmptySectionMessage extends StatelessWidget {
  const _EmptySectionMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

void _openProjection(BuildContext context, CalendarProjectionItem item) {
  final location = switch (item.kind) {
    EventKind.course => '/course/${item.sourceId}',
    EventKind.assignmentDeadline => '/assignment/${item.sourceId}',
    EventKind.exam => '/exam/${item.sourceId}/edit',
    EventKind.normal => '/event/${item.sourceId}/edit',
    EventKind.routine => '/routine/${item.sourceId}/edit',
    EventKind.group => '/calendar',
  };
  context.go(location);
}

IconData _itemIcon(EventKind kind) => switch (kind) {
      EventKind.course => Icons.school_outlined,
      EventKind.assignmentDeadline => Icons.assignment_outlined,
      EventKind.exam => Icons.quiz_outlined,
      EventKind.normal => Icons.event_outlined,
      EventKind.routine => Icons.repeat_outlined,
      EventKind.group => Icons.groups_outlined,
    };

String _dateLabel(DateTime instant) {
  final civil = JapanTime.civil(instant);
  const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  return '${civil.month}月${civil.day}日（${weekdays[civil.weekday - 1]}）';
}

String _dateTime(DateTime instant) {
  final civil = JapanTime.civil(instant);
  return '${civil.month}/${civil.day} ${_time(instant)}';
}

String _timeRange(CalendarProjectionItem item) {
  if (item.isAllDay) return '終日';
  return '${_time(item.startAt)}〜${_time(item.endAt)}';
}

String _time(DateTime instant) {
  final civil = JapanTime.civil(instant);
  return '${civil.hour.toString().padLeft(2, '0')}:'
      '${civil.minute.toString().padLeft(2, '0')}';
}

String _locationSuffix(CalendarProjectionItem item) {
  final location = item.location?.trim();
  return location == null || location.isEmpty ? '' : '・$location';
}
