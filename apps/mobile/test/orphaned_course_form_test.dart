import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_form_screen.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

const _orphanedCourseNotice = '元の授業は削除されています。授業を「なし」または別の授業に変更してから保存してください。';
const _orphanedCourseSaveError = '削除済みの授業を「なし」または別の授業に変更してください。';

void main() {
  testWidgets('exam save remains within the Android safe tap area',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _router(initialLocation: '/exams/new');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final saveExam = find.byKey(const Key('exam-save'));
    final formScrollable = find.ancestor(
      of: saveExam,
      matching: find.byType(Scrollable),
    );
    expect(formScrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      saveExam,
      200,
      scrollable: formScrollable,
    );
    final scrollState = tester.state<ScrollableState>(formScrollable);
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final appBar = find.byType(AppBar);
    final navigationBar = find.byType(NavigationBar);
    expect(appBar, findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(navigationBar, findsOneWidget);

    final appBarBottom = tester.getBottomLeft(appBar).dy;
    final navigationBarTop = tester.getTopLeft(navigationBar).dy;
    expect(tester.getTopLeft(saveExam).dy, greaterThan(appBarBottom));
    expect(
      tester.getBottomLeft(saveExam).dy,
      lessThanOrEqualTo(navigationBarTop),
    );
  });

  testWidgets(
      'assignment form requires explicit resolution of a deleted course',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoScheduleContext.termId,
      input: const UserCourseInput(
        title: '削除済み授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '紐付けを解除する課題',
        dueAt: DateTime.utc(2026, 7, 20, 12),
        courseId: courseId,
      ),
    );
    await repository.deleteUserCourse(
      courseId: courseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );
    final router = _router(initialLocation: '/assignment/$assignmentId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_orphanedCourseNotice), findsOneWidget);
    expect(find.text('削除済みの授業（選び直してください）'), findsOneWidget);
    expect(_dropdownFormField('授業'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, '課題名'),
      '更新した課題',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text(_orphanedCourseSaveError), findsOneWidget);
    final unresolved = await (db.select(db.assignments)
          ..where((row) => row.id.equals(assignmentId)))
        .getSingle();
    expect(unresolved.courseId, courseId);
    expect(unresolved.title, '紐付けを解除する課題');

    await tester.ensureVisible(_dropdownFormField('授業'));
    await tester.drag(find.byType(ListView).first, const Offset(0, 96));
    await tester.pump();
    await tester.tap(_dropdownFormField('授業'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('なし').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final updated = await (db.select(db.assignments)
          ..where((row) => row.id.equals(assignmentId)))
        .getSingle();
    expect(updated.courseId, isNull);
    expect(updated.title, '更新した課題');

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('exam form requires explicit resolution of a deleted course',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoScheduleContext.termId,
      input: const UserCourseInput(
        title: '削除済み授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    final examId = await repository.createExam(
      ownerUserId: demoUserId,
      input: ExamInput(
        title: '紐付けを解除するテスト',
        startAt: DateTime.utc(2026, 7, 20, 12),
        endAt: DateTime.utc(2026, 7, 20, 13),
        courseId: courseId,
      ),
    );
    await repository.deleteUserCourse(
      courseId: courseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );
    final router = _router(initialLocation: '/exam/$examId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_orphanedCourseNotice), findsOneWidget);
    expect(find.text('削除済みの授業（選び直してください）'), findsOneWidget);
    expect(_dropdownFormField('授業'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'テスト名'),
      '更新したテスト',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text(_orphanedCourseSaveError), findsOneWidget);
    final unresolved = await (db.select(db.exams)
          ..where((row) => row.id.equals(examId)))
        .getSingle();
    expect(unresolved.courseId, courseId);
    expect(unresolved.title, '紐付けを解除するテスト');

    await tester.ensureVisible(_dropdownFormField('授業'));
    await tester.drag(find.byType(ListView).first, const Offset(0, 96));
    await tester.pump();
    await tester.tap(_dropdownFormField('授業'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('なし').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final updated = await (db.select(db.exams)
          ..where((row) => row.id.equals(examId)))
        .getSingle();
    expect(updated.courseId, isNull);
    expect(updated.title, '更新したテスト');

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('assignment form retains a cross-term active course link',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: 'previous-term',
      input: const UserCourseInput(
        title: '別学期の有効な授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '別学期に紐づく課題',
        dueAt: DateTime.utc(2026, 7, 20, 12),
        courseId: courseId,
      ),
    );
    final router = _router(initialLocation: '/assignment/$assignmentId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_orphanedCourseNotice), findsNothing);
    expect(find.text('別学期の有効な授業'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, '課題名'),
      '別学期の紐付けを保つ課題',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final updated = await (db.select(db.assignments)
          ..where((row) => row.id.equals(assignmentId)))
        .getSingle();
    expect(updated.courseId, courseId);
    expect(updated.title, '別学期の紐付けを保つ課題');

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('exam form retains a cross-term active course link',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: 'previous-term',
      input: const UserCourseInput(
        title: '別学期の有効な授業',
        dayOfWeek: DateTime.monday,
        periodNo: 1,
      ),
    );
    final examId = await repository.createExam(
      ownerUserId: demoUserId,
      input: ExamInput(
        title: '別学期に紐づくテスト',
        startAt: DateTime.utc(2026, 7, 20, 12),
        endAt: DateTime.utc(2026, 7, 20, 13),
        courseId: courseId,
      ),
    );
    final router = _router(initialLocation: '/exam/$examId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(_orphanedCourseNotice), findsNothing);
    expect(find.text('別学期の有効な授業'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'テスト名'),
      '別学期の紐付けを保つテスト',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final updated = await (db.select(db.exams)
          ..where((row) => row.id.equals(examId)))
        .getSingle();
    expect(updated.courseId, courseId);
    expect(updated.title, '別学期の紐付けを保つテスト');

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });
}

List<Override> _scheduleOverrides(local.AppDatabase db) {
  return [
    appDatabaseProvider.overrideWithValue(db),
    activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
    demoScheduleDataEnabledProvider.overrideWithValue(true),
  ];
}

GoRouter _router({required String initialLocation}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/assignment/:id/edit',
        builder: (context, state) =>
            AssignmentFormScreen(assignmentId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/exam/:id/edit',
        builder: (context, state) =>
            ExamFormScreen(examId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/exams/new',
        builder: (context, state) => const ExamFormScreen(),
      ),
      GoRoute(
        path: '/assignments',
        builder: (context, state) => const Scaffold(body: Text('assignments')),
      ),
      GoRoute(
        path: '/exams',
        builder: (context, state) => const Scaffold(body: Text('exams')),
      ),
    ],
  );
}

Finder _dropdownFormField(String label) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == label,
    description: 'DropdownButtonFormField labeled $label',
  );
}
