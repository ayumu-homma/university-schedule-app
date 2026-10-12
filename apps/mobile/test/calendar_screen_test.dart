import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/calendar/presentation/calendar_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart'
    show ActiveScheduleContext, activeScheduleContextProvider;
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  final now = DateTime(2026, 7, 15, 12);

  testWidgets('狭いAndroid画面で表示切り替えがオーバーフローしない', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_testApp(state: _state(now: now), now: now));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('月'), findsOneWidget);
    expect(find.text('リスト'), findsOneWidget);
    expect(find.byKey(const Key('calendar-scroll-list')), findsOneWidget);
  });

  testWidgets('月・週・日・リスト表示が対象期間を切り替える', (tester) async {
    final state = _state(
      now: now,
      calendarItems: [
        _item(
          'ended-today',
          '今日終了した予定',
          DateTime(2026, 7, 15, 9),
        ),
        _item('today', '今日の予定', DateTime(2026, 7, 15, 13)),
        _item('week', '今週の予定', DateTime(2026, 7, 17, 13)),
        _item('month', '今月の予定', DateTime(2026, 7, 22, 13)),
        _item('next-month', '来月の予定', DateTime(2026, 8, 2, 13)),
      ],
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    expect(find.text('今後90日間の予定'), findsOneWidget);
    expect(find.text('今日終了した予定'), findsNothing);
    expect(find.text('今日の予定'), findsOneWidget);
    expect(find.text('今週の予定'), findsOneWidget);
    expect(find.text('4件'), findsOneWidget);

    await tester.tap(find.text('日'));
    await tester.pump();
    expect(find.text('今日終了した予定'), findsOneWidget);
    expect(find.text('今日の予定'), findsOneWidget);
    expect(find.text('今週の予定'), findsNothing);
    expect(find.text('2件'), findsOneWidget);

    await tester.tap(find.text('週'));
    await tester.pump();
    expect(find.text('今日終了した予定'), findsOneWidget);
    expect(find.text('今週の予定'), findsOneWidget);
    expect(find.text('今月の予定'), findsNothing);
    expect(find.text('3件'), findsOneWidget);

    await tester.tap(find.text('月'));
    await tester.pump();
    expect(find.text('今日終了した予定'), findsOneWidget);
    expect(find.text('今週の予定'), findsOneWidget);
    expect(find.text('4件'), findsOneWidget);
  });

  testWidgets('表示モードごとに意味のある空状態を表示する', (tester) async {
    await tester.pumpWidget(_testApp(state: _state(now: now), now: now));
    await tester.pumpAndSettle();

    expect(find.text('今後90日間の予定はありません'), findsOneWidget);

    await tester.tap(find.text('日'));
    await tester.pump();
    expect(find.text('今日の予定はありません'), findsOneWidget);

    await tester.tap(find.text('週'));
    await tester.pump();
    expect(find.text('今週の予定はありません'), findsOneWidget);

    await tester.tap(find.text('月'));
    await tester.pump();
    expect(find.text('今月の予定はありません'), findsOneWidget);
  });

  testWidgets('種別フィルタで授業・課題・テスト・個人予定を絞り込む', (tester) async {
    final preferenceStream =
        StreamController<CalendarFilterPreferencesSnapshot>(sync: true);
    addTearDown(preferenceStream.close);
    final state = _state(
      now: now,
      calendarItems: [
        _item(
          'course',
          '授業予定',
          DateTime(2026, 7, 16, 9),
          kind: EventKind.course,
        ),
        _item(
          'assignment',
          '課題締切',
          DateTime(2026, 7, 16, 10),
          kind: EventKind.assignmentDeadline,
        ),
        _item(
          'exam',
          '期末テスト',
          DateTime(2026, 7, 16, 11),
          kind: EventKind.exam,
        ),
        _item(
          'normal',
          '友人との約束',
          DateTime(2026, 7, 16, 12),
        ),
        _item(
          'routine',
          '繰り返しの個人予定',
          DateTime(2026, 7, 16, 13),
          kind: EventKind.routine,
        ),
      ],
    );

    await tester.pumpWidget(
      _testApp(
        state: state,
        now: now,
        preferenceStream: preferenceStream.stream,
      ),
    );
    await tester.pump();
    preferenceStream.add(_filterSnapshot(_scheduleContext));
    await _pumpLoadedFilterUpdate(tester);

    expect(find.text('授業予定'), findsOneWidget);
    expect(find.text('課題締切'), findsOneWidget);
    expect(find.text('期末テスト'), findsOneWidget);

    preferenceStream.add(
      _filterSnapshot(
        _scheduleContext,
        const CalendarFilterPreferences(showCourses: false),
      ),
    );
    await _pumpLoadedFilterUpdate(tester);
    expect(find.text('授業予定'), findsNothing);
    expect(find.text('課題締切'), findsOneWidget);

    preferenceStream.add(
      _filterSnapshot(
        _scheduleContext,
        const CalendarFilterPreferences(
          showCourses: false,
          showAssignmentDeadlines: false,
        ),
      ),
    );
    await _pumpLoadedFilterUpdate(tester);
    expect(find.text('課題締切'), findsNothing);
    expect(find.text('期末テスト'), findsOneWidget);

    preferenceStream.add(
      _filterSnapshot(
        _scheduleContext,
        const CalendarFilterPreferences(
          showCourses: false,
          showAssignmentDeadlines: false,
          showExams: false,
        ),
      ),
    );
    await _pumpLoadedFilterUpdate(tester);
    expect(find.text('期末テスト'), findsNothing);
    expect(find.text('友人との約束'), findsOneWidget);
    expect(find.text('繰り返しの個人予定'), findsOneWidget);

    preferenceStream.add(
      _filterSnapshot(
        _scheduleContext,
        const CalendarFilterPreferences(
          showCourses: false,
          showAssignmentDeadlines: false,
          showExams: false,
          showPersonalEvents: false,
        ),
      ),
    );
    await _pumpLoadedFilterUpdate(tester);
    expect(find.text('友人との約束'), findsNothing);
    expect(find.text('繰り返しの個人予定'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('保存済みフィルタはProvider再作成後もownerごとに復元する', (tester) async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final state = _state(
      now: now,
      calendarItems: [
        _item(
          'course',
          '保存済みの授業',
          DateTime(2026, 7, 16, 9),
          kind: EventKind.course,
        ),
        _item(
          'assignment',
          '保存済みの課題',
          DateTime(2026, 7, 16, 10),
          kind: EventKind.assignmentDeadline,
        ),
      ],
    );
    await database.calendarDisplayPreferencesDao.savePreferences(
      ownerUserId: _scheduleContext.ownerUserId,
      showCourses: false,
      showAssignmentDeadlines: true,
      showExams: true,
      showPersonalEvents: true,
      updatedAt: DateTime.utc(2026, 7, 18, 9),
    );
    final ownerAFirstSnapshot = await _databaseSnapshot(
      database,
      _scheduleContext,
    );

    await tester.pumpWidget(
      _testApp(
        state: state,
        now: now,
        preferenceStream: Stream.value(ownerAFirstSnapshot),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存済みの授業'), findsNothing);
    expect(find.text('保存済みの課題'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final ownerARecreatedSnapshot = await _databaseSnapshot(
      database,
      _scheduleContext,
    );
    await tester.pumpWidget(
      _testApp(
        state: state,
        now: now,
        preferenceStream: Stream.value(ownerARecreatedSnapshot),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存済みの授業'), findsNothing);
    expect(find.text('保存済みの課題'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final ownerBSnapshot = await _databaseSnapshot(
      database,
      _secondScheduleContext,
    );
    await tester.pumpWidget(
      _testApp(
        state: state,
        now: now,
        scheduleContext: _secondScheduleContext,
        preferenceStream: Stream.value(ownerBSnapshot),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存済みの授業'), findsOneWidget);
    expect(find.text('保存済みの課題'), findsOneWidget);
    expect(
      await database.calendarDisplayPreferencesDao
          .preferencesForOwner(_secondScheduleContext.ownerUserId),
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('保存済みフィルタを実providerが再作成後もownerごとに復元する', () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    ProviderContainer? firstContainer;
    ProviderContainer? recreatedContainer;
    ProviderContainer? otherOwnerContainer;
    try {
      await database.calendarDisplayPreferencesDao.savePreferences(
        ownerUserId: _scheduleContext.ownerUserId,
        showCourses: false,
        showAssignmentDeadlines: true,
        showExams: false,
        showPersonalEvents: false,
        updatedAt: DateTime.utc(2026, 7, 18, 9),
      );

      firstContainer = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          activeScheduleContextProvider.overrideWithValue(_scheduleContext),
        ],
      );
      final firstSnapshot =
          await firstContainer.read(calendarFilterPreferencesProvider.future);
      expect(firstSnapshot.ownerUserId, _scheduleContext.ownerUserId);
      expect(firstSnapshot.preferences!.showCourses, isFalse);
      expect(firstSnapshot.preferences!.showExams, isFalse);
      expect(firstSnapshot.preferences!.showPersonalEvents, isFalse);
      firstContainer.dispose();
      firstContainer = null;

      recreatedContainer = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          activeScheduleContextProvider.overrideWithValue(_scheduleContext),
        ],
      );
      final recreatedSnapshot = await recreatedContainer
          .read(calendarFilterPreferencesProvider.future);
      expect(recreatedSnapshot.ownerUserId, _scheduleContext.ownerUserId);
      expect(recreatedSnapshot.preferences!.showCourses, isFalse);
      expect(recreatedSnapshot.preferences!.showAssignmentDeadlines, isTrue);

      otherOwnerContainer = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          activeScheduleContextProvider.overrideWithValue(
            _secondScheduleContext,
          ),
        ],
      );
      final otherOwnerSnapshot = await otherOwnerContainer
          .read(calendarFilterPreferencesProvider.future);
      expect(
          otherOwnerSnapshot.ownerUserId, _secondScheduleContext.ownerUserId);
      expect(otherOwnerSnapshot.preferences, isNull);
    } finally {
      firstContainer?.dispose();
      recreatedContainer?.dispose();
      otherOwnerContainer?.dispose();
      await database.close();
    }
  });

  testWidgets('有効な種別チップは実providerを通じてownerの設定を保存する', (tester) async {
    final state = _state(
      now: now,
      calendarItems: [
        _item(
          'course',
          '保存対象の授業',
          DateTime(2026, 7, 16, 9),
          kind: EventKind.course,
        ),
      ],
    );
    local.AppDatabase? database;
    ProviderContainer? container;
    ProviderSubscription<AsyncValue<CalendarFilterPreferencesSnapshot>>?
        preferencesSubscription;

    try {
      final initialSnapshot = await tester.runAsync(
        () async {
          database = local.AppDatabase(NativeDatabase.memory());
          container = ProviderContainer(
            overrides: [
              appClockProvider.overrideWithValue(_FixedClock(now)),
              appDatabaseProvider.overrideWithValue(database!),
              activeScheduleContextProvider.overrideWithValue(_scheduleContext),
              demoAppControllerProvider.overrideWith(
                () => _TestDemoAppController(state),
              ),
            ],
          );
          preferencesSubscription = container!.listen(
            calendarFilterPreferencesProvider,
            (_, __) {},
          );
          return container!.read(calendarFilterPreferencesProvider.future);
        },
      );
      expect(initialSnapshot, isNotNull);
      expect(initialSnapshot!.ownerUserId, _scheduleContext.ownerUserId);
      expect(initialSnapshot.preferences, isNull);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: const MaterialApp(home: CalendarScreen()),
        ),
      );
      await tester.pump();
      expect(find.text('表示設定を読み込み中です'), findsNothing);
      expect(find.text('保存対象の授業'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '授業'))
            .onSelected,
        isNotNull,
      );

      await tester.tap(find.widgetWithText(FilterChip, '授業'));
      await tester.pump();
      final saved = await tester.runAsync(
        () => database!.calendarDisplayPreferencesDao
            .watchForOwner(_scheduleContext.ownerUserId)
            .firstWhere((preference) => preference?.showCourses == false),
      );
      expect(saved, isNotNull);
      expect(saved!.showCourses, isFalse);
      expect(saved.showAssignmentDeadlines, isTrue);
      expect(saved.showExams, isTrue);
      expect(saved.showPersonalEvents, isTrue);

      await tester.pump();
      expect(find.text('保存対象の授業'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        preferencesSubscription?.close();
        container?.dispose();
        await database?.close();
      });
    }
  });

  testWidgets('表示設定の読み込み中は変更できず、読み込み後の値を反映する', (tester) async {
    final database = local.AppDatabase(NativeDatabase.memory());
    final preferenceStream =
        StreamController<CalendarFilterPreferencesSnapshot>(sync: true);
    addTearDown(preferenceStream.close);
    addTearDown(database.close);
    await database.calendarDisplayPreferencesDao.savePreferences(
      ownerUserId: _scheduleContext.ownerUserId,
      showCourses: false,
      showAssignmentDeadlines: true,
      showExams: true,
      showPersonalEvents: true,
      updatedAt: DateTime.utc(2026, 7, 18, 9),
    );
    final state = _state(
      now: now,
      calendarItems: [
        _item(
          'course',
          '読み込み対象の授業',
          DateTime(2026, 7, 16, 9),
          kind: EventKind.course,
        ),
      ],
    );

    await tester.pumpWidget(
      _testApp(
        state: state,
        now: now,
        preferenceStream: preferenceStream.stream,
      ),
    );
    await tester.pump();

    expect(find.text('表示設定を読み込み中です'), findsOneWidget);
    final loadingChip =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, '授業'));
    expect(loadingChip.onSelected, isNull);
    await tester.tap(find.widgetWithText(FilterChip, '授業'));
    await tester.pump();
    final beforeLoad = await database.calendarDisplayPreferencesDao
        .preferencesForOwner(_scheduleContext.ownerUserId);
    expect(beforeLoad!.showCourses, isFalse);

    preferenceStream.add(
      _filterSnapshot(
        _scheduleContext,
        const CalendarFilterPreferences(showCourses: false),
      ),
    );
    await _pumpLoadedFilterUpdate(tester);

    expect(find.text('表示設定を読み込み中です'), findsNothing);
    final loadedChip =
        tester.widget<FilterChip>(find.widgetWithText(FilterChip, '授業'));
    expect(loadedChip.onSelected, isNotNull);
    expect(find.text('読み込み対象の授業'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('ルーティンの発生回を編集画面へ開ける', (tester) async {
    const routineId = 'routine-calendar-item';
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const CalendarScreen()),
        GoRoute(
          path: '/routine/:id/edit',
          builder: (_, state) => Scaffold(
            body: Text('routine:${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appClockProvider.overrideWithValue(_FixedClock(now)),
          activeScheduleContextProvider.overrideWithValue(_scheduleContext),
          calendarFilterPreferencesProvider.overrideWith(
            (ref) => Stream.value(_filterSnapshot(_scheduleContext)),
          ),
          demoAppControllerProvider.overrideWith(
            () => _TestDemoAppController(
              _state(
                now: now,
                calendarItems: [
                  CalendarProjectionItem(
                    sourceId: routineId,
                    kind: EventKind.routine,
                    title: '毎週の復習',
                    startAt: DateTime(2026, 7, 16, 9),
                    endAt: DateTime(2026, 7, 16, 10),
                  ),
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('毎週の復習'));
    await tester.pumpAndSettle();

    expect(find.text('routine:$routineId'), findsOneWidget);
  });
}

Widget _testApp({
  required DemoAppState state,
  required DateTime now,
  ActiveScheduleContext scheduleContext = _scheduleContext,
  Stream<CalendarFilterPreferencesSnapshot>? preferenceStream,
}) {
  return ProviderScope(
    overrides: [
      appClockProvider.overrideWithValue(_FixedClock(now)),
      activeScheduleContextProvider.overrideWithValue(scheduleContext),
      calendarFilterPreferencesProvider.overrideWith(
        (ref) =>
            preferenceStream ?? Stream.value(_filterSnapshot(scheduleContext)),
      ),
      demoAppControllerProvider.overrideWith(
        () => _TestDemoAppController(state),
      ),
    ],
    child: const MaterialApp(home: CalendarScreen()),
  );
}

Future<void> _pumpLoadedFilterUpdate(WidgetTester tester) async {
  await tester.pump();
}

Future<CalendarFilterPreferencesSnapshot> _databaseSnapshot(
  local.AppDatabase database,
  ActiveScheduleContext scheduleContext,
) async {
  final preference = await database.calendarDisplayPreferencesDao
      .preferencesForOwner(scheduleContext.ownerUserId);
  return CalendarFilterPreferencesSnapshot(
    ownerUserId: scheduleContext.ownerUserId,
    preferences: preference == null
        ? null
        : CalendarFilterPreferences.fromDatabase(preference),
  );
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

class _TestDemoAppController extends DemoAppController {
  _TestDemoAppController(this.initialState);

  final DemoAppState initialState;

  @override
  Stream<DemoAppState> build() => Stream.value(initialState);
}

CalendarProjectionItem _item(
  String id,
  String title,
  DateTime startAt, {
  EventKind kind = EventKind.normal,
}) =>
    CalendarProjectionItem(
      sourceId: id,
      kind: kind,
      title: title,
      startAt: startAt,
      endAt: startAt.add(const Duration(hours: 1)),
    );

const _scheduleContext = ActiveScheduleContext(
  ownerUserId: 'calendar-test-owner',
  universityId: 'calendar-test-university',
  termId: 'calendar-test-term',
  academicYear: 2026,
  primaryCalendarId: 'calendar-test-primary',
);

const _secondScheduleContext = ActiveScheduleContext(
  ownerUserId: 'calendar-test-owner-b',
  universityId: 'calendar-test-university',
  termId: 'calendar-test-term',
  academicYear: 2026,
  primaryCalendarId: 'calendar-test-primary-b',
);

CalendarFilterPreferencesSnapshot _filterSnapshot(
  ActiveScheduleContext context, [
  CalendarFilterPreferences? preferences,
]) {
  return CalendarFilterPreferencesSnapshot(
    ownerUserId: context.ownerUserId,
    preferences: preferences ?? const CalendarFilterPreferences(),
  );
}

DemoAppState _state({
  required DateTime now,
  List<CalendarProjectionItem> calendarItems = const [],
}) {
  return DemoAppState(
    templates: const [],
    periodSettings: const [],
    courses: const [],
    assignments: const [],
    assignmentStates: const {},
    exams: const [],
    events: const [],
    eventExceptions: const [],
    calendarItems: calendarItems,
    widgetSnapshot: WidgetSnapshot.empty(now),
    pendingMutations: const [],
    syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
  );
}
