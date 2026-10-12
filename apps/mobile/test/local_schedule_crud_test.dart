import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
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
      createId: () => 'crud-${idCounter++}',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('personal Event create, update, and delete retain a tombstone',
      () async {
    final eventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '研究室ミーティング',
        startAt: DateTime(2026, 7, 11, 14),
        endAt: DateTime(2026, 7, 11, 15),
        location: 'C201',
        description: '進捗共有',
      ),
    );

    var event = (await repository.eventsForUser(demoUserId))
        .singleWhere((item) => item.id == eventId);
    expect(event.title, '研究室ミーティング');
    expect(event.version, 1);

    await repository.updateEvent(
      eventId: eventId,
      ownerUserId: demoUserId,
      expectedVersion: event.version,
      input: EventInput(
        title: '研究室ミーティング（変更）',
        startAt: DateTime(2026, 7, 11, 15),
        endAt: DateTime(2026, 7, 11, 16),
        location: 'C202',
      ),
    );

    event = (await repository.eventsForUser(demoUserId))
        .singleWhere((item) => item.id == eventId);
    expect(event.title, '研究室ミーティング（変更）');
    expect(event.version, 2);

    await repository.deleteEvent(
      eventId: eventId,
      ownerUserId: demoUserId,
      expectedVersion: event.version,
    );

    final active = await repository.eventsForUser(demoUserId);
    final tombstone = await (db.select(db.events)
          ..where((row) => row.id.equals(eventId)))
        .getSingle();
    final mutations =
        await repository.pendingMutations(ownerUserId: demoUserId);
    final deleted = mutations.singleWhere(
      (mutation) =>
          mutation.entityId == eventId &&
          mutation.operation == SyncOperation.delete,
    );

    expect(active.map((item) => item.id), isNot(contains(eventId)));
    expect(tombstone.deletedAt, isNotNull);
    expect(tombstone.version, 3);
    expect(deleted.baseVersion, 2);
    expect(deleted.payload['version'], 3);
    expect(deleted.payload['ownerUserId'], demoUserId);
  });

  test('Course delete hides only the course and preserves linked history',
      () async {
    await _loadDemoSnapshot(repository);

    await repository.deleteUserCourse(
      courseId: 'course-algo',
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );

    final courses = await repository.coursesForTerm(
      ownerUserId: demoUserId,
      termId: demoTermId,
    );
    final assignments = await repository.assignmentsForUser(demoUserId);
    final exams = await repository.examsForUser(demoUserId);
    final tombstone = await (db.select(db.userCourses)
          ..where((row) => row.id.equals('course-algo')))
        .getSingle();
    final deletion = (await repository.pendingMutations(
      ownerUserId: demoUserId,
    ))
        .singleWhere(
      (mutation) => mutation.operation == SyncOperation.delete,
    );

    expect(courses.map((course) => course.id), isNot(contains('course-algo')));
    expect(
      assignments.any((assignment) => assignment.courseId == 'course-algo'),
      isTrue,
    );
    expect(exams.any((exam) => exam.courseId == 'course-algo'), isTrue);
    expect(tombstone.deletedAt, isNotNull);
    expect(tombstone.version, 2);
    expect(deletion.entityType, 'user_course');
    expect(deletion.baseVersion, 1);
  });

  test('Assignment and Exam deletes retain versioned tombstones', () async {
    await _loadDemoSnapshot(repository);

    await repository.deleteAssignment(
      assignmentId: 'assignment-report-1',
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );
    await repository.deleteExam(
      examId: 'exam-midterm-1',
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );

    final assignments = await repository.assignmentsForUser(demoUserId);
    final exams = await repository.examsForUser(demoUserId);
    final assignmentRow = await (db.select(db.assignments)
          ..where((row) => row.id.equals('assignment-report-1')))
        .getSingle();
    final examRow = await (db.select(db.exams)
          ..where((row) => row.id.equals('exam-midterm-1')))
        .getSingle();
    final deletions = (await repository.pendingMutations(
      ownerUserId: demoUserId,
    ))
        .where((mutation) => mutation.operation == SyncOperation.delete)
        .toList();

    expect(
      assignments.map((assignment) => assignment.id),
      isNot(contains('assignment-report-1')),
    );
    expect(exams.map((exam) => exam.id), isNot(contains('exam-midterm-1')));
    expect(assignmentRow.deletedAt, isNotNull);
    expect(assignmentRow.version, 2);
    expect(examRow.deletedAt, isNotNull);
    expect(examRow.version, 2);
    expect(deletions.map((mutation) => mutation.baseVersion), everyElement(1));
  });

  test('stale expected version is rejected without overwriting newer data',
      () async {
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: '分散システム',
        dayOfWeek: DateTime.tuesday,
        periodNo: 2,
      ),
    );
    await repository.updateUserCourse(
      courseId: courseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
      input: const UserCourseInput(
        title: '分散システム 最新',
        dayOfWeek: DateTime.tuesday,
        periodNo: 2,
      ),
    );

    await expectLater(
      repository.updateUserCourse(
        courseId: courseId,
        ownerUserId: demoUserId,
        expectedVersion: 1,
        input: const UserCourseInput(
          title: '古い編集',
          dayOfWeek: DateTime.friday,
          periodNo: 5,
        ),
      ),
      throwsA(isA<ConflictError>()),
    );

    final course = await db.timetableDao.courseById(courseId, demoUserId);
    expect(course!.title, '分散システム 最新');
    expect(course.version, 2);
  });

  test('owner scope blocks cross-account delete and calendar writes', () async {
    await _loadDemoSnapshot(repository);

    await expectLater(
      repository.deleteUserCourse(
        courseId: 'course-algo',
        ownerUserId: 'other-user',
        expectedVersion: 1,
      ),
      throwsArgumentError,
    );

    final row = await db.timetableDao.courseById('course-algo', demoUserId);
    expect(row, isNotNull);
    final otherCourseId = await repository.createUserCourse(
      ownerUserId: 'other-user',
      termId: 'other-term',
      input: const UserCourseInput(
        title: '別アカウントの授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    await expectLater(
      repository.createAssignment(
        ownerUserId: demoUserId,
        input: AssignmentInput(
          title: '不正な授業参照',
          dueAt: DateTime(2026, 7, 12, 18),
          courseId: otherCourseId,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.submitAssignment(
        assignmentId: 'assignment-report-1',
        userId: 'other-user',
        submittedAt: DateTime(2026, 7, 10, 12),
      ),
      throwsArgumentError,
    );
    await expectLater(
      repository.createEvent(
        ownerUserId: 'other-user',
        input: EventInput(
          title: '不正なカレンダー参照',
          startAt: DateTime(2026, 7, 12, 10),
          endAt: DateTime(2026, 7, 12, 11),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      await repository.pendingMutations(ownerUserId: demoUserId),
      isEmpty,
    );
    expect(
      await repository.pendingMutations(ownerUserId: 'other-user'),
      hasLength(1),
    );
  });
}

Future<LocalScheduleSnapshot> _loadDemoSnapshot(
  DriftScheduleRepository repository,
) {
  return repository.loadSnapshot(
    now: DateTime(2026, 7, 10),
    ownerUserId: demoUserId,
    universityId: demoUniversityId,
    termId: demoTermId,
    academicYear: 2026,
  );
}
