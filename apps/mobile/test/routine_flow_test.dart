import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/calendar/presentation/routine_form_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';

DateTime jst(int year, int month, int day, [int hour = 0, int minute = 0]) {
  return JapanTime.at(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
  );
}

void main() {
  test('routine recurrence and one-off exception changes persist locally',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'routine-$idCounter',
      clock: () => jst(2026, 6, 1),
    );
    addTearDown(db.close);

    final routineId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '朝の復習',
        startAt: jst(2026, 6, 29, 9),
        endAt: jst(2026, 6, 29, 10),
        kind: EventKind.routine,
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 4,
        ),
      ),
    );
    idCounter++;

    final created = (await repository.eventsForUser(demoUserId))
        .singleWhere((event) => event.id == routineId);
    expect(created.kind, EventKind.routine);
    expect(created.recurrenceRule?.frequency, RecurrenceFrequency.weekly);
    expect(created.recurrenceRule?.count, 4);
    final rawRoutine = await (db.select(db.events)
          ..where((row) => row.id.equals(routineId)))
        .getSingle();
    expect(rawRoutine.rrule, contains('FREQ=WEEKLY'));
    expect(rawRoutine.rrule, contains('COUNT=4'));

    final exceptionId = await repository.createEventException(
      eventId: routineId,
      ownerUserId: demoUserId,
      input: EventExceptionInput(
        recurrenceId: jst(2026, 7, 6, 9),
        mode: EventExceptionMode.cancelled,
      ),
    );
    idCounter++;

    var items = await _routineItems(repository, routineId);
    expect(items.map((item) => item.startAt), [
      jst(2026, 6, 29, 9),
      jst(2026, 7, 13, 9),
      jst(2026, 7, 20, 9),
    ]);

    await repository.updateEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: demoUserId,
      input: EventExceptionInput(
        recurrenceId: jst(2026, 7, 6, 9),
        mode: EventExceptionMode.modified,
        overrideStartAt: jst(2026, 7, 6, 13),
        overrideEndAt: jst(2026, 7, 6, 14),
        overrideTitle: '朝の復習（午後）',
      ),
    );
    final exceptions = await repository.eventExceptionsForEvent(
      eventId: routineId,
      ownerUserId: demoUserId,
    );
    expect(exceptions, hasLength(1));
    expect(exceptions.single.mode, EventExceptionMode.modified);
    expect(exceptions.single.overrideTitle, '朝の復習（午後）');

    items = await _routineItems(repository, routineId);
    expect(items.map((item) => item.startAt), [
      jst(2026, 6, 29, 9),
      jst(2026, 7, 6, 13),
      jst(2026, 7, 13, 9),
      jst(2026, 7, 20, 9),
    ]);
    expect(
      items.singleWhere((item) => item.startAt == jst(2026, 7, 6, 13)).title,
      '朝の復習（午後）',
    );

    await repository.deleteEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: demoUserId,
    );
    expect(
      await repository.eventExceptionsForEvent(
        eventId: routineId,
        ownerUserId: demoUserId,
      ),
      isEmpty,
    );
    items = await _routineItems(repository, routineId);
    expect(items.map((item) => item.startAt), [
      jst(2026, 6, 29, 9),
      jst(2026, 7, 6, 9),
      jst(2026, 7, 13, 9),
      jst(2026, 7, 20, 9),
    ]);
  });

  test('routine requires exactly one valid recurrence ending rule', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'invalid-routine',
    );
    addTearDown(db.close);

    Future<String> create(RecurrenceRule rule) {
      return repository.createEvent(
        ownerUserId: demoUserId,
        input: EventInput(
          title: '検証対象',
          startAt: jst(2026, 6, 29, 9),
          endAt: jst(2026, 6, 29, 10),
          kind: EventKind.routine,
          recurrenceRule: rule,
        ),
      );
    }

    await expectLater(
      create(const RecurrenceRule(frequency: RecurrenceFrequency.daily)),
      throwsA(isA<ValidationError>()),
    );
    await expectLater(
      create(
        const RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          count: 0,
        ),
      ),
      throwsA(isA<ValidationError>()),
    );
    await expectLater(
      create(
        RecurrenceRule(
          frequency: RecurrenceFrequency.daily,
          until: jst(2026, 6, 28),
        ),
      ),
      throwsA(isA<ValidationError>()),
    );
  });

  testWidgets('routine form creates a weekly routine with a persisted RRULE',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _routineRouter(initialLocation: '/routines/new');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'ルーティン名'),
      'フォームからのルーティン',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    final routine = (await db.eventDao.eventsForUser(demoUserId)).singleWhere(
      (event) => event.title == 'フォームからのルーティン',
    );
    expect(routine.kind, EventKind.routine.name);
    expect(routine.rrule, contains('FREQ=WEEKLY'));
    expect(routine.rrule, contains('UNTIL='));
  });

  testWidgets('routine form persists weekdays-only recurrence count',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _routineRouter(initialLocation: '/routines/new');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'ルーティン名'),
      '平日3回の習慣',
    );

    final recurrenceField = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField &&
          widget.decoration.labelText == '繰り返し',
    );
    await tester.tap(recurrenceField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('平日のみ').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('回数').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '回数'),
      '3',
    );

    final saveRoutine = find.byKey(const Key('routine-save'));
    await tester.scrollUntilVisible(
      saveRoutine,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveRoutine);
    await tester.pumpAndSettle();

    final routine = (await db.eventDao.eventsForUser(demoUserId)).singleWhere(
      (event) => event.title == '平日3回の習慣',
    );
    expect(routine.rrule, contains('FREQ=WEEKDAYS'));
    expect(routine.rrule, contains('COUNT=3'));
    expect(routine.rrule, isNot(contains('UNTIL=')));
  });

  testWidgets('routine save remains above the persistent navigation bar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _routineRouter(initialLocation: '/routines/new');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final saveRoutine = find.byKey(const Key('routine-save'));
    final routineFormList = find.byKey(const Key('routine-form-list'));
    expect(routineFormList, findsOneWidget);
    final formScrollables = find.descendant(
      of: routineFormList,
      matching: find.byType(Scrollable),
    );
    expect(formScrollables, findsAtLeastNWidgets(1));
    final formScrollable = formScrollables.first;
    expect(
      tester.widget<Scrollable>(formScrollable).axisDirection,
      AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      saveRoutine,
      200,
      scrollable: formScrollable,
    );
    final scrollState = tester.state<ScrollableState>(formScrollable);
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
    await tester.pumpAndSettle();

    final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
    expect(find.byType(FloatingActionButton), findsNothing);
    final navigationBarTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    expect(tester.getTopLeft(saveRoutine).dy, greaterThan(appBarBottom));
    expect(
      tester.getBottomLeft(saveRoutine).dy,
      lessThanOrEqualTo(navigationBarTop),
    );
  });

  testWidgets('routine form exposes recurrence choices and validates count',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final router = _routineRouter(initialLocation: '/routines/new');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final recurrenceField = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField &&
          widget.decoration.labelText == '繰り返し',
    );
    await tester.tap(recurrenceField);
    await tester.pumpAndSettle();
    for (final label in ['毎日', '毎週', '隔週', '毎月', '毎月第n曜日', '平日のみ']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text('毎日').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('回数'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '回数'), '0');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final saveRoutine = find.byKey(const Key('routine-save'));
    final formScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      saveRoutine,
      200,
      scrollable: formScrollable,
    );
    await Scrollable.ensureVisible(
      tester.element(saveRoutine),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pumpAndSettle();
    await tester.tap(saveRoutine);
    await tester.pumpAndSettle();
    final scrollState = tester.state<ScrollableState>(formScrollable);
    scrollState.position.jumpTo(scrollState.position.minScrollExtent);
    await tester.pumpAndSettle();

    expect(find.text('1以上の回数を入力してください'), findsOneWidget);
  });

  testWidgets('routine exception add and delete are reachable from edit UI',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final seedRepository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'screen-routine-${idCounter++}',
    );
    final routineId = await seedRepository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '画面例外',
        startAt: jst(2026, 6, 29, 9),
        endAt: jst(2026, 6, 29, 10),
        kind: EventKind.routine,
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 3,
        ),
      ),
    );
    final router = _routineRouter(initialLocation: '/routine/$routineId/edit');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, '例外を追加'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '例外を追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '例外設定を保存'));
    await tester.pumpAndSettle();

    expect(find.text('この回を削除しますか？'), findsOneWidget);
    expect(await db.eventDao.exceptionsForEvents([routineId]), isEmpty);
    final cancellationDialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: cancellationDialog,
        matching: find.widgetWithText(FilledButton, '削除'),
      ),
    );
    await tester.pumpAndSettle();

    final rowsAfterAdd = await db.eventDao.exceptionsForEvents([routineId]);
    expect(rowsAfterAdd, hasLength(1));
    expect(rowsAfterAdd.single.mode, EventExceptionMode.cancelled.name);

    await tester.scrollUntilVisible(
      find.text('この回を削除'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この回を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '例外設定を削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '削除'));
    await tester.pumpAndSettle();

    expect(await db.eventDao.exceptionsForEvents([routineId]), isEmpty);
  });

  testWidgets('routine exception can be changed from the edit bottom sheet',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final seedRepository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'screen-modified-routine-${idCounter++}',
    );
    final routineId = await seedRepository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '画面変更例外',
        startAt: jst(2026, 6, 29, 9),
        endAt: jst(2026, 6, 29, 10),
        kind: EventKind.routine,
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 3,
        ),
      ),
    );
    final router = _routineRouter(initialLocation: '/routine/$routineId/edit');
    addTearDown(router.dispose);
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _scheduleOverrides(db),
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, '例外を追加'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '例外を追加'));
    await tester.pumpAndSettle();

    final modeField = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<EventExceptionMode> &&
          widget.decoration.labelText == 'この回の扱い',
    );
    expect(modeField, findsOneWidget);
    await tester.tap(modeField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('この回を変更'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'この回の予定名'), findsOneWidget);
    final exceptionScrollable = find.ancestor(
      of: modeField,
      matching: find.byType(Scrollable),
    );
    expect(exceptionScrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, '場所'),
      200,
      scrollable: exceptionScrollable,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '場所'),
      '変更後の教室',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '例外設定を保存'),
      200,
      scrollable: exceptionScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, '例外設定を保存'));
    await tester.pumpAndSettle();

    final exceptions = await seedRepository.eventExceptionsForEvent(
      eventId: routineId,
      ownerUserId: demoUserId,
    );
    expect(exceptions, hasLength(1));
    expect(exceptions.single.mode, EventExceptionMode.modified);
    expect(exceptions.single.overrideLocation, '変更後の教室');
  });

  testWidgets('Quick Add routes routine creation to the routine form route',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const MvpScaffold(
            title: 'テスト',
            selectedIndex: 0,
            child: SizedBox.shrink(),
          ),
        ),
        GoRoute(
          path: '/routines/new',
          builder: (_, __) => const Scaffold(body: Text('routine route')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byTooltip('追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ルーティンを追加'));
    await tester.pumpAndSettle();

    expect(find.text('routine route'), findsOneWidget);
    expect(find.text('授業を追加'), findsNothing);
  });
}

Future<List<CalendarProjectionItem>> _routineItems(
  DriftScheduleRepository repository,
  String routineId,
) async {
  final items = await repository.calendarProjection(
    ownerUserId: demoUserId,
    universityId: demoUniversityId,
    termId: demoTermId,
    rangeStart: jst(2026, 6, 29),
    rangeEnd: jst(2026, 7, 27),
  );
  return items.where((item) => item.sourceId == routineId).toList();
}

List<Override> _scheduleOverrides(local.AppDatabase db) {
  return [
    appDatabaseProvider.overrideWithValue(db),
    activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
    demoScheduleDataEnabledProvider.overrideWithValue(true),
    appClockProvider.overrideWithValue(_FixedClock(jst(2026, 6, 1, 8))),
  ];
}

GoRouter _routineRouter({required String initialLocation}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/routines/new',
        builder: (_, __) => const RoutineFormScreen(),
      ),
      GoRoute(
        path: '/routine/:id/edit',
        builder: (_, state) =>
            RoutineFormScreen(routineId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/calendar',
        builder: (_, __) => const Scaffold(body: Text('calendar')),
      ),
    ],
  );
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
