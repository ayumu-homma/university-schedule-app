import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/error/app_error.dart';
import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/responsive_content.dart';
import '../../../shared/widgets/unsaved_changes_guard.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../../notification/presentation/ordinary_notification_permission_prompt.dart';

class AssignmentFormScreen extends ConsumerStatefulWidget {
  const AssignmentFormScreen(
      {this.assignmentId, this.initialCourseId, super.key});

  final String? assignmentId;
  final String? initialCourseId;

  @override
  ConsumerState<AssignmentFormScreen> createState() =>
      _AssignmentFormScreenState();
}

class _AssignmentFormScreenState extends ConsumerState<AssignmentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _memoController = TextEditingController();

  DateTime? _dueAt;
  String? _courseId;
  String? _priority;
  int? _loadedVersion;
  bool _initialized = false;
  bool _saving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    // A new assignment has no due date until the user explicitly chooses
    // both date and time. Guessing a deadline can create a misleading task.
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final assignment =
            _assignmentById(state.assignments, widget.assignmentId);
        if (widget.assignmentId != null && assignment == null) {
          return const MvpScaffold(
            title: '課題編集',
            selectedIndex: 2,
            showQuickAdd: false,
            child: Center(child: Text('課題が見つかりません')),
          );
        }
        _initialize(assignment);
        final storedCourseId = assignment?.courseId ?? _initialCourseId;
        final courseLink = storedCourseId == null
            ? const AsyncData<UserCourse?>(null)
            : ref.watch(activeCourseByIdProvider(storedCourseId));
        if (courseLink.isLoading) {
          return MvpScaffold(
            title: widget.assignmentId == null ? '課題を作成' : '課題を編集',
            selectedIndex: 2,
            showQuickAdd: false,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (courseLink.hasError) {
          return MvpScaffold(
            title: widget.assignmentId == null ? '課題を作成' : '課題を編集',
            selectedIndex: 2,
            showQuickAdd: false,
            child: Center(
              child: FilledButton.icon(
                onPressed: () =>
                    ref.invalidate(activeCourseByIdProvider(storedCourseId!)),
                icon: const Icon(Icons.refresh),
                label: const Text('授業の状態を再確認'),
              ),
            ),
          );
        }
        final linkedCourse = courseLink.valueOrNull;
        final hasDeletedCourseLink = storedCourseId != null &&
            linkedCourse == null &&
            _courseId == storedCourseId;
        final availableCourses = [
          ...state.courses,
          if (linkedCourse != null &&
              !state.courses.any((course) => course.id == linkedCourse.id) &&
              _courseId == linkedCourse.id)
            linkedCourse,
        ];
        return UnsavedChangesGuard(
          hasUnsavedChanges: _hasUnsavedChanges,
          isSaving: _saving,
          child: MvpScaffold(
            title: widget.assignmentId == null ? '課題を作成' : '課題を編集',
            selectedIndex: 2,
            showQuickAdd: false,
            onBeforeNavigate: _confirmNavigation,
            child: ResponsiveContent(
              maxWidth: AppSizes.formMaxWidth,
              child: Form(
                key: _formKey,
                onChanged: _markDirty,
                child: ListView(
                  key: const Key('assignment-form-list'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    Text(
                      '基本情報',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: '課題名',
                        suffixText: '必須',
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          value == null || value.trim().isEmpty ? '必須です' : null,
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      key: const Key('assignment-due-field'),
                      leading: const Icon(Icons.schedule_outlined),
                      title: const Text('締切'),
                      subtitle: Text(_dueAt == null
                          ? '日付と時刻を選択してください · 必須'
                          : '${_formatDateTime(_dueAt!)} · 必須'),
                      onTap: _pickDueAt,
                    ),
                    const SizedBox(height: 12),
                    if (hasDeletedCourseLink) ...[
                      const Text(
                        '元の授業は削除されています。授業を「なし」または別の授業に変更してから保存してください。',
                      ),
                      const SizedBox(height: 12),
                    ],
                    DropdownButtonFormField<String>(
                      initialValue: _courseId ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '授業',
                        suffixText: '任意',
                      ),
                      items: [
                        if (hasDeletedCourseLink)
                          DropdownMenuItem(
                            value: storedCourseId,
                            child: const Text('削除済みの授業（選び直してください）'),
                          ),
                        const DropdownMenuItem(value: '', child: Text('なし')),
                        for (final course in availableCourses)
                          DropdownMenuItem(
                            value: course.id,
                            child: Text(
                              course.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        setState(() => _courseId = value == '' ? null : value);
                      },
                    ),
                    if (_courseId != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '選択中: ${_selectedCourseLabel(availableCourses, _courseId!)}',
                          softWrap: true,
                        ),
                      ),
                    if (widget.assignmentId == null &&
                        !hasDeletedCourseLink &&
                        _initialCourseId != null &&
                        _courseId == _initialCourseId)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          '授業起点から引き継いでいます。必要なら変更できます。',
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      '補足（任意）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _memoController,
                      decoration: const InputDecoration(
                        labelText: 'メモ',
                        suffixText: '任意',
                      ),
                      maxLines: 3,
                      textInputAction: TextInputAction.newline,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _priority ?? '',
                      decoration: const InputDecoration(
                        labelText: '優先度',
                        suffixText: '任意',
                      ),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('未設定')),
                        DropdownMenuItem(value: 'low', child: Text('低')),
                        DropdownMenuItem(value: 'normal', child: Text('通常')),
                        DropdownMenuItem(value: 'high', child: Text('高')),
                      ],
                      onChanged: (value) {
                        setState(() => _priority = value == '' ? null : value);
                      },
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      key: const Key('assignment-save'),
                      onPressed: _saving
                          ? null
                          : () => _save(
                                assignment,
                                hasDeletedCourseLink: hasDeletedCourseLink,
                              ),
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: AppSizes.iconSmall,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? '保存中' : '保存'),
                    ),
                    if (assignment != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : () => _delete(assignment),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('この課題を削除'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const MvpScaffold(
        title: '課題',
        selectedIndex: 2,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '課題',
        selectedIndex: 2,
        showQuickAdd: false,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  void _initialize(Assignment? assignment) {
    if (_initialized) return;
    _initialized = true;
    _titleController.text = assignment?.title ?? '';
    _memoController.text = assignment?.description ?? '';
    _dueAt = assignment?.dueAt ?? _dueAt;
    _courseId = assignment?.courseId ?? _initialCourseId;
    _priority = assignment?.priority;
    _loadedVersion = assignment?.version;
  }

  String? get _initialCourseId {
    final normalized = widget.initialCourseId?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  String _selectedCourseLabel(List<UserCourse> courses, String courseId) {
    for (final course in courses) {
      if (course.id == courseId) return course.title;
    }
    return '削除済みの授業';
  }

  Future<void> _pickDueAt() async {
    final currentCivil =
        JapanTime.civil(_dueAt ?? ref.read(appClockProvider).now())
            .pickerDateTime;
    final date = await showDatePicker(
      context: context,
      initialDate: currentCivil,
      currentDate:
          JapanTime.civil(ref.read(appClockProvider).now()).pickerDateTime,
      firstDate: _dateYearsFromNow(-1),
      lastDate: _dateYearsFromNow(5, endOfYear: true),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentCivil),
    );
    if (time == null || !mounted) return;
    setState(() {
      _hasUnsavedChanges = true;
      _dueAt = JapanTime.at(
        year: date.year,
        month: date.month,
        day: date.day,
        hour: time.hour,
        minute: time.minute,
      );
    });
  }

  Future<void> _save(
    Assignment? assignment, {
    required bool hasDeletedCourseLink,
  }) async {
    if (!_formKey.currentState!.validate()) return;
    if (hasDeletedCourseLink) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('削除済みの授業を「なし」または別の授業に変更してください。'),
        ),
      );
      return;
    }
    final dueAt = _dueAt;
    if (dueAt == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('締切の日付と時刻を選択してください。')),
      );
      return;
    }
    setState(() => _saving = true);
    final input = AssignmentInput(
      title: _titleController.text.trim(),
      dueAt: dueAt,
      courseId: _courseId,
      // The URL field is intentionally absent from this form. Preserve it
      // during edits so the presentation change cannot erase existing data.
      submissionUrl: assignment?.submissionUrl,
      memo: _blankToNull(_memoController.text),
      priority: _priority,
      visibilityLevel: assignment?.visibilityLevel ?? VisibilityLevel.private,
    );
    try {
      if (assignment == null) {
        await ref
            .read(demoAppControllerProvider.notifier)
            .createAssignment(input);
      } else {
        await ref
            .read(demoAppControllerProvider.notifier)
            .updateAssignment(assignment.id, _loadedVersion!, input);
      }
      if (assignment == null && mounted) {
        await offerPostRegistrationNotificationPermissionPrompt(context, ref);
      }
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/assignments');
      }
    } catch (error) {
      _showOperationError(error, action: '保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(Assignment assignment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('課題を削除しますか？'),
        content: const Text('端末ではすぐ非表示になり、削除は同期キューに保存されます。'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(demoAppControllerProvider.notifier)
          .deleteAssignment(assignment.id, _loadedVersion!);
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/assignments');
      }
    } catch (error) {
      _showOperationError(error, action: '削除');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Assignment? _assignmentById(List<Assignment> assignments, String? id) {
    if (id == null) return null;
    for (final assignment in assignments) {
      if (assignment.id == id) return assignment;
    }
    return null;
  }

  void _markDirty() {
    if (!_initialized || _hasUnsavedChanges) return;
    setState(() => _hasUnsavedChanges = true);
  }

  Future<bool> _confirmNavigation() async {
    final discard = await confirmDiscardUnsavedChanges(
      context,
      hasUnsavedChanges: _hasUnsavedChanges,
      isSaving: _saving,
    );
    if (discard && mounted && _hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = false);
    }
    return discard;
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showOperationError(Object error, {required String action}) {
    if (!mounted) return;
    final message = error is ConflictError
        ? '別の変更が反映されました。画面を開き直して確認してください。'
        : '$actionに失敗しました。もう一度お試しください。';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDateTime(DateTime value) {
    final civil = JapanTime.civil(value);
    final minute = civil.minute.toString().padLeft(2, '0');
    return '${civil.year}/${civil.month}/${civil.day} ${civil.hour}:$minute';
  }

  DateTime _dateYearsFromNow(int years, {bool endOfYear = false}) {
    final now = JapanTime.civil(ref.read(appClockProvider).now());
    return endOfYear
        ? DateTime.utc(now.year + years, 12, 31)
        : DateTime.utc(now.year + years, now.month, now.day);
  }
}
