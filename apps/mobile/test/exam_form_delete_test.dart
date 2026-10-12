import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';

void main() {
  testWidgets('canceling exam deletion makes no mutation', (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule();
    final router = await _pumpExamEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    expect(find.text('テストを削除しますか？'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(schedule.deleteCalls, isEmpty);
    expect(find.text('テストを編集'), findsOneWidget);
    expect(find.text('テスト一覧へ戻りました'), findsNothing);
  });

  testWidgets('confirmed exam deletion sends loaded version then navigates',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule();
    final router = await _pumpExamEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(
      schedule.deleteCalls,
      [(examId: 'exam-1', expectedVersion: 4)],
    );
    expect(find.text('テスト一覧へ戻りました'), findsOneWidget);
  });

  testWidgets('exam delete conflict keeps form and explains recovery',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule(failure: _DeleteFailure.conflict);
    final router = await _pumpExamEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('別の変更が反映されました。画面を開き直して確認してください。'), findsOneWidget);
    expect(find.text('テストを編集'), findsOneWidget);
    expect(find.text('テスト一覧へ戻りました'), findsNothing);
    expect(schedule.deleteCalls, [(examId: 'exam-1', expectedVersion: 4)]);
  });

  testWidgets('exam delete failure keeps form and allows retry',
      (tester) async {
    _useTallViewport(tester);
    final schedule = _ExamSchedule(failure: _DeleteFailure.generic);
    final router = await _pumpExamEdit(tester, schedule);
    addTearDown(router.dispose);

    await _openDeleteConfirmation(tester);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();

    expect(find.text('削除に失敗しました。もう一度お試しください。'), findsOneWidget);
    expect(find.text('テストを編集'), findsOneWidget);
    expect(find.text('テスト一覧へ戻りました'), findsNothing);
    expect(schedule.deleteCalls, [(examId: 'exam-1', expectedVersion: 4)]);
    final deleteButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'このテストを削除'),
    );
    expect(deleteButton.onPressed, isNotNull);
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

Future<void> _openDeleteConfirmation(WidgetTester tester) async {
  final delete = find.text('このテストを削除');
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

class _ExamSchedule extends DemoAppController {
  _ExamSchedule({this.failure = _DeleteFailure.none});

  final _DeleteFailure failure;
  final deleteCalls = <({String examId, int expectedVersion})>[];

  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 9, 24)).copyWith(
          exams: [_exam],
        ),
      );

  @override
  Future<void> deleteExam(String examId, int expectedVersion) async {
    deleteCalls.add((examId: examId, expectedVersion: expectedVersion));
    switch (failure) {
      case _DeleteFailure.none:
        return;
      case _DeleteFailure.conflict:
        throw const ConflictError('synthetic exam version conflict');
      case _DeleteFailure.generic:
        throw StateError('synthetic exam delete failure');
    }
  }
}

final _exam = Exam(
  id: 'exam-1',
  ownerUserId: 'owner-1',
  title: '中間試験',
  startAt: DateTime.utc(2026, 10, 1, 1),
  endAt: DateTime.utc(2026, 10, 1, 2),
  room: '教室 201',
  examType: 'レポート',
  version: 4,
);
