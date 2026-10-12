import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  late local.AppDatabase db;
  late DriftScheduleRepository repository;
  late int idCounter;

  setUp(() {
    idCounter = 0;
    db = local.AppDatabase(NativeDatabase.memory());
    repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'generated-${idCounter++}',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('Drift-backed timetable repository loads demo timetable data', () async {
    final snapshot = await repository.loadSnapshot(
      now: DateTime(2026, 6, 29),
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      academicYear: 2026,
    );

    expect(snapshot.periodSettings, hasLength(25));
    expect(snapshot.courses, hasLength(2));
    expect(
      snapshot.courses.any(
        (course) =>
            course.dayOfWeek == DateTime.monday &&
            course.periodNo == 2 &&
            course.title == 'アルゴリズムとデータ構造Ⅰ',
      ),
      isTrue,
    );
  });

  test('saved widget privacy survives reload and malformed data fails closed',
      () async {
    await repository.saveWidgetSnapshot(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.title,
      ),
      generatedAt: DateTime.utc(2026, 7, 1),
    );

    var snapshot = await repository.loadSnapshot(
      now: DateTime.utc(2026, 7, 1),
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      academicYear: 2026,
    );
    expect(snapshot.widgetSnapshot.privacyMode, WidgetPrivacyMode.title);
    expect(
      snapshot.widgetSnapshot.cells.where((cell) => !cell.isEmpty),
      everyElement(predicate<WidgetSnapshotCell>((cell) => cell.room == null)),
    );

    await db.widgetSnapshotDao.saveSnapshot(
      local.WidgetSnapshotsCompanion.insert(
        id: 'weekly-$demoUserId',
        ownerUserId: demoUserId,
        payloadJson: '{"schemaVersion":2}',
        generatedAt: DateTime.utc(2026, 7, 2),
      ),
    );
    snapshot = await repository.loadSnapshot(
      now: DateTime.utc(2026, 7, 2),
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      academicYear: 2026,
    );
    expect(snapshot.widgetSnapshot.privacyMode, WidgetPrivacyMode.busyOnly);
    expect(
      snapshot.widgetSnapshot.cells.where((cell) => !cell.isEmpty),
      everyElement(
        predicate<WidgetSnapshotCell>((cell) => cell.title == '予定あり'),
      ),
    );
  });

  test('widget snapshot follows term switches and course CRUD', () async {
    final activeCourseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: 'ウィジェット実装演習',
        dayOfWeek: DateTime.tuesday,
        periodNo: 2,
        room: 'W201',
      ),
    );
    await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: 'presentation-term',
      input: const UserCourseInput(
        title: '発表会特別講義',
        dayOfWeek: DateTime.friday,
        periodNo: 5,
      ),
    );

    var snapshot = await repository.saveWidgetSnapshot(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.titleAndRoom,
      ),
      generatedAt: DateTime.utc(2026, 7, 1),
    );
    expect(
      snapshot.cells.where((cell) => cell.courseId == activeCourseId).single,
      isA<WidgetSnapshotCell>()
          .having((cell) => cell.weekday, 'weekday', DateTime.tuesday)
          .having((cell) => cell.periodNo, 'period', 2)
          .having((cell) => cell.title, 'title', 'ウィジェット実装演習')
          .having((cell) => cell.room, 'room', 'W201'),
    );
    expect(
      snapshot.cells.any((cell) => cell.title == '発表会特別講義'),
      isFalse,
    );

    await repository.updateUserCourse(
      courseId: activeCourseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
      input: const UserCourseInput(
        title: 'ウィジェット実装演習・更新',
        dayOfWeek: DateTime.thursday,
        periodNo: 4,
        room: 'W404',
      ),
    );
    snapshot = await repository.saveWidgetSnapshot(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.titleAndRoom,
      ),
      generatedAt: DateTime.utc(2026, 7, 1, 1),
    );
    expect(
      snapshot.cells.where((cell) => cell.courseId == activeCourseId).single,
      isA<WidgetSnapshotCell>()
          .having((cell) => cell.weekday, 'weekday', DateTime.thursday)
          .having((cell) => cell.periodNo, 'period', 4)
          .having((cell) => cell.title, 'title', 'ウィジェット実装演習・更新')
          .having((cell) => cell.room, 'room', 'W404'),
    );

    await repository.deleteUserCourse(
      courseId: activeCourseId,
      ownerUserId: demoUserId,
      expectedVersion: 2,
    );
    snapshot = await repository.saveWidgetSnapshot(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      settings: const WidgetSnapshotSettings(),
      generatedAt: DateTime.utc(2026, 7, 1, 2),
    );
    expect(
      snapshot.cells.any((cell) => cell.courseId == activeCourseId),
      isFalse,
    );

    final switched = await repository.saveWidgetSnapshot(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: 'presentation-term',
      settings: const WidgetSnapshotSettings(),
      generatedAt: DateTime.utc(2026, 7, 1, 3),
    );
    expect(
      switched.cells.where((cell) => cell.title == '発表会特別講義').single,
      isA<WidgetSnapshotCell>()
          .having((cell) => cell.weekday, 'weekday', DateTime.friday)
          .having((cell) => cell.periodNo, 'period', 5),
    );
  });

  test('snapshot projects the explicit 90-day agenda horizon', () async {
    final monthlyRoutineId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '月次の先行予定',
        startAt: DateTime.utc(2026, 7, 10),
        endAt: DateTime.utc(2026, 7, 10, 1),
        kind: EventKind.routine,
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.monthly,
          monthDay: 10,
          count: 2,
        ),
      ),
    );
    final futureEventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: 'アジェンダ内の将来予定',
        startAt: DateTime.utc(2026, 9, 30),
        endAt: DateTime.utc(2026, 9, 30, 1),
      ),
    );
    final monthStartEventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '今月前半の予定',
        startAt: DateTime.utc(2026, 7, 1),
        endAt: DateTime.utc(2026, 7, 1, 1),
      ),
    );
    final agendaBoundary = JapanTime.startOfDay(DateTime.utc(2026, 7, 10))
        .add(const Duration(days: 90));
    final agendaBoundaryEventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: 'アジェンダ境界の予定',
        startAt: agendaBoundary,
        endAt: agendaBoundary.add(const Duration(hours: 1)),
      ),
    );

    final snapshot = await repository.loadSnapshot(
      now: DateTime.utc(2026, 7, 10),
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      academicYear: 2026,
    );

    expect(
      snapshot.calendarItems.where((item) => item.sourceId == monthlyRoutineId),
      hasLength(2),
    );
    expect(
      snapshot.calendarItems.any((item) => item.sourceId == futureEventId),
      isTrue,
    );
    expect(
      snapshot.calendarItems.any((item) => item.sourceId == monthStartEventId),
      isTrue,
    );
    expect(
      snapshot.calendarItems.any(
        (item) => item.sourceId == agendaBoundaryEventId,
      ),
      isFalse,
    );
  });

  test('copying a course template creates an independent UserCourse snapshot',
      () async {
    final copiedId = await repository.copyTemplate(
      templateId: 'tmpl-algo-1',
      ownerUserId: demoUserId,
      termId: demoTermId,
    );

    await (db.update(db.courseTemplatesCache)
          ..where((row) => row.id.equals('tmpl-algo-1')))
        .write(
      const local.CourseTemplatesCacheCompanion(
        title: Value('変更済みテンプレ名'),
        normalizedTitle: Value('変更済みテンプレ名'),
      ),
    );

    final copiedCourse = await db.timetableDao.courseById(copiedId, demoUserId);
    final template = await db.courseTemplateDao.templateById('tmpl-algo-1');

    expect(copiedCourse, isNotNull);
    expect(copiedCourse!.sourceTemplateId, 'tmpl-algo-1');
    expect(copiedCourse.title, 'アルゴリズムとデータ構造Ⅰ');
    expect(template!.copyCountTotal, 125);
    expect(template.copyCountTerm, 32);
  });

  test('assignment submit hides deadline projection but keeps history',
      () async {
    final before = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );

    expect(
      before.any((item) => item.kind == EventKind.assignmentDeadline),
      isTrue,
    );

    await repository.submitAssignment(
      assignmentId: 'assignment-report-1',
      userId: demoUserId,
      submittedAt: DateTime(2026, 7, 1, 12),
    );

    final after = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );
    final assignments = await repository.assignmentsForUser(demoUserId);
    final states = await repository.assignmentStatesForUser(demoUserId);

    expect(
      after.any((item) => item.kind == EventKind.assignmentDeadline),
      isFalse,
    );
    expect(assignments.map((assignment) => assignment.id),
        contains('assignment-report-1'));
    expect(states['assignment-report-1']!.status, AssignmentStatus.submitted);
  });

  test('calendar projection includes expected demo items from Drift', () async {
    final items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );

    expect(items.any((item) => item.kind == EventKind.course), isTrue);
    expect(
      items.any((item) => item.kind == EventKind.assignmentDeadline),
      isTrue,
    );
    expect(items.any((item) => item.kind == EventKind.exam), isTrue);
    expect(items.where((item) => item.kind == EventKind.routine), hasLength(3));
  });

  test('manual UserCourse create creates a local row and enqueues mutation',
      () async {
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: '線形代数',
        dayOfWeek: DateTime.wednesday,
        periodNo: 3,
        room: 'C301',
        instructorName: '佐藤',
        color: '#27AE60',
        visibilityLevel: VisibilityLevel.titleOnly,
      ),
    );

    final course = await db.timetableDao.courseById(courseId, demoUserId);
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);

    expect(course, isNotNull);
    expect(course!.title, '線形代数');
    expect(course.sourceTemplateId, isNull);
    expect(mutations, hasLength(1));
    expect(mutations.single.entityType, 'user_course');
    expect(mutations.single.entityId, courseId);
    expect(mutations.single.operation, SyncOperation.create);
    expect(mutations.single.status, SyncMutationStatus.pending);
  });

  test('editing UserCourse updates only user snapshot and enqueues mutation',
      () async {
    final copiedId = await repository.copyTemplate(
      templateId: 'tmpl-algo-1',
      ownerUserId: demoUserId,
      termId: demoTermId,
    );

    await repository.updateUserCourse(
      courseId: copiedId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
      input: const UserCourseInput(
        title: '個人用アルゴリズム',
        dayOfWeek: DateTime.thursday,
        periodNo: 4,
        room: 'D404',
        instructorName: '山田 太郎',
        color: '#9B51E0',
      ),
    );

    final course = await db.timetableDao.courseById(copiedId, demoUserId);
    final template = await db.courseTemplateDao.templateById('tmpl-algo-1');
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);

    expect(course!.title, '個人用アルゴリズム');
    expect(course.sourceTemplateId, 'tmpl-algo-1');
    expect(template!.title, 'アルゴリズムとデータ構造Ⅰ');
    expect(
      mutations.where(
        (mutation) =>
            mutation.entityType == 'user_course' &&
            mutation.entityId == copiedId &&
            mutation.operation == SyncOperation.update,
      ),
      hasLength(1),
    );
  });

  test('assignment create appears in list and calendar projection', () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '英語プレゼン準備',
        dueAt: DateTime(2026, 7, 2, 18),
        courseId: 'course-english',
        submissionUrl: 'https://lms.example.edu/assignments/english',
        memo: '3分発表',
        priority: 'high',
      ),
    );

    final assignments = await repository.assignmentsForUser(demoUserId);
    final items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);

    expect(
        assignments.map((assignment) => assignment.id), contains(assignmentId));
    expect(
      items.any(
        (item) =>
            item.kind == EventKind.assignmentDeadline &&
            item.sourceId == assignmentId,
      ),
      isTrue,
    );
    expect(mutations.single.entityType, 'assignment');
    expect(mutations.single.operation, SyncOperation.create);
  });

  test('assignment submit hides deadline projection and enqueues mutation',
      () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '提出キュー確認',
        dueAt: DateTime(2026, 7, 4, 20),
      ),
    );

    await repository.submitAssignment(
      assignmentId: assignmentId,
      userId: demoUserId,
      submittedAt: DateTime(2026, 7, 3, 12),
    );

    final items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );
    final states = await repository.assignmentStatesForUser(demoUserId);
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);

    expect(
      items.any(
        (item) =>
            item.kind == EventKind.assignmentDeadline &&
            item.sourceId == assignmentId,
      ),
      isFalse,
    );
    expect(states[assignmentId]!.status, AssignmentStatus.submitted);
    expect(
      mutations.where((mutation) => mutation.operation == SyncOperation.submit),
      hasLength(1),
    );
  });

  test('assignment progress state queues create and versioned updates',
      () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '進捗状態の同期確認',
        dueAt: DateTime.utc(2026, 7, 4, 20),
      ),
    );

    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: demoUserId,
      status: AssignmentStatus.inProgress,
      updatedAt: DateTime.utc(2026, 7, 3, 9),
    );
    var items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime.utc(2026, 6, 29),
      rangeEnd: DateTime.utc(2026, 7, 14),
    );
    var states = await repository.assignmentStatesForUser(demoUserId);
    expect(states[assignmentId]!.status, AssignmentStatus.inProgress);
    expect(states[assignmentId]!.submittedAt, isNull);
    expect(
      items.any((item) => item.sourceId == assignmentId),
      isTrue,
    );

    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: demoUserId,
      status: AssignmentStatus.notStarted,
      updatedAt: DateTime.utc(2026, 7, 3, 10),
    );
    await repository.submitAssignment(
      assignmentId: assignmentId,
      userId: demoUserId,
      submittedAt: DateTime.utc(2026, 7, 3, 11),
    );
    items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime.utc(2026, 6, 29),
      rangeEnd: DateTime.utc(2026, 7, 14),
    );
    expect(
      items.any((item) => item.sourceId == assignmentId),
      isFalse,
    );

    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: demoUserId,
      status: AssignmentStatus.inProgress,
      updatedAt: DateTime.utc(2026, 7, 3, 12),
    );
    states = await repository.assignmentStatesForUser(demoUserId);
    final mutations =
        (await repository.pendingMutations(ownerUserId: demoUserId))
            .where((mutation) => mutation.entityType == 'assignment_user_state')
            .toList();
    final row = await db.assignmentDao.stateForAssignment(
      assignmentId: assignmentId,
      userId: demoUserId,
    );

    expect(states[assignmentId]!.status, AssignmentStatus.inProgress);
    expect(states[assignmentId]!.submittedAt, isNull);
    expect(row!.version, 4);
    expect(row.submittedAt, isNull);
    expect(mutations.map((mutation) => mutation.operation), [
      SyncOperation.create,
      SyncOperation.update,
      SyncOperation.submit,
      SyncOperation.update,
    ]);
    expect(mutations.map((mutation) => mutation.baseVersion), [null, 1, 2, 3]);
    expect(mutations[0].payload['status'], 'inProgress');
    expect(mutations[0].payload['submittedAt'], isNull);
    expect(mutations[1].payload['status'], 'notStarted');
    expect(mutations[3].payload['status'], 'inProgress');
  });

  test('snapshot resolves assignment courses across terms in one bulk lookup',
      () async {
    final historicalCourseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: '過去学期の授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    await (db.update(db.userCourses)
          ..where((row) => row.id.equals(historicalCourseId)))
        .write(
            const local.UserCoursesCompanion(termId: Value('historical-term')));
    await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '過去学期のレポート',
        dueAt: DateTime.utc(2026, 7, 5, 20),
        courseId: historicalCourseId,
      ),
    );

    final snapshot = await repository.loadSnapshot(
      now: DateTime.utc(2026, 7, 3),
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      academicYear: 2026,
    );

    expect(snapshot.courses.map((course) => course.id),
        isNot(contains(historicalCourseId)));
    expect(snapshot.assignmentCourses.map((course) => course.id),
        contains(historicalCourseId));
  });

  test('exam create appears in exam list and calendar projection', () async {
    final examId = await repository.createExam(
      ownerUserId: demoUserId,
      input: ExamInput(
        title: '英語小テスト',
        startAt: DateTime(2026, 7, 6, 9),
        endAt: DateTime(2026, 7, 6, 10),
        courseId: 'course-english',
        room: 'B203',
        memo: 'Unit 4',
        examType: 'quiz',
      ),
    );

    final exams = await repository.examsForUser(demoUserId);
    final items = await repository.calendarProjection(
      ownerUserId: demoUserId,
      universityId: demoUniversityId,
      termId: demoTermId,
      rangeStart: DateTime(2026, 6, 29),
      rangeEnd: DateTime(2026, 7, 14),
    );
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);

    expect(exams.map((exam) => exam.id), contains(examId));
    expect(
      items.any(
          (item) => item.kind == EventKind.exam && item.sourceId == examId),
      isTrue,
    );
    expect(mutations.single.entityType, 'exam');
    expect(mutations.single.operation, SyncOperation.create);
  });

  test('sync_queue receives expected mutation records', () async {
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: '同期基礎',
        dayOfWeek: DateTime.friday,
        periodNo: 5,
      ),
    );
    await repository.updateUserCourse(
      courseId: courseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
      input: const UserCourseInput(
        title: '同期基礎 更新',
        dayOfWeek: DateTime.friday,
        periodNo: 5,
      ),
    );

    final rows = await db.syncQueueDao.pendingMutations(demoUserId);

    expect(rows, hasLength(2));
    expect(rows.map((row) => row.entityType), everyElement('user_course'));
    expect(rows.map((row) => row.entityId), everyElement(courseId));
    expect(rows.map((row) => row.status), everyElement('pending'));
    expect(rows.map((row) => row.operation), ['create', 'update']);
  });
}
