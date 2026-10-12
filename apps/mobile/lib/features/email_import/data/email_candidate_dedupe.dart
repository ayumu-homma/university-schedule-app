import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_domain/shared_domain.dart';

String emailCandidateSemanticFingerprint(
  EmailCandidatePayload payload, {
  CourseNormalizer? normalizer,
}) {
  final textNormalizer = normalizer ?? CourseNormalizer();
  String? normalized(String? value) {
    final result =
        value == null ? null : textNormalizer.normalizeTitle(value.trim());
    return result == null || result.isEmpty ? null : result;
  }

  final semantic = jsonEncode({
    'candidate_type': payload.candidateType.wireName,
    'title': normalized(payload.title),
    'course': normalized(
      payload.courseHint.code ?? payload.courseHint.name,
    ),
    'due_at': payload.due.at?.toUtc().toIso8601String(),
    'start_at': payload.startAt?.toUtc().toIso8601String(),
    'submission_url': payload.submissionUrl,
  });
  return sha256.convert(utf8.encode(semantic)).toString();
}

/// A proposal identity covers every field that explicit acceptance may apply
/// to the canonical entity or its durable notification request. It is kept
/// separate from the deliberately narrower source semantic fingerprint so a
/// location, end-time, memo, or reminder-only change cannot be discarded.
String emailCandidateUpdateFingerprint(EmailCandidatePayload payload) {
  final value = jsonEncode({
    'candidate_type': payload.candidateType.wireName,
    'course': payload.courseHint.code ?? payload.courseHint.name,
    'fields': emailScheduleFieldValues(payload),
  });
  return sha256.convert(utf8.encode(value)).toString();
}

/// Privacy-safe authentication for a canonical schedule mutation payload.
///
/// The recursive key sort makes the digest independent of map insertion order,
/// while timestamps use the same UTC wire form as the schedule sync boundary.
/// Only the digest is persisted by replay-provenance receipts.
String emailSchedulePayloadFingerprint(Map<String, Object?> payload) {
  final canonical = jsonEncode({
    'domain': 'email-schedule-payload-v1',
    'payload': _canonicalJsonValue(payload),
  });
  return base64Url
      .encode(sha256.convert(utf8.encode(canonical)).bytes)
      .replaceAll('=', '');
}

/// Matches Drift's SQLite `DateTime` storage precision.
///
/// Drift 2.x persists timestamps as whole Unix seconds. Schedule provenance
/// therefore has to authenticate the value that survives a database restart,
/// rather than a sub-second value that existed only in memory.
DateTime emailScheduleSqliteTimestamp(DateTime value) {
  final milliseconds = value.toUtc().millisecondsSinceEpoch;
  return DateTime.fromMillisecondsSinceEpoch(
    (milliseconds ~/ Duration.millisecondsPerSecond) *
        Duration.millisecondsPerSecond,
    isUtc: true,
  );
}

String emailCandidatePayloadFingerprint(EmailCandidatePayload payload) {
  final canonical = jsonEncode({
    'domain': 'email-candidate-payload-v1',
    'payload': jsonDecode(const EmailCandidatePayloadCodec().encode(payload)),
  });
  return base64Url
      .encode(sha256.convert(utf8.encode(canonical)).bytes)
      .replaceAll('=', '');
}

/// Produces the one full, type-stable entity shape used by edit receipts.
/// Transport payloads historically omit nullable columns such as Exam.scope
/// and Event.groupId, so normalizing them here prevents those fields from
/// falling outside replay authentication. Event.isAllDay intentionally stays
/// outside this legacy hash: email Events are always timed, while the general
/// Events table now persists the field and the transport boundary carries
/// `false`. Keeping the established replay shape preserves old receipts.
Map<String, Object?> emailScheduleReplayPayload({
  required EmailCandidateType entityType,
  required Map<String, Object?> payload,
}) {
  return switch (entityType) {
    EmailCandidateType.assignment => <String, Object?>{
        'id': payload['id'],
        'ownerUserId': payload['ownerUserId'],
        'courseId': payload['courseId'],
        'title': payload['title'],
        'dueAt': _sqliteScheduleTimestampValue(payload['dueAt']),
        'submissionUrl': payload['submissionUrl'],
        'memo': payload['memo'],
        'priority': payload['priority'],
        'visibilityLevel': payload['visibilityLevel'],
        'updatedAt': _sqliteScheduleTimestampValue(payload['updatedAt']),
        'deletedAt': _sqliteScheduleTimestampValue(payload['deletedAt']),
        'version': payload['version'],
      },
    EmailCandidateType.exam => <String, Object?>{
        'id': payload['id'],
        'ownerUserId': payload['ownerUserId'],
        'courseId': payload['courseId'],
        'title': payload['title'],
        'startAt': _sqliteScheduleTimestampValue(payload['startAt']),
        'endAt': _sqliteScheduleTimestampValue(payload['endAt']),
        'room': payload['room'],
        'scope': payload['scope'],
        'memo': payload['memo'],
        'examType': payload['examType'],
        'visibilityLevel': payload['visibilityLevel'],
        'updatedAt': _sqliteScheduleTimestampValue(payload['updatedAt']),
        'deletedAt': _sqliteScheduleTimestampValue(payload['deletedAt']),
        'version': payload['version'],
      },
    EmailCandidateType.event => <String, Object?>{
        'id': payload['id'],
        'ownerUserId': payload['ownerUserId'],
        'calendarId': payload['calendarId'],
        'groupId': payload['groupId'],
        'title': payload['title'],
        'kind': payload['kind'],
        'startAt': _sqliteScheduleTimestampValue(payload['startAt']),
        'endAt': _sqliteScheduleTimestampValue(payload['endAt']),
        'location': payload['location'],
        'description': payload['description'],
        'rrule': payload['rrule'],
        'timezone': payload['timezone'],
        'visibilityLevel': payload['visibilityLevel'],
        'updatedAt': _sqliteScheduleTimestampValue(payload['updatedAt']),
        'deletedAt': _sqliteScheduleTimestampValue(payload['deletedAt']),
        'version': payload['version'],
      },
    EmailCandidateType.announcement ||
    EmailCandidateType.unknown =>
      throw ArgumentError.value(entityType, 'entityType'),
  };
}

Object? _sqliteScheduleTimestampValue(Object? value) {
  if (value is DateTime) return emailScheduleSqliteTimestamp(value);
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return emailScheduleSqliteTimestamp(parsed);
  }
  return value;
}

Object? _canonicalJsonValue(Object? value, {String? key}) {
  if (value is DateTime) {
    final canonical = _scheduleTimestampKeys.contains(key)
        ? emailScheduleSqliteTimestamp(value)
        : value.toUtc();
    return canonical.toIso8601String();
  }
  if (value is String && _scheduleTimestampKeys.contains(key)) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return emailScheduleSqliteTimestamp(parsed).toIso8601String();
    }
  }
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJsonValue(value[key], key: key),
    };
  }
  if (value is Iterable) {
    return value.map(_canonicalJsonValue).toList(growable: false);
  }
  return value;
}

const _scheduleTimestampKeys = <String>{
  'dueAt',
  'startAt',
  'endAt',
  'updatedAt',
  'deletedAt',
  'due_at',
  'start_at',
  'end_at',
  'updated_at',
  'deleted_at',
};

Map<String, Object?> emailScheduleFieldValues(
  EmailCandidatePayload payload,
) {
  String? timestamp(DateTime? value) => value?.toUtc().toIso8601String();

  return switch (payload.candidateType) {
    EmailCandidateType.assignment => <String, Object?>{
        'title': payload.title,
        'due_at': timestamp(payload.due.at),
        'due_all_day': payload.due.allDay,
        'due_timezone': payload.due.timezone,
        'submission_url': payload.submissionUrl,
        'summary': payload.summary,
        'suggested_reminders_minutes': payload.suggestedRemindersMinutes,
      },
    EmailCandidateType.exam || EmailCandidateType.event => <String, Object?>{
        'title': payload.title,
        'start_at': timestamp(payload.startAt),
        'end_at': timestamp(payload.endAt),
        'due_timezone': payload.due.timezone,
        'location': payload.location,
        'summary': payload.summary,
        'suggested_reminders_minutes': payload.suggestedRemindersMinutes,
      },
    EmailCandidateType.announcement ||
    EmailCandidateType.unknown =>
      const <String, Object?>{},
  };
}

Map<String, Object?> emailScheduleFieldDiff({
  required EmailCandidatePayload baseline,
  required EmailCandidatePayload proposed,
}) {
  if (baseline.candidateType != proposed.candidateType) {
    return const <String, Object?>{};
  }
  final before = emailScheduleFieldValues(baseline);
  final after = emailScheduleFieldValues(proposed);
  final diff = <String, Object?>{};
  for (final field in before.keys) {
    if (!_emailFieldEquals(before[field], after[field])) {
      diff[field] = <String, Object?>{
        'before': before[field],
        'after': after[field],
      };
    }
  }
  return diff;
}

bool _emailFieldEquals(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_emailFieldEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) ||
          !_emailFieldEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
