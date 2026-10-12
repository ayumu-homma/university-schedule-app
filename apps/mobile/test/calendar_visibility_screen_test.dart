import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/calendar/data/calendar_visibility_repository.dart';
import 'package:university_schedule_mobile/features/calendar/presentation/calendar_visibility_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  testWidgets('personal calendar default authoring persists explicit NULL',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.calendars).insert(
          local.CalendarsCompanion.insert(
            id: 'calendar-owner',
            ownerUserId: 'owner',
            groupId: const Value(null),
            name: 'Personal',
            defaultVisibility: const Value('PRIVATE'),
          ),
        );
    final repository = CalendarVisibilityRepository(
      database: db,
      client: null,
      demoMode: true,
      ownerUserId: 'owner',
      calendarId: 'calendar-owner',
      currentUserId: () => null,
      currentScheduleOwnerId: () => 'owner',
      clock: () => DateTime.utc(2026, 9, 28),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          calendarVisibilityRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: CalendarVisibilityScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('カレンダーの公開範囲'), findsOneWidget);
    await tester.tap(find.byKey(const Key('calendar-default-visibility')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('詳細まで').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-calendar-default-visibility')));
    await tester.pumpAndSettle();
    expect(
      (await db.select(db.calendars).getSingle()).defaultVisibility,
      'FULL',
    );

    await tester.tap(find.byKey(const Key('calendar-default-visibility')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未設定（自分のみ）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-calendar-default-visibility')));
    await tester.pumpAndSettle();
    expect(
      (await db.select(db.calendars).getSingle()).defaultVisibility,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('repository refuses to change a group calendar', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.calendars).insert(
          local.CalendarsCompanion.insert(
            id: 'calendar-group',
            ownerUserId: 'owner',
            groupId: const Value('group'),
            name: 'Group',
          ),
        );
    final repository = CalendarVisibilityRepository(
      database: db,
      client: null,
      demoMode: true,
      ownerUserId: 'owner',
      calendarId: 'calendar-group',
      currentUserId: () => null,
      currentScheduleOwnerId: () => 'owner',
      clock: DateTime.now,
    );

    await expectLater(
      repository.save(VisibilityLevel.full),
      throwsStateError,
    );
    expect(
      (await db.select(db.calendars).getSingle()).defaultVisibility,
      'PRIVATE',
    );
  });

  test('live mode fails closed without the matching authenticated client',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.calendars).insert(
          local.CalendarsCompanion.insert(
            id: 'calendar-owner',
            ownerUserId: 'owner',
            groupId: const Value(null),
            name: 'Personal',
            defaultVisibility: const Value('PRIVATE'),
          ),
        );
    final repository = CalendarVisibilityRepository(
      database: db,
      client: null,
      demoMode: false,
      ownerUserId: 'owner',
      calendarId: 'calendar-owner',
      currentUserId: () => 'owner',
      currentScheduleOwnerId: () => 'owner',
      clock: DateTime.now,
    );

    await expectLater(
      repository.save(VisibilityLevel.full),
      throwsStateError,
    );
    expect(
      (await db.select(db.calendars).getSingle()).defaultVisibility,
      'PRIVATE',
    );
  });
}
