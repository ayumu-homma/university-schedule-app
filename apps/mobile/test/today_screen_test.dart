import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/assignment/application/assignment_undo.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/features/today/domain/today_briefing.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_screen.dart';

DateTime _jst(int day, [int hour = 0, int minute = 0]) => JapanTime.at(
      year: 2026,
      month: 8,
      day: day,
      hour: hour,
      minute: minute,
    );

void main() {
  final now = _jst(10, 10);

  testWidgets('Todayが全項目と終日表現を狭いAndroid画面に表示する', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _TodayTestController(_state(now));

    await tester.pumpWidget(_testApp(controller: controller, now: now));
    await tester.pumpAndSettle();

    expect(find.text('8月10日（月）'), findsOneWidget);
    expect(find.text('現在の授業'), findsWidgets);
    final currentCourse = tester.widget<Text>(
      find.byKey(const Key('today-current-course')),
    );
    final courseContext = tester.element(
      find.byKey(const Key('today-current-course')),
    );
    expect(
      currentCourse.style?.color,
      Theme.of(courseContext).colorScheme.onPrimaryContainer,
    );
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('今日の課題'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('今日の課題'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('期限超過の課題'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('期限超過の課題'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('今日の試験'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('今日の試験'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('終日予定'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('終日予定'), findsOneWidget);
    expect(find.text('終日'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('毎週の復習'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('毎週の復習'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Todayの提出は二重送信を防ぎSnackbarから元に戻せる', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _TodayTestController(_state(now));

    await tester.pumpWidget(_testApp(controller: controller, now: now));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('today-submit-due'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.submitCalls, 1);
    expect(find.text('「今日の課題」を提出済みにしました。'), findsOneWidget);
    expect(find.text('元に戻す'), findsOneWidget);

    await tester.tap(find.byType(SnackBarAction));
    await tester.pumpAndSettle();

    expect(controller.undoCalls, 1);
    expect(find.text('今日の課題'), findsOneWidget);
  });

  testWidgets('Todayを離れても提出のUndoが実行される', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _TodayTestController(_state(now));
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const TodayScreen()),
        GoRoute(
          path: '/other',
          builder: (_, __) => const Scaffold(body: Text('別画面')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeScheduleContextProvider.overrideWithValue(_context),
          todayTimeProvider.overrideWith((ref) => Stream.value(now)),
          demoAppControllerProvider.overrideWith(() => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final submitButton = find.byKey(const Key('today-submit-due'));
    await tester.ensureVisible(submitButton);
    await tester.tap(find.byKey(const Key('today-submit-due')));
    await tester.pumpAndSettle();
    expect(find.text('元に戻す'), findsOneWidget);

    router.go('/other');
    await tester.pumpAndSettle();
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();

    expect(controller.undoCalls, 1);
  });

  testWidgets('代表的な2倍文字サイズでスクロール可能かつoverflowしない', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _TodayTestController(_state(now));

    await tester.pumpWidget(
      _testApp(controller: controller, now: now, textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-briefing-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Todayの読み込み失敗は内部例外を表示しない', (tester) async {
    const internalDetail =
        'postgres://admin:super-secret@internal.example/production';
    final controller = _TodayTestController(_state(now));

    await tester.pumpWidget(
      _testApp(
        controller: controller,
        now: now,
        briefingState: AsyncError<TodayBriefing>(
          StateError(internalDetail),
          StackTrace.fromString('internal stack frame with $internalDetail'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today-load-error')), findsOneWidget);
    expect(find.text('今日の予定を読み込めませんでした'), findsOneWidget);
    expect(find.textContaining(internalDetail), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });
}

Widget _testApp({
  required _TodayTestController controller,
  required DateTime now,
  double textScale = 1,
  AsyncValue<TodayBriefing>? briefingState,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const TodayScreen()),
      GoRoute(
        path: '/assignment/:id/edit',
        builder: (_, state) => Scaffold(
          body: Text('assignment:${state.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, __) => const Scaffold(body: Text('settings')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      activeScheduleContextProvider.overrideWithValue(_context),
      todayTimeProvider.overrideWith((ref) => Stream.value(now)),
      demoAppControllerProvider.overrideWith(() => controller),
      if (briefingState != null)
        todayBriefingProvider.overrideWithValue(briefingState),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
    ),
  );
}

class _TodayTestController extends DemoAppController {
  _TodayTestController(this.initial);

  final DemoAppState initial;
  int submitCalls = 0;
  int undoCalls = 0;

  @override
  Stream<DemoAppState> build() => Stream.value(initial);

  @override
  Future<void> submitAssignment(String assignmentId) async {
    submitCalls++;
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        assignmentStates: {
          ...current.assignmentStates,
          assignmentId: AssignmentUserState(
            assignmentId: assignmentId,
            userId: _context.ownerUserId,
            status: AssignmentStatus.submitted,
            submittedAt: nowForTest,
          ),
        },
      ),
    );
  }

  @override
  Future<AssignmentUndoOperation> submitAssignmentWithUndo(
    String assignmentId,
  ) async {
    final before = state.requireValue.assignmentStates[assignmentId];
    await submitAssignment(assignmentId);
    final after = state.requireValue.assignmentStates[assignmentId]!;
    return AssignmentUndoOperation(
      receipt: AssignmentUndoReceipt(
        assignmentId: assignmentId,
        ownerUserId: after.userId,
        previousState: before,
        resultingVersion: after.version,
      ),
      undo: (receipt) => setAssignmentStatus(
        receipt.assignmentId,
        receipt.previousState?.status ?? AssignmentStatus.notStarted,
      ),
    );
  }

  @override
  Future<void> setAssignmentStatus(
    String assignmentId,
    AssignmentStatus status,
  ) async {
    undoCalls++;
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        assignmentStates: {
          ...current.assignmentStates,
          assignmentId: AssignmentUserState(
            assignmentId: assignmentId,
            userId: _context.ownerUserId,
            status: status,
          ),
        },
      ),
    );
  }
}

final nowForTest = _jst(10, 10);

DemoAppState _state(DateTime now) {
  return DemoAppState(
    templates: const [],
    periodSettings: const [
      PeriodSetting(
        id: 'period-1',
        ownerUserId: 'owner',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
        startTimeMinutes: 9 * 60,
        endTimeMinutes: 10 * 60 + 30,
      ),
    ],
    courses: const [
      UserCourse(
        id: 'course',
        ownerUserId: 'owner',
        termId: 'term',
        title: '現在の授業',
        normalizedTitle: '現在の授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    ],
    assignments: [
      Assignment(
        id: 'due',
        ownerUserId: 'owner',
        title: '今日の課題',
        dueAt: _jst(10, 18),
      ),
      Assignment(
        id: 'overdue',
        ownerUserId: 'owner',
        title: '期限超過の課題',
        dueAt: _jst(9, 18),
      ),
    ],
    assignmentStates: const {},
    exams: [
      Exam(
        id: 'exam',
        ownerUserId: 'owner',
        title: '今日の試験',
        startAt: _jst(10, 15),
        endAt: _jst(10, 16),
      ),
    ],
    events: [
      ScheduleEvent(
        id: 'all-day',
        ownerUserId: 'owner',
        calendarId: 'calendar',
        title: '終日予定',
        kind: EventKind.normal,
        startAt: _jst(10),
        endAt: _jst(11),
        isAllDay: true,
      ),
      ScheduleEvent(
        id: 'routine',
        ownerUserId: 'owner',
        calendarId: 'calendar',
        title: '毎週の復習',
        kind: EventKind.routine,
        startAt: _jst(10, 20),
        endAt: _jst(10, 21),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 1,
        ),
      ),
    ],
    eventExceptions: const [],
    calendarItems: const [],
    widgetSnapshot: WidgetSnapshot.empty(now),
    pendingMutations: const [],
    syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
  );
}

const _context = ActiveScheduleContext(
  ownerUserId: 'owner',
  universityId: 'university',
  termId: 'term',
  academicYear: 2026,
  primaryCalendarId: 'calendar',
);
