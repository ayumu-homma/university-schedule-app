import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/assignment/presentation/assignment_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:drift/drift.dart' hide isNotNull, isNull;

void main() {
  testWidgets('URL・公開範囲・提出状態を編集フォームで保持する', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '保持対象の課題',
        dueAt: DateTime.utc(2026, 10, 3, 12),
        submissionUrl: 'https://lms.example.edu/keep',
        memo: '画面に残るメモ',
        priority: 'high',
        visibilityLevel: VisibilityLevel.titleOnly,
      ),
    );
    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: demoUserId,
      status: AssignmentStatus.inProgress,
      updatedAt: DateTime.utc(2026, 9, 18, 1),
    );
    await db.into(db.assignmentUserStates).insertOnConflictUpdate(
          local.AssignmentUserStatesCompanion.insert(
            assignmentId: assignmentId,
            userId: demoUserId,
            status: const Value('submitted'),
            submittedAt: Value(DateTime.utc(2026, 9, 18, 1)),
            note: const Value('個人の提出メモ'),
            updatedAt: Value(DateTime.utc(2026, 9, 18, 1)),
            deletedAt: const Value(null),
            version: const Value(2),
          ),
        );

    final router = _router('/assignment/$assignmentId/edit');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(
      find.widgetWithText(TextFormField, '課題名'),
      '編集後も保持する課題',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('assignment-save'));
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();

    final row = await (db.select(db.assignments)
          ..where((item) => item.id.equals(assignmentId)))
        .getSingle();
    expect(row.title, '編集後も保持する課題');
    expect(row.submissionUrl, 'https://lms.example.edu/keep');
    expect(row.visibilityLevel, VisibilityLevel.titleOnly.wireName);
    expect(row.description, '画面に残るメモ');
    expect(row.priority, 'high');
    final state =
        (await repository.assignmentStatesForUser(demoUserId))[assignmentId];
    expect(state?.status, AssignmentStatus.submitted);
    expect(state?.note, '個人の提出メモ');
  });

  testWidgets('新規課題は締切未設定で保存できず、授業起点を変更できる', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoScheduleContext.termId,
      input: const UserCourseInput(
        title: '継承して変更できる授業',
        dayOfWeek: DateTime.tuesday,
        periodNo: 2,
      ),
    );
    final router = _router('/assignments/new?courseId=$courseId');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('日付と時刻を選択してください · 必須'), findsOneWidget);
    expect(find.text('継承して変更できる授業'), findsOneWidget);
    expect(find.text('授業起点から引き継いでいます。必要なら変更できます。'), findsOneWidget);
    expect(find.text('提出URL'), findsNothing);

    await tester.tap(_dropdownFormField('授業'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('なし').last);
    await tester.pumpAndSettle();
    expect(find.text('授業起点から引き継いでいます。必要なら変更できます。'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextFormField, '課題名'),
      '締切必須の新規課題',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('assignment-save'));
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('締切の日付と時刻を選択してください。'), findsOneWidget);
  });

  testWidgets('締切の日付選択をキャンセルすると保存済み値を保つ', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: '締切取消テスト',
        dueAt: DateTime.utc(2026, 10, 3, 12),
      ),
    );
    final router = _router('/assignment/$assignmentId/edit');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2026/10/3 21:00 · 必須'), findsOneWidget);
    await tester.tap(find.byKey(const Key('assignment-due-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('2026/10/3 21:00 · 必須'), findsOneWidget);
  });

  testWidgets('空の授業クエリは授業なしとして安全に扱う', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router('/assignments/new?courseId=');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(_dropdownFormField('授業'), findsOneWidget);
    expect(find.text('なし'), findsOneWidget);
    expect(find.text('授業起点から引き継いでいます。必要なら変更できます。'), findsNothing);
  });

  testWidgets('作成・編集フォームはIME表示中のスクロールでフォーカスを保つ', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = DriftScheduleRepository(db, enableDemoData: true);
    final assignmentId = await repository.createAssignment(
      ownerUserId: demoUserId,
      input: AssignmentInput(
        title: 'IME表示中の編集課題',
        dueAt: DateTime.utc(2026, 10, 3, 12),
      ),
    );
    final router = _router('/assignments/new');
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: const EdgeInsets.only(bottom: 320),
            ),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final location in [
      '/assignments/new',
      '/assignment/$assignmentId/edit',
    ]) {
      router.go(location);
      await tester.pumpAndSettle();
      final title = find.widgetWithText(TextFormField, '課題名');
      final titleEditable = find.descendant(
        of: title,
        matching: find.byType(EditableText),
      );
      await tester.showKeyboard(title);
      await tester.pump();
      final titleFocusNode =
          tester.widget<EditableText>(titleEditable).focusNode;
      expect(titleFocusNode.hasFocus, isTrue);

      await tester.drag(
        find.byKey(const Key('assignment-form-list')),
        const Offset(0, -500),
      );
      await tester.pump();

      expect(titleFocusNode.hasFocus, isTrue);
      final save = find.byKey(const Key('assignment-save'));
      await tester.ensureVisible(save);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(
        tester.getBottomLeft(save).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(NavigationBar)).dy),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      tester.testTextInput.hide();
      await tester.pump();
    }
  });

  testWidgets('未知の授業クエリは選び直せる削除済み授業として扱う', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = _router('/assignments/new?courseId=missing-course');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('元の授業は削除されています。授業を「なし」または別の授業に変更してから保存してください。'),
      findsOneWidget,
    );
    expect(find.text('削除済みの授業（選び直してください）'), findsOneWidget);
    expect(find.text('授業起点から引き継いでいます。必要なら変更できます。'), findsNothing);
  });
}

List<Override> _overrides(local.AppDatabase db) => [
      appDatabaseProvider.overrideWithValue(db),
      activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
      demoScheduleDataEnabledProvider.overrideWithValue(true),
    ];

GoRouter _router(String initialLocation) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/assignments/new',
          builder: (_, state) => AssignmentFormScreen(
            initialCourseId: state.uri.queryParameters['courseId'],
          ),
        ),
        GoRoute(
          path: '/assignment/:id/edit',
          builder: (_, state) => AssignmentFormScreen(
            assignmentId: state.pathParameters['id'],
          ),
        ),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const Scaffold(body: Text('assignments')),
        ),
      ],
    );

Finder _dropdownFormField(String label) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.decoration.labelText == label,
  );
}
