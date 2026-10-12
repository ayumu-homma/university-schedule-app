import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_planner.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('exam create, edit, and delete replace the local reminder projection',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const owner = 'exam-notification-owner';
    final store = LocalNotificationStore(db);
    final repository = DriftScheduleRepository(
      db,
      createId: () => 'exam-notification-lifecycle',
    );
    const planner = LocalNotificationPlanner();
    final now = JapanTime.at(year: 2026, month: 4, day: 1, hour: 9);
    final firstStart = JapanTime.at(year: 2026, month: 4, day: 12, hour: 10);

    Future<List<LocalNotificationPlan>> plansFor(
      List<Exam> exams, {
      required int sourceEpoch,
      required int projectionEpoch,
    }) async =>
        planner.plan(
          ownerUserId: owner,
          projectionService: CalendarProjectionService(),
          courses: const [],
          periodSettings: const [],
          assignments: const [],
          assignmentStates: const {},
          exams: exams,
          events: const [],
          eventExceptions: const [],
          settings: const LocalNotificationSettingsValue(),
          now: now,
          sourceEpoch: sourceEpoch,
          projectionEpoch: projectionEpoch,
        );

    final beforeCreate = await store.sourceEpoch();
    final examId = await repository.createExam(
      ownerUserId: owner,
      input: ExamInput(
        title: '期末レポート',
        startAt: firstStart,
        endAt: firstStart.add(const Duration(hours: 2)),
        examType: 'レポート',
        room: '教室 201',
      ),
    );
    final afterCreate = await store.sourceEpoch();
    expect(examId, 'exam-notification-lifecycle');
    expect(afterCreate, greaterThan(beforeCreate));
    final createdExam = (await repository.examsForUser(owner)).single;
    final createPlans = await plansFor(
      [createdExam],
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
    );
    expect(
      createPlans.map((plan) => plan.rule),
      containsAll(['exam_week', 'exam_previous_day', 'exam_day_morning']),
    );
    expect(
        createPlans.every((plan) => plan.sourceEpoch == afterCreate), isTrue);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
      capped: false,
      plans: createPlans,
    );
    final firstRows = await store.desiredRows(owner);
    expect(firstRows, hasLength(3));
    final firstIds = firstRows.map((row) => row['id']).toSet();

    final movedStart = JapanTime.at(year: 2026, month: 4, day: 18, hour: 11);
    await repository.updateExam(
      examId: examId,
      ownerUserId: owner,
      expectedVersion: 1,
      input: ExamInput(
        title: '発表資料',
        startAt: movedStart,
        endAt: movedStart.add(const Duration(hours: 2)),
        examType: '発表',
        room: '発表室',
        memo: '更新後の予定',
      ),
    );
    final afterUpdate = await store.sourceEpoch();
    expect(afterUpdate, greaterThan(afterCreate));
    final updatedExam = (await repository.examsForUser(owner)).single;
    expect(updatedExam.version, 2);
    final updatePlans = await plansFor(
      [updatedExam],
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
    );
    expect(updatePlans, hasLength(3));
    expect(
        updatePlans.every((plan) => plan.occurrenceAt == movedStart), isTrue);
    expect(
        updatePlans.every((plan) => plan.sourceEpoch == afterUpdate), isTrue);
    expect(updatePlans.map((plan) => plan.id).toSet().intersection(firstIds),
        isEmpty);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
      capped: false,
      plans: updatePlans,
    );
    final movedRows = await store.desiredRows(owner);
    expect(movedRows, hasLength(3));
    expect(
        movedRows.every((row) => row['source_epoch'] == afterUpdate), isTrue);
    expect(
      movedRows.map((row) => row['id']).toSet().intersection(firstIds),
      isEmpty,
    );

    await repository.deleteExam(
      examId: examId,
      ownerUserId: owner,
      expectedVersion: 2,
    );
    final afterDelete = await store.sourceEpoch();
    expect(afterDelete, greaterThan(afterUpdate));
    final remainingExams = await repository.examsForUser(owner);
    expect(remainingExams, isEmpty);
    final deletePlans = await plansFor(
      remainingExams,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
    );
    expect(deletePlans, isEmpty);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
      capped: false,
      plans: deletePlans,
    );
    expect(await store.desiredRows(owner), isEmpty);
    expect(await store.projectionEpoch(owner), 3);
  });
}
