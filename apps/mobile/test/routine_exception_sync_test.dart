import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

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
  test('personal routine persists Japan civil input as canonical UTC payloads',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      clock: () => DateTime.utc(2026, 7, 10, 9),
      createId: () => 'japan-routine',
    );
    addTearDown(db.close);

    final routineId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: 'JST routine',
        startAt: jst(2026, 7, 6, 9),
        endAt: jst(2026, 7, 6, 10),
        kind: EventKind.routine,
        recurrenceRule: RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: const [DateTime.monday],
          until: jst(2026, 7, 20, 23, 59),
        ),
      ),
    );

    final row = await (db.select(db.events)
          ..where((event) => event.id.equals(routineId)))
        .getSingle();
    final event = (await repository.eventsForUser(demoUserId))
        .singleWhere((item) => item.id == routineId);
    final payload = (await repository.pendingMutations(ownerUserId: demoUserId))
        .singleWhere((mutation) => mutation.entityId == routineId)
        .payload;

    expect(row.startAt.toUtc(), DateTime.utc(2026, 7, 6));
    expect(row.timezone, japanTimeZone);
    expect(row.rrule, contains('UNTIL=2026-07-20T14:59:00.000Z'));
    expect(event.startAt, DateTime.utc(2026, 7, 6));
    expect(event.recurrenceRule?.until, DateTime.utc(2026, 7, 20, 14, 59));
    expect(event.timezone, japanTimeZone);
    expect(payload['startAt'], '2026-07-06T00:00:00.000Z');
    expect(payload['endAt'], '2026-07-06T01:00:00.000Z');
  });

  test('offline routine exception CRUD is versioned, queued, and tombstoned',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 7, 10, 9);
    var nextId = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      clock: () => now,
      createId: () => 'routine-sync-${nextId++}',
    );
    addTearDown(db.close);

    final routineId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: '朝の復習',
        startAt: jst(2026, 7, 6, 9),
        endAt: jst(2026, 7, 6, 10),
        kind: EventKind.routine,
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 3,
        ),
      ),
    );
    final recurrenceId = jst(2026, 7, 13, 9);
    final exceptionId = await repository.createEventException(
      eventId: routineId,
      ownerUserId: demoUserId,
      input: EventExceptionInput(
        recurrenceId: recurrenceId,
        mode: EventExceptionMode.cancelled,
      ),
    );

    var row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals(exceptionId)))
        .getSingle();
    expect(row.ownerUserId, demoUserId);
    expect(row.version, 1);
    expect(row.deletedAt, isNull);
    expect(row.updatedAt.toUtc(), now);
    var mutations = (await repository.pendingMutations(ownerUserId: demoUserId))
        .where((mutation) => mutation.entityType == 'event_exception')
        .toList();
    expect(mutations, hasLength(1));
    expect(mutations.single.operation, SyncOperation.create);
    expect(mutations.single.baseVersion, isNull);
    expect(mutations.single.payload['eventId'], routineId);
    expect(mutations.single.payload['mode'], 'cancelled');

    await repository.updateEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: demoUserId,
      input: EventExceptionInput(
        recurrenceId: recurrenceId,
        mode: EventExceptionMode.modified,
        overrideStartAt: jst(2026, 7, 13, 13),
        overrideEndAt: jst(2026, 7, 13, 14),
        overrideTitle: '午後の復習',
      ),
    );

    row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals(exceptionId)))
        .getSingle();
    expect(row.version, 2);
    expect(row.deletedAt, isNull);
    expect(row.overridePayloadJson, contains('午後の復習'));
    mutations = (await repository.pendingMutations(ownerUserId: demoUserId))
        .where((mutation) => mutation.entityType == 'event_exception')
        .toList();
    expect(mutations.map((mutation) => mutation.operation), [
      SyncOperation.create,
      SyncOperation.update,
    ]);
    expect(mutations.last.baseVersion, 1);
    expect(mutations.last.payload['version'], 2);

    await repository.deleteEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: demoUserId,
    );

    row = await (db.select(db.eventExceptions)
          ..where((exception) => exception.id.equals(exceptionId)))
        .getSingle();
    expect(row.version, 3);
    expect(row.deletedAt?.toUtc(), now);
    expect(
      await repository.eventExceptionsForEvent(
        eventId: routineId,
        ownerUserId: demoUserId,
      ),
      isEmpty,
    );
    mutations = (await repository.pendingMutations(ownerUserId: demoUserId))
        .where((mutation) => mutation.entityType == 'event_exception')
        .toList();
    expect(mutations.last.operation, SyncOperation.delete);
    expect(mutations.last.baseVersion, 2);
    expect(mutations.last.payload['deletedAt'], isNotNull);
    expect(mutations.last.payload['version'], 3);
  });
}
