import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_dedupe.dart';

void main() {
  test('Exam and Event timezone-only changes stay explicit and distinct', () {
    for (final type in [EmailCandidateType.exam, EmailCandidateType.event]) {
      final baseline = _scheduledPayload(type, timezone: 'Asia/Tokyo');
      final proposed = _scheduledPayload(type, timezone: 'America/New_York');

      expect(
        emailScheduleFieldDiff(baseline: baseline, proposed: proposed),
        {
          'due_timezone': {
            'before': 'Asia/Tokyo',
            'after': 'America/New_York',
          },
        },
        reason: '${type.wireName} must disclose notification-zone changes',
      );
      expect(
        emailCandidateUpdateFingerprint(proposed),
        isNot(emailCandidateUpdateFingerprint(baseline)),
        reason: '${type.wireName} update identity must include its timezone',
      );
    }
  });
}

EmailCandidatePayload _scheduledPayload(
  EmailCandidateType type, {
  required String timezone,
}) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: type,
    title: 'Timezone fixture',
    courseHint: const EmailCourseHint(),
    due: EmailDueCandidate(timezone: timezone),
    startAt: DateTime.utc(2031, 3, 8, 6, 30),
    endAt: DateTime.utc(2031, 3, 8, 7, 30),
    location: 'Fixture room',
    summary: 'Timezone parity fixture',
    suggestedRemindersMinutes: const [60],
    confidence: const EmailCandidateConfidence(
      overall: 1,
      title: 1,
      course: 1,
      dateTime: 1,
    ),
    requiresUserConfirmation: true,
  );
}
