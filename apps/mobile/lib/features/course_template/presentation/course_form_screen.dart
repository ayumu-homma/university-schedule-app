import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/unsaved_changes_guard.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../../notification/presentation/ordinary_notification_permission_prompt.dart';
import '../application/course_template_providers.dart';

class CourseFormScreen extends ConsumerStatefulWidget {
  const CourseFormScreen({
    this.courseId,
    this.initialWeekday,
    this.initialPeriod,
    this.firstCourseContinuation = false,
    super.key,
  });

  final String? courseId;
  final int? initialWeekday;
  final int? initialPeriod;
  final bool firstCourseContinuation;

  @override
  ConsumerState<CourseFormScreen> createState() => _CourseFormScreenState();
}

class _CourseFormScreenState extends ConsumerState<CourseFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _roomController = TextEditingController();
  final _instructorController = TextEditingController();

  int _dayOfWeek = DateTime.monday;
  int _periodNo = 1;
  String? _color = '#2F80ED';
  VisibilityLevel _visibility = VisibilityLevel.private;
  int? _loadedVersion;
  bool _initialized = false;
  bool _saving = false;
  bool _hasUnsavedChanges = false;
  bool _publishTemplate = false;

  static const _colors = ['#2F80ED', '#27AE60', '#9B51E0', '#F2994A'];

  @override
  void dispose() {
    _titleController.dispose();
    _roomController.dispose();
    _instructorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final course = _courseById(state.courses, widget.courseId);
        if (widget.courseId != null && course == null) {
          return const MvpScaffold(
            title: '授業編集',
            selectedIndex: 1,
            showQuickAdd: false,
            child: Center(child: Text('授業が見つかりません')),
          );
        }
        _initialize(course);
        return UnsavedChangesGuard(
          hasUnsavedChanges: _hasUnsavedChanges,
          isSaving: _saving,
          onDiscard: () async {
            if (!mounted) return;
            final destination = widget.courseId == null
                ? widget.firstCourseContinuation
                    ? '/'
                    : '/timetable'
                : '/course/${widget.courseId}';
            context.go(destination);
          },
          child: MvpScaffold(
            title: widget.courseId == null ? '授業を作成' : '授業を編集',
            selectedIndex: 1,
            showQuickAdd: false,
            onBeforeNavigate: _confirmNavigation,
            child: Form(
              key: _formKey,
              onChanged: _markDirty,
              child: ListView(
                key: const Key('course-form-list'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: '授業名',
                      suffixText: '必須',
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '必須です' : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _dayOfWeek,
                          decoration: const InputDecoration(
                            labelText: '曜日',
                            suffixText: '必須',
                          ),
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('月')),
                            DropdownMenuItem(value: 2, child: Text('火')),
                            DropdownMenuItem(value: 3, child: Text('水')),
                            DropdownMenuItem(value: 4, child: Text('木')),
                            DropdownMenuItem(value: 5, child: Text('金')),
                            DropdownMenuItem(value: 6, child: Text('土')),
                            DropdownMenuItem(value: 7, child: Text('日')),
                          ],
                          onChanged: (value) =>
                              setState(() => _dayOfWeek = value ?? _dayOfWeek),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _periodNo,
                          decoration: const InputDecoration(
                            labelText: '時限',
                            suffixText: '必須',
                          ),
                          items: [
                            for (var period = 1; period <= 7; period++)
                              DropdownMenuItem(
                                value: period,
                                child: Text('$period限'),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => _periodNo = value ?? _periodNo),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _roomController,
                    decoration: const InputDecoration(
                      labelText: '教室',
                      suffixText: '任意',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _instructorController,
                    decoration: const InputDecoration(
                      labelText: '教員名',
                      suffixText: '任意',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('色 · 任意', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final color in _colors)
                        ChoiceChip(
                          label: const SizedBox(width: 24, height: 24),
                          selected: _color == color,
                          avatar: CircleAvatar(
                              backgroundColor: _colorFromHex(color)),
                          onSelected: (_) => setState(() {
                            _hasUnsavedChanges = true;
                            _color = color;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<VisibilityLevel>(
                    initialValue: _visibility,
                    decoration: const InputDecoration(
                      labelText: '公開範囲',
                      suffixText: '必須',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: VisibilityLevel.private,
                        child: Text('自分のみ'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.busyOnly,
                        child: Text('予定あり'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.titleOnly,
                        child: Text('タイトルのみ'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.full,
                        child: Text('詳細まで'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _visibility = value ?? _visibility),
                  ),
                  if (widget.courseId == null &&
                      !ref.watch(appConfigProvider).demoMode) ...[
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      key: const Key('course-publish-template'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('同じ大学の学生向けに授業テンプレートを公開'),
                      subtitle: const Text(
                        '授業名・教員・曜日・時限・教室などの公開項目だけが共有されます。'
                        '個人メモ、課題、通知、公開範囲は共有されません。',
                      ),
                      value: _publishTemplate,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                                _publishTemplate = value;
                                _hasUnsavedChanges = true;
                              }),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('course-save'),
                    onPressed: _saving ? null : () => _save(course),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const MvpScaffold(
        title: '授業',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '授業',
        selectedIndex: 1,
        showQuickAdd: false,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  void _initialize(UserCourse? course) {
    if (_initialized) return;
    _initialized = true;
    _titleController.text = course?.title ?? '';
    _roomController.text = course?.room ?? '';
    _instructorController.text = course?.instructorName ?? '';
    _dayOfWeek = course?.dayOfWeek ?? widget.initialWeekday ?? DateTime.monday;
    _periodNo = course?.periodNo ?? widget.initialPeriod ?? 1;
    _color = course?.color ?? _color;
    _visibility = course?.visibilityLevel ?? VisibilityLevel.private;
    _loadedVersion = course?.version;
  }

  Future<void> _save(UserCourse? course) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final input = UserCourseInput(
      title: _titleController.text.trim(),
      dayOfWeek: _dayOfWeek,
      periodNo: _periodNo,
      room: _blankToNull(_roomController.text),
      instructorName: _blankToNull(_instructorController.text),
      color: _color,
      visibilityLevel: _visibility,
    );
    try {
      if (course == null) {
        final id = await ref
            .read(demoAppControllerProvider.notifier)
            .createUserCourse(input);
        if (_publishTemplate && !ref.read(appConfigProvider).demoMode) {
          try {
            final publication = await ref
                .read(courseTemplateRepositoryProvider)
                .publishTemplate(courseId: id);
            final queued = publication['status'] == 'queued';
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(queued
                      ? '個人授業を保存し、公開処理を同期キューに追加しました'
                      : '個人授業を保存し、授業テンプレートを公開しました'),
                ),
              );
            }
          } on AppError catch (error) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content:
                        Text('個人授業は保存済みですが、共有投稿に失敗しました: ${error.message}')),
              );
            }
          } on Object {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('個人授業は保存済みですが、共有投稿は未送信です。後で再試行してください。')),
              );
            }
          }
        }
        if (mounted && widget.firstCourseContinuation) {
          await offerFirstCourseNotificationEducation(context, ref);
        }
        if (mounted) {
          setState(() => _hasUnsavedChanges = false);
          context.go(
            widget.firstCourseContinuation ? '/' : '/course/$id',
          );
        }
      } else {
        await ref
            .read(demoAppControllerProvider.notifier)
            .updateUserCourse(course.id, _loadedVersion!, input);
        if (mounted) {
          setState(() => _hasUnsavedChanges = false);
          context.go('/course/${course.id}');
        }
      }
    } catch (error) {
      _showOperationError(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showOperationError(Object error) {
    if (!mounted) return;
    final message = error is ConflictError
        ? '別の変更が反映されました。画面を開き直して確認してください。'
        : '保存に失敗しました。入力内容を確認して再試行してください。';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  UserCourse? _courseById(List<UserCourse> courses, String? id) {
    if (id == null) return null;
    for (final course in courses) {
      if (course.id == id) return course;
    }
    return null;
  }

  Color _colorFromHex(String value) {
    return Color(int.parse(value.replaceFirst('#', '0xff')));
  }
}
