import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../today/application/today_briefing_provider.dart';
import '../../today/domain/today_briefing.dart';
import '../../today/presentation/today_summary_card.dart';
import '../application/demo_app_controller.dart';
import '../data/local_schedule_repository.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
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
    final scheduleContext = ref.watch(activeScheduleContextProvider);
    if (scheduleContext == null) {
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
    final schedule = ref.watch(demoAppControllerProvider);
    final briefing = ref.watch(todayBriefingProvider);
    return briefing.when(
      data: (value) => _HomeContent(
        briefing: value,
        academicYear: scheduleContext.academicYear,
        showFirstCourseContinuation:
            schedule.valueOrNull?.courses.isEmpty == true,
      ),
      loading: () => const MvpScaffold(
        title: 'ホーム',
        selectedIndex: 0,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => MvpScaffold(
        title: 'ホーム',
        selectedIndex: 0,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.briefing,
    required this.academicYear,
    required this.showFirstCourseContinuation,
  });

  final TodayBriefing briefing;
  final int academicYear;
  final bool showFirstCourseContinuation;

  @override
  Widget build(BuildContext context) {
    return MvpScaffold(
      title: 'ホーム',
      selectedIndex: 0,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text(
            '$academicYear 年度',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (showFirstCourseContinuation) ...[
            Card(
              key: const Key('first-course-continuation-card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '最初の授業を登録しましょう',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '保存後に、必要に応じて通知設定の案内が表示されます。',
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const Key('first-course-continuation-button'),
                      onPressed: () => context.go(
                        '/courses/manual?firstCourse=true',
                      ),
                      icon: const Icon(Icons.school_outlined),
                      label: const Text('最初の授業を登録'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          TodaySummaryCard(
            briefing: briefing,
            onOpen: () => context.go('/today'),
          ),
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(
              'すぐに確認',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => context.go('/timetable'),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('時間割'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/assignments'),
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('課題'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => context.go('/calendar'),
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('カレンダー'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _AttentionCard(briefing: briefing),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => context.go('/availability'),
            icon: const Icon(Icons.search),
            label: const Text('空きコマを探す'),
          ),
        ],
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.briefing});

  final TodayBriefing briefing;

  @override
  Widget build(BuildContext context) {
    final overdueCount = briefing.overdueAssignments.length;
    final dueTodayCount = briefing.dueTodayAssignments.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '見落とし防止',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              overdueCount == 0 && dueTodayCount == 0
                  ? '急ぎの未提出課題はありません。'
                  : '期限超過 $overdueCount 件・今日締切 $dueTodayCount 件',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => context.go('/today'),
                icon: const Icon(Icons.today_outlined),
                label: const Text('今日を詳しく見る'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
