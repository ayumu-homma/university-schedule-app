import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/features/calendar/presentation/event_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  testWidgets('event form persists explicit calendar inheritance as NULL',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 3120);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _router(initialLocation: '/events/new');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '予定名'),
      '継承する予定',
    );
    await tester.tap(find.byKey(const Key('event-visibility')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('カレンダーの設定に従う').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('event-save')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('event-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('後で'));
    await tester.pumpAndSettle();

    final created = (await db.eventDao.eventsForUser(demoUserId))
        .singleWhere((event) => event.title == '継承する予定');
    expect(created.visibilityLevel, isNull);
    final mutation = await db.customSelect(
      "SELECT payload_json FROM sync_queue_entries WHERE entity_id = ?",
      variables: [
        Variable.withString(created.id),
      ],
    ).getSingle();
    expect(mutation.read<String>('payload_json'),
        contains('"visibilityLevel":null'));

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('CI-sized event form saves through the real interactive surface',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 3120);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _router(initialLocation: '/events/new');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '予定名'),
      'フォームから追加',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '場所'),
      'CI viewport',
    );
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    final formList = find.byKey(const Key('event-form-list'));
    final formScrollables = find.descendant(
      of: formList,
      matching: find.byType(Scrollable),
    );
    final saveAction = find.descendant(
      of: formList,
      matching: find.byKey(const Key('event-save')),
    );
    expect(formList, findsOneWidget);
    expect(formScrollables, findsAtLeastNWidgets(1));
    await tester.scrollUntilVisible(
      saveAction,
      200,
      scrollable: formScrollables.first,
    );
    await tester.pump();
    expect(saveAction, findsOneWidget);
    expect(tester.widget<FilledButton>(saveAction).onPressed, isNotNull);
    final interactiveSaveSurface = find
        .descendant(of: saveAction, matching: find.byType(InkWell))
        .hitTestable();
    expect(interactiveSaveSurface, findsOneWidget);
    await tester.tap(interactiveSaveSurface);
    await tester.pumpAndSettle();

    expect(find.text('予定通知を有効にしますか？'), findsOneWidget);
    await tester.tap(find.text('後で'));
    await tester.pumpAndSettle();
    expect(find.text('calendar'), findsOneWidget);
    final events = await db.eventDao.eventsForUser(demoUserId);
    final created = events.singleWhere((event) => event.title == 'フォームから追加');
    expect(created.calendarId, demoPersonalCalendarId);
    expect(created.location, 'CI viewport');
    expect(created.visibilityLevel, 'PRIVATE');
    expect(created.deletedAt, isNull);
    final prompts = await db
        .customSelect(
          'SELECT owner_user_id, prompt_key '
          'FROM local_notification_permission_prompts',
        )
        .get();
    expect(prompts, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('Event form confirms a soft delete', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'form-${idCounter++}',
    );
    final eventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '削除対象予定',
        startAt: DateTime(2026, 7, 12, 10),
        endAt: DateTime(2026, 7, 12, 11),
      ),
    );
    final router = _router(initialLocation: '/event/$eventId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('この予定を削除'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final deleteButton = find.widgetWithText(OutlinedButton, 'この予定を削除');
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();

    final active = await db.eventDao.eventsForUser(demoUserId);
    final raw = await (db.select(db.events)
          ..where((event) => event.id.equals(eventId)))
        .getSingle();
    expect(active.map((event) => event.id), isNot(contains(eventId)));
    expect(raw.deletedAt, isNotNull);
    expect(raw.version, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await db.close();
  });

  testWidgets('Event form rejects stale fields after a reactive refresh',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'stale-form-${idCounter++}',
    );
    final eventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '初期予定',
        startAt: DateTime(2026, 7, 12, 10),
        endAt: DateTime(2026, 7, 12, 11),
      ),
    );
    final router = _router(initialLocation: '/event/$eventId/edit');

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '予定名'),
      '古いフォームの編集',
    );

    await repository.updateEvent(
      eventId: eventId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
      input: EventInput(
        title: '外部更新済み',
        startAt: DateTime(2026, 7, 12, 12),
        endAt: DateTime(2026, 7, 12, 13),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final event = (await repository.eventsForUser(demoUserId))
        .singleWhere((item) => item.id == eventId);
    expect(event.title, '外部更新済み');
    expect(event.version, 2);
    expect(
      find.text('別の変更が反映されました。画面を開き直して確認してください。'),
      findsOneWidget,
    );

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
        path: '/events/new',
        builder: (context, state) => const EventFormScreen(),
      ),
      GoRoute(
        path: '/event/:id/edit',
        builder: (context, state) =>
            EventFormScreen(eventId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/calendar',
        builder: (context, state) => const Scaffold(body: Text('calendar')),
      ),
    ],
  );
}
