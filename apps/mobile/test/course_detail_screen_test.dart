import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/course_template/application/course_template_providers.dart';
import 'package:university_schedule_mobile/features/course_template/presentation/course_detail_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  testWidgets('canceling course deletion leaves the detail unchanged',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _Schedule();
    final router = await _pumpDetailWithNavigation(tester, schedule);
    addTearDown(router.dispose);

    await tester.tap(find.byTooltip('授業を削除'));
    await tester.pumpAndSettle();
    expect(find.text('授業を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(schedule.deleteCalls, isEmpty);
    expect(find.text('授業'), findsOneWidget);
    expect(find.text('時間割へ戻りました'), findsNothing);
  });

  testWidgets(
      'confirmed deletion sends the loaded version and returns to timetable',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _Schedule();
    final router = await _pumpDetailWithNavigation(tester, schedule);
    addTearDown(router.dispose);

    await tester.tap(find.byTooltip('授業を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(schedule.deleteCalls, [(courseId: 'course-1', expectedVersion: 1)]);
    expect(find.text('時間割へ戻りました'), findsOneWidget);
  });

  testWidgets('delete conflict keeps detail open and shows recovery guidance',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _Schedule(failDeleteWithConflict: true);
    final router = await _pumpDetailWithNavigation(tester, schedule);
    addTearDown(router.dispose);

    await tester.tap(find.byTooltip('授業を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('別の変更が反映されました。画面を開き直して確認してください。'), findsOneWidget);
    expect(find.text('授業'), findsOneWidget);
    expect(find.text('時間割へ戻りました'), findsNothing);
    expect(schedule.deleteCalls, [(courseId: 'course-1', expectedVersion: 1)]);
  });

  testWidgets('delete failure keeps detail open and offers retry guidance',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _Schedule(failDeleteWithError: true);
    final router = await _pumpDetailWithNavigation(tester, schedule);
    addTearDown(router.dispose);

    await tester.tap(find.byTooltip('授業を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(
      find.text('授業を削除できませんでした。時間割を更新して再試行してください。'),
      findsOneWidget,
    );
    expect(find.text('授業'), findsOneWidget);
    expect(find.text('時間割へ戻りました'), findsNothing);
    expect(schedule.deleteCalls, [(courseId: 'course-1', expectedVersion: 1)]);
  });

  testWidgets('report dialog can be dismissed by Back after text entry',
      (tester) async {
    await _pumpDetail(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('course-template-report')),
      300,
      scrollable: find.byType(Scrollable),
    );

    await tester.tap(find.byKey(const Key('course-template-report')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '教室が違います');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('proposal dialog can be dismissed by Back after text entry',
      (tester) async {
    await _pumpDetail(
      tester,
      extraOverrides: [
        courseTemplateRepositoryProvider
            .overrideWithValue(_TemplateRepository()),
      ],
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('course-template-proposal')),
      300,
      scrollable: find.byType(Scrollable),
    );

    await tester.tap(find.byKey(const Key('course-template-proposal')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '更新後の授業');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('proposal sends edited public fields with the fetched version',
      (tester) async {
    final repository = _TemplateRepository();
    final schedule = _Schedule();
    await _pumpDetail(
      tester,
      schedule: schedule,
      extraOverrides: [
        courseTemplateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('course-template-proposal')),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.byKey(const Key('course-template-proposal')));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '授業');
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, '教員');
    await tester.enterText(fields.at(0), '更新後の授業');
    await tester.enterText(fields.at(1), '更新後の教員');
    await tester.tap(find.text('提案する'));
    await tester.pumpAndSettle();

    expect(repository.proposalCalls, hasLength(1));
    final submitted = repository.proposalCalls.single;
    expect(submitted.templateId, 'template-1');
    expect(submitted.payload, {
      'title': '更新後の授業',
      'instructor_name': '更新後の教員',
    });
    expect(submitted.expectedVersion, 4);
    expect(schedule.updateCalls, 0);
    expect(find.text('修正提案を受け付けました'), findsOneWidget);
  });

  testWidgets('template update dialog compares personal and after values',
      (tester) async {
    final repository = _UpdateRepository();
    await _pumpDetail(
      tester,
      extraOverrides: [
        courseTemplateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await _openUpdateReview(tester);

    expect(find.text('現在の自分の授業'), findsOneWidget);
    expect(find.text('反映後'), findsOneWidget);
    expect(find.text('授業'), findsOneWidget);
    expect(find.text('更新授業'), findsOneWidget);
    expect(find.text('教員'), findsAtLeastNWidgets(1));
    expect(find.text('更新教員'), findsOneWidget);
    expect(find.text('月曜'), findsOneWidget);
    expect(find.text('火曜'), findsOneWidget);
    expect(find.text('1限'), findsOneWidget);
    expect(find.text('3限'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(repository.reviewCalls, isEmpty);
  });

  testWidgets('template update ignore uses both response versions',
      (tester) async {
    final repository = _UpdateRepository();
    await _pumpDetail(
      tester,
      extraOverrides: [
        courseTemplateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await _openUpdateReview(tester);

    await tester.tap(find.text('今回は無視'));
    await tester.pumpAndSettle();

    expect(repository.reviewCalls, [
      (
        action: 'ignore',
        templateVersion: 12,
        courseVersion: 7,
      ),
    ]);
  });

  testWidgets('template update apply uses both response versions',
      (tester) async {
    final repository = _UpdateRepository();
    await _pumpDetail(
      tester,
      extraOverrides: [
        courseTemplateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await _openUpdateReview(tester);

    await tester.tap(find.text('反映する'));
    await tester.pumpAndSettle();

    expect(repository.reviewCalls, [
      (
        action: 'apply',
        templateVersion: 12,
        courseVersion: 7,
      ),
    ]);
  });

  testWidgets('malformed template comparison shows an error without review',
      (tester) async {
    final repository = _UpdateRepository(
      response: const {
        'available': true,
        'template_version': 12,
        'course_version': 7,
        'after': {
          'canonical_template_id': 'template-1',
          'title': '更新授業',
          'instructor_name': '更新教員',
          'day_of_week': 2,
          'period_no': 3,
        },
        'changed': {'title': '更新授業'},
      },
    );
    await _pumpDetail(
      tester,
      extraOverrides: [
        courseTemplateRepositoryProvider.overrideWithValue(repository),
      ],
    );
    await _openUpdateReview(tester);

    expect(
      find.text('テンプレート更新の比較情報を確認できませんでした'),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(repository.reviewCalls, isEmpty);
  });
}

Future<void> _openUpdateReview(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('course-template-update-review')),
    300,
    scrollable: find.byType(Scrollable),
  );
  await tester.tap(find.byKey(const Key('course-template-update-review')));
  await tester.pumpAndSettle();
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
  _Schedule? schedule,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        demoAppControllerProvider.overrideWith(() => schedule ?? _Schedule()),
        ...extraOverrides,
      ],
      child: const MaterialApp(
        home: CourseDetailScreen(courseId: 'course-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump();
  await tester.pump();
}

Future<GoRouter> _pumpDetailWithNavigation(
  WidgetTester tester,
  _Schedule schedule,
) async {
  final router = GoRouter(
    initialLocation: '/course/course-1',
    routes: [
      GoRoute(
        path: '/course/:id',
        builder: (context, state) =>
            CourseDetailScreen(courseId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/timetable',
        builder: (context, state) => const Scaffold(body: Text('時間割へ戻りました')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [demoAppControllerProvider.overrideWith(() => schedule)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Schedule extends DemoAppController {
  _Schedule({
    this.failDeleteWithConflict = false,
    this.failDeleteWithError = false,
  });

  final bool failDeleteWithConflict;
  final bool failDeleteWithError;
  final deleteCalls = <({String courseId, int expectedVersion})>[];
  int updateCalls = 0;

  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 9, 22)).copyWith(
          courses: const [
            UserCourse(
              id: 'course-1',
              ownerUserId: 'owner-1',
              termId: 'term-1',
              title: '授業',
              normalizedTitle: '授業',
              sourceTemplateId: 'template-1',
              instructorName: '教員',
              dayOfWeek: DateTime.monday,
              periodNo: 1,
            ),
          ],
        ),
      );

  @override
  Future<void> updateUserCourse(
    String courseId,
    int expectedVersion,
    UserCourseInput input,
  ) async {
    updateCalls++;
  }

  @override
  Future<void> deleteUserCourse(String courseId, int expectedVersion) async {
    deleteCalls.add((courseId: courseId, expectedVersion: expectedVersion));
    if (failDeleteWithConflict) {
      throw const ConflictError('synthetic course version conflict');
    }
    if (failDeleteWithError) {
      throw StateError('synthetic delete failure');
    }
  }
}

class _TemplateRepository
    implements CourseTemplateRepository, CourseTemplateContributionRepository {
  final proposalCalls = <({
    String templateId,
    Map<String, Object?> payload,
    int expectedVersion,
  })>[];

  @override
  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  }) async =>
      'course-copy';

  @override
  Future<List<CourseTemplate>> searchTemplates({
    required String universityId,
    required int academicYear,
    String? termId,
    String query = '',
    String instructor = '',
    int? weekday,
    int? period,
  }) async =>
      const [];

  @override
  Future<Map<String, Object?>> publishTemplate({
    required String courseId,
    String? operationId,
  }) async =>
      const {};

  @override
  Future<Map<String, Object?>> submitEditProposal({
    required String templateId,
    required Map<String, Object?> proposedPayload,
    required int expectedVersion,
    String? operationId,
  }) async {
    proposalCalls.add((
      templateId: templateId,
      payload: Map<String, Object?>.from(proposedPayload),
      expectedVersion: expectedVersion,
    ));
    return const {'proposal_id': 'proposal-1'};
  }

  @override
  Future<Map<String, Object?>> reportTemplate({
    required String templateId,
    required String reason,
    String? operationId,
  }) async =>
      const {};

  @override
  Future<Map<String, Object?>> templateDetails(String templateId) async =>
      const {
        'title': '授業',
        'instructor_name': '教員',
        'version': 4,
      };

  @override
  Future<Map<String, Object?>> templateUpdate(String courseId) async =>
      const {'available': false};

  @override
  Future<Map<String, Object?>> reviewTemplateUpdate({
    required String courseId,
    required String action,
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  }) async =>
      const {};
}

class _UpdateRepository extends _TemplateRepository {
  _UpdateRepository({Map<String, Object?>? response})
      : response = response ??
            const {
              'available': true,
              'template_version': 12,
              'course_version': 7,
              'after': {
                'canonical_template_id': 'template-1',
                'title': '更新授業',
                'instructor_name': '更新教員',
                'day_of_week': 2,
                'period_no': 3,
                'room': '新教室',
              },
              'changed': {
                'title': '更新授業',
                'instructor_name': '更新教員',
                'day_of_week': 2,
                'period_no': 3,
                'room': '新教室',
              },
            };

  final Map<String, Object?> response;
  final reviewCalls =
      <({String action, int? templateVersion, int? courseVersion})>[];

  @override
  Future<Map<String, Object?>> templateUpdate(String courseId) async =>
      response;

  @override
  Future<Map<String, Object?>> reviewTemplateUpdate({
    required String courseId,
    required String action,
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  }) async {
    reviewCalls.add(
      (
        action: action,
        templateVersion: expectedTemplateVersion,
        courseVersion: expectedCourseVersion,
      ),
    );
    return const {'status': 'applied'};
  }
}
