// Local widget integration coverage. This exercises real Riverpod controllers,
// routes, and the Drift repository with synthetic demo rows in memory; it is
// not hosted-auth, device, or end-to-end acceptance evidence.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_list_screen.dart';
import 'package:university_schedule_mobile/features/course_template/presentation/course_detail_screen.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_list_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/home_screen.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/timetable_screen.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_screen.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  testWidgets(
    'local journey keeps Today, timetable, course, assignment Undo, exam, and Drift state connected',
    (tester) async {
      final now = DateTime.utc(2026, 6, 28, 23); // Monday 08:00 in Japan.
      final db = local.AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = DriftScheduleRepository(
        db,
        enableDemoData: true,
        clock: () => now,
      );
      await repository.ensureDemoDataSeeded();

      final router = _journeyRouter();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
          demoScheduleDataEnabledProvider.overrideWithValue(true),
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          appClockProvider.overrideWithValue(_FixedClock(now)),
          todayTimeProvider.overrideWith((ref) => Stream.value(now)),
        ],
      );
      addTearDown(() {
        router.dispose();
        container.dispose();
      });

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

      // Home -> Today uses the visible overview action.
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byKey(const Key('open-today-briefing')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-today-briefing')));
      await tester.pumpAndSettle();
      expect(find.byType(TodayScreen), findsOneWidget);
      final focusCourse = find.byKey(const Key('today-focus-course'));
      expect(focusCourse, findsOneWidget);
      expect(find.text('締切 0件'), findsOneWidget);
      expect(
        find.descendant(
            of: focusCourse, matching: find.textContaining('10:40')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: focusCourse, matching: find.textContaining('A101')),
        findsOneWidget,
      );

      // Today -> timetable through its existing bottom navigation; verify both
      // day and week controls, then open the course's actual detail route.
      await tester.tap(find.text('時間割').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-day-view')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('timetable-day-1')),
          findsOneWidget);
      await tester.tap(find.text('週全体'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-week-view')), findsOneWidget);
      await tester.tap(find.byTooltip('アルゴリズムとデータ構造Ⅰの操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('詳細を見る'));
      await tester.pumpAndSettle();
      expect(find.byType(CourseDetailScreen), findsOneWidget);
      expect(find.text('計算量レポート'), findsOneWidget);
      expect(find.text('中間テスト'), findsOneWidget);

      // The workload route is reached through the app navigation. Submitting
      // and Undoing must affect the same Drift rows observed by the UI.
      await tester.tap(find.text('課題・テスト').last);
      await tester.pumpAndSettle();
      expect(find.byType(AssignmentListScreen), findsOneWidget);
      final before = await repository.pendingMutations(
        ownerUserId: demoUserId,
      );
      final submitButton = find.widgetWithText(
        OutlinedButton,
        '提出済みを記録',
      );
      await tester.scrollUntilVisible(
        submitButton,
        300,
        scrollable: _assignmentScrollable(),
      );
      await tester.ensureVisible(submitButton);
      await tester.pumpAndSettle();
      final submitRect = tester.getRect(submitButton);
      final assignmentViewportRect = tester.getRect(_assignmentViewport());
      expect(submitRect.top, greaterThanOrEqualTo(assignmentViewportRect.top));
      expect(
        submitRect.bottom,
        lessThanOrEqualTo(assignmentViewportRect.bottom),
      );
      expect(submitButton.hitTestable(), findsOneWidget);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();
      expect(find.text('元に戻す'), findsOneWidget);
      var states = await repository.assignmentStatesForUser(demoUserId);
      expect(states['assignment-report-1']?.status, AssignmentStatus.submitted);
      var mutations = await repository.pendingMutations(
        ownerUserId: demoUserId,
      );
      expect(mutations.length, greaterThan(before.length));
      expect(mutations.last.entityId, 'assignment-report-1');
      expect(mutations.last.operation, SyncOperation.submit);

      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();
      states = await repository.assignmentStatesForUser(demoUserId);
      expect(
          states['assignment-report-1']?.status, AssignmentStatus.notStarted);
      mutations = await repository.pendingMutations(ownerUserId: demoUserId);
      expect(mutations.last.entityId, 'assignment-report-1');
      expect(mutations.last.operation, SyncOperation.update);
      expect(mutations.last.payload['status'], 'notStarted');
      expect(mutations.last.baseVersion, greaterThan(0));

      // Switch to exams, verify its seeded record, then return to assignments
      // and Home using visible existing controls.
      await tester.scrollUntilVisible(
        find.byKey(const Key('academic-mode-exams')),
        -250,
        scrollable: _assignmentScrollable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('academic-mode-exams')));
      await tester.pumpAndSettle();
      expect(find.byType(ExamListScreen), findsOneWidget);
      expect(find.text('中間テスト'), findsOneWidget);
      await tester.tap(find.byKey(const Key('academic-mode-assignments')));
      await tester.pumpAndSettle();
      expect(find.byType(AssignmentListScreen), findsOneWidget);
      await tester.tap(find.text('ホーム').last);
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing the active owner while a timetable course sheet is open removes its content',
    (tester) async {
      final now = DateTime.utc(2026, 6, 28, 23);
      final db = local.AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = DriftScheduleRepository(
        db,
        enableDemoData: true,
        clock: () => now,
      );
      await repository.ensureDemoDataSeeded();
      ActiveScheduleContext? activeContext = demoScheduleContext;
      final router = _journeyRouter();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeScheduleContextProvider.overrideWith((ref) => activeContext),
          demoScheduleDataEnabledProvider.overrideWithValue(true),
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          appClockProvider.overrideWithValue(_FixedClock(now)),
          todayTimeProvider.overrideWith((ref) => Stream.value(now)),
        ],
      );
      addTearDown(() {
        router.dispose();
        container.dispose();
      });

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
      await tester.tap(find.text('時間割').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('アルゴリズムとデータ構造Ⅰの操作'));
      await tester.pumpAndSettle();
      expect(find.text('アルゴリズムとデータ構造Ⅰ'), findsWidgets);
      expect(find.text('詳細を見る'), findsOneWidget);

      activeContext = null;
      container.invalidate(activeScheduleContextProvider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('詳細を見る'), findsNothing);
      expect(find.byKey(const Key('course-selection-room')), findsNothing);
      expect(find.text('アルゴリズムとデータ構造Ⅰ'), findsNothing);
      expect(find.text('A101'), findsNothing);
      expect(find.byType(TimetableScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

GoRouter _journeyRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
        GoRoute(
            path: '/timetable', builder: (_, __) => const TimetableScreen()),
        GoRoute(
          path: '/course/:id',
          builder: (_, state) =>
              CourseDetailScreen(courseId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const AssignmentListScreen(),
        ),
        GoRoute(path: '/exams', builder: (_, __) => const ExamListScreen()),
      ],
    );

Finder _assignmentScrollable() {
  final assignmentList = find.byType(ListView).first;
  return find
      .descendant(
        of: assignmentList,
        matching: find.byType(Scrollable),
      )
      .first;
}

Finder _assignmentViewport() => find
    .descendant(
      of: _assignmentScrollable(),
      matching: find.byType(Viewport),
    )
    .first;

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
