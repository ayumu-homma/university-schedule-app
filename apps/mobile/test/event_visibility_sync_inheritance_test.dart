import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('delta explicit NULL clears override; omitted update preserves it',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.calendars).insert(
          local.CalendarsCompanion.insert(
            id: 'calendar-a',
            ownerUserId: 'owner-a',
            groupId: const Value(null),
            name: 'Personal',
          ),
        );
    await db.into(db.events).insert(
          local.EventsCompanion.insert(
            id: 'event-a',
            ownerUserId: 'owner-a',
            calendarId: 'calendar-a',
            title: 'Existing',
            kind: 'normal',
            startAt: DateTime.utc(2026, 9, 28, 9),
            endAt: DateTime.utc(2026, 9, 28, 10),
            visibilityLevel: const Value('FULL'),
          ),
        );
    final store = DriftScheduleSyncStore(db, ownerUserId: 'owner-a');

    await store.applyDeltaPage(ScheduleDeltaPage(
      afterCursor: 0,
      nextCursor: 1,
      hasMore: false,
      changes: [
        _upsert(cursor: 1, version: 2, visibilityIncluded: true),
      ],
    ));
    var event = await (db.select(db.events)
          ..where((row) => row.id.equals('event-a')))
        .getSingle();
    expect(event.visibilityLevel, isNull);
    expect(event.version, 2);

    await store.applyDeltaPage(ScheduleDeltaPage(
      afterCursor: 1,
      nextCursor: 2,
      hasMore: false,
      changes: [
        _upsert(cursor: 2, version: 3, visibilityIncluded: true, value: 'FULL'),
      ],
    ));
    await store.applyDeltaPage(ScheduleDeltaPage(
      afterCursor: 2,
      nextCursor: 3,
      hasMore: false,
      changes: [
        _upsert(cursor: 3, version: 4, visibilityIncluded: false),
      ],
    ));
    event = await (db.select(db.events)
          ..where((row) => row.id.equals('event-a')))
        .getSingle();
    expect(event.visibilityLevel, 'FULL');
    expect(event.version, 4);

    await store.applyDeltaPage(ScheduleDeltaPage(
      afterCursor: 3,
      nextCursor: 4,
      hasMore: false,
      changes: [
        _upsert(
          id: 'event-new',
          cursor: 4,
          version: 1,
          visibilityIncluded: false,
        ),
      ],
    ));
    final created = await (db.select(db.events)
          ..where((row) => row.id.equals('event-new')))
        .getSingle();
    expect(created.visibilityLevel, 'PRIVATE');
  });
}

ScheduleDeltaChange _upsert({
  String id = 'event-a',
  required int cursor,
  required int version,
  required bool visibilityIncluded,
  String? value,
}) {
  final payload = <String, Object?>{
    'id': id,
    'ownerUserId': 'owner-a',
    'calendarId': 'calendar-a',
    'groupId': null,
    'title': 'Existing',
    'kind': 'normal',
    'startAt': '2026-09-28T09:00:00.000Z',
    'endAt': '2026-09-28T10:00:00.000Z',
    'isAllDay': false,
    'location': null,
    'description': null,
    'rrule': null,
    'timezone': 'Asia/Tokyo',
    'updatedAt': '2026-09-28T08:00:00.000Z',
    'deletedAt': null,
    'version': version,
  };
  if (visibilityIncluded) payload['visibilityLevel'] = value;
  return ScheduleDeltaChange(
    changeCursor: cursor,
    entityType: 'event',
    entityId: id,
    operation: ScheduleDeltaOperation.upsert,
    serverVersion: version,
    payload: payload,
  );
}
