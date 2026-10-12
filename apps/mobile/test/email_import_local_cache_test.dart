import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test(
    'email cache isolates owners across restart and derived deletion retains assignment',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'email-import-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final databaseFile = File(
        '${directory.path}${Platform.pathSeparator}schedule.sqlite',
      );
      var database = local.AppDatabase(NativeDatabase(databaseFile));

      try {
        await _insertCandidateGraph(
          database,
          ownerUserId: 'owner-a',
          connectionId: 'connection-a',
          sourceId: 'source-a',
          candidateId: 'candidate-a',
          linkedAssignmentId: 'assignment-a',
        );
        await _insertCandidateGraph(
          database,
          ownerUserId: 'owner-b',
          connectionId: 'connection-b',
          sourceId: 'source-b',
          candidateId: 'candidate-b',
        );

        expect(
          await database.emailImportDao.candidateById(
            ownerUserId: 'owner-a',
            candidateId: 'candidate-b',
          ),
          isNull,
        );
        expect(
          await database.emailImportDao.watchReviewCandidates('owner-a').first,
          isEmpty,
          reason: 'confirmed candidates are not offered for review again',
        );
        expect(
          await database.emailImportDao.watchReviewCandidates('owner-b').first,
          hasLength(1),
        );
        expect(
          await database.emailImportDao.deleteDerivedDataForConnection(
            ownerUserId: 'owner-b',
            connectionId: 'connection-a',
          ),
          0,
        );

        await database.close();
        database = local.AppDatabase(NativeDatabase(databaseFile));

        expect(
          await database.emailImportDao.candidateById(
            ownerUserId: 'owner-a',
            candidateId: 'candidate-a',
          ),
          isNotNull,
        );
        expect(
          await database.emailImportDao.candidateById(
            ownerUserId: 'owner-b',
            candidateId: 'candidate-b',
          ),
          isNotNull,
        );

        expect(
          await database.emailImportDao.deleteDerivedDataForConnection(
            ownerUserId: 'owner-a',
            connectionId: 'connection-a',
          ),
          1,
        );
        expect(
          await database.emailImportDao.candidateById(
            ownerUserId: 'owner-a',
            candidateId: 'candidate-a',
          ),
          isNull,
        );
        expect(
          await database.emailImportDao.candidateById(
            ownerUserId: 'owner-b',
            candidateId: 'candidate-b',
          ),
          isNotNull,
        );
        expect(
          await (database.select(database.assignments)
                ..where((row) => row.id.equals('assignment-a')))
              .getSingleOrNull(),
          isNotNull,
          reason: 'confirmed schedule entities are not provider-derived data',
        );
      } finally {
        await database.close();
      }
    },
  );

  test('email cache rejects owner takeover and untrusted protocol values',
      () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await _insertCandidateGraph(
      database,
      ownerUserId: 'owner-a',
      connectionId: 'connection-a',
      sourceId: 'source-a',
      candidateId: 'candidate-a',
    );

    await expectLater(
      database.emailImportDao.upsertConnection(
        ownerUserId: 'owner-b',
        connection: local.EmailConnectionsCompanion.insert(
          id: 'connection-a',
          ownerUserId: 'owner-b',
          provider: 'gmail',
          providerAccountHash: 'owner-b-takeover-hash',
        ),
      ),
      throwsStateError,
    );
    await expectLater(
      (database.update(database.emailConnections)
            ..where((row) => row.id.equals('connection-a')))
          .write(
        const local.EmailConnectionsCompanion(
          ownerUserId: Value('owner-b'),
        ),
      ),
      throwsA(anything),
    );
    expect(
      await database.emailImportDao.deleteDerivedDataForConnection(
        ownerUserId: 'owner-b',
        connectionId: 'connection-a',
      ),
      0,
    );
    expect(
      await database.emailImportDao.candidateById(
        ownerUserId: 'owner-a',
        candidateId: 'candidate-a',
      ),
      isNotNull,
    );

    await expectLater(
      (database.update(database.emailSources)
            ..where((row) => row.id.equals('source-a')))
          .write(
        const local.EmailSourcesCompanion(
          processingState: Value('failed'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailSources)
            ..where((row) => row.id.equals('source-a')))
          .write(
        const local.EmailSourcesCompanion(
          errorCategory: Value('timeout'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailCandidates)
            ..where((row) => row.id.equals('candidate-a')))
          .write(
        const local.EmailCandidatesCompanion(
          reviewState: Value('failed'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailCandidates)
            ..where((row) => row.id.equals('candidate-a')))
          .write(
        const local.EmailCandidatesCompanion(
          errorCategory: Value('timeout'),
        ),
      ),
      throwsA(anything),
    );

    final failedAt = DateTime.utc(2026, 7, 22, 11);
    await database.emailImportDao.upsertSource(
      ownerUserId: 'owner-a',
      source: local.EmailSourcesCompanion.insert(
        id: 'failed-source',
        ownerUserId: 'owner-a',
        connectionId: 'connection-a',
        providerMessageId: 'failed-message',
        providerThreadId: 'failed-thread',
        receivedAt: failedAt,
        sanitizedContentHash: 'failed-content-hash',
        processingState: const Value('failed'),
        errorCategory: const Value('timeout'),
        updatedAt: Value(failedAt),
      ),
    );
    await database.emailImportDao.upsertCandidate(
      ownerUserId: 'owner-a',
      candidate: local.EmailCandidatesCompanion.insert(
        id: 'failed-candidate',
        ownerUserId: 'owner-a',
        sourceId: 'failed-source',
        schemaVersion: '1.0',
        candidateType: 'unknown',
        normalizedPayloadJson: '{}',
        reviewState: const Value('failed'),
        semanticFingerprint: 'failed-fingerprint',
        errorCategory: const Value('timeout'),
        updatedAt: Value(failedAt),
      ),
    );
    await expectLater(
      (database.update(database.emailCandidates)
            ..where((row) => row.id.equals('failed-candidate')))
          .write(
        const local.EmailCandidatesCompanion(
          errorCategory: Value('network_unavailable'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailSources)
            ..where((row) => row.id.equals('failed-source')))
          .write(
        const local.EmailSourcesCompanion(
          errorCategory: Value('network_unavailable'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailSources)
            ..where((row) => row.id.equals('failed-source')))
          .write(
        const local.EmailSourcesCompanion(
          evidenceExcerptsJson: Value('["unsafe"]'),
        ),
      ),
      throwsA(anything),
    );
    await expectLater(
      (database.update(database.emailCandidates)
            ..where((row) => row.id.equals('failed-candidate')))
          .write(
        const local.EmailCandidatesCompanion(
          normalizedPayloadJson: Value('{"schema_version":"1.0"}'),
        ),
      ),
      throwsA(anything),
    );

    await expectLater(
      database.emailImportDao.upsertConnection(
        ownerUserId: 'owner-a',
        connection: local.EmailConnectionsCompanion.insert(
          id: 'invalid-connection',
          ownerUserId: 'owner-a',
          provider: 'gmail',
          providerAccountHash: 'invalid-account-hash',
          state: const Value('silently_connected'),
          errorCategory: const Value('provider response with credentials'),
        ),
      ),
      throwsA(anything),
    );

    await database.emailImportDao.upsertSource(
      ownerUserId: 'owner-a',
      source: local.EmailSourcesCompanion.insert(
        id: 'source-other-thread',
        ownerUserId: 'owner-a',
        connectionId: 'connection-a',
        providerMessageId: 'message-other-thread',
        providerThreadId: 'thread-other',
        receivedAt: DateTime.utc(2026, 7, 22, 10),
        sanitizedContentHash: 'content-hash-other-thread',
      ),
    );
    await expectLater(
      database.emailImportDao.upsertCandidateUpdate(
        ownerUserId: 'owner-a',
        update: local.EmailCandidateUpdatesCompanion.insert(
          id: 'cross-thread-update',
          ownerUserId: 'owner-a',
          candidateId: 'candidate-a',
          sourceId: 'source-other-thread',
          fieldDiffJson: '{}',
          proposedPayloadJson: '{"schema_version":"1.0"}',
          semanticFingerprint: 'fingerprint-other-thread',
        ),
      ),
      throwsA(anything),
    );
  });

  test('retained installs replace all email failure parity guards', () async {
    final directory = await Directory.systemTemp.createTemp(
      'email-retained-trigger-replacement-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final databaseFile = File(
      '${directory.path}${Platform.pathSeparator}schedule.sqlite',
    );
    var database = local.AppDatabase(NativeDatabase(databaseFile));
    try {
      await database.customSelect('SELECT 1').getSingle();
      const legacyTriggers = <String, String>{
        'email_sources_owner_guard_insert': 'BEFORE INSERT ON email_sources',
        'email_sources_owner_guard_update': 'BEFORE UPDATE ON email_sources',
        'email_candidates_owner_guard_insert':
            'BEFORE INSERT ON email_candidates',
        'email_candidates_owner_guard_update':
            'BEFORE UPDATE ON email_candidates',
      };
      for (final trigger in legacyTriggers.entries) {
        await database.customStatement(
          'DROP TRIGGER IF EXISTS ${trigger.key}',
        );
        await database.customStatement('''
          CREATE TRIGGER ${trigger.key}
          ${trigger.value}
          FOR EACH ROW
          BEGIN
            SELECT 1;
          END
        ''');
      }
      await database.close();

      database = local.AppDatabase(NativeDatabase(databaseFile));
      final triggers = await database.customSelect('''
        SELECT name, sql
        FROM sqlite_master
        WHERE type = 'trigger'
          AND name IN (
            'email_sources_owner_guard_insert',
            'email_sources_owner_guard_update',
            'email_candidates_owner_guard_insert',
            'email_candidates_owner_guard_update'
          )
      ''').get();
      expect(triggers, hasLength(4));
      for (final trigger in triggers) {
        final name = trigger.read<String>('name');
        final sql = trigger.read<String>('sql');
        if (name.startsWith('email_sources_')) {
          expect(sql, contains('candidate.error_category IS NOT'));
          expect(sql, contains("NEW.processing_state = 'failed'"));
        } else {
          expect(sql, contains('s.error_category IS NEW.error_category'));
          expect(sql, contains("NEW.review_state = 'failed'"));
        }
      }
    } finally {
      await database.close();
    }
  });
}

Future<void> _insertCandidateGraph(
  local.AppDatabase database, {
  required String ownerUserId,
  required String connectionId,
  required String sourceId,
  required String candidateId,
  String? linkedAssignmentId,
}) async {
  final now = DateTime.utc(2026, 7, 22, 9);
  if (linkedAssignmentId != null) {
    await database.into(database.assignments).insert(
          local.AssignmentsCompanion.insert(
            id: linkedAssignmentId,
            ownerUserId: ownerUserId,
            title: 'Confirmed private assignment',
            dueAt: DateTime.utc(2026, 7, 25, 8),
            visibilityLevel: const Value('PRIVATE'),
            updatedAt: Value(now),
          ),
        );
  }
  await database.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: local.EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: ownerUserId,
      provider: 'gmail',
      providerAccountHash: 'account-hash-$ownerUserId',
      state: const Value('connected'),
      updatedAt: Value(now),
    ),
  );
  await database.emailImportDao.upsertSource(
    ownerUserId: ownerUserId,
    source: local.EmailSourcesCompanion.insert(
      id: sourceId,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerMessageId: 'message-$ownerUserId',
      providerThreadId: 'thread-$ownerUserId',
      receivedAt: now,
      sanitizedContentHash: 'content-hash-$ownerUserId',
      updatedAt: Value(now),
    ),
  );
  await database.emailImportDao.upsertCandidate(
    ownerUserId: ownerUserId,
    candidate: local.EmailCandidatesCompanion.insert(
      id: candidateId,
      ownerUserId: ownerUserId,
      sourceId: sourceId,
      schemaVersion: '1.0',
      candidateType: 'assignment',
      normalizedPayloadJson: '{"schema_version":"1.0"}',
      semanticFingerprint: 'fingerprint-$ownerUserId',
      reviewState: Value(
        linkedAssignmentId == null ? 'needs_review' : 'confirmed',
      ),
      linkedEntityType: Value(
        linkedAssignmentId == null ? null : 'assignment',
      ),
      linkedEntityId: Value(linkedAssignmentId),
      confirmationIdempotencyKey: Value(
        linkedAssignmentId == null ? null : 'confirm-$candidateId',
      ),
      confirmedAt: Value(linkedAssignmentId == null ? null : now),
      updatedAt: Value(now),
    ),
  );
}
