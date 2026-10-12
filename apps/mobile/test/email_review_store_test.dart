import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/drift_email_review_store.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';

void main() {
  const ownerUserId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2030, 4, 5, 6, 7, 8);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('editing an update proposal cannot turn it into a confirmable candidate',
      () async {
    final original = _assignmentPayload('元の課題');
    await db.emailImportDao.upsertConnection(
      ownerUserId: ownerUserId,
      connection: EmailConnectionsCompanion.insert(
        id: 'connection-1',
        ownerUserId: ownerUserId,
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: List.filled(64, 'a').join(),
        state: Value(EmailConnectionStatus.connected.wireName),
        updatedAt: Value(now),
      ),
    );
    await db.emailImportDao.upsertSource(
      ownerUserId: ownerUserId,
      source: EmailSourcesCompanion.insert(
        id: 'source-1',
        ownerUserId: ownerUserId,
        connectionId: 'connection-1',
        providerMessageId: 'message-1',
        providerThreadId: 'thread-1',
        receivedAt: now,
        sanitizedContentHash: List.filled(64, 'b').join(),
        processingState: const Value('processed'),
        updatedAt: Value(now),
      ),
    );
    await db.emailImportDao.upsertCandidate(
      ownerUserId: ownerUserId,
      candidate: EmailCandidatesCompanion.insert(
        id: 'candidate-1',
        ownerUserId: ownerUserId,
        sourceId: 'source-1',
        schemaVersion: original.schemaVersion,
        candidateType: original.candidateType.wireName,
        normalizedPayloadJson:
            const EmailCandidatePayloadCodec().encode(original),
        reviewState: Value(EmailCandidateReviewState.updateAvailable.wireName),
        semanticFingerprint: List.filled(64, 'c').join(),
        updatedAt: Value(now),
      ),
    );

    final store = DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
      clock: () => now.add(const Duration(minutes: 1)),
    );
    final gateway = _CountingConfirmationGateway();
    final controller = EmailReviewActionController(
      store: store,
      remoteActions: const _UnusedRemoteActions(),
      confirmationGateway: gateway,
    );
    addTearDown(controller.dispose);

    final confirmed = await controller.saveAndConfirm(
      ownerUserId: ownerUserId,
      candidateId: 'candidate-1',
      payload: _assignmentPayload('編集済み課題'),
      warningsAcknowledged: true,
    );

    expect(confirmed, isFalse);
    expect(gateway.calls, 0);
    expect(
      controller.state.failureCategory,
      EmailErrorCategory.validationFailed,
    );
    final row = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: 'candidate-1',
    );
    expect(
        row?.reviewState, EmailCandidateReviewState.updateAvailable.wireName);
    expect(
      const EmailCandidatePayloadCodec()
          .decode(row!.normalizedPayloadJson)
          .title,
      '編集済み課題',
    );
  });

  test('failed sentinel preserves its allow-listed source failure category',
      () async {
    await _seedCandidate(
      db,
      ownerUserId: ownerUserId,
      now: now,
      reviewState: EmailCandidateReviewState.failed,
      payloadJson: '{}',
      errorCategory: EmailErrorCategory.unsafeContent,
    );
    final store = DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
    );

    final item = (await store.watchCandidates(ownerUserId).first).single;

    expect(item.state, EmailCandidateReviewState.failed);
    expect(item.payload, isNull);
    expect(item.errorCategory, EmailErrorCategory.unsafeContent);
    expect(item.canRetry, isFalse);
  });

  test('malformed persisted payload remains a safe extraction failure',
      () async {
    // Simulate a malformed row retained from an older schema. Current writes are
    // rejected by the current candidate guard before they reach the review
    // store, so the legacy fixture must bypass that insert-time guard.
    await db
        .customStatement('DROP TRIGGER email_candidates_owner_guard_insert');
    await _seedCandidate(
      db,
      ownerUserId: ownerUserId,
      now: now,
      reviewState: EmailCandidateReviewState.readyForReview,
      payloadJson: '{}',
    );
    final store = DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
    );

    final item = (await store.watchCandidates(ownerUserId).first).single;

    expect(item.state, EmailCandidateReviewState.failed);
    expect(item.payload, isNull);
    expect(item.errorCategory, EmailErrorCategory.invalidExtraction);
  });

  test('dismissed tombstone remains visible without payload or evidence',
      () async {
    final payload = _assignmentPayload('除外する課題');
    await _seedCandidate(
      db,
      ownerUserId: ownerUserId,
      now: now,
      reviewState: EmailCandidateReviewState.readyForReview,
      payloadJson: const EmailCandidatePayloadCodec().encode(payload),
    );
    final store = DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
      clock: () => now.add(const Duration(minutes: 1)),
    );

    await store.dismiss(
      ownerUserId: ownerUserId,
      candidateId: 'candidate-test',
    );

    final item = (await store.watchCandidates(ownerUserId).first).single;
    expect(item.id, 'candidate-test');
    expect(item.state, EmailCandidateReviewState.dismissed);
    expect(item.payload, isNull);
    expect(item.errorCategory, isNull);
    expect(item.canRetry, isFalse);
    expect(
      await store.loadCandidate(
        ownerUserId: ownerUserId,
        candidateId: 'candidate-test',
      ),
      isNotNull,
    );
    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    expect(await db.select(db.emailDismissalTombstones).get(), hasLength(1));
  });
}

Future<void> _seedCandidate(
  AppDatabase db, {
  required String ownerUserId,
  required DateTime now,
  required EmailCandidateReviewState reviewState,
  required String payloadJson,
  EmailErrorCategory? errorCategory,
}) async {
  await db.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: EmailConnectionsCompanion.insert(
      id: 'connection-test',
      ownerUserId: ownerUserId,
      provider: EmailProvider.gmail.wireName,
      providerAccountHash: 'a' * 64,
      state: Value(EmailConnectionStatus.connected.wireName),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertSource(
    ownerUserId: ownerUserId,
    source: EmailSourcesCompanion.insert(
      id: 'source-test',
      ownerUserId: ownerUserId,
      connectionId: 'connection-test',
      providerMessageId: 'private-message-test',
      providerThreadId: 'private-thread-test',
      receivedAt: now,
      sanitizedContentHash: 'b' * 64,
      evidenceExcerptsJson: const Value('[]'),
      processingState: Value(
        reviewState == EmailCandidateReviewState.failed
            ? 'failed'
            : 'processed',
      ),
      errorCategory: Value(errorCategory?.wireName),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertCandidate(
    ownerUserId: ownerUserId,
    candidate: EmailCandidatesCompanion.insert(
      id: 'candidate-test',
      ownerUserId: ownerUserId,
      sourceId: 'source-test',
      schemaVersion: '1.0',
      candidateType: EmailCandidateType.assignment.wireName,
      normalizedPayloadJson: payloadJson,
      reviewState: Value(reviewState.wireName),
      semanticFingerprint: 'c' * 64,
      errorCategory: Value(errorCategory?.wireName),
      updatedAt: Value(now),
    ),
  );
}

EmailCandidatePayload _assignmentPayload(String title) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: EmailCandidateType.assignment,
    title: title,
    courseHint: const EmailCourseHint(name: '情報工学', code: 'CS101'),
    due: EmailDueCandidate(
      at: DateTime.utc(2030, 4, 10, 14, 59),
      timezone: 'Asia/Tokyo',
      rawText: '4月10日 23:59',
    ),
    confidence: const EmailCandidateConfidence(
      overall: 0.8,
      title: 0.9,
      course: 0.7,
      dateTime: 0.8,
    ),
    requiresUserConfirmation: true,
  );
}

final class _CountingConfirmationGateway
    implements EmailCandidateConfirmationGateway {
  int calls = 0;

  @override
  Future<EmailCandidateConfirmationResult> confirm({
    required String ownerUserId,
    required String candidateId,
    String? courseId,
  }) async {
    calls++;
    return EmailCandidateConfirmationResult(
      candidateId: candidateId,
      entityType: EmailCandidateType.assignment,
      entityId: 'entity-1',
      replayed: false,
    );
  }
}

final class _UnusedRemoteActions implements EmailReviewRemoteActions {
  const _UnusedRemoteActions();

  Never _unused() => throw StateError('Unexpected remote action in test.');

  @override
  Future<EmailConnectionState> connect({required String ownerUserId}) =>
      _unused();

  @override
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  }) =>
      _unused();

  @override
  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) =>
      _unused();

  @override
  Future<void> deleteAccountData({required String ownerUserId}) => _unused();

  @override
  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  }) =>
      _unused();

  @override
  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  }) =>
      _unused();
}
