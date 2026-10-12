import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  for (final sourceVersion in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) {
    test('schema $sourceVersion upgrades to current schema 19', () async {
      final upgraded = _databaseAtVersion(sourceVersion);

      try {
        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle();
        final queueColumns = await upgraded
            .customSelect("PRAGMA table_info('sync_queue_entries')")
            .map((row) => row.read<String>('name'))
            .get();

        expect(version, 19);
        if (sourceVersion >= 6) {
          expect(
            await _tableColumns(upgraded, 'events'),
            contains('is_all_day'),
          );
        }
        expect(
          queueColumns,
          containsAll(<String>[
            'status',
            'error_message',
            'idempotency_key',
            'base_version',
            'server_version',
            'server_payload_json',
            'conflict_cursor',
            'attempt_count',
            'next_retry_at',
            'last_attempt_at',
            'claimed_at',
            'owner_user_id',
            'enqueue_sequence',
            'completion_provenance',
          ]),
        );
        final sequenceStateColumns = await upgraded
            .customSelect("PRAGMA table_info('sync_queue_sequence_states')")
            .map((row) => row.read<String>('name'))
            .get();
        expect(sequenceStateColumns, containsAll(['id', 'next_value']));
        expect(await upgraded.syncQueueDao.readCursor('legacy-owner'), 0);
        final calendarPreferenceColumns = await upgraded
            .customSelect("PRAGMA table_info('calendar_display_preferences')")
            .map((row) => row.read<String>('name'))
            .get();
        expect(
          calendarPreferenceColumns,
          containsAll(<String>[
            'owner_user_id',
            'show_courses',
            'show_assignment_deadlines',
            'show_exams',
            'show_personal_events',
            'updated_at',
          ]),
        );
        await _expectEmailFoundationSchema(upgraded);
        await _expectEmailConfirmationSchema(upgraded);
        await _expectEmailDedupeSchema(upgraded);
        await _expectEmailReconciliationSchema(upgraded);
        await upgraded.syncQueueDao.writeCursor(
          ownerUserId: 'legacy-owner',
          cursor: 42,
          updatedAt: DateTime.utc(2026, 7, 10),
        );
        expect(await upgraded.syncQueueDao.readCursor('legacy-owner'), 42);

        final ownerRows =
            await upgraded.syncQueueDao.allMutations('legacy-owner');
        final quarantinedRows = await upgraded.syncQueueDao.allMutations(
          local.legacyQuarantinedOwnerId,
        );
        expect(ownerRows, hasLength(1));
        expect(quarantinedRows, hasLength(1));

        final pending = ownerRows.single;
        final quarantined = quarantinedRows.single;
        expect(pending.clientMutationId, 'legacy-pending-$sourceVersion');
        expect(pending.ownerUserId, 'legacy-owner');
        expect(pending.idempotencyKey, 'legacy-pending-$sourceVersion');
        expect(pending.status, 'pending');
        expect(pending.payloadJson, isNot('{}'));
        expect(pending.syncedAt, isNull);
        expect(pending.enqueueSequence, greaterThan(0));
        expect(quarantined.clientMutationId, 'legacy-ack-$sourceVersion');
        expect(quarantined.status, 'quarantined');
        expect(quarantined.payloadJson, '{}');
        expect(quarantined.errorMessage, isNull);
        expect(quarantined.syncedAt, isNotNull);
        expect(quarantined.enqueueSequence, greaterThan(0));

        if (sourceVersion == 1) {
          await _expectVersionOneEntityColumns(upgraded);
        }
        if (sourceVersion == 4) {
          await _expectVersionFourContextMigration(upgraded);
        }
        if (sourceVersion == 6) {
          await _expectVersionSixEventExceptionMigration(upgraded);
        }
        if (sourceVersion >= 9) {
          await _expectEmailFoundationConstraints(upgraded, suffix: 'upgrade');
        }

        await upgraded.customStatement('''
          INSERT INTO sync_queue_entries (
            client_mutation_id,
            owner_user_id,
            entity_type,
            entity_id,
            operation,
            payload_json,
            created_at
          ) VALUES (
            'trigger-mutation-$sourceVersion',
            'legacy-owner',
            'exam',
            'exam-1',
            'create',
            '{}',
            1783659600
          )
        ''');
        final triggerRow =
            (await upgraded.syncQueueDao.allMutations('legacy-owner'))
                .singleWhere(
          (row) => row.clientMutationId == 'trigger-mutation-$sourceVersion',
        );
        expect(triggerRow.idempotencyKey, 'trigger-mutation-$sourceVersion');
        expect(
            triggerRow.enqueueSequence, greaterThan(pending.enqueueSequence));

        await expectLater(
          upgraded.customStatement('''
            INSERT INTO sync_queue_entries (
              client_mutation_id,
              entity_type,
              entity_id,
              operation,
              payload_json,
              created_at
            ) VALUES (
              'missing-owner-$sourceVersion',
              'exam',
              'exam-2',
              'create',
              '{}',
              1783659600
            )
          '''),
          throwsA(anything),
        );
      } finally {
        await upgraded.close();
      }
    });
  }

  test(
    'schema 11 backfills proposal versions and prunes dismissed payloads',
    () async {
      final upgraded = _databaseAtVersionEmailLifecycle(11);
      try {
        final version = await upgraded
            .customSelect('PRAGMA user_version')
            .map((row) => row.read<int>('user_version'))
            .getSingle();
        expect(version, 19);
        await _expectEmailFoundationSchema(upgraded);
        await _expectEmailConfirmationSchema(upgraded);
        await _expectEmailDedupeSchema(upgraded);
        await _expectEmailReconciliationSchema(upgraded);

        final proposal =
            (await upgraded.select(upgraded.emailCandidateUpdates).get())
                .single;
        expect(proposal.id, 'legacy-update');
        expect(proposal.baseEntityVersion, 7);

        final tombstone =
            (await upgraded.select(upgraded.emailDismissalTombstones).get())
                .single;
        expect(tombstone.id, 'dismissed-candidate');
        expect(tombstone.providerAccountHash, 'b' * 64);
        expect(tombstone.providerMessageIdHash, hasLength(64));
        expect(tombstone.providerThreadIdHash, hasLength(64));
        expect(tombstone.providerMessageIdHash, isNot(contains('raw')));
        expect(tombstone.providerThreadIdHash, isNot(contains('raw')));
        expect(
          await (upgraded.select(upgraded.emailSources)
                ..where((row) => row.id.equals('dismissed-source')))
              .getSingleOrNull(),
          isNull,
        );
        expect(
          await (upgraded.select(upgraded.emailCandidates)
                ..where((row) => row.id.equals('dismissed-candidate')))
              .getSingleOrNull(),
          isNull,
        );
      } finally {
        await upgraded.close();
      }
    },
  );

  test('fresh schema 19 includes replay and document infrastructure', () async {
    final database = local.AppDatabase(NativeDatabase.memory());
    try {
      final stateColumns = await database
          .customSelect("PRAGMA table_info('assignment_user_states')")
          .map((row) => row.read<String>('name'))
          .get();
      final cursorColumns = await database
          .customSelect("PRAGMA table_info('sync_cursors')")
          .map((row) => row.read<String>('name'))
          .get();
      final exceptionColumns = await database
          .customSelect("PRAGMA table_info('event_exceptions')")
          .map((row) => row.read<String>('name'))
          .get();
      final calendarPreferenceColumns = await database
          .customSelect("PRAGMA table_info('calendar_display_preferences')")
          .map((row) => row.read<String>('name'))
          .get();
      final queueColumns = await database
          .customSelect("PRAGMA table_info('sync_queue_entries')")
          .map((row) => row.read<String>('name'))
          .get();
      final sequenceStateColumns = await database
          .customSelect("PRAGMA table_info('sync_queue_sequence_states')")
          .map((row) => row.read<String>('name'))
          .get();
      final nextSequence = await database
          .customSelect(
            'SELECT next_value FROM sync_queue_sequence_states WHERE id = 1',
          )
          .map((row) => row.read<int>('next_value'))
          .getSingle();

      expect(stateColumns, containsAll(['deleted_at', 'version']));
      expect(
        cursorColumns,
        containsAll(['owner_user_id', 'stream', 'cursor', 'updated_at']),
      );
      expect(
        exceptionColumns,
        containsAll([
          'owner_user_id',
          'updated_at',
          'deleted_at',
          'version',
        ]),
      );
      expect(
        calendarPreferenceColumns,
        containsAll([
          'owner_user_id',
          'show_courses',
          'show_assignment_deadlines',
          'show_exams',
          'show_personal_events',
          'updated_at',
        ]),
      );
      expect(queueColumns, contains('enqueue_sequence'));
      expect(sequenceStateColumns, containsAll(['id', 'next_value']));
      expect(nextSequence, 1);
      await _expectEmailFoundationSchema(database);
      await _expectEmailConfirmationSchema(database);
      await _expectEmailDedupeSchema(database);
      await _expectEmailReconciliationSchema(database);
      await _expectEmailFoundationConstraints(database, suffix: 'fresh');
      expect(
        await _tableColumns(database, 'document_sources_cache'),
        containsAll(<String>[
          'id',
          'owner_user_id',
          'storage_path',
          'content_hash',
          'processing_state',
          'candidate_count',
        ]),
      );
      expect(
        await _tableColumns(database, 'document_candidates_cache'),
        containsAll(<String>[
          'id',
          'owner_user_id',
          'source_id',
          'candidate_key',
          'normalized_payload_json',
          'review_state',
          'is_selected',
          'course_id',
          'remote_sync_state',
        ]),
      );
      expect(
        await _tableColumns(database, 'document_schedule_entity_links'),
        containsAll(<String>[
          'id',
          'owner_user_id',
          'source_id',
          'candidate_cache_id',
          'entity_type',
          'entity_id',
          'confirmation_idempotency_key',
        ]),
      );
    } finally {
      await database.close();
    }
  });

  test('real schema 12 email decisions backfill before v15 queue reads',
      () async {
    final database = _databaseAtVersionEmailLifecycle(12);
    try {
      final version = await database
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle();
      expect(version, 19);

      final receipts =
          await database.select(database.emailReconciliationReceipts).get();
      expect(receipts, hasLength(3));

      final confirmation =
          receipts.singleWhere((row) => row.action == 'confirmation');
      expect(confirmation.localReferenceId, 'confirmed-candidate');
      expect(
          confirmation.requiredSyncMutationId, 'legacy-confirmation-mutation');
      expect(confirmation.scheduleAckedAt, isNull);
      expect(confirmation.state, 'pending');

      final update = receipts.singleWhere((row) => row.action == 'update');
      expect(update.localReferenceId, 'legacy-update');
      expect(update.resolution, 'accepted');
      expect(update.requiredSyncMutationId, 'legacy-update-resolution');
      expect(update.scheduleAckedAt, isNull);
      expect(update.state, 'pending');

      final dismissal =
          receipts.singleWhere((row) => row.action == 'dismissal');
      expect(dismissal.localReferenceId, 'dismissed-tombstone');
      expect(dismissal.providerMessageIdHash, '6' * 64);
      expect(dismissal.providerThreadIdHash, '7' * 64);
      expect(dismissal.reviewedPayloadJson, isNull);
      expect(dismissal.state, 'pending');
    } finally {
      await database.close();
    }
  });

  test('retained schema 14 opens atomically with empty edit provenance',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'schedule-schema-14-to-15-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    var database = local.AppDatabase(NativeDatabase(file));
    await database.customSelect('SELECT 1').getSingle();
    await database.customStatement('DROP TABLE email_schedule_edit_receipts');
    await database.customStatement('PRAGMA user_version = 14');
    await database.close();

    database = local.AppDatabase(NativeDatabase(file));
    try {
      final version = await database
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle();
      expect(version, 19);
      expect(
        await _tableColumns(database, 'email_schedule_edit_receipts'),
        containsAll(<String>[
          'mutation_id',
          'candidate_id',
          'link_id',
          'base_payload_fingerprint',
          'payload_fingerprint',
          'candidate_payload_fingerprint',
        ]),
      );
      expect(await database.select(database.emailScheduleEditReceipts).get(),
          isEmpty);
    } finally {
      await database.close();
    }
  });

  test('schema 15 to 16 adds is_all_day with a safe false backfill', () async {
    final directory = await Directory.systemTemp.createTemp(
      'schedule-schema-15-to-16-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    var database = local.AppDatabase(NativeDatabase(file));
    await database.customSelect('SELECT 1').getSingle();
    await database.customStatement('''
      INSERT INTO events (
        id, owner_user_id, calendar_id, title, kind, start_at, end_at,
        is_all_day, updated_at, version
      ) VALUES (
        'legacy-event', 'legacy-owner', 'legacy-calendar', 'Legacy event',
        'normal', 1783659600, 1783663200, 0, 1783659600, 1
      )
    ''');
    await database.customStatement('ALTER TABLE events DROP COLUMN is_all_day');
    await database.customStatement('PRAGMA user_version = 15');
    await database.close();

    database = local.AppDatabase(NativeDatabase(file));
    try {
      final version = await database
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle();
      final event = await (database.select(database.events)
            ..where((row) => row.id.equals('legacy-event')))
          .getSingle();

      expect(version, 19);
      expect(event.isAllDay, isFalse);
      expect(
        await _tableColumns(database, 'events'),
        contains('is_all_day'),
      );
    } finally {
      await database.close();
    }
  });

  test('schema 16 to 17 adds owner-private document cache tables', () async {
    final directory = await Directory.systemTemp.createTemp(
      'schedule-schema-16-to-17-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    var database = local.AppDatabase(NativeDatabase(file));
    await database.customSelect('SELECT 1').getSingle();
    await database.customStatement(
      'DROP TABLE document_schedule_entity_links',
    );
    await database.customStatement('DROP TABLE document_candidates_cache');
    await database.customStatement('DROP TABLE document_sources_cache');
    await database.customStatement('PRAGMA user_version = 16');
    await database.close();

    database = local.AppDatabase(NativeDatabase(file));
    try {
      final version = await database
          .customSelect('PRAGMA user_version')
          .map((row) => row.read<int>('user_version'))
          .getSingle();
      expect(version, 19);
      expect(
        await _tableColumns(database, 'document_sources_cache'),
        contains('owner_user_id'),
      );
      expect(
        await _tableColumns(database, 'document_candidates_cache'),
        containsAll(['source_id', 'remote_sync_state']),
      );
      expect(
        await _tableColumns(database, 'document_schedule_entity_links'),
        contains('candidate_cache_id'),
      );
    } finally {
      await database.close();
    }
  });

  test(
      'calendar display preferences persist across recreation and isolate owners',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'calendar-display-preferences-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    var database = local.AppDatabase(NativeDatabase(file));

    try {
      await database.calendarDisplayPreferencesDao.savePreferences(
        ownerUserId: 'owner-a',
        showCourses: false,
        showAssignmentDeadlines: true,
        showExams: false,
        showPersonalEvents: false,
        updatedAt: DateTime.utc(2026, 7, 18, 9),
      );
      await database.close();

      database = local.AppDatabase(NativeDatabase(file));
      final ownerA = await database.calendarDisplayPreferencesDao
          .preferencesForOwner('owner-a');
      final ownerB = await database.calendarDisplayPreferencesDao
          .preferencesForOwner('owner-b');

      expect(ownerA, isNotNull);
      expect(ownerA!.showCourses, isFalse);
      expect(ownerA.showAssignmentDeadlines, isTrue);
      expect(ownerA.showExams, isFalse);
      expect(ownerA.showPersonalEvents, isFalse);
      expect(ownerB, isNull);

      await database.calendarDisplayPreferencesDao.savePreferences(
        ownerUserId: 'owner-b',
        showCourses: true,
        showAssignmentDeadlines: false,
        showExams: true,
        showPersonalEvents: true,
        updatedAt: DateTime.utc(2026, 7, 18, 10),
      );
      final ownerAAfterOwnerBWrite = await database
          .calendarDisplayPreferencesDao
          .preferencesForOwner('owner-a');
      expect(ownerAAfterOwnerBWrite!.showCourses, isFalse);
      expect(ownerAAfterOwnerBWrite.showAssignmentDeadlines, isTrue);
    } finally {
      await database.close();
    }
  });
}

Future<void> _expectEmailFoundationSchema(local.AppDatabase database) async {
  final expectedColumns = <String, List<String>>{
    'email_connections': [
      'id',
      'owner_user_id',
      'provider',
      'provider_account_hash',
      'account_hint',
      'scopes_json',
      'cursor',
      'state',
      'error_category',
      'retry_after',
      'last_synced_at',
      'disconnected_at',
      'created_at',
      'updated_at',
    ],
    'email_sources': [
      'id',
      'owner_user_id',
      'connection_id',
      'provider_message_id',
      'provider_thread_id',
      'received_at',
      'sanitized_content_hash',
      'evidence_excerpts_json',
      'processing_state',
      'error_category',
      'created_at',
      'updated_at',
    ],
    'email_candidates': [
      'id',
      'owner_user_id',
      'source_id',
      'schema_version',
      'candidate_type',
      'normalized_payload_json',
      'review_state',
      'semantic_fingerprint',
      'linked_entity_type',
      'linked_entity_id',
      'confirmation_idempotency_key',
      'error_category',
      'requires_user_confirmation',
      'confirmed_at',
      'dismissed_at',
      'created_at',
      'updated_at',
    ],
    'email_candidate_updates': [
      'id',
      'owner_user_id',
      'candidate_id',
      'source_id',
      'field_diff_json',
      'proposed_payload_json',
      'semantic_fingerprint',
      'base_entity_version',
      'state',
      'error_category',
      'resolution_idempotency_key',
      'resolved_at',
      'created_at',
      'updated_at',
    ],
  };

  for (final entry in expectedColumns.entries) {
    final columns = await _tableColumns(database, entry.key);
    expect(columns, containsAll(entry.value), reason: entry.key);
    expect(
      columns.where(_isForbiddenEmailColumn),
      isEmpty,
      reason: '${entry.key} must expose no body, token, or credential column',
    );
  }
}

Future<void> _expectEmailDedupeSchema(local.AppDatabase database) async {
  final columns = await _tableColumns(
    database,
    'email_dismissal_tombstones',
  );
  expect(
    columns,
    containsAll(<String>[
      'id',
      'owner_user_id',
      'provider',
      'provider_account_hash',
      'provider_message_id_hash',
      'provider_thread_id_hash',
      'sanitized_content_hash',
      'semantic_fingerprint',
      'dismissed_at',
    ]),
  );
  expect(columns.where(_isForbiddenEmailColumn), isEmpty);
  expect(columns, isNot(contains('provider_message_id')));
  expect(columns, isNot(contains('provider_thread_id')));
  expect(columns, isNot(contains('normalized_payload_json')));
  expect(columns, isNot(contains('evidence_excerpts_json')));
}

Future<void> _expectEmailReconciliationSchema(
  local.AppDatabase database,
) async {
  final columns = await _tableColumns(
    database,
    'email_reconciliation_receipts',
  );
  expect(
    columns,
    containsAll(<String>[
      'id',
      'owner_user_id',
      'connection_id',
      'action',
      'local_reference_id',
      'provider',
      'provider_account_hash',
      'provider_message_id_hash',
      'provider_thread_id_hash',
      'sanitized_content_hash',
      'reviewed_payload_json',
      'resolution',
      'entity_type',
      'entity_id',
      'idempotency_key',
      'required_sync_mutation_id',
      'schedule_acked_at',
      'state',
      'attempt_count',
      'next_retry_at',
      'last_attempt_at',
      'reconciled_at',
      'replayed',
      'error_category',
      'created_at',
      'updated_at',
    ]),
  );
  expect(columns, isNot(contains('provider_message_id')));
  expect(columns, isNot(contains('provider_thread_id')));
  expect(columns.where(_isForbiddenEmailColumn), isEmpty);
}

Future<void> _expectEmailConfirmationSchema(local.AppDatabase database) async {
  final expectedColumns = <String, List<String>>{
    'email_schedule_entity_links': [
      'id',
      'owner_user_id',
      'source_id',
      'candidate_id',
      'entity_type',
      'entity_id',
      'confirmation_idempotency_key',
      'created_at',
    ],
    'email_schedule_edit_receipts': [
      'mutation_id',
      'owner_user_id',
      'candidate_id',
      'link_id',
      'entity_type',
      'entity_id',
      'provenance',
      'base_entity_version',
      'entity_version',
      'base_payload_fingerprint',
      'payload_fingerprint',
      'candidate_payload_fingerprint',
      'entity_updated_at',
      'created_at',
    ],
    'notification_schedule_requests': [
      'id',
      'owner_user_id',
      'entity_type',
      'entity_id',
      'source_type',
      'source_id',
      'idempotency_key',
      'anchor_at',
      'all_day',
      'timezone',
      'reminders_minutes_json',
      'target_path',
      'state',
      'created_at',
      'updated_at',
    ],
  };

  for (final entry in expectedColumns.entries) {
    final columns = await _tableColumns(database, entry.key);
    expect(columns, containsAll(entry.value), reason: entry.key);
    expect(columns.where(_isForbiddenEmailColumn), isEmpty, reason: entry.key);
  }
}

Future<void> _expectEmailFoundationConstraints(
  local.AppDatabase database, {
  required String suffix,
}) async {
  final now = DateTime.utc(2026, 7, 22, 9);
  final connectionId = 'constraint-connection-$suffix';
  final sourceId = 'constraint-source-$suffix';
  await database.emailImportDao.upsertConnection(
    ownerUserId: 'constraint-owner',
    connection: local.EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: 'constraint-owner',
      provider: 'gmail',
      providerAccountHash: 'constraint-account-$suffix',
      updatedAt: Value(now),
    ),
  );
  await database.emailImportDao.upsertSource(
    ownerUserId: 'constraint-owner',
    source: local.EmailSourcesCompanion.insert(
      id: sourceId,
      ownerUserId: 'constraint-owner',
      connectionId: connectionId,
      providerMessageId: 'provider-message-$suffix',
      providerThreadId: 'provider-thread-$suffix',
      receivedAt: now,
      sanitizedContentHash: 'content-hash-$suffix',
      updatedAt: Value(now),
    ),
  );

  await expectLater(
    database.into(database.emailSources).insert(
          local.EmailSourcesCompanion.insert(
            id: 'duplicate-source-$suffix',
            ownerUserId: 'constraint-owner',
            connectionId: connectionId,
            providerMessageId: 'provider-message-$suffix',
            providerThreadId: 'different-thread-$suffix',
            receivedAt: now,
            sanitizedContentHash: 'different-content-hash-$suffix',
            updatedAt: Value(now),
          ),
        ),
    throwsA(anything),
  );

  local.EmailCandidatesCompanion candidate({
    required String id,
    Value<bool> requiresUserConfirmation = const Value.absent(),
  }) {
    return local.EmailCandidatesCompanion.insert(
      id: id,
      ownerUserId: 'constraint-owner',
      sourceId: sourceId,
      schemaVersion: '1.0',
      candidateType: 'assignment',
      normalizedPayloadJson: '{"schema_version":"1.0"}',
      semanticFingerprint: 'fingerprint-$suffix',
      requiresUserConfirmation: requiresUserConfirmation,
      updatedAt: Value(now),
    );
  }

  await expectLater(
    database.emailImportDao.upsertCandidate(
      ownerUserId: 'constraint-owner',
      candidate: candidate(
        id: 'unconfirmed-candidate-$suffix',
        requiresUserConfirmation: const Value(false),
      ),
    ),
    throwsA(anything),
  );
  await expectLater(
    database.emailImportDao.upsertCandidate(
      ownerUserId: 'constraint-owner',
      candidate: candidate(id: 'partial-confirmation-$suffix').copyWith(
        reviewState: const Value('confirmed'),
      ),
    ),
    throwsA(anything),
  );
  await expectLater(
    database.emailImportDao.upsertCandidate(
      ownerUserId: 'constraint-owner',
      candidate: candidate(id: 'unsupported-confirmation-$suffix').copyWith(
        candidateType: const Value('announcement'),
        reviewState: const Value('confirmed'),
        linkedEntityType: const Value('announcement'),
        linkedEntityId: const Value('announcement-entity'),
        confirmationIdempotencyKey: Value('announcement-confirmation-$suffix'),
        confirmedAt: Value(now),
      ),
    ),
    throwsA(anything),
  );
  await expectLater(
    database.emailImportDao.upsertCandidate(
      ownerUserId: 'constraint-owner',
      candidate: candidate(id: 'mismatched-confirmation-$suffix').copyWith(
        reviewState: const Value('confirmed'),
        linkedEntityType: const Value('exam'),
        linkedEntityId: const Value('exam-entity'),
        confirmationIdempotencyKey: Value('mismatched-confirmation-$suffix'),
        confirmedAt: Value(now),
      ),
    ),
    throwsA(anything),
  );
  final candidateId = 'confirmed-review-candidate-$suffix';
  await database.emailImportDao.upsertCandidate(
    ownerUserId: 'constraint-owner',
    candidate: candidate(id: candidateId),
  );
  expect(
    (await database.emailImportDao.candidateById(
      ownerUserId: 'constraint-owner',
      candidateId: candidateId,
    ))
        ?.requiresUserConfirmation,
    isTrue,
  );
  await expectLater(
    (database.update(database.emailCandidates)
          ..where((row) => row.id.equals(candidateId)))
        .write(
      const local.EmailCandidatesCompanion(
        requiresUserConfirmation: Value(false),
      ),
    ),
    throwsA(anything),
  );
}

Future<List<String>> _tableColumns(
  local.AppDatabase database,
  String tableName,
) {
  return database
      .customSelect('PRAGMA table_info("$tableName")')
      .map((row) => row.read<String>('name'))
      .get();
}

bool _isForbiddenEmailColumn(String column) {
  final normalized = column.toLowerCase();
  return normalized == 'body' ||
      normalized.endsWith('_body') ||
      normalized.contains('raw_body') ||
      normalized.contains('token') ||
      normalized.contains('credential') ||
      normalized.contains('client_secret') ||
      normalized.contains('refresh_secret');
}

local.AppDatabase _databaseAtVersion(int sourceVersion) {
  return local.AppDatabase(
    NativeDatabase.memory(
      setup: (database) {
        if (sourceVersion == 1) {
          database.execute('CREATE TABLE assignments (id TEXT PRIMARY KEY)');
          database.execute('CREATE TABLE exams (id TEXT PRIMARY KEY)');
        }
        if (sourceVersion == 4) {
          _createVersionFourContextTables(database.execute);
        }
        if (sourceVersion == 6) {
          _createVersionSixEventExceptionTables(database.execute);
        }
        if (sourceVersion >= 7) {
          _createVersionSevenEventExceptionTables(database.execute);
        }
        if (sourceVersion >= 8) {
          _createVersionEightCalendarDisplayPreferencesTable(database.execute);
        }
        if (sourceVersion >= 10) {
          _createVersionTenEmailFoundationTables(database.execute);
        }
        database.execute('''
          CREATE TABLE sync_queue_entries (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            synced_at INTEGER
            ${sourceVersion >= 2 ? ", status TEXT NOT NULL DEFAULT 'pending'" : ''}
            ${sourceVersion >= 3 ? ', error_message TEXT' : ''}
            ${sourceVersion >= 4 ? ', idempotency_key TEXT' : ''}
            ${sourceVersion >= 4 ? ', base_version INTEGER' : ''}
            ${sourceVersion >= 4 ? ', server_version INTEGER' : ''}
            ${sourceVersion >= 4 ? ', attempt_count INTEGER NOT NULL DEFAULT 0' : ''}
            ${sourceVersion >= 4 ? ', next_retry_at INTEGER' : ''}
            ${sourceVersion >= 4 ? ', last_attempt_at INTEGER' : ''}
            ${sourceVersion >= 4 ? ', claimed_at INTEGER' : ''}
            ${sourceVersion >= 5 ? ', owner_user_id TEXT NOT NULL' : ''}
            ${sourceVersion >= 6 ? ', server_payload_json TEXT' : ''}
            ${sourceVersion >= 6 ? ', conflict_cursor INTEGER' : ''}
            ${sourceVersion >= 9 ? ', enqueue_sequence INTEGER NOT NULL DEFAULT 0' : ''}
          )
        ''');
        final columns = <String>[
          'client_mutation_id',
          'entity_type',
          'entity_id',
          'operation',
          'payload_json',
          'created_at',
          'synced_at',
          if (sourceVersion >= 2) 'status',
          if (sourceVersion >= 3) 'error_message',
          if (sourceVersion >= 4) ...[
            'idempotency_key',
            'base_version',
            'server_version',
            'attempt_count',
            'next_retry_at',
            'last_attempt_at',
            'claimed_at',
            if (sourceVersion >= 5) 'owner_user_id',
            if (sourceVersion >= 6) ...[
              'server_payload_json',
              'conflict_cursor',
            ],
            if (sourceVersion >= 9) 'enqueue_sequence',
          ],
        ];
        var nextLegacySequence = 1;

        void insertLegacyRow({
          required String id,
          required int? syncedAt,
          required String status,
          required String payload,
        }) {
          final values = <Object?>[
            id,
            'assignment',
            'assignment-1',
            'update',
            payload,
            1783659600,
            syncedAt,
            if (sourceVersion >= 2) status,
            if (sourceVersion >= 3) null,
            if (sourceVersion >= 4) ...[
              id,
              null,
              null,
              0,
              null,
              null,
              null,
              if (sourceVersion >= 5)
                syncedAt == null
                    ? 'legacy-owner'
                    : local.legacyQuarantinedOwnerId,
              if (sourceVersion >= 6) ...[null, null],
              if (sourceVersion >= 9) nextLegacySequence++,
            ],
          ];
          final placeholders = List.filled(values.length, '?').join(', ');
          database.execute(
            'INSERT INTO sync_queue_entries '
            '(${columns.join(', ')}) VALUES ($placeholders)',
            values,
          );
        }

        insertLegacyRow(
          id: 'legacy-ack-$sourceVersion',
          syncedAt: 1783659600,
          status: sourceVersion == 3
              ? 'failed'
              : sourceVersion >= 5
                  ? 'quarantined'
                  : 'synced',
          payload: sourceVersion >= 4
              ? '{}'
              : '{"ownerUserId":"legacy-owner","title":"acknowledged"}',
        );
        insertLegacyRow(
          id: 'legacy-pending-$sourceVersion',
          syncedAt: null,
          status: 'pending',
          payload: '{"ownerUserId":"legacy-owner","title":"pending"}',
        );
        if (sourceVersion >= 6) {
          database.execute('''
            CREATE TABLE sync_cursors (
              owner_user_id TEXT NOT NULL,
              stream TEXT NOT NULL DEFAULT 'schedule',
              cursor INTEGER NOT NULL DEFAULT 0,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (owner_user_id, stream)
            )
          ''');
        }
        if (sourceVersion >= 9) {
          database.execute('''
            CREATE TABLE sync_queue_sequence_states (
              id INTEGER NOT NULL PRIMARY KEY,
              next_value INTEGER NOT NULL
            )
          ''');
          database.execute(
            'INSERT INTO sync_queue_sequence_states (id, next_value) '
            'VALUES (1, $nextLegacySequence)',
          );
        }
        database.execute('PRAGMA user_version = $sourceVersion');
      },
    ),
  );
}

local.AppDatabase _databaseAtVersionEmailLifecycle(int sourceVersion) {
  assert(sourceVersion == 11 || sourceVersion == 12);
  return local.AppDatabase(
    NativeDatabase.memory(
      setup: (database) {
        database.execute('''
          CREATE TABLE assignments (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            course_id TEXT,
            title TEXT NOT NULL,
            description TEXT,
            submission_url TEXT,
            priority TEXT,
            due_at INTEGER NOT NULL,
            visibility_level TEXT NOT NULL DEFAULT 'PRIVATE',
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER,
            version INTEGER NOT NULL DEFAULT 1
          )
        ''');
        database.execute('''
          CREATE TABLE exams (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            course_id TEXT,
            title TEXT NOT NULL,
            start_at INTEGER NOT NULL,
            end_at INTEGER NOT NULL,
            room TEXT,
            scope TEXT,
            memo TEXT,
            exam_type TEXT,
            visibility_level TEXT NOT NULL DEFAULT 'PRIVATE',
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER,
            version INTEGER NOT NULL DEFAULT 1
          )
        ''');
        database.execute('''
          CREATE TABLE events (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            calendar_id TEXT NOT NULL,
            group_id TEXT,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            start_at INTEGER NOT NULL,
            end_at INTEGER NOT NULL,
            location TEXT,
            description TEXT,
            rrule TEXT,
            timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo',
            visibility_level TEXT NOT NULL DEFAULT 'PRIVATE',
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER,
            version INTEGER NOT NULL DEFAULT 1
          )
        ''');
        _createVersionTenEmailFoundationTables(
          database.execute,
          createCanonicalTables: false,
        );
        if (sourceVersion >= 12) {
          database.execute('''
            ALTER TABLE email_candidate_updates
            ADD COLUMN base_entity_version INTEGER NOT NULL DEFAULT 0
          ''');
          database.execute('''
            CREATE TABLE email_dismissal_tombstones (
              id TEXT NOT NULL PRIMARY KEY,
              owner_user_id TEXT NOT NULL,
              provider TEXT NOT NULL,
              provider_account_hash TEXT NOT NULL,
              provider_message_id_hash TEXT NOT NULL,
              provider_thread_id_hash TEXT NOT NULL,
              sanitized_content_hash TEXT NOT NULL,
              semantic_fingerprint TEXT NOT NULL,
              dismissed_at INTEGER NOT NULL,
              UNIQUE (
                owner_user_id, provider, provider_account_hash,
                provider_message_id_hash
              ),
              UNIQUE (
                owner_user_id, provider, provider_account_hash,
                provider_thread_id_hash, sanitized_content_hash
              ),
              UNIQUE (
                owner_user_id, provider, provider_account_hash,
                provider_thread_id_hash, semantic_fingerprint
              )
            )
          ''');
        }
        database.execute('''
          CREATE TABLE email_schedule_entity_links (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            source_id TEXT NOT NULL REFERENCES email_sources(id)
              ON DELETE CASCADE,
            candidate_id TEXT NOT NULL REFERENCES email_candidates(id)
              ON DELETE CASCADE,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            confirmation_idempotency_key TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(candidate_id),
            UNIQUE(confirmation_idempotency_key),
            UNIQUE(owner_user_id, entity_type, entity_id)
          )
        ''');
        database.execute('''
          CREATE TABLE notification_schedule_requests (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'email_confirmation',
            source_id TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            anchor_at INTEGER NOT NULL,
            all_day INTEGER NOT NULL DEFAULT 0,
            timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo',
            reminders_minutes_json TEXT NOT NULL DEFAULT '[]',
            target_path TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            UNIQUE(idempotency_key),
            UNIQUE(owner_user_id, entity_type, entity_id)
          )
        ''');
        database.execute('''
          CREATE TABLE sync_queue_entries (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            idempotency_key TEXT,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            base_version INTEGER,
            server_version INTEGER,
            server_payload_json TEXT,
            conflict_cursor INTEGER,
            created_at INTEGER NOT NULL,
            enqueue_sequence INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'pending',
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at INTEGER,
            last_attempt_at INTEGER,
            claimed_at INTEGER,
            synced_at INTEGER,
            error_message TEXT
          )
        ''');
        database.execute('''
          CREATE TABLE sync_queue_sequence_states (
            id INTEGER NOT NULL PRIMARY KEY,
            next_value INTEGER NOT NULL
          )
        ''');
        database.execute('''
          INSERT INTO sync_queue_sequence_states (id, next_value)
          VALUES (1, 1)
        ''');
        database.execute('''
          INSERT INTO assignments (
            id, owner_user_id, title, due_at, visibility_level,
            updated_at, version
          ) VALUES (
            'confirmed-entity', 'legacy-owner', 'Original', 1783659600,
            'PRIVATE', 1783659600, 7
          )
        ''');
        database.execute('''
          INSERT INTO email_connections (
            id, owner_user_id, provider, provider_account_hash, state,
            created_at, updated_at
          ) VALUES (
            'legacy-connection', 'legacy-owner', 'gmail', ?, 'connected',
            1783659600, 1783659600
          )
        ''', ['b' * 64]);
        database.execute('''
          INSERT INTO email_sources (
            id, owner_user_id, connection_id, provider_message_id,
            provider_thread_id, received_at, sanitized_content_hash,
            evidence_excerpts_json, processing_state, created_at, updated_at
          ) VALUES
            (
              'confirmed-source', 'legacy-owner', 'legacy-connection',
              'confirmed-message', 'confirmed-thread', 1783659600, ?,
              '[]', 'processed', 1783659600, 1783659600
            ),
            (
              'proposal-source', 'legacy-owner', 'legacy-connection',
              'proposal-message', 'confirmed-thread', 1783663200, ?,
              '[]', 'processed', 1783663200, 1783663200
            ),
            (
              'dismissed-source', 'legacy-owner', 'legacy-connection',
              'raw-dismissed-message', 'raw-dismissed-thread', 1783666800, ?,
              '["secret excerpt"]', 'processed', 1783666800, 1783666800
            )
        ''', ['c' * 64, 'd' * 64, 'e' * 64]);
        database.execute('''
          INSERT INTO email_candidates (
            id, owner_user_id, source_id, schema_version, candidate_type,
            normalized_payload_json, review_state, semantic_fingerprint,
            linked_entity_type, linked_entity_id,
            confirmation_idempotency_key, requires_user_confirmation,
            confirmed_at, dismissed_at, created_at, updated_at
          ) VALUES
            (
              'confirmed-candidate', 'legacy-owner', 'confirmed-source',
              '1.0', 'assignment', ?, 'confirmed', ?, 'assignment',
              'confirmed-entity', 'legacy-confirmation', 1, 1783659600,
              NULL, 1783659600, 1783659600
            ),
            (
              'dismissed-candidate', 'legacy-owner', 'dismissed-source',
              '1.0', 'assignment', ?, 'dismissed', ?, NULL, NULL, NULL, 1,
              NULL, 1783666800, 1783666800, 1783666800
            )
        ''', [
          '{"schema_version":"1.0","candidate_type":"assignment"}',
          'f' * 64,
          '{"schema_version":"1.0","candidate_type":"assignment","summary":"secret proposal"}',
          'a' * 64,
        ]);
        database.execute('''
          INSERT INTO email_candidate_updates (
            id, owner_user_id, candidate_id, source_id, field_diff_json,
            proposed_payload_json, semantic_fingerprint, state,
            created_at, updated_at
          ) VALUES (
            'legacy-update', 'legacy-owner', 'confirmed-candidate',
            'proposal-source', ?, ?, ?, 'pending', 1783663200, 1783663200
          )
        ''', [
          '{"due_at":{"before":"2030-01-01T00:00:00.000Z","after":"2030-01-02T00:00:00.000Z"}}',
          '{"schema_version":"1.0","candidate_type":"assignment"}',
          '1' * 64,
        ]);
        if (sourceVersion >= 12) {
          database.execute('''
            UPDATE email_candidate_updates
            SET base_entity_version = 7,
                state = 'accepted',
                resolution_idempotency_key = 'legacy-update-resolution',
                resolved_at = 1783663200
            WHERE id = 'legacy-update'
          ''');
          database.execute('''
            INSERT INTO email_dismissal_tombstones (
              id, owner_user_id, provider, provider_account_hash,
              provider_message_id_hash, provider_thread_id_hash,
              sanitized_content_hash, semantic_fingerprint, dismissed_at
            ) VALUES (
              'dismissed-tombstone', 'legacy-owner', 'gmail', ?, ?, ?, ?, ?,
              1783666800
            )
          ''', [
            'b' * 64,
            '6' * 64,
            '7' * 64,
            '8' * 64,
            '9' * 64,
          ]);
          database.execute('''
            INSERT INTO sync_queue_entries (
              client_mutation_id, owner_user_id, idempotency_key,
              entity_type, entity_id, operation, payload_json, base_version,
              created_at, enqueue_sequence, status
            ) VALUES
              (
                'legacy-confirmation-mutation', 'legacy-owner',
                'legacy-confirmation', 'assignment', 'confirmed-entity',
                'create', '{}', NULL, 1783659600, 1, 'pending'
              ),
              (
                'legacy-update-resolution', 'legacy-owner',
                'legacy-update-resolution', 'assignment', 'confirmed-entity',
                'update', '{}', 7, 1783663200, 2, 'pending'
              )
          ''');
          database.execute('''
            UPDATE sync_queue_sequence_states SET next_value = 3 WHERE id = 1
          ''');
        }
        database.execute('''
          INSERT INTO email_schedule_entity_links (
            id, owner_user_id, source_id, candidate_id, entity_type,
            entity_id, confirmation_idempotency_key, created_at
          ) VALUES (
            'legacy-link', 'legacy-owner', 'confirmed-source',
            'confirmed-candidate', 'assignment', 'confirmed-entity',
            'legacy-confirmation', 1783659600
          )
        ''');
        database.execute('''
          INSERT INTO notification_schedule_requests (
            id, owner_user_id, entity_type, entity_id, source_id,
            idempotency_key, anchor_at, target_path, created_at, updated_at
          ) VALUES (
            'legacy-notification', 'legacy-owner', 'assignment',
            'confirmed-entity', 'confirmed-candidate', 'legacy-confirmation',
            1783659600, '/assignment/confirmed-entity/edit',
            1783659600, 1783659600
          )
        ''');
        database.execute('PRAGMA user_version = $sourceVersion');
      },
    ),
  );
}

void _createVersionFourContextTables(void Function(String) execute) {
  execute('''
    CREATE TABLE profiles (
      user_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      university_id TEXT
    )
  ''');
  execute('''
    CREATE TABLE universities (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      normalized_name TEXT NOT NULL,
      aliases_json TEXT NOT NULL DEFAULT '[]',
      domain_hints_json TEXT NOT NULL DEFAULT '[]',
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  execute('''
    CREATE TABLE terms (
      id TEXT PRIMARY KEY,
      university_id TEXT NOT NULL,
      name TEXT NOT NULL,
      academic_year INTEGER NOT NULL,
      start_date INTEGER NOT NULL,
      end_date INTEGER NOT NULL,
      term_type TEXT NOT NULL
    )
  ''');
  execute('''
    CREATE TABLE period_settings (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      day_of_week INTEGER NOT NULL,
      period_no INTEGER NOT NULL,
      start_time_minutes INTEGER NOT NULL,
      end_time_minutes INTEGER NOT NULL
    )
  ''');
  execute('''
    CREATE TABLE user_courses (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      term_id TEXT NOT NULL
    )
  ''');
  execute('''
    INSERT INTO universities (
      id, name, normalized_name, aliases_json, domain_hints_json, updated_at
    ) VALUES ('university-a', 'University A', 'university a', '[]', '[]', 0)
  ''');
  execute('''
    INSERT INTO terms (
      id, university_id, name, academic_year, start_date, end_date, term_type
    ) VALUES ('term-a', 'university-a', '2026 Spring', 2026, 0, 1, 'semester')
  ''');
  execute('''
    INSERT INTO user_courses (id, owner_user_id, term_id)
    VALUES ('course-a', 'legacy-owner', 'term-a')
  ''');
  execute('''
    INSERT INTO period_settings (
      id, owner_user_id, day_of_week, period_no,
      start_time_minutes, end_time_minutes
    ) VALUES ('period-a', 'legacy-owner', 1, 1, 520, 620)
  ''');
}

void _createVersionSixEventExceptionTables(void Function(String) execute) {
  execute('''
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      deleted_at INTEGER
    )
  ''');
  execute('''
    CREATE TABLE event_exceptions (
      id TEXT PRIMARY KEY,
      event_id TEXT NOT NULL,
      recurrence_id INTEGER NOT NULL,
      mode TEXT NOT NULL,
      override_start_at INTEGER,
      override_end_at INTEGER,
      override_payload_json TEXT NOT NULL DEFAULT '{}'
    )
  ''');
  execute('''
    INSERT INTO events (id, owner_user_id, deleted_at)
    VALUES ('routine-legacy', 'legacy-owner', NULL)
  ''');
  execute('''
    INSERT INTO event_exceptions (
      id, event_id, recurrence_id, mode, override_payload_json
    ) VALUES (
      'exception-legacy',
      'routine-legacy',
      1783987200,
      'cancelled',
      '{}'
    )
  ''');
}

void _createVersionSevenEventExceptionTables(void Function(String) execute) {
  execute('''
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      deleted_at INTEGER
    )
  ''');
  execute('''
    CREATE TABLE event_exceptions (
      id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      event_id TEXT NOT NULL,
      recurrence_id INTEGER NOT NULL,
      mode TEXT NOT NULL,
      override_start_at INTEGER,
      override_end_at INTEGER,
      override_payload_json TEXT NOT NULL DEFAULT '{}',
      updated_at INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER,
      version INTEGER NOT NULL DEFAULT 1
    )
  ''');
}

void _createVersionEightCalendarDisplayPreferencesTable(
  void Function(String) execute,
) {
  execute('''
    CREATE TABLE calendar_display_preferences (
      owner_user_id TEXT NOT NULL PRIMARY KEY,
      show_courses INTEGER NOT NULL DEFAULT 1,
      show_assignment_deadlines INTEGER NOT NULL DEFAULT 1,
      show_exams INTEGER NOT NULL DEFAULT 1,
      show_personal_events INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL
    )
  ''');
}

void _createVersionTenEmailFoundationTables(
  void Function(String) execute, {
  bool createCanonicalTables = true,
}) {
  if (createCanonicalTables) {
    execute('''
      CREATE TABLE assignments (
        id TEXT NOT NULL PRIMARY KEY,
        owner_user_id TEXT NOT NULL
      )
    ''');
    execute('''
      CREATE TABLE exams (
        id TEXT NOT NULL PRIMARY KEY,
        owner_user_id TEXT NOT NULL
      )
    ''');
  }
  execute('''
    CREATE TABLE email_connections (
      id TEXT NOT NULL PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      provider_account_hash TEXT NOT NULL,
      account_hint TEXT,
      scopes_json TEXT NOT NULL DEFAULT '[]',
      cursor TEXT,
      state TEXT NOT NULL DEFAULT 'disconnected',
      error_category TEXT,
      retry_after INTEGER,
      last_synced_at INTEGER,
      disconnected_at INTEGER,
      created_at INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  execute('''
    CREATE TABLE email_sources (
      id TEXT NOT NULL PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      connection_id TEXT NOT NULL REFERENCES email_connections(id)
        ON DELETE CASCADE,
      provider_message_id TEXT NOT NULL,
      provider_thread_id TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      sanitized_content_hash TEXT NOT NULL,
      evidence_excerpts_json TEXT NOT NULL DEFAULT '[]',
      processing_state TEXT NOT NULL DEFAULT 'pending',
      error_category TEXT,
      created_at INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL DEFAULT 0,
      UNIQUE(connection_id, provider_message_id)
    )
  ''');
  execute('''
    CREATE TABLE email_candidates (
      id TEXT NOT NULL PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      source_id TEXT NOT NULL REFERENCES email_sources(id)
        ON DELETE CASCADE,
      schema_version TEXT NOT NULL,
      candidate_type TEXT NOT NULL,
      normalized_payload_json TEXT NOT NULL,
      review_state TEXT NOT NULL DEFAULT 'needs_review',
      semantic_fingerprint TEXT NOT NULL,
      linked_entity_type TEXT,
      linked_entity_id TEXT,
      confirmation_idempotency_key TEXT,
      error_category TEXT,
      requires_user_confirmation INTEGER NOT NULL DEFAULT 1,
      confirmed_at INTEGER,
      dismissed_at INTEGER,
      created_at INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  execute('''
    CREATE TABLE email_candidate_updates (
      id TEXT NOT NULL PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      candidate_id TEXT NOT NULL REFERENCES email_candidates(id)
        ON DELETE CASCADE,
      source_id TEXT NOT NULL REFERENCES email_sources(id)
        ON DELETE CASCADE,
      field_diff_json TEXT NOT NULL,
      proposed_payload_json TEXT NOT NULL,
      semantic_fingerprint TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending',
      error_category TEXT,
      resolution_idempotency_key TEXT,
      resolved_at INTEGER,
      created_at INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
}

Future<void> _expectVersionFourContextMigration(
  local.AppDatabase database,
) async {
  final period = await (database.select(database.periodSettings)
        ..where((row) => row.id.equals('period-a')))
      .getSingle();
  expect(period.ownerUserId, 'legacy-owner');
  expect(period.universityId, 'university-a');
  expect(period.termId, 'term-a');

  final profileColumns = await database
      .customSelect("PRAGMA table_info('profiles')")
      .map((row) => row.read<String>('name'))
      .get();
  expect(
    profileColumns,
    containsAll(<String>[
      'user_type',
      'campus_id',
      'faculty_id',
      'department_id',
      'active_term_id',
      'entry_academic_year',
      'onboarding_status',
      'onboarding_step',
      'onboarding_completed_at',
      'version',
    ]),
  );
}

Future<void> _expectVersionSixEventExceptionMigration(
  local.AppDatabase database,
) async {
  final columns = await database
      .customSelect("PRAGMA table_info('event_exceptions')")
      .map((row) => row.read<String>('name'))
      .get();
  expect(
    columns,
    containsAll(['owner_user_id', 'updated_at', 'deleted_at', 'version']),
  );
  final exception = await (database.select(database.eventExceptions)
        ..where((row) => row.id.equals('exception-legacy')))
      .getSingle();
  expect(exception.ownerUserId, 'legacy-owner');
  expect(exception.version, 1);
  expect(exception.deletedAt, isNull);
}

Future<void> _expectVersionOneEntityColumns(local.AppDatabase database) async {
  final assignmentColumns = await database
      .customSelect("PRAGMA table_info('assignments')")
      .map((row) => row.read<String>('name'))
      .get();
  final examColumns = await database
      .customSelect("PRAGMA table_info('exams')")
      .map((row) => row.read<String>('name'))
      .get();

  expect(assignmentColumns, contains('priority'));
  expect(examColumns, containsAll(<String>['memo', 'exam_type']));
}
