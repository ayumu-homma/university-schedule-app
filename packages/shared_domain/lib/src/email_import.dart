/// Provider-independent contracts and value objects for the private email
/// import boundary.
///
/// Provider SDK objects, OAuth material and message contents intentionally do
/// not appear in this mobile-facing API. Production connectors call an
/// authenticated trusted endpoint and receive only source metadata plus a
/// validated proposal.
enum EmailProvider {
  gmail('gmail');

  const EmailProvider(this.wireName);

  final String wireName;

  static EmailProvider fromWire(String value) {
    return EmailProvider.values.firstWhere(
      (provider) => provider.wireName == value,
      orElse: () => throw FormatException('Unsupported email provider.'),
    );
  }
}

enum EmailConnectionStatus {
  disconnected('disconnected'),
  connecting('connecting'),
  connected('connected'),
  reauthRequired('reauth_required'),
  rateLimited('rate_limited'),
  failed('failed'),
  disconnecting('disconnecting');

  const EmailConnectionStatus(this.wireName);

  final String wireName;

  static EmailConnectionStatus fromWire(String value) {
    return EmailConnectionStatus.values.firstWhere(
      (status) => status.wireName == value,
      orElse: () => throw FormatException('Unsupported connection status.'),
    );
  }
}

/// Non-sensitive categories that may cross the trusted boundary or be stored.
/// Provider response text and exception details must never be substituted for
/// one of these values.
enum EmailErrorCategory {
  authorizationRevoked('authorization_revoked'),
  cursorExpired('cursor_expired'),
  rateLimited('rate_limited'),
  timeout('timeout'),
  networkUnavailable('network_unavailable'),
  providerUnavailable('provider_unavailable'),
  configurationMissing('configuration_missing'),
  malformedContent('malformed_content'),
  oversizedContent('oversized_content'),
  unsafeContent('unsafe_content'),
  invalidExtraction('invalid_extraction'),
  unsupportedSchema('unsupported_schema'),
  unsafeUrl('unsafe_url'),
  validationFailed('validation_failed'),
  internalError('internal_error');

  const EmailErrorCategory(this.wireName);

  final String wireName;

  static EmailErrorCategory fromWire(String value) {
    return EmailErrorCategory.values.firstWhere(
      (category) => category.wireName == value,
      orElse: () => throw FormatException('Unsupported email error category.'),
    );
  }

  /// Only transient, source-specific failures may be retried in place.
  /// Content, schema, authorization and cursor failures require dismissal or
  /// a different recovery flow and must not repeatedly reprocess the message.
  bool get isCandidateRetryable => switch (this) {
        EmailErrorCategory.rateLimited ||
        EmailErrorCategory.timeout ||
        EmailErrorCategory.networkUnavailable ||
        EmailErrorCategory.providerUnavailable ||
        EmailErrorCategory.internalError =>
          true,
        EmailErrorCategory.authorizationRevoked ||
        EmailErrorCategory.cursorExpired ||
        EmailErrorCategory.configurationMissing ||
        EmailErrorCategory.malformedContent ||
        EmailErrorCategory.oversizedContent ||
        EmailErrorCategory.unsafeContent ||
        EmailErrorCategory.invalidExtraction ||
        EmailErrorCategory.unsupportedSchema ||
        EmailErrorCategory.unsafeUrl ||
        EmailErrorCategory.validationFailed =>
          false,
      };
}

enum EmailCandidateType {
  assignment('assignment'),
  exam('exam'),
  event('event'),
  announcement('announcement'),
  unknown('unknown');

  const EmailCandidateType(this.wireName);

  final String wireName;

  static EmailCandidateType fromWire(String value) {
    return EmailCandidateType.values.firstWhere(
      (type) => type.wireName == value,
      orElse: () => throw FormatException('Unsupported candidate type.'),
    );
  }
}

enum EmailCandidateReviewState {
  needsReview('needs_review'),
  readyForReview('ready_for_review'),
  updateAvailable('update_available'),
  confirmed('confirmed'),
  dismissed('dismissed'),
  failed('failed');

  const EmailCandidateReviewState(this.wireName);

  final String wireName;

  static EmailCandidateReviewState fromWire(String value) {
    return EmailCandidateReviewState.values.firstWhere(
      (state) => state.wireName == value,
      orElse: () => throw FormatException('Unsupported review state.'),
    );
  }
}

enum EmailCandidateUpdateState {
  pending('pending'),
  accepted('accepted'),
  rejected('rejected');

  const EmailCandidateUpdateState(this.wireName);

  final String wireName;
}

class EmailConnectionState {
  const EmailConnectionState({
    required this.provider,
    required this.status,
    this.errorCategory,
    this.retryAfter,
    this.connectedAt,
    this.oauthChallenge,
  })  : assert(
          status == EmailConnectionStatus.failed || errorCategory == null,
          'Only failed connection state may carry a general error category.',
        ),
        assert(
          status == EmailConnectionStatus.connecting || oauthChallenge == null,
          'Only a connecting state may carry an OAuth challenge.',
        );

  final EmailProvider provider;
  final EmailConnectionStatus status;
  final EmailErrorCategory? errorCategory;
  final Duration? retryAfter;
  final DateTime? connectedAt;
  final EmailOAuthAuthorizationChallenge? oauthChallenge;
}

/// A short-lived, public PKCE authorization request returned by the trusted
/// server. It contains no verifier, access token, refresh token, email address,
/// or message content and must never be persisted or logged by the client.
class EmailOAuthAuthorizationChallenge {
  const EmailOAuthAuthorizationChallenge({
    required this.authorizationUri,
    required this.codeChallenge,
    required this.expiresAt,
  });

  final Uri authorizationUri;
  final String codeChallenge;
  final DateTime expiresAt;
}

class EmailFetchItem {
  const EmailFetchItem({
    required this.providerMessageId,
    required this.providerThreadId,
    required this.receivedAt,
    required this.sanitizedContentHash,
    required this.evidenceExcerpts,
    required this.candidate,
    this.errorCategory,
  })  : assert(
          (candidate == null) == (errorCategory != null),
          'A fetch item must contain either one candidate or one safe error.',
        ),
        assert(
          candidate != null || evidenceExcerpts.length == 0,
          'Failed fetch items cannot retain evidence excerpts.',
        ),
        assert(
          candidate == null || providerThreadId != null,
          'Successful fetch items require a provider thread identity.',
        );

  final String providerMessageId;
  final String? providerThreadId;
  final DateTime receivedAt;
  final String sanitizedContentHash;
  final List<String> evidenceExcerpts;
  final EmailCandidatePayload? candidate;
  final EmailErrorCategory? errorCategory;

  bool get isFailed => errorCategory != null;
}

enum EmailFetchSuppressionReason {
  dismissed('dismissed'),
  deduplicated('deduplicated');

  const EmailFetchSuppressionReason(this.wireName);

  final String wireName;

  static EmailFetchSuppressionReason fromWire(String value) {
    return EmailFetchSuppressionReason.values.firstWhere(
      (reason) => reason.wireName == value,
      orElse: () => throw const FormatException(
        'Unsupported email fetch suppression reason.',
      ),
    );
  }
}

/// A trusted acknowledgement that a provider message produced no review item.
/// It carries only the opaque message identity needed to prune a stale failed
/// cache entry; no email content, candidate payload, or evidence is retained.
class EmailFetchSuppression {
  const EmailFetchSuppression({
    required this.providerMessageIdHash,
    required this.reason,
  });

  final String providerMessageIdHash;
  final EmailFetchSuppressionReason reason;
}

class EmailFetchPage {
  const EmailFetchPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    this.suppressions = const [],
  });

  final List<EmailFetchItem> items;
  final String? nextCursor;
  final bool hasMore;
  final List<EmailFetchSuppression> suppressions;
}

abstract interface class EmailConnector {
  EmailProvider get provider;

  Future<EmailConnectionState> connect();

  Future<EmailFetchPage> fetchDelta({String? cursor});

  Future<void> disconnect({required bool deleteDerivedData});
}

class EmailCourseHint {
  const EmailCourseHint({this.name, this.code});

  final String? name;
  final String? code;
}

class EmailDueCandidate {
  const EmailDueCandidate({
    this.at,
    this.allDay = false,
    this.timezone,
    this.rawText,
  });

  final DateTime? at;
  final bool allDay;
  final String? timezone;
  final String? rawText;
}

class EmailCandidateConfidence {
  const EmailCandidateConfidence({
    required this.overall,
    required this.title,
    required this.course,
    required this.dateTime,
  });

  final double overall;
  final double title;
  final double course;
  final double dateTime;
}

class EmailCandidateEvidence {
  const EmailCandidateEvidence({required this.field, required this.text});

  final String field;
  final String text;
}

/// Version 1.0 structured proposal. Validation is deliberately a separate
/// boundary: model-backed and fake extractors both return untrusted proposals
/// that must pass the same validator before persistence.
class EmailCandidatePayload {
  const EmailCandidatePayload({
    required this.schemaVersion,
    required this.candidateType,
    required this.courseHint,
    required this.due,
    required this.confidence,
    required this.requiresUserConfirmation,
    this.title,
    this.startAt,
    this.endAt,
    this.location,
    this.submissionUrl,
    this.summary,
    this.suggestedRemindersMinutes = const [],
    this.evidence = const [],
    this.warnings = const [],
  });

  final String schemaVersion;
  final EmailCandidateType candidateType;
  final String? title;
  final EmailCourseHint courseHint;
  final EmailDueCandidate due;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? location;
  final String? submissionUrl;
  final String? summary;
  final List<int> suggestedRemindersMinutes;
  final EmailCandidateConfidence confidence;
  final List<EmailCandidateEvidence> evidence;
  final List<String> warnings;
  final bool requiresUserConfirmation;
}

extension EmailCandidatePayloadTimezone on EmailCandidatePayload {
  /// Returns the same proposal with the trusted configured timezone attached.
  ///
  /// The schema has no top-level timezone field, so every candidate type uses
  /// `due.timezone` as its review/notification timezone, including Exam and
  /// Event proposals whose `due.at` remains null.
  EmailCandidatePayload withConfiguredTimezone(String timezone) {
    return EmailCandidatePayload(
      schemaVersion: schemaVersion,
      candidateType: candidateType,
      title: title,
      courseHint: courseHint,
      due: EmailDueCandidate(
        at: due.at,
        allDay: due.allDay,
        timezone: timezone,
        rawText: due.rawText,
      ),
      startAt: startAt,
      endAt: endAt,
      location: location,
      submissionUrl: submissionUrl,
      summary: summary,
      suggestedRemindersMinutes: suggestedRemindersMinutes,
      confidence: confidence,
      evidence: evidence,
      warnings: warnings,
      requiresUserConfirmation: requiresUserConfirmation,
    );
  }
}
