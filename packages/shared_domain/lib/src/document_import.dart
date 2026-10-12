/// Mobile-safe contracts for importing schedule candidates from a private
/// class document. Raw document bytes and provider responses never appear in
/// these value objects.
enum DocumentMediaType {
  pdf('application/pdf'),
  png('image/png'),
  jpeg('image/jpeg'),
  plainText('text/plain');

  const DocumentMediaType(this.mimeType);

  final String mimeType;

  static DocumentMediaType fromMimeType(String value) {
    return DocumentMediaType.values.firstWhere(
      (type) => type.mimeType == value,
      orElse: () => throw const FormatException('Unsupported document type.'),
    );
  }
}

enum DocumentImportState {
  selected('selected'),
  uploading('uploading'),
  analyzing('analyzing'),
  readyForReview('ready_for_review'),
  partiallyConfirmed('partially_confirmed'),
  confirmed('confirmed'),
  failed('failed'),
  deleted('deleted');

  const DocumentImportState(this.wireName);

  final String wireName;

  static DocumentImportState fromWire(String value) {
    return DocumentImportState.values.firstWhere(
      (state) => state.wireName == value,
      orElse: () => throw const FormatException('Unsupported import state.'),
    );
  }
}

enum DocumentImportErrorCategory {
  configurationMissing('configuration_missing', false),
  unsupportedType('unsupported_type', false),
  oversizedFile('oversized_file', false),
  oversizedDocument('oversized_document', false),
  corruptDocument('corrupt_document', false),
  encryptedDocument('encrypted_document', false),
  spoofedMediaType('spoofed_media_type', false),
  unsafeContent('unsafe_content', false),
  invalidExtraction('invalid_extraction', false),
  rateLimited('rate_limited', true),
  timeout('timeout', true),
  networkUnavailable('network_unavailable', true),
  providerUnavailable('provider_unavailable', true),
  cancelled('cancelled', true),
  internalError('internal_error', true);

  const DocumentImportErrorCategory(this.wireName, this.isRetryable);

  final String wireName;
  final bool isRetryable;

  static DocumentImportErrorCategory fromWire(String value) {
    return DocumentImportErrorCategory.values.firstWhere(
      (category) => category.wireName == value,
      orElse: () =>
          throw const FormatException('Unsupported document error category.'),
    );
  }
}

enum DocumentCandidateType {
  assignment('assignment'),
  exam('exam');

  const DocumentCandidateType(this.wireName);

  final String wireName;

  static DocumentCandidateType fromWire(String value) {
    return DocumentCandidateType.values.firstWhere(
      (type) => type.wireName == value,
      orElse: () => throw const FormatException('Unsupported candidate type.'),
    );
  }
}

enum DocumentCandidateReviewState {
  needsReview('needs_review'),
  excluded('excluded'),
  confirmed('confirmed'),
  failed('failed');

  const DocumentCandidateReviewState(this.wireName);

  final String wireName;

  static DocumentCandidateReviewState fromWire(String value) {
    return DocumentCandidateReviewState.values.firstWhere(
      (state) => state.wireName == value,
      orElse: () => throw const FormatException('Unsupported review state.'),
    );
  }
}

enum DocumentCandidateWarning {
  missingYear('missing_year'),
  missingDate('missing_date'),
  missingTime('missing_time'),
  ambiguousCourse('ambiguous_course'),
  duplicateMention('duplicate_mention'),
  relativeDate('relative_date'),
  lowConfidence('low_confidence');

  const DocumentCandidateWarning(this.wireName);

  final String wireName;

  static DocumentCandidateWarning fromWire(String value) {
    return DocumentCandidateWarning.values.firstWhere(
      (warning) => warning.wireName == value,
      orElse: () => throw const FormatException('Unsupported warning.'),
    );
  }
}

class DocumentCourseHint {
  const DocumentCourseHint({this.name, this.code});

  final String? name;
  final String? code;
}

class DocumentCandidateConfidence {
  const DocumentCandidateConfidence({
    required this.overall,
    required this.course,
    required this.dateTime,
  });

  final double overall;
  final double course;
  final double dateTime;
}

class DocumentCandidateEvidence {
  const DocumentCandidateEvidence({
    required this.excerpt,
    this.pageNumber,
    this.section,
  });

  final int? pageNumber;
  final String? section;
  final String excerpt;
}

/// A proposal only. No schedule entity, reminder, projection, or sync
/// mutation may be created until a user explicitly confirms this candidate.
class DocumentScheduleCandidate {
  const DocumentScheduleCandidate({
    required this.candidateId,
    required this.type,
    required this.title,
    required this.courseHint,
    required this.allDay,
    required this.timezone,
    required this.confidence,
    required this.evidence,
    required this.warnings,
    required this.requiresUserConfirmation,
    this.dueAt,
    this.startAt,
    this.endAt,
    this.location,
    this.submissionUrl,
    this.notes,
  });

  final String candidateId;
  final DocumentCandidateType type;
  final String title;
  final DocumentCourseHint courseHint;
  final DateTime? dueAt;
  final bool allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? location;
  final String? submissionUrl;
  final String? notes;
  final String timezone;
  final DocumentCandidateConfidence confidence;
  final List<DocumentCandidateEvidence> evidence;
  final List<DocumentCandidateWarning> warnings;
  final bool requiresUserConfirmation;

  DocumentScheduleCandidate copyWith({
    DocumentCandidateType? type,
    String? title,
    DocumentCourseHint? courseHint,
    DateTime? dueAt,
    bool clearDueAt = false,
    bool? allDay,
    DateTime? startAt,
    bool clearStartAt = false,
    DateTime? endAt,
    bool clearEndAt = false,
    String? location,
    bool clearLocation = false,
    String? submissionUrl,
    String? notes,
    List<DocumentCandidateWarning>? warnings,
  }) {
    return DocumentScheduleCandidate(
      candidateId: candidateId,
      type: type ?? this.type,
      title: title ?? this.title,
      courseHint: courseHint ?? this.courseHint,
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      allDay: allDay ?? this.allDay,
      startAt: clearStartAt ? null : (startAt ?? this.startAt),
      endAt: clearEndAt ? null : (endAt ?? this.endAt),
      location: clearLocation ? null : (location ?? this.location),
      submissionUrl: submissionUrl ?? this.submissionUrl,
      notes: notes ?? this.notes,
      timezone: timezone,
      confidence: confidence,
      evidence: evidence,
      warnings: warnings ?? this.warnings,
      requiresUserConfirmation: requiresUserConfirmation,
    );
  }
}

class ScheduleCandidateBatch {
  const ScheduleCandidateBatch({
    required this.schemaVersion,
    required this.sourceId,
    required this.contentHash,
    required this.timezone,
    required this.candidates,
  });

  final String schemaVersion;
  final String sourceId;
  final String contentHash;
  final String timezone;
  final List<DocumentScheduleCandidate> candidates;
}

class DocumentConfirmationItem {
  const DocumentConfirmationItem({
    required this.candidateId,
    this.courseId,
  });

  final String candidateId;
  final String? courseId;
}

class DocumentConfirmationSuccess {
  const DocumentConfirmationSuccess({
    required this.candidateId,
    required this.entityType,
    required this.entityId,
    required this.replayed,
  });

  final String candidateId;
  final DocumentCandidateType entityType;
  final String entityId;
  final bool replayed;
}

class DocumentConfirmationFailure {
  const DocumentConfirmationFailure({
    required this.candidateId,
    required this.errorCategory,
  });

  final String candidateId;
  final DocumentImportErrorCategory errorCategory;
}

class DocumentBulkConfirmationResult {
  const DocumentBulkConfirmationResult({
    required this.confirmed,
    required this.failed,
  });

  final List<DocumentConfirmationSuccess> confirmed;
  final List<DocumentConfirmationFailure> failed;

  bool get hasPartialSuccess => confirmed.isNotEmpty && failed.isNotEmpty;
}
