import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('manual course CRUD and pending outbox survive SQLite reopen', () async {
    final directory = await Directory.systemTemp.createTemp('course-offline-');
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    local.AppDatabase? database;
    var idCounter = 0;
    var clockTick = 0;
    DateTime clock() => DateTime.utc(2026, 9, 24).add(
          Duration(seconds: clockTick++),
        );

    DriftScheduleRepository repositoryFor(local.AppDatabase db) =>
        DriftScheduleRepository(
          db,
          createId: () => 'offline-${idCounter++}',
          clock: clock,
        );

    try {
      database = local.AppDatabase(NativeDatabase(file));
      var repository = repositoryFor(database);
      final courseId = await repository.createUserCourse(
        ownerUserId: 'owner-offline',
        termId: 'term-offline',
        input: const UserCourseInput(
          title: '保存前の授業',
          dayOfWeek: DateTime.monday,
          periodNo: 2,
        ),
      );
      await repository.updateUserCourse(
        courseId: courseId,
        ownerUserId: 'owner-offline',
        expectedVersion: 1,
        input: const UserCourseInput(
          title: '更新後の授業',
          dayOfWeek: DateTime.tuesday,
          periodNo: 3,
          room: 'D303',
        ),
      );

      await database.close();
      database = local.AppDatabase(NativeDatabase(file));
      repository = repositoryFor(database);

      final restored = await database.timetableDao.courseById(
        courseId,
        'owner-offline',
      );
      expect(restored?.title, '更新後の授業');
      expect(restored?.version, 2);
      final pendingBeforeDelete = await repository.pendingMutations(
        ownerUserId: 'owner-offline',
      );
      expect(
        pendingBeforeDelete.map((mutation) => mutation.operation),
        [SyncOperation.create, SyncOperation.update],
      );
      expect(
        pendingBeforeDelete.map((mutation) => mutation.baseVersion),
        [null, 1],
      );

      await repository.deleteUserCourse(
        courseId: courseId,
        ownerUserId: 'owner-offline',
        expectedVersion: 2,
      );
      final preRestartMutationIds = pendingBeforeDelete
          .map((mutation) => mutation.clientMutationId)
          .toList();

      await database.close();
      database = local.AppDatabase(NativeDatabase(file));
      repository = repositoryFor(database);

      final tombstone = await (database.select(database.userCourses)
            ..where((course) => course.id.equals(courseId)))
          .getSingle();
      expect(tombstone.deletedAt, isNotNull);
      expect(tombstone.version, 3);
      expect(
        await repository.coursesForTerm(
          ownerUserId: 'owner-offline',
          termId: 'term-offline',
        ),
        isEmpty,
      );

      final pendingAfterDelete = await repository.pendingMutations(
        ownerUserId: 'owner-offline',
      );
      expect(
        pendingAfterDelete.map((mutation) => mutation.operation),
        [SyncOperation.create, SyncOperation.update, SyncOperation.delete],
      );
      expect(
        pendingAfterDelete.map((mutation) => mutation.baseVersion),
        [null, 1, 2],
      );
      expect(
        pendingAfterDelete.take(2).map((mutation) => mutation.clientMutationId),
        preRestartMutationIds,
      );
      expect(
        pendingAfterDelete.every(
          (mutation) => mutation.status == SyncMutationStatus.pending,
        ),
        isTrue,
      );
      expect(pendingAfterDelete.last.payload['version'], 3);
      expect(pendingAfterDelete.last.payload['ownerUserId'], 'owner-offline');
    } finally {
      await database?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
