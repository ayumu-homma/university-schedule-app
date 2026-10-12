import 'dart:convert';

import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  const codec = DocumentCandidateBatchCodec();

  group('document candidate batch codec', () {
    test('round-trips a multi-candidate assignment and exam batch', () {
      final batch = _validBatch();

      final decoded = codec.decode(codec.encode(batch));

      expect(decoded.schemaVersion, '1.0');
      expect(decoded.candidates, hasLength(3));
      expect(
        decoded.candidates
            .where((item) => item.type == DocumentCandidateType.assignment),
        hasLength(2),
      );
      expect(
        decoded.candidates
            .where((item) => item.type == DocumentCandidateType.exam),
        hasLength(1),
      );
      expect(decoded.candidates.last.evidence.single.pageNumber, 18);
      expect(
        decoded.candidates.every((item) => item.requiresUserConfirmation),
        isTrue,
      );
    });

    test('rejects prose, missing fields, unknown fields, and schema drift', () {
      expect(
        () => codec.decode('result: ${codec.encode(_validBatch())}'),
        _issue(DocumentCandidateValidationIssue.malformedJson),
      );

      final missing = _json();
      missing.remove('content_hash');
      expect(
        () => codec.decodeObject(missing),
        _issue(DocumentCandidateValidationIssue.missingField),
      );

      final unknown = _json()..['provider_debug'] = 'secret-like detail';
      expect(
        () => codec.decodeObject(unknown),
        _issue(DocumentCandidateValidationIssue.unknownField),
      );

      final schema = _json()..['schema_version'] = '2.0';
      expect(
        () => codec.decodeObject(schema),
        _issue(DocumentCandidateValidationIssue.unsupportedSchema),
      );
    });

    test('requires confirmation and unique stable candidate identifiers', () {
      final bypass = _json();
      _candidate(bypass, 0)['requires_user_confirmation'] = false;
      expect(
        () => codec.decodeObject(bypass),
        _issue(DocumentCandidateValidationIssue.confirmationRequired),
      );

      final duplicate = _json();
      _candidate(duplicate, 1)['candidate_id'] =
          _candidate(duplicate, 0)['candidate_id'];
      expect(
        () => codec.decodeObject(duplicate),
        _issue(DocumentCandidateValidationIssue.duplicateCandidate),
      );
    });

    test('permits an ambiguous date only with an explicit warning', () {
      final ambiguous = _json();
      final candidate = _candidate(ambiguous, 0)
        ..['due_at'] = null
        ..['warnings'] = ['missing_year'];

      final decoded = codec.decodeObject(ambiguous);
      expect(decoded.candidates.first.dueAt, isNull);
      expect(
        decoded.candidates.first.warnings,
        contains(DocumentCandidateWarning.missingYear),
      );

      candidate['warnings'] = <Object?>[];
      expect(
        () => codec.decodeObject(ambiguous),
        _issue(DocumentCandidateValidationIssue.inconsistentCandidate),
      );
    });

    test('rejects inconsistent types, ranges, and all-day values', () {
      final assignmentWithExamTime = _json();
      _candidate(assignmentWithExamTime, 0)['start_at'] =
          '2026-08-20T01:00:00Z';
      expect(
        () => codec.decodeObject(assignmentWithExamTime),
        _issue(DocumentCandidateValidationIssue.inconsistentCandidate),
      );

      final reversedExam = _json();
      _candidate(reversedExam, 2)['end_at'] = '2026-08-27T00:00:00Z';
      expect(
        () => codec.decodeObject(reversedExam),
        _issue(DocumentCandidateValidationIssue.inconsistentCandidate),
      );

      final noDateAllDay = _json();
      _candidate(noDateAllDay, 1)
        ..['due_at'] = null
        ..['all_day'] = true
        ..['warnings'] = ['missing_date'];
      expect(
        () => codec.decodeObject(noDateAllDay),
        _issue(DocumentCandidateValidationIssue.inconsistentCandidate),
      );
    });

    test('bounds evidence, confidence, candidate count, and JSON size', () {
      final noEvidence = _json();
      _candidate(noEvidence, 0)['evidence'] = <Object?>[];
      expect(
        () => codec.decodeObject(noEvidence),
        _issue(DocumentCandidateValidationIssue.invalidEvidence),
      );

      final badPage = _json();
      ((_candidate(badPage, 0)['evidence'] as List).first
          as Map)['page_number'] = 501;
      expect(
        () => codec.decodeObject(badPage),
        _issue(DocumentCandidateValidationIssue.invalidEvidence),
      );

      final confidence = _json();
      (_candidate(confidence, 0)['confidence'] as Map)['overall'] = 1.1;
      expect(
        () => codec.decodeObject(confidence),
        _issue(DocumentCandidateValidationIssue.valueOutOfBounds),
      );

      final tooMany = _json();
      final original = (tooMany['candidates'] as List).first;
      tooMany['candidates'] = [
        for (var index = 0;
            index <= DocumentCandidateBatchCodec.maxCandidates;
            index++)
          {
            ...Map<String, Object?>.from(original as Map),
            'candidate_id': 'source-1:extra:$index',
          },
      ];
      expect(
        () => codec.decodeObject(tooMany),
        _issue(DocumentCandidateValidationIssue.valueOutOfBounds),
      );

      expect(
        () =>
            codec.decode(' ' * (DocumentCandidateBatchCodec.maxJsonBytes + 1)),
        _issue(DocumentCandidateValidationIssue.valueOutOfBounds),
      );
    });

    test('rejects active markup and unsafe submission URLs', () {
      final markup = _json();
      _candidate(markup, 0)['title'] = '<script>alert(1)</script>';
      expect(
        () => codec.decodeObject(markup),
        _issue(DocumentCandidateValidationIssue.unsafeContent),
      );

      for (final url in [
        'http://lms.example.edu/item',
        'https://localhost/item',
        'https://127.0.0.1/item',
        'https://user:pass@lms.example.edu/item',
      ]) {
        final unsafeUrl = _json();
        _candidate(unsafeUrl, 0)['submission_url'] = url;
        expect(
          () => codec.decodeObject(unsafeUrl),
          _issue(DocumentCandidateValidationIssue.unsafeUrl),
          reason: url,
        );
      }
    });

    test('requires valid RFC3339 timestamps and Japan timezone', () {
      final timestamp = _json();
      _candidate(timestamp, 0)['due_at'] = '2026-08-20 23:59';
      expect(
        () => codec.decodeObject(timestamp),
        _issue(DocumentCandidateValidationIssue.invalidTimestamp),
      );

      final timezone = _json()..['timezone'] = 'UTC';
      expect(
        () => codec.decodeObject(timezone),
        _issue(DocumentCandidateValidationIssue.invalidTimezone),
      );
    });

    test('copyWith explicitly clears location without changing codec shape',
        () {
      final batch = _validBatch();
      final exam = batch.candidates.last;

      expect(exam.copyWith(title: '更新後の試験').location, 'B203');

      final assignment = exam.copyWith(
        type: DocumentCandidateType.assignment,
        dueAt: exam.startAt,
        clearStartAt: true,
        clearEndAt: true,
        clearLocation: true,
      );
      final editedBatch = ScheduleCandidateBatch(
        schemaVersion: batch.schemaVersion,
        sourceId: batch.sourceId,
        contentHash: batch.contentHash,
        timezone: batch.timezone,
        candidates: [assignment],
      );
      final encoded = codec.encode(editedBatch);
      final decoded = codec.decode(encoded).candidates.single;

      expect(assignment.location, isNull);
      expect((jsonDecode(encoded) as Map)['candidates'], hasLength(1));
      expect(
        ((jsonDecode(encoded) as Map)['candidates'] as List).single,
        containsPair('location', null),
      );
      expect(decoded.location, isNull);
      expect(decoded.type, DocumentCandidateType.assignment);
      expect(decoded.dueAt, exam.startAt);
    });
  });
}

ScheduleCandidateBatch _validBatch() {
  const evidence = DocumentCandidateEvidence(
    pageNumber: 12,
    section: '課題',
    excerpt: '提出期限は8月20日23時59分',
  );
  const confidence = DocumentCandidateConfidence(
    overall: 0.9,
    course: 0.8,
    dateTime: 0.9,
  );
  return ScheduleCandidateBatch(
    schemaVersion: '1.0',
    sourceId: 'source-1',
    contentHash: 'a' * 64,
    timezone: 'Asia/Tokyo',
    candidates: [
      DocumentScheduleCandidate(
        candidateId: 'source-1:assignment:1',
        type: DocumentCandidateType.assignment,
        title: 'レポート1',
        courseHint: const DocumentCourseHint(name: '情報科学'),
        dueAt: DateTime.utc(2026, 8, 20, 14, 59),
        allDay: false,
        timezone: 'Asia/Tokyo',
        confidence: confidence,
        evidence: const [evidence],
        warnings: const [],
        requiresUserConfirmation: true,
      ),
      DocumentScheduleCandidate(
        candidateId: 'source-1:assignment:2',
        type: DocumentCandidateType.assignment,
        title: 'ワークシート',
        courseHint: const DocumentCourseHint(name: '情報科学'),
        dueAt: DateTime.utc(2026, 8, 23, 15),
        allDay: true,
        timezone: 'Asia/Tokyo',
        confidence: confidence,
        evidence: const [
          DocumentCandidateEvidence(
            pageNumber: 15,
            excerpt: '8月24日まで',
          ),
        ],
        warnings: const [DocumentCandidateWarning.missingTime],
        requiresUserConfirmation: true,
      ),
      DocumentScheduleCandidate(
        candidateId: 'source-1:exam:1',
        type: DocumentCandidateType.exam,
        title: '達成度確認',
        courseHint: const DocumentCourseHint(name: '情報科学'),
        allDay: false,
        startAt: DateTime.utc(2026, 8, 27, 1, 35),
        endAt: DateTime.utc(2026, 8, 27, 3, 5),
        location: 'B203',
        timezone: 'Asia/Tokyo',
        confidence: confidence,
        evidence: const [
          DocumentCandidateEvidence(
            pageNumber: 18,
            section: '試験',
            excerpt: '10時35分から達成度確認',
          ),
        ],
        warnings: const [],
        requiresUserConfirmation: true,
      ),
    ],
  );
}

Map<String, dynamic> _json() {
  return jsonDecode(
    const DocumentCandidateBatchCodec().encode(_validBatch()),
  ) as Map<String, dynamic>;
}

Map<String, dynamic> _candidate(Map<String, dynamic> batch, int index) {
  return (batch['candidates'] as List)[index] as Map<String, dynamic>;
}

Matcher _issue(DocumentCandidateValidationIssue issue) {
  return throwsA(
    isA<DocumentCandidateValidationException>()
        .having((error) => error.issue, 'issue', issue),
  );
}
