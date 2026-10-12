import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/assignment/application/assignment_undo.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_list_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

DateTime _jst(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
]) =>
    JapanTime.at(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
    );

void main() {
  final now = _jst(2026, 7, 15, 12);

  testWidgets('狭いAndroid画面でフィルターがオーバーフローしない', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_testApp(state: _state(now: now), now: now));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('未提出'), findsOneWidget);
    expect(find.text('提出済み'), findsOneWidget);
  });

  testWidgets('一覧画面ではクイック追加FABを表示する', (tester) async {
    await tester.pumpWidget(_testApp(state: _state(now: now), now: now));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byTooltip('追加'), findsOneWidget);
  });

  testWidgets('編集アクションは対象の課題名を読み上げる', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _testApp(
        state: _state(
          now: now,
          assignments: [
            _assignment('labelled', 'アクセシビリティ課題', _jst(2026, 7, 15, 18)),
          ],
        ),
        now: now,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('「アクセシビリティ課題」を編集'), findsOneWidget);
    final editSemantics = find.bySemanticsLabel('「アクセシビリティ課題」を編集');
    expect(
      editSemantics,
      findsOneWidget,
    );
    expect(
      tester.getSemantics(editSemantics),
      isSemantics(
        label: '「アクセシビリティ課題」を編集',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('課題フィルターが今日・今週・提出済みを切り替える', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = _state(
      now: now,
      assignments: [
        _assignment('today', '今日の課題', _jst(2026, 7, 15, 18)),
        _assignment('week', '今週の課題', _jst(2026, 7, 17, 18)),
        _assignment('later', '来週の課題', _jst(2026, 7, 20, 18)),
        _assignment('done', '提出済みの課題', _jst(2026, 7, 14, 18)),
      ],
      assignmentStates: {
        'done': AssignmentUserState(
          assignmentId: 'done',
          userId: 'student',
          status: AssignmentStatus.submitted,
          submittedAt: _jst(2026, 7, 14, 12),
        ),
      },
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    expect(find.text('今日の課題'), findsOneWidget);
    expect(find.text('今週の課題'), findsOneWidget);
    expect(find.text('来週の課題'), findsOneWidget);
    expect(find.text('提出済みの課題'), findsNothing);

    await tester.tap(find.byKey(const Key('assignment-filter-today')));
    await tester.pump();
    expect(find.text('今日の課題'), findsOneWidget);
    expect(find.text('今週の課題'), findsNothing);
    expect(find.text('来週の課題'), findsNothing);

    await tester.tap(find.byKey(const Key('assignment-filter-week')));
    await tester.pump();
    expect(find.text('今日の課題'), findsOneWidget);
    expect(find.text('今週の課題'), findsOneWidget);
    expect(find.text('来週の課題'), findsNothing);

    await tester.tap(find.byKey(const Key('assignment-filter-done')));
    await tester.pump();
    expect(find.text('提出済みの課題'), findsOneWidget);
    expect(find.text('今日の課題'), findsNothing);
  });

  testWidgets('未提出課題を期限切れ・今日・今週・それ以降に分ける', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = _state(
      now: now,
      assignments: [
        _assignment('overdue', '遅れている課題', _jst(2026, 7, 14, 18)),
        _assignment('today', '今日までの課題', _jst(2026, 7, 15, 18)),
        _assignment('week', '週内の課題', _jst(2026, 7, 17, 18)),
        _assignment('later', '先の課題', _jst(2026, 7, 22, 18)),
      ],
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    expect(find.text('期限切れの課題（1件）'), findsOneWidget);
    expect(find.text('今日まで（1件）'), findsOneWidget);
    expect(find.text('今週中（1件）'), findsOneWidget);
    expect(find.text('それ以降（1件）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提出処理をawaitし、完了まで二重送信を防ぐ', (tester) async {
    final submission = Completer<void>();
    final controller = _TestDemoAppController(
      initialState: _state(
        now: now,
        assignments: [
          _assignment('pending', '待機する課題', _jst(2026, 7, 15, 18)),
        ],
      ),
      onSubmit: (_) => submission.future,
    );

    await tester.pumpWidget(
      _testApp(
          state: controller.initialState, now: now, controller: controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '提出済みを記録'));
    await tester.pump();

    expect(controller.submitCalls, 1);
    expect(find.widgetWithText(OutlinedButton, '更新中'), findsOneWidget);
    final loadingButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '更新中'),
    );
    expect(loadingButton.onPressed, isNull);

    submission.complete();
    await tester.pumpAndSettle();

    expect(controller.submitCalls, 1);
    expect(find.text('「待機する課題」を提出済みにしました。'), findsOneWidget);
    expect(find.text('未提出の課題はありません'), findsOneWidget);

    await tester.tap(find.byKey(const Key('assignment-filter-done')));
    await tester.pump();
    expect(find.text('待機する課題'), findsOneWidget);
  });

  testWidgets('提出失敗を安全に表示し、再試行できる状態に戻す', (tester) async {
    final controller = _TestDemoAppController(
      initialState: _state(
        now: now,
        assignments: [
          _assignment('failure', '失敗する課題', _jst(2026, 7, 15, 18)),
        ],
      ),
      onSubmit: (_) async {
        throw StateError('internal-token-must-not-leak');
      },
    );

    await tester.pumpWidget(
      _testApp(
          state: controller.initialState, now: now, controller: controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '提出済みを記録'));
    await tester.pumpAndSettle();

    expect(
      find.text('提出状態を更新できませんでした。もう一度お試しください。'),
      findsOneWidget,
    );
    expect(find.textContaining('internal-token'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '提出済みを記録'), findsOneWidget);
  });

  testWidgets('提出直後のUndoで元の状態へ戻せる', (tester) async {
    final controller = _TestDemoAppController(
      initialState: _state(
        now: now,
        assignments: [
          _assignment('undo', 'Undoする課題', _jst(2026, 7, 15, 18)),
        ],
      ),
    );

    await tester.pumpWidget(
      _testApp(
        state: controller.initialState,
        now: now,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '提出済みを記録'));
    await tester.pumpAndSettle();
    expect(find.text('元に戻す'), findsOneWidget);
    expect(find.text('Undoする課題'), findsNothing);

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();

    expect(controller.statusChanges, [AssignmentStatus.notStarted]);
    expect(find.text('Undoする課題'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '提出済みを記録'), findsOneWidget);
  });

  testWidgets('一覧を離れてもUndoが元の状態を復元する', (tester) async {
    final assignment = _assignment(
      'route-undo',
      '画面移動後も戻す課題',
      _jst(2026, 7, 15, 18),
    );
    final controller = _TestDemoAppController(
      initialState: _state(
        now: now,
        assignments: [assignment],
        assignmentStates: {
          assignment.id: AssignmentUserState(
            assignmentId: assignment.id,
            userId: 'student',
            status: AssignmentStatus.inProgress,
          ),
        },
      ),
    );
    final router = GoRouter(
      initialLocation: '/assignments',
      routes: [
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const AssignmentListScreen(),
        ),
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
          appClockProvider.overrideWithValue(_FixedClock(now)),
          demoAppControllerProvider.overrideWith(() => controller),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '提出済みを記録'));
    await tester.pumpAndSettle();
    expect(find.text('元に戻す'), findsOneWidget);

    router.go('/other');
    await tester.pumpAndSettle();
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();

    expect(controller.statusChanges, [AssignmentStatus.inProgress]);
  });

  testWidgets('授業別で全学期の授業・授業なし・削除済みを区別する', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = _state(
      now: now,
      assignments: [
        _assignment(
          'math',
          '数学の課題',
          _jst(2026, 7, 16, 18),
          courseId: 'course-math',
        ),
        _assignment(
          'history',
          '過去学期の課題',
          _jst(2026, 7, 17, 18),
          courseId: 'course-history',
        ),
        _assignment('free', '授業なしの課題', _jst(2026, 7, 18, 18)),
        _assignment(
          'deleted',
          '削除済み授業の課題',
          _jst(2026, 7, 19, 18),
          courseId: 'course-deleted',
        ),
      ],
      assignmentCourses: [
        _course('course-math', '数学', 'spring'),
        _course('course-history', '歴史学', 'previous-term'),
      ],
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('assignment-course-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('歴史学').last);
    await tester.pumpAndSettle();
    expect(find.text('過去学期の課題'), findsOneWidget);
    expect(find.text('数学の課題'), findsNothing);

    await tester.tap(find.byKey(const Key('assignment-course-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('授業なし').last);
    await tester.pumpAndSettle();
    expect(find.text('授業なしの課題'), findsOneWidget);
    expect(find.text('削除済み授業の課題'), findsNothing);

    await tester.tap(find.byKey(const Key('assignment-course-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除済みの授業').last);
    await tester.pumpAndSettle();
    expect(find.text('削除済み授業の課題'), findsOneWidget);
    expect(find.text('削除済みの授業'), findsNWidgets(2));
  });

  testWidgets('手動授業を授業別候補として表示し、その課題だけに絞り込む', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = _state(
      now: now,
      assignments: [
        _assignment(
          'manual-course',
          '手動授業の課題',
          _jst(2026, 7, 16, 18),
          courseId: 'course-manual',
        ),
        _assignment('unassigned', '授業なしの課題', _jst(2026, 7, 17, 18)),
      ],
      courses: [_course('course-manual', '手動登録の授業', 'current-term')],
      assignmentCourses: const [],
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    final courseFilter = find.byKey(const Key('assignment-course-filter'));
    final dropdownButton = find.descendant(
      of: courseFilter,
      matching: find.byWidgetPredicate(
        (widget) => widget is DropdownButton,
        description: 'a dropdown button',
      ),
    );
    expect(dropdownButton, findsOneWidget);
    final dropdown = tester.widget<DropdownButton<dynamic>>(dropdownButton);
    expect(
      (dropdown.items ?? const <DropdownMenuItem<dynamic>>[]).any(
        (item) =>
            item.key ==
            const ValueKey<String>(
              'assignment-course-option-course-manual',
            ),
      ),
      isTrue,
    );

    await tester.tap(courseFilter);
    await tester.pumpAndSettle();
    final manualCourseOption = find.byKey(
      const ValueKey<String>('assignment-course-option-course-manual'),
    );
    expect(manualCourseOption, findsOneWidget);
    expect(
      find.descendant(
        of: manualCourseOption,
        matching: find.text('手動登録の授業'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('手動登録の授業').last);
    await tester.pumpAndSettle();

    expect(find.text('手動授業の課題'), findsOneWidget);
    expect(find.text('授業なしの課題'), findsNothing);
  });

  testWidgets('状態チップで進行中にし、期限切れは表示だけで算出する', (tester) async {
    final controller = _TestDemoAppController(
      initialState: _state(
        now: now,
        assignments: [
          _assignment('start', '着手する課題', _jst(2026, 7, 16, 18)),
          _assignment('late', '期限切れ課題', _jst(2026, 7, 14, 18)),
        ],
      ),
    );

    await tester.pumpWidget(
      _testApp(
        state: controller.initialState,
        now: now,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未着手'), findsOneWidget);
    expect(find.text('期限切れ'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('assignment-status-start')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assignment-status-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('進行中にする'));
    await tester.pumpAndSettle();

    expect(controller.statusChanges, [AssignmentStatus.inProgress]);
    expect(find.text('進行中'), findsOneWidget);
    expect(find.text('「着手する課題」を進行中にしました。'), findsOneWidget);
    expect(find.text('期限切れ'), findsOneWidget);
  });
}

Widget _testApp({
  required DemoAppState state,
  required DateTime now,
  _TestDemoAppController? controller,
}) {
  return ProviderScope(
    overrides: [
      appClockProvider.overrideWithValue(_FixedClock(now)),
      demoAppControllerProvider.overrideWith(
        () => controller ?? _TestDemoAppController(initialState: state),
      ),
    ],
    child: const MaterialApp(home: AssignmentListScreen()),
  );
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

class _TestDemoAppController extends DemoAppController {
  _TestDemoAppController({
    required this.initialState,
    this.onSubmit,
  });

  final DemoAppState initialState;
  final Future<void> Function(String assignmentId)? onSubmit;
  int submitCalls = 0;
  final List<AssignmentStatus> statusChanges = [];

  @override
  Stream<DemoAppState> build() => Stream.value(initialState);

  @override
  Future<void> submitAssignment(String assignmentId) async {
    submitCalls += 1;
    await onSubmit?.call(assignmentId);
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        assignmentStates: {
          ...current.assignmentStates,
          assignmentId: AssignmentUserState(
            assignmentId: assignmentId,
            userId: 'student',
            status: AssignmentStatus.submitted,
            submittedAt: _jst(2026, 7, 15, 12),
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
    statusChanges.add(status);
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(
        assignmentStates: {
          ...current.assignmentStates,
          assignmentId: AssignmentUserState(
            assignmentId: assignmentId,
            userId: 'student',
            status: status,
          ),
        },
      ),
    );
  }
}

Assignment _assignment(
  String id,
  String title,
  DateTime dueAt, {
  String? courseId,
}) =>
    Assignment(
      id: id,
      ownerUserId: 'student',
      title: title,
      dueAt: dueAt,
      courseId: courseId,
    );

UserCourse _course(String id, String title, String termId) => UserCourse(
      id: id,
      ownerUserId: 'student',
      termId: termId,
      title: title,
      normalizedTitle: title,
    );

DemoAppState _state({
  required DateTime now,
  List<Assignment> assignments = const [],
  Map<String, AssignmentUserState> assignmentStates = const {},
  List<UserCourse> courses = const [],
  List<UserCourse> assignmentCourses = const [],
}) {
  return DemoAppState(
    templates: const [],
    periodSettings: const [],
    courses: courses,
    assignmentCourses: assignmentCourses,
    assignments: assignments,
    assignmentStates: assignmentStates,
    exams: const [],
    events: const [],
    eventExceptions: const [],
    calendarItems: const [],
    widgetSnapshot: WidgetSnapshot.empty(now),
    pendingMutations: const [],
    syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
  );
}
