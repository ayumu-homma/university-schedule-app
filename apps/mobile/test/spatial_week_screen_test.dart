import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_flag.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_canvas.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  group('SpatialWeekScreen', () {
    testWidgets(
        'shows full list details and preserves selection after detail back',
        (tester) async {
      final stream = StreamController<DemoAppState>.broadcast();
      addTearDown(stream.close);
      final container = ProviderContainer(
        overrides: [
          _testContextProvider.overrideWith(_TestContextNotifier.new),
          activeScheduleContextProvider.overrideWith(
            (ref) => ref.watch(_testContextProvider),
          ),
          spatialWeekEnabledProvider.overrideWithValue(true),
          appClockProvider.overrideWithValue(_FixedClock(_now)),
          demoAppControllerProvider.overrideWith(
            () => _StreamingDemoAppController(stream.stream),
          ),
        ],
      );
      addTearDown(container.dispose);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      stream.add(_state(_context, title: '研究会の予定'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('spatial-week-canvas')), findsOneWidget);
      expect(
          find.byKey(const Key(
              'spatial-entry-event:meeting:2026-05-04T00:00:00.000Z:2026-05-04T01:00:00.000Z')),
          findsOneWidget);
      await tester.ensureVisible(find.text('研究会の予定').first);
      await tester.tap(find.text('研究会の予定').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);
      expect(find.text('場所: 研究棟 2階'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('spatial-open-detail')));
      await tester.tap(find.byKey(const Key('spatial-open-detail')));
      await tester.pumpAndSettle();
      expect(find.text('詳細 route: meeting'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const Key('spatial-clear-selection')));
      await tester.tap(find.byKey(const Key('spatial-clear-selection')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);
    });

    testWidgets(
        'removed entries clear selection and obsolete callbacks are ignored',
        (tester) async {
      final stream = StreamController<DemoAppState>.broadcast();
      addTearDown(stream.close);
      final container = _container(stream.stream);
      addTearDown(container.dispose);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      stream.add(_state(_context, title: '一度だけの予定'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('一度だけの予定').first);
      await tester.tap(find.text('一度だけの予定').first);
      await tester.pumpAndSettle();
      final staleOpen = tester
          .widget<OutlinedButton>(find.byKey(const Key('spatial-open-detail')))
          .onPressed!;

      stream.add(DemoAppState.empty(now: _now));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);
      staleOpen();
      await tester.pumpAndSettle();
      expect(find.text('詳細 route: meeting'), findsNothing);
    });

    testWidgets('entry and detail semantics actions select and push once',
        (tester) async {
      final stream = StreamController<DemoAppState>.broadcast();
      addTearDown(stream.close);
      final container = _container(stream.stream);
      addTearDown(container.dispose);
      final observer = _DetailPushObserver();
      final router = _router(observer: observer);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      stream.add(_state(_context, title: '共有しない研究会'));
      await tester.pumpAndSettle();

      final semanticsHandle = tester.ensureSemantics();
      try {
        await tester.ensureVisible(find.text('共有しない研究会'));
        await tester.pumpAndSettle();
        final entryFinder = find.semantics.byLabel(
          '予定、配置済み、共有しない研究会、5/4 09:00–10:00、場所: 研究棟 2階',
        );
        expect(entryFinder, findsOneWidget);
        final entryNode = entryFinder.evaluate().single;
        final entryData = entryNode.getSemanticsData();
        expect(entryData.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(entryData.label, contains('予定'));
        expect(entryData.label, contains('配置済み'));
        expect(entryData.label, contains('共有しない研究会'));
        expect(entryData.label, contains('5/4 09:00–10:00'));
        expect(entryData.label, contains('場所: 研究棟 2階'));

        entryNode.owner!.performAction(
          entryNode.id,
          ui.SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
        expect(
            find.byKey(const Key('spatial-selected-detail')), findsOneWidget);

        await tester
            .ensureVisible(find.byKey(const Key('spatial-open-detail')));
        await tester.pumpAndSettle();
        final detailFinder = find.semantics.byLabel('詳細を開く');
        expect(detailFinder, findsOneWidget);
        final detailNode = detailFinder.evaluate().single;
        expect(detailNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            isTrue);
        detailNode.owner!.performAction(
          detailNode.id,
          ui.SemanticsAction.tap,
        );
        await tester.pumpAndSettle();
      } finally {
        semanticsHandle.dispose();
      }

      expect(find.text('詳細 route: meeting'), findsOneWidget);
      expect(observer.detailPushes, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'all-day list states show single-day and inclusive multi-day ranges',
        (tester) async {
      final stream = StreamController<DemoAppState>.broadcast();
      addTearDown(stream.close);
      final container = _container(stream.stream);
      addTearDown(container.dispose);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      stream.add(DemoAppState.empty(now: _now).copyWith(
        events: [
          ScheduleEvent(
            id: 'single-day',
            ownerUserId: _context.ownerUserId,
            calendarId: _context.primaryCalendarId,
            title: '祝日',
            kind: EventKind.normal,
            startAt: JapanTime.at(year: 2026, month: 5, day: 5),
            endAt: JapanTime.at(year: 2026, month: 5, day: 6),
            isAllDay: true,
          ),
          ScheduleEvent(
            id: 'multi-day',
            ownerUserId: _context.ownerUserId,
            calendarId: _context.primaryCalendarId,
            title: '学園祭',
            kind: EventKind.normal,
            startAt: JapanTime.at(year: 2026, month: 5, day: 6),
            endAt: JapanTime.at(year: 2026, month: 5, day: 9),
            isAllDay: true,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('終日 · 5/5'), findsOneWidget);
      expect(find.textContaining('終日 · 5/6–5/8'), findsOneWidget);
      expect(find.textContaining('5/9'), findsNothing);
    });

    testWidgets('full context changes reset camera and selection',
        (tester) async {
      final stream = StreamController<DemoAppState>.broadcast();
      addTearDown(stream.close);
      final container = _container(stream.stream);
      addTearDown(container.dispose);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      stream.add(_state(_context, title: '元の学期の予定'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('元の学期の予定').first);
      await tester.tap(find.text('元の学期の予定').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);
      final staleOpen = tester
          .widget<OutlinedButton>(find.byKey(const Key('spatial-open-detail')))
          .onPressed!;

      container.read(_testContextProvider.notifier).state = _otherContext;
      await tester.pumpAndSettle();
      stream.add(_state(_otherContext, title: '新しい学期の予定'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);
      expect(find.text('新しい学期の予定'), findsOneWidget);
      staleOpen();
      await tester.pumpAndSettle();
      expect(find.text('詳細 route: meeting'), findsNothing);
    });

    testWidgets(
        'wraps controls at 360dp with 200 percent text and exposes labels',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = _container(Stream.value(DemoAppState.empty(now: _now)));
      addTearDown(container.dispose);
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: MaterialApp.router(routerConfig: router),
        ),
      ));
      await tester.pumpAndSettle();

      final semantics = tester.ensureSemantics();
      try {
        expect(find.byKey(const Key('spatial-turn-left')), findsOneWidget);
        expect(find.byKey(const Key('spatial-turn-right')), findsOneWidget);
        expect(find.byKey(const Key('spatial-tilt-up')), findsOneWidget);
        expect(find.byKey(const Key('spatial-tilt-down')), findsOneWidget);
        expect(find.byKey(const Key('spatial-zoom-in')), findsOneWidget);
        expect(find.byKey(const Key('spatial-reset')), findsOneWidget);
        expect(
            tester.getSize(find.byKey(const Key('spatial-turn-left'))).height,
            greaterThanOrEqualTo(48));
        expect(find.byTooltip('左に回転'), findsOneWidget);
        expect(find.byTooltip('視点をリセット'), findsOneWidget);
      } finally {
        semantics.dispose();
      }

      final canvasFinder = find.byKey(const Key('spatial-week-canvas'));
      final yawBefore =
          tester.widget<SpatialWeekCanvas>(canvasFinder).camera.yaw;
      final turnIconFinder = find
          .descendant(
            of: find.byKey(const Key('spatial-turn-left')),
            matching: find.byIcon(Icons.rotate_left),
          )
          .first;
      Focus.of(tester.element(turnIconFinder)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<SpatialWeekCanvas>(canvasFinder).camera.yaw,
          isNot(yawBefore));

      await tester.tap(find.byKey(const Key('spatial-list-only')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-week-canvas')), findsNothing);
      expect(find.byKey(const Key('spatial-turn-left')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '2D, spatial and list views fit 412dp and tablet landscape with reduced motion',
        (tester) async {
      final cases = [
        (const Size(412, 850), Brightness.light, const TextScaler.linear(2)),
        (const Size(1100, 700), Brightness.dark, const TextScaler.linear(1)),
      ];
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final (size, brightness, textScaler) in cases) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final container =
            _container(Stream.value(DemoAppState.empty(now: _now)));
        final router = _router();
        addTearDown(container.dispose);
        addTearDown(router.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: textScaler,
                disableAnimations: true,
              ),
              child: child!,
            ),
          ),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('spatial-mode-depth')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(const Key('spatial-mode-depth')))
              .selected,
          isTrue,
        );
        await tester.tap(find.byKey(const Key('spatial-list-only')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('spatial-week-canvas')), findsNothing);
        await tester.tap(find.byKey(const Key('spatial-list-only')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('spatial-week-canvas')), findsOneWidget);
        expect(
          tester
              .widget<ChoiceChip>(find.byKey(const Key('spatial-mode-depth')))
              .selected,
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'disabled flag screen does not subscribe to schedule controller',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/spatial-week',
        routes: [
          GoRoute(
            path: '/spatial-week',
            builder: (context, state) => const SpatialWeekScreen(),
          ),
          GoRoute(
            path: '/timetable',
            builder: (context, state) => const Scaffold(body: Text('通常の時間割')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          spatialWeekEnabledProvider.overrideWithValue(false),
          demoAppControllerProvider.overrideWith(
            _ThrowingDemoAppController.new,
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      expect(find.text('この実験ビューは現在利用できません。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('spatial-disabled-return')));
      await tester.pumpAndSettle();
      expect(find.text('通常の時間割'), findsOneWidget);
    });
  });
}

final _testContextProvider =
    NotifierProvider<_TestContextNotifier, ActiveScheduleContext?>(
  _TestContextNotifier.new,
);

class _TestContextNotifier extends Notifier<ActiveScheduleContext?> {
  @override
  ActiveScheduleContext? build() => _context;
}

ProviderContainer _container(Stream<DemoAppState> stream) => ProviderContainer(
      overrides: [
        _testContextProvider.overrideWith(_TestContextNotifier.new),
        activeScheduleContextProvider.overrideWith(
          (ref) => ref.watch(_testContextProvider),
        ),
        spatialWeekEnabledProvider.overrideWithValue(true),
        appClockProvider.overrideWithValue(_FixedClock(_now)),
        demoAppControllerProvider.overrideWith(
          () => _StreamingDemoAppController(stream),
        ),
      ],
    );

GoRouter _router({NavigatorObserver? observer}) => GoRouter(
      initialLocation: '/spatial-week',
      observers: observer == null ? const [] : [observer],
      routes: [
        GoRoute(
          path: '/spatial-week',
          builder: (context, state) => const SpatialWeekScreen(),
        ),
        GoRoute(
          path: '/event/:id',
          name: 'event-detail',
          builder: (context, state) => Scaffold(
            body:
                Center(child: Text('詳細 route: ${state.pathParameters['id']}')),
          ),
        ),
      ],
    );

class _DetailPushObserver extends NavigatorObserver {
  int detailPushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == 'event-detail') detailPushes++;
    super.didPush(route, previousRoute);
  }
}

class _StreamingDemoAppController extends DemoAppController {
  _StreamingDemoAppController(this.stream);

  final Stream<DemoAppState> stream;

  @override
  Stream<DemoAppState> build() => stream;
}

class _ThrowingDemoAppController extends DemoAppController {
  @override
  Stream<DemoAppState> build() => throw StateError('should not subscribe');
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

const _context = ActiveScheduleContext(
  ownerUserId: 'spatial-owner',
  universityId: 'spatial-university',
  termId: 'spatial-term',
  academicYear: 2026,
  primaryCalendarId: 'spatial-calendar',
);

const _otherContext = ActiveScheduleContext(
  ownerUserId: 'spatial-owner',
  universityId: 'spatial-university',
  termId: 'another-term',
  academicYear: 2026,
  primaryCalendarId: 'spatial-calendar',
);

final _now = JapanTime.at(year: 2026, month: 5, day: 4, hour: 8);

DemoAppState _state(ActiveScheduleContext context, {required String title}) =>
    DemoAppState.empty(now: _now).copyWith(
      events: [
        ScheduleEvent(
          id: 'meeting',
          ownerUserId: context.ownerUserId,
          calendarId: context.primaryCalendarId,
          title: title,
          kind: EventKind.normal,
          startAt: JapanTime.at(year: 2026, month: 5, day: 4, hour: 9),
          endAt: JapanTime.at(year: 2026, month: 5, day: 4, hour: 10),
          location: '研究棟 2階',
        ),
      ],
    );
