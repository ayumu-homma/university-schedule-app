import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../application/course_template_providers.dart';
import '../../timetable/data/local_schedule_repository.dart';

class CourseSearchScreen extends ConsumerStatefulWidget {
  const CourseSearchScreen({
    this.initialWeekday,
    this.initialPeriod,
    super.key,
  });

  final int? initialWeekday;
  final int? initialPeriod;

  @override
  ConsumerState<CourseSearchScreen> createState() => _CourseSearchScreenState();
}

class _CourseSearchScreenState extends ConsumerState<CourseSearchScreen> {
  late final TextEditingController _queryController;
  late final TextEditingController _instructorController;
  late int? _weekday;
  late int? _period;
  String _query = '';
  String _instructor = '';
  String? _copyingTemplateId;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController();
    _instructorController = TextEditingController();
    _weekday = widget.initialWeekday;
    _period = widget.initialPeriod;
  }

  @override
  void dispose() {
    _queryController.dispose();
    _instructorController.dispose();
    super.dispose();
  }

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
    final filter = CourseTemplateSearchFilter(
      query: _query,
      instructor: _instructor,
      weekday: _weekday,
      period: _period,
    );
    final templates = ref.watch(courseTemplateSearchProvider(filter));
    return MvpScaffold(
      title: '授業検索',
      selectedIndex: 1,
      child: templates.when(
        loading: () => _CourseSearchContent(
          queryController: _queryController,
          instructorController: _instructorController,
          weekday: _weekday,
          period: _period,
          templates: const [],
          loading: true,
          copyingTemplateId: _copyingTemplateId,
          onSearch: _applySearch,
          onWeekdayChanged: _setWeekday,
          onPeriodChanged: _setPeriod,
          onCopy: _copyTemplate,
          onRetry: () => ref.invalidate(courseTemplateSearchProvider(filter)),
        ),
        error: (_, __) => _CourseSearchContent(
          queryController: _queryController,
          instructorController: _instructorController,
          weekday: _weekday,
          period: _period,
          templates: const [],
          error: true,
          copyingTemplateId: _copyingTemplateId,
          onSearch: _applySearch,
          onWeekdayChanged: _setWeekday,
          onPeriodChanged: _setPeriod,
          onCopy: _copyTemplate,
          onRetry: () => ref.invalidate(courseTemplateSearchProvider(filter)),
        ),
        data: (items) => _CourseSearchContent(
          queryController: _queryController,
          instructorController: _instructorController,
          weekday: _weekday,
          period: _period,
          templates: items,
          copyingTemplateId: _copyingTemplateId,
          onSearch: _applySearch,
          onWeekdayChanged: _setWeekday,
          onPeriodChanged: _setPeriod,
          onCopy: _copyTemplate,
          onRetry: () => ref.invalidate(courseTemplateSearchProvider(filter)),
        ),
      ),
    );
  }

  void _applySearch() {
    setState(() {
      _query = _queryController.text.trim();
      _instructor = _instructorController.text.trim();
    });
  }

  void _setWeekday(int? value) => setState(() => _weekday = value);

  void _setPeriod(int? value) => setState(() => _period = value);

  Future<void> _copyTemplate(CourseTemplate template) async {
    if (_copyingTemplateId != null) return;
    setState(() => _copyingTemplateId = template.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final contextState = ref.read(requiredActiveScheduleContextProvider);
      final courseId =
          await ref.read(courseTemplateRepositoryProvider).copyTemplate(
                templateId: template.id,
                ownerUserId: contextState.ownerUserId,
                termId: contextState.termId,
              );
      if (!mounted) return;
      context.go('/course/$courseId');
    } on AppError catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('授業テンプレートをコピーできませんでした')),
      );
    } finally {
      if (mounted) setState(() => _copyingTemplateId = null);
    }
  }
}

class _CourseSearchContent extends StatelessWidget {
  const _CourseSearchContent({
    required this.queryController,
    required this.instructorController,
    required this.weekday,
    required this.period,
    required this.templates,
    required this.copyingTemplateId,
    required this.onSearch,
    required this.onWeekdayChanged,
    required this.onPeriodChanged,
    required this.onCopy,
    required this.onRetry,
    this.loading = false,
    this.error = false,
  });

  final TextEditingController queryController;
  final TextEditingController instructorController;
  final int? weekday;
  final int? period;
  final List<CourseTemplate> templates;
  final String? copyingTemplateId;
  final VoidCallback onSearch;
  final ValueChanged<int?> onWeekdayChanged;
  final ValueChanged<int?> onPeriodChanged;
  final Future<void> Function(CourseTemplate template) onCopy;
  final VoidCallback onRetry;
  final bool loading;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final duplicateCandidateCounts = _duplicateCandidateCounts(templates);
    return ListView(
      key: const Key('course-template-search-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
      children: [
        TextField(
          key: const Key('course-template-query'),
          controller: queryController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: '授業名で検索',
            suffixIcon: IconButton(
              tooltip: '検索',
              onPressed: onSearch,
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (_) => onSearch(),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('course-template-instructor'),
          controller: instructorController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.person_search_outlined),
            labelText: '教員名で絞り込み',
          ),
          onSubmitted: (_) => onSearch(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int?>(
                key: const Key('course-template-weekday'),
                initialValue: weekday,
                decoration: const InputDecoration(labelText: '曜日'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('指定なし'),
                  ),
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem<int?>(
                      value: day,
                      child: Text(_weekdayLabel(day)),
                    ),
                ],
                onChanged: onWeekdayChanged,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int?>(
                key: const Key('course-template-period'),
                initialValue: period,
                decoration: const InputDecoration(labelText: '時限'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('指定なし'),
                  ),
                  for (var value = 1; value <= 9; value++)
                    DropdownMenuItem<int?>(
                      value: value,
                      child: Text('$value限'),
                    ),
                ],
                onChanged: onPeriodChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('course-template-search-submit'),
            onPressed: onSearch,
            icon: const Icon(Icons.search),
            label: const Text('検索する'),
          ),
        ),
        const SizedBox(height: 16),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (error)
          EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '授業テンプレートを取得できませんでした',
            message: '通信状態を確認して、もう一度お試しください。',
            action: FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          )
        else if (templates.isEmpty)
          const _NoTemplates()
        else ...[
          Text('同大学内の検索結果 ${templates.length}件（関連度・コピー数順）'),
          const SizedBox(height: 8),
          for (final (index, template) in templates.indexed)
            _CourseTemplateResultCard(
              template: template,
              rank: index + 1,
              duplicateCandidateCount:
                  duplicateCandidateCounts[template.duplicateKey] ?? 1,
              copying: copyingTemplateId == template.id,
              copyEnabled: copyingTemplateId == null,
              onCopy: () => onCopy(template),
            ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            final params = [
              if (weekday != null) 'weekday=$weekday',
              if (period != null) 'period=$period',
            ].join('&');
            context.go('/courses/manual${params.isEmpty ? '' : '?$params'}');
          },
          icon: const Icon(Icons.edit_note),
          label: const Text('手動で授業を登録'),
        ),
      ],
    );
  }
}

class _CourseTemplateResultCard extends StatelessWidget {
  const _CourseTemplateResultCard({
    required this.template,
    required this.rank,
    required this.duplicateCandidateCount,
    required this.copying,
    required this.copyEnabled,
    required this.onCopy,
  });

  final CourseTemplate template;
  final int rank;
  final int duplicateCandidateCount;
  final bool copying;
  final bool copyEnabled;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final weekday = template.dayOfWeek == null
        ? '曜日未設定'
        : _weekdayLabel(template.dayOfWeek!);
    final period = template.periodNo == null ? '' : ' ${template.periodNo}限';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.school_outlined),
        title: Text(template.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${template.instructorName ?? '教員未設定'} · $weekday$period'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text('検索順位 $rank'),
                Text('学期内コピー ${template.copyCountTerm}'),
                Text('総コピー ${template.copyCountTotal}'),
                if (duplicateCandidateCount > 1)
                  Text('検索結果内の重複候補 $duplicateCandidateCount件'),
              ],
            ),
          ],
        ),
        trailing: copying
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton.icon(
                onPressed: copyEnabled ? onCopy : null,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('コピー'),
              ),
      ),
    );
  }
}

Map<String, int> _duplicateCandidateCounts(
  Iterable<CourseTemplate> templates,
) {
  final counts = <String, int>{};
  for (final template in templates) {
    final key = template.duplicateKey;
    if (key == null || key.isEmpty) continue;
    counts.update(key, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

class _NoTemplates extends StatelessWidget {
  const _NoTemplates();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.search_off_outlined,
      title: '一致する授業テンプレートがありません',
      message: '検索条件を変えるか、手動で授業を登録してください。',
    );
  }
}

String _weekdayLabel(int day) {
  const labels = ['月', '火', '水', '木', '金', '土', '日'];
  if (day < 1 || day > labels.length) return '$day曜';
  return '${labels[day - 1]}曜';
}
