import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/assignment/application/assignment_undo.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_list_screen.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_list_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/shared/widgets/academic_mode_switch.dart';

void main() {
  final now = _jst(2026, 7, 15, 12);

  testWidgets('workload modes expose one labelled selected accessible action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final router = _router();
    addTearDown(router.dispose);
    try {
      await tester.pumpWidget(
        _app(
          state: _state(now: now),
          now: now,
          router: router,
          mediaSize: const Size(412, 900),
        ),
      );
      await tester.pumpAndSettle();

      _expectModeSemantics(tester, AcademicMode.assignments);
      final examNode = find.semantics.byLabel('テスト、1件。全日程のテスト数');
      tester.semantics.tap(examNode);
      await tester.pumpAndSettle();
      expect(find.byType(ExamListScreen), findsOneWidget);
      _expectModeSemantics(tester, AcademicMode.exams);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'native submit semantics invokes one guarded submission and disables while pending',
      (
    tester,
  ) async {
    final submission = Completer<AssignmentUndoOperation>();
    final controller = _TestDemoAppController(
      _state(now: now),
      onSubmit: (assignmentId) {
        expect(assignmentId, 'today');
        return submission.future;
      },
    );
    final router = _router();
    addTearDown(router.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _app(
          state: controller.initialState,
          now: now,
          router: router,
          mediaSize: const Size(412, 900),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      final visibleSubmitText = find.text('提出済みを記録');
      await tester.scrollUntilVisible(
        visibleSubmitText,
        250,
        scrollable: _routeScrollable(),
      );
      await tester.ensureVisible(visibleSubmitText);
      await tester.pumpAndSettle();

      final submitButton = _todayAssignmentButton('提出済みを記録');
      final submitNode = tester.semantics.find(submitButton);
      expect(submitNode.label, '提出済みを記録');
      final submitData = submitNode.getSemanticsData();
      expect(submitData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(submitData.flagsCollection.isButton, isTrue);
      expect(submitData.flagsCollection.isEnabled, ui.Tristate.isTrue);
      tester.semantics.tap(
        find.semantics.byPredicate((node) => node.id == submitNode.id),
      );
      await tester.pump();

      expect(controller.submitCalls, 1);
      expect(controller.submittedAssignmentIds, ['today']);
      final pendingButton = _todayAssignmentButton('更新中');
      final pendingNode = tester.semantics.find(pendingButton);
      expect(pendingNode.label, '更新中');
      final pendingData = pendingNode.getSemanticsData();
      expect(pendingData.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(pendingData.hasAction(ui.SemanticsAction.tap), isFalse);

      submission.complete(
        AssignmentUndoOperation(
          receipt: const AssignmentUndoReceipt(
            assignmentId: 'today',
            ownerUserId: 'student',
            previousState: null,
            resultingVersion: 1,
          ),
          undo: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.submitCalls, 1);
    } finally {
      try {
        if (!submission.isCompleted) {
          submission.complete(
            AssignmentUndoOperation(
              receipt: const AssignmentUndoReceipt(
                assignmentId: 'today',
                ownerUserId: 'student',
                previousState: null,
                resultingVersion: 1,
              ),
              undo: (_) async {},
            ),
          );
          await tester.pumpAndSettle();
        }
      } finally {
        semantics.dispose();
      }
    }
  });

  for (final fail in [false, true]) {
    testWidgets(
      'submission ${fail ? 'failure' : 'success'} after route disposal is suppressed',
      (tester) async {
        final submission = Completer<AssignmentUndoOperation>();
        final controller = _TestDemoAppController(
          _state(now: now),
          onSubmit: (_) => submission.future,
        );
        final router = _router();
        addTearDown(router.dispose);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _app(
              state: controller.initialState,
              now: now,
              router: router,
              mediaSize: const Size(412, 900),
              controller: controller,
            ),
          );
          await tester.pumpAndSettle();
          await _performNativeSubmitSemantics(tester);
          expect(controller.submitCalls, 1);
          expect(controller.submittedAssignmentIds, ['today']);

          final rootMessenger = tester.state<ScaffoldMessengerState>(
            find.byType(ScaffoldMessenger).first,
          );
          router.go('/other');
          await tester.pumpAndSettle();
          expect(find.text('別の画面'), findsOneWidget);
          expect(find.byType(AssignmentListScreen), findsNothing);
          expect(rootMessenger.mounted, isTrue);
          expect(
            identical(
              rootMessenger,
              tester.state<ScaffoldMessengerState>(
                find.byType(ScaffoldMessenger).first,
              ),
            ),
            isTrue,
          );

          if (fail) {
            submission.completeError(StateError('synthetic submission error'));
          } else {
            submission.complete(_undoOperation());
          }
          await tester.pump();
          await tester.pump();

          expect(controller.submitCalls, 1);
          expect(
            find.text('「今日が締切の課題」を提出済みにしました。'),
            findsNothing,
          );
          expect(
            find.text('提出状態を更新できませんでした。もう一度お試しください。'),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        } finally {
          try {
            if (!submission.isCompleted) {
              submission.complete(_undoOperation());
              await tester.pump();
            }
          } finally {
            semantics.dispose();
          }
        }
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'submission ${fail ? 'failure' : 'success'} after owner change is suppressed',
      (tester) async {
        final submission = Completer<AssignmentUndoOperation>();
        final controller = _TestDemoAppController(
          _state(now: now),
          onSubmit: (_) => submission.future,
        );
        var activeContext = demoScheduleContext;
        final container = ProviderContainer(
          overrides: [
            appClockProvider.overrideWithValue(_FixedClock(now)),
            activeScheduleContextProvider.overrideWith((ref) => activeContext),
            demoAppControllerProvider.overrideWith(() => controller),
          ],
        );
        addTearDown(container.dispose);
        final router = _router();
        addTearDown(router.dispose);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _app(
              state: controller.initialState,
              now: now,
              router: router,
              mediaSize: const Size(412, 900),
              controller: controller,
              container: container,
            ),
          );
          await tester.pumpAndSettle();
          final assignmentState =
              tester.state(find.byType(AssignmentListScreen));
          await _performNativeSubmitSemantics(tester);
          expect(controller.submitCalls, 1);

          activeContext = const ActiveScheduleContext(
            ownerUserId: 'different-owner',
            universityId: 'different-university',
            termId: 'different-term',
            academicYear: 2027,
            primaryCalendarId: 'different-calendar',
          );
          container.invalidate(activeScheduleContextProvider);
          expect(find.byType(AssignmentListScreen), findsOneWidget);
          expect(
            tester.state(find.byType(AssignmentListScreen)),
            same(assignmentState),
          );

          if (fail) {
            submission.completeError(StateError('synthetic submission error'));
          } else {
            submission.complete(_undoOperation());
          }
          await tester.pump();
          await tester.pump();

          expect(
            tester.state(find.byType(AssignmentListScreen)),
            same(assignmentState),
          );
          expect(find.text('「今日が締切の課題」を提出済みにしました。'), findsNothing);
          expect(
            find.text('提出状態を更新できませんでした。もう一度お試しください。'),
            findsNothing,
          );
          expect(controller.submitCalls, 1);
          expect(controller.submittedAssignmentIds, ['today']);
          expect(tester.takeException(), isNull);
        } finally {
          try {
            if (!submission.isCompleted) {
              submission.complete(_undoOperation());
              await tester.pump();
            }
          } finally {
            semantics.dispose();
          }
        }
      },
    );
  }

  testWidgets('課題とテストを双方向に切り替え、スナップショット件数を示す', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      _app(
        state: _state(now: now),
        now: now,
        router: router,
        mediaSize: const Size(412, 900),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('課題 3件'), findsOneWidget);
    expect(find.text('テスト 1件'), findsOneWidget);
    expect(find.text('未提出 2件 · 期限切れ 0件 · 今日 1件'), findsOneWidget);
    final todayAction = find.text('今日を見る');
    await tester.ensureVisible(todayAction);
    await tester.tap(todayAction);
    await tester.pumpAndSettle();
    expect(find.text('今日が締切の課題'), findsOneWidget);
    expect(find.text('来週の課題'), findsNothing);

    await tester.tap(find.byKey(const Key('academic-mode-exams')));
    await tester.pumpAndSettle();
    expect(find.text('今日の小テスト'), findsOneWidget);
    expect(find.text('課題 3件'), findsOneWidget);
    expect(find.text('テスト 1件'), findsOneWidget);

    await tester.tap(find.byKey(const Key('academic-mode-assignments')));
    await tester.pumpAndSettle();
    expect(find.text('今日が締切の課題'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final viewportCases = <({
    String name,
    Size size,
    ThemeMode themeMode,
    EdgeInsets viewInsets,
  })>[
    (
      name: '360 dp phone',
      size: const Size(360, 800),
      themeMode: ThemeMode.light,
      viewInsets: EdgeInsets.zero,
    ),
    (
      name: '412 dp phone',
      size: const Size(412, 915),
      themeMode: ThemeMode.dark,
      viewInsets: EdgeInsets.zero,
    ),
    (
      name: '1024 dp tablet',
      size: const Size(1024, 900),
      themeMode: ThemeMode.light,
      viewInsets: EdgeInsets.zero,
    ),
    (
      name: '844 dp landscape with keyboard inset',
      size: const Size(844, 390),
      themeMode: ThemeMode.dark,
      viewInsets: const EdgeInsets.only(bottom: 120),
    ),
  ];

  for (final scenario in viewportCases) {
    testWidgets(
      '${scenario.name} supports 200% Japanese text and both workload modes',
      (tester) async {
        await tester.binding.setSurfaceSize(scenario.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final router = _router();
        addTearDown(router.dispose);

        await tester.pumpWidget(
          _app(
            state: _state(now: now, longText: true),
            now: now,
            router: router,
            mediaSize: scenario.size,
            textScale: 2,
            themeMode: scenario.themeMode,
            viewInsets: scenario.viewInsets,
          ),
        );
        await tester.pumpAndSettle();

        final media = tester.widget<MediaQuery>(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is MediaQuery && widget.data.size == scenario.size,
              )
              .last,
        );
        expect(media.data.size, scenario.size);
        expect(media.data.viewInsets, scenario.viewInsets);
        expect(tester.takeException(), isNull);
        _expectModeControls(tester);

        final assignmentTitle = find.text('非常に長い日本語の課題タイトルを拡大表示しても内容を確認できる課題');
        await _ensureTextVisible(tester, assignmentTitle, scenario);
        expect(assignmentTitle, findsOneWidget);

        final examsMode = find.byKey(const Key('academic-mode-exams'));
        await tester.scrollUntilVisible(
          examsMode,
          -150,
          scrollable: _routeScrollable(),
        );
        await tester.tap(examsMode);
        await tester.pumpAndSettle();
        _expectModeControls(tester);

        final examTitle = find.text('日本語の長い試験名を拡大表示しても最後まで読める中間試験');
        await _ensureTextVisible(tester, examTitle, scenario);
        expect(examTitle, findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

void _expectModeControls(WidgetTester tester) {
  for (final mode in ['assignments', 'exams']) {
    final control = find.byKey(Key('academic-mode-$mode'));
    expect(tester.getSize(control).height, greaterThanOrEqualTo(48));
  }
}

void _expectModeSemantics(WidgetTester tester, AcademicMode selectedMode) {
  final expectedLabels = {
    AcademicMode.assignments: '課題、3件。提出済みを含む全課題数',
    AcademicMode.exams: 'テスト、1件。全日程のテスト数',
  };
  final modeNodes =
      tester.semantics.simulatedAccessibilityTraversal().where((node) {
    final label = node.getSemanticsData().label;
    return expectedLabels.values.contains(label) ||
        label == '課題 3件' ||
        label == 'テスト 1件';
  }).toList();
  expect(modeNodes, hasLength(2));
  expect(
    modeNodes.every(
      (node) => node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
    ),
    isTrue,
  );

  for (final mode in AcademicMode.values) {
    final nodeFinder = find.semantics.byLabel(expectedLabels[mode]!);
    expect(nodeFinder, findsOneWidget);
    final data = nodeFinder.evaluate().single.getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
    expect(
      data.flagsCollection.isSelected,
      mode == selectedMode ? ui.Tristate.isTrue : ui.Tristate.isFalse,
    );
    expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
  }
}

Future<void> _ensureTextVisible(
  WidgetTester tester,
  Finder target,
  ({
    String name,
    Size size,
    ThemeMode themeMode,
    EdgeInsets viewInsets
  }) scenario,
) async {
  await tester.scrollUntilVisible(
    target,
    100,
    scrollable: _routeScrollable(),
  );
  await tester.pumpAndSettle();
  final viewport = tester.getRect(_routeViewport());
  final text = tester.widget<Text>(target);
  expect(text.data, isNotEmpty, reason: scenario.name);
  expect(text.maxLines, isNull, reason: scenario.name);
  expect(text.overflow, isNot(TextOverflow.ellipsis), reason: scenario.name);
  final semantics = tester.ensureSemantics();
  try {
    expect(
      tester.getSemantics(target).label,
      contains(text.data!),
      reason: scenario.name,
    );
  } finally {
    semantics.dispose();
  }

  await Scrollable.ensureVisible(
    tester.element(target),
    alignment: 0,
  );
  await tester.pumpAndSettle();
  final firstReadingRect = tester.getRect(target);
  expect(
    firstReadingRect.top,
    greaterThanOrEqualTo(viewport.top - 1),
    reason: scenario.name,
  );
  if (firstReadingRect.height <= viewport.height) {
    expect(
      firstReadingRect.bottom,
      lessThanOrEqualTo(viewport.bottom + 1),
      reason: scenario.name,
    );
    return;
  }

  await Scrollable.ensureVisible(
    tester.element(target),
    alignment: 1,
  );
  await tester.pumpAndSettle();
  final lastReadingRect = tester.getRect(target);
  expect(
    lastReadingRect.bottom,
    lessThanOrEqualTo(viewport.bottom + 1),
    reason: scenario.name,
  );
  expect(
    lastReadingRect.top,
    lessThan(viewport.bottom),
    reason: scenario.name,
  );
}

Finder _routeScrollable() {
  final listView = find.byType(ListView).first;
  return find
      .descendant(
        of: listView,
        matching: find.byType(Scrollable),
      )
      .first;
}

Future<void> _performNativeSubmitSemantics(WidgetTester tester) async {
  final submitButton = _todayAssignmentButton('提出済みを記録');
  await tester.scrollUntilVisible(
    submitButton,
    250,
    scrollable: _routeScrollable(),
  );
  await tester.ensureVisible(submitButton);
  await tester.pumpAndSettle();
  final submitNode = tester.semantics.find(submitButton);
  expect(submitNode.label, '提出済みを記録');
  tester.semantics.tap(
    find.semantics.byPredicate((node) => node.id == submitNode.id),
  );
  await tester.pump();
}

Finder _todayAssignmentButton(String label) => find.descendant(
      of: find.ancestor(
        of: find.text('今日が締切の課題'),
        matching: find.byType(Card),
      ),
      matching: find.widgetWithText(OutlinedButton, label),
    );

AssignmentUndoOperation _undoOperation() => AssignmentUndoOperation(
      receipt: const AssignmentUndoReceipt(
        assignmentId: 'today',
        ownerUserId: 'student',
        previousState: null,
        resultingVersion: 1,
      ),
      undo: (_) async {},
    );

Finder _routeViewport() => find
    .descendant(
      of: _routeScrollable(),
      matching: find.byType(Viewport),
    )
    .first;

GoRouter _router() => GoRouter(
      initialLocation: '/assignments',
      routes: [
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const AssignmentListScreen(),
        ),
        GoRoute(
          path: '/exams',
          builder: (_, __) => const ExamListScreen(),
        ),
        GoRoute(
          path: '/other',
          builder: (_, __) => const Scaffold(body: Text('別の画面')),
        ),
      ],
    );

Widget _app({
  required DemoAppState state,
  required DateTime now,
  required GoRouter router,
  required Size mediaSize,
  double textScale = 1,
  ThemeMode themeMode = ThemeMode.light,
  EdgeInsets viewInsets = EdgeInsets.zero,
  DemoAppController? controller,
  ProviderContainer? container,
}) {
  final app = MaterialApp.router(
    routerConfig: router,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: mediaSize,
        viewInsets: viewInsets,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: child!,
    ),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(
    overrides: [
      appClockProvider.overrideWithValue(_FixedClock(now)),
      demoAppControllerProvider.overrideWith(
        () => controller ?? _TestDemoAppController(state),
      ),
    ],
    child: app,
  );
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

class _TestDemoAppController extends DemoAppController {
  _TestDemoAppController(this.initialState, {this.onSubmit});

  final DemoAppState initialState;
  final Future<AssignmentUndoOperation> Function(String assignmentId)? onSubmit;
  int submitCalls = 0;

  @override
  Stream<DemoAppState> build() => Stream.value(initialState);

  @override
  Future<AssignmentUndoOperation> submitAssignmentWithUndo(
    String assignmentId,
  ) {
    submitCalls += 1;
    submittedAssignmentIds.add(assignmentId);
    return onSubmit?.call(assignmentId) ??
        super.submitAssignmentWithUndo(assignmentId);
  }

  final List<String> submittedAssignmentIds = [];
}

DemoAppState _state({required DateTime now, bool longText = false}) {
  final assignments = [
    Assignment(
      id: 'today',
      ownerUserId: 'student',
      title: longText ? '非常に長い日本語の課題タイトルを拡大表示しても内容を確認できる課題' : '今日が締切の課題',
      dueAt: _jst(2026, 7, 15, 18),
    ),
    Assignment(
      id: 'submitted',
      ownerUserId: 'student',
      title: '提出済みの課題',
      dueAt: _jst(2026, 7, 14, 18),
    ),
    Assignment(
      id: 'later',
      ownerUserId: 'student',
      title: '来週の課題',
      dueAt: _jst(2026, 7, 22, 18),
    ),
  ];
  return DemoAppState(
    templates: const [],
    periodSettings: const [],
    courses: const [],
    assignments: assignments,
    assignmentStates: {
      'submitted': AssignmentUserState(
        assignmentId: 'submitted',
        userId: 'student',
        status: AssignmentStatus.submitted,
        submittedAt: _jst(2026, 7, 14, 12),
      ),
    },
    exams: [
      Exam(
        id: 'exam',
        ownerUserId: 'student',
        title: longText ? '日本語の長い試験名を拡大表示しても最後まで読める中間試験' : '今日の小テスト',
        startAt: _jst(2026, 7, 15, 16),
        endAt: _jst(2026, 7, 15, 17, 30),
        room: '講義室101',
      ),
    ],
    events: const [],
    eventExceptions: const [],
    calendarItems: const [],
    widgetSnapshot: WidgetSnapshot.empty(now),
    pendingMutations: const [],
    syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
  );
}

DateTime _jst(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    JapanTime.at(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
    );
