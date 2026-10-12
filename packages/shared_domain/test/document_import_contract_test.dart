import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  test('wire enums are explicit and unknown values fail closed', () {
    expect(
      DocumentMediaType.fromMimeType('application/pdf'),
      DocumentMediaType.pdf,
    );
    expect(
      DocumentImportState.fromWire('ready_for_review'),
      DocumentImportState.readyForReview,
    );
    expect(
      DocumentCandidateType.fromWire('exam'),
      DocumentCandidateType.exam,
    );
    expect(
      () => DocumentCandidateType.fromWire('execute_tool'),
      throwsFormatException,
    );
    expect(
      () => DocumentImportErrorCategory.fromWire('provider body: secret'),
      throwsFormatException,
    );
  });

  test('safe error categories expose an explicit retry policy', () {
    expect(DocumentImportErrorCategory.timeout.isRetryable, isTrue);
    expect(DocumentImportErrorCategory.cancelled.isRetryable, isTrue);
    expect(DocumentImportErrorCategory.unsafeContent.isRetryable, isFalse);
    expect(DocumentImportErrorCategory.encryptedDocument.isRetryable, isFalse);
  });

  test('bulk confirmation reports partial success without hiding failures', () {
    const result = DocumentBulkConfirmationResult(
      confirmed: [
        DocumentConfirmationSuccess(
          candidateId: 'candidate-1',
          entityType: DocumentCandidateType.assignment,
          entityId: 'assignment-1',
          replayed: false,
        ),
      ],
      failed: [
        DocumentConfirmationFailure(
          candidateId: 'candidate-2',
          errorCategory: DocumentImportErrorCategory.invalidExtraction,
        ),
      ],
    );

    expect(result.hasPartialSuccess, isTrue);
    expect(result.confirmed, hasLength(1));
    expect(result.failed, hasLength(1));
  });
}
