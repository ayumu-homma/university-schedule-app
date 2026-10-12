import 'document_candidate_codec.dart';
import 'document_import.dart';

class SanitizedDocumentInput {
  const SanitizedDocumentInput({
    required this.sourceId,
    required this.contentHash,
    required this.mediaType,
    required this.byteLength,
    required this.pageCount,
    required this.sanitizedText,
    required this.uploadedAt,
    this.timezone = DocumentCandidateBatchCodec.timezone,
  });

  final String sourceId;
  final String contentHash;
  final DocumentMediaType mediaType;
  final int byteLength;
  final int pageCount;
  final String sanitizedText;
  final DateTime uploadedAt;
  final String timezone;
}

abstract interface class DocumentScheduleExtractor {
  Future<ScheduleCandidateBatch> extract(SanitizedDocumentInput input);
}

/// Enforces the same bounded, fail-closed contract around fake and production
/// adapters. Prompt-like text remains inert document data; this boundary never
/// exposes URL fetching, tools, or executable instructions.
class GuardedDocumentScheduleExtractor implements DocumentScheduleExtractor {
  const GuardedDocumentScheduleExtractor(this.delegate);

  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxPageCount = 80;
  static const maxTextCharacters = 200000;

  final DocumentScheduleExtractor delegate;

  @override
  Future<ScheduleCandidateBatch> extract(SanitizedDocumentInput input) async {
    _validateInput(input);
    final untrusted = await delegate.extract(input);
    final validated = const DocumentCandidateBatchCodec().decodeObject(
      const DocumentCandidateBatchCodec().toJson(untrusted),
    );
    if (validated.sourceId != input.sourceId ||
        validated.contentHash != input.contentHash ||
        validated.timezone != input.timezone) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.inconsistentCandidate,
        path: r'$',
      );
    }
    return validated;
  }

  static void _validateInput(SanitizedDocumentInput input) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
            .hasMatch(input.sourceId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(input.contentHash) ||
        input.byteLength < 1 ||
        input.byteLength > maxFileBytes ||
        input.pageCount < 1 ||
        input.pageCount > maxPageCount ||
        input.sanitizedText.isEmpty ||
        input.sanitizedText.runes.length > maxTextCharacters ||
        input.sanitizedText.contains('\u0000') ||
        input.timezone != DocumentCandidateBatchCodec.timezone ||
        _activeMarkup.hasMatch(input.sanitizedText)) {
      throw const DocumentCandidateValidationException(
        DocumentCandidateValidationIssue.unsafeContent,
        path: r'$input',
      );
    }
  }

  static final _activeMarkup = RegExp(
    r'<\s*/?\s*(?:script|iframe|object|embed)[^>]*>|'
    r'\bon(?:load|error|click)\s*=|javascript\s*:',
    caseSensitive: false,
  );
}

/// Secret-free deterministic composition used by unit tests, local demo mode,
/// screenshots, and CI. It is never silently substituted for the production
/// server adapter.
class DeterministicDocumentScheduleExtractor
    implements DocumentScheduleExtractor {
  const DeterministicDocumentScheduleExtractor();

  @override
  Future<ScheduleCandidateBatch> extract(SanitizedDocumentInput input) async {
    return ScheduleCandidateBatch(
      schemaVersion: DocumentCandidateBatchCodec.schemaVersion,
      sourceId: input.sourceId,
      contentHash: input.contentHash,
      timezone: input.timezone,
      candidates: [
        DocumentScheduleCandidate(
          candidateId: '${input.sourceId}:assignment:1',
          type: DocumentCandidateType.assignment,
          title: '第8回アルゴリズムレポート',
          courseHint: const DocumentCourseHint(
            name: 'アルゴリズムとデータ構造Ⅰ',
            code: 'CS-201',
          ),
          dueAt: DateTime.utc(2026, 8, 20, 14, 59),
          allDay: false,
          timezone: input.timezone,
          submissionUrl: 'https://lms.example.edu/assignments/synthetic-8',
          notes: 'ソートアルゴリズムの計算量を比較する。',
          confidence: const DocumentCandidateConfidence(
            overall: 0.96,
            course: 0.94,
            dateTime: 0.98,
          ),
          evidence: const [
            DocumentCandidateEvidence(
              pageNumber: 12,
              section: '課題',
              excerpt: '第8回レポートの提出期限は8月20日23時59分です。',
            ),
          ],
          warnings: const [],
          requiresUserConfirmation: true,
        ),
        DocumentScheduleCandidate(
          candidateId: '${input.sourceId}:assignment:2',
          type: DocumentCandidateType.assignment,
          title: 'セキュリティ演習ワークシート',
          courseHint: const DocumentCourseHint(name: '情報セキュリティ'),
          dueAt: DateTime.utc(2026, 8, 23, 15),
          allDay: true,
          timezone: input.timezone,
          notes: '時刻は資料に明記されていないため要確認。',
          confidence: const DocumentCandidateConfidence(
            overall: 0.82,
            course: 0.91,
            dateTime: 0.7,
          ),
          evidence: const [
            DocumentCandidateEvidence(
              pageNumber: 15,
              section: '演習',
              excerpt: 'ワークシートは8月24日までに提出すること。',
            ),
          ],
          warnings: const [DocumentCandidateWarning.missingTime],
          requiresUserConfirmation: true,
        ),
        DocumentScheduleCandidate(
          candidateId: '${input.sourceId}:exam:1',
          type: DocumentCandidateType.exam,
          title: '達成度確認',
          courseHint: const DocumentCourseHint(name: '情報セキュリティ'),
          allDay: false,
          startAt: DateTime.utc(2026, 8, 27, 1, 35),
          endAt: DateTime.utc(2026, 8, 27, 3, 5),
          location: 'B203',
          timezone: input.timezone,
          confidence: const DocumentCandidateConfidence(
            overall: 0.93,
            course: 0.9,
            dateTime: 0.95,
          ),
          evidence: const [
            DocumentCandidateEvidence(
              pageNumber: 18,
              section: '試験',
              excerpt: '8月27日10時35分からB203教室で達成度確認を実施します。',
            ),
          ],
          warnings: const [],
          requiresUserConfirmation: true,
        ),
      ],
    );
  }
}
