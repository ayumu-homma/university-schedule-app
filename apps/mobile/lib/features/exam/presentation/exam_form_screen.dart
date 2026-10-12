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

class ExamFormScreen extends ConsumerStatefulWidget {
  const ExamFormScreen({this.examId, super.key});

  final String? examId;

  @override
  ConsumerState<ExamFormScreen> createState() => _ExamFormScreenState();
}

class _ExamFormScreenState extends ConsumerState<ExamFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _roomController = TextEditingController();
  final _memoController = TextEditingController();
  final _examTypeController = TextEditingController();

  late DateTime _startAt;
  late DateTime _endAt;
  String? _courseId;
  int? _loadedVersion;
  bool _initialized = false;
  bool _saving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    final now = JapanTime.civil(ref.read(appClockProvider).now());
    _startAt = JapanTime.at(
      year: now.year,
      month: now.month,
      day: now.day,
      hour: now.hour + 1,
    );
    _endAt = _startAt.add(const Duration(minutes: 90));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _roomController.dispose();
    _memoController.dispose();
    _examTypeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final exam = _examById(state.exams, widget.examId);
        if (widget.examId != null && exam == null) {
          return const MvpScaffold(
            title: 'テスト編集',
            selectedIndex: 2,
            showQuickAdd: false,
            child: Center(child: Text('テストが見つかりません')),
          );
        }
        _initialize(exam);
        final storedCourseId = exam?.courseId;
        final courseLink = storedCourseId == null
            ? const AsyncData<UserCourse?>(null)
            : ref.watch(activeCourseByIdProvider(storedCourseId));
        if (courseLink.isLoading) {
          return MvpScaffold(
            title: widget.examId == null ? 'テストを作成' : 'テストを編集',
            selectedIndex: 2,
            showQuickAdd: false,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (courseLink.hasError) {
          return MvpScaffold(
            title: widget.examId == null ? 'テストを作成' : 'テストを編集',
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
            title: widget.examId == null ? 'テストを作成' : 'テストを編集',
            selectedIndex: 2,
            showQuickAdd: false,
            onBeforeNavigate: _confirmNavigation,
            child: ResponsiveContent(
              maxWidth: AppSizes.formMaxWidth,
              child: Form(
                key: _formKey,
                onChanged: _markDirty,
                child: ListView(
                  key: const Key('exam-form-list'),
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    TextFormField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'テスト名',
                        suffixText: '必須',
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (value) =>
                          value == null || value.trim().isEmpty ? '必須です' : null,
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      leading: const Icon(Icons.play_arrow_outlined),
                      title: const Text('開始'),
                      subtitle: Text('${_formatDateTime(_startAt)} · 必須'),
                      onTap: () => _pickDateTime(isStart: true),
                    ),
                    ListTile(
                      leading: const Icon(Icons.stop_outlined),
                      title: const Text('終了'),
                      subtitle: Text('${_formatDateTime(_endAt)} · 必須'),
                      onTap: () => _pickDateTime(isStart: false),
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
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _roomController,
                      decoration: const InputDecoration(
                        labelText: '教室',
                        suffixText: '任意',
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _examTypeController,
                      decoration: const InputDecoration(
                        labelText: '種別',
                        suffixText: '任意',
                        hintText: '例: 中間試験、発表',
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _memoController,
                      decoration: const InputDecoration(
                        labelText: 'メモ',
                        suffixText: '任意',
                      ),
                      maxLines: 3,
                      textInputAction: TextInputAction.newline,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('exam-save'),
                      onPressed: _saving
                          ? null
                          : () => _save(
                                exam,
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
                    if (exam != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : () => _delete(exam),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('このテストを削除'),
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
        title: 'テスト',
        selectedIndex: 2,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: 'テスト',
        selectedIndex: 2,
        showQuickAdd: false,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  void _initialize(Exam? exam) {
    if (_initialized) return;
    _initialized = true;
    _titleController.text = exam?.title ?? '';
    _roomController.text = exam?.room ?? '';
    _memoController.text = exam?.memo ?? exam?.scope ?? '';
    _examTypeController.text = exam?.examType ?? '';
    _startAt = exam?.startAt ?? _startAt;
    _endAt = exam?.endAt ?? _endAt;
    _courseId = exam?.courseId;
    _loadedVersion = exam?.version;
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final current = isStart ? _startAt : _endAt;
    final currentCivil = JapanTime.civil(current).pickerDateTime;
    final date = await showDatePicker(
      context: context,
      initialDate: currentCivil,
      firstDate: _dateYearsFromNow(-1),
      lastDate: _dateYearsFromNow(5, endOfYear: true),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentCivil),
    );
    if (time == null || !mounted) return;
    final next = JapanTime.at(
      year: date.year,
      month: date.month,
      day: date.day,
      hour: time.hour,
      minute: time.minute,
    );
    setState(() {
      _hasUnsavedChanges = true;
      if (isStart) {
        _startAt = next;
        if (!_endAt.isAfter(_startAt)) {
          _endAt = _startAt.add(const Duration(minutes: 90));
        }
      } else {
        _endAt = next;
      }
    });
  }

  Future<void> _save(
    Exam? exam, {
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
    if (!_endAt.isAfter(_startAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('終了は開始より後にしてください')),
      );
      return;
    }
    setState(() => _saving = true);
    final input = ExamInput(
      title: _titleController.text.trim(),
      startAt: _startAt,
      endAt: _endAt,
      courseId: _courseId,
      room: _blankToNull(_roomController.text),
      memo: _blankToNull(_memoController.text),
      examType: _blankToNull(_examTypeController.text),
    );
    try {
      if (exam == null) {
        await ref.read(demoAppControllerProvider.notifier).createExam(input);
      } else {
        await ref
            .read(demoAppControllerProvider.notifier)
            .updateExam(exam.id, _loadedVersion!, input);
      }
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/exams');
      }
    } catch (error) {
      _showOperationError(error, action: '保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(Exam exam) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('テストを削除しますか？'),
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
          .deleteExam(exam.id, _loadedVersion!);
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/exams');
      }
    } catch (error) {
      _showOperationError(error, action: '削除');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Exam? _examById(List<Exam> exams, String? id) {
    if (id == null) return null;
    for (final exam in exams) {
      if (exam.id == id) return exam;
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
