import 'package:flutter/material.dart';
import 'package:shared_domain/shared_domain.dart';

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
    return Card(
      child: InkWell(
        key: const Key('open-today-briefing'),
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.today_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        '今日の予定',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              if (current != null)
                Text('授業中: ${current.title}（${_time(current.endAt)}まで）')
              else if (next != null)
                Text('次の授業: ${_time(next.startAt)} ${next.title}')
              else
                const Text('このあとの授業はありません'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CountLabel(
                    icon: Icons.school_outlined,
                    label: '授業 ${briefing.courses.length}',
                  ),
                  _CountLabel(
                    icon: Icons.assignment_late_outlined,
                    label:
                        '課題 ${briefing.dueTodayAssignments.length + briefing.overdueAssignments.length}',
                  ),
                  _CountLabel(
                    icon: Icons.quiz_outlined,
                    label: 'テスト ${briefing.exams.length}',
                  ),
                  _CountLabel(
                    icon: Icons.event_outlined,
                    label:
                        '予定 ${briefing.personalEvents.length + briefing.routines.length + briefing.otherCalendarOccurrences.length}',
                  ),
                ],
              ),
            ],
          ),
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
  const _CountLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}
