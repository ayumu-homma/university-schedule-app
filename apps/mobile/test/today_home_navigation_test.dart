import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/home_screen.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_screen.dart';

void main() {
  testWidgets('HomeとTodayが同じbriefing providerを使って遷移する', (tester) async {
    final now = JapanTime.at(year: 2026, month: 8, day: 10, hour: 10);
    final state = DemoAppState(
      templates: const [],
      periodSettings: const [],
      courses: const [],
      assignments: [
        Assignment(
          id: 'home-due',
          ownerUserId: 'owner',
          title: 'Homeにも出る課題',
          dueAt: JapanTime.at(year: 2026, month: 8, day: 10, hour: 18),
        ),
      ],
      assignmentStates: const {},
      exams: const [],
      events: const [],
      eventExceptions: const [],
      calendarItems: const [],
      widgetSnapshot: WidgetSnapshot.empty(now),
      pendingMutations: const [],
      syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('settings')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeScheduleContextProvider.overrideWithValue(_context),
          todayTimeProvider.overrideWith((ref) => Stream.value(now)),
          demoAppControllerProvider.overrideWith(
            () => _HomeTestController(state),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('課題 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-today-briefing')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-briefing-list')), findsOneWidget);
    expect(find.text('Homeにも出る課題'), findsOneWidget);
  });
}

class _HomeTestController extends DemoAppController {
  _HomeTestController(this.initial);

  final DemoAppState initial;

  @override
  Stream<DemoAppState> build() => Stream.value(initial);
}

const _context = ActiveScheduleContext(
  ownerUserId: 'owner',
  universityId: 'university',
  termId: 'term',
  academicYear: 2026,
  primaryCalendarId: 'calendar',
);
