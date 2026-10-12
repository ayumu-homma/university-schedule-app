/// Phase 4 personal scheduling is intentionally scoped to Japan.
///
/// Persisted timestamps are always UTC instants.  Calendar and recurrence
/// calculations use this small civil-time adapter instead of the device local
/// timezone, so a student travelling outside Japan still sees the same
/// Asia/Tokyo schedule.  Japan has no daylight-saving transition, which makes
/// the fixed +09:00 conversion correct for this product scope.
const japanTimeZone = 'Asia/Tokyo';

class JapanCivilDateTime {
  const JapanCivilDateTime({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.millisecond,
    required this.microsecond,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int millisecond;
  final int microsecond;

  /// This is a UTC-backed *civil* value for Flutter date/time pickers only.
  /// Convert it back through [JapanTime.fromCivil] before persistence.
  DateTime get pickerDateTime => DateTime.utc(
        year,
        month,
        day,
        hour,
        minute,
        second,
        millisecond,
        microsecond,
      );

  int get weekday => pickerDateTime.weekday;
}

class JapanTime {
  JapanTime._();

  static const timeZone = japanTimeZone;
  static const utcOffset = Duration(hours: 9);

  static bool isSupportedTimeZone(String value) => value == timeZone;

  /// Reads an instant as Asia/Tokyo calendar fields without consulting the
  /// device timezone.
  static JapanCivilDateTime civil(DateTime instant) {
    final shifted = instant.toUtc().add(utcOffset);
    return JapanCivilDateTime(
      year: shifted.year,
      month: shifted.month,
      day: shifted.day,
      hour: shifted.hour,
      minute: shifted.minute,
      second: shifted.second,
      millisecond: shifted.millisecond,
      microsecond: shifted.microsecond,
    );
  }

  /// Builds the UTC instant represented by an Asia/Tokyo wall-clock value.
  static DateTime at({
    required int year,
    required int month,
    required int day,
    int hour = 0,
    int minute = 0,
    int second = 0,
    int millisecond = 0,
    int microsecond = 0,
  }) {
    return DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
      millisecond,
      microsecond,
    ).subtract(utcOffset);
  }

  static DateTime fromCivil(DateTime value) => at(
        year: value.year,
        month: value.month,
        day: value.day,
        hour: value.hour,
        minute: value.minute,
        second: value.second,
        millisecond: value.millisecond,
        microsecond: value.microsecond,
      );

  static DateTime startOfDay(DateTime instant) {
    final value = civil(instant);
    return at(year: value.year, month: value.month, day: value.day);
  }

  static DateTime endOfDay(DateTime instant) {
    final value = civil(instant);
    return at(
      year: value.year,
      month: value.month,
      day: value.day,
      hour: 23,
      minute: 59,
      second: 59,
      millisecond: 999,
    );
  }

  static DateTime startOfWeek(DateTime instant) {
    final value = civil(instant);
    final date = DateTime.utc(value.year, value.month, value.day)
        .subtract(Duration(days: value.weekday - DateTime.monday));
    return at(year: date.year, month: date.month, day: date.day);
  }
}
