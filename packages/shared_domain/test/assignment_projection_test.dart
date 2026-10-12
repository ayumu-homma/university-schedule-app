import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  test('effective assignment status is derived without changing calendar rules',
      () {
    final resolver = AssignmentStatusResolver();
    final assignment = Assignment(
      id: 'a-status',
      ownerUserId: 'u1',
      title: '進捗確認レポート',
      dueAt: DateTime.utc(2026, 7, 2, 0),
    );

    expect(
      resolver.effectiveStatus(
        assignment: assignment,
        now: DateTime.utc(2026, 7, 1, 0),
      ),
      AssignmentStatus.notStarted,
    );
    expect(
      resolver.effectiveStatus(
        assignment: assignment,
        now: DateTime.utc(2026, 7, 1, 0),
        state: const AssignmentUserState(
          assignmentId: 'a-status',
          userId: 'u1',
          status: AssignmentStatus.inProgress,
        ),
      ),
      AssignmentStatus.inProgress,
    );
    expect(
      resolver.effectiveStatus(
        assignment: assignment,
        now: DateTime.utc(2026, 7, 3, 0),
      ),
      AssignmentStatus.overdue,
    );
    expect(
      resolver.effectiveStatus(
        assignment: assignment,
        now: DateTime.utc(2026, 7, 1, 0),
        state: const AssignmentUserState(
          assignmentId: 'a-status',
          userId: 'u1',
          status: AssignmentStatus.overdue,
        ),
      ),
      AssignmentStatus.notStarted,
    );
  });

  test(
      'submitted assignment disappears from calendar projection but remains in state history',
      () {
    final assignment = Assignment(
      id: 'a1',
      ownerUserId: 'u1',
      title: 'レポート',
      dueAt: DateTime(2026, 7, 1, 23, 59),
    );
    final state = AssignmentUserState(
      assignmentId: 'a1',
      userId: 'u1',
    ).submit(DateTime(2026, 6, 30, 12));

    final service = AssignmentProjectionService();
    final projected = service.projectDeadlines([assignment], {'a1': state});

    expect(projected, isEmpty);
    expect(state.status, equals(AssignmentStatus.submitted));
    expect(state.submittedAt, isNotNull);
  });
}
