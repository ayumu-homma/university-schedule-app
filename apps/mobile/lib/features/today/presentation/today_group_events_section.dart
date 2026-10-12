import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../application/today_group_events_provider.dart';

class TodayGroupEventsSection extends ConsumerWidget {
  const TodayGroupEventsSection({
    required this.rangeStart,
    required this.rangeEnd,
    super.key,
  });

  final DateTime rangeStart;
  final DateTime rangeEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(todayGroupEventsProvider);
    return state.when(
      loading: () => _SectionCard(
        title: '今日のグループ予定',
        child: Semantics(
          liveRegion: true,
          label: 'グループ予定を読み込み中',
          child: const LinearProgressIndicator(),
        ),
      ),
      error: (_, __) => _SectionCard(
        title: '今日のグループ予定',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('グループ予定を読み込めませんでした。個人の予定は引き続き表示しています。'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('today-group-events-retry'),
                onPressed: () => ref.invalidate(todayGroupEventsProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
              ),
            ),
          ],
        ),
      ),
      data: (events) {
        final visible = groupEventsInRange(
          events,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
        );
        return _SectionCard(
          title: '今日のグループ予定',
          child: visible.isEmpty
              ? const Text('今日のグループ予定はありません。')
              : Column(
                  children: [
                    for (final item in visible)
                      ListTile(
                        key: Key('today-group-event-${item.event.eventId}'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.groups_outlined),
                        title: Text(item.event.title),
                        subtitle: Text(
                          '${_time(item.event.startAt)}–${_time(item.event.endAt)} · ${item.group.name}',
                        ),
                        onTap: () => context.go('/group/${item.group.id}'),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      );
}

String _time(DateTime value) {
  final civil = JapanTime.civil(value);
  return '${civil.hour.toString().padLeft(2, '0')}:${civil.minute.toString().padLeft(2, '0')}';
}
