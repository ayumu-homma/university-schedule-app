import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/course_template/data/supabase_course_template_repository.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const owner = '11111111-1111-4111-8111-111111111111';
  const university = '22222222-2222-4222-8222-222222222222';
  const term = '33333333-3333-4333-8333-333333333333';
  const context = ActiveScheduleContext(
    ownerUserId: owner,
    universityId: university,
    termId: term,
    academicYear: 2026,
    primaryCalendarId: '66666666-6666-4666-8666-666666666666',
  );

  test('publishing, proposal, report, and explicit update review use RPCs',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final calls = <String>[];
    final repo = SupabaseCourseTemplateRepository(
      db: db,
      context: context,
      clock: DateTime.now,
      authenticatedUserIdOverride: () => owner,
      copiedCourseLookupOverride: (
              {required courseId, required ownerUserId}) async =>
          {'id': courseId, 'owner_user_id': ownerUserId},
      rpcOverride: (name, parameters) async {
        calls.add('$name:${parameters['p_operation_id'] ?? ''}');
        if (name == 'get_course_template_update') {
          return {'available': true, 'template_version': 3};
        }
        if (name == 'get_course_template_for_user') {
          return {'id': 'template-id', 'version': 2, 'title': '授業'};
        }
        return {'ok': true};
      },
    );

    expect(
        await repo.publishTemplate(
            courseId: 'course-id', operationId: 'op-publish'),
        {'ok': true});
    expect(
      await repo.submitEditProposal(
        templateId: 'template-id',
        proposedPayload: const {'title': '更新授業'},
        expectedVersion: 2,
        operationId: 'op-proposal',
      ),
      {'ok': true},
    );
    expect(await repo.templateDetails('template-id'), {
      'id': 'template-id',
      'version': 2,
      'title': '授業',
    });
    expect(
        await repo.reportTemplate(
            templateId: 'template-id',
            reason: '教室が違う',
            operationId: 'op-report'),
        {'ok': true});
    expect(await repo.templateUpdate('course-id'),
        {'available': true, 'template_version': 3});
    expect(
      await repo.reviewTemplateUpdate(
          courseId: 'course-id', action: 'apply', expectedTemplateVersion: 3),
      {'ok': true},
    );
    expect(calls.map((value) => value.split(':').first), [
      'publish_course_template',
      'submit_course_template_edit_proposal',
      'get_course_template_for_user',
      'report_course_template',
      'get_course_template_update',
      'review_course_template_update',
    ]);
  });

  test('offline-first template operations follow the durable create order',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final schedule = DriftScheduleRepository(db);
    final courseId = await schedule.createUserCourse(
      ownerUserId: owner,
      termId: term,
      input: const UserCourseInput(title: '授業', dayOfWeek: 1, periodNo: 1),
    );
    final repo = SupabaseCourseTemplateRepository(
      db: db,
      context: context,
      clock: DateTime.now,
      offlineFirst: true,
      authenticatedUserIdOverride: () => owner,
      copiedCourseLookupOverride: (
              {required courseId, required ownerUserId}) async =>
          {'id': courseId, 'owner_user_id': ownerUserId},
      rpcOverride: (name, parameters) async => {'ok': true},
    );
    expect(await repo.publishTemplate(courseId: courseId), {
      'course_id': courseId,
      'personal_course_id': courseId,
      'status': 'queued',
      'operation_id': isA<String>(),
    });
    final queued = await DriftSyncQueue(db, ownerUserId: owner).all();
    expect(queued.map((mutation) => mutation.entityType), [
      'user_course',
      'course_template_publish',
    ]);
  });
}
