import 'dart:convert';
import 'dart:io';

import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  final generatedAt = DateTime.utc(2026, 7, 1, 3);
  const course = UserCourse(
    id: 'course-1',
    ownerUserId: 'u1',
    termId: 'term',
    title: '線形代数',
    normalizedTitle: '線形代数',
    dayOfWeek: DateTime.monday,
    periodNo: 2,
    room: 'A101',
    color: 'course_blue',
  );

  test('canonical schema-v1 fixture round-trips through the strict decoder',
      () {
    final fixture = jsonDecode(
      File('test/fixtures/widget_snapshot_v1.json').readAsStringSync(),
    ) as Map<String, Object?>;

    expect(WidgetSnapshot.fromJson(fixture).toJson(), fixture);
  });

  test('generates the canonical versioned Monday-Friday snapshot contract', () {
    final snapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      periodSettings: const [
        PeriodSetting(
          id: 'p1',
          ownerUserId: 'u1',
          dayOfWeek: DateTime.monday,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60 + 30,
        ),
      ],
      courses: const [course],
    );

    expect(snapshot.schemaVersion, widgetSnapshotSchemaVersion);
    expect(snapshot.mode, widgetSnapshotMode);
    expect(snapshot.weekStart, '2026-06-29');
    expect(snapshot.timezone, japanTimeZone);
    expect(snapshot.days.map((day) => day.label), ['月', '火', '水', '木', '金']);
    expect(snapshot.periods, hasLength(5));
    expect(snapshot.periods.first.start, '09:00');
    expect(snapshot.periods.first.end, '10:30');
    expect(snapshot.cells, hasLength(25));
    expect(snapshot.cells.first.title, isNull);
    expect(snapshot.cells[1].title, '線形代数');

    final json = snapshot.toJson();
    expect(json.keys, {
      'schemaVersion',
      'mode',
      'generatedAt',
      'weekStart',
      'timezone',
      'privacyMode',
      'days',
      'periods',
      'items',
    });
    expect((json['items']! as List<Object?>), hasLength(1));
    expect(
      WidgetSnapshot.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      ).toJson(),
      json,
    );
  });

  test('privacy modes omit room and redact course details at the source', () {
    final titleSnapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.title,
      ),
      courses: const [course],
    );
    final busySnapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.busyOnly,
      ),
      courses: const [course],
    );

    final titleItem =
        (titleSnapshot.toJson()['items']! as List<Object?>).single as JsonMap;
    final busyItem =
        (busySnapshot.toJson()['items']! as List<Object?>).single as JsonMap;
    expect(titleItem, isNot(contains('room')));
    expect(titleItem['title'], '線形代数');
    expect(busyItem, isNot(contains('room')));
    expect(busyItem['title'], '予定あり');
    expect(jsonEncode(busySnapshot.toJson()), isNot(contains('線形代数')));
    expect(jsonEncode(busySnapshot.toJson()), isNot(contains('A101')));
  });

  test('empty timetable serializes no occupied items and keeps all slots', () {
    final snapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      courses: const [],
    );

    expect(snapshot.cells, hasLength(25));
    expect(
      snapshot.cells,
      everyElement(predicate<WidgetSnapshotCell>((cell) => cell.isEmpty)),
    );
    expect(snapshot.toJson()['items'], isEmpty);
  });

  test('multiple courses retain their slots and production deep links', () {
    final snapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      courses: const [
        course,
        UserCourse(
          id: 'course-2',
          ownerUserId: 'u1',
          termId: 'term',
          title: '情報セキュリティ',
          normalizedTitle: '情報セキュリティ',
          dayOfWeek: DateTime.friday,
          periodNo: 5,
        ),
      ],
    );

    final occupied = snapshot.cells.where((cell) => !cell.isEmpty).toList();
    expect(occupied, hasLength(2));
    expect(
      occupied.map((cell) => (cell.weekday, cell.periodNo, cell.deepLink)),
      containsAll([
        (DateTime.monday, 2, 'unischedule://course/course-1'),
        (DateTime.friday, 5, 'unischedule://course/course-2'),
      ]),
    );
  });

  test('long Japanese titles and rooms are bounded before serialization', () {
    final snapshot = WidgetSnapshotGenerator().generate(
      generatedAt: generatedAt,
      settings: const WidgetSnapshotSettings(
        privacyMode: WidgetPrivacyMode.titleAndRoom,
      ),
      courses: [
        UserCourse(
          id: 'long-course',
          ownerUserId: 'u1',
          termId: 'term',
          title: '発表会向け長い授業名' * 20,
          normalizedTitle: '発表会向け長い授業名',
          dayOfWeek: DateTime.wednesday,
          periodNo: 4,
          room: '中央キャンパス講義棟' * 20,
        ),
      ],
    );

    final occupied = snapshot.cells.singleWhere((cell) => !cell.isEmpty);
    expect(occupied.title, hasLength(120));
    expect(occupied.room, hasLength(80));
    expect(
      WidgetSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
      ).toJson(),
      snapshot.toJson(),
    );
  });

  test('strict decoder rejects unknown versions, fields, and unsafe links', () {
    final valid = WidgetSnapshotGenerator()
        .generate(generatedAt: generatedAt, courses: const [course]).toJson();
    final invalidPayloads = <JsonMap>[
      {...valid, 'schemaVersion': 2},
      {...valid, 'secret': 'must-not-be-accepted'},
      {...valid, 'weekStart': '2026-07-01'},
      {
        ...valid,
        'items': [
          {
            ...((valid['items']! as List<Object?>).single as JsonMap),
            'deepLink': 'https://attacker.example/course-1',
          },
        ],
      },
      {...valid, 'periods': const []},
    ];

    for (final payload in invalidPayloads) {
      expect(
        () => WidgetSnapshot.fromJson(payload),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('invalid course identifiers cannot enter widget deep links', () {
    expect(
      () => WidgetSnapshotGenerator().generate(
        generatedAt: generatedAt,
        courses: const [
          UserCourse(
            id: '../course',
            ownerUserId: 'u1',
            termId: 'term',
            title: '線形代数',
            normalizedTitle: '線形代数',
            dayOfWeek: DateTime.monday,
            periodNo: 1,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
}
