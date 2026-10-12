import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/links/external_uri_launcher.dart';
import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/app_status_badge.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../../../shared/widgets/responsive_content.dart';
import 'assignment_undo_feedback.dart';
import '../../timetable/application/demo_app_controller.dart';

/// Read-only assignment presentation. Editing remains a separate route so a
/// user can inspect the full saved record before changing it.
class AssignmentDetailScreen extends ConsumerWidget {
  const AssignmentDetailScreen({required this.assignmentId, super.key});

  final String assignmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final assignment = _findAssignment(state.assignments, assignmentId);
        if (assignment == null) {
          return const MvpScaffold(
            title: '課題の詳細',
            selectedIndex: 2,
            child: Center(child: Text('課題が見つかりません')),
          );
        }
        final rawState = state.assignmentStates[assignment.id];
        final effectiveStatus =
            const AssignmentStatusResolver().effectiveStatus(
          assignment: assignment,
          state: rawState,
          now: ref.watch(appClockProvider).now(),
        );
        return _AssignmentDetailContent(
          assignment: assignment,
          course: _findCourse(state, assignment.courseId),
          status: effectiveStatus,
          rawState: rawState,
        );
      },
      loading: () => const MvpScaffold(
        title: '課題の詳細',
        selectedIndex: 2,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '課題の詳細',
        selectedIndex: 2,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  Assignment? _findAssignment(List<Assignment> assignments, String id) {
    for (final assignment in assignments) {
      if (assignment.id == id) return assignment;
    }
    return null;
  }

  UserCourse? _findCourse(DemoAppState state, String? courseId) {
    if (courseId == null) return null;
    for (final course in [...state.courses, ...state.assignmentCourses]) {
      if (course.id == courseId) return course;
    }
    return null;
  }
}

class _AssignmentDetailContent extends ConsumerStatefulWidget {
  const _AssignmentDetailContent({
    required this.assignment,
    required this.course,
    required this.status,
    required this.rawState,
  });

  final Assignment assignment;
  final UserCourse? course;
  final AssignmentStatus status;
  final AssignmentUserState? rawState;

  @override
  ConsumerState<_AssignmentDetailContent> createState() =>
      _AssignmentDetailContentState();
}

class _AssignmentDetailContentState
    extends ConsumerState<_AssignmentDetailContent> {
  bool _updating = false;

  @override
  Widget build(BuildContext context) {
    final assignment = widget.assignment;
    final status = widget.status;
    final statusTone = switch (status) {
      AssignmentStatus.notStarted => AppStatusTone.neutral,
      AssignmentStatus.inProgress => AppStatusTone.warning,
      AssignmentStatus.submitted => AppStatusTone.success,
      AssignmentStatus.overdue => AppStatusTone.critical,
    };
    final statusIcon = switch (status) {
      AssignmentStatus.notStarted => Icons.radio_button_unchecked,
      AssignmentStatus.inProgress => Icons.pending_actions,
      AssignmentStatus.submitted => Icons.check_circle_outline,
      AssignmentStatus.overdue => Icons.error_outline,
    };
    return MvpScaffold(
      title: '課題の詳細',
      selectedIndex: 2,
      actions: [
        IconButton(
          tooltip: '課題を編集',
          onPressed: _updating
              ? null
              : () => context.go('/assignment/${assignment.id}/edit'),
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
      child: ResponsiveContent(
        maxWidth: AppSizes.formMaxWidth,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 128),
          children: [
            Text(assignment.title,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AppStatusBadge(
                  label: _statusLabel(status),
                  icon: statusIcon,
                  tone: statusTone,
                ),
                PrivacyBadge(level: assignment.visibilityLevel),
              ],
            ),
            const SizedBox(height: 20),
            _DetailRow(
              icon: Icons.schedule_outlined,
              label: '締切',
              value: _formatDateTime(assignment.dueAt),
            ),
            _DetailRow(
              icon: Icons.school_outlined,
              label: '授業',
              value: widget.course?.title ??
                  (assignment.courseId == null ? '授業なし' : '削除済みの授業'),
            ),
            if (assignment.description?.trim().isNotEmpty == true)
              _DetailRow(
                icon: Icons.notes_outlined,
                label: 'メモ',
                value: assignment.description!,
              ),
            if (assignment.priority?.trim().isNotEmpty == true)
              _DetailRow(
                icon: Icons.flag_outlined,
                label: '優先度',
                value: _priorityLabel(assignment.priority!),
              ),
            if (assignment.submissionUrl?.trim().isNotEmpty == true) ...[
              _DetailRow(
                icon: Icons.link,
                label: '提出先',
                value: assignment.submissionUrl!.trim(),
                selectable: true,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('assignment-open-url'),
                onPressed: _updating ? null : _openSubmissionUrl,
                icon: const Icon(Icons.open_in_new),
                label: const Text('提出先を開く'),
              ),
              const SizedBox(height: 4),
              Text(
                '提出先を開くだけでは提出済みとして記録されません。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 24),
            if (status != AssignmentStatus.submitted)
              FilledButton.icon(
                key: const Key('assignment-record-submission'),
                onPressed: _updating ? null : _recordSubmission,
                icon: const Icon(Icons.check),
                label: const Text('提出済みを記録'),
              )
            else
              OutlinedButton.icon(
                key: const Key('assignment-restore-submission'),
                onPressed: _updating ? null : _restoreSubmission,
                icon: const Icon(Icons.undo),
                label: const Text('未提出に戻す'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _recordSubmission() async {
    setState(() => _updating = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final operation = await ref
          .read(demoAppControllerProvider.notifier)
          .submitAssignmentWithUndo(widget.assignment.id);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('提出済みとして記録しました。'),
            action: SnackBarAction(
              label: '元に戻す',
              onPressed: () => unawaited(
                runAssignmentUndoWithFeedback(operation, messenger),
              ),
            ),
          ),
        );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('提出状態を更新できませんでした。もう一度お試しください。')),
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _restoreSubmission() async {
    setState(() => _updating = true);
    try {
      await ref.read(demoAppControllerProvider.notifier).setAssignmentStatus(
            widget.assignment.id,
            AssignmentStatus.notStarted,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未提出に戻しました。')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('状態を戻せませんでした。もう一度お試しください。')),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _openSubmissionUrl() async {
    final value = widget.assignment.submissionUrl?.trim();
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提出先URLを確認できません。')),
        );
      }
      return;
    }
    bool opened = false;
    try {
      opened = await ref.read(externalUriLauncherProvider)(uri);
    } on Object {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提出先を開けませんでした。')),
      );
    }
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: selectable ? SelectableText(value) : Text(value),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime instant) {
  final civil = JapanTime.civil(instant);
  return '${civil.year}/${civil.month}/${civil.day} '
      '${civil.hour}:${civil.minute.toString().padLeft(2, '0')}';
}

String _statusLabel(AssignmentStatus status) => switch (status) {
      AssignmentStatus.notStarted => '未着手',
      AssignmentStatus.inProgress => '進行中',
      AssignmentStatus.submitted => '提出済み',
      AssignmentStatus.overdue => '期限切れ',
    };

String _priorityLabel(String priority) => switch (priority) {
      'low' => '低',
      'high' => '高',
      'normal' => '通常',
      _ => priority,
    };
