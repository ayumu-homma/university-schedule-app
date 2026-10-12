import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';

void main() {
  testWidgets('canceling assignment deletion makes no mutation',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule();
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    expect(find.text('課題を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(schedule.deleteCalls, isEmpty);
    expect(find.text('課題を編集'), findsOneWidget);
    expect(find.text('時間割へ戻りました'), findsNothing);
  });

  testWidgets(
      'confirmed assignment deletion sends loaded version then navigates',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule();
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(
      schedule.deleteCalls,
      [(assignmentId: 'assignment-1', expectedVersion: 6)],
    );
    expect(find.text('課題一覧へ戻りました'), findsOneWidget);
  });

  testWidgets('assignment delete conflict keeps form and explains recovery',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule(failure: _DeleteFailure.conflict);
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('別の変更が反映されました。画面を開き直して確認してください。'), findsOneWidget);
    expect(find.text('課題を編集'), findsOneWidget);
    expect(find.text('課題一覧へ戻りました'), findsNothing);
    expect(
      schedule.deleteCalls,
      [(assignmentId: 'assignment-1', expectedVersion: 6)],
    );
  });

  testWidgets('assignment delete failure keeps form and allows retry',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule(failure: _DeleteFailure.generic);
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('削除に失敗しました。もう一度お試しください。'), findsOneWidget);
    expect(find.text('課題を編集'), findsOneWidget);
    expect(find.text('課題一覧へ戻りました'), findsNothing);
    expect(
      schedule.deleteCalls,
      [(assignmentId: 'assignment-1', expectedVersion: 6)],
    );
    final deleteButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'この課題を削除'),
    );
    expect(deleteButton.onPressed, isNotNull);
  });
}

Future<GoRouter> _pumpAssignmentEdit(
  WidgetTester tester,
  _AssignmentSchedule schedule,
) async {
  final router = GoRouter(
    initialLocation: '/assignment/assignment-1/edit',
    routes: [
      GoRoute(
        path: '/assignment/:id/edit',
        builder: (context, state) => AssignmentFormScreen(
          assignmentId: state.pathParameters['id'],
        ),
      ),
      GoRoute(
        path: '/assignments',
        builder: (context, state) => const Scaffold(body: Text('課題一覧へ戻りました')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [demoAppControllerProvider.overrideWith(() => schedule)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _openDeleteConfirmation(WidgetTester tester) async {
  final delete = find.text('この課題を削除');
  await tester.scrollUntilVisible(
    delete,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(delete);
  await tester.pumpAndSettle();
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

enum _DeleteFailure { none, conflict, generic }

class _AssignmentSchedule extends DemoAppController {
  _AssignmentSchedule({this.failure = _DeleteFailure.none});

  final _DeleteFailure failure;
  final deleteCalls = <({String assignmentId, int expectedVersion})>[];

  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 9, 24)).copyWith(
          assignments: [_assignment],
        ),
      );

  @override
  Future<void> deleteAssignment(
      String assignmentId, int expectedVersion) async {
    deleteCalls
        .add((assignmentId: assignmentId, expectedVersion: expectedVersion));
    switch (failure) {
      case _DeleteFailure.none:
        return;
      case _DeleteFailure.conflict:
        throw const ConflictError('synthetic assignment version conflict');
      case _DeleteFailure.generic:
        throw StateError('synthetic assignment delete failure');
    }
  }
}

final _assignment = Assignment(
  id: 'assignment-1',
  ownerUserId: 'owner-1',
  title: '提出レポート',
  dueAt: DateTime.utc(2026, 10, 1, 12),
  version: 6,
);
