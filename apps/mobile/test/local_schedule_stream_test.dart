import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('snapshot stream reacts to create and tombstone without manual reload',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'stream-${idCounter++}',
    );
    final iterator = StreamIterator(
      repository.watchSnapshot(
        now: DateTime(2026, 7, 10),
        ownerUserId: demoUserId,
        universityId: demoUniversityId,
        termId: demoTermId,
        academicYear: 2026,
      ),
    );
    addTearDown(() async {
      await iterator.cancel();
      await db.close();
    });

    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current.events.map((event) => event.id),
        isNot(contains('stream-0')));

    final eventId = await repository.createEvent(
      ownerUserId: demoUserId,
      input: EventInput(
        title: 'ストリーム予定',
        startAt: DateTime(2026, 7, 11, 10),
        endAt: DateTime(2026, 7, 11, 11),
      ),
    );
    final created = await _nextMatching(
      iterator,
      (snapshot) => snapshot.events.any((event) => event.id == eventId),
    );
    final createdEvent =
        created.events.singleWhere((event) => event.id == eventId);

    expect(
      created.calendarItems.any(
        (item) => item.kind == EventKind.normal && item.sourceId == eventId,
      ),
      isTrue,
    );
    expect(created.pendingMutations, hasLength(1));

    await repository.deleteEvent(
      eventId: eventId,
      ownerUserId: demoUserId,
      expectedVersion: createdEvent.version,
    );
    final deleted = await _nextMatching(
      iterator,
      (snapshot) =>
          snapshot.events.every((event) => event.id != eventId) &&
          snapshot.pendingMutations.length == 2,
    );

    expect(deleted.events.map((event) => event.id), isNot(contains(eventId)));
    expect(
      deleted.calendarItems.map((item) => item.sourceId),
      isNot(contains(eventId)),
    );
  });
}

Future<LocalScheduleSnapshot> _nextMatching(
  StreamIterator<LocalScheduleSnapshot> iterator,
  bool Function(LocalScheduleSnapshot snapshot) predicate,
) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    final hasNext =
        await iterator.moveNext().timeout(const Duration(seconds: 3));
    if (!hasNext) break;
    if (predicate(iterator.current)) return iterator.current;
  }
  throw StateError('Expected snapshot emission was not observed.');
}
