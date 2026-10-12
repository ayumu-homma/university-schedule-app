import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../domain/today_briefing.dart';

/// A compact action surface backed by the same briefing as the full agenda.
class TodayAtAGlance extends StatelessWidget {
  const TodayAtAGlance({required this.briefing, super.key});

  final TodayBriefing briefing;

  @override
  Widget build(BuildContext context) {
    final current = briefing.currentCourse;
    final next = briefing.nextCourse;
    final focusCourse = current ?? next;
    final assignmentCount = briefing.dueTodayAssignments.length +
        briefing.overdueAssignments.length;
    final eventCount = briefing.personalEvents.length +
        briefing.routines.length +
        briefing.otherCalendarOccurrences.length;

    return Card(
      key: const Key('today-at-a-glance'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(_dateLabel(briefing.generatedAt),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (focusCourse == null)
              Text(briefing.courses.isEmpty ? '今日の授業はありません' : 'このあとの授業はありません')
            else
              OutlinedButton.icon(
                key: const Key('today-focus-course'),
                onPressed: () => context.go('/course/${focusCourse.sourceId}'),
                icon: const Icon(Icons.school_outlined),
                label: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(current == null ? '次の授業' : '現在の授業'),
                    Text(
                      '${_time(focusCourse.startAt)}〜${_time(focusCourse.endAt)}　${focusCourse.location?.trim().isNotEmpty == true ? focusCourse.location!.trim() : '教室未設定'}',
                    ),
                    Text(focusCourse.title),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                _RouteCount(
                  key: const Key('today-count-assignments'),
                  icon: Icons.assignment_late_outlined,
                  label: '締切 $assignmentCount件',
                  semanticsLabel: '期限超過と今日締切の課題 $assignmentCount件',
                  route: '/assignments',
                ),
                _RouteCount(
                  key: const Key('today-count-exams'),
                  icon: Icons.quiz_outlined,
                  label: 'テスト ${briefing.exams.length}件',
                  semanticsLabel: '今日のテスト ${briefing.exams.length}件',
                  route: '/exams',
                ),
                _RouteCount(
                  key: const Key('today-count-events'),
                  icon: Icons.event_outlined,
                  label: '予定 $eventCount件',
                  semanticsLabel: '個人予定、ルーティン、共有カレンダーの予定 $eventCount件',
                  route: '/calendar',
                ),
              ],
            ),
            if (briefing.actionableCount == 0) ...[
              const SizedBox(height: AppSpacing.sm),
              const Text('今日の個人予定はまだありません。必要なものを追加できます。'),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  OutlinedButton.icon(
                    key: const Key('today-empty-add-course'),
                    onPressed: () => context.go('/courses/manual'),
                    icon: const Icon(Icons.add),
                    label: const Text('授業を追加'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('today-empty-add-event'),
                    onPressed: () => context.go('/events/new'),
                    icon: const Icon(Icons.event_outlined),
                    label: const Text('予定を追加'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RouteCount extends StatelessWidget {
  const _RouteCount({
    required super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final String route;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: semanticsLabel,
        child: OutlinedButton.icon(
          onPressed: () => context.go(route),
          icon: Icon(icon),
          label: Text(label),
        ),
      );
}

String _dateLabel(DateTime instant) {
  final civil = JapanTime.civil(instant);
  const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  return '${civil.month}月${civil.day}日（${weekdays[civil.weekday - 1]}）';
}

String _time(DateTime instant) {
  final civil = JapanTime.civil(instant);
  return '${civil.hour.toString().padLeft(2, '0')}:${civil.minute.toString().padLeft(2, '0')}';
}
