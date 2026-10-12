import 'package:shared_domain/shared_domain.dart';
import 'package:shared_domain/email_import_trusted.dart';
import 'package:test/test.dart';

void main() {
  test('email wire states are explicit and reject unknown values', () {
    expect(EmailProvider.fromWire('gmail'), EmailProvider.gmail);
    expect(
      EmailConnectionStatus.fromWire('reauth_required'),
      EmailConnectionStatus.reauthRequired,
    );
    expect(
      EmailCandidateReviewState.fromWire('update_available'),
      EmailCandidateReviewState.updateAvailable,
    );
    expect(
      () => EmailConnectionStatus.fromWire('silently_connected'),
      throwsFormatException,
    );
  });

  test('connection failures expose only allow-listed categories', () {
    const state = EmailConnectionState(
      provider: EmailProvider.gmail,
      status: EmailConnectionStatus.failed,
      errorCategory: EmailErrorCategory.configurationMissing,
    );

    expect(state.errorCategory?.wireName, 'configuration_missing');
    expect(
      () => EmailErrorCategory.fromWire('provider response: token=secret'),
      throwsFormatException,
    );
  });

  test('candidate contract retains the mandatory confirmation boundary', () {
    final candidate = EmailCandidatePayload(
      schemaVersion: '1.0',
      candidateType: EmailCandidateType.assignment,
      title: 'レポート',
      courseHint: const EmailCourseHint(name: '情報科学'),
      due: EmailDueCandidate(
        at: DateTime.utc(2030, 7, 1, 8),
        timezone: 'Asia/Tokyo',
      ),
      confidence: const EmailCandidateConfidence(
        overall: 0.8,
        title: 0.9,
        course: 0.7,
        dateTime: 0.8,
      ),
      requiresUserConfirmation: true,
    );

    expect(candidate.schemaVersion, '1.0');
    expect(candidate.requiresUserConfirmation, isTrue);
    expect(candidate.candidateType.wireName, 'assignment');
  });

  test('trusted extractor input is separated from the mobile fetch result', () {
    final input = SanitizedEmailInput(
      receivedAt: DateTime.utc(2030, 1, 1),
      timezone: 'Asia/Tokyo',
      sanitizedSubject: 'synthetic subject',
      sanitizedContent: 'synthetic content',
    );

    expect(input.sanitizedContent, 'synthetic content');
  });

  test('failed fetch items carry only safe failure metadata', () {
    final failed = EmailFetchItem(
      providerMessageId: 'provider-message-1',
      providerThreadId: null,
      receivedAt: DateTime.utc(2030, 1, 1),
      sanitizedContentHash: 'a' * 64,
      evidenceExcerpts: const [],
      candidate: null,
      errorCategory: EmailErrorCategory.unsafeContent,
    );

    expect(failed.isFailed, isTrue);
    expect(failed.candidate, isNull);
    expect(failed.evidenceExcerpts, isEmpty);
    expect(failed.errorCategory, EmailErrorCategory.unsafeContent);
    expect(failed.errorCategory?.isCandidateRetryable, isFalse);
    expect(EmailErrorCategory.timeout.isCandidateRetryable, isTrue);
  });

  test('suppression acknowledgements expose only identity and reason', () {
    const suppression = EmailFetchSuppression(
      providerMessageIdHash:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      reason: EmailFetchSuppressionReason.dismissed,
    );
    const page = EmailFetchPage(
      items: [],
      suppressions: [suppression],
      nextCursor: 'cursor-after-suppression',
      hasMore: false,
    );

    expect(page.suppressions.single.providerMessageIdHash, hasLength(64));
    expect(page.suppressions.single.reason.wireName, 'dismissed');
    expect(
      EmailFetchSuppressionReason.fromWire('deduplicated'),
      EmailFetchSuppressionReason.deduplicated,
    );
    expect(
      () => EmailFetchSuppressionReason.fromWire('raw-content'),
      throwsFormatException,
    );
  });
}
