import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/today/domain/today_briefing.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('終日予定をDriftからoffline再起動後もTodayへ復元する', () async {
    final directory = await Directory.systemTemp.createTemp('today-restart-');
    final file = File('${directory.path}${Platform.pathSeparator}schedule.db');
    local.AppDatabase? database;

    try {
      database = local.AppDatabase(NativeDatabase(file));
      await database.into(database.events).insert(
            local.EventsCompanion.insert(
              id: 'offline-all-day',
              ownerUserId: 'owner',
              calendarId: 'calendar',
              title: '端末保存の終日予定',
              kind: EventKind.normal.name,
              startAt: JapanTime.at(year: 2026, month: 8, day: 10),
              endAt: JapanTime.at(year: 2026, month: 8, day: 11),
              isAllDay: const Value(true),
              updatedAt: Value(DateTime.utc(2026, 8, 9, 15)),
            ),
          );
      await database.close();
      database = null;

      database = local.AppDatabase(NativeDatabase(file));
      final repository = DriftScheduleRepository(database);
      final events = await repository.eventsForUser('owner');
      final briefing = TodayBriefingService().build(
        now: JapanTime.at(year: 2026, month: 8, day: 10, hour: 9),
        events: events,
      );

      expect(events.single.isAllDay, isTrue);
      expect(briefing.personalEvents.single.sourceId, 'offline-all-day');
      expect(briefing.personalEvents.single.isAllDay, isTrue);
    } finally {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}
