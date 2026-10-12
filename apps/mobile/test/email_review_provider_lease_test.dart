import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/drift_email_review_store.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  test('production review provider lease is revoked across ABA and DB swap',
      () async {
    final db1 = AppDatabase(NativeDatabase.memory());
    final db2 = AppDatabase(NativeDatabase.memory());
    const ownerA = 'owner-a';
    const ownerB = 'owner-b';
    final session = StateProvider<AppAuthSession?>(
      (_) => const AppAuthSession(userId: ownerA),
    );
    final database = StateProvider<AppDatabase>((_) => db1);
    final payload = _payload('original');
    await _seedCandidate(db1, payload);

    final container = ProviderContainer(
      overrides: [
        currentAuthSessionProvider.overrideWith(
          (ref) => ref.watch(session),
        ),
        appDatabaseProvider.overrideWith(
          (ref) => ref.watch(database),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db1.close();
      await db2.close();
    });

    final oldStore =
        container.read(emailReviewStoreProvider) as DriftEmailReviewStore;
    await oldStore.saveDraft(
      ownerUserId: ownerA,
      candidateId: 'candidate-1',
      payload: payload,
    );
    final beforeSwitch = await db1.emailImportDao.candidateById(
      ownerUserId: ownerA,
      candidateId: 'candidate-1',
    );

    container.read(session.notifier).state =
        const AppAuthSession(userId: ownerB);
    await Future<void>.delayed(Duration.zero);
    container.read(session.notifier).state =
        const AppAuthSession(userId: ownerA);
    container.read(database.notifier).state = db2;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(oldStore.lease?.isRevoked, isTrue);
    await expectLater(
      oldStore.saveDraft(
        ownerUserId: ownerA,
        candidateId: 'candidate-1',
        payload: _payload('stale-write'),
      ),
      throwsA(isA<EmailReviewActionException>()),
    );
    final afterSwitch = await db1.emailImportDao.candidateById(
      ownerUserId: ownerA,
      candidateId: 'candidate-1',
    );
    expect(afterSwitch?.normalizedPayloadJson,
        beforeSwitch?.normalizedPayloadJson);
    expect(await db2.select(db2.emailCandidates).get(), isEmpty);
  });
}

Future<void> _seedCandidate(
    AppDatabase db, EmailCandidatePayload payload) async {
  final now = DateTime.utc(2030, 4, 5, 6, 7, 8);
  await db.emailImportDao.upsertConnection(
    ownerUserId: 'owner-a',
    connection: EmailConnectionsCompanion.insert(
      id: 'connection-1',
      ownerUserId: 'owner-a',
      provider: EmailProvider.gmail.wireName,
      providerAccountHash: 'a' * 64,
      state: const Value('connected'),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertSource(
    ownerUserId: 'owner-a',
    source: EmailSourcesCompanion.insert(
      id: 'source-1',
      ownerUserId: 'owner-a',
      connectionId: 'connection-1',
      providerMessageId: 'message-1',
      providerThreadId: 'thread-1',
      receivedAt: now,
      sanitizedContentHash: 'b' * 64,
      processingState: const Value('processed'),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertCandidate(
    ownerUserId: 'owner-a',
    candidate: EmailCandidatesCompanion.insert(
      id: 'candidate-1',
      ownerUserId: 'owner-a',
      sourceId: 'source-1',
      schemaVersion: payload.schemaVersion,
      candidateType: payload.candidateType.wireName,
      normalizedPayloadJson: const EmailCandidatePayloadCodec().encode(payload),
      reviewState: const Value('ready_for_review'),
      semanticFingerprint: 'c' * 64,
      updatedAt: Value(now),
    ),
  );
}

EmailCandidatePayload _payload(String title) {
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
