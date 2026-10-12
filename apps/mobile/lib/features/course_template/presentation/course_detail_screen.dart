import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../application/course_template_providers.dart';

class CourseDetailScreen extends ConsumerWidget {
  const CourseDetailScreen({required this.courseId, super.key});

  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) => _CourseDetailContent(
        state: state,
        courseId: courseId,
      ),
      loading: () => const MvpScaffold(
        title: '授業詳細',
        selectedIndex: 1,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '授業詳細',
        selectedIndex: 1,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }
}

class _CourseDetailContent extends ConsumerWidget {
  const _CourseDetailContent({
    required this.state,
    required this.courseId,
  });

  final DemoAppState state;
  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final course = _courseById(state.courses, courseId);
    return MvpScaffold(
      title: '授業詳細',
      selectedIndex: 1,
      actions: [
        if (course != null)
          IconButton(
            tooltip: 'この授業に課題を追加',
            onPressed: () => context.go(
              '/assignments/new?courseId=${Uri.encodeComponent(course.id)}',
            ),
            icon: const Icon(Icons.add_task_outlined),
          ),
        if (course != null)
          IconButton(
            tooltip: '授業を編集',
            onPressed: () => context.go('/course/${course.id}/edit'),
            icon: const Icon(Icons.edit_outlined),
          ),
        if (course != null)
          IconButton(
            tooltip: '授業を削除',
            onPressed: () => _delete(context, ref, course),
            icon: const Icon(Icons.delete_outline),
          ),
      ],
      child: course == null
          ? const Center(child: Text('授業が見つかりません'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(course.title,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                        label: Text(
                            '${_weekdayLabel(course.dayOfWeek)} ${course.periodNo ?? '-'}限')),
                    if (course.room != null) Chip(label: Text(course.room!)),
                    PrivacyBadge(level: course.visibilityLevel),
                  ],
                ),
                const SizedBox(height: 24),
                Text('概要', style: Theme.of(context).textTheme.titleMedium),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(course.instructorName ?? '教員未設定'),
                ),
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: Text(course.sourceTemplateId == null
                      ? '手動登録'
                      : '授業テンプレからコピー済み'),
                  subtitle: const Text('コピー後は個人時間割として独立しています'),
                ),
                const Divider(),
                Text('課題', style: Theme.of(context).textTheme.titleMedium),
                for (final assignment in state.assignments
                    .where((item) => item.courseId == course.id))
                  ListTile(
                    leading: const Icon(Icons.assignment_outlined),
                    title: Text(assignment.title),
                    subtitle: Text(_dueDateLabel(assignment.dueAt)),
                    onTap: () => context.go('/assignment/${assignment.id}'),
                  ),
                const Divider(),
                Text('テスト', style: Theme.of(context).textTheme.titleMedium),
                for (final exam
                    in state.exams.where((item) => item.courseId == course.id))
                  ListTile(
                    leading: const Icon(Icons.quiz_outlined),
                    title: Text(exam.title),
                    subtitle: Text(
                        '${_dateTimeLabel(exam.startAt)}${exam.room == null ? '' : ' ・${exam.room}'}'),
                  ),
                const Divider(),
                Text('共有', style: Theme.of(context).textTheme.titleMedium),
                const ListTile(
                  leading: Icon(Icons.report_outlined),
                  title: Text('テンプレ修正提案・通報'),
                  subtitle: Text('公開項目だけを修正提案・通報できます。個人予定は自動更新されません。'),
                ),
                if (course.sourceTemplateId != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('course-template-update-review'),
                    onPressed: () =>
                        _reviewTemplateUpdate(context, ref, course),
                    icon: const Icon(Icons.sync_alt_outlined),
                    label: const Text('テンプレート更新を確認'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('course-template-report'),
                    onPressed: () => _reportTemplate(context, ref, course),
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('テンプレートを通報'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('course-template-proposal'),
                    onPressed: () => _proposeTemplate(context, ref, course),
                    icon: const Icon(Icons.edit_note_outlined),
                    label: const Text('テンプレート修正を提案'),
                  ),
                ],
              ],
            ),
    );
  }

  UserCourse? _courseById(List<UserCourse> courses, String id) {
    for (final course in courses) {
      if (course.id == id) return course;
    }
    return null;
  }

  String _weekdayLabel(int? weekday) {
    return const {
          DateTime.monday: '月曜',
          DateTime.tuesday: '火曜',
          DateTime.wednesday: '水曜',
          DateTime.thursday: '木曜',
          DateTime.friday: '金曜',
          DateTime.saturday: '土曜',
          DateTime.sunday: '日曜',
        }[weekday] ??
        '曜日未設定';
  }

  String _dueDateLabel(DateTime instant) {
    return '${_dateTimeLabel(instant)} 締切';
  }

  String _dateTimeLabel(DateTime instant) {
    final civil = JapanTime.civil(instant);
    return '${civil.year}/${civil.month}/${civil.day} ${civil.hour}:'
        '${civil.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    UserCourse course,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('授業を削除しますか？'),
        content: const Text('紐づく課題・テストの履歴は残り、授業だけが非表示になります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(demoAppControllerProvider.notifier)
          .deleteUserCourse(course.id, course.version);
      if (context.mounted) context.go('/timetable');
    } catch (error) {
      if (!context.mounted) return;
      final message = error is ConflictError
          ? '別の変更が反映されました。画面を開き直して確認してください。'
          : '授業を削除できませんでした。時間割を更新して再試行してください。';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _reportTemplate(
    BuildContext context,
    WidgetRef ref,
    UserCourse course,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _TemplateReportDialog(),
    );
    if (reason == null || reason.trim().isEmpty || !context.mounted) return;
    try {
      await ref.read(courseTemplateRepositoryProvider).reportTemplate(
            templateId: course.sourceTemplateId!,
            reason: reason,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('通報を受け付けました')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('通報を送信できませんでした: $error')));
      }
    }
  }

  Future<void> _reviewTemplateUpdate(
    BuildContext context,
    WidgetRef ref,
    UserCourse course,
  ) async {
    final repository = ref.read(courseTemplateRepositoryProvider);
    late final Map<String, Object?> update;
    try {
      update = await repository.templateUpdate(course.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新を確認できませんでした: $error')));
      }
      return;
    }
    if (!context.mounted) return;
    if (update['available'] != true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('テンプレートに新しい更新はありません')));
      return;
    }

    late final _TemplateUpdateComparison comparison;
    try {
      comparison = _TemplateUpdateComparison.fromResponse(update);
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('テンプレート更新の比較情報を確認できませんでした')));
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _TemplateUpdateDialog(
        course: course,
        comparison: comparison,
        onCancel: () => Navigator.pop(dialogContext),
        onIgnore: () => Navigator.pop(dialogContext, 'ignore'),
        onApply: () => Navigator.pop(dialogContext, 'apply'),
      ),
    );
    if (action == null ||
        (action != 'ignore' && action != 'apply') ||
        !context.mounted) {
      return;
    }

    try {
      final review = await repository.reviewTemplateUpdate(
        courseId: course.id,
        action: action,
        expectedTemplateVersion: comparison.templateVersion,
        expectedCourseVersion: comparison.courseVersion,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(review['status'] == 'queued'
                ? 'テンプレート更新を同期キューに追加しました'
                : action == 'apply'
                    ? 'テンプレート更新を反映しました'
                    : '更新を無視しました')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新を確認できませんでした: $error')));
      }
    }
  }

  Future<void> _proposeTemplate(
    BuildContext context,
    WidgetRef ref,
    UserCourse course,
  ) async {
    try {
      final details = await ref
          .read(courseTemplateRepositoryProvider)
          .templateDetails(course.sourceTemplateId!);
      if (!context.mounted) return;
      final values = await showDialog<(String, String)?>(
        context: context,
        builder: (_) => _TemplateProposalDialog(
          initialTitle: details['title']?.toString() ?? course.title,
          initialInstructor: details['instructor_name']?.toString() ?? '',
        ),
      );
      if (values == null || !context.mounted) return;
      final version = (details['version'] as num?)?.toInt();
      if (version == null) throw const ValidationError('テンプレートの版を確認できませんでした。');
      await ref.read(courseTemplateRepositoryProvider).submitEditProposal(
            templateId: course.sourceTemplateId!,
            proposedPayload: {
              'title': values.$1.trim(),
              'instructor_name': values.$2.trim(),
            },
            expectedVersion: version,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('修正提案を受け付けました')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('修正提案を送信できませんでした: $error')));
      }
    }
  }
}

class _TemplateReportDialog extends StatefulWidget {
  const _TemplateReportDialog();

  @override
  State<_TemplateReportDialog> createState() => _TemplateReportDialogState();
}

class _TemplateReportDialogState extends State<_TemplateReportDialog> {
  late final TextEditingController _reasonController;

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('テンプレートを通報'),
      content: TextField(
        controller: _reasonController,
        autofocus: true,
        maxLength: 1000,
        decoration: const InputDecoration(labelText: '理由'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _reasonController.text),
          child: const Text('送信'),
        ),
      ],
    );
  }
}

class _TemplateProposalDialog extends StatefulWidget {
  const _TemplateProposalDialog({
    required this.initialTitle,
    required this.initialInstructor,
  });

  final String initialTitle;
  final String initialInstructor;

  @override
  State<_TemplateProposalDialog> createState() =>
      _TemplateProposalDialogState();
}

class _TemplateProposalDialogState extends State<_TemplateProposalDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _instructorController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _instructorController =
        TextEditingController(text: widget.initialInstructor);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _instructorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('テンプレート修正を提案'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: '授業名'),
          ),
          TextField(
            controller: _instructorController,
            decoration: const InputDecoration(labelText: '教員名'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (_titleController.text, _instructorController.text),
          ),
          child: const Text('提案する'),
        ),
      ],
    );
  }
}

class _TemplateUpdateDialog extends StatelessWidget {
  const _TemplateUpdateDialog({
    required this.course,
    required this.comparison,
    required this.onCancel,
    required this.onIgnore,
    required this.onApply,
  });

  final UserCourse course;
  final _TemplateUpdateComparison comparison;
  final VoidCallback onCancel;
  final VoidCallback onIgnore;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final fields = comparison.changedFields;
    return AlertDialog(
      title: const Text('テンプレート更新を確認'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('個人のメモ・課題・通知・公開範囲は保持されます。公開項目を反映しますか？'),
              const SizedBox(height: 16),
              if (fields.isEmpty)
                const Text('公開項目の変更はありません。テンプレートの参照先だけが更新されます。')
              else ...[
                const Row(
                  children: [
                    Expanded(
                      child: Text('現在の自分の授業',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: Text('反映後',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final field in fields)
                  _TemplateUpdateComparisonRow(
                    label: field.label,
                    current: _currentValue(course, field.key),
                    after: _afterValue(comparison.after, field.key),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: onCancel, child: const Text('キャンセル')),
        TextButton(onPressed: onIgnore, child: const Text('今回は無視')),
        FilledButton(onPressed: onApply, child: const Text('反映する')),
      ],
    );
  }

  String _currentValue(UserCourse course, String key) {
    return switch (key) {
      'title' => _textValue(course.title),
      'instructor_name' => _textValue(course.instructorName),
      'day_of_week' => _weekdayValue(course.dayOfWeek),
      'period_no' => _periodValue(course.periodNo),
      'room' => _textValue(course.room),
      _ => '未設定',
    };
  }

  String _afterValue(Map<String, Object?> after, String key) {
    return switch (key) {
      'title' => _textValue(after[key] as String?),
      'instructor_name' => _textValue(after[key] as String?),
      'day_of_week' => _weekdayValue(after[key] as int?),
      'period_no' => _periodValue(after[key] as int?),
      'room' => _textValue(after[key] as String?),
      _ => '未設定',
    };
  }

  String _textValue(String? value) {
    return value == null || value.trim().isEmpty ? '未設定' : value;
  }

  String _weekdayValue(int? value) {
    return value == null ? '未設定' : _weekdayLabel(value);
  }

  String _periodValue(int? value) {
    return value == null ? '未設定' : '$value限';
  }

  String _weekdayLabel(int weekday) {
    return const {
          DateTime.monday: '月曜',
          DateTime.tuesday: '火曜',
          DateTime.wednesday: '水曜',
          DateTime.thursday: '木曜',
          DateTime.friday: '金曜',
          DateTime.saturday: '土曜',
          DateTime.sunday: '日曜',
        }[weekday] ??
        '未設定';
  }
}

class _TemplateUpdateComparisonRow extends StatelessWidget {
  const _TemplateUpdateComparisonRow({
    required this.label,
    required this.current,
    required this.after,
  });

  final String label;
  final String current;
  final String after;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(current)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_forward, size: 16),
              ),
              Expanded(child: Text(after)),
            ],
          ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

class _TemplateUpdateField {
  const _TemplateUpdateField(this.key, this.label);

  final String key;
  final String label;
}

class _TemplateUpdateComparison {
  _TemplateUpdateComparison({
    required this.templateVersion,
    required this.courseVersion,
    required this.after,
    required this.changedFields,
  });

  static const _allowlistedFields = <_TemplateUpdateField>[
    _TemplateUpdateField('title', '授業名'),
    _TemplateUpdateField('instructor_name', '教員名'),
    _TemplateUpdateField('day_of_week', '曜日'),
    _TemplateUpdateField('period_no', '時限'),
    _TemplateUpdateField('room', '教室'),
  ];

  final int templateVersion;
  final int courseVersion;
  final Map<String, Object?> after;
  final List<_TemplateUpdateField> changedFields;

  static _TemplateUpdateComparison fromResponse(Map<String, Object?> response) {
    final templateVersion = _version(response['template_version']);
    final courseVersion = _version(response['course_version']);
    final after = _objectMap(response['after']);
    final changed = _objectMap(response['changed']);
    if (templateVersion == null ||
        courseVersion == null ||
        after == null ||
        changed == null ||
        after['canonical_template_id'] is! String ||
        (after['canonical_template_id'] as String).trim().isEmpty) {
      throw const ValidationError('テンプレート更新の比較情報が不正です。');
    }

    const textFields = {'title', 'instructor_name', 'room'};
    for (final key in textFields) {
      if (!after.containsKey(key) ||
          (after[key] != null && after[key] is! String)) {
        throw const ValidationError('テンプレート更新の比較情報が不正です。');
      }
    }
    for (final key in const ['day_of_week', 'period_no']) {
      final value = after[key];
      if (!after.containsKey(key) || (value != null && _slot(value) == null)) {
        throw const ValidationError('テンプレート更新の比較情報が不正です。');
      }
      if (value != null) {
        final number = _slot(value)!;
        final valid = key == 'day_of_week'
            ? number >= DateTime.monday && number <= DateTime.sunday
            : number >= 1 && number <= 9;
        if (!valid) {
          throw const ValidationError('テンプレート更新の比較情報が不正です。');
        }
      }
    }

    final fieldsByKey = {
      for (final field in _allowlistedFields) field.key: field,
    };
    final changedFields = <_TemplateUpdateField>[];
    for (final key in changed.keys) {
      if (key != 'canonical_template_id' && !fieldsByKey.containsKey(key)) {
        throw const ValidationError('テンプレート更新の比較情報が不正です。');
      }
      if (!after.containsKey(key) || changed[key] != after[key]) {
        throw const ValidationError('テンプレート更新の比較情報が不正です。');
      }
      final field = fieldsByKey[key];
      if (field != null) changedFields.add(field);
    }

    return _TemplateUpdateComparison(
      templateVersion: templateVersion,
      courseVersion: courseVersion,
      after: after,
      changedFields: [
        for (final field in _allowlistedFields)
          if (changedFields.any((item) => item.key == field.key)) field,
      ],
    );
  }

  static int? _version(Object? value) {
    if (value is! int || value < 1) {
      return null;
    }
    return value.toInt();
  }

  static int? _slot(Object? value) {
    if (value is! int) {
      return null;
    }
    return value.toInt();
  }

  static Map<String, Object?>? _objectMap(Object? value) {
    if (value is! Map) return null;
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) return null;
      result[entry.key as String] = entry.value;
    }
    return result;
  }
}
