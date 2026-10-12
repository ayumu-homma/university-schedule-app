import 'dart:async';

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
import '../application/assignment_undo.dart';
import 'assignment_undo_feedback.dart';
import '../../timetable/application/demo_app_controller.dart';

enum AssignmentListFilter { open, today, week, done }

class AssignmentListScreen extends ConsumerStatefulWidget {
  const AssignmentListScreen({super.key});

  @override
  ConsumerState<AssignmentListScreen> createState() =>
      _AssignmentListScreenState();
}

class _AssignmentListScreenState extends ConsumerState<AssignmentListScreen> {
  AssignmentListFilter _filter = AssignmentListFilter.open;
  _AssignmentCourseFilter _courseFilter = const _AssignmentCourseFilter.all();
  final Set<String> _updatingAssignmentIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    final now = ref.watch(appClockProvider).now().toUtc();
    return asyncState.when(
      data: (state) => _AssignmentListContent(
        state: state,
        now: now,
        filter: _filter,
        courseFilter: _courseFilter,
        updatingAssignmentIds: _updatingAssignmentIds,
        onFilterChanged: (filter) => setState(() => _filter = filter),
        onCourseFilterChanged: (filter) =>
            setState(() => _courseFilter = filter),
        onStatusChanged: _updateAssignmentStatus,
      ),
      loading: () => const MvpScaffold(
        title: '課題・テスト',
        selectedIndex: 2,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '課題・テスト',
        selectedIndex: 2,
        child: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: '課題を読み込めませんでした',
          message: '通信状態を確認して、もう一度お試しください。',
          action: FilledButton.icon(
            onPressed: () => ref.invalidate(demoAppControllerProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('再読み込み'),
          ),
        ),
      ),
    );
  }

  Future<void> _updateAssignmentStatus(
    Assignment assignment,
    AssignmentStatus status,
  ) async {
    if (_updatingAssignmentIds.contains(assignment.id)) return;
    final controller = ref.read(demoAppControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updatingAssignmentIds.add(assignment.id));

    try {
      AssignmentUndoOperation? undoOperation;
      if (status == AssignmentStatus.submitted) {
        undoOperation =
            await controller.submitAssignmentWithUndo(assignment.id);
      } else {
        await controller.setAssignmentStatus(assignment.id, status);
      }
      final message = switch (status) {
        AssignmentStatus.submitted => '「${assignment.title}」を提出済みにしました。',
        AssignmentStatus.inProgress => '「${assignment.title}」を進行中にしました。',
        AssignmentStatus.notStarted => '「${assignment.title}」を未着手に戻しました。',
        AssignmentStatus.overdue => '',
      };
      if (message.isNotEmpty) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              action: undoOperation == null
                  ? null
                  : SnackBarAction(
                      label: '元に戻す',
                      onPressed: () {
                        unawaited(
                          runAssignmentUndoWithFeedback(
                            undoOperation!,
                            messenger,
                          ),
                        );
                      },
                    ),
            ),
          );
      }
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('提出状態を更新できませんでした。もう一度お試しください。'),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _updatingAssignmentIds.remove(assignment.id));
      }
    }
  }
}

class _AssignmentListContent extends StatelessWidget {
  const _AssignmentListContent({
    required this.state,
    required this.now,
    required this.filter,
    required this.courseFilter,
    required this.updatingAssignmentIds,
    required this.onFilterChanged,
    required this.onCourseFilterChanged,
    required this.onStatusChanged,
  });

  final DemoAppState state;
  final DateTime now;
  final AssignmentListFilter filter;
  final _AssignmentCourseFilter courseFilter;
  final Set<String> updatingAssignmentIds;
  final ValueChanged<AssignmentListFilter> onFilterChanged;
  final ValueChanged<_AssignmentCourseFilter> onCourseFilterChanged;
  final Future<void> Function(Assignment assignment, AssignmentStatus status)
      onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final coursesById = {
      for (final course in state.courses) course.id: course,
      for (final course in state.assignmentCourses) course.id: course,
    };
    final assignmentCourseIds = state.assignments
        .map((assignment) => assignment.courseId)
        .whereType<String>()
        .toSet();
    final assignmentCourses = assignmentCourseIds
        .map((courseId) => coursesById[courseId])
        .whereType<UserCourse>()
        .toList()
      ..sort((left, right) => left.title.compareTo(right.title));
    final hasUnassigned =
        state.assignments.any((assignment) => assignment.courseId == null);
    final hasDeletedCourse = assignmentCourseIds
        .any((courseId) => !coursesById.containsKey(courseId));
    final selectedCourseFilter = courseFilter.isAvailable(
      courses: assignmentCourses,
      hasUnassigned: hasUnassigned,
      hasDeletedCourse: hasDeletedCourse,
    )
        ? courseFilter
        : const _AssignmentCourseFilter.all();
    const statusResolver = AssignmentStatusResolver();
    final assignments = state.assignments
        .where(
          (assignment) => _matchesFilter(
            assignment: assignment,
            coursesById: coursesById,
            courseFilter: selectedCourseFilter,
            statusResolver: statusResolver,
          ),
        )
        .toList()
      ..sort((left, right) => left.dueAt.compareTo(right.dueAt));
    final exams = [...state.exams]
      ..sort((left, right) => left.startAt.compareTo(right.startAt));
    final assignmentGroups = _groupAssignments(
      assignments,
      statusResolver: statusResolver,
    );

    return MvpScaffold(
      title: '課題・テスト',
      selectedIndex: 2,
      actions: [
        IconButton(
          tooltip: '課題を追加',
          onPressed: () => context.go('/assignments/new'),
          icon: const Icon(Icons.add),
        ),
        IconButton(
          tooltip: 'テスト一覧',
          onPressed: () => context.go('/exams'),
          icon: const Icon(Icons.quiz_outlined),
        ),
      ],
      child: ResponsiveContent(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Semantics(
              container: true,
              label: '課題の表示期間',
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final value in AssignmentListFilter.values)
                    ChoiceChip(
                      key: ValueKey('assignment-filter-${value.name}'),
                      selected: filter == value,
                      onSelected: (_) => onFilterChanged(value),
                      avatar: Icon(
                        _filterIcon(value),
                        size: AppSizes.iconSmall,
                      ),
                      label: Text(_filterLabel(value)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _AssignmentCourseFilterSelector(
              selected: selectedCourseFilter,
              courses: assignmentCourses,
              hasUnassigned: hasUnassigned,
              hasDeletedCourse: hasDeletedCourse,
              onChanged: onCourseFilterChanged,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (assignments.isEmpty)
              _AssignmentEmptyState(filter: filter)
            else
              for (final group in assignmentGroups) ...[
                AppSectionHeader(
                  title: group.label,
                  icon: group.icon,
                  count: group.items.length,
                ),
                const SizedBox(height: AppSpacing.xs),
                for (final item in group.items) ...[
                  _AssignmentTile(
                    assignment: item.assignment,
                    rawStatus: item.rawStatus,
                    effectiveStatus: item.effectiveStatus,
                    courseLabel: _courseLabel(item.assignment, coursesById),
                    now: now,
                    isUpdating:
                        updatingAssignmentIds.contains(item.assignment.id),
                    onEdit: () => context.go(
                      '/assignment/${item.assignment.id}/edit',
                    ),
                    onDetail: () => context.go(
                      '/assignment/${item.assignment.id}',
                    ),
                    onStatusChanged: (status) =>
                        onStatusChanged(item.assignment, status),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                const SizedBox(height: AppSpacing.md),
              ],
            const SizedBox(height: AppSpacing.xs),
            AppSectionHeader(
              title: 'テスト',
              icon: Icons.quiz_outlined,
              count: exams.length,
            ),
            const SizedBox(height: AppSpacing.xs),
            if (exams.isEmpty)
              Text(
                '登録されたテストはありません。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              )
            else
              for (final exam in exams) ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.quiz_outlined),
                    title: Text(exam.title),
                    subtitle: Text(_examDateLabel(exam.startAt)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.go('/exam/${exam.id}/edit'),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  List<_AssignmentGroup> _groupAssignments(
    List<Assignment> assignments, {
    required AssignmentStatusResolver statusResolver,
  }) {
    final grouped = <_AssignmentGroupKind, List<_AssignmentListItem>>{
      for (final kind in _AssignmentGroupKind.values) kind: [],
    };
    final civilNow = JapanTime.civil(now).pickerDateTime;
    for (final assignment in assignments) {
      final rawStatus = state.assignmentStates[assignment.id]?.status ??
          AssignmentStatus.notStarted;
      final effectiveStatus = statusResolver.effectiveStatus(
        assignment: assignment,
        state: state.assignmentStates[assignment.id],
        now: now,
      );
      final dueAt = JapanTime.civil(assignment.dueAt).pickerDateTime;
      final kind = effectiveStatus == AssignmentStatus.submitted
          ? _AssignmentGroupKind.submitted
          : effectiveStatus == AssignmentStatus.overdue
              ? _AssignmentGroupKind.overdue
              : _isSameDate(dueAt, civilNow)
                  ? _AssignmentGroupKind.today
                  : _isInCurrentWeek(dueAt, civilNow)
                      ? _AssignmentGroupKind.thisWeek
                      : _AssignmentGroupKind.later;
      grouped[kind]!.add(
        _AssignmentListItem(
          assignment: assignment,
          rawStatus: rawStatus,
          effectiveStatus: effectiveStatus,
        ),
      );
    }
    return [
      for (final kind in _AssignmentGroupKind.values)
        if (grouped[kind]!.isNotEmpty)
          _AssignmentGroup(kind: kind, items: grouped[kind]!),
    ];
  }

  bool _matchesFilter({
    required Assignment assignment,
    required Map<String, UserCourse> coursesById,
    required _AssignmentCourseFilter courseFilter,
    required AssignmentStatusResolver statusResolver,
  }) {
    if (!_matchesCourseFilter(assignment, coursesById, courseFilter)) {
      return false;
    }
    final effectiveStatus = statusResolver.effectiveStatus(
      assignment: assignment,
      state: state.assignmentStates[assignment.id],
      now: now,
    );
    final submitted = effectiveStatus == AssignmentStatus.submitted;
    final dueAt = JapanTime.civil(assignment.dueAt).pickerDateTime;
    final civilNow = JapanTime.civil(now).pickerDateTime;
    return switch (filter) {
      AssignmentListFilter.open => !submitted,
      AssignmentListFilter.today => !submitted && _isSameDate(dueAt, civilNow),
      AssignmentListFilter.week =>
        !submitted && _isInCurrentWeek(dueAt, civilNow),
      AssignmentListFilter.done => submitted,
    };
  }
}

enum _AssignmentGroupKind { overdue, today, thisWeek, later, submitted }

class _AssignmentListItem {
  const _AssignmentListItem({
    required this.assignment,
    required this.rawStatus,
    required this.effectiveStatus,
  });

  final Assignment assignment;
  final AssignmentStatus rawStatus;
  final AssignmentStatus effectiveStatus;
}

class _AssignmentGroup {
  const _AssignmentGroup({required this.kind, required this.items});

  final _AssignmentGroupKind kind;
  final List<_AssignmentListItem> items;

  String get label => switch (kind) {
        _AssignmentGroupKind.overdue => '期限切れの課題',
        _AssignmentGroupKind.today => '今日まで',
        _AssignmentGroupKind.thisWeek => '今週中',
        _AssignmentGroupKind.later => 'それ以降',
        _AssignmentGroupKind.submitted => '提出後の履歴',
      };

  IconData get icon => switch (kind) {
        _AssignmentGroupKind.overdue => Icons.error_outline,
        _AssignmentGroupKind.today => Icons.today_outlined,
        _AssignmentGroupKind.thisWeek => Icons.date_range_outlined,
        _AssignmentGroupKind.later => Icons.event_note_outlined,
        _AssignmentGroupKind.submitted => Icons.task_alt,
      };
}

class _AssignmentCourseFilterSelector extends StatelessWidget {
  const _AssignmentCourseFilterSelector({
    required this.selected,
    required this.courses,
    required this.hasUnassigned,
    required this.hasDeletedCourse,
    required this.onChanged,
  });

  final _AssignmentCourseFilter selected;
  final List<UserCourse> courses;
  final bool hasUnassigned;
  final bool hasDeletedCourse;
  final ValueChanged<_AssignmentCourseFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<_AssignmentCourseFilter>(
      key: const Key('assignment-course-filter'),
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '授業別',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(
          key: Key('assignment-course-option-all'),
          value: _AssignmentCourseFilter.all(),
          child: Text('すべての授業'),
        ),
        for (final course in courses)
          DropdownMenuItem(
            key: ValueKey('assignment-course-option-${course.id}'),
            value: _AssignmentCourseFilter.course(course.id),
            child: Text(course.title, overflow: TextOverflow.ellipsis),
          ),
        if (hasUnassigned)
          const DropdownMenuItem(
            key: Key('assignment-course-option-unassigned'),
            value: _AssignmentCourseFilter.unassigned(),
            child: Text('授業なし'),
          ),
        if (hasDeletedCourse)
          const DropdownMenuItem(
            key: Key('assignment-course-option-deleted'),
            value: _AssignmentCourseFilter.deleted(),
            child: Text('削除済みの授業'),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class _AssignmentEmptyState extends StatelessWidget {
  const _AssignmentEmptyState({required this.filter});

  final AssignmentListFilter filter;

  @override
  Widget build(BuildContext context) {
    final (title, message, icon) = switch (filter) {
      AssignmentListFilter.open => (
          '未提出の課題はありません',
          '新しい課題が出たら登録しましょう。',
          Icons.task_alt,
        ),
      AssignmentListFilter.today => (
          '今日締切の課題はありません',
          '今週の課題も確認しておくと安心です。',
          Icons.today_outlined,
        ),
      AssignmentListFilter.week => (
          '今週締切の課題はありません',
          '未提出タブでその先の課題を確認できます。',
          Icons.event_available_outlined,
        ),
      AssignmentListFilter.done => (
          '提出済みの課題はまだありません',
          '課題を提出済みにすると、ここに履歴が残ります。',
          Icons.history,
        ),
    };
    return EmptyState(
      icon: icon,
      title: title,
      message: message,
      action: filter == AssignmentListFilter.open
          ? OutlinedButton.icon(
              onPressed: () => context.go('/assignments/new'),
              icon: const Icon(Icons.add),
              label: const Text('課題を追加'),
            )
          : null,
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  const _AssignmentTile({
    required this.assignment,
    required this.rawStatus,
    required this.effectiveStatus,
    required this.courseLabel,
    required this.now,
    required this.isUpdating,
    required this.onEdit,
    required this.onDetail,
    required this.onStatusChanged,
  });

  final Assignment assignment;
  final AssignmentStatus rawStatus;
  final AssignmentStatus effectiveStatus;
  final String courseLabel;
  final DateTime now;
  final bool isUpdating;
  final VoidCallback onEdit;
  final VoidCallback onDetail;
  final Future<void> Function(AssignmentStatus status) onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final submitted = effectiveStatus == AssignmentStatus.submitted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onDetail,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        assignment.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _AssignmentStatusMenu(
                  assignmentId: assignment.id,
                  rawStatus: rawStatus,
                  effectiveStatus: effectiveStatus,
                  enabled: !isUpdating,
                  onSelected: (status) => onStatusChanged(status),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              submitted ? '$courseLabel · 提出済み · 履歴に保存' : courseLabel,
            ),
            const SizedBox(height: 2),
            Text(
              _dueLabel(assignment.dueAt, now, submitted: submitted),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 6,
              children: [
                Semantics(
                  button: true,
                  enabled: !isUpdating,
                  label: '「${assignment.title}」を編集',
                  onTap: isUpdating ? null : onEdit,
                  excludeSemantics: true,
                  child: IconButton(
                    tooltip: '「${assignment.title}」を編集',
                    onPressed: isUpdating ? null : onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
                if (!submitted)
                  Semantics(
                    button: true,
                    label: '提出済みを記録',
                    child: OutlinedButton.icon(
                      onPressed: isUpdating
                          ? null
                          : () => onStatusChanged(AssignmentStatus.submitted),
                      icon: isUpdating
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_file, size: 18),
                      label: Text(isUpdating ? '更新中' : '提出済みを記録'),
                    ),
                  ),
                TextButton.icon(
                  onPressed: onDetail,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('詳細'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignmentStatusMenu extends StatelessWidget {
  const _AssignmentStatusMenu({
    required this.assignmentId,
    required this.rawStatus,
    required this.effectiveStatus,
    required this.enabled,
    required this.onSelected,
  });

  final String assignmentId;
  final AssignmentStatus rawStatus;
  final AssignmentStatus effectiveStatus;
  final bool enabled;
  final ValueChanged<AssignmentStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    final (tone, icon) = switch (effectiveStatus) {
      AssignmentStatus.notStarted => (
          AppStatusTone.neutral,
          Icons.radio_button_unchecked,
        ),
      AssignmentStatus.inProgress => (
          AppStatusTone.warning,
          Icons.pending_actions,
        ),
      AssignmentStatus.submitted => (
          AppStatusTone.success,
          Icons.check_circle_outline,
        ),
      AssignmentStatus.overdue => (
          AppStatusTone.critical,
          Icons.error_outline,
        ),
    };
    return PopupMenuButton<AssignmentStatus>(
      key: ValueKey('assignment-status-$assignmentId'),
      tooltip: '状態を変更',
      enabled: enabled,
      onSelected: onSelected,
      itemBuilder: (context) => [
        if (rawStatus != AssignmentStatus.notStarted)
          const PopupMenuItem(
            value: AssignmentStatus.notStarted,
            child: Text('未着手に戻す'),
          ),
        if (rawStatus != AssignmentStatus.inProgress)
          const PopupMenuItem(
            value: AssignmentStatus.inProgress,
            child: Text('進行中にする'),
          ),
      ],
      child: Semantics(
        button: true,
        label: '状態: ${_statusLabel(effectiveStatus)}。状態を変更',
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AppSizes.minimumTouchTarget,
            minHeight: AppSizes.minimumTouchTarget,
          ),
          child: Center(
            child: AppStatusBadge(
              label: _statusLabel(effectiveStatus),
              icon: icon,
              tone: tone,
              excludeFromSemantics: true,
            ),
          ),
        ),
      ),
    );
  }
}

enum _AssignmentCourseFilterKind { all, course, unassigned, deleted }

class _AssignmentCourseFilter {
  const _AssignmentCourseFilter.all()
      : kind = _AssignmentCourseFilterKind.all,
        courseId = null;

  const _AssignmentCourseFilter.course(String this.courseId)
      : kind = _AssignmentCourseFilterKind.course;

  const _AssignmentCourseFilter.unassigned()
      : kind = _AssignmentCourseFilterKind.unassigned,
        courseId = null;

  const _AssignmentCourseFilter.deleted()
      : kind = _AssignmentCourseFilterKind.deleted,
        courseId = null;

  final _AssignmentCourseFilterKind kind;
  final String? courseId;

  bool isAvailable({
    required List<UserCourse> courses,
    required bool hasUnassigned,
    required bool hasDeletedCourse,
  }) {
    return switch (kind) {
      _AssignmentCourseFilterKind.all => true,
      _AssignmentCourseFilterKind.course =>
        courses.any((course) => course.id == courseId),
      _AssignmentCourseFilterKind.unassigned => hasUnassigned,
      _AssignmentCourseFilterKind.deleted => hasDeletedCourse,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is _AssignmentCourseFilter &&
      other.kind == kind &&
      other.courseId == courseId;

  @override
  int get hashCode => Object.hash(kind, courseId);
}

bool _matchesCourseFilter(
  Assignment assignment,
  Map<String, UserCourse> coursesById,
  _AssignmentCourseFilter courseFilter,
) {
  return switch (courseFilter.kind) {
    _AssignmentCourseFilterKind.all => true,
    _AssignmentCourseFilterKind.course =>
      assignment.courseId == courseFilter.courseId,
    _AssignmentCourseFilterKind.unassigned => assignment.courseId == null,
    _AssignmentCourseFilterKind.deleted => assignment.courseId != null &&
        !coursesById.containsKey(assignment.courseId),
  };
}

String _courseLabel(
    Assignment assignment, Map<String, UserCourse> coursesById) {
  final courseId = assignment.courseId;
  if (courseId == null) return '授業なし';
  return coursesById[courseId]?.title ?? '削除済みの授業';
}

String _filterLabel(AssignmentListFilter filter) {
  return switch (filter) {
    AssignmentListFilter.open => '未提出',
    AssignmentListFilter.today => '今日',
    AssignmentListFilter.week => '今週',
    AssignmentListFilter.done => '提出済み',
  };
}

IconData _filterIcon(AssignmentListFilter filter) {
  return switch (filter) {
    AssignmentListFilter.open => Icons.pending_actions,
    AssignmentListFilter.today => Icons.today,
    AssignmentListFilter.week => Icons.view_week,
    AssignmentListFilter.done => Icons.done,
  };
}

String _statusLabel(AssignmentStatus status) {
  return switch (status) {
    AssignmentStatus.notStarted => '未着手',
    AssignmentStatus.inProgress => '進行中',
    AssignmentStatus.submitted => '提出済み',
    AssignmentStatus.overdue => '期限切れ',
  };
}

String _examDateLabel(DateTime startAt) {
  final civil = JapanTime.civil(startAt);
  return '${civil.month}/${civil.day} '
      '${civil.hour}:${civil.minute.toString().padLeft(2, '0')}';
}

String _dueLabel(DateTime dueAt, DateTime current, {bool submitted = false}) {
  final civilDue = JapanTime.civil(dueAt);
  final dueCivil = civilDue.pickerDateTime;
  final civilCurrent = JapanTime.civil(current).pickerDateTime;
  final time = '${civilDue.hour}:${civilDue.minute.toString().padLeft(2, '0')}';
  if (!submitted && dueAt.toUtc().isBefore(current.toUtc())) {
    return '期限切れ · ${civilDue.month}/${civilDue.day} $time';
  }
  final remaining = _remainingLabel(dueAt.toUtc().difference(current.toUtc()));
  if (_isSameDate(dueCivil, civilCurrent)) {
    return submitted ? '今日 $time 締切' : '今日 $time 締切 · $remaining';
  }
  final tomorrow = _dateOnly(civilCurrent).add(const Duration(days: 1));
  if (_isSameDate(dueCivil, tomorrow)) {
    return submitted ? '明日 $time 締切' : '明日 $time 締切 · $remaining';
  }
  return submitted
      ? '${civilDue.month}/${civilDue.day} $time 締切'
      : '${civilDue.month}/${civilDue.day} $time 締切 · $remaining';
}

String _remainingLabel(Duration duration) {
  if (duration.inDays >= 1) return '残り${duration.inDays}日';
  if (duration.inHours >= 1) return '残り${duration.inHours}時間';
  if (duration.inMinutes >= 1) return '残り${duration.inMinutes}分';
  return 'まもなく締切';
}

bool _isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

bool _isInCurrentWeek(DateTime value, DateTime now) {
  final weekStart =
      _dateOnly(now).subtract(Duration(days: now.weekday - DateTime.monday));
  final weekEnd = weekStart.add(const Duration(days: DateTime.daysPerWeek));
  return !value.isBefore(weekStart) && value.isBefore(weekEnd);
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
