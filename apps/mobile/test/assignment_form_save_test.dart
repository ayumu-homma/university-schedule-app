import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  testWidgets('assignment edit saves changed values with the loaded version',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule();
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _editTitleAndSave(tester, '更新後のレポート');

    expect(
      schedule.updateCalls,
      hasLength(1),
    );
    final call = schedule.updateCalls.single;
    expect(call.assignmentId, 'assignment-1');
    expect(call.expectedVersion, 6);
    expect(call.input.title, '更新後のレポート');
    expect(call.input.dueAt, DateTime.utc(2026, 10, 1, 12));
    expect(find.text('課題一覧へ戻りました'), findsOneWidget);
  });

  testWidgets('assignment save conflict keeps the edited draft for recovery',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule(failure: _SaveFailure.conflict);
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _editTitleAndSave(tester, '競合後も残るレポート');

    expect(
      find.text('別の変更が反映されました。画面を開き直して確認してください。'),
      findsOneWidget,
    );
    expect(find.text('課題を編集'), findsOneWidget);
    expect(find.text('競合後も残るレポート'), findsOneWidget);
    expect(find.text('課題一覧へ戻りました'), findsNothing);
    expect(schedule.updateCalls.single.expectedVersion, 6);
  });

  testWidgets('assignment save failure keeps draft and restores retry action',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _AssignmentSchedule(failure: _SaveFailure.generic);
    final router = await _pumpAssignmentEdit(tester, schedule);
    addTearDown(router.dispose);

    await _editTitleAndSave(tester, '一時失敗後も残るレポート');

    expect(find.text('保存に失敗しました。もう一度お試しください。'), findsOneWidget);
    expect(find.text('課題を編集'), findsOneWidget);
    expect(find.text('一時失敗後も残るレポート'), findsOneWidget);
    expect(find.text('課題一覧へ戻りました'), findsNothing);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('assignment-save')),
    );
    expect(save.onPressed, isNotNull);
    expect(schedule.updateCalls, hasLength(1));
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

Future<void> _editTitleAndSave(WidgetTester tester, String title) async {
  final titleField = find.widgetWithText(TextFormField, '課題名');
  await tester.enterText(titleField, title);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final save = find.byKey(const Key('assignment-save'));
  await tester.scrollUntilVisible(
    save,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

enum _SaveFailure { none, conflict, generic }

class _AssignmentSchedule extends DemoAppController {
  _AssignmentSchedule({this.failure = _SaveFailure.none});

  final _SaveFailure failure;
  final updateCalls =
      <({String assignmentId, int expectedVersion, AssignmentInput input})>[];

  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 9, 24)).copyWith(
          assignments: [_assignment],
        ),
      );

  @override
  Future<void> updateAssignment(
    String assignmentId,
    int expectedVersion,
    AssignmentInput input,
  ) async {
    updateCalls.add((
      assignmentId: assignmentId,
      expectedVersion: expectedVersion,
      input: input,
    ));
    switch (failure) {
      case _SaveFailure.none:
        return;
      case _SaveFailure.conflict:
        throw const ConflictError('synthetic assignment version conflict');
      case _SaveFailure.generic:
        throw StateError('synthetic assignment save failure');
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
