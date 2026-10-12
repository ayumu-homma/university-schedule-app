import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('close and reopen preserves tombstone, version, and queued delete',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('schedule-restart-');
    final databaseFile = File('${tempDir.path}${Platform.pathSeparator}app.db');
    local.AppDatabase? openDatabase;

    try {
      var idCounter = 0;
      openDatabase = local.AppDatabase(NativeDatabase(databaseFile));
      final repository = DriftScheduleRepository(
        openDatabase,
        createId: () => 'restart-${idCounter++}',
      );
      final courseId = await repository.createUserCourse(
        ownerUserId: demoUserId,
        termId: demoTermId,
        input: const UserCourseInput(
          title: '再起動テスト',
          dayOfWeek: DateTime.thursday,
          periodNo: 4,
        ),
      );
      await repository.deleteUserCourse(
        courseId: courseId,
        ownerUserId: demoUserId,
        expectedVersion: 1,
      );
      await openDatabase.close();
      openDatabase = null;

      openDatabase = local.AppDatabase(NativeDatabase(databaseFile));
      final reopenedRepository = DriftScheduleRepository(openDatabase);
      final activeCourses = await reopenedRepository.coursesForTerm(
        ownerUserId: demoUserId,
        termId: demoTermId,
      );
      final row = await (openDatabase.select(openDatabase.userCourses)
            ..where((course) => course.id.equals(courseId)))
          .getSingle();
      final queued = await DriftSyncQueue(
        openDatabase,
        ownerUserId: demoUserId,
      ).all();
      final deletion = queued.singleWhere(
        (mutation) =>
            mutation.entityId == courseId &&
            mutation.operation == SyncOperation.delete,
      );

      expect(
          activeCourses.map((course) => course.id), isNot(contains(courseId)));
      expect(row.deletedAt, isNotNull);
      expect(row.version, 2);
      expect(deletion.status, SyncMutationStatus.pending);
      expect(deletion.baseVersion, 1);
      expect(deletion.payload['version'], 2);
    } finally {
      await openDatabase?.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });
}
