import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/features/course_template/data/supabase_course_template_repository.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  const ownerUserId = '11111111-1111-4111-8111-111111111111';
  const universityId = '22222222-2222-4222-8222-222222222222';
  const termId = '33333333-3333-4333-8333-333333333333';
  const templateId = '44444444-4444-4444-8444-444444444444';
  const copiedCourseId = '55555555-5555-4555-8555-555555555555';
  const context = ActiveScheduleContext(
    ownerUserId: ownerUserId,
    universityId: universityId,
    termId: termId,
    academicYear: 2026,
    primaryCalendarId: '66666666-6666-4666-8666-666666666666',
  );

  test('authenticated search maps the RPC result and refreshes the local cache',
      () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    String? rpcName;
    Map<String, Object?>? rpcParameters;
    final repository = SupabaseCourseTemplateRepository(
      db: database,
      context: context,
      clock: () => DateTime.utc(2026, 7, 18, 12),
      authenticatedUserIdOverride: () => ownerUserId,
      copiedCourseLookupOverride: _copiedCourse,
      rpcOverride: (name, parameters) async {
        rpcName = name;
        rpcParameters = parameters;
        return [_templateRow()];
      },
    );

    final results = await repository.searchTemplates(
      universityId: universityId,
      academicYear: 2026,
      query: ' 分散 システム ',
      instructor: ' 山田 ',
      weekday: 1,
      period: 2,
    );

    expect(rpcName, 'search_course_templates');
    expect(rpcParameters?['target_university_id'], universityId);
    expect(rpcParameters?['target_academic_year'], 2026);
    expect(rpcParameters?['target_instructor_name'], '山田');
    expect(rpcParameters?['target_day_of_week'], 1);
    expect(rpcParameters?['target_period_no'], 2);
    expect(results, hasLength(1));
    expect(results.single.id, templateId);
    expect(results.single.instructorName, '山田 太郎');
    expect(results.single.copyCountTotal, 12);
    expect(results.single.duplicateKey, '分散システム:山田太郎:1:2');
    expect(results.single.rankScore, 123.45);

    final cached = await database.courseTemplateDao.templateById(templateId);
    expect(cached, isNotNull);
    expect(cached!.universityId, universityId);
    expect(cached.copyCountTotal, 12);
  });

  test('search rejects a different university before an RPC is sent', () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    var wasCalled = false;
    final repository = SupabaseCourseTemplateRepository(
      db: database,
      context: context,
      clock: DateTime.now,
      authenticatedUserIdOverride: () => ownerUserId,
      copiedCourseLookupOverride: _copiedCourse,
      rpcOverride: (_, __) async {
        wasCalled = true;
        return const [];
      },
    );

    await expectLater(
      repository.searchTemplates(
        universityId: 'other-university',
        academicYear: 2026,
      ),
      throwsA(isA<PermissionError>()),
    );
    expect(wasCalled, isFalse);
  });

  test('copy uses the server RPC and hydrates an independent local snapshot',
      () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final calls = <String>[];
    final gateway = FakeRemoteScheduleGateway(
      deltaFor: (call) {
        if (call.afterCursor == 0) {
          return const ScheduleDeltaPage(
            afterCursor: 0,
            nextCursor: 4,
            hasMore: true,
            changes: [
              ScheduleDeltaChange(
                changeCursor: 4,
                entityType: 'assignment',
                entityId: '77777777-7777-4777-8777-777777777777',
                operation: ScheduleDeltaOperation.upsert,
                serverVersion: 1,
                payload: {'id': '77777777-7777-4777-8777-777777777777'},
              ),
            ],
          );
        }
        expect(call.afterCursor, 4);
        expect(call.limit, 500);
        return ScheduleDeltaPage(
          afterCursor: 4,
          nextCursor: 5,
          hasMore: false,
          changes: [_copiedCourseDelta()],
        );
      },
    );
    final repository = SupabaseCourseTemplateRepository(
      db: database,
      context: context,
      clock: () => DateTime.utc(2026, 7, 18, 12),
      authenticatedUserIdOverride: () => ownerUserId,
      rpcOverride: (name, parameters) async {
        calls.add(name);
        expect(name, 'copy_course_template');
        expect(parameters, {
          'template_id': templateId,
          'target_term_id': termId,
        });
        return copiedCourseId;
      },
      scheduleGateway: gateway,
    );

    final result = await repository.copyTemplate(
      templateId: templateId,
      ownerUserId: ownerUserId,
      termId: termId,
    );

    expect(result, copiedCourseId);
    expect(calls, ['copy_course_template']);
    expect(
      gateway.pullCalls.map((call) => call.afterCursor),
      [0, 4],
      reason: 'The copy hydration uses only the authenticated delta RPC.',
    );
    final course = await (database.select(database.userCourses)
          ..where((row) => row.id.equals(copiedCourseId)))
        .getSingle();
    expect(course.ownerUserId, ownerUserId);
    expect(course.termId, termId);
    expect(course.sourceTemplateId, templateId);
    expect(course.title, '分散システム');
    expect(course.visibilityLevel, 'PRIVATE');
    expect(
      await database.select(database.syncQueueEntries).get(),
      isEmpty,
      reason: 'The copied server row must not enqueue a duplicate create.',
    );
  });

  test(
      'copy classifies delta-hydration failures without retrying the server copy',
      () async {
    final cases = <(RemoteScheduleException, Matcher)>[
      (
        const RemoteScheduleAuthenticationException('authentication failed'),
        isA<AuthError>(),
      ),
      (
        const RemoteScheduleTransientException('transport failed'),
        isA<NetworkError>(),
      ),
      (
        const RemoteScheduleProtocolException('protocol failed'),
        isA<UnknownAppError>().having(
          (error) => error.message,
          'message',
          '授業データの形式を確認できませんでした。',
        ),
      ),
      (
        const RemoteScheduleException('remote failed'),
        isA<UnknownAppError>().having(
          (error) => error.message,
          'message',
          '授業データを取得できませんでした。しばらくしてからお試しください。',
        ),
      ),
    ];

    for (final (failure, matcher) in cases) {
      final database = local.AppDatabase(NativeDatabase.memory());
      try {
        final calls = <String>[];
        final gateway = FakeRemoteScheduleGateway(
          deltaFor: (_) => throw failure,
        );
        final repository = SupabaseCourseTemplateRepository(
          db: database,
          context: context,
          clock: () => DateTime.utc(2026, 7, 18, 12),
          authenticatedUserIdOverride: () => ownerUserId,
          rpcOverride: (name, _) async {
            calls.add(name);
            return copiedCourseId;
          },
          scheduleGateway: gateway,
        );

        await expectLater(
          repository.copyTemplate(
            templateId: templateId,
            ownerUserId: ownerUserId,
            termId: termId,
          ),
          throwsA(matcher),
        );
        expect(calls, ['copy_course_template']);
        expect(gateway.pullCalls, hasLength(1));
        expect(await database.select(database.userCourses).get(), isEmpty);
      } finally {
        await database.close();
      }
    }
  });

  test('copy handles a bodyless RPC failure without hydration or retry',
      () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final calls = <String>[];
    final gateway = FakeRemoteScheduleGateway(
      deltaFor: (_) => fail('A failed copy must not start delta hydration.'),
    );
    final repository = SupabaseCourseTemplateRepository(
      db: database,
      context: context,
      clock: () => DateTime.utc(2026, 7, 18, 12),
      authenticatedUserIdOverride: () => ownerUserId,
      rpcOverride: (name, _) async {
        calls.add(name);
        throw const PostgrestException(message: '', code: '400');
      },
      scheduleGateway: gateway,
    );

    await expectLater(
      repository.copyTemplate(
        templateId: templateId,
        ownerUserId: ownerUserId,
        termId: termId,
      ),
      throwsA(
        isA<UnknownAppError>().having(
          (error) => error.message,
          'message',
          '授業データを取得できませんでした。しばらくしてからお試しください。',
        ),
      ),
    );
    expect(calls, ['copy_course_template']);
    expect(gateway.pullCalls, isEmpty);
    expect(await database.select(database.userCourses).get(), isEmpty);
  });
}

ScheduleDeltaChange _copiedCourseDelta() => const ScheduleDeltaChange(
      changeCursor: 5,
      entityType: 'user_course',
      entityId: _copiedCourseId,
      operation: ScheduleDeltaOperation.upsert,
      serverVersion: 1,
      payload: {
        'id': _copiedCourseId,
        'ownerUserId': _ownerUserId,
        'termId': _termId,
        'sourceTemplateId': _templateId,
        'title': '分散システム',
        'normalizedTitle': '分散システム',
        'instructorName': '山田 太郎',
        'normalizedInstructorName': '山田太郎',
        'dayOfWeek': 1,
        'periodNo': 2,
        'room': 'E-201',
        'color': '#2F80ED',
        'visibilityLevel': 'PRIVATE',
        'updatedAt': '2026-07-18T12:00:00Z',
        'deletedAt': null,
        'version': 1,
      },
    );

const _ownerUserId = '11111111-1111-4111-8111-111111111111';
const _universityId = '22222222-2222-4222-8222-222222222222';
const _termId = '33333333-3333-4333-8333-333333333333';
const _templateId = '44444444-4444-4444-8444-444444444444';
const _copiedCourseId = '55555555-5555-4555-8555-555555555555';

Map<String, Object?> _templateRow() => {
      'id': _templateId,
      'university_id': _universityId,
      'academic_year': 2026,
      'term_id': null,
      'title': '分散システム',
      'normalized_title': '分散システム',
      'instructor_name': '山田 太郎',
      'normalized_instructor_name': '山田太郎',
      'day_of_week': 1,
      'period_no': 2,
      'room': 'E-201',
      'normalized_room': 'e201',
      'credit_count': 2,
      'syllabus_url': 'https://example.test/syllabus',
      'external_course_code': 'CS-201',
      'copy_count_total': 12,
      'copy_count_term': 4,
      'trust_score': 0.8,
      'duplicate_key': '分散システム:山田太郎:1:2',
      'rank_score': '123.45',
      'created_by': 'server-only-author',
      'author_display_name': 'server-only-author',
    };

Future<Map<String, Object?>> _copiedCourse({
  required String courseId,
  required String ownerUserId,
}) async {
  expect(courseId, _copiedCourseId);
  expect(ownerUserId, _ownerUserId);
  return {
    'id': _copiedCourseId,
    'owner_user_id': _ownerUserId,
    'term_id': _termId,
    'source_template_id': _templateId,
    'title': '分散システム',
    'normalized_title': '分散システム',
    'instructor_name': '山田 太郎',
    'normalized_instructor_name': '山田太郎',
    'day_of_week': 1,
    'period_no': 2,
    'room': 'E-201',
    'color': '#2F80ED',
    'visibility_level': 'PRIVATE',
    'updated_at': '2026-07-18T12:00:00Z',
    'deleted_at': null,
    'version': 1,
  };
}
