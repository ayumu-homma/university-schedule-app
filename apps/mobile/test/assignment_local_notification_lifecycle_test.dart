import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_planner.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('assignment create, due-date edit, and delete reconcile reminders',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const owner = 'assignment-notification-owner';
    final store = LocalNotificationStore(db);
    final repository = DriftScheduleRepository(
      db,
      createId: () => 'assignment-notification-lifecycle',
    );
    const planner = LocalNotificationPlanner();
    final now = JapanTime.at(year: 2026, month: 4, day: 1, hour: 9);
    final firstDue = JapanTime.at(year: 2026, month: 4, day: 12, hour: 10);

    List<LocalNotificationPlan> plansFor(
      List<Assignment> assignments, {
      required int sourceEpoch,
      required int projectionEpoch,
    }) =>
        planner.plan(
          ownerUserId: owner,
          projectionService: CalendarProjectionService(),
          courses: const [],
          periodSettings: const [],
          assignments: assignments,
          assignmentStates: const {},
          exams: const [],
          events: const [],
          eventExceptions: const [],
          settings: const LocalNotificationSettingsValue(),
          now: now,
          sourceEpoch: sourceEpoch,
          projectionEpoch: projectionEpoch,
        );

    final beforeCreate = await store.sourceEpoch();
    final assignmentId = await repository.createAssignment(
      ownerUserId: owner,
      input: AssignmentInput(
        title: '提出レポート',
        dueAt: firstDue,
      ),
    );
    final afterCreate = await store.sourceEpoch();
    expect(assignmentId, 'assignment-notification-lifecycle');
    expect(afterCreate, greaterThan(beforeCreate));
    final created = (await repository.assignmentsForUser(owner)).single;
    final initialPlans = plansFor(
      [created],
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
    );
    expect(
      initialPlans.map((plan) => plan.rule),
      containsAll(['assignment_previous_day', 'assignment_due_reminder']),
    );
    expect(initialPlans, hasLength(2));
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
      capped: false,
      plans: initialPlans,
    );
    final firstRows = await store.desiredRows(owner);
    expect(firstRows, hasLength(2));
    final firstIds = firstRows.map((row) => row['id']).toSet();

    final movedDue = JapanTime.at(year: 2026, month: 4, day: 18, hour: 11);
    await repository.updateAssignment(
      assignmentId: assignmentId,
      ownerUserId: owner,
      expectedVersion: 1,
      input: AssignmentInput(
        title: '発表資料の提出',
        dueAt: movedDue,
      ),
    );
    final afterUpdate = await store.sourceEpoch();
    expect(afterUpdate, greaterThan(afterCreate));
    final updated = (await repository.assignmentsForUser(owner)).single;
    expect(updated.version, 2);
    final updatedPlans = plansFor(
      [updated],
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
    );
    expect(updatedPlans, hasLength(2));
    expect(updatedPlans.every((plan) => plan.occurrenceAt == movedDue), isTrue);
    expect(
        updatedPlans.every((plan) => plan.sourceEpoch == afterUpdate), isTrue);
    expect(
      updatedPlans.map((plan) => plan.id).toSet().intersection(firstIds),
      isEmpty,
    );
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
      capped: false,
      plans: updatedPlans,
    );
    final movedRows = await store.desiredRows(owner);
    expect(movedRows, hasLength(2));
    expect(
        movedRows.every((row) => row['source_epoch'] == afterUpdate), isTrue);
    expect(
      movedRows.map((row) => row['id']).toSet().intersection(firstIds),
      isEmpty,
    );

    await repository.deleteAssignment(
      assignmentId: assignmentId,
      ownerUserId: owner,
      expectedVersion: 2,
    );
    final afterDelete = await store.sourceEpoch();
    expect(afterDelete, greaterThan(afterUpdate));
    final remaining = await repository.assignmentsForUser(owner);
    expect(remaining, isEmpty);
    final deletedPlans = plansFor(
      remaining,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
    );
    expect(deletedPlans, isEmpty);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
      capped: false,
      plans: deletedPlans,
    );
    expect(await store.desiredRows(owner), isEmpty);
    expect(await store.projectionEpoch(owner), 3);
  });
}
