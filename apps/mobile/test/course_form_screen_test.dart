import 'dart:async';

import '../integration_test/support/popup_route_dismissal.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/course_template/application/course_template_providers.dart';
import 'package:university_schedule_mobile/features/course_template/presentation/course_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';

void main() {
  testWidgets('Quick Add course route dismisses blocking popup transitions',
      (tester) async {
    _useTallViewport(tester);
    final observer = _PopupObserver();
    final router = GoRouter(
      observers: [observer],
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const MvpScaffold(
            title: 'テスト',
            selectedIndex: 0,
            child: SizedBox.shrink(),
          ),
        ),
        GoRoute(
          path: '/courses/manual',
          builder: (_, __) => const CourseFormScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
        demoAppControllerProvider.overrideWith(() => _PublishingSchedule()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('追加'));
    await tester.pumpAndSettle();
    final quickAddRoute = observer.lastPopup!;
    expect(quickAddRoute, isA<ModalBottomSheetRoute<dynamic>>());
    await tester.tap(find.text('授業を追加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    debugPrint('LOCAL_ROUTE_DIAGNOSTIC: quickAdd='
        '${quickAddRoute.runtimeType} active=${quickAddRoute.isActive} '
        'barriers=${find.byType(ModalBarrier).evaluate().length} '
        'blocking=${find.byType(ModalBarrier).hitTestable().evaluate().length} '
        'sheets=${find.byType(BottomSheet).evaluate().length}');
    await waitForPopupRouteDismissal(
      tester,
      quickAddRoute,
      label: 'the Quick Add course route',
    );
    expect(find.text('授業を作成'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('授業を追加'), findsNothing);
    expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
    await tester.enterText(find.byType(TextFormField).first, '合成授業');
    final weekday = find.byType(DropdownButtonFormField<int>).first;
    await tester.tap(weekday);
    await tester.pump(const Duration(milliseconds: 300));
    final dropdownRoute = observer.lastPopup!;
    expect(identical(dropdownRoute, quickAddRoute), isFalse);
    final option = find.text('火').last;
    await tester.tapAt(tester.getCenter(option));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.state<FormFieldState<int>>(weekday).value, DateTime.tuesday);
    debugPrint('LOCAL_ROUTE_DIAGNOSTIC: dropdown='
        '${dropdownRoute.runtimeType} active=${dropdownRoute.isActive} '
        'barriers=${find.byType(ModalBarrier).evaluate().length} '
        'blocking=${find.byType(ModalBarrier).hitTestable().evaluate().length}');
    await waitForPopupRouteDismissal(
      tester,
      dropdownRoute,
      label: 'the course weekday popup route',
    );
    expect(dropdownRoute.overlayEntries, isEmpty);
    expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
    final save = find.byKey(const Key('course-save'));
    await tester.ensureVisible(save);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(
        find.descendant(of: save, matching: find.byType(InkWell)).hitTestable(),
        findsOneWidget);
  });

  testWidgets('edit form waits for the course snapshot before showing fields',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _DeferredSchedule();
    addTearDown(schedule.close);
    final router = _courseEditRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          demoAppControllerProvider.overrideWith(() => schedule),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('course-form-list')), findsNothing);

    schedule.emit(_editState());
    await tester.pumpAndSettle();

    expect(find.text('授業を編集'), findsOneWidget);
    expect(find.byKey(const Key('course-form-list')), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller
          ?.text,
      '既存授業',
    );
  });

  testWidgets('form displays a recoverable message when the snapshot fails',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _DeferredSchedule();
    addTearDown(schedule.close);
    final router = _courseFormRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          demoAppControllerProvider.overrideWith(() => schedule),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    schedule.fail(StateError('synthetic snapshot failure'));
    await tester.pumpAndSettle();

    expect(find.textContaining('読み込みに失敗しました:'), findsOneWidget);
    expect(find.byKey(const Key('course-form-list')), findsNothing);
  });

  testWidgets('edit saves the loaded version and preserves unchanged fields',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _EditingSchedule();
    final router = _courseEditRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          demoAppControllerProvider.overrideWith(() => schedule),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    expect(tester.widget<TextFormField>(fields.at(0)).controller?.text, '既存授業');
    expect(tester.widget<TextFormField>(fields.at(1)).controller?.text, '教室A');
    expect(tester.widget<TextFormField>(fields.at(2)).controller?.text, '教員A');
    await tester.enterText(fields.at(0), '変更後の授業');
    await tester.tap(find.byKey(const Key('course-save')));
    await tester.pumpAndSettle();

    expect(schedule.updateCalls, hasLength(1));
    final update = schedule.updateCalls.single;
    expect(update.courseId, 'course-1');
    expect(update.expectedVersion, 8);
    expect(update.input.title, '変更後の授業');
    expect(update.input.dayOfWeek, DateTime.tuesday);
    expect(update.input.periodNo, 3);
    expect(update.input.room, '教室A');
    expect(update.input.instructorName, '教員A');
    expect(update.input.color, '#27AE60');
    expect(update.input.visibilityLevel, VisibilityLevel.busyOnly);
    expect(find.text('編集後の詳細 course-1'), findsOneWidget);
  });

  testWidgets('edit conflict keeps the draft and explains how to recover',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _EditingSchedule(failWithConflict: true);
    final router = _courseEditRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          demoAppControllerProvider.overrideWith(() => schedule),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '競合後も保持する入力');
    await tester.tap(find.byKey(const Key('course-save')));
    await tester.pumpAndSettle();

    expect(find.text('別の変更が反映されました。画面を開き直して確認してください。'), findsOneWidget);
    expect(find.byKey(const Key('course-form-list')), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller
          ?.text,
      '競合後も保持する入力',
    );
    expect(schedule.updateCalls, hasLength(1));
    expect(schedule.updateCalls.single.expectedVersion, 8);
  });

  testWidgets('template publishing is opt-in and follows personal save',
      (tester) async {
    final schedule = _PublishingSchedule();
    final repository = _PublishingTemplateRepository(events: schedule.events);
    final router = _courseFormRouter();
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(
              _contributionTestConfig(),
            ),
            demoAppControllerProvider.overrideWith(() => schedule),
            courseTemplateRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final publishSwitch = find.byKey(const Key('course-publish-template'));
      expect(tester.widget<SwitchListTile>(publishSwitch).value, isFalse);
      expect(find.textContaining('個人メモ'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, '公開を選んだ授業');
      await tester.tap(publishSwitch);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(publishSwitch).value, isTrue);
      await tester.tap(find.byKey(const Key('course-save')));
      await tester.pumpAndSettle();

      expect(schedule.events, [
        'save:公開を選んだ授業',
        'publish:course-published',
      ]);
      expect(repository.publishedCourseIds, ['course-published']);
      expect(find.text('公開後の授業 course-published'), findsOneWidget);
      expect(find.text('個人授業を保存し、授業テンプレートを公開しました'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('personal course save never publishes when opt-in stays off',
      (tester) async {
    final schedule = _PublishingSchedule();
    final repository = _PublishingTemplateRepository(events: schedule.events);
    final router = _courseFormRouter();
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(_contributionTestConfig()),
            demoAppControllerProvider.overrideWith(() => schedule),
            courseTemplateRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final publishSwitch = find.byKey(const Key('course-publish-template'));
      expect(tester.widget<SwitchListTile>(publishSwitch).value, isFalse);
      await tester.enterText(find.byType(TextFormField).first, '個人だけの授業');
      await tester.tap(find.byKey(const Key('course-save')));
      await tester.pumpAndSettle();

      expect(schedule.events, ['save:個人だけの授業']);
      expect(repository.publishedCourseIds, isEmpty);
      expect(find.text('公開後の授業 course-published'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('failed optional publish leaves the saved personal course intact',
      (tester) async {
    final schedule = _PublishingSchedule();
    final repository = _PublishingTemplateRepository(
      events: schedule.events,
      failPublish: true,
    );
    final router = _courseFormRouter();
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(
              _contributionTestConfig(),
            ),
            demoAppControllerProvider.overrideWith(() => schedule),
            courseTemplateRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, '個人保存を守る授業');
      await tester.tap(find.byKey(const Key('course-publish-template')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('course-save')));
      await tester.pumpAndSettle();

      expect(schedule.events, [
        'save:個人保存を守る授業',
        'publish:course-published',
      ]);
      expect(repository.publishedCourseIds, ['course-published']);
      expect(find.text('公開後の授業 course-published'), findsOneWidget);
      expect(
        find.text('個人授業は保存済みですが、共有投稿は未送信です。後で再試行してください。'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('empty title is blocked and a failed course save can be retried',
      (tester) async {
    final schedule = _RecoveringSchedule();
    final router = GoRouter(
      initialLocation: '/courses/manual',
      routes: [
        GoRoute(
          path: '/courses/manual',
          builder: (context, state) => const CourseFormScreen(),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (context, state) => Scaffold(
            body: Text('保存後の授業 ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            demoAppControllerProvider.overrideWith(() => schedule),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final saveButton = find.byKey(const Key('course-save'));
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(find.text('必須です'), findsOneWidget);
      expect(schedule.attempts, 0);

      await tester.enterText(
        find.byType(TextFormField).first,
        '再試行できる授業',
      );
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(
        find.text('保存に失敗しました。入力内容を確認して再試行してください。'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller
            ?.text,
        '再試行できる授業',
      );
      expect(schedule.attempts, 1);

      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(find.text('保存後の授業 course-retry'), findsOneWidget);
      expect(schedule.attempts, 2);
      expect(schedule.inputs.map((input) => input.title),
          ['再試行できる授業', '再試行できる授業']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('course edit discard pops the GoRouter route exactly once',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/course/course-1',
      routes: [
        GoRoute(
          path: '/course/course-1',
          builder: (context, state) => Scaffold(
            body: FilledButton(
              key: const Key('open-course-edit'),
              onPressed: () => context.go('/course/course-1/edit'),
              child: const Text('詳細画面'),
            ),
          ),
        ),
        GoRoute(
          path: '/course/course-1/edit',
          builder: (context, state) =>
              const CourseFormScreen(courseId: 'course-1'),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          demoAppControllerProvider.overrideWith(_Schedule.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-course-edit')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '変更後の授業');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('変更を破棄しますか？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('keep-editing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-form-list')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes')));
    await tester.pumpAndSettle();

    expect(find.text('詳細画面'), findsOneWidget);
    expect(find.byKey(const Key('course-form-list')), findsNothing);
  });
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

GoRouter _courseFormRouter() => GoRouter(
      initialLocation: '/courses/manual',
      routes: [
        GoRoute(
          path: '/courses/manual',
          builder: (context, state) => const CourseFormScreen(),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (context, state) => Scaffold(
            body: Text('公開後の授業 ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );

GoRouter _courseEditRouter() => GoRouter(
      initialLocation: '/course/course-1/edit',
      routes: [
        GoRoute(
          path: '/course/:id',
          builder: (context, state) => Scaffold(
            body: Text('編集後の詳細 ${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/course/:id/edit',
          builder: (context, state) =>
              CourseFormScreen(courseId: state.pathParameters['id']),
        ),
      ],
    );

AppConfig _contributionTestConfig() => AppConfig.validated(
      environment: 'local',
      demoMode: false,
      supabaseUrl: 'http://127.0.0.1:55321',
      supabasePublishableKey: 'synthetic-local-publishable-key',
    );

class _RecoveringSchedule extends DemoAppController {
  int attempts = 0;
  final List<UserCourseInput> inputs = [];

  @override
  Stream<DemoAppState> build() =>
      Stream.value(DemoAppState.empty(now: DateTime.utc(2026, 9, 22)));

  @override
  Future<String> createUserCourse(UserCourseInput input) async {
    inputs.add(input);
    attempts++;
    if (attempts == 1) throw StateError('synthetic transient save failure');
    return 'course-retry';
  }
}

DemoAppState _editState() => DemoAppState.empty(
      now: DateTime.utc(2026, 9, 22),
    ).copyWith(courses: const [_editableCourse]);

const _editableCourse = UserCourse(
  id: 'course-1',
  ownerUserId: 'owner-1',
  termId: 'term-1',
  title: '既存授業',
  normalizedTitle: '既存授業',
  instructorName: '教員A',
  dayOfWeek: DateTime.tuesday,
  periodNo: 3,
  room: '教室A',
  color: '#27AE60',
  visibilityLevel: VisibilityLevel.busyOnly,
  version: 8,
);

class _PopupObserver extends NavigatorObserver {
  PopupRoute<dynamic>? lastPopup;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute<dynamic>) lastPopup = route;
  }
}

class _DeferredSchedule extends DemoAppController {
  final _states = StreamController<DemoAppState>();

  @override
  Stream<DemoAppState> build() => _states.stream;

  void emit(DemoAppState state) => _states.add(state);

  void fail(Object error) => _states.addError(error);

  Future<void> close() => _states.close();
}

class _EditingSchedule extends DemoAppController {
  _EditingSchedule({this.failWithConflict = false});

  final bool failWithConflict;
  final updateCalls = <({
    String courseId,
    int expectedVersion,
    UserCourseInput input,
  })>[];

  @override
  Stream<DemoAppState> build() => Stream.value(_editState());

  @override
  Future<void> updateUserCourse(
    String courseId,
    int expectedVersion,
    UserCourseInput input,
  ) async {
    updateCalls.add((
      courseId: courseId,
      expectedVersion: expectedVersion,
      input: input,
    ));
    if (failWithConflict) {
      throw const ConflictError('synthetic course version conflict');
    }
  }
}

class _PublishingSchedule extends DemoAppController {
  final events = <String>[];

  @override
  Stream<DemoAppState> build() =>
      Stream.value(DemoAppState.empty(now: DateTime.utc(2026, 9, 22)));

  @override
  Future<String> createUserCourse(UserCourseInput input) async {
    events.add('save:${input.title}');
    return 'course-published';
  }
}

class _PublishingTemplateRepository
    implements CourseTemplateRepository, CourseTemplateContributionRepository {
  _PublishingTemplateRepository(
      {required this.events, this.failPublish = false});

  final List<String> events;
  final bool failPublish;
  final publishedCourseIds = <String>[];

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
  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  }) async =>
      'course-copy';

  @override
  Future<Map<String, Object?>> publishTemplate({
    required String courseId,
    String? operationId,
  }) async {
    publishedCourseIds.add(courseId);
    events.add('publish:$courseId');
    if (failPublish) throw StateError('synthetic publish failure');
    return const {'ok': true};
  }

  @override
  Future<Map<String, Object?>> submitEditProposal({
    required String templateId,
    required Map<String, Object?> proposedPayload,
    required int expectedVersion,
    String? operationId,
  }) async =>
      const {};

  @override
  Future<Map<String, Object?>> reportTemplate({
    required String templateId,
    required String reason,
    String? operationId,
  }) async =>
      const {};

  @override
  Future<Map<String, Object?>> templateDetails(String templateId) async =>
      const {};

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

class _Schedule extends DemoAppController {
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
              instructorName: '教員',
              dayOfWeek: DateTime.monday,
              periodNo: 1,
            ),
          ],
        ),
      );
}
