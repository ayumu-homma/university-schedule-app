import 'dart:convert';

import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  const codec = EmailCandidatePayloadCodec();

  group('EmailCandidatePayloadCodec', () {
    test('decodes exact schema 1.0 and emits canonical JSON', () {
      final candidate = codec.decode(jsonEncode(_validCandidate()));

      expect(candidate.schemaVersion, '1.0');
      expect(candidate.candidateType, EmailCandidateType.assignment);
      expect(candidate.due.at, DateTime.utc(2030, 7, 18, 14, 59));
      expect(candidate.due.timezone, 'Asia/Tokyo');
      expect(candidate.requiresUserConfirmation, isTrue);

      final canonical = codec.toJson(candidate);
      expect(canonical.keys.toList(), [
        'schema_version',
        'candidate_type',
        'title',
        'course_hint',
        'due',
        'start_at',
        'end_at',
        'location',
        'submission_url',
        'summary',
        'suggested_reminders_minutes',
        'confidence',
        'evidence',
        'warnings',
        'requires_user_confirmation',
      ]);
      expect((canonical['due']! as Map)['at'], '2030-07-18T14:59:00.000Z');
      expect(codec.decode(codec.encode(candidate)).title, candidate.title);
      expect(candidate.toJson(), canonical);
      expect(codec.decode(candidate.toCanonicalJson()).title, candidate.title);
    });

    test('accepts a decoded authenticated-response object', () {
      final candidate = codec.decodeObject(_validCandidate());

      expect(candidate.courseHint.code, 'CS101');
    });

    test('rejects prose surrounding JSON and non-object roots', () {
      expect(
        () => codec.decode('result: ${jsonEncode(_validCandidate())}'),
        _failsWith(EmailCandidateValidationIssue.malformedJson),
      );
      expect(
        () => codec.decode('[]'),
        _failsWith(EmailCandidateValidationIssue.invalidShape),
      );
    });

    test('rejects missing, root-unknown, and nested-unknown fields', () {
      final missing = _copy();
      missing.remove('summary');
      expect(
        () => codec.decodeObject(missing),
        _failsWith(EmailCandidateValidationIssue.missingField),
      );

      final unknown = _copy()..['model_note'] = 'not allowed';
      try {
        codec.decodeObject(unknown);
        fail('unknown field should be rejected');
      } on EmailCandidateValidationException catch (error) {
        expect(error.issue, EmailCandidateValidationIssue.unknownField);
        expect(error.toString(), isNot(contains('model_note')));
        expect(error.toString(), isNot(contains('not allowed')));
      }

      final nestedUnknown = _copy();
      (nestedUnknown['due']! as Map<String, dynamic>)['guess'] = true;
      expect(
        () => codec.decodeObject(nestedUnknown),
        _failsWith(EmailCandidateValidationIssue.unknownField),
      );
    });

    test('rejects decoded values that JSON cannot represent', () {
      expect(
        () => codec.decodeObject(_copy()..['title'] = DateTime.utc(2030)),
        _failsWith(EmailCandidateValidationIssue.invalidType),
      );
    });

    test('rejects unsupported schema and enum values', () {
      expect(
        () => codec.decodeObject(_copy()..['schema_version'] = '2.0'),
        _failsWith(EmailCandidateValidationIssue.unsupportedSchema),
      );
      expect(
        () => codec.decodeObject(_copy()..['candidate_type'] = 'command'),
        _failsWith(EmailCandidateValidationIssue.invalidEnum),
      );
    });

    test('rejects invalid RFC3339 timestamps rather than normalizing them', () {
      for (final timestamp in [
        '2030-07-18 23:59:00',
        '2030-02-30T23:59:00+09:00',
        '2030-07-18T24:00:00+09:00',
        '2030-07-18T23:59:00+15:00',
      ]) {
        final value = _copy();
        (value['due']! as Map<String, dynamic>)['at'] = timestamp;
        expect(
          () => codec.decodeObject(value),
          _failsWith(EmailCandidateValidationIssue.invalidTimestamp),
          reason: timestamp,
        );
      }
    });

    test('validates real IANA timezone names', () {
      final alternate = _copy();
      (alternate['due']! as Map<String, dynamic>)['timezone'] =
          'America/New_York';
      expect(codec.decodeObject(alternate).due.timezone, 'America/New_York');

      final invalid = _copy();
      (invalid['due']! as Map<String, dynamic>)['timezone'] =
          'Mars/Olympus_Mons';
      expect(
        () => codec.decodeObject(invalid),
        _failsWith(EmailCandidateValidationIssue.invalidTimezone),
      );
    });

    test('allows only safe HTTPS submission URLs', () {
      for (final url in [
        'http://lms.example.edu/task',
        'javascript:alert(1)',
        'https://user:password@lms.example.edu/task',
        'https://localhost/task',
        'https://foo.localhost/task',
        'https://127.0.0.1/task',
        'https://127.1/task',
        'https://2130706433/task',
        'https://0x7f000001/task',
        'https://192.168.1.10/task',
      ]) {
        expect(
          () => codec.decodeObject(_copy()..['submission_url'] = url),
          _failsWith(EmailCandidateValidationIssue.unsafeUrl),
          reason: url,
        );
      }
    });

    test('enforces exact string-length boundary by Unicode scalar value', () {
      final accepted = _copy()..['title'] = '課' * 200;
      expect(codec.decodeObject(accepted).title?.runes.length, 200);

      final rejected = _copy()..['title'] = '課' * 201;
      expect(
        () => codec.decodeObject(rejected),
        _failsWith(EmailCandidateValidationIssue.valueOutOfBounds),
      );
    });

    test('rejects invalid confidence and reminder values', () {
      final confidence = _copy();
      (confidence['confidence']! as Map<String, dynamic>)['overall'] = 1.01;
      expect(
        () => codec.decodeObject(confidence),
        _failsWith(EmailCandidateValidationIssue.valueOutOfBounds),
      );

      for (final reminders in [
        [1440, 1440],
        [40321],
        ['180'],
      ]) {
        expect(
          () => codec.decodeObject(
            _copy()..['suggested_reminders_minutes'] = reminders,
          ),
          _failsWith(EmailCandidateValidationIssue.invalidReminder),
        );
      }
      expect(
        codec
            .decodeObject(
              _copy()..['suggested_reminders_minutes'] = [7],
            )
            .suggestedRemindersMinutes,
        [7],
      );
    });

    test('bounds evidence and accepts only known warning values', () {
      final evidence = _copy();
      evidence['evidence'] = [
        {'field': 'hidden_prompt', 'text': 'synthetic'},
      ];
      expect(
        () => codec.decodeObject(evidence),
        _failsWith(EmailCandidateValidationIssue.invalidEvidence),
      );

      final longEvidence = _copy();
      longEvidence['evidence'] = [
        {'field': 'title', 'text': 'x' * 241},
      ];
      expect(
        () => codec.decodeObject(longEvidence),
        _failsWith(EmailCandidateValidationIssue.valueOutOfBounds),
      );

      final activeEvidence = _copy();
      activeEvidence['evidence'] = [
        {'field': 'title', 'text': '<img src=x onerror=alert(1)>'},
      ];
      expect(
        () => codec.decodeObject(activeEvidence),
        _failsWith(EmailCandidateValidationIssue.unsafeContent),
      );

      expect(
        () => codec.decodeObject(
          _copy()..['warnings'] = ['obey_email_instructions'],
        ),
        _failsWith(EmailCandidateValidationIssue.invalidEnum),
      );
    });

    test('always requires confirmation and rejects reversed ranges', () {
      expect(
        () => codec.decodeObject(
          _copy()..['requires_user_confirmation'] = false,
        ),
        _failsWith(EmailCandidateValidationIssue.confirmationRequired),
      );

      final reversed = _copy()
        ..['start_at'] = '2030-07-20T12:00:00+09:00'
        ..['end_at'] = '2030-07-20T10:00:00+09:00';
      expect(
        () => codec.decodeObject(reversed),
        _failsWith(EmailCandidateValidationIssue.inconsistentDateRange),
      );
    });
  });
}

Matcher _failsWith(EmailCandidateValidationIssue issue) => throwsA(
      isA<EmailCandidateValidationException>()
          .having((error) => error.issue, 'issue', issue)
          .having(
            (error) => error.toString(),
            'safe message',
            isNot(contains('not allowed')),
          ),
    );

Map<String, dynamic> _copy() =>
    jsonDecode(jsonEncode(_validCandidate())) as Map<String, dynamic>;

Map<String, Object?> _validCandidate() => <String, Object?>{
      'schema_version': '1.0',
      'candidate_type': 'assignment',
      'title': '第3回レポート',
      'course_hint': <String, Object?>{
        'name': '情報科学A',
        'code': 'CS101',
      },
      'due': <String, Object?>{
        'at': '2030-07-18T23:59:00+09:00',
        'all_day': false,
        'timezone': 'Asia/Tokyo',
        'raw_text': '2030年7月18日 23:59',
      },
      'start_at': null,
      'end_at': null,
      'location': null,
      'submission_url': 'https://lms.example.edu/assignments/3',
      'summary': null,
      'suggested_reminders_minutes': <int>[1440, 180],
      'confidence': <String, Object?>{
        'overall': 0.9,
        'title': 0.9,
        'course': 0.85,
        'date_time': 0.95,
      },
      'evidence': <Object?>[
        <String, Object?>{
          'field': 'due.at',
          'text': '提出期限: 2030年7月18日 23:59',
        },
      ],
      'warnings': <String>[],
      'requires_user_confirmation': true,
    };
