import 'dart:convert';

import 'document_import.dart';

enum DocumentCandidateValidationIssue {
  malformedJson,
  invalidShape,
  missingField,
  unknownField,
  invalidType,
  unsupportedSchema,
  invalidEnum,
  valueOutOfBounds,
  invalidTimestamp,
  invalidTimezone,
  unsafeUrl,
  unsafeContent,
  invalidEvidence,
  confirmationRequired,
  duplicateCandidate,
  inconsistentCandidate;
}

class DocumentCandidateValidationException implements Exception {
  const DocumentCandidateValidationException(this.issue, {this.path});

  final DocumentCandidateValidationIssue issue;
  final String? path;

  @override
  String toString() {
    final location = path == null ? '' : ' at $path';
    return 'Document candidate validation failed: ${issue.name}$location.';
  }
}

/// Strict canonical codec shared by fake and production document extractors.
/// Unknown keys, prose around JSON, unsafe markup, invented unsupported types,
/// and confirmation bypasses fail closed.
class DocumentCandidateBatchCodec {
  const DocumentCandidateBatchCodec();

  static const schemaVersion = '1.0';
  static const timezone = 'Asia/Tokyo';
  static const maxJsonBytes = 256 * 1024;
  static const maxCandidates = 20;
  static const maxTitleCharacters = 200;
  static const maxCourseCharacters = 160;
  static const maxCourseCodeCharacters = 64;
  static const maxLocationCharacters = 200;
  static const maxNotesCharacters = 1000;
  static const maxEvidenceItems = 8;
  static const maxEvidenceExcerptCharacters = 500;
  static const maxEvidenceSectionCharacters = 120;

  static const _batchFields = <String>{
    'schema_version',
    'source_id',
    'content_hash',
    'timezone',
    'candidates',
  };
  static const _candidateFields = <String>{
    'candidate_id',
    'type',
    'title',
    'course_hint',
    'due_at',
    'all_day',
    'start_at',
    'end_at',
    'location',
    'submission_url',
    'notes',
    'confidence',
    'evidence',
    'warnings',
    'requires_user_confirmation',
  };
  static const _courseFields = <String>{'name', 'code'};
  static const _confidenceFields = <String>{
    'overall',
    'course',
    'date_time',
  };
  static const _evidenceFields = <String>{
    'page_number',
    'section',
    'excerpt',
  };

  ScheduleCandidateBatch decode(String source) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: r'$json',
      );
    }
    final Object? value;
    try {
      value = jsonDecode(source);
    } on FormatException {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.malformedJson,
        path: r'$json',
      );
    }
    return decodeObject(value);
  }

  ScheduleCandidateBatch decodeObject(Object? value) {
    final map = _requiredMap(value, r'$');
    final encoded = jsonEncode(map);
    if (utf8.encode(encoded).length > maxJsonBytes) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: r'$json',
      );
    }
    _expectExactFields(map, _batchFields, r'$');

    final version = _requiredString(
      map['schema_version'],
      r'$.schema_version',
      maxCharacters: 16,
    );
    if (version != schemaVersion) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.unsupportedSchema,
        path: r'$.schema_version',
      );
    }
    final sourceId = _safeIdentifier(map['source_id'], r'$.source_id');
    final contentHash = _requiredString(
      map['content_hash'],
      r'$.content_hash',
      maxCharacters: 64,
    );
    if (!_sha256.hasMatch(contentHash)) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: r'$.content_hash',
      );
    }
    final batchTimezone = _requiredString(
      map['timezone'],
      r'$.timezone',
      maxCharacters: 64,
    );
    if (batchTimezone != timezone) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidTimezone,
        path: r'$.timezone',
      );
    }
    final values = _requiredList(map['candidates'], r'$.candidates');
    if (values.length > maxCandidates) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: r'$.candidates',
      );
    }
    final ids = <String>{};
    final candidates = <DocumentScheduleCandidate>[];
    for (var index = 0; index < values.length; index++) {
      final candidate = _decodeCandidate(
        values[index],
        r'$.candidates[' + '$index]',
        batchTimezone,
      );
      if (!ids.add(candidate.candidateId)) {
        throw DocumentCandidateValidationException(
          DocumentCandidateValidationIssue.duplicateCandidate,
          path: r'$.candidates[' + '$index].candidate_id',
        );
      }
      candidates.add(candidate);
    }
    return ScheduleCandidateBatch(
      schemaVersion: version,
      sourceId: sourceId,
      contentHash: contentHash,
      timezone: batchTimezone,
      candidates: List.unmodifiable(candidates),
    );
  }

  Map<String, Object?> toJson(ScheduleCandidateBatch batch) {
    String? timestamp(DateTime? value) => value?.toUtc().toIso8601String();

    final value = <String, Object?>{
      'schema_version': batch.schemaVersion,
      'source_id': batch.sourceId,
      'content_hash': batch.contentHash,
      'timezone': batch.timezone,
      'candidates': [
        for (final candidate in batch.candidates)
          <String, Object?>{
            'candidate_id': candidate.candidateId,
            'type': candidate.type.wireName,
            'title': candidate.title,
            'course_hint': <String, Object?>{
              'name': candidate.courseHint.name,
              'code': candidate.courseHint.code,
            },
            'due_at': timestamp(candidate.dueAt),
            'all_day': candidate.allDay,
            'start_at': timestamp(candidate.startAt),
            'end_at': timestamp(candidate.endAt),
            'location': candidate.location,
            'submission_url': candidate.submissionUrl,
            'notes': candidate.notes,
            'confidence': <String, Object?>{
              'overall': candidate.confidence.overall,
              'course': candidate.confidence.course,
              'date_time': candidate.confidence.dateTime,
            },
            'evidence': [
              for (final evidence in candidate.evidence)
                <String, Object?>{
                  'page_number': evidence.pageNumber,
                  'section': evidence.section,
                  'excerpt': evidence.excerpt,
                },
            ],
            'warnings': [
              for (final warning in candidate.warnings) warning.wireName,
            ],
            'requires_user_confirmation': candidate.requiresUserConfirmation,
          },
      ],
    };
    decodeObject(value);
    return value;
  }

  String encode(ScheduleCandidateBatch batch) => jsonEncode(toJson(batch));

  DocumentScheduleCandidate _decodeCandidate(
    Object? value,
    String path,
    String batchTimezone,
  ) {
    final map = _requiredMap(value, path);
    _expectExactFields(map, _candidateFields, path);
    final candidateId = _safeIdentifier(
      map['candidate_id'],
      '$path.candidate_id',
    );
    final typeWire = _requiredString(
      map['type'],
      '$path.type',
      maxCharacters: 32,
    );
    final DocumentCandidateType type;
    try {
      type = DocumentCandidateType.fromWire(typeWire);
    } on FormatException {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidEnum,
        path: '$path.type',
      );
    }
    final title = _requiredString(
      map['title'],
      '$path.title',
      maxCharacters: maxTitleCharacters,
    );
    final course = _requiredMap(map['course_hint'], '$path.course_hint');
    _expectExactFields(course, _courseFields, '$path.course_hint');
    final courseHint = DocumentCourseHint(
      name: _nullableString(
        course['name'],
        '$path.course_hint.name',
        maxCharacters: maxCourseCharacters,
      ),
      code: _nullableString(
        course['code'],
        '$path.course_hint.code',
        maxCharacters: maxCourseCodeCharacters,
      ),
    );
    final dueAt = _nullableTimestamp(map['due_at'], '$path.due_at');
    final allDay = _requiredBool(map['all_day'], '$path.all_day');
    final startAt = _nullableTimestamp(map['start_at'], '$path.start_at');
    final endAt = _nullableTimestamp(map['end_at'], '$path.end_at');
    final location = _nullableString(
      map['location'],
      '$path.location',
      maxCharacters: maxLocationCharacters,
    );
    final submissionUrl = _nullableString(
      map['submission_url'],
      '$path.submission_url',
      maxCharacters: 2048,
      rejectUnsafeText: false,
    );
    if (submissionUrl != null) {
      _validateHttpsUrl(submissionUrl, '$path.submission_url');
    }
    final notes = _nullableString(
      map['notes'],
      '$path.notes',
      maxCharacters: maxNotesCharacters,
    );
    final confidenceMap = _requiredMap(map['confidence'], '$path.confidence');
    _expectExactFields(
      confidenceMap,
      _confidenceFields,
      '$path.confidence',
    );
    final confidence = DocumentCandidateConfidence(
      overall: _confidence(
        confidenceMap['overall'],
        '$path.confidence.overall',
      ),
      course: _confidence(
        confidenceMap['course'],
        '$path.confidence.course',
      ),
      dateTime: _confidence(
        confidenceMap['date_time'],
        '$path.confidence.date_time',
      ),
    );
    final evidence = _decodeEvidence(map['evidence'], '$path.evidence');
    final warnings = _decodeWarnings(map['warnings'], '$path.warnings');
    final confirmation = _requiredBool(
      map['requires_user_confirmation'],
      '$path.requires_user_confirmation',
    );
    if (!confirmation) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.confirmationRequired,
        path: '$path.requires_user_confirmation',
      );
    }
    _validateCandidateConsistency(
      path: path,
      type: type,
      dueAt: dueAt,
      allDay: allDay,
      startAt: startAt,
      endAt: endAt,
      warnings: warnings,
    );
    return DocumentScheduleCandidate(
      candidateId: candidateId,
      type: type,
      title: title,
      courseHint: courseHint,
      dueAt: dueAt,
      allDay: allDay,
      startAt: startAt,
      endAt: endAt,
      location: location,
      submissionUrl: submissionUrl,
      notes: notes,
      timezone: batchTimezone,
      confidence: confidence,
      evidence: List.unmodifiable(evidence),
      warnings: List.unmodifiable(warnings),
      requiresUserConfirmation: true,
    );
  }

  static void _validateCandidateConsistency({
    required String path,
    required DocumentCandidateType type,
    required DateTime? dueAt,
    required bool allDay,
    required DateTime? startAt,
    required DateTime? endAt,
    required List<DocumentCandidateWarning> warnings,
  }) {
    if (allDay && dueAt == null) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.inconsistentCandidate,
        path: '$path.all_day',
      );
    }
    if (endAt != null && (startAt == null || !endAt.isAfter(startAt))) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.inconsistentCandidate,
        path: '$path.end_at',
      );
    }
    final missingDate =
        warnings.contains(DocumentCandidateWarning.missingDate) ||
            warnings.contains(DocumentCandidateWarning.missingYear);
    switch (type) {
      case DocumentCandidateType.assignment:
        if (startAt != null ||
            endAt != null ||
            (dueAt == null && !missingDate)) {
          throw DocumentCandidateValidationException(
            DocumentCandidateValidationIssue.inconsistentCandidate,
            path: path,
          );
        }
      case DocumentCandidateType.exam:
        if (dueAt != null || allDay || (startAt == null && !missingDate)) {
          throw DocumentCandidateValidationException(
            DocumentCandidateValidationIssue.inconsistentCandidate,
            path: path,
          );
        }
    }
  }

  static List<DocumentCandidateEvidence> _decodeEvidence(
    Object? value,
    String path,
  ) {
    final items = _requiredList(value, path);
    if (items.isEmpty || items.length > maxEvidenceItems) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidEvidence,
        path: path,
      );
    }
    return List.generate(items.length, (index) {
      final itemPath = '$path[$index]';
      final map = _requiredMap(items[index], itemPath);
      _expectExactFields(map, _evidenceFields, itemPath);
      final pageNumber = map['page_number'];
      if (pageNumber != null &&
          (pageNumber is! int || pageNumber < 1 || pageNumber > 500)) {
        throw DocumentCandidateValidationException(
          DocumentCandidateValidationIssue.invalidEvidence,
          path: '$itemPath.page_number',
        );
      }
      return DocumentCandidateEvidence(
        pageNumber: pageNumber as int?,
        section: _nullableString(
          map['section'],
          '$itemPath.section',
          maxCharacters: maxEvidenceSectionCharacters,
        ),
        excerpt: _requiredString(
          map['excerpt'],
          '$itemPath.excerpt',
          maxCharacters: maxEvidenceExcerptCharacters,
        ),
      );
    }, growable: false);
  }

  static List<DocumentCandidateWarning> _decodeWarnings(
    Object? value,
    String path,
  ) {
    final values = _requiredList(value, path);
    if (values.length > DocumentCandidateWarning.values.length) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    final result = <DocumentCandidateWarning>[];
    for (var index = 0; index < values.length; index++) {
      final wire = _requiredString(
        values[index],
        '$path[$index]',
        maxCharacters: 32,
      );
      final DocumentCandidateWarning warning;
      try {
        warning = DocumentCandidateWarning.fromWire(wire);
      } on FormatException {
        throw DocumentCandidateValidationException(
          DocumentCandidateValidationIssue.invalidEnum,
          path: '$path[$index]',
        );
      }
      if (result.contains(warning)) {
        throw DocumentCandidateValidationException(
          DocumentCandidateValidationIssue.invalidEnum,
          path: '$path[$index]',
        );
      }
      result.add(warning);
    }
    return result;
  }

  static Map<String, dynamic> _requiredMap(Object? value, String path) {
    if (value is! Map) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw DocumentCandidateValidationException(
          DocumentCandidateValidationIssue.invalidShape,
          path: path,
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static List<Object?> _requiredList(Object? value, String path) {
    if (value is! List) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    return value.cast<Object?>();
  }

  static bool _requiredBool(Object? value, String path) {
    if (value is! bool) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    return value;
  }

  static String _safeIdentifier(Object? value, String path) {
    final id = _requiredString(value, path, maxCharacters: 128);
    if (!_safeId.hasMatch(id)) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    return id;
  }

  static String _requiredString(
    Object? value,
    String path, {
    required int maxCharacters,
    bool rejectUnsafeText = true,
  }) {
    if (value is! String) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    if (value.isEmpty ||
        value.trim() != value ||
        value.runes.length > maxCharacters ||
        value.runes.any((rune) => rune < 0x20 && rune != 0x0a)) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    if (rejectUnsafeText && _unsafeText.hasMatch(value)) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.unsafeContent,
        path: path,
      );
    }
    return value;
  }

  static String? _nullableString(
    Object? value,
    String path, {
    required int maxCharacters,
    bool rejectUnsafeText = true,
  }) {
    if (value == null) return null;
    return _requiredString(
      value,
      path,
      maxCharacters: maxCharacters,
      rejectUnsafeText: rejectUnsafeText,
    );
  }

  static double _confidence(Object? value, String path) {
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    return value.toDouble();
  }

  static DateTime? _nullableTimestamp(Object? value, String path) {
    if (value == null) return null;
    if (value is! String || !_rfc3339.hasMatch(value)) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidTimestamp,
        path: path,
      );
    }
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.invalidTimestamp,
        path: path,
      );
    }
  }

  static void _validateHttpsUrl(String value, String path) {
    final uri = Uri.tryParse(value);
    final host = uri?.host.toLowerCase() ?? '';
    if (uri == null ||
        uri.scheme != 'https' ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.contains(':') ||
        _isPrivateIpv4(host) ||
        _numericHost.hasMatch(host)) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.unsafeUrl,
        path: path,
      );
    }
  }

  static bool _isPrivateIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((part) => part == null || part < 0 || part > 255)) {
      return false;
    }
    final first = octets[0]!;
    final second = octets[1]!;
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  static void _expectExactFields(
    Map<String, dynamic> map,
    Set<String> expected,
    String path,
  ) {
    final keys = map.keys.toSet();
    final missing = expected.difference(keys);
    if (missing.isNotEmpty) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.missingField,
        path: '$path.${missing.first}',
      );
    }
    final unknown = keys.difference(expected);
    if (unknown.isNotEmpty) {
      throw DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.unknownField,
        path: '$path.<unknown>',
      );
    }
  }

  static final _sha256 = RegExp(r'^[a-f0-9]{64}$');
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
  static final _rfc3339 = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    r'(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$',
  );
  static final _unsafeText = RegExp(
    r'<\s*/?\s*(?:script|iframe|object|embed|style|svg|html)[^>]*>|'
    r'\bon(?:load|error|click|mouseover)\s*=|javascript\s*:',
    caseSensitive: false,
  );
  static final _numericHost = RegExp(
    r'^(?:\d+|0x[0-9a-f]+)(?:\.(?:\d+|0x[0-9a-f]+))*$',
    caseSensitive: false,
  );
}

extension ScheduleCandidateBatchJson on ScheduleCandidateBatch {
  Map<String, Object?> toJson() =>
      const DocumentCandidateBatchCodec().toJson(this);

  String toCanonicalJson() => const DocumentCandidateBatchCodec().encode(this);
}
