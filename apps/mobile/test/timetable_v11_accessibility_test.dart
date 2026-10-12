import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/timetable_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

final _testActiveScheduleContextProvider =
    StateProvider<ActiveScheduleContext?>((ref) => demoScheduleContext);

const _otherScheduleContext = ActiveScheduleContext(
  ownerUserId: 'other-user',
  universityId: 'other-university',
  termId: 'other-term',
  academicYear: 2027,
  primaryCalendarId: 'other-calendar',
);

void main() {
  const title = '日本近代文学と地域文化を横断する長い講義タイトルの表示確認';
  const room = '総合教育研究棟・東側キャンパス三階三〇一演習室';
  final now = DateTime.utc(2026, 8, 10, 1); // Monday 10:00 JST.

  testWidgets(
      'course selection sheet restores long Japanese summary and routes',
      (tester) async {
    for (final size in const [
      Size(360, 800),
      Size(412, 915),
      Size(1024, 1000)
    ]) {
      await tester.binding.setSurfaceSize(size);
      final db = local.AppDatabase(NativeDatabase.memory());
      final router = _router();
      final keyboardInset = size.width == 360 ? 280.0 : 0.0;

      await _pumpTimetable(
        tester,
        db,
        router: router,
        now: now,
        mediaSize: size,
        textScale: 2,
        dark: size.width >= 840,
        reducedMotion: true,
        keyboardInset: keyboardInset,
        state: _state(now, title: title, room: room, withRelatedItems: true),
      );

      final cell = find.byKey(const ValueKey('course-cell-course-1'));
      await tester.ensureVisible(cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('course-selection-title')), findsOneWidget);
      expect(
          tester
              .widget<Text>(find.byKey(const Key('course-selection-title')))
              .data,
          title);
      final selectedRoom = find.descendant(
        of: find.byKey(const Key('course-selection-room')),
        matching: find.text(room),
      );
      expect(selectedRoom, findsOneWidget);
      expect(tester.widget<Text>(selectedRoom).data, room);
      expect(find.text('月曜日・1限'), findsOneWidget);
      expect(find.text('10:00 – 11:30'), findsOneWidget);
      expect(find.text('課題 1件'), findsOneWidget);
      expect(find.text('試験 1件'), findsOneWidget);
      final detailAction = find.byKey(const Key('course-selection-detail'));
      expect(detailAction, findsOneWidget);
      await tester.ensureVisible(detailAction);
      if (keyboardInset > 0) {
        expect(
          tester.getRect(detailAction).bottom,
          lessThanOrEqualTo(size.height - keyboardInset),
        );
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('course-selection-detail')));
      await tester.pumpAndSettle();
      expect(find.text('/course/course-1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await db.close();
      router.dispose();
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('narrow day layout names the time-details fallback',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(280, 800),
      textScale: 2,
      state: _state(now, title: title, room: room),
    );
    expect(
        find.byKey(const Key('timetable-day-time-fallback')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('course detail does not invent times when its slot is unset',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      state: _state(
        now,
        title: title,
        room: room,
        withPeriodSetting: false,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('course-cell-course-1')));
    await tester.pumpAndSettle();

    expect(find.text('月曜日・1限'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('course-selection-time')),
        matching: find.text('時刻未設定'),
      ),
      findsOneWidget,
    );
    expect(find.text('09:00 – 10:30'), findsNothing);
    expect(find.textContaining('09:00'), findsNothing);
    final periodLabel = find.byKey(
      const ValueKey('timetable-period-label-1-day'),
    );
    expect(periodLabel, findsOneWidget);
    expect(tester.widget<Semantics>(periodLabel).properties.label, '1限 時刻未設定');
    expect(tester.takeException(), isNull);
  });

  testWidgets('week period time appears only when all weekdays agree',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(412, 900),
      state: _state(
        now,
        title: title,
        room: room,
        periodSettings: _weekdaySettings(
          (weekday) => _periodSettingFor(weekday, 10 * 60, 11 * 60 + 30),
        ),
      ),
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    final periodLabel = find.byKey(
      const ValueKey('timetable-period-label-1-week'),
    );
    expect(tester.widget<Semantics>(periodLabel).properties.label,
        '1限 10:00から11:30');
    expect(
      find.descendant(of: periodLabel, matching: find.text('10:00\n11:30')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('week period reports unset only when every weekday is unset',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(412, 900),
      state: _state(
        now,
        title: title,
        room: room,
        periodSettings: const [],
      ),
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    final periodLabel = find.byKey(
      const ValueKey('timetable-period-label-1-week'),
    );
    expect(tester.widget<Semantics>(periodLabel).properties.label, '1限 時刻未設定');
    expect(
      find.descendant(of: periodLabel, matching: find.text('時刻未設定')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mixed week times stay neutral and course details stay weekday-specific',
      (tester) async {
    for (final textScale in [1.0, 2.0]) {
      for (final settings in [
        _weekdaySettings(
          (weekday) => _periodSettingFor(
            weekday,
            weekday == DateTime.tuesday ? 9 * 60 : 10 * 60,
            weekday == DateTime.tuesday ? 10 * 60 + 30 : 11 * 60 + 30,
          ),
        ),
        _weekdaySettings(
          (weekday) => weekday == DateTime.wednesday
              ? null
              : _periodSettingFor(weekday, 10 * 60, 11 * 60 + 30),
        ),
      ]) {
        await tester.binding.setSurfaceSize(const Size(412, 900));
        final db = local.AppDatabase(NativeDatabase.memory());
        final router = _router();

        await _pumpTimetable(
          tester,
          db,
          router: router,
          now: now,
          mediaSize: const Size(412, 900),
          textScale: textScale,
          state: _state(
            now,
            title: title,
            room: room,
            periodSettings: settings,
          ),
        );
        await tester.tap(find.text('週全体'));
        await tester.pumpAndSettle();

        final periodLabel = find.byKey(
          const ValueKey('timetable-period-label-1-week'),
        );
        expect(tester.widget<Semantics>(periodLabel).properties.label,
            '1限 時刻は授業詳細');
        expect(
          find.descendant(of: periodLabel, matching: find.text('10:00\n11:30')),
          findsNothing,
        );
        expect(
          find.descendant(of: periodLabel, matching: find.text('09:00\n10:30')),
          findsNothing,
        );
        if (textScale == 1.0) {
          expect(
            find.descendant(of: periodLabel, matching: find.text('詳細')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byKey(const Key('timetable-week-time-fallback')),
            findsOneWidget,
          );
        }

        final mondayCell = find.byKey(
          const ValueKey('week-course-cell-course-1'),
        );
        await tester.ensureVisible(mondayCell);
        await tester.tap(mondayCell);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('course-selection-time')),
            matching: find.text('10:00 – 11:30'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await db.close();
        router.dispose();
      }
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('week selection and management sheets have separate actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      state: _state(now, title: title, room: room, withRelatedItems: true),
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-week-time-fallback')), findsNothing);

    await tester
        .ensureVisible(find.byKey(const ValueKey('week-course-cell-course-1')));
    await tester.tap(find.byKey(const ValueKey('week-course-cell-course-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-selection-title')), findsOneWidget);
    expect(find.text(title), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('course-selection-room')),
        matching: find.text(room),
      ),
      findsOneWidget,
    );
    expect(find.text('月曜日・1限'), findsOneWidget);
    expect(find.text('課題 1件'), findsOneWidget);
    expect(find.text('試験 1件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('course-selection-detail')));
    await tester.pumpAndSettle();
    expect(find.text('/course/course-1'), findsOneWidget);

    router.go('/timetable');
    await tester.pumpAndSettle();
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    final menu = find.byTooltip('$titleの操作');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-actions-title')), findsOneWidget);
    expect(find.byKey(const Key('course-actions-room')), findsOneWidget);
    expect(
      find.byKey(const Key('course-actions-schedule')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('course-actions-title'))).data,
      title,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('course-actions-room'))).data,
      room,
    );
    expect(find.text('課題 1件'), findsOneWidget);
    expect(find.text('試験 1件'), findsOneWidget);
    expect(find.text('詳細を見る'), findsOneWidget);
    expect(find.text('編集'), findsOneWidget);
    expect(find.text('削除'), findsOneWidget);
  });

  testWidgets('day, week, weekday, and compact menu targets meet 48dp',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      state: _state(now, title: '短い講義', room: 'A棟 101'),
    );
    expect(
      tester.getSize(find.byKey(const Key('timetable-view-control'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('timetable-day-1'))).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    final menu = find.byTooltip('短い講義の操作');
    await tester.ensureVisible(menu);
    expect(tester.getSize(menu).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% week labels fall back explicitly without horizontal scroll',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      textScale: 2,
      reducedMotion: true,
      state: _state(now, title: title, room: room),
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('timetable-week-time-fallback')), findsOneWidget);
    expect(find.text('空き'), findsNothing);
    final horizontalScrollables = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .where((widget) =>
            widget.axisDirection == AxisDirection.left ||
            widget.axisDirection == AxisDirection.right);
    expect(horizontalScrollables, isEmpty);
    expect(
      tester.getSize(find.byTooltip('$titleの操作')).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape large text remains scrollable with reduced motion',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(800, 360),
      textScale: 2,
      dark: true,
      reducedMotion: true,
      state: _state(now, title: title, room: room),
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('timetable-week-view')), findsOneWidget);
    expect(
        find.byKey(const Key('timetable-week-time-fallback')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'selection sheet hides and ignores detail after auth becomes null',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      textScale: 2,
      keyboardInset: 280,
      state: _state(now, title: title, room: room),
    );
    await tester.tap(find.byKey(const ValueKey('course-cell-course-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-selection-title')), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TimetableScreen)),
    );
    final detailAction = find.byKey(const Key('course-selection-detail'));
    await tester.ensureVisible(detailAction);
    container.read(_testActiveScheduleContextProvider.notifier).state = null;
    await tester.tap(detailAction);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('timetable-auth-transition')), findsOneWidget);
    expect(find.byKey(const Key('course-selection-title')), findsNothing);
    expect(find.byKey(const Key('course-selection-detail')), findsNothing);
    expect(find.text('/course/course-1'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/timetable');
    expect(tester.takeException(), isNull);
  });

  testWidgets('management sheet hides and ignores delete after owner changes',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router();
    addTearDown(router.dispose);

    await _pumpTimetable(
      tester,
      db,
      router: router,
      now: now,
      mediaSize: const Size(360, 800),
      textScale: 2,
      keyboardInset: 280,
      state: _state(now, title: title, room: room),
    );
    final courseMenu = find.byTooltip('$titleの操作');
    await tester.ensureVisible(courseMenu);
    await tester.tap(courseMenu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('course-actions-title')), findsOneWidget);
    final deleteAction = find.text('削除');
    await tester.drag(
      find.byKey(const Key('course-actions-scroll')),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    expect(deleteAction, findsOneWidget);
    await tester.ensureVisible(deleteAction);
    expect(
      tester.getRect(deleteAction).bottom,
      lessThanOrEqualTo(800 - 280),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(TimetableScreen)),
    );
    container.read(_testActiveScheduleContextProvider.notifier).state =
        _otherScheduleContext;
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('course-actions-title')), findsNothing);
    expect(find.text('授業を削除しますか？'), findsNothing);
    expect(find.text('/course/course-1/edit'), findsNothing);
    expect(find.text('/course/course-1'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/timetable');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpTimetable(
  WidgetTester tester,
  local.AppDatabase db, {
  required GoRouter router,
  required DateTime now,
  required DemoAppState state,
  required Size mediaSize,
  double textScale = 1,
  bool dark = false,
  bool reducedMotion = false,
  double keyboardInset = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeScheduleContextProvider.overrideWith(
          (ref) => ref.watch(_testActiveScheduleContextProvider),
        ),
        demoScheduleDataEnabledProvider.overrideWithValue(true),
        appClockProvider.overrideWithValue(_FixedClock(now)),
        demoAppControllerProvider.overrideWith(() => _FixedController(state)),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: mediaSize,
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

GoRouter _router() => GoRouter(
      initialLocation: '/timetable',
      routes: [
        GoRoute(
          path: '/timetable',
          builder: (_, __) => const TimetableScreen(),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (context, state) => Scaffold(
            body: Center(child: Text(state.uri.path)),
          ),
        ),
        GoRoute(
          path: '/course/:id/edit',
          builder: (context, state) => Scaffold(
            body: Center(child: Text(state.uri.path)),
          ),
        ),
        GoRoute(
          path: '/courses/search',
          builder: (context, state) => Scaffold(
            body: Center(child: Text(state.uri.toString())),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('settings')),
        ),
      ],
    );

DemoAppState _state(
  DateTime now, {
  required String title,
  required String room,
  bool withRelatedItems = false,
  bool withPeriodSetting = true,
  List<PeriodSetting>? periodSettings,
}) {
  final course = UserCourse(
    id: 'course-1',
    ownerUserId: demoScheduleContext.ownerUserId,
    termId: demoScheduleContext.termId,
    title: title,
    normalizedTitle: title,
    dayOfWeek: DateTime.monday,
    periodNo: 1,
    room: room,
  );
  return DemoAppState.empty(now: now).copyWith(
    periodSettings: periodSettings ??
        (withPeriodSetting
            ? const [
                PeriodSetting(
                  id: 'period-1',
                  ownerUserId: 'demo-user',
                  dayOfWeek: DateTime.monday,
                  periodNo: 1,
                  startTimeMinutes: 10 * 60,
                  endTimeMinutes: 11 * 60 + 30,
                ),
              ]
            : const []),
    courses: [course],
    assignments: withRelatedItems
        ? [
            Assignment(
              id: 'assignment-1',
              ownerUserId: demoScheduleContext.ownerUserId,
              title: 'レポート',
              dueAt: DateTime.utc(2026, 8, 14),
              courseId: course.id,
            ),
          ]
        : const [],
    exams: withRelatedItems
        ? [
            Exam(
              id: 'exam-1',
              ownerUserId: demoScheduleContext.ownerUserId,
              title: '小テスト',
              startAt: DateTime.utc(2026, 8, 14, 1),
              endAt: DateTime.utc(2026, 8, 14, 2),
              courseId: course.id,
            ),
          ]
        : const [],
  );
}

List<PeriodSetting> _weekdaySettings(
  PeriodSetting? Function(int weekday) create,
) {
  final settings = <PeriodSetting>[];
  for (final weekday in const [
    DateTime.monday,
    DateTime.tuesday,
    DateTime.wednesday,
    DateTime.thursday,
    DateTime.friday,
  ]) {
    final setting = create(weekday);
    if (setting != null) settings.add(setting);
  }
  return settings;
}

PeriodSetting _periodSettingFor(int weekday, int start, int end) =>
    PeriodSetting(
      id: 'period-$weekday',
      ownerUserId: 'demo-user',
      dayOfWeek: weekday,
      periodNo: 1,
      startTimeMinutes: start,
      endTimeMinutes: end,
    );

class _FixedController extends DemoAppController {
  _FixedController(this.value);

  final DemoAppState value;

  @override
  Stream<DemoAppState> build() => Stream.value(value);
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
