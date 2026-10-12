import 'enums.dart';
import 'models.dart';

class AssignmentCalendarItem {
  const AssignmentCalendarItem({
    required this.assignmentId,
    required this.title,
    required this.dueAt,
    this.courseId,
  });

  final String assignmentId;
  final String title;
  final DateTime dueAt;
  final String? courseId;
}

/// Resolves the student-facing state without writing an automatic state change.
///
/// A missing personal state means that the assignment has not been started.
/// Deadline expiry is intentionally derived at read time: it must not enqueue a
/// mutation merely because time passed while the app was not running.
class AssignmentStatusResolver {
  const AssignmentStatusResolver();

  AssignmentStatus effectiveStatus({
    required Assignment assignment,
    required DateTime now,
    AssignmentUserState? state,
  }) {
    final status = state?.status ?? AssignmentStatus.notStarted;
    if (status == AssignmentStatus.submitted) {
      return AssignmentStatus.submitted;
    }
    if (assignment.dueAt.isBefore(now)) {
      return AssignmentStatus.overdue;
    }
    // Older clients could persist `overdue`; it is now a derived state and
    // should not make a future assignment look overdue forever.
    return status == AssignmentStatus.overdue
        ? AssignmentStatus.notStarted
        : status;
  }
}

class AssignmentProjectionService {
  bool isVisibleOnCalendar(Assignment assignment, AssignmentUserState? state) {
    return state?.status != AssignmentStatus.submitted;
  }

  List<AssignmentCalendarItem> projectDeadlines(
    Iterable<Assignment> assignments,
    Map<String, AssignmentUserState> statesByAssignmentId,
  ) {
    return assignments
        .where((assignment) => isVisibleOnCalendar(
            assignment, statesByAssignmentId[assignment.id]))
        .map(
          (assignment) => AssignmentCalendarItem(
            assignmentId: assignment.id,
            title: assignment.title,
            dueAt: assignment.dueAt,
            courseId: assignment.courseId,
          ),
        )
        .toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  }
}
