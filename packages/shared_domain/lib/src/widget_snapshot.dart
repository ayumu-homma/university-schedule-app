import 'enums.dart';
import 'japan_time.dart';
import 'models.dart';

const widgetSnapshotSchemaVersion = 1;
const widgetSnapshotMode = 'timetable_week';

class WidgetSnapshotSettings {
  const WidgetSnapshotSettings({
    this.privacyMode = WidgetPrivacyMode.titleAndRoom,
  });

  final WidgetPrivacyMode privacyMode;
}

class WidgetSnapshotDay {
  const WidgetSnapshotDay({
    required this.dayOfWeek,
    required this.label,
  });

  final int dayOfWeek;
  final String label;

  JsonMap toJson() => {
        'dayOfWeek': dayOfWeek,
        'label': label,
      };
}

class WidgetSnapshotPeriod {
  const WidgetSnapshotPeriod({
    required this.periodNo,
    required this.start,
    required this.end,
  });

  final int periodNo;
  final String start;
  final String end;

  JsonMap toJson() => {
        'periodNo': periodNo,
        'start': start,
        'end': end,
      };
}

class WidgetSnapshotCell {
  const WidgetSnapshotCell({
    required this.weekday,
    required this.periodNo,
    this.courseId,
    this.title,
    this.room,
    this.colorKey,
    this.deepLink,
  });

  final int weekday;
  final int periodNo;
  final String? courseId;
  final String? title;
  final String? room;
  final String? colorKey;
  final String? deepLink;

  bool get isEmpty => courseId == null;

  JsonMap toItemJson({required bool includeRoom}) => {
        'courseId': courseId,
        'dayOfWeek': weekday,
        'periodNo': periodNo,
        'title': title,
        if (includeRoom) 'room': room,
        'colorKey': colorKey,
        'deepLink': deepLink,
      };
}

class WidgetSnapshot {
  const WidgetSnapshot({
    required this.generatedAt,
    required this.weekStart,
    required this.timezone,
    required this.privacyMode,
    required this.days,
    required this.periods,
    required this.cells,
    this.schemaVersion = widgetSnapshotSchemaVersion,
    this.mode = widgetSnapshotMode,
  });

  final int schemaVersion;
  final String mode;
  final DateTime generatedAt;
  final String weekStart;
  final String timezone;
  final WidgetPrivacyMode privacyMode;
  final List<WidgetSnapshotDay> days;
  final List<WidgetSnapshotPeriod> periods;
  final List<WidgetSnapshotCell> cells;

  factory WidgetSnapshot.empty(DateTime generatedAt) {
    return WidgetSnapshotGenerator().generate(
      courses: const [],
      generatedAt: generatedAt,
    );
  }

  JsonMap toJson() => {
        'schemaVersion': schemaVersion,
        'mode': mode,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'weekStart': weekStart,
        'timezone': timezone,
        'privacyMode': privacyMode.wireName,
        'days': days.map((day) => day.toJson()).toList(growable: false),
        'periods':
            periods.map((period) => period.toJson()).toList(growable: false),
        'items': cells
            .where((cell) => !cell.isEmpty)
            .map(
              (cell) => cell.toItemJson(
                includeRoom: privacyMode == WidgetPrivacyMode.titleAndRoom,
              ),
            )
            .toList(growable: false),
      };

  factory WidgetSnapshot.fromJson(JsonMap json) {
    _requireExactKeys(json, const {
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
    if (json['schemaVersion'] != widgetSnapshotSchemaVersion ||
        json['mode'] != widgetSnapshotMode ||
        json['timezone'] != JapanTime.timeZone) {
      throw const FormatException('Unsupported widget snapshot contract.');
    }

    final generatedAt = DateTime.tryParse(_requireString(
      json['generatedAt'],
      'generatedAt',
      maxLength: 40,
    ));
    if (generatedAt == null || !generatedAt.isUtc) {
      throw const FormatException('generatedAt must be a UTC timestamp.');
    }
    final weekStart = _requireString(
      json['weekStart'],
      'weekStart',
      maxLength: 10,
    );
    if (!_datePattern.hasMatch(weekStart)) {
      throw const FormatException('weekStart must use YYYY-MM-DD.');
    }
    final weekStartParts =
        weekStart.split('-').map(int.parse).toList(growable: false);
    final weekStartDate = DateTime.utc(
      weekStartParts[0],
      weekStartParts[1],
      weekStartParts[2],
    );
    if (_date(weekStartDate.year, weekStartDate.month, weekStartDate.day) !=
            weekStart ||
        weekStartDate.weekday != DateTime.monday) {
      throw const FormatException('weekStart must be a valid Monday.');
    }
    final privacyMode = WidgetPrivacyModeWire.fromWire(
      _requireString(json['privacyMode'], 'privacyMode', maxLength: 32),
    );
    final days = _decodeDays(json['days']);
    final periods = _decodePeriods(json['periods']);
    final cells = <WidgetSnapshotCell>[
      for (final day in days)
        for (final period in periods)
          WidgetSnapshotCell(
            weekday: day.dayOfWeek,
            periodNo: period.periodNo,
          ),
    ];
    final cellIndex = <String, int>{
      for (var index = 0; index < cells.length; index++)
        '${cells[index].weekday}:${cells[index].periodNo}': index,
    };
    final items = json['items'];
    if (items is! List<Object?> || items.length > cells.length) {
      throw const FormatException('items must fit the widget grid.');
    }
    for (final value in items) {
      if (value is! Map) {
        throw const FormatException('Each widget item must be an object.');
      }
      final item = Map<String, Object?>.from(value);
      _requireExactKeys(
        item,
        privacyMode == WidgetPrivacyMode.titleAndRoom
            ? const {
                'courseId',
                'dayOfWeek',
                'periodNo',
                'title',
                'room',
                'colorKey',
                'deepLink',
              }
            : const {
                'courseId',
                'dayOfWeek',
                'periodNo',
                'title',
                'colorKey',
                'deepLink',
              },
      );
      final weekday = _requireInt(item['dayOfWeek'], 'dayOfWeek');
      final periodNo = _requireInt(item['periodNo'], 'periodNo');
      final index = cellIndex['$weekday:$periodNo'];
      if (index == null || !cells[index].isEmpty) {
        throw const FormatException('Widget item slot is invalid or repeated.');
      }
      final courseId = _requireSafeSegment(item['courseId'], 'courseId');
      final deepLink = _requireString(
        item['deepLink'],
        'deepLink',
        maxLength: 512,
      );
      if (deepLink != 'unischedule://course/$courseId') {
        throw const FormatException('Widget course deep link is invalid.');
      }
      final title = _requireString(item['title'], 'title', maxLength: 120);
      if (privacyMode == WidgetPrivacyMode.busyOnly && title != '予定あり') {
        throw const FormatException('Busy-only snapshots must redact titles.');
      }
      cells[index] = WidgetSnapshotCell(
        weekday: weekday,
        periodNo: periodNo,
        courseId: courseId,
        title: title,
        room: privacyMode == WidgetPrivacyMode.titleAndRoom
            ? _requireNullableString(item['room'], 'room', maxLength: 80)
            : null,
        colorKey: _requireColorKey(item['colorKey']),
        deepLink: deepLink,
      );
    }

    return WidgetSnapshot(
      generatedAt: generatedAt,
      weekStart: weekStart,
      timezone: JapanTime.timeZone,
      privacyMode: privacyMode,
      days: days,
      periods: periods,
      cells: cells,
    );
  }

  static List<WidgetSnapshotDay> _decodeDays(Object? value) {
    if (value is! List<Object?> || value.length != 5) {
      throw const FormatException('days must contain Monday through Friday.');
    }
    final days = <WidgetSnapshotDay>[];
    for (var index = 0; index < value.length; index++) {
      final raw = value[index];
      if (raw is! Map) {
        throw const FormatException('Each widget day must be an object.');
      }
      final day = Map<String, Object?>.from(raw);
      _requireExactKeys(day, const {'dayOfWeek', 'label'});
      final dayOfWeek = _requireInt(day['dayOfWeek'], 'dayOfWeek');
      final expectedDay = index + DateTime.monday;
      final label = _requireString(day['label'], 'label', maxLength: 1);
      if (dayOfWeek != expectedDay || label != _weekdayLabels[index]) {
        throw const FormatException('Widget days are not canonical.');
      }
      days.add(WidgetSnapshotDay(dayOfWeek: dayOfWeek, label: label));
    }
    return days;
  }

  static List<WidgetSnapshotPeriod> _decodePeriods(Object? value) {
    if (value is! List<Object?> || value.length != 5) {
      throw const FormatException('periods must contain periods 1 through 5.');
    }
    final periods = <WidgetSnapshotPeriod>[];
    for (var index = 0; index < value.length; index++) {
      final raw = value[index];
      if (raw is! Map) {
        throw const FormatException('Each widget period must be an object.');
      }
      final period = Map<String, Object?>.from(raw);
      _requireExactKeys(period, const {'periodNo', 'start', 'end'});
      final periodNo = _requireInt(period['periodNo'], 'periodNo');
      final start = _requireClock(period['start'], 'start');
      final end = _requireClock(period['end'], 'end');
      if (periodNo != index + 1 ||
          _minutesForClock(end) <= _minutesForClock(start)) {
        throw const FormatException('Widget period is invalid.');
      }
      periods.add(
        WidgetSnapshotPeriod(periodNo: periodNo, start: start, end: end),
      );
    }
    return periods;
  }
}

class WidgetSnapshotGenerator {
  WidgetSnapshot generate({
    required Iterable<UserCourse> courses,
    required DateTime generatedAt,
    Iterable<PeriodSetting> periodSettings = const [],
    WidgetSnapshotSettings settings = const WidgetSnapshotSettings(),
  }) {
    final normalizedGeneratedAt = generatedAt.toUtc();
    final bySlot = <String, UserCourse>{};
    for (final course in courses) {
      final weekday = course.dayOfWeek;
      final periodNo = course.periodNo;
      if (weekday == null ||
          periodNo == null ||
          weekday < DateTime.monday ||
          weekday > DateTime.friday ||
          periodNo < 1 ||
          periodNo > 5) {
        continue;
      }
      bySlot.putIfAbsent('$weekday:$periodNo', () => course);
    }

    final days = <WidgetSnapshotDay>[
      for (var index = 0; index < _weekdayLabels.length; index++)
        WidgetSnapshotDay(
          dayOfWeek: index + DateTime.monday,
          label: _weekdayLabels[index],
        ),
    ];
    final periods = <WidgetSnapshotPeriod>[
      for (var periodNo = 1; periodNo <= 5; periodNo++)
        _periodFor(periodNo, periodSettings),
    ];
    final cells = <WidgetSnapshotCell>[
      for (final day in days)
        for (final period in periods)
          _cellFor(
            bySlot['${day.dayOfWeek}:${period.periodNo}'],
            day.dayOfWeek,
            period.periodNo,
            settings.privacyMode,
          ),
    ];
    final monday = JapanTime.civil(
      JapanTime.startOfWeek(normalizedGeneratedAt),
    );

    return WidgetSnapshot(
      generatedAt: normalizedGeneratedAt,
      weekStart: _date(monday.year, monday.month, monday.day),
      timezone: JapanTime.timeZone,
      privacyMode: settings.privacyMode,
      days: days,
      periods: periods,
      cells: cells,
    );
  }

  WidgetSnapshotPeriod _periodFor(
    int periodNo,
    Iterable<PeriodSetting> settings,
  ) {
    PeriodSetting? match;
    for (final setting in settings) {
      if (setting.periodNo == periodNo &&
          setting.dayOfWeek >= DateTime.monday &&
          setting.dayOfWeek <= DateTime.friday &&
          setting.startTimeMinutes >= 0 &&
          setting.endTimeMinutes <= 24 * 60 &&
          setting.endTimeMinutes > setting.startTimeMinutes) {
        match = setting;
        if (setting.dayOfWeek == DateTime.monday) break;
      }
    }
    final fallback = _fallbackPeriods[periodNo - 1];
    return WidgetSnapshotPeriod(
      periodNo: periodNo,
      start: _clock(match?.startTimeMinutes ?? fallback.$1),
      end: _clock(match?.endTimeMinutes ?? fallback.$2),
    );
  }

  WidgetSnapshotCell _cellFor(
    UserCourse? course,
    int weekday,
    int periodNo,
    WidgetPrivacyMode mode,
  ) {
    if (course == null) {
      return WidgetSnapshotCell(weekday: weekday, periodNo: periodNo);
    }
    if (!_safeSegmentPattern.hasMatch(course.id)) {
      throw ArgumentError.value(
        course.id,
        'courses',
        'Widget course id is not a safe deep-link segment.',
      );
    }
    return WidgetSnapshotCell(
      weekday: weekday,
      periodNo: periodNo,
      courseId: course.id,
      title: mode == WidgetPrivacyMode.busyOnly
          ? '予定あり'
          : _bounded(course.title, 120),
      room: mode == WidgetPrivacyMode.titleAndRoom
          ? _boundedNullable(course.room, 80)
          : null,
      colorKey: _safeColorKey(course.color),
      deepLink: 'unischedule://course/${course.id}',
    );
  }
}

extension WidgetPrivacyModeWire on WidgetPrivacyMode {
  String get wireName => switch (this) {
        WidgetPrivacyMode.title => 'title',
        WidgetPrivacyMode.titleAndRoom => 'titleAndRoom',
        WidgetPrivacyMode.busyOnly => 'busyOnly',
      };

  static WidgetPrivacyMode fromWire(String value) => switch (value) {
        'title' => WidgetPrivacyMode.title,
        'titleAndRoom' => WidgetPrivacyMode.titleAndRoom,
        'busyOnly' => WidgetPrivacyMode.busyOnly,
        _ => throw const FormatException('Unknown widget privacy mode.'),
      };
}

const _weekdayLabels = ['月', '火', '水', '木', '金'];
const _fallbackPeriods = [
  (8 * 60 + 40, 10 * 60 + 20),
  (10 * 60 + 35, 12 * 60 + 15),
  (13 * 60 + 5, 14 * 60 + 45),
  (15 * 60, 16 * 60 + 40),
  (16 * 60 + 55, 18 * 60 + 35),
];
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _clockPattern = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$');
final _safeSegmentPattern = RegExp(r'^[A-Za-z0-9._~-]{1,256}$');
final _colorKeyPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

void _requireExactKeys(JsonMap json, Set<String> expected) {
  if (json.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(json.keys.toSet()).isNotEmpty) {
    throw const FormatException('Widget snapshot keys are invalid.');
  }
}

String _requireString(
  Object? value,
  String field, {
  required int maxLength,
}) {
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('$field is invalid.');
  }
  return value;
}

String? _requireNullableString(
  Object? value,
  String field, {
  required int maxLength,
}) {
  if (value == null) return null;
  return _requireString(value, field, maxLength: maxLength);
}

int _requireInt(Object? value, String field) {
  if (value is! int) throw FormatException('$field must be an integer.');
  return value;
}

String _requireSafeSegment(Object? value, String field) {
  final result = _requireString(value, field, maxLength: 256);
  if (!_safeSegmentPattern.hasMatch(result)) {
    throw FormatException('$field is not a safe URI segment.');
  }
  return result;
}

String _requireColorKey(Object? value) {
  final result = _requireString(value, 'colorKey', maxLength: 32);
  if (!_colorKeyPattern.hasMatch(result)) {
    throw const FormatException('colorKey is invalid.');
  }
  return result;
}

String _requireClock(Object? value, String field) {
  final result = _requireString(value, field, maxLength: 5);
  if (!_clockPattern.hasMatch(result)) {
    throw FormatException('$field must use HH:mm.');
  }
  return result;
}

int _minutesForClock(String value) {
  final parts = value.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

String _clock(int minutes) {
  final hour = minutes ~/ 60;
  final minute = minutes % 60;
  return '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
}

String _date(int year, int month, int day) {
  return '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

String _bounded(String value, int maxLength) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw const FormatException('Widget title must not be empty.');
  }
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

String? _boundedNullable(String? value, int maxLength) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized.length <= maxLength
      ? normalized
      : normalized.substring(0, maxLength);
}

String _safeColorKey(String? value) {
  final normalized = value?.trim().toLowerCase().replaceAll(
        RegExp('[^a-z0-9_]'),
        '_',
      );
  if (normalized == null ||
      normalized.isEmpty ||
      !_colorKeyPattern.hasMatch(normalized)) {
    return 'course_blue';
  }
  return normalized;
}
