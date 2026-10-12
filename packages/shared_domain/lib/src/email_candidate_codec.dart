import 'dart:convert';

import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

import 'email_import.dart';

/// Stable, non-sensitive reasons why an untrusted candidate payload was
/// rejected.
enum EmailCandidateValidationIssue {
  malformedJson(EmailErrorCategory.invalidExtraction),
  invalidShape(EmailErrorCategory.invalidExtraction),
  missingField(EmailErrorCategory.invalidExtraction),
  unknownField(EmailErrorCategory.invalidExtraction),
  invalidType(EmailErrorCategory.invalidExtraction),
  unsupportedSchema(EmailErrorCategory.unsupportedSchema),
  invalidEnum(EmailErrorCategory.invalidExtraction),
  valueOutOfBounds(EmailErrorCategory.validationFailed),
  invalidTimestamp(EmailErrorCategory.validationFailed),
  invalidTimezone(EmailErrorCategory.validationFailed),
  unsafeUrl(EmailErrorCategory.unsafeUrl),
  unsafeContent(EmailErrorCategory.unsafeContent),
  invalidReminder(EmailErrorCategory.validationFailed),
  invalidEvidence(EmailErrorCategory.validationFailed),
  confirmationRequired(EmailErrorCategory.validationFailed),
  inconsistentDateRange(EmailErrorCategory.validationFailed);

  const EmailCandidateValidationIssue(this.errorCategory);

  final EmailErrorCategory errorCategory;
}

/// An allow-listed validation failure that never includes source email or
/// provider response text.
class EmailCandidateValidationException implements Exception {
  const EmailCandidateValidationException(this.issue, {this.path});

  final EmailCandidateValidationIssue issue;
  final String? path;

  EmailErrorCategory get errorCategory => issue.errorCategory;

  @override
  String toString() {
    final location = path == null ? '' : ' at $path';
    return 'Email candidate validation failed: ${issue.name}$location.';
  }
}

/// Strict decoder and canonical encoder for the normative email candidate
/// schema version 1.0.
///
/// Every object must contain exactly the documented fields. JSON surrounded by
/// prose, missing fields, extra fields and values outside the documented
/// bounds are rejected before a candidate may be persisted.
class EmailCandidatePayloadCodec {
  const EmailCandidatePayloadCodec();

  static const schemaVersion = '1.0';
  static const maxJsonBytes = 65536;
  static const maxTitleCharacters = 200;
  static const maxCourseNameCharacters = 160;
  static const maxCourseCodeCharacters = 64;
  static const maxRawDateTextCharacters = 240;
  static const maxLocationCharacters = 200;
  static const maxSubmissionUrlCharacters = 2048;
  static const maxSummaryCharacters = 1000;
  static const maxEvidenceItems = 8;
  static const maxEvidenceFieldCharacters = 64;
  static const maxEvidenceTextCharacters = 240;
  static const maxWarningItems = 16;
  static const maxWarningCharacters = 64;
  static const maxReminderItems = 8;
  static const minReminderMinutes = 0;
  static const maxReminderMinutes = 40320;

  static const allowedEvidenceFields = <String>{
    'candidate_type',
    'title',
    'course_hint.name',
    'course_hint.code',
    'due.at',
    'due.all_day',
    'due.timezone',
    'due.raw_text',
    'start_at',
    'end_at',
    'location',
    'submission_url',
    'summary',
  };

  static const allowedWarnings = <String>{
    'ambiguous_date',
    'ambiguous_year',
    'ambiguous_time',
    'ambiguous_course',
    'missing_title',
    'missing_date_time',
    'relative_date',
    'low_confidence',
    'untrusted_instruction_ignored',
  };

  static const _rootFields = <String>{
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
  };
  static const _courseFields = <String>{'name', 'code'};
  static const _dueFields = <String>{
    'at',
    'all_day',
    'timezone',
    'raw_text',
  };
  static const _confidenceFields = <String>{
    'overall',
    'title',
    'course',
    'date_time',
  };
  static const _evidenceFields = <String>{'field', 'text'};

  /// Decodes JSON and validates the exact schema. Leading or trailing JSON
  /// whitespace is allowed, but any prose or second JSON value is rejected.
  EmailCandidatePayload decode(String source) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: r'$json',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.malformedJson,
        path: r'$json',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidShape,
        path: r'$',
      );
    }
    return _decodeMap(decoded);
  }

  /// Validates an already-decoded object from an authenticated server response.
  EmailCandidatePayload decodeObject(Object? value) {
    if (value is! Map) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidShape,
        path: r'$',
      );
    }
    final map = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const EmailCandidateValidationException(
          EmailCandidateValidationIssue.invalidShape,
          path: r'$',
        );
      }
      map[entry.key as String] = entry.value;
    }
    final String encoded;
    try {
      encoded = jsonEncode(map);
    } catch (_) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: r'$',
      );
    }
    if (utf8.encode(encoded).length > maxJsonBytes) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: r'$json',
      );
    }
    return _decodeMap(map);
  }

  /// Returns a canonical JSON object after re-validating an in-memory payload.
  Map<String, Object?> toJson(EmailCandidatePayload payload) {
    final map = _uncheckedJson(payload);
    _decodeMap(Map<String, dynamic>.from(map));
    return map;
  }

  /// Returns compact canonical JSON after re-validating the payload.
  String encode(EmailCandidatePayload payload) => jsonEncode(toJson(payload));

  EmailCandidatePayload _decodeMap(Map<String, dynamic> map) {
    _expectExactFields(map, _rootFields, r'$');

    final version = _requiredString(
      map['schema_version'],
      r'$.schema_version',
      maxCharacters: 16,
    );
    if (version != schemaVersion) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.unsupportedSchema,
        path: r'$.schema_version',
      );
    }

    final candidateTypeWire = _requiredString(
      map['candidate_type'],
      r'$.candidate_type',
      maxCharacters: 32,
    );
    final EmailCandidateType candidateType;
    try {
      candidateType = EmailCandidateType.fromWire(candidateTypeWire);
    } on FormatException {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidEnum,
        path: r'$.candidate_type',
      );
    }

    final courseMap = _requiredMap(map['course_hint'], r'$.course_hint');
    _expectExactFields(courseMap, _courseFields, r'$.course_hint');
    final courseHint = EmailCourseHint(
      name: _nullableString(
        courseMap['name'],
        r'$.course_hint.name',
        maxCharacters: maxCourseNameCharacters,
      ),
      code: _nullableString(
        courseMap['code'],
        r'$.course_hint.code',
        maxCharacters: maxCourseCodeCharacters,
      ),
    );

    final dueMap = _requiredMap(map['due'], r'$.due');
    _expectExactFields(dueMap, _dueFields, r'$.due');
    final dueTimezone = _nullableString(
      dueMap['timezone'],
      r'$.due.timezone',
      maxCharacters: 64,
    );
    if (dueTimezone != null) {
      _validateIanaTimezone(dueTimezone, r'$.due.timezone');
    }
    final dueAt = _nullableTimestamp(dueMap['at'], r'$.due.at');
    final dueAllDay = _requiredBool(dueMap['all_day'], r'$.due.all_day');
    if (dueAllDay && dueAt == null) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidShape,
        path: r'$.due.all_day',
      );
    }
    final due = EmailDueCandidate(
      at: dueAt,
      allDay: dueAllDay,
      timezone: dueTimezone,
      rawText: _nullableString(
        dueMap['raw_text'],
        r'$.due.raw_text',
        maxCharacters: maxRawDateTextCharacters,
      ),
    );

    final startAt = _nullableTimestamp(map['start_at'], r'$.start_at');
    final endAt = _nullableTimestamp(map['end_at'], r'$.end_at');
    if ((startAt == null && endAt != null) ||
        (startAt != null && endAt != null && !endAt.isAfter(startAt))) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.inconsistentDateRange,
        path: r'$.end_at',
      );
    }

    final submissionUrl = _nullableString(
      map['submission_url'],
      r'$.submission_url',
      maxCharacters: maxSubmissionUrlCharacters,
      rejectUnsafeText: false,
    );
    if (submissionUrl != null) {
      _validateHttpsUrl(submissionUrl);
    }

    final reminders = _decodeReminders(map['suggested_reminders_minutes']);

    final confidenceMap = _requiredMap(map['confidence'], r'$.confidence');
    _expectExactFields(confidenceMap, _confidenceFields, r'$.confidence');
    final confidence = EmailCandidateConfidence(
      overall: _confidence(confidenceMap['overall'], r'$.confidence.overall'),
      title: _confidence(confidenceMap['title'], r'$.confidence.title'),
      course: _confidence(confidenceMap['course'], r'$.confidence.course'),
      dateTime:
          _confidence(confidenceMap['date_time'], r'$.confidence.date_time'),
    );

    final evidence = _decodeEvidence(map['evidence']);
    final warnings = _decodeWarnings(map['warnings']);
    final requiresConfirmation = _requiredBool(
      map['requires_user_confirmation'],
      r'$.requires_user_confirmation',
    );
    if (!requiresConfirmation) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.confirmationRequired,
        path: r'$.requires_user_confirmation',
      );
    }

    return EmailCandidatePayload(
      schemaVersion: version,
      candidateType: candidateType,
      title: _nullableString(
        map['title'],
        r'$.title',
        maxCharacters: maxTitleCharacters,
      ),
      courseHint: courseHint,
      due: due,
      startAt: startAt,
      endAt: endAt,
      location: _nullableString(
        map['location'],
        r'$.location',
        maxCharacters: maxLocationCharacters,
      ),
      submissionUrl: submissionUrl,
      summary: _nullableString(
        map['summary'],
        r'$.summary',
        maxCharacters: maxSummaryCharacters,
      ),
      suggestedRemindersMinutes: List.unmodifiable(reminders),
      confidence: confidence,
      evidence: List.unmodifiable(evidence),
      warnings: List.unmodifiable(warnings),
      requiresUserConfirmation: true,
    );
  }

  static List<int> _decodeReminders(Object? value) {
    if (value is! List) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: r'$.suggested_reminders_minutes',
      );
    }
    if (value.length > maxReminderItems) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: r'$.suggested_reminders_minutes',
      );
    }
    final result = <int>[];
    for (final item in value) {
      if (item is! int ||
          item < minReminderMinutes ||
          item > maxReminderMinutes) {
        throw const EmailCandidateValidationException(
          EmailCandidateValidationIssue.invalidReminder,
          path: r'$.suggested_reminders_minutes',
        );
      }
      if (!result.addIfAbsent(item)) {
        throw const EmailCandidateValidationException(
          EmailCandidateValidationIssue.invalidReminder,
          path: r'$.suggested_reminders_minutes',
        );
      }
    }
    return result;
  }

  static List<EmailCandidateEvidence> _decodeEvidence(Object? value) {
    if (value is! List) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: r'$.evidence',
      );
    }
    if (value.length > maxEvidenceItems) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: r'$.evidence',
      );
    }
    return List<EmailCandidateEvidence>.generate(value.length, (index) {
      final path = r'$.evidence[' + '$index]';
      final map = _requiredMap(value[index], path);
      _expectExactFields(map, _evidenceFields, path);
      final field = _requiredString(
        map['field'],
        '$path.field',
        maxCharacters: maxEvidenceFieldCharacters,
      );
      if (!allowedEvidenceFields.contains(field)) {
        throw EmailCandidateValidationException(
          EmailCandidateValidationIssue.invalidEvidence,
          path: '$path.field',
        );
      }
      return EmailCandidateEvidence(
        field: field,
        text: _requiredString(
          map['text'],
          '$path.text',
          maxCharacters: maxEvidenceTextCharacters,
        ),
      );
    });
  }

  static List<String> _decodeWarnings(Object? value) {
    if (value is! List) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: r'$.warnings',
      );
    }
    if (value.length > maxWarningItems) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: r'$.warnings',
      );
    }
    final result = <String>[];
    for (var index = 0; index < value.length; index++) {
      final warning = _requiredString(
        value[index],
        r'$.warnings[' + '$index]',
        maxCharacters: maxWarningCharacters,
      );
      if (!allowedWarnings.contains(warning) || !result.addIfAbsent(warning)) {
        throw EmailCandidateValidationException(
          EmailCandidateValidationIssue.invalidEnum,
          path: r'$.warnings[' + '$index]',
        );
      }
    }
    return result;
  }

  static Map<String, dynamic> _requiredMap(Object? value, String path) {
    if (value is! Map<String, dynamic>) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    return value;
  }

  static bool _requiredBool(Object? value, String path) {
    if (value is! bool) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    return value;
  }

  static String _requiredString(
    Object? value,
    String path, {
    required int maxCharacters,
    bool rejectUnsafeText = true,
  }) {
    if (value is! String) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidType,
        path: path,
      );
    }
    _validateBoundedString(
      value,
      path,
      maxCharacters: maxCharacters,
      rejectUnsafeText: rejectUnsafeText,
    );
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

  static void _validateBoundedString(
    String value,
    String path, {
    required int maxCharacters,
    required bool rejectUnsafeText,
  }) {
    if (value.isEmpty || value.trim() != value) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    final characters = value.runes.length;
    if (characters > maxCharacters || value.runes.any((rune) => rune < 0x20)) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    if (rejectUnsafeText && _unsafeText.hasMatch(value)) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.unsafeContent,
        path: path,
      );
    }
  }

  static double _confidence(Object? value, String path) {
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.valueOutOfBounds,
        path: path,
      );
    }
    return value.toDouble();
  }

  static DateTime? _nullableTimestamp(Object? value, String path) {
    if (value == null) return null;
    if (value is! String || !_rfc3339.hasMatch(value)) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidTimestamp,
        path: path,
      );
    }
    final match = _rfc3339.firstMatch(value)!;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    final offsetHour = int.tryParse(match.group(11) ?? '0') ?? 0;
    final offsetMinute = int.tryParse(match.group(12) ?? '0') ?? 0;
    if (!_isValidDate(year, month, day) ||
        hour > 23 ||
        minute > 59 ||
        second > 59 ||
        offsetHour > 14 ||
        offsetMinute > 59 ||
        (offsetHour == 14 && offsetMinute != 0)) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidTimestamp,
        path: path,
      );
    }
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidTimestamp,
        path: path,
      );
    }
  }

  static bool _isValidDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final nextMonth =
        month == 12 ? DateTime.utc(year + 1, 1) : DateTime.utc(year, month + 1);
    final daysInMonth = nextMonth.subtract(const Duration(days: 1)).day;
    return day <= daysInMonth;
  }

  static void _validateIanaTimezone(String value, String path) {
    _initializeTimezones();
    try {
      timezone.getLocation(value);
    } on timezone.LocationNotFoundException {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.invalidTimezone,
        path: path,
      );
    }
  }

  static void _validateHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host.toLowerCase() == 'localhost' ||
        uri.host.toLowerCase().endsWith('.localhost') ||
        uri.host.toLowerCase().endsWith('.local') ||
        _isNumericHostVariant(uri.host) ||
        _isLoopbackOrPrivateIpv4(uri.host)) {
      throw const EmailCandidateValidationException(
        EmailCandidateValidationIssue.unsafeUrl,
        path: r'$.submission_url',
      );
    }
  }

  static bool _isLoopbackOrPrivateIpv4(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList(growable: false);
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
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

  static bool _isNumericHostVariant(String host) {
    final numericPart = RegExp(
      r'^(?:\d+|0x[0-9a-f]+)$',
      caseSensitive: false,
    );
    final parts = host.split('.');
    return parts.isNotEmpty && parts.every(numericPart.hasMatch);
  }

  static void _expectExactFields(
    Map<String, dynamic> map,
    Set<String> expected,
    String path,
  ) {
    final missing = expected.difference(map.keys.toSet());
    if (missing.isNotEmpty) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.missingField,
        path: '$path.${missing.first}',
      );
    }
    final unknown = map.keys.toSet().difference(expected);
    if (unknown.isNotEmpty) {
      throw EmailCandidateValidationException(
        EmailCandidateValidationIssue.unknownField,
        path: '$path.<unknown>',
      );
    }
  }

  static Map<String, Object?> _uncheckedJson(EmailCandidatePayload payload) {
    String? timestamp(DateTime? value) => value?.toUtc().toIso8601String();

    return <String, Object?>{
      'schema_version': payload.schemaVersion,
      'candidate_type': payload.candidateType.wireName,
      'title': payload.title,
      'course_hint': <String, Object?>{
        'name': payload.courseHint.name,
        'code': payload.courseHint.code,
      },
      'due': <String, Object?>{
        'at': timestamp(payload.due.at),
        'all_day': payload.due.allDay,
        'timezone': payload.due.timezone,
        'raw_text': payload.due.rawText,
      },
      'start_at': timestamp(payload.startAt),
      'end_at': timestamp(payload.endAt),
      'location': payload.location,
      'submission_url': payload.submissionUrl,
      'summary': payload.summary,
      'suggested_reminders_minutes': payload.suggestedRemindersMinutes,
      'confidence': <String, Object?>{
        'overall': payload.confidence.overall,
        'title': payload.confidence.title,
        'course': payload.confidence.course,
        'date_time': payload.confidence.dateTime,
      },
      'evidence': payload.evidence
          .map(
            (item) => <String, Object?>{
              'field': item.field,
              'text': item.text,
            },
          )
          .toList(growable: false),
      'warnings': payload.warnings,
      'requires_user_confirmation': payload.requiresUserConfirmation,
    };
  }

  static final _rfc3339 = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(\.(\d{1,9}))?(Z|([+-])(\d{2}):(\d{2}))$',
  );
  static final _unsafeText = RegExp(
    r'<\s*/?\s*[a-z][^>]*>|\bon(?:load|error|click|mouseover)\s*=|'
    r'javascript\s*:',
    caseSensitive: false,
  );
}

/// Canonical schema 1.0 JSON for transport or persistence. Invalid manually
/// constructed payloads fail with [EmailCandidateValidationException].
extension EmailCandidatePayloadJson on EmailCandidatePayload {
  Map<String, Object?> toJson() =>
      const EmailCandidatePayloadCodec().toJson(this);

  String toCanonicalJson() => const EmailCandidatePayloadCodec().encode(this);
}

bool _timezoneDatabaseInitialized = false;

void _initializeTimezones() {
  if (_timezoneDatabaseInitialized) return;
  timezone_data.initializeTimeZones();
  _timezoneDatabaseInitialized = true;
}

extension on List<int> {
  bool addIfAbsent(int value) {
    if (contains(value)) return false;
    add(value);
    return true;
  }
}

extension on List<String> {
  bool addIfAbsent(String value) {
    if (contains(value)) return false;
    add(value);
    return true;
  }
}
