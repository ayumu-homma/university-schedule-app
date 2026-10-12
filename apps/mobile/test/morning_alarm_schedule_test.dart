import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';

void main() {
  group('MorningAlarmSchedule', () {
    test('uses the same selected Tokyo day when the time is still ahead', () {
      final now = JapanTime.at(
        year: 2026,
        month: 8,
        day: 10,
        hour: 7,
        minute: 29,
      );

      final next = MorningAlarmSchedule.nextOccurrence(
        now: now,
        hour: 7,
        minute: 30,
        weekdays: const {DateTime.monday},
      );

      expect(
        next,
        JapanTime.at(
          year: 2026,
          month: 8,
          day: 10,
          hour: 7,
          minute: 30,
        ),
      );
    });

    test('strictly advances when now is exactly the selected time', () {
      final now = JapanTime.at(
        year: 2026,
        month: 8,
        day: 10,
        hour: 7,
        minute: 30,
      );

      final next = MorningAlarmSchedule.nextOccurrence(
        now: now,
        hour: 7,
        minute: 30,
        weekdays: const {DateTime.monday},
      );

      expect(
        next,
        JapanTime.at(
          year: 2026,
          month: 8,
          day: 17,
          hour: 7,
          minute: 30,
        ),
      );
    });

    test('wraps Friday to Monday across the selected-weekday boundary', () {
      final now = JapanTime.at(
        year: 2026,
        month: 8,
        day: 14,
        hour: 22,
      );

      final next = MorningAlarmSchedule.nextOccurrence(
        now: now,
        hour: 7,
        minute: 30,
        weekdays: const {
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
        },
      );

      expect(
        next,
        JapanTime.at(
          year: 2026,
          month: 8,
          day: 17,
          hour: 7,
          minute: 30,
        ),
      );
    });

    test('interprets an offset instant in Asia/Tokyo rather than device time',
        () {
      final now = DateTime.parse('2026-08-09T23:00:00Z'); // Monday 08:00 JST.

      final next = MorningAlarmSchedule.nextOccurrence(
        now: now,
        hour: 7,
        minute: 30,
        weekdays: const {DateTime.monday},
      );

      expect(next.toIso8601String(), '2026-08-16T22:30:00.000Z');
    });

    test('rejects an empty weekday selection', () {
      expect(
        () => MorningAlarmSchedule.nextOccurrence(
          now: DateTime.utc(2026, 8, 10),
          hour: 7,
          minute: 30,
          weekdays: const {},
        ),
        throwsFormatException,
      );
    });
  });

  test('settings are initially disabled and round-trip the strict contract',
      () {
    final settings = MorningAlarmSettings(ownerUserId: 'owner-a');
    final payload = settings.toPlatformMap()..remove('ownerId');

    final decoded = MorningAlarmSettings.fromPlatformMap('owner-a', payload);

    expect(decoded, settings);
    expect(decoded.enabled, isFalse);
    expect(decoded.snoozeMinutes, 10);
    expect(decoded.lockScreenPrivacy, isTrue);
  });
}
