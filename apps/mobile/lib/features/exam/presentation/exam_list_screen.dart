import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/app_status_badge.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/responsive_content.dart';
import '../../../shared/widgets/section_header.dart';
import '../../timetable/application/demo_app_controller.dart';

class ExamListScreen extends ConsumerWidget {
  const ExamListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(demoAppControllerProvider);
    final now = ref.watch(appClockProvider).now().toUtc();
    return asyncState.when(
      data: (state) {
        final exams = [...state.exams]
          ..sort((left, right) => left.startAt.compareTo(right.startAt));
        final groups = _groupExams(exams, now);
        return MvpScaffold(
          title: 'テスト',
          selectedIndex: 2,
          actions: [
            IconButton(
              tooltip: 'テストを追加',
              onPressed: () => context.go('/exams/new'),
              icon: const Icon(Icons.add),
            ),
          ],
          child: ResponsiveContent(
            child: exams.isEmpty
                ? EmptyState(
                    icon: Icons.quiz_outlined,
                    title: 'テストはまだありません',
                    message: '試験日が決まったら登録して、課題と一緒に見通せます。',
                    action: FilledButton.icon(
                      onPressed: () => context.go('/exams/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('テストを作成'),
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final group in groups) ...[
                        AppSectionHeader(
                          title: group.label,
                          icon: group.icon,
                          count: group.exams.length,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        for (final exam in group.exams) ...[
                          _ExamCard(
                            exam: exam,
                            isPast: group.kind == _ExamGroupKind.past,
                            onTap: () => context.go('/exam/${exam.id}/edit'),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                        ],
                        const SizedBox(height: AppSpacing.md),
                      ],
                      OutlinedButton.icon(
                        onPressed: () => context.go('/exams/new'),
                        icon: const Icon(Icons.add),
                        label: const Text('テストを作成'),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                    ],
                  ),
          ),
        );
      },
      loading: () => MvpScaffold(
        title: 'テスト',
        selectedIndex: 2,
        child: Center(
          child: Semantics(
            label: 'テストを読み込み中',
            child: const CircularProgressIndicator(),
          ),
        ),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: 'テスト',
        selectedIndex: 2,
        child: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'テストを読み込めませんでした',
          message: '保存済みデータを再確認します。もう一度お試しください。',
          action: FilledButton.icon(
            onPressed: () => ref.invalidate(demoAppControllerProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('再読み込み'),
          ),
        ),
      ),
    );
  }
}

class _ExamCard extends StatelessWidget {
  const _ExamCard({
    required this.exam,
    required this.isPast,
    required this.onTap,
  });

  final Exam exam;
  final bool isPast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final startAt = JapanTime.civil(exam.startAt);
    final minute = startAt.minute.toString().padLeft(2, '0');
    final dateLabel =
        '${startAt.month}月${startAt.day}日 ${startAt.hour}:$minute';
    final room = exam.room?.trim();
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.medium),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: AppStatusBadge(
                  label: isPast ? '終了' : '予定',
                  icon: isPast ? Icons.history : Icons.quiz_outlined,
                  tone: isPast ? AppStatusTone.neutral : AppStatusTone.exam,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      exam.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      room == null || room.isEmpty
                          ? dateLabel
                          : '$dateLabel · $room',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '「${exam.title}」を編集',
                onPressed: onTap,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ExamGroupKind { today, thisWeek, later, past }

class _ExamGroup {
  const _ExamGroup({required this.kind, required this.exams});

  final _ExamGroupKind kind;
  final List<Exam> exams;

  String get label => switch (kind) {
        _ExamGroupKind.today => '今日のテスト',
        _ExamGroupKind.thisWeek => '今週のテスト',
        _ExamGroupKind.later => 'それ以降のテスト',
        _ExamGroupKind.past => '終了したテスト',
      };

  IconData get icon => switch (kind) {
        _ExamGroupKind.today => Icons.today_outlined,
        _ExamGroupKind.thisWeek => Icons.date_range_outlined,
        _ExamGroupKind.later => Icons.event_note_outlined,
        _ExamGroupKind.past => Icons.history,
      };
}

List<_ExamGroup> _groupExams(List<Exam> exams, DateTime now) {
  final grouped = <_ExamGroupKind, List<Exam>>{
    for (final kind in _ExamGroupKind.values) kind: [],
  };
  final civilNow = JapanTime.civil(now).pickerDateTime;
  final today = DateTime.utc(civilNow.year, civilNow.month, civilNow.day);
  final weekEnd = today
      .subtract(Duration(days: civilNow.weekday - DateTime.monday))
      .add(const Duration(days: DateTime.daysPerWeek));

  for (final exam in exams) {
    final startAt = JapanTime.civil(exam.startAt).pickerDateTime;
    final examDate = DateTime.utc(startAt.year, startAt.month, startAt.day);
    final kind = !exam.endAt.toUtc().isAfter(now.toUtc())
        ? _ExamGroupKind.past
        : examDate == today
            ? _ExamGroupKind.today
            : examDate.isBefore(weekEnd)
                ? _ExamGroupKind.thisWeek
                : _ExamGroupKind.later;
    grouped[kind]!.add(exam);
  }

  return [
    for (final kind in _ExamGroupKind.values)
      if (grouped[kind]!.isNotEmpty)
        _ExamGroup(kind: kind, exams: grouped[kind]!),
  ];
}
