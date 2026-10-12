import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

bool _emailTimezonesInitialized = false;

void _initializeEmailTimezones() {
  if (_emailTimezonesInitialized) return;
  timezone_data.initializeTimeZones();
  _emailTimezonesInitialized = true;
}

timezone.Location? emailTimezoneLocationOrNull(String value) {
  if (value.isEmpty || value != value.trim() || value.length > 64) return null;
  _initializeEmailTimezones();
  try {
    return timezone.getLocation(value);
  } on timezone.LocationNotFoundException {
    return null;
  }
}

bool isValidEmailTimezone(String value) =>
    emailTimezoneLocationOrNull(value) != null;

DateTime emailDateTimeInTimezone(DateTime value, String timeZone) {
  final location = emailTimezoneLocationOrNull(timeZone);
  if (location == null) {
    throw FormatException('Invalid IANA timezone.', timeZone);
  }
  return timezone.TZDateTime.from(value.toUtc(), location);
}

/// Parses one minute-precision civil timestamp in [timeZone].
///
/// A nonexistent DST wall time is rejected. If [referenceInstant] represents
/// the same civil minute, it is retained so editing an unchanged timestamp in
/// a repeated fall-back hour does not silently switch to the other occurrence.
DateTime? parseEmailCivilDateTime(
  String value, {
  required String timeZone,
  DateTime? referenceInstant,
}) {
  final normalized = value.trim();
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$',
  ).firstMatch(normalized);
  final location = emailTimezoneLocationOrNull(timeZone);
  if (match == null || location == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  if (month < 1 || month > 12 || hour > 23 || minute > 59) return null;

  bool hasRequestedFields(DateTime candidate) =>
      candidate.year == year &&
      candidate.month == month &&
      candidate.day == day &&
      candidate.hour == hour &&
      candidate.minute == minute;

  if (referenceInstant != null) {
    final reference =
        timezone.TZDateTime.from(referenceInstant.toUtc(), location);
    if (hasRequestedFields(reference)) return referenceInstant.toUtc();
  }

  final candidate = timezone.TZDateTime(
    location,
    year,
    month,
    day,
    hour,
    minute,
  );
  if (!hasRequestedFields(candidate)) return null;
  return candidate.toUtc();
}
