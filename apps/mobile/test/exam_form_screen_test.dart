import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  for (final examType in ['レポート', '発表']) {
    testWidgets('edit form saves the $examType variant with its loaded version',
        (tester) async {
      _useTallViewport(tester);
      final schedule = _ExamSchedule(examType: examType);
      final router = await _pumpExamEdit(tester, schedule);
      addTearDown(router.dispose);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'テスト名'),
        '$examType の提出物',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '教室'),
        '講義棟 301',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'メモ'),
        '編集後の提出範囲',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await _tapSave(tester);

      expect(schedule.updateCalls, hasLength(1));
      final call = schedule.updateCalls.single;
      expect(call.examId, 'exam-1');
      expect(call.expectedVersion, 4);
      expect(call.input.title, '$examType の提出物');
      expect(call.input.startAt, DateTime.utc(2026, 10, 1, 1));
      expect(call.input.endAt, DateTime.utc(2026, 10, 1, 2));
      expect(call.input.room, '講義棟 301');
      expect(call.input.examType, examType);
      expect(call.input.memo, '編集後の提出範囲');
      expect(find.text('テスト一覧へ戻りました'), findsOneWidget);
    });
  }

  testWidgets('exam edit conflict keeps the changed draft for recovery',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule(failure: _SaveFailure.conflict);
    final router = await _pumpExamEdit(tester, schedule);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'テスト名'),
      '競合後に残す試験',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '種別'),
      '発表',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _tapSave(tester);

    expect(find.text('別の変更が反映されました。画面を開き直して確認してください。'), findsOneWidget);
    expect(find.text('テストを編集'), findsOneWidget);
    expect(find.text('競合後に残す試験'), findsOneWidget);
    expect(find.text('発表'), findsOneWidget);
    expect(find.text('テスト一覧へ戻りました'), findsNothing);
    expect(schedule.updateCalls.single.expectedVersion, 4);
    router.dispose();
  });

  testWidgets('exam edit failure keeps draft and restores save action',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule(failure: _SaveFailure.generic);
    final router = await _pumpExamEdit(tester, schedule);
    addTearDown(router.dispose);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'テスト名'),
      '再試行できるテスト',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _tapSave(tester);

    expect(find.text('保存に失敗しました。もう一度お試しください。'), findsOneWidget);
    expect(find.text('テストを編集'), findsOneWidget);
    expect(find.text('再試行できるテスト'), findsOneWidget);
    expect(find.text('テスト一覧へ戻りました'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('exam-save'))).onPressed,
      isNotNull,
    );
    expect(schedule.updateCalls, hasLength(1));
  });
}

Future<GoRouter> _pumpExamEdit(
  WidgetTester tester,
  _ExamSchedule schedule,
) async {
  final router = GoRouter(
    initialLocation: '/exam/exam-1/edit',
    routes: [
      GoRoute(
        path: '/exam/:id/edit',
        builder: (context, state) => ExamFormScreen(
          examId: state.pathParameters['id'],
        ),
      ),
      GoRoute(
        path: '/exams',
        builder: (context, state) => const Scaffold(body: Text('テスト一覧へ戻りました')),
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

Future<void> _tapSave(WidgetTester tester) async {
  final save = find.byKey(const Key('exam-save'));
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

class _ExamSchedule extends DemoAppController {
  _ExamSchedule({
    this.examType = 'レポート',
    this.failure = _SaveFailure.none,
  });

  final String examType;
  final _SaveFailure failure;
  final updateCalls =
      <({String examId, int expectedVersion, ExamInput input})>[];

  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 9, 24)).copyWith(
          exams: [_exam],
        ),
      );

  @override
  Future<void> updateExam(
    String examId,
    int expectedVersion,
    ExamInput input,
  ) async {
    updateCalls.add((
      examId: examId,
      expectedVersion: expectedVersion,
      input: input,
    ));
    switch (failure) {
      case _SaveFailure.none:
        return;
      case _SaveFailure.conflict:
        throw const ConflictError('synthetic exam version conflict');
      case _SaveFailure.generic:
        throw StateError('synthetic exam save failure');
    }
  }

  Exam get _exam => Exam(
        id: 'exam-1',
        ownerUserId: 'owner-1',
        title: '中間試験',
        startAt: DateTime.utc(2026, 10, 1, 1),
        endAt: DateTime.utc(2026, 10, 1, 2),
        room: '教室 201',
        examType: examType,
        memo: '既存の提出範囲',
        version: 4,
      );
}
