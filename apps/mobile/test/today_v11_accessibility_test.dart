import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_screen.dart';

void main() {
  final now = JapanTime.at(year: 2026, month: 8, day: 10, hour: 10);

  testWidgets('Today overview uses briefing counts and opens existing routes',
      (tester) async {
    const viewport = Size(412, 915);
    await _setViewport(tester, viewport);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(
      router: router,
      viewportSize: viewport,
      now: now,
      state: _state(now, withData: true),
    ));
    await tester.pumpAndSettle();

    expect(find.text('現在の授業'), findsWidgets);
    final focusCourse = find.byKey(const Key('today-focus-course'));
    expect(
      find.descendant(
        of: focusCourse,
        matching: find.textContaining('09:00〜11:30'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: focusCourse,
        matching: find.textContaining('North Hall 301'),
      ),
      findsOneWidget,
    );
    expect(find.text('締切 2件'), findsOneWidget);
    expect(find.text('テスト 1件'), findsOneWidget);
    expect(focusCourse, findsOneWidget);

    await tester.tap(focusCourse);
    await tester.pumpAndSettle();
    expect(find.text('/course/course-1'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('today-count-assignments')));
    await tester.pumpAndSettle();
    expect(find.text('/assignments'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('today-count-exams')));
    await tester.pumpAndSettle();
    expect(find.text('/exams'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('today-count-events')));
    await tester.pumpAndSettle();
    expect(find.text('/calendar'), findsOneWidget);
  });

  testWidgets(
      'empty Today has one useful add prompt without empty category wall',
      (tester) async {
    const viewport = Size(360, 800);
    await _setViewport(tester, viewport);
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(
      router: router,
      viewportSize: viewport,
      now: now,
      state: _state(now),
    ));
    await tester.pumpAndSettle();

    expect(find.text('今日の個人予定はまだありません。必要なものを追加できます。'), findsOneWidget);
    expect(find.text('締切'), findsNothing);
    expect(find.text('今日の授業'), findsNothing);
    expect(find.text('今日のテスト'), findsNothing);
    expect(find.byKey(const Key('today-empty-add-course')), findsOneWidget);
    expect(find.byKey(const Key('today-empty-add-event')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('next class is shown before its start with its time and room',
      (tester) async {
    const viewport = Size(412, 915);
    await _setViewport(tester, viewport);
    final router = _router();
    addTearDown(router.dispose);
    final beforeClass = JapanTime.at(year: 2026, month: 8, day: 10, hour: 8);

    await tester.pumpWidget(_app(
      router: router,
      viewportSize: viewport,
      now: beforeClass,
      state: _state(beforeClass, withData: true),
    ));
    await tester.pumpAndSettle();

    expect(find.text('次の授業'), findsOneWidget);
    final focusCourse = find.byKey(const Key('today-focus-course'));
    expect(
      find.descendant(
        of: focusCourse,
        matching: find.textContaining('09:00〜11:30'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: focusCourse,
        matching: find.textContaining('North Hall 301'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('200% scale and long Japanese course text stays reachable',
      (tester) async {
    const viewports = [
      Size(360, 640),
      Size(412, 915),
      Size(1024, 768),
      Size(844, 390),
    ];
    for (final viewport in viewports) {
      for (final dark in [false, true]) {
        await _setViewport(tester, viewport);
        final router = _router();
        final keyboardInset = viewport.height < 500 ? 120.0 : 0.0;
        await tester.pumpWidget(_app(
          router: router,
          viewportSize: viewport,
          now: now,
          state: _state(now, withData: true, longJapanese: true),
          textScale: 2,
          dark: dark,
          keyboardInset: keyboardInset,
        ));
        await tester.pumpAndSettle();

        final courseButton = find.byKey(const Key('today-focus-course'));
        await tester.ensureVisible(courseButton);
        final semanticsHandle = tester.ensureSemantics();
        try {
          expect(
            find.descendant(
              of: courseButton,
              matching: find.text(
                '現代日本語と大学生活に関する長い講義タイトルの表示確認テスト',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: courseButton,
              matching: find.textContaining('総合教育研究棟・東側キャンパス三階三〇一演習室'),
            ),
            findsOneWidget,
          );
          expect(
            Theme.of(tester.element(courseButton)).brightness,
            dark ? Brightness.dark : Brightness.light,
          );
          expect(tester.getSize(courseButton).height, greaterThanOrEqualTo(48));
          expect(
            tester
                .getSemantics(courseButton)
                .getSemanticsData()
                .hasAction(SemanticsAction.tap),
            isTrue,
          );
          final availableHeight = viewport.height - keyboardInset;
          final availableBounds = Rect.fromLTWH(
            0,
            0,
            viewport.width,
            availableHeight,
          );
          expect(
            availableBounds.overlaps(tester.getRect(courseButton)),
            isTrue,
            reason: 'course action should remain visible after scrolling in '
                '${viewport.width}x${viewport.height}, dark=$dark',
          );
          final assignmentButton =
              find.byKey(const Key('today-count-assignments'));
          await tester.ensureVisible(assignmentButton);
          expect(tester.getSize(assignmentButton).height,
              greaterThanOrEqualTo(48));
          expect(find.byKey(const Key('today-briefing-list')), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semanticsHandle.dispose();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        router.dispose();
      }
    }
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Widget _app({
  required GoRouter router,
  required Size viewportSize,
  required DateTime now,
  required DemoAppState state,
  double textScale = 1,
  bool dark = false,
  double keyboardInset = 0,
}) =>
    ProviderScope(
      overrides: [
        activeScheduleContextProvider.overrideWithValue(_context),
        todayTimeProvider.overrideWith((ref) => Stream.value(now)),
        demoAppControllerProvider.overrideWith(() => _TestController(state)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: viewportSize,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
      ),
    );

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const TodayScreen()),
        for (final path in [
          '/course/:id',
          '/assignments',
          '/exams',
          '/calendar',
          '/courses/manual',
          '/events/new',
          '/settings',
        ])
          GoRoute(
            path: path,
            builder: (context, state) => Scaffold(
              body: Center(child: Text(state.uri.path)),
            ),
          ),
      ],
    );

class _TestController extends DemoAppController {
  _TestController(this.initial);

  final DemoAppState initial;

  @override
  Stream<DemoAppState> build() => Stream.value(initial);
}

DemoAppState _state(DateTime now,
        {bool withData = false, bool longJapanese = false}) =>
    DemoAppState(
      templates: const [],
      periodSettings: withData
          ? const [
              PeriodSetting(
                id: 'period-1',
                ownerUserId: 'owner',
                dayOfWeek: DateTime.monday,
                periodNo: 1,
                startTimeMinutes: 9 * 60,
                endTimeMinutes: 11 * 60 + 30,
              ),
            ]
          : const [],
      courses: withData
          ? [
              UserCourse(
                id: 'course-1',
                ownerUserId: 'owner',
                termId: 'term',
                title:
                    longJapanese ? '現代日本語と大学生活に関する長い講義タイトルの表示確認テスト' : '現代日本語',
                normalizedTitle: '現代日本語',
                dayOfWeek: DateTime.monday,
                periodNo: 1,
                room:
                    longJapanese ? '総合教育研究棟・東側キャンパス三階三〇一演習室' : 'North Hall 301',
              ),
            ]
          : const [],
      assignments: withData
          ? [
              Assignment(
                id: 'due-1',
                ownerUserId: 'owner',
                title: '今日締切',
                dueAt: JapanTime.at(year: 2026, month: 8, day: 10, hour: 18),
              ),
              Assignment(
                id: 'overdue-1',
                ownerUserId: 'owner',
                title: '期限超過',
                dueAt: JapanTime.at(year: 2026, month: 8, day: 9, hour: 18),
              ),
            ]
          : const [],
      assignmentStates: const {},
      exams: withData
          ? [
              Exam(
                id: 'exam-1',
                ownerUserId: 'owner',
                title: '今日の試験',
                startAt: JapanTime.at(year: 2026, month: 8, day: 10, hour: 15),
                endAt: JapanTime.at(year: 2026, month: 8, day: 10, hour: 16),
              ),
            ]
          : const [],
      events: const [],
      eventExceptions: const [],
      calendarItems: const [],
      widgetSnapshot: WidgetSnapshot.empty(now),
      pendingMutations: const [],
      syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
    );

const _context = ActiveScheduleContext(
  ownerUserId: 'owner',
  universityId: 'university',
  termId: 'term',
  academicYear: 2026,
  primaryCalendarId: 'calendar',
);
