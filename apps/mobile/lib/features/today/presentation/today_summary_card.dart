import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../domain/today_briefing.dart';

class TodaySummaryCard extends StatelessWidget {
  const TodaySummaryCard({
    required this.briefing,
    required this.onOpen,
    super.key,
  });

  final TodayBriefing briefing;
  final VoidCallback onOpen;

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
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('open-today-briefing'),
                onPressed: onOpen,
                icon: const Icon(Icons.today_outlined),
                label: const Text('今日の予定を見る'),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (focusCourse != null)
              OutlinedButton.icon(
                key: const Key('home-focus-course'),
                onPressed: () => context.go('/course/${focusCourse.sourceId}'),
                icon: const Icon(Icons.school_outlined),
                label: Text(
                  '${current == null ? '次の授業' : '現在の授業'} ${_time(focusCourse.startAt)}〜${_time(focusCourse.endAt)}・${focusCourse.location?.trim().isNotEmpty == true ? focusCourse.location!.trim() : '教室未設定'}\n${focusCourse.title}',
                ),
              )
            else
              const Text('このあとの授業はありません'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                _CountLabel(
                  key: const Key('home-count-courses'),
                  icon: Icons.school_outlined,
                  label: '授業 ${briefing.courses.length}件',
                  route: '/timetable',
                ),
                _CountLabel(
                  key: const Key('home-count-assignments'),
                  icon: Icons.assignment_late_outlined,
                  label: '課題 $assignmentCount件',
                  route: '/assignments',
                ),
                _CountLabel(
                  key: const Key('home-count-exams'),
                  icon: Icons.quiz_outlined,
                  label: 'テスト ${briefing.exams.length}件',
                  route: '/exams',
                ),
                _CountLabel(
                  key: const Key('home-count-events'),
                  icon: Icons.event_outlined,
                  label: '予定 $eventCount件',
                  route: '/calendar',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime instant) {
    final civil = JapanTime.civil(instant);
    return '${civil.hour.toString().padLeft(2, '0')}:'
        '${civil.minute.toString().padLeft(2, '0')}';
  }
}

class _CountLabel extends StatelessWidget {
  const _CountLabel({
    required super.key,
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: () => context.go(route),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}
