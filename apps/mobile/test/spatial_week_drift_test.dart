// Real in-memory Drift + Riverpod + GoRouter coverage for the read-only
// spatial week viewer. This is local integration evidence, not device E2E.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/notification/presentation/notification_target_detail_screen.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_flag.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  final now = DateTime.utc(2026, 6, 28, 15); // Monday 00:00 in Japan.

  testWidgets(
    'real Drift viewer is read-only until explicit repository event changes',
    (tester) async {
      var id = 0;
      final db = local.AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = DriftScheduleRepository(
        db,
        enableDemoData: true,
        clock: () => now,
        createId: () => 'spatial-write-${id++}',
      );
      await repository.ensureDemoDataSeeded();
      final standaloneAssignmentId = await repository.createAssignment(
        ownerUserId: demoUserId,
        input: AssignmentInput(
          title: 'Standalone spatial assignment',
          dueAt: JapanTime.at(year: 2026, month: 6, day: 30, hour: 18),
        ),
      );

      final router = _spatialRouter();
      ActiveScheduleContext? activeContext = demoScheduleContext;
      final container = _container(db, () => activeContext, now);
      addTearDown(() {
        router.dispose();
        container.dispose();
      });

      final beforeViewer = await _canonicalSnapshot(db, repository);
      await _mount(tester, router, container);
      expect(find.byType(SpatialWeekScreen), findsOneWidget);
      expect(find.text('アルゴリズムとデータ構造Ⅰ'), findsWidgets);
      expect(find.text('Standalone spatial assignment'), findsOneWidget);
      expect(find.text('サークル定例'), findsWidgets);
      expect(find.text('計算量レポート'), findsWidgets);

      await tester.ensureVisible(find.byKey(const Key('spatial-mode-depth')));
      await tester.tap(find.byKey(const Key('spatial-mode-depth')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('spatial-turn-left')));
      await tester.tap(find.byKey(const Key('spatial-turn-left')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('spatial-zoom-in')));
      await tester.tap(find.byKey(const Key('spatial-zoom-in')));
      await tester.pumpAndSettle();

      final routineTile = _entryTileFor(tester, 'event-club');
      await tester.ensureVisible(routineTile);
      await tester.tap(routineTile);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);
      expect(find.text('サークル定例'), findsWidgets);

      final openDetail = find.byKey(const Key('spatial-open-detail'));
      await tester.ensureVisible(openDetail);
      await tester.tap(openDetail);
      await tester.pumpAndSettle();
      expect(find.byType(NotificationTargetDetailScreen), findsOneWidget);
      expect(find.text('サークル定例'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SpatialWeekScreen), findsOneWidget);

      // The display, orbit, zoom, selection, destination, and return path do
      // not write canonical schedule rows or add outbox work.
      expect(await _canonicalSnapshot(db, repository), beforeViewer);

      final createdEventId = await repository.createEvent(
        ownerUserId: demoUserId,
        input: EventInput(
          title: 'Added outside viewer',
          calendarId: demoPersonalCalendarId,
          startAt: JapanTime.at(year: 2026, month: 6, day: 30, hour: 19),
          endAt: JapanTime.at(year: 2026, month: 6, day: 30, hour: 20),
          location: 'Library',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Added outside viewer'), findsWidgets);

      await repository.updateEvent(
        eventId: createdEventId,
        ownerUserId: demoUserId,
        expectedVersion: 1,
        input: EventInput(
          title: 'Modified outside viewer',
          calendarId: demoPersonalCalendarId,
          startAt: JapanTime.at(year: 2026, month: 6, day: 30, hour: 19),
          endAt: JapanTime.at(year: 2026, month: 6, day: 30, hour: 20),
          location: 'Library Annex',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Modified outside viewer'), findsWidgets);
      expect(find.text('Added outside viewer'), findsNothing);

      final modifiedTile = _entryTileFor(tester, createdEventId);
      await tester.ensureVisible(modifiedTile);
      await tester.tap(modifiedTile);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);
      expect(find.text('Modified outside viewer'), findsWidgets);

      await repository.deleteEvent(
        eventId: createdEventId,
        ownerUserId: demoUserId,
        expectedVersion: 2,
      );
      await tester.pumpAndSettle();
      expect(find.text('Modified outside viewer'), findsNothing);
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);

      final persistedEvent = await (db.select(db.events)
            ..where((row) => row.id.equals(createdEventId)))
          .getSingle();
      expect(persistedEvent.deletedAt, isNotNull);
      expect(persistedEvent.title, 'Modified outside viewer');
      final persistedAssignment = await (db.select(db.assignments)
            ..where((row) => row.id.equals(standaloneAssignmentId)))
          .getSingle();
      expect(persistedAssignment.courseId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'context changes and null auth clear a selected row despite retained old AsyncData',
    (tester) async {
      final db = local.AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = DriftScheduleRepository(
        db,
        enableDemoData: true,
        clock: () => now,
      );
      await repository.ensureDemoDataSeeded();
      ActiveScheduleContext? activeContext = demoScheduleContext;
      final router = _spatialRouter();
      final container = _container(db, () => activeContext, now);
      addTearDown(() {
        router.dispose();
        container.dispose();
      });

      await _mount(tester, router, container);
      final oldCourseTitle = 'アルゴリズムとデータ構造Ⅰ';
      expect(find.text(oldCourseTitle), findsWidgets);
      final courseTile = _entryTileFor(tester, 'course-algo');
      await tester.ensureVisible(courseTile);
      await tester.tap(courseTile);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);

      final maliciousOldState =
          container.read(demoAppControllerProvider).valueOrNull!;
      activeContext = const ActiveScheduleContext(
        ownerUserId: 'different-owner',
        universityId: demoUniversityId,
        termId: demoTermId,
        academicYear: 2026,
        primaryCalendarId: demoPersonalCalendarId,
      );
      container.invalidate(activeScheduleContextProvider);
      // Retain a deliberately stale AsyncData snapshot across the selector
      // change. The new context projection must still fence the old owner.
      container.read(demoAppControllerProvider.notifier).state =
          AsyncData(maliciousOldState);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(oldCourseTitle), findsNothing);
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);
      expect(find.byKey(const Key('spatial-open-detail')), findsNothing);

      activeContext = demoScheduleContext;
      container.invalidate(activeScheduleContextProvider);
      await tester.pumpAndSettle();
      expect(find.text(oldCourseTitle), findsWidgets);
      final reselection = _entryTileFor(tester, 'course-algo');
      await tester.ensureVisible(reselection);
      await tester.tap(reselection);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial-selected-detail')), findsOneWidget);

      activeContext = null;
      container.invalidate(activeScheduleContextProvider);
      await tester.pump();
      // The auth-transition state intentionally owns an indeterminate
      // progress indicator, so settle the rebuild with a bounded pump.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(oldCourseTitle), findsNothing);
      expect(find.byKey(const Key('spatial-selected-detail')), findsNothing);
      expect(find.byKey(const Key('spatial-open-detail')), findsNothing);
      expect(find.bySemanticsLabel('認証状態を確認中'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

ProviderContainer _container(
  local.AppDatabase db,
  ActiveScheduleContext? Function() readContext,
  DateTime now,
) =>
    ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeScheduleContextProvider.overrideWith((ref) => readContext()),
        demoScheduleDataEnabledProvider.overrideWithValue(true),
        spatialWeekEnabledProvider.overrideWithValue(true),
        appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
        appClockProvider.overrideWithValue(_FixedClock(now)),
      ],
    );

GoRouter _spatialRouter() => GoRouter(
      initialLocation: '/spatial-week',
      routes: [
        GoRoute(
          path: '/spatial-week',
          builder: (_, __) => const SpatialWeekScreen(),
        ),
        GoRoute(
          path: '/event/:id',
          builder: (_, state) => NotificationTargetDetailScreen(
            kind: 'event',
            id: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/routine/:id',
          builder: (_, state) => NotificationTargetDetailScreen(
            kind: 'routine',
            id: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (_, state) => Scaffold(
            body: Text('Course ${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/assignment/:id',
          builder: (_, state) => Scaffold(
            body: Text('Assignment ${state.pathParameters['id']}'),
          ),
        ),
      ],
    );

Future<void> _mount(
  WidgetTester tester,
  GoRouter router,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _entryTileFor(WidgetTester tester, String sourceId) =>
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('spatial-entry-') &&
          key.value.contains(sourceId);
    });

Future<Map<String, List<String>>> _canonicalSnapshot(
  local.AppDatabase db,
  DriftScheduleRepository repository,
) async {
  final mutations = await repository.pendingMutations(ownerUserId: demoUserId);
  return {
    'periodSettings': (await db.select(db.periodSettings).get())
        .map((row) => row.toString())
        .toList()
      ..sort(),
    'courses': (await db.select(db.userCourses).get())
        .map((row) => row.toString())
        .toList()
      ..sort(),
    'assignments': (await db.select(db.assignments).get())
        .map((row) => row.toString())
        .toList()
      ..sort(),
    'assignmentStates': (await db.select(db.assignmentUserStates).get())
        .map((row) => row.toString())
        .toList()
      ..sort(),
    'exams':
        (await db.select(db.exams).get()).map((row) => row.toString()).toList()
          ..sort(),
    'events':
        (await db.select(db.events).get()).map((row) => row.toString()).toList()
          ..sort(),
    'eventExceptions': (await db.select(db.eventExceptions).get())
        .map((row) => row.toString())
        .toList()
      ..sort(),
    'pendingMutations': mutations
        .map((mutation) => [
              mutation.clientMutationId,
              mutation.ownerUserId,
              mutation.entityType,
              mutation.entityId,
              mutation.operation.name,
              mutation.payload.toString(),
              mutation.createdAt.toIso8601String(),
              mutation.baseVersion?.toString() ?? '',
              mutation.status.name,
            ].join('|'))
        .toList()
      ..sort(),
  };
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
