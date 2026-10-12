import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:uuid/uuid.dart';

import '../features/email_import/data/email_candidate_dedupe.dart';
import '../core/native/sqlite_identity_handshake.dart';
import 'email_import_identity.dart';
import 'tables/app_tables.dart';

part 'app_database.g.dart';
part 'daos/app_daos.dart';

const scheduleSyncCompletionRemoteApplied = 'remote_applied';
const scheduleSyncCompletionServerWins = 'server_wins';
const appDatabaseCurrentSchemaVersion = 19;

@DriftDatabase(
  tables: [
    Profiles,
    Universities,
    Campuses,
    Faculties,
    Departments,
    UniversityDomains,
    Terms,
    PeriodTemplateSets,
    PeriodTemplates,
    PeriodSettings,
    OnboardingDrafts,
    CourseTemplatesCache,
    UserCourses,
    Assignments,
    AssignmentUserStates,
    Exams,
    Calendars,
    Events,
    EventExceptions,
    CalendarDisplayPreferences,
    Friendships,
    Groups,
    GroupMembers,
    EventParticipants,
    EventComments,
    EventReactions,
    EmailConnections,
    EmailSources,
    EmailCandidates,
    EmailCandidateUpdates,
    EmailDismissalTombstones,
    EmailReconciliationReceipts,
    EmailScheduleEntityLinks,
    EmailScheduleEditReceipts,
    DocumentSourcesCache,
    DocumentCandidatesCache,
    DocumentScheduleEntityLinks,
    NotificationScheduleRequests,
    LocalNotificationSettings,
    LocalNotificationOccurrences,
    LocalNotificationProjectionStates,
    SyncQueueEntries,
    SyncQueueSequenceStates,
    SyncCursors,
    WidgetSnapshots,
  ],
  daos: [
    ProfileDao,
    TimetableDao,
    CourseTemplateDao,
    AssignmentDao,
    ExamDao,
    EventDao,
    CalendarDisplayPreferencesDao,
    GroupDao,
    EmailImportDao,
    WidgetSnapshotDao,
    SyncQueueDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor) {
    // Drift may be constructed by foreground, worker, or headless paths. The
    // handshake is idempotent, and on Android this fails closed if a caller
    // bypassed bootstrap before opening the canonical database.
    SqliteIdentityHandshake.requireVerified();
  }

  @override
  int get schemaVersion => appDatabaseCurrentSchemaVersion;

  /// Removes one account's cached data without deleting the shared backend
  /// region database or rows owned by other users on this device.
  Future<void> purgeAccountData({
    required String ownerUserId,
    required List<Map<String, Object?>> groupActions,
  }) async {
    final owner = ownerUserId.trim();
    if (owner.isEmpty || owner.length > 256) {
      throw ArgumentError.value(ownerUserId, 'ownerUserId');
    }
    final actions = <String, Map<String, Object?>>{};
    for (final action in groupActions) {
      final id = action['group_id'];
      final kind = action['action'];
      if (id is! String ||
          id.isEmpty ||
          !const {'transfer', 'disband', 'delete'}.contains(kind) ||
          actions.containsKey(id)) {
        throw const FormatException('Invalid account deletion group actions.');
      }
      actions[id] = action;
    }

    await transaction(() async {
      final locallyOwnedGroups = await customSelect(
        'SELECT id FROM groups WHERE owner_user_id = ?',
        variables: [Variable.withString(owner)],
      ).get();
      final localGroupIds =
          locallyOwnedGroups.map((row) => row.read<String>('id')).toSet();
      if (!localGroupIds.every(actions.containsKey)) {
        throw StateError(
          'Local group ownership changed; account cleanup must be retried.',
        );
      }

      for (final entry in actions.entries) {
        final groupId = entry.key;
        final action = entry.value;
        if (action['action'] == 'transfer') {
          final successor = action['successor_id'];
          if (successor is! String || successor.isEmpty || successor == owner) {
            throw const FormatException('Invalid account deletion successor.');
          }
          await customStatement(
            'UPDATE groups SET owner_user_id = ? WHERE id = ? AND owner_user_id = ?',
            [successor, groupId, owner],
          );
          await customStatement(
            'UPDATE events SET owner_user_id = ? WHERE group_id = ? AND owner_user_id = ?',
            [successor, groupId, owner],
          );
          await customStatement(
            'UPDATE calendars SET owner_user_id = ? WHERE group_id = ? AND owner_user_id = ?',
            [successor, groupId, owner],
          );
          await customStatement(
            "UPDATE group_members SET role = 'member' WHERE group_id = ? AND user_id = ?",
            [groupId, owner],
          );
          await customStatement(
            "UPDATE group_members SET role = 'owner' WHERE group_id = ? AND user_id = ?",
            [groupId, successor],
          );
        } else {
          await customStatement(
            'DELETE FROM event_comments WHERE event_id IN (SELECT id FROM events WHERE group_id = ?)',
            [groupId],
          );
          await customStatement(
            'DELETE FROM event_participants WHERE event_id IN (SELECT id FROM events WHERE group_id = ?)',
            [groupId],
          );
          await customStatement(
            'DELETE FROM event_reactions WHERE event_id IN (SELECT id FROM events WHERE group_id = ?)',
            [groupId],
          );
          await customStatement(
            'DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM events WHERE group_id = ?)',
            [groupId],
          );
          await customStatement(
              'DELETE FROM events WHERE group_id = ?', [groupId]);
          await customStatement(
              'DELETE FROM calendars WHERE group_id = ?', [groupId]);
          await customStatement(
              'DELETE FROM group_members WHERE group_id = ?', [groupId]);
          await customStatement('DELETE FROM groups WHERE id = ?', [groupId]);
        }
      }

      // The remote cleanup transfers any remaining user-owned event/calendar
      // in a shared group to that group's owner before deleting personal rows.
      await customStatement('''
        UPDATE events SET owner_user_id = (
          SELECT groups.owner_user_id FROM groups WHERE groups.id = events.group_id
        ) WHERE owner_user_id = ? AND group_id IS NOT NULL
      ''', [owner]);
      await customStatement('''
        UPDATE calendars SET owner_user_id = (
          SELECT groups.owner_user_id FROM groups WHERE groups.id = calendars.group_id
        ) WHERE owner_user_id = ? AND group_id IS NOT NULL
      ''', [owner]);

      await customStatement('''
        DELETE FROM event_comments WHERE author_user_id = ? OR event_id IN (
          SELECT id FROM events WHERE owner_user_id = ? AND group_id IS NULL
        )
      ''', [owner, owner]);
      for (final table in const [
        'event_participants',
        'event_reactions',
      ]) {
        await customStatement('DELETE FROM $table WHERE user_id = ?', [owner]);
      }
      await customStatement('''
        DELETE FROM event_exceptions WHERE owner_user_id = ? OR event_id IN (
          SELECT id FROM events WHERE owner_user_id = ? AND group_id IS NULL
        )
      ''', [owner, owner]);
      await customStatement(
        'DELETE FROM events WHERE owner_user_id = ? AND group_id IS NULL',
        [owner],
      );
      await customStatement(
          'DELETE FROM assignment_user_states WHERE user_id = ?', [owner]);
      await customStatement(
        'DELETE FROM friendships WHERE requester_user_id = ? OR addressee_user_id = ?',
        [owner, owner],
      );
      await customStatement(
          'DELETE FROM group_members WHERE user_id = ?', [owner]);
      await customStatement('DELETE FROM profiles WHERE user_id = ?', [owner]);

      // Child and lease rows are removed before their owner-bound source rows.
      for (final table in const [
        'email_schedule_edit_receipts',
        'email_schedule_entity_links',
        'email_reconciliation_receipts',
        'email_candidate_updates',
        'email_candidates',
        'email_dismissal_tombstones',
        'email_sources',
        'email_connections',
        'document_schedule_entity_links',
        'document_candidates_cache',
        'document_sources_cache',
        'sync_queue_entries',
        'notification_schedule_requests',
        'local_notification_occurrences',
        'local_notification_projection_states',
        'local_notification_settings',
        'event_exceptions',
        'events',
        'assignments',
        'exams',
        'user_courses',
        'period_settings',
        'onboarding_drafts',
        'terms',
        'calendars',
        'calendar_display_preferences',
        'sync_cursors',
        'widget_snapshots',
      ]) {
        await customStatement(
          'DELETE FROM $table WHERE owner_user_id = ?',
          [owner],
        );
      }
    });
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2 && to >= 2) {
            await m.addColumn(assignments, assignments.priority);
            await m.addColumn(exams, exams.memo);
            await m.addColumn(exams, exams.examType);
            await m.addColumn(syncQueueEntries, syncQueueEntries.status);
          }
          if (from < 3 && to >= 3) {
            await m.addColumn(syncQueueEntries, syncQueueEntries.errorMessage);
          }
          if (from < 4 && to >= 4) {
            await m.addColumn(
              syncQueueEntries,
              syncQueueEntries.idempotencyKey,
            );
            await m.addColumn(syncQueueEntries, syncQueueEntries.baseVersion);
            await m.addColumn(syncQueueEntries, syncQueueEntries.serverVersion);
            await m.addColumn(syncQueueEntries, syncQueueEntries.attemptCount);
            await m.addColumn(syncQueueEntries, syncQueueEntries.nextRetryAt);
            await m.addColumn(syncQueueEntries, syncQueueEntries.lastAttemptAt);
            await m.addColumn(syncQueueEntries, syncQueueEntries.claimedAt);

            await customStatement('''
              UPDATE sync_queue_entries
              SET idempotency_key = client_mutation_id
              WHERE idempotency_key IS NULL OR idempotency_key = ''
            ''');
            await customStatement('''
              UPDATE sync_queue_entries
              SET status = 'synced'
              WHERE synced_at IS NOT NULL
                AND status <> 'synced'
            ''');
            await customStatement('''
              UPDATE sync_queue_entries
              SET payload_json = '{}',
                  error_message = NULL,
                  synced_at = COALESCE(synced_at, created_at)
              WHERE status = 'synced'
            ''');
            await customStatement('''
              UPDATE sync_queue_entries
              SET error_message = NULL
              WHERE error_message IS NOT NULL
            ''');
          }
          if (from < 5 && to >= 5) {
            await _migrateToV5(m);
          }
          if (from < 6 && to >= 6) {
            await m.addColumn(
              syncQueueEntries,
              syncQueueEntries.serverPayloadJson,
            );
            await m.addColumn(
              syncQueueEntries,
              syncQueueEntries.conflictCursor,
            );
            if (await _tableExists('assignment_user_states')) {
              await _addColumnIfMissing(
                m,
                'assignment_user_states',
                assignmentUserStates,
                assignmentUserStates.deletedAt,
              );
              await _addColumnIfMissing(
                m,
                'assignment_user_states',
                assignmentUserStates,
                assignmentUserStates.version,
              );
            }
            await m.createTable(syncCursors);
          }
          if (from < 7 && to >= 7) {
            await _migrateToV7();
          }
          if (from < 8 && to >= 8) {
            await _createTableIfMissing(
              m,
              'calendar_display_preferences',
              calendarDisplayPreferences,
            );
          }
          if (from < 9 && to >= 9) {
            await _migrateToV9(m);
          }
          if (from < 10 && to >= 10) {
            await _migrateToV10(m);
          }
          if (from < 11 && to >= 11) {
            await _migrateToV11(m);
          }
          if (from < 12 && to >= 12) {
            await _migrateToV12(m);
          }
          if (from < 13 && to >= 13) {
            // The v13 receipt backfill reads complete SyncQueueEntry rows
            // through Drift. When this upgrade also targets v14, make the v14
            // column available before that typed read. A real v12 table does
            // not have completion_provenance yet.
            if (to >= 14) {
              await _addSyncQueueCompletionProvenanceColumn(m);
            }
            await _migrateToV13(m);
          }
          if (from < 14 && to >= 14) {
            await _migrateToV14(m);
          }
          if (from < 15 && to >= 15) {
            await _migrateToV15(m);
          }
          if (from < 16 && to >= 16 && await _tableExists('events')) {
            await _addColumnIfMissing(
              m,
              'events',
              events,
              events.isAllDay,
            );
          }
          if (from < 17 && to >= 17) {
            await _createTableIfMissing(
              m,
              'document_sources_cache',
              documentSourcesCache,
            );
            await _createTableIfMissing(
              m,
              'document_candidates_cache',
              documentCandidatesCache,
            );
            await _createTableIfMissing(
              m,
              'document_schedule_entity_links',
              documentScheduleEntityLinks,
            );
          }
          if (from < 18 && to >= 18) {
            await _createTableIfMissing(
              m,
              'local_notification_settings',
              localNotificationSettings,
            );
            await _createTableIfMissing(
              m,
              'local_notification_occurrences',
              localNotificationOccurrences,
            );
            await _createTableIfMissing(
              m,
              'local_notification_projection_states',
              localNotificationProjectionStates,
            );
          }
          if (from < 19 && to >= 19) {
            await _migrateToV19(m);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await _ensureSyncQueueInfrastructure();
          await _ensureEventExceptionInfrastructure();
          await _ensureEmailImportInfrastructure();
          await _ensureEmailConfirmationInfrastructure();
          await _ensureEmailDedupeInfrastructure();
          await _ensureEmailReconciliationInfrastructure();
          await _ensureEmailScheduleEditReceiptInfrastructure();
          await _ensureDocumentImportInfrastructure();
          await _ensureLocalNotificationInfrastructure();
        },
      );

  Future<void> _migrateToV19(Migrator migrator) async {
    // The old PRIVATE values/defaults are retained. Rebuild only these two
    // tables so their existing rows survive while explicit NULL overrides
    // become representable. beforeOpen recreates the event epoch triggers.
    if (await _hasColumns('calendars', const [
      'id',
      'owner_user_id',
      'group_id',
      'name',
      'default_visibility',
      'updated_at',
    ])) {
      await migrator.alterTable(TableMigration(calendars));
    }
    if (await _hasColumns('events', const [
      'id',
      'owner_user_id',
      'calendar_id',
      'group_id',
      'title',
      'kind',
      'start_at',
      'end_at',
      'is_all_day',
      'location',
      'description',
      'rrule',
      'timezone',
      'visibility_level',
      'updated_at',
      'deleted_at',
      'version',
    ])) {
      await migrator.alterTable(TableMigration(events));
    }
  }

  Future<bool> _hasColumns(String table, List<String> expected) async {
    if (!await _tableExists(table)) return false;
    final columns = await customSelect('PRAGMA table_info($table)')
        .map((row) => row.read<String>('name'))
        .get();
    return expected.every(columns.contains);
  }

  Future<void> _ensureLocalNotificationInfrastructure() async {
    if (!await _tableExists('local_notification_settings') ||
        !await _tableExists('local_notification_occurrences') ||
        !await _tableExists('local_notification_projection_states')) {
      return;
    }
    await customStatement('''
      CREATE INDEX IF NOT EXISTS local_notification_occurrences_owner_trigger_idx
      ON local_notification_occurrences(owner_user_id, trigger_at)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS local_notification_occurrences_owner_source_idx
      ON local_notification_occurrences(owner_user_id, source_entity_id)
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_notification_source_revisions (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        epoch INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO local_notification_source_revisions(id, epoch)
      VALUES (1, 0)
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_notification_permission_prompts (
        owner_user_id TEXT NOT NULL,
        prompt_key TEXT NOT NULL,
        prompted_at INTEGER NOT NULL,
        PRIMARY KEY (owner_user_id, prompt_key)
      )
    ''');
    const watchedTables = <String>[
      'terms',
      'period_settings',
      'user_courses',
      'assignments',
      'assignment_user_states',
      'exams',
      'events',
      'event_exceptions',
      'notification_schedule_requests',
      'local_notification_settings',
    ];
    for (final table in watchedTables) {
      if (!await _tableExists(table)) continue;
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS local_notification_epoch_${table}_insert
        AFTER INSERT ON $table BEGIN
          UPDATE local_notification_source_revisions
          SET epoch = epoch + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1;
        END
      ''');
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS local_notification_epoch_${table}_update
        AFTER UPDATE ON $table BEGIN
          UPDATE local_notification_source_revisions
          SET epoch = epoch + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1;
        END
      ''');
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS local_notification_epoch_${table}_delete
        AFTER DELETE ON $table BEGIN
          UPDATE local_notification_source_revisions
          SET epoch = epoch + 1, updated_at = CURRENT_TIMESTAMP WHERE id = 1;
        END
      ''');
    }
  }

  Future<void> _ensureDocumentImportInfrastructure() async {
    if (!await _tableExists('document_sources_cache') ||
        !await _tableExists('document_candidates_cache') ||
        !await _tableExists('document_schedule_entity_links')) {
      return;
    }
    await customStatement('''
      CREATE INDEX IF NOT EXISTS document_sources_cache_owner_updated_idx
      ON document_sources_cache(owner_user_id, updated_at DESC)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS document_candidates_cache_owner_review_idx
      ON document_candidates_cache(owner_user_id, review_state, updated_at DESC)
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS document_candidate_owner_guard_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS document_candidate_owner_guard_update',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS document_link_owner_guard_insert',
    );
    await customStatement('''
      CREATE TRIGGER document_candidate_owner_guard_insert
      BEFORE INSERT ON document_candidates_cache
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1 FROM document_sources_cache source
        WHERE source.id = NEW.source_id
          AND source.owner_user_id = NEW.owner_user_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'document candidate owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER document_candidate_owner_guard_update
      BEFORE UPDATE OF owner_user_id, source_id ON document_candidates_cache
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR NOT EXISTS (
          SELECT 1 FROM document_sources_cache source
          WHERE source.id = NEW.source_id
            AND source.owner_user_id = NEW.owner_user_id
        )
      BEGIN
        SELECT RAISE(ABORT, 'document candidate owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER document_link_owner_guard_insert
      BEFORE INSERT ON document_schedule_entity_links
      FOR EACH ROW
      WHEN NOT EXISTS (
        SELECT 1
        FROM document_candidates_cache candidate
        JOIN document_sources_cache source ON source.id = candidate.source_id
        WHERE candidate.id = NEW.candidate_cache_id
          AND candidate.source_id = NEW.source_id
          AND candidate.owner_user_id = NEW.owner_user_id
          AND source.owner_user_id = NEW.owner_user_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'document link owner mismatch');
      END
    ''');
  }

  Future<void> _migrateToV15(Migrator m) async {
    await _createTableIfMissing(
      m,
      'email_schedule_edit_receipts',
      emailScheduleEditReceipts,
    );
    await _backfillV15EmailScheduleProvenance();
  }

  Future<void> _backfillV15EmailScheduleProvenance() async {
    if (!await _tableExists('email_schedule_edit_receipts') ||
        !await _tableExists('email_reconciliation_receipts') ||
        !await _tableExists('email_schedule_entity_links') ||
        !await _tableExists('sync_queue_entries')) {
      return;
    }
    await customStatement(
      'DROP TRIGGER IF EXISTS email_reconciliation_values_guard_update',
    );
    final candidates = await (select(emailCandidates)
          ..where((row) =>
              row.reviewState.equals('confirmed') &
              row.confirmedAt.isNotNull() &
              row.linkedEntityType.isIn(const ['assignment', 'exam', 'event']) &
              row.linkedEntityId.isNotNull() &
              row.confirmationIdempotencyKey.isNotNull()))
        .get();
    const codec = domain.EmailCandidatePayloadCodec();
    for (final candidate in candidates) {
      final receipt = await (select(emailReconciliationReceipts)
            ..where((row) =>
                row.id.equals('confirmation:${candidate.id}') &
                row.ownerUserId.equals(candidate.ownerUserId)))
          .getSingleOrNull();
      final link = await (select(emailScheduleEntityLinks)
            ..where((row) =>
                row.ownerUserId.equals(candidate.ownerUserId) &
                row.candidateId.equals(candidate.id) &
                row.entityType.equals(candidate.linkedEntityType!) &
                row.entityId.equals(candidate.linkedEntityId!)))
          .getSingleOrNull();
      final mutation = receipt?.requiredSyncMutationId == null
          ? null
          : await (select(syncQueueEntries)
                ..where((row) =>
                    row.clientMutationId
                        .equals(receipt!.requiredSyncMutationId!) &
                    row.ownerUserId.equals(candidate.ownerUserId)))
              .getSingleOrNull();
      final type = domain.EmailCandidateType.fromWire(
        candidate.linkedEntityType!,
      );
      if (receipt == null ||
          link == null ||
          mutation == null ||
          mutation.operation != 'create' ||
          mutation.baseVersion != null ||
          mutation.entityType != candidate.linkedEntityType ||
          mutation.entityId != candidate.linkedEntityId ||
          mutation.idempotencyKey != candidate.confirmationIdempotencyKey ||
          !mutation.createdAt.isAtSameMomentAs(candidate.confirmedAt!)) {
        continue;
      }
      final retainedFullCreate = mutation.payloadJson != '{}' &&
          _v15IsVerifiableNonterminalMutation(mutation);
      final acknowledgedScrubbedCreate =
          _v15IsAuthenticatedScrubbedCreate(mutation, receipt);
      if (!retainedFullCreate && !acknowledgedScrubbedCreate) continue;
      if (acknowledgedScrubbedCreate) {
        await _v15BackfillAcknowledgedScrubbedConfirmation(
          candidate: candidate,
          receipt: receipt,
          link: link,
          mutation: mutation,
          entityType: type,
          codec: codec,
        );
        continue;
      }
      final Object? decodedMutation;
      try {
        decodedMutation = jsonDecode(mutation.payloadJson);
      } on FormatException {
        continue;
      }
      if (decodedMutation is! Map) continue;
      final rawInitialPayload = decodedMutation.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
      final initialPayload = emailScheduleReplayPayload(
        entityType: type,
        payload: rawInitialPayload,
      );
      if (initialPayload['id'] != candidate.linkedEntityId ||
          initialPayload['ownerUserId'] != candidate.ownerUserId ||
          initialPayload['version'] != 1 ||
          initialPayload['visibilityLevel'] != 'PRIVATE' ||
          !_v15DateTimeMatches(
            initialPayload['updatedAt'],
            candidate.confirmedAt!,
          ) ||
          !_v15ValidInitialPayloadShape(
            entityType: type,
            rawPayload: rawInitialPayload,
            canonicalPayload: initialPayload,
          )) {
        continue;
      }
      final originalCandidate = await _v15OriginalCandidatePayload(
        candidate,
        codec,
      );
      if (originalCandidate == null ||
          !_v15CandidateMatchesEntity(originalCandidate, initialPayload)) {
        continue;
      }
      final originalCandidateJson = codec.encode(originalCandidate);
      if (receipt.reviewedPayloadJson != originalCandidateJson) {
        await (update(emailReconciliationReceipts)
              ..where((row) =>
                  row.id.equals(receipt.id) &
                  row.ownerUserId.equals(candidate.ownerUserId)))
            .write(
          EmailReconciliationReceiptsCompanion(
            reviewedPayloadJson: Value(originalCandidateJson),
          ),
        );
      }
      final confirmedAt = candidate.confirmedAt!.toUtc();
      final initialFingerprint =
          emailSchedulePayloadFingerprint(initialPayload);
      await into(emailScheduleEditReceipts).insert(
        EmailScheduleEditReceiptsCompanion.insert(
          mutationId: mutation.clientMutationId,
          ownerUserId: candidate.ownerUserId,
          candidateId: candidate.id,
          linkId: link.id,
          entityType: candidate.linkedEntityType!,
          entityId: candidate.linkedEntityId!,
          provenance: 'confirmation',
          baseEntityVersion: 0,
          entityVersion: 1,
          basePayloadFingerprint: initialFingerprint,
          payloadFingerprint: initialFingerprint,
          candidatePayloadFingerprint:
              emailCandidatePayloadFingerprint(originalCandidate),
          entityUpdatedAt: confirmedAt,
          createdAt: confirmedAt,
        ),
        mode: InsertMode.insertOrIgnore,
      );
      final currentPayload = await _v15CurrentEntityPayload(
        ownerUserId: candidate.ownerUserId,
        entityType: type,
        entityId: candidate.linkedEntityId!,
      );
      final currentVersion = currentPayload?['version'];
      final currentUpdatedAt = currentPayload?['updatedAt'];
      if (currentPayload == null ||
          currentVersion is! int ||
          currentUpdatedAt is! DateTime ||
          currentVersion < 1) {
        await (delete(emailScheduleEditReceipts)
              ..where(
                  (row) => row.mutationId.equals(mutation.clientMutationId)))
            .go();
        continue;
      }
      final currentFingerprint =
          emailSchedulePayloadFingerprint(currentPayload);
      if (currentVersion == 1) {
        if (currentFingerprint != initialFingerprint) {
          await (delete(emailScheduleEditReceipts)
                ..where(
                    (row) => row.mutationId.equals(mutation.clientMutationId)))
              .go();
        }
        continue;
      }
      final currentCandidate = codec.decode(candidate.normalizedPayloadJson);
      final backfilled = await _v15BackfillRetainedScheduleChain(
        candidate: candidate,
        link: link,
        entityType: type,
        initialPayload: initialPayload,
        initialFingerprint: initialFingerprint,
        originalCandidate: originalCandidate,
        currentPayload: currentPayload,
        currentFingerprint: currentFingerprint,
        currentCandidate: currentCandidate,
        codec: codec,
      );
      if (!backfilled) {
        await (delete(emailScheduleEditReceipts)
              ..where((row) =>
                  row.ownerUserId.equals(candidate.ownerUserId) &
                  row.candidateId.equals(candidate.id) &
                  row.entityType.equals(candidate.linkedEntityType!) &
                  row.entityId.equals(candidate.linkedEntityId!)))
            .go();
      }
    }
  }

  bool _v15IsAuthenticatedScrubbedCreate(
    SyncQueueEntry mutation,
    EmailReconciliationReceipt receipt,
  ) {
    final syncedAt = mutation.syncedAt;
    final scheduleAckedAt = receipt.scheduleAckedAt;
    return mutation.payloadJson == '{}' &&
        mutation.status == 'synced' &&
        mutation.completionProvenance == scheduleSyncCompletionRemoteApplied &&
        mutation.serverVersion == 1 &&
        mutation.serverPayloadJson == null &&
        mutation.conflictCursor == null &&
        mutation.errorMessage == null &&
        syncedAt != null &&
        scheduleAckedAt != null &&
        syncedAt.isAtSameMomentAs(scheduleAckedAt);
  }

  Future<void> _v15BackfillAcknowledgedScrubbedConfirmation({
    required EmailCandidate candidate,
    required EmailReconciliationReceipt receipt,
    required EmailScheduleEntityLink link,
    required SyncQueueEntry mutation,
    required domain.EmailCandidateType entityType,
    required domain.EmailCandidatePayloadCodec codec,
  }) async {
    final originalCandidate = await _v15OriginalCandidatePayload(
      candidate,
      codec,
    );
    final currentPayload = await _v15CurrentEntityPayload(
      ownerUserId: candidate.ownerUserId,
      entityType: entityType,
      entityId: candidate.linkedEntityId!,
    );
    if (originalCandidate == null ||
        currentPayload == null ||
        currentPayload['version'] != 1 ||
        currentPayload['deletedAt'] != null ||
        receipt.reviewedPayloadJson != codec.encode(originalCandidate) ||
        codec.encode(originalCandidate) != candidate.normalizedPayloadJson ||
        candidate.semanticFingerprint !=
            emailCandidateSemanticFingerprint(originalCandidate) ||
        !_v15CandidateMatchesEntity(originalCandidate, currentPayload) ||
        !_v15ValidAcknowledgedV1Defaults(entityType, currentPayload) ||
        !await _v15HasExactAcknowledgedConfirmationArtifacts(
          candidate: candidate,
          receipt: receipt,
          link: link,
          entityType: entityType,
          currentPayload: currentPayload,
          candidatePayload: originalCandidate,
        )) {
      return;
    }
    final baseline = _v15AcknowledgedV1Baseline(
      candidate: candidate,
      entityType: entityType,
      currentPayload: currentPayload,
      originalCandidate: originalCandidate,
    );
    final currentUpdatedAt = currentPayload['updatedAt'];
    if (baseline == null || currentUpdatedAt is! DateTime) return;
    final baselineFingerprint = emailSchedulePayloadFingerprint(baseline);
    final currentFingerprint = emailSchedulePayloadFingerprint(currentPayload);
    await _v15InsertScheduleEditReceipt(
      mutationId: mutation.clientMutationId,
      candidate: candidate,
      link: link,
      provenance: 'confirmation',
      baseEntityVersion: 0,
      entityVersion: 1,
      basePayloadFingerprint: baselineFingerprint,
      payloadFingerprint: baselineFingerprint,
      candidatePayload: originalCandidate,
      entityUpdatedAt: candidate.confirmedAt!,
    );
    await _v15InsertScheduleEditReceipt(
      mutationId: 'remote-ack:${mutation.clientMutationId}',
      candidate: candidate,
      link: link,
      provenance: 'remote_ack',
      baseEntityVersion: 1,
      entityVersion: 1,
      basePayloadFingerprint: baselineFingerprint,
      payloadFingerprint: currentFingerprint,
      candidatePayload: originalCandidate,
      entityUpdatedAt: currentUpdatedAt,
    );
  }

  Map<String, Object?>? _v15AcknowledgedV1Baseline({
    required EmailCandidate candidate,
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> currentPayload,
    required domain.EmailCandidatePayload originalCandidate,
  }) {
    final confirmedAt = candidate.confirmedAt?.toUtc();
    if (confirmedAt == null) return null;
    final payload = switch (entityType) {
      domain.EmailCandidateType.assignment => <String, Object?>{
          'id': candidate.linkedEntityId,
          'ownerUserId': candidate.ownerUserId,
          'courseId': currentPayload['courseId'],
          'title': originalCandidate.title,
          'dueAt': originalCandidate.due.at,
          'submissionUrl': originalCandidate.submissionUrl,
          'memo': originalCandidate.summary,
          'priority': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': confirmedAt,
          'version': 1,
        },
      domain.EmailCandidateType.exam => <String, Object?>{
          'id': candidate.linkedEntityId,
          'ownerUserId': candidate.ownerUserId,
          'courseId': currentPayload['courseId'],
          'title': originalCandidate.title,
          'startAt': originalCandidate.startAt,
          'endAt': originalCandidate.endAt,
          'room': originalCandidate.location,
          'scope': null,
          'memo': originalCandidate.summary,
          'examType': null,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': confirmedAt,
          'version': 1,
        },
      domain.EmailCandidateType.event => <String, Object?>{
          'id': candidate.linkedEntityId,
          'ownerUserId': candidate.ownerUserId,
          'calendarId': currentPayload['calendarId'],
          'groupId': null,
          'title': originalCandidate.title,
          'kind': domain.EventKind.normal.name,
          'startAt': originalCandidate.startAt,
          'endAt': originalCandidate.endAt,
          'location': originalCandidate.location,
          'description': originalCandidate.summary,
          'rrule': null,
          'timezone': domain.japanTimeZone,
          'visibilityLevel': 'PRIVATE',
          'updatedAt': confirmedAt,
          'version': 1,
        },
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        null,
    };
    return payload == null
        ? null
        : emailScheduleReplayPayload(
            entityType: entityType,
            payload: payload,
          );
  }

  bool _v15ValidAcknowledgedV1Defaults(
    domain.EmailCandidateType entityType,
    Map<String, Object?> payload,
  ) {
    if (payload['visibilityLevel'] != 'PRIVATE') return false;
    return switch (entityType) {
      domain.EmailCandidateType.assignment => payload['priority'] == null,
      domain.EmailCandidateType.exam =>
        payload['scope'] == null && payload['examType'] == null,
      domain.EmailCandidateType.event => payload['groupId'] == null &&
          payload['kind'] == domain.EventKind.normal.name &&
          payload['rrule'] == null &&
          payload['timezone'] == domain.japanTimeZone,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        false,
    };
  }

  Future<bool> _v15HasExactAcknowledgedConfirmationArtifacts({
    required EmailCandidate candidate,
    required EmailReconciliationReceipt receipt,
    required EmailScheduleEntityLink link,
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> currentPayload,
    required domain.EmailCandidatePayload candidatePayload,
  }) async {
    final source = await (select(emailSources)
          ..where((row) =>
              row.id.equals(candidate.sourceId) &
              row.ownerUserId.equals(candidate.ownerUserId)))
        .getSingleOrNull();
    final connection = source == null
        ? null
        : await (select(emailConnections)
              ..where((row) =>
                  row.id.equals(source.connectionId) &
                  row.ownerUserId.equals(candidate.ownerUserId)))
            .getSingleOrNull();
    final notifications = await (select(notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(candidate.ownerUserId) &
              row.entityType.equals(entityType.wireName) &
              row.entityId.equals(candidate.linkedEntityId!) &
              row.sourceId.equals(candidate.id) &
              row.idempotencyKey.equals(candidate.confirmationIdempotencyKey!)))
        .get();
    if (source == null ||
        connection == null ||
        notifications.length != 1 ||
        source.processingState != 'processed' ||
        source.errorCategory != null ||
        receipt.action != 'confirmation' ||
        receipt.localReferenceId != candidate.id ||
        receipt.connectionId != source.connectionId ||
        receipt.provider != connection.provider ||
        receipt.providerAccountHash != connection.providerAccountHash ||
        receipt.providerMessageIdHash !=
            emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ) ||
        receipt.providerThreadIdHash !=
            emailProviderIdentifierHash(
              kind: 'thread',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerThreadId,
            ) ||
        receipt.sanitizedContentHash != source.sanitizedContentHash ||
        receipt.resolution != null ||
        receipt.entityType != entityType.wireName ||
        receipt.entityId != candidate.linkedEntityId ||
        receipt.idempotencyKey != candidate.confirmationIdempotencyKey ||
        receipt.requiredSyncMutationId == null ||
        receipt.errorCategory != null ||
        link.sourceId != candidate.sourceId ||
        link.confirmationIdempotencyKey !=
            candidate.confirmationIdempotencyKey) {
      return false;
    }
    final notification = notifications.single;
    final containerId = switch (entityType) {
      domain.EmailCandidateType.assignment ||
      domain.EmailCandidateType.exam =>
        currentPayload['courseId'],
      domain.EmailCandidateType.event => currentPayload['calendarId'],
      _ => null,
    };
    if (containerId != null &&
        (containerId is! String || containerId.trim().isEmpty)) {
      return false;
    }
    if (entityType == domain.EmailCandidateType.event && containerId == null) {
      return false;
    }
    final expectedConfirmationKey = const Uuid().v5(
      Namespace.url.value,
      'email-confirmation\u0000${candidate.ownerUserId}\u0000${candidate.id}'
      '\u0000${entityType.wireName}\u0000${containerId ?? '<standalone>'}',
    );
    if (candidate.confirmationIdempotencyKey != expectedConfirmationKey ||
        link.confirmationIdempotencyKey != expectedConfirmationKey ||
        receipt.idempotencyKey != expectedConfirmationKey ||
        notification.idempotencyKey != expectedConfirmationKey) {
      return false;
    }
    final anchorKey = entityType == domain.EmailCandidateType.assignment
        ? 'dueAt'
        : 'startAt';
    final anchor = _v15PayloadDateTime(currentPayload[anchorKey]);
    final currentUpdatedAt = _v15PayloadDateTime(currentPayload['updatedAt']);
    if (anchor == null || currentUpdatedAt == null) return false;
    final targetPath = switch (entityType) {
      domain.EmailCandidateType.assignment =>
        '/assignment/${candidate.linkedEntityId}/edit',
      domain.EmailCandidateType.exam =>
        '/exam/${candidate.linkedEntityId}/edit',
      domain.EmailCandidateType.event =>
        '/event/${candidate.linkedEntityId}/edit',
      _ => '',
    };
    final validReceiptState = receipt.state == 'pending'
        ? receipt.reconciledAt == null && receipt.replayed == null
        : receipt.state == 'succeeded' &&
            receipt.reconciledAt != null &&
            receipt.lastAttemptAt != null &&
            receipt.nextRetryAt == null &&
            receipt.replayed != null;
    final notificationTimeIsRetainedConfirmation =
        notification.updatedAt.isAtSameMomentAs(candidate.confirmedAt!.toUtc());
    final notificationTimeIsEmailAwareAck =
        notification.updatedAt.isAtSameMomentAs(currentUpdatedAt);
    return validReceiptState &&
        notification.sourceType == 'email_confirmation' &&
        notification.anchorAt.isAtSameMomentAs(anchor) &&
        notification.allDay ==
            (entityType == domain.EmailCandidateType.assignment &&
                candidatePayload.due.allDay) &&
        notification.timezone ==
            (candidatePayload.due.timezone ?? domain.japanTimeZone) &&
        notification.remindersMinutesJson ==
            jsonEncode(candidatePayload.suggestedRemindersMinutes) &&
        notification.targetPath == targetPath &&
        notification.state == 'pending' &&
        (notificationTimeIsRetainedConfirmation ||
            notificationTimeIsEmailAwareAck);
  }

  Future<bool> _v15BackfillRetainedScheduleChain({
    required EmailCandidate candidate,
    required EmailScheduleEntityLink link,
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> initialPayload,
    required String initialFingerprint,
    required domain.EmailCandidatePayload originalCandidate,
    required Map<String, Object?> currentPayload,
    required String currentFingerprint,
    required domain.EmailCandidatePayload currentCandidate,
    required domain.EmailCandidatePayloadCodec codec,
  }) async {
    final currentVersion = currentPayload['version'];
    final currentUpdatedAt = currentPayload['updatedAt'];
    if (currentVersion is! int || currentUpdatedAt is! DateTime) return false;
    final retained = (await (select(syncQueueEntries)
              ..where((row) =>
                  row.ownerUserId.equals(candidate.ownerUserId) &
                  row.entityType.equals(candidate.linkedEntityType!) &
                  row.entityId.equals(candidate.linkedEntityId!) &
                  row.operation.isIn(const ['update', 'delete'])))
            .get())
        .where(_v15IsVerifiableNonterminalMutation)
        .where((row) => row.payloadJson != '{}')
        .toList()
      ..sort((left, right) {
        final byBase = (left.baseVersion ?? -1).compareTo(
          right.baseVersion ?? -1,
        );
        if (byBase != 0) return byBase;
        final bySequence = left.enqueueSequence.compareTo(
          right.enqueueSequence,
        );
        if (bySequence != 0) return bySequence;
        return left.createdAt.compareTo(right.createdAt);
      });
    var chainVersion = 1;
    var chainPayload = initialPayload;
    var chainFingerprint = initialFingerprint;
    var chainCandidate = originalCandidate;

    while (chainVersion < currentVersion) {
      final matching = retained
          .where((row) => row.baseVersion == chainVersion)
          .toList(growable: false);
      if (matching.length > 1) return false;
      if (matching.isEmpty) break;
      final mutation = matching.single;
      final postPayload = _v15RetainedMutationPostPayload(
        mutation: mutation,
        entityType: entityType,
        ownerUserId: candidate.ownerUserId,
        entityId: candidate.linkedEntityId!,
        basePayload: chainPayload,
      );
      if (postPayload == null) return false;
      final entityVersion = postPayload['version'];
      final entityUpdatedAt = _v15PayloadDateTime(postPayload['updatedAt']);
      if (entityVersion is! int ||
          entityVersion != chainVersion + 1 ||
          entityUpdatedAt == null ||
          !_v15DateTimeMatches(entityUpdatedAt, mutation.createdAt)) {
        return false;
      }
      final acceptedCandidate = await _v15AcceptedCandidateForMutation(
        candidate: candidate,
        mutation: mutation,
        codec: codec,
      );
      if (acceptedCandidate != null) chainCandidate = acceptedCandidate;
      final postFingerprint = emailSchedulePayloadFingerprint(postPayload);
      await _v15InsertScheduleEditReceipt(
        mutationId: mutation.clientMutationId,
        candidate: candidate,
        link: link,
        provenance: acceptedCandidate == null ? 'user_edit' : 'accepted_update',
        baseEntityVersion: chainVersion,
        entityVersion: entityVersion,
        basePayloadFingerprint: chainFingerprint,
        payloadFingerprint: postFingerprint,
        candidatePayload: chainCandidate,
        entityUpdatedAt: entityUpdatedAt,
      );
      retained.remove(mutation);
      chainVersion = entityVersion;
      chainPayload = postPayload;
      chainFingerprint = postFingerprint;
    }

    if (chainVersion == currentVersion) {
      return retained.isEmpty &&
          chainFingerprint == currentFingerprint &&
          codec.encode(chainCandidate) == codec.encode(currentCandidate);
    }

    if (retained.isEmpty) {
      await _v15InsertScheduleEditReceipt(
        mutationId: 'legacy-trusted-tip:${emailSchedulePayloadFingerprint({
              'ownerUserId': candidate.ownerUserId,
              'candidateId': candidate.id,
              'entityType': candidate.linkedEntityType,
              'entityId': candidate.linkedEntityId,
              'version': currentVersion,
            })}',
        candidate: candidate,
        link: link,
        provenance: 'legacy_trusted_tip',
        baseEntityVersion: chainVersion,
        entityVersion: currentVersion,
        basePayloadFingerprint: chainFingerprint,
        payloadFingerprint: currentFingerprint,
        candidatePayload: currentCandidate,
        entityUpdatedAt: currentUpdatedAt,
      );
      return true;
    }

    if (retained.length != 1) return false;
    final retainedTip = retained.single;
    final tipPayload = _v15RetainedMutationPostPayload(
      mutation: retainedTip,
      entityType: entityType,
      ownerUserId: candidate.ownerUserId,
      entityId: candidate.linkedEntityId!,
      basePayload: currentPayload,
      sparseDeletePayload: currentPayload,
    );
    if (retainedTip.baseVersion == null ||
        retainedTip.baseVersion! < chainVersion ||
        tipPayload == null ||
        emailSchedulePayloadFingerprint(tipPayload) != currentFingerprint ||
        !_v15DateTimeMatches(tipPayload['updatedAt'], currentUpdatedAt)) {
      return false;
    }
    await _v15InsertScheduleEditReceipt(
      mutationId: retainedTip.clientMutationId,
      candidate: candidate,
      link: link,
      provenance: 'legacy_trusted_tip',
      baseEntityVersion: chainVersion,
      entityVersion: currentVersion,
      basePayloadFingerprint: chainFingerprint,
      payloadFingerprint: currentFingerprint,
      candidatePayload: currentCandidate,
      entityUpdatedAt: currentUpdatedAt,
    );
    return true;
  }

  Future<domain.EmailCandidatePayload?> _v15OriginalCandidatePayload(
    EmailCandidate candidate,
    domain.EmailCandidatePayloadCodec codec,
  ) async {
    domain.EmailCandidatePayload current;
    try {
      current = codec.decode(candidate.normalizedPayloadJson);
    } on domain.EmailCandidateValidationException {
      return null;
    }
    final value = codec.toJson(current);
    final updates = await (select(emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(candidate.ownerUserId) &
              row.candidateId.equals(candidate.id) &
              (row.state.equals('accepted') |
                  (row.state.equals('superseded') &
                      row.resolutionIdempotencyKey.isNotNull())))
          ..orderBy([
            (row) => OrderingTerm.desc(row.resolvedAt),
            (row) => OrderingTerm.desc(row.updatedAt),
          ]))
        .get();
    for (final update in updates) {
      if (update.state == 'superseded' &&
          !(update.resolutionIdempotencyKey ?? '')
              .startsWith('email-update-server-wins-reject:')) {
        continue;
      }
      final Object? decodedDiff;
      try {
        decodedDiff = jsonDecode(update.fieldDiffJson);
      } on FormatException {
        return null;
      }
      if (decodedDiff is! Map) return null;
      for (final entry in decodedDiff.entries) {
        final change = entry.value;
        if (change is! Map || !change.containsKey('before')) return null;
        if (!_v15WriteCandidateField(
          value,
          entry.key.toString(),
          change['before'],
        )) {
          return null;
        }
      }
    }
    try {
      return codec.decodeObject(value);
    } on domain.EmailCandidateValidationException {
      return null;
    }
  }

  bool _v15IsVerifiableNonterminalMutation(SyncQueueEntry mutation) {
    const statuses = <String>{'pending', 'processing', 'failed', 'conflict'};
    if (!statuses.contains(mutation.status) ||
        mutation.syncedAt != null ||
        mutation.completionProvenance != null) {
      return false;
    }
    if (mutation.status == 'conflict') {
      return mutation.serverVersion != null &&
          mutation.serverPayloadJson != null &&
          mutation.conflictCursor != null;
    }
    return true;
  }

  Map<String, Object?>? _v15DecodeSchedulePayload(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return decoded.map<String, Object?>(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  Map<String, Object?>? _v15RetainedMutationPostPayload({
    required SyncQueueEntry mutation,
    required domain.EmailCandidateType entityType,
    required String ownerUserId,
    required String entityId,
    required Map<String, Object?> basePayload,
    Map<String, Object?>? sparseDeletePayload,
  }) {
    final decoded = _v15DecodeSchedulePayload(mutation.payloadJson);
    final baseVersion = mutation.baseVersion;
    if (decoded == null ||
        baseVersion == null ||
        decoded['id'] != entityId ||
        decoded['ownerUserId'] != ownerUserId ||
        decoded['version'] != baseVersion + 1 ||
        !_v15DateTimeMatches(decoded['updatedAt'], mutation.createdAt)) {
      return null;
    }
    if (mutation.operation == 'update') {
      if (!_v15ValidRetainedPayloadShape(
            entityType: entityType,
            rawPayload: decoded,
            deleted: false,
          ) ||
          decoded['deletedAt'] != null) {
        return null;
      }
      return emailScheduleReplayPayload(
        entityType: entityType,
        payload: decoded,
      );
    }
    if (mutation.operation != 'delete' ||
        !_v15ValidRetainedPayloadShape(
          entityType: entityType,
          rawPayload: decoded,
          deleted: true,
        )) {
      return null;
    }
    final deletedAt = _v15PayloadDateTime(decoded['deletedAt']);
    if (deletedAt == null) return null;
    final sparseKeys = const <String>{
      'id',
      'ownerUserId',
      'updatedAt',
      'deletedAt',
      'version',
    };
    if (decoded.keys.toSet().difference(sparseKeys).isEmpty) {
      final merged = <String, Object?>{
        ...(sparseDeletePayload ?? basePayload),
      };
      for (final key in sparseKeys) {
        if (decoded.containsKey(key)) merged[key] = decoded[key];
      }
      return emailScheduleReplayPayload(
        entityType: entityType,
        payload: merged,
      );
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: decoded,
    );
  }

  bool _v15ValidRetainedPayloadShape({
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> rawPayload,
    required bool deleted,
  }) {
    const identityKeys = <String>{
      'id',
      'ownerUserId',
      'updatedAt',
      'version',
    };
    final requiredEntityKeys = switch (entityType) {
      domain.EmailCandidateType.assignment => const <String>{
          'courseId',
          'title',
          'dueAt',
          'submissionUrl',
          'memo',
          'priority',
          'visibilityLevel',
        },
      domain.EmailCandidateType.exam => const <String>{
          'courseId',
          'title',
          'startAt',
          'endAt',
          'room',
          'memo',
          'examType',
          'visibilityLevel',
        },
      domain.EmailCandidateType.event => const <String>{
          'calendarId',
          'title',
          'kind',
          'startAt',
          'endAt',
          'location',
          'description',
          'rrule',
          'timezone',
          'visibilityLevel',
        },
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        const <String>{},
    };
    if (requiredEntityKeys.isEmpty) return false;
    final optionalEntityKeys = switch (entityType) {
      domain.EmailCandidateType.exam => const <String>{'scope'},
      domain.EmailCandidateType.event => const <String>{'groupId'},
      _ => const <String>{},
    };
    final keys = rawPayload.keys.toSet();
    final sparseDeleteKeys = <String>{...identityKeys, 'deletedAt'};
    if (deleted &&
        keys.length == sparseDeleteKeys.length &&
        keys.containsAll(sparseDeleteKeys)) {
      return true;
    }
    final required = <String>{
      ...identityKeys,
      ...requiredEntityKeys,
      if (deleted) 'deletedAt',
    };
    final allowed = <String>{
      ...required,
      ...optionalEntityKeys,
      if (!deleted) 'deletedAt',
    };
    return keys.containsAll(required) && keys.difference(allowed).isEmpty;
  }

  DateTime? _v15PayloadDateTime(Object? value) {
    if (value is DateTime) return emailScheduleSqliteTimestamp(value);
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      return parsed == null ? null : emailScheduleSqliteTimestamp(parsed);
    }
    return null;
  }

  Future<void> _v15InsertScheduleEditReceipt({
    required String mutationId,
    required EmailCandidate candidate,
    required EmailScheduleEntityLink link,
    required String provenance,
    required int baseEntityVersion,
    required int entityVersion,
    required String basePayloadFingerprint,
    required String payloadFingerprint,
    required domain.EmailCandidatePayload candidatePayload,
    required DateTime entityUpdatedAt,
  }) {
    return into(emailScheduleEditReceipts).insert(
      EmailScheduleEditReceiptsCompanion.insert(
        mutationId: mutationId,
        ownerUserId: candidate.ownerUserId,
        candidateId: candidate.id,
        linkId: link.id,
        entityType: candidate.linkedEntityType!,
        entityId: candidate.linkedEntityId!,
        provenance: provenance,
        baseEntityVersion: baseEntityVersion,
        entityVersion: entityVersion,
        basePayloadFingerprint: basePayloadFingerprint,
        payloadFingerprint: payloadFingerprint,
        candidatePayloadFingerprint:
            emailCandidatePayloadFingerprint(candidatePayload),
        entityUpdatedAt: emailScheduleSqliteTimestamp(entityUpdatedAt),
        createdAt: emailScheduleSqliteTimestamp(entityUpdatedAt),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<domain.EmailCandidatePayload?> _v15AcceptedCandidateForMutation({
    required EmailCandidate candidate,
    required SyncQueueEntry mutation,
    required domain.EmailCandidatePayloadCodec codec,
  }) async {
    final receipts = await (select(emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(candidate.ownerUserId) &
              row.requiredSyncMutationId.equals(mutation.clientMutationId) &
              row.action.equals('update') &
              row.resolution.equals('accepted') &
              row.state.equals('pending')))
        .get();
    if (receipts.length != 1) return null;
    final receipt = receipts.single;
    final proposal = await (select(emailCandidateUpdates)
          ..where((row) =>
              row.id.equals(receipt.localReferenceId) &
              row.ownerUserId.equals(candidate.ownerUserId) &
              row.candidateId.equals(candidate.id)))
        .getSingleOrNull();
    if (proposal == null ||
        proposal.state != 'accepted' ||
        proposal.errorCategory != null ||
        proposal.resolutionIdempotencyKey != mutation.clientMutationId ||
        proposal.baseEntityVersion != mutation.baseVersion ||
        receipt.idempotencyKey != mutation.clientMutationId ||
        receipt.entityType != candidate.linkedEntityType ||
        receipt.entityId != candidate.linkedEntityId) {
      return null;
    }
    try {
      final proposed = codec.decode(proposal.proposedPayloadJson);
      if (emailCandidateUpdateFingerprint(proposed) !=
          proposal.semanticFingerprint) {
        return null;
      }
      return proposed;
    } on domain.EmailCandidateValidationException {
      return null;
    }
  }

  bool _v15DateTimeMatches(Object? value, DateTime expected) {
    final parsed = value is DateTime
        ? emailScheduleSqliteTimestamp(value)
        : value is String
            ? DateTime.tryParse(value)
            : null;
    return parsed != null &&
        emailScheduleSqliteTimestamp(parsed).isAtSameMomentAs(
          emailScheduleSqliteTimestamp(expected),
        );
  }

  bool _v15ValidInitialPayloadShape({
    required domain.EmailCandidateType entityType,
    required Map<String, Object?> rawPayload,
    required Map<String, Object?> canonicalPayload,
  }) {
    final expectedKeys = switch (entityType) {
      domain.EmailCandidateType.assignment => const <String>{
          'id',
          'ownerUserId',
          'courseId',
          'title',
          'dueAt',
          'submissionUrl',
          'memo',
          'priority',
          'visibilityLevel',
          'updatedAt',
          'version',
        },
      domain.EmailCandidateType.exam => const <String>{
          'id',
          'ownerUserId',
          'courseId',
          'title',
          'startAt',
          'endAt',
          'room',
          'memo',
          'examType',
          'visibilityLevel',
          'updatedAt',
          'version',
        },
      domain.EmailCandidateType.event => const <String>{
          'id',
          'ownerUserId',
          'calendarId',
          'title',
          'kind',
          'startAt',
          'endAt',
          'location',
          'description',
          'rrule',
          'timezone',
          'visibilityLevel',
          'updatedAt',
          'version',
        },
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        const <String>{},
    };
    if (rawPayload.keys.toSet().length != expectedKeys.length ||
        !rawPayload.keys.toSet().containsAll(expectedKeys) ||
        canonicalPayload['deletedAt'] != null) {
      return false;
    }
    return switch (entityType) {
      domain.EmailCandidateType.assignment =>
        canonicalPayload['priority'] == null,
      domain.EmailCandidateType.exam => canonicalPayload['scope'] == null &&
          canonicalPayload['examType'] == null,
      domain.EmailCandidateType.event => canonicalPayload['groupId'] == null &&
          canonicalPayload['kind'] == domain.EventKind.normal.name &&
          canonicalPayload['rrule'] == null &&
          canonicalPayload['timezone'] == domain.japanTimeZone,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        false,
    };
  }

  bool _v15WriteCandidateField(
    Map<String, Object?> payload,
    String field,
    Object? value,
  ) {
    if (field == 'due_at' ||
        field == 'due_all_day' ||
        field == 'due_timezone') {
      final dueValue = payload['due'];
      if (dueValue is! Map) return false;
      final due = dueValue.map<String, Object?>(
        (key, item) => MapEntry(key.toString(), item),
      );
      due[field == 'due_at'
          ? 'at'
          : field == 'due_all_day'
              ? 'all_day'
              : 'timezone'] = value;
      payload['due'] = due;
      return true;
    }
    const fields = <String, String>{
      'title': 'title',
      'start_at': 'start_at',
      'end_at': 'end_at',
      'location': 'location',
      'submission_url': 'submission_url',
      'summary': 'summary',
      'suggested_reminders_minutes': 'suggested_reminders_minutes',
    };
    final key = fields[field];
    if (key == null) return false;
    payload[key] = value;
    return true;
  }

  bool _v15CandidateMatchesEntity(
    domain.EmailCandidatePayload candidate,
    Map<String, Object?> entity,
  ) {
    DateTime? at(Object? value) {
      if (value is DateTime) return emailScheduleSqliteTimestamp(value);
      if (value is String) {
        final parsed = DateTime.tryParse(value);
        return parsed == null ? null : emailScheduleSqliteTimestamp(parsed);
      }
      return null;
    }

    return switch (candidate.candidateType) {
      domain.EmailCandidateType.assignment =>
        entity['title'] == candidate.title &&
            at(entity['dueAt']) ==
                (candidate.due.at == null
                    ? null
                    : emailScheduleSqliteTimestamp(candidate.due.at!)) &&
            entity['submissionUrl'] == candidate.submissionUrl &&
            entity['memo'] == candidate.summary,
      domain.EmailCandidateType.exam => entity['title'] == candidate.title &&
          at(entity['startAt']) ==
              (candidate.startAt == null
                  ? null
                  : emailScheduleSqliteTimestamp(candidate.startAt!)) &&
          at(entity['endAt']) ==
              (candidate.endAt == null
                  ? null
                  : emailScheduleSqliteTimestamp(candidate.endAt!)) &&
          entity['room'] == candidate.location &&
          entity['memo'] == candidate.summary,
      domain.EmailCandidateType.event => entity['title'] == candidate.title &&
          at(entity['startAt']) ==
              (candidate.startAt == null
                  ? null
                  : emailScheduleSqliteTimestamp(candidate.startAt!)) &&
          at(entity['endAt']) ==
              (candidate.endAt == null
                  ? null
                  : emailScheduleSqliteTimestamp(candidate.endAt!)) &&
          entity['location'] == candidate.location &&
          entity['description'] == candidate.summary,
      domain.EmailCandidateType.announcement ||
      domain.EmailCandidateType.unknown =>
        false,
    };
  }

  Future<Map<String, Object?>?> _v15CurrentEntityPayload({
    required String ownerUserId,
    required domain.EmailCandidateType entityType,
    required String entityId,
  }) async {
    final Map<String, Object?> payload;
    switch (entityType) {
      case domain.EmailCandidateType.assignment:
        final row = await (select(assignments)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) return null;
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'courseId': row.courseId,
          'title': row.title,
          'dueAt': row.dueAt,
          'submissionUrl': row.submissionUrl,
          'memo': row.description,
          'priority': row.priority,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.exam:
        final row = await (select(exams)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) return null;
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'courseId': row.courseId,
          'title': row.title,
          'startAt': row.startAt,
          'endAt': row.endAt,
          'room': row.room,
          'scope': row.scope,
          'memo': row.memo,
          'examType': row.examType,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.event:
        final row = await (select(events)
              ..where((item) =>
                  item.id.equals(entityId) &
                  item.ownerUserId.equals(ownerUserId)))
            .getSingleOrNull();
        if (row == null) return null;
        payload = {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'calendarId': row.calendarId,
          'groupId': row.groupId,
          'title': row.title,
          'kind': row.kind,
          'startAt': row.startAt,
          'endAt': row.endAt,
          'location': row.location,
          'description': row.description,
          'rrule': row.rrule,
          'timezone': row.timezone,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'deletedAt': row.deletedAt,
          'version': row.version,
        };
      case domain.EmailCandidateType.announcement:
      case domain.EmailCandidateType.unknown:
        return null;
    }
    return emailScheduleReplayPayload(
      entityType: entityType,
      payload: payload,
    );
  }

  Future<void> _migrateToV14(Migrator m) async {
    await _addSyncQueueCompletionProvenanceColumn(m);
    if (await _tableExists('email_reconciliation_receipts')) {
      // Schema 13 could not distinguish a remote acknowledgement from a
      // server-wins resolution. Unknown legacy completion therefore cannot
      // safely release a still-pending email reconciliation receipt.
      await customStatement('''
        UPDATE email_reconciliation_receipts
        SET schedule_acked_at = NULL
        WHERE state = 'pending'
          AND required_sync_mutation_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM sync_queue_entries mutation
            WHERE mutation.owner_user_id =
                    email_reconciliation_receipts.owner_user_id
              AND mutation.client_mutation_id =
                    email_reconciliation_receipts.required_sync_mutation_id
              AND mutation.completion_provenance =
                    '$scheduleSyncCompletionRemoteApplied'
          )
      ''');
    }
  }

  Future<void> _addSyncQueueCompletionProvenanceColumn(Migrator m) async {
    await _addColumnIfMissing(
      m,
      'sync_queue_entries',
      syncQueueEntries,
      syncQueueEntries.completionProvenance,
    );
  }

  Future<void> _migrateToV13(Migrator m) async {
    await _createTableIfMissing(
      m,
      'email_reconciliation_receipts',
      emailReconciliationReceipts,
    );
    await _backfillEmailReconciliationReceipts();
  }

  Future<void> _backfillEmailReconciliationReceipts() async {
    if (!await _tableExists('email_reconciliation_receipts') ||
        !await _tableExists('email_candidates') ||
        !await _tableExists('email_sources') ||
        !await _tableExists('email_connections')) {
      return;
    }
    final confirmedRows = await (select(emailCandidates).join([
      innerJoin(
          emailSources, emailSources.id.equalsExp(emailCandidates.sourceId)),
      innerJoin(
        emailConnections,
        emailConnections.id.equalsExp(emailSources.connectionId),
      ),
    ])
          ..where(
            emailCandidates.reviewState.equals('confirmed') &
                emailCandidates.confirmationIdempotencyKey.isNotNull() &
                emailCandidates.linkedEntityType
                    .isIn(const ['assignment', 'exam', 'event']) &
                emailCandidates.linkedEntityId.isNotNull(),
          ))
        .get();
    for (final joined in confirmedRows) {
      final candidate = joined.readTable(emailCandidates);
      final source = joined.readTable(emailSources);
      final connection = joined.readTable(emailConnections);
      final mutation = await (select(syncQueueEntries)
            ..where((row) =>
                row.ownerUserId.equals(candidate.ownerUserId) &
                row.idempotencyKey
                    .equals(candidate.confirmationIdempotencyKey!))
            ..limit(1))
          .getSingleOrNull();
      if (mutation == null) continue;
      await into(emailReconciliationReceipts).insert(
        EmailReconciliationReceiptsCompanion.insert(
          id: 'confirmation:${candidate.id}',
          ownerUserId: candidate.ownerUserId,
          connectionId: source.connectionId,
          action: 'confirmation',
          localReferenceId: candidate.id,
          provider: connection.provider,
          providerAccountHash: connection.providerAccountHash,
          providerMessageIdHash: emailProviderIdentifierHash(
            kind: 'message',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerMessageId,
          ),
          providerThreadIdHash: emailProviderIdentifierHash(
            kind: 'thread',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerThreadId,
          ),
          sanitizedContentHash: source.sanitizedContentHash,
          reviewedPayloadJson: Value(candidate.normalizedPayloadJson),
          entityType: Value(candidate.linkedEntityType),
          entityId: Value(candidate.linkedEntityId),
          idempotencyKey: candidate.confirmationIdempotencyKey!,
          requiredSyncMutationId: Value(mutation.clientMutationId),
          scheduleAckedAt: Value(
            mutation.status == 'synced'
                ? mutation.syncedAt ?? mutation.createdAt
                : null,
          ),
          createdAt: Value(candidate.confirmedAt ?? candidate.updatedAt),
          updatedAt: Value(candidate.updatedAt),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
    if (await _tableExists('email_candidate_updates')) {
      final resolvedRows = await (select(emailCandidateUpdates).join([
        innerJoin(
          emailCandidates,
          emailCandidates.id.equalsExp(emailCandidateUpdates.candidateId),
        ),
        innerJoin(
          emailSources,
          emailSources.id.equalsExp(emailCandidateUpdates.sourceId),
        ),
        innerJoin(
          emailConnections,
          emailConnections.id.equalsExp(emailSources.connectionId),
        ),
      ])
            ..where(
              emailCandidateUpdates.state.isIn(const ['accepted', 'rejected']) &
                  emailCandidateUpdates.resolutionIdempotencyKey.isNotNull() &
                  emailCandidates.linkedEntityType
                      .isIn(const ['assignment', 'exam', 'event']) &
                  emailCandidates.linkedEntityId.isNotNull(),
            ))
          .get();
      for (final joined in resolvedRows) {
        final proposal = joined.readTable(emailCandidateUpdates);
        final candidate = joined.readTable(emailCandidates);
        final source = joined.readTable(emailSources);
        final connection = joined.readTable(emailConnections);
        SyncQueueEntry? acceptedMutation;
        if (proposal.state == 'accepted') {
          acceptedMutation = await (select(syncQueueEntries)
                ..where((row) =>
                    row.ownerUserId.equals(proposal.ownerUserId) &
                    row.clientMutationId
                        .equals(proposal.resolutionIdempotencyKey!))
                ..limit(1))
              .getSingleOrNull();
          if (acceptedMutation == null) continue;
        }
        await into(emailReconciliationReceipts).insert(
          EmailReconciliationReceiptsCompanion.insert(
            id: 'update:${proposal.id}',
            ownerUserId: proposal.ownerUserId,
            connectionId: source.connectionId,
            action: 'update',
            localReferenceId: proposal.id,
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            providerMessageIdHash: emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ),
            providerThreadIdHash: emailProviderIdentifierHash(
              kind: 'thread',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerThreadId,
            ),
            sanitizedContentHash: source.sanitizedContentHash,
            resolution: Value(proposal.state),
            entityType: Value(candidate.linkedEntityType),
            entityId: Value(candidate.linkedEntityId),
            idempotencyKey: proposal.resolutionIdempotencyKey!,
            requiredSyncMutationId: Value(
              proposal.state == 'accepted'
                  ? proposal.resolutionIdempotencyKey
                  : null,
            ),
            scheduleAckedAt: Value(
              acceptedMutation?.status == 'synced'
                  ? acceptedMutation?.syncedAt ?? acceptedMutation?.createdAt
                  : null,
            ),
            createdAt: Value(proposal.resolvedAt ?? proposal.updatedAt),
            updatedAt: Value(proposal.updatedAt),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    }
    if (await _tableExists('email_dismissal_tombstones')) {
      final tombstones = await select(emailDismissalTombstones).get();
      for (final tombstone in tombstones) {
        final connection = await (select(emailConnections)
              ..where((row) =>
                  row.ownerUserId.equals(tombstone.ownerUserId) &
                  row.provider.equals(tombstone.provider) &
                  row.providerAccountHash.equals(tombstone.providerAccountHash))
              ..orderBy([
                (row) => OrderingTerm.desc(row.updatedAt),
              ])
              ..limit(1))
            .getSingleOrNull();
        if (connection == null) continue;
        await into(emailReconciliationReceipts).insert(
          EmailReconciliationReceiptsCompanion.insert(
            id: 'dismissal:${tombstone.id}',
            ownerUserId: tombstone.ownerUserId,
            connectionId: connection.id,
            action: 'dismissal',
            localReferenceId: tombstone.id,
            provider: tombstone.provider,
            providerAccountHash: tombstone.providerAccountHash,
            providerMessageIdHash: tombstone.providerMessageIdHash,
            providerThreadIdHash: tombstone.providerThreadIdHash,
            sanitizedContentHash: tombstone.sanitizedContentHash,
            idempotencyKey: 'email-dismissal-${tombstone.id}',
            createdAt: Value(tombstone.dismissedAt),
            updatedAt: Value(tombstone.dismissedAt),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    }
  }

  Future<void> _migrateToV12(Migrator m) async {
    await _createTableIfMissing(
      m,
      'email_dismissal_tombstones',
      emailDismissalTombstones,
    );
    if (await _tableExists('email_candidate_updates')) {
      await _addColumnIfMissing(
        m,
        'email_candidate_updates',
        emailCandidateUpdates,
        emailCandidateUpdates.baseEntityVersion,
      );
      await _backfillEmailUpdateBaseVersions();
      await _normalizeLegacyEmailUpdateProposals();
    }
    await _migrateDismissedCandidatesToTombstones();
  }

  Future<void> _normalizeLegacyEmailUpdateProposals() async {
    await customStatement('''
      DELETE FROM email_candidate_updates
      WHERE rowid NOT IN (
        SELECT MAX(rowid)
        FROM email_candidate_updates
        GROUP BY source_id
      )
    ''');
    await customStatement('''
      DELETE FROM email_candidate_updates
      WHERE rowid NOT IN (
        SELECT MAX(rowid)
        FROM email_candidate_updates
        GROUP BY candidate_id, semantic_fingerprint
      )
    ''');
    await customStatement('''
      UPDATE email_candidate_updates
      SET state = 'superseded',
          resolution_idempotency_key = 'v12-superseded-' || id,
          resolved_at = COALESCE(resolved_at, updated_at)
      WHERE state = 'pending'
        AND rowid NOT IN (
          SELECT MAX(rowid)
          FROM email_candidate_updates
          WHERE state = 'pending'
          GROUP BY candidate_id
        )
    ''');
    await customStatement('''
      UPDATE email_candidate_updates
      SET resolution_idempotency_key = 'v12-resolution-' || id
      WHERE resolution_idempotency_key IS NOT NULL
        AND rowid NOT IN (
          SELECT MIN(rowid)
          FROM email_candidate_updates
          WHERE resolution_idempotency_key IS NOT NULL
          GROUP BY resolution_idempotency_key
        )
    ''');
    await customStatement('''
      UPDATE email_candidate_updates
      SET state = 'failed',
          error_category = 'validation_failed',
          resolution_idempotency_key = NULL,
          resolved_at = COALESCE(resolved_at, updated_at)
      WHERE state = 'pending'
        AND base_entity_version < 1
    ''');
  }

  Future<void> _backfillEmailUpdateBaseVersions() async {
    if (!await _columnExists('assignments', 'version') ||
        !await _columnExists('exams', 'version') ||
        !await _columnExists('events', 'version')) {
      return;
    }
    await customStatement('''
      UPDATE email_candidate_updates AS proposal
      SET base_entity_version = COALESCE((
        SELECT CASE candidate.linked_entity_type
          WHEN 'assignment' THEN (
            SELECT assignment.version
            FROM assignments assignment
            WHERE assignment.id = candidate.linked_entity_id
              AND assignment.owner_user_id = proposal.owner_user_id
          )
          WHEN 'exam' THEN (
            SELECT exam.version
            FROM exams exam
            WHERE exam.id = candidate.linked_entity_id
              AND exam.owner_user_id = proposal.owner_user_id
          )
          WHEN 'event' THEN (
            SELECT event.version
            FROM events event
            WHERE event.id = candidate.linked_entity_id
              AND event.owner_user_id = proposal.owner_user_id
          )
        END
        FROM email_candidates candidate
        WHERE candidate.id = proposal.candidate_id
          AND candidate.owner_user_id = proposal.owner_user_id
      ), 0)
      WHERE proposal.base_entity_version = 0
    ''');
  }

  Future<void> _migrateDismissedCandidatesToTombstones() async {
    if (!await _tableExists('email_dismissal_tombstones') ||
        !await _tableExists('email_candidates') ||
        !await _tableExists('email_sources') ||
        !await _tableExists('email_connections')) {
      return;
    }
    final dismissed = await customSelect('''
      SELECT
        candidate.id AS candidate_id,
        source.id AS source_id,
        candidate.owner_user_id AS owner_user_id,
        candidate.semantic_fingerprint AS semantic_fingerprint,
        COALESCE(candidate.dismissed_at, candidate.updated_at) AS dismissed_at,
        source.provider_message_id AS provider_message_id,
        source.provider_thread_id AS provider_thread_id,
        source.sanitized_content_hash AS sanitized_content_hash,
        connection.provider AS provider,
        connection.provider_account_hash AS provider_account_hash
      FROM email_candidates candidate
      JOIN email_sources source ON source.id = candidate.source_id
      JOIN email_connections connection ON connection.id = source.connection_id
      WHERE candidate.review_state = 'dismissed'
        AND candidate.owner_user_id = source.owner_user_id
        AND candidate.owner_user_id = connection.owner_user_id
    ''').get();
    for (final row in dismissed) {
      final candidateId = row.read<String>('candidate_id');
      await into(emailDismissalTombstones).insert(
        EmailDismissalTombstonesCompanion.insert(
          id: candidateId,
          ownerUserId: row.read<String>('owner_user_id'),
          provider: row.read<String>('provider'),
          providerAccountHash: row.read<String>('provider_account_hash'),
          providerMessageIdHash: _emailIdentifierHash(
            kind: 'message',
            provider: row.read<String>('provider'),
            providerAccountHash: row.read<String>('provider_account_hash'),
            value: row.read<String>('provider_message_id'),
          ),
          providerThreadIdHash: _emailIdentifierHash(
            kind: 'thread',
            provider: row.read<String>('provider'),
            providerAccountHash: row.read<String>('provider_account_hash'),
            value: row.read<String>('provider_thread_id'),
          ),
          sanitizedContentHash: row.read<String>('sanitized_content_hash'),
          semanticFingerprint: row.read<String>('semantic_fingerprint'),
          dismissedAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('dismissed_at') * 1000,
            isUtc: true,
          ),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
    for (final row in dismissed) {
      final candidateId = row.read<String>('candidate_id');
      final sourceId = row.read<String>('source_id');
      // Drift migrations run with foreign-key enforcement temporarily
      // disabled. Delete every derived row explicitly so the v11 payload and
      // excerpts cannot survive as orphaned data.
      await customStatement(
        'DELETE FROM email_candidate_updates WHERE candidate_id = ?',
        [candidateId],
      );
      await customStatement(
        'DELETE FROM email_schedule_entity_links WHERE candidate_id = ?',
        [candidateId],
      );
      await customStatement(
        'DELETE FROM notification_schedule_requests WHERE source_id = ?',
        [candidateId],
      );
      await customStatement(
        'DELETE FROM email_candidates WHERE id = ?',
        [candidateId],
      );
      await customStatement(
        'DELETE FROM email_sources WHERE id = ?',
        [sourceId],
      );
    }
  }

  String _emailIdentifierHash({
    required String kind,
    required String provider,
    required String providerAccountHash,
    required String value,
  }) {
    return emailProviderIdentifierHash(
      kind: kind,
      provider: provider,
      providerAccountHash: providerAccountHash,
      rawIdentifier: value,
    );
  }

  Future<void> _migrateToV11(Migrator m) async {
    await _createTableIfMissing(
      m,
      'email_schedule_entity_links',
      emailScheduleEntityLinks,
    );
    await _createTableIfMissing(
      m,
      'notification_schedule_requests',
      notificationScheduleRequests,
    );
  }

  Future<void> _migrateToV10(Migrator m) async {
    await _createTableIfMissing(m, 'email_connections', emailConnections);
    await _createTableIfMissing(m, 'email_sources', emailSources);
    await _createTableIfMissing(m, 'email_candidates', emailCandidates);
    await _createTableIfMissing(
      m,
      'email_candidate_updates',
      emailCandidateUpdates,
    );
  }

  Future<void> _ensureEmailImportInfrastructure() async {
    if (!await _tableExists('email_connections') ||
        !await _tableExists('email_sources') ||
        !await _tableExists('email_candidates') ||
        !await _tableExists('email_candidate_updates')) {
      return;
    }
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_connections_owner_account_idx
      ON email_connections(owner_user_id, provider, provider_account_hash)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_sources_connection_message_idx
      ON email_sources(connection_id, provider_message_id)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_sources_owner_thread_idx
      ON email_sources(owner_user_id, connection_id, provider_thread_id, received_at)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidates_source_idx
      ON email_candidates(source_id)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_candidates_owner_state_idx
      ON email_candidates(owner_user_id, review_state, updated_at)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidates_confirmation_key_idx
      ON email_candidates(confirmation_idempotency_key)
      WHERE confirmation_idempotency_key IS NOT NULL
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_candidate_updates_owner_state_idx
      ON email_candidate_updates(owner_user_id, state, created_at)
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_connections_values_guard_insert
      BEFORE INSERT ON email_connections
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.provider <> 'gmail'
        OR NEW.state NOT IN (
          'disconnected', 'connecting', 'connected', 'reauth_required',
          'rate_limited', 'failed', 'disconnecting'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR NOT json_valid(NEW.scopes_json)
        OR json_type(NEW.scopes_json) <> 'array'
        OR length(NEW.scopes_json) > 4096
        OR (NEW.cursor IS NOT NULL AND length(NEW.cursor) > 4096)
        OR (NEW.account_hint IS NOT NULL AND length(NEW.account_hint) > 160)
      BEGIN
        SELECT RAISE(ABORT, 'invalid email connection metadata');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_connections_values_guard_update
      BEFORE UPDATE ON email_connections
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR trim(NEW.owner_user_id) = ''
        OR NEW.provider <> 'gmail'
        OR NEW.state NOT IN (
          'disconnected', 'connecting', 'connected', 'reauth_required',
          'rate_limited', 'failed', 'disconnecting'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR NOT json_valid(NEW.scopes_json)
        OR json_type(NEW.scopes_json) <> 'array'
        OR length(NEW.scopes_json) > 4096
        OR (NEW.cursor IS NOT NULL AND length(NEW.cursor) > 4096)
        OR (NEW.account_hint IS NOT NULL AND length(NEW.account_hint) > 160)
      BEGIN
        SELECT RAISE(ABORT, 'invalid email connection metadata');
      END
    ''');
    // These guards predate schema-version bumps on retained installs. Replace
    // them on every open so newly tightened failure invariants are applied to
    // an existing database instead of being skipped by IF NOT EXISTS.
    await customStatement(
      'DROP TRIGGER IF EXISTS email_sources_owner_guard_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS email_sources_owner_guard_update',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS email_candidates_owner_guard_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS email_candidates_owner_guard_update',
    );
    await customStatement('''
      CREATE TRIGGER email_sources_owner_guard_insert
      BEFORE INSERT ON email_sources
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR trim(NEW.provider_message_id) = ''
        OR length(NEW.provider_message_id) > 1024
        OR trim(NEW.provider_thread_id) = ''
        OR length(NEW.provider_thread_id) > 1024
        OR trim(NEW.sanitized_content_hash) = ''
        OR NEW.processing_state NOT IN (
          'pending', 'processing', 'processed', 'ignored', 'failed'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.processing_state = 'failed'
          AND NEW.error_category IS NULL
        )
        OR (
          NEW.processing_state <> 'failed'
          AND NEW.error_category IS NOT NULL
        )
        OR NOT json_valid(NEW.evidence_excerpts_json)
        OR json_type(NEW.evidence_excerpts_json) <> 'array'
        OR length(NEW.evidence_excerpts_json) > 8192
        OR (
          NEW.processing_state = 'failed'
          AND json_array_length(NEW.evidence_excerpts_json) <> 0
        )
        OR NOT EXISTS (
        SELECT 1 FROM email_connections c
        WHERE c.id = NEW.connection_id
          AND c.owner_user_id = NEW.owner_user_id
      )
        OR EXISTS (
          SELECT 1 FROM email_candidates candidate
          WHERE candidate.source_id = NEW.id
            AND (
              (candidate.review_state = 'failed') <>
                (NEW.processing_state = 'failed')
              OR candidate.error_category IS NOT NEW.error_category
            )
        )
      BEGIN
        SELECT RAISE(ABORT, 'email source owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER email_sources_owner_guard_update
      BEFORE UPDATE ON email_sources
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.connection_id <> OLD.connection_id
        OR trim(NEW.owner_user_id) = ''
        OR trim(NEW.provider_message_id) = ''
        OR length(NEW.provider_message_id) > 1024
        OR trim(NEW.provider_thread_id) = ''
        OR length(NEW.provider_thread_id) > 1024
        OR trim(NEW.sanitized_content_hash) = ''
        OR NEW.processing_state NOT IN (
          'pending', 'processing', 'processed', 'ignored', 'failed'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.processing_state = 'failed'
          AND NEW.error_category IS NULL
        )
        OR (
          NEW.processing_state <> 'failed'
          AND NEW.error_category IS NOT NULL
        )
        OR NOT json_valid(NEW.evidence_excerpts_json)
        OR json_type(NEW.evidence_excerpts_json) <> 'array'
        OR length(NEW.evidence_excerpts_json) > 8192
        OR (
          NEW.processing_state = 'failed'
          AND json_array_length(NEW.evidence_excerpts_json) <> 0
        )
        OR NOT EXISTS (
        SELECT 1 FROM email_connections c
        WHERE c.id = NEW.connection_id
          AND c.owner_user_id = NEW.owner_user_id
      )
        OR EXISTS (
          SELECT 1 FROM email_candidates candidate
          WHERE candidate.source_id = NEW.id
            AND (
              (candidate.review_state = 'failed') <>
                (NEW.processing_state = 'failed')
              OR candidate.error_category IS NOT NEW.error_category
            )
        )
      BEGIN
        SELECT RAISE(ABORT, 'email source owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER email_candidates_owner_guard_insert
      BEFORE INSERT ON email_candidates
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.schema_version <> '1.0'
        OR NEW.candidate_type NOT IN (
          'assignment', 'exam', 'event', 'announcement', 'unknown'
        )
        OR NEW.review_state NOT IN (
          'needs_review', 'ready_for_review', 'update_available',
          'confirmed', 'dismissed', 'failed'
        )
        OR (
          NEW.linked_entity_type IS NOT NULL
          AND NEW.linked_entity_type NOT IN ('assignment', 'exam', 'event')
        )
        OR ((NEW.linked_entity_type IS NULL) <> (NEW.linked_entity_id IS NULL))
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.review_state = 'failed'
          AND NEW.error_category IS NULL
        )
        OR (
          NEW.review_state <> 'failed'
          AND NEW.error_category IS NOT NULL
        )
        OR NOT json_valid(NEW.normalized_payload_json)
        OR json_type(NEW.normalized_payload_json) <> 'object'
        OR length(NEW.normalized_payload_json) > 65536
        OR (
          NEW.review_state = 'failed'
          AND (SELECT count(*) FROM json_each(NEW.normalized_payload_json)) <> 0
        )
        OR (
          NEW.review_state <> 'failed'
          AND (SELECT count(*) FROM json_each(NEW.normalized_payload_json)) = 0
        )
        OR NEW.requires_user_confirmation <> 1
        OR NOT EXISTS (
        SELECT 1 FROM email_sources s
        WHERE s.id = NEW.source_id
          AND s.owner_user_id = NEW.owner_user_id
          AND (s.processing_state = 'failed') =
            (NEW.review_state = 'failed')
          AND s.error_category IS NEW.error_category
      )
      BEGIN
        SELECT RAISE(ABORT, 'email candidate owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER email_candidates_owner_guard_update
      BEFORE UPDATE ON email_candidates
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.source_id <> OLD.source_id
        OR trim(NEW.owner_user_id) = ''
        OR NEW.schema_version <> '1.0'
        OR NEW.candidate_type NOT IN (
          'assignment', 'exam', 'event', 'announcement', 'unknown'
        )
        OR NEW.review_state NOT IN (
          'needs_review', 'ready_for_review', 'update_available',
          'confirmed', 'dismissed', 'failed'
        )
        OR (
          NEW.linked_entity_type IS NOT NULL
          AND NEW.linked_entity_type NOT IN ('assignment', 'exam', 'event')
        )
        OR ((NEW.linked_entity_type IS NULL) <> (NEW.linked_entity_id IS NULL))
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.review_state = 'failed'
          AND NEW.error_category IS NULL
        )
        OR (
          NEW.review_state <> 'failed'
          AND NEW.error_category IS NOT NULL
        )
        OR NOT json_valid(NEW.normalized_payload_json)
        OR json_type(NEW.normalized_payload_json) <> 'object'
        OR length(NEW.normalized_payload_json) > 65536
        OR (
          NEW.review_state = 'failed'
          AND (SELECT count(*) FROM json_each(NEW.normalized_payload_json)) <> 0
        )
        OR (
          NEW.review_state <> 'failed'
          AND (SELECT count(*) FROM json_each(NEW.normalized_payload_json)) = 0
        )
        OR NEW.requires_user_confirmation <> 1
        OR NOT EXISTS (
        SELECT 1 FROM email_sources s
        WHERE s.id = NEW.source_id
          AND s.owner_user_id = NEW.owner_user_id
          AND (s.processing_state = 'failed') =
            (NEW.review_state = 'failed')
          AND s.error_category IS NEW.error_category
      )
      BEGIN
        SELECT RAISE(ABORT, 'email candidate owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_confirmation_guard_insert
      BEFORE INSERT ON email_candidates
      FOR EACH ROW
      WHEN NEW.requires_user_confirmation <> 1
      BEGIN
        SELECT RAISE(ABORT, 'email candidate confirmation is required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_confirmation_guard_update
      BEFORE UPDATE OF requires_user_confirmation ON email_candidates
      FOR EACH ROW
      WHEN NEW.requires_user_confirmation <> 1
      BEGIN
        SELECT RAISE(ABORT, 'email candidate confirmation is required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidate_updates_owner_guard_insert
      BEFORE INSERT ON email_candidate_updates
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.state NOT IN (
          'pending', 'accepted', 'rejected', 'superseded', 'failed'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR NOT json_valid(NEW.field_diff_json)
        OR json_type(NEW.field_diff_json) <> 'object'
        OR length(NEW.field_diff_json) > 32768
        OR NOT json_valid(NEW.proposed_payload_json)
        OR json_type(NEW.proposed_payload_json) <> 'object'
        OR length(NEW.proposed_payload_json) > 65536
        OR NOT EXISTS (
        SELECT 1
        FROM email_candidates c
        JOIN email_sources original ON original.id = c.source_id
        JOIN email_sources proposed ON proposed.id = NEW.source_id
        WHERE c.id = NEW.candidate_id
          AND c.owner_user_id = NEW.owner_user_id
          AND original.owner_user_id = NEW.owner_user_id
          AND proposed.owner_user_id = NEW.owner_user_id
          AND proposed.connection_id = original.connection_id
          AND proposed.provider_thread_id = original.provider_thread_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'email candidate update owner mismatch');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidate_updates_owner_guard_update
      BEFORE UPDATE ON email_candidate_updates
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.candidate_id <> OLD.candidate_id
        OR NEW.source_id <> OLD.source_id
        OR trim(NEW.owner_user_id) = ''
        OR NEW.state NOT IN (
          'pending', 'accepted', 'rejected', 'superseded', 'failed'
        )
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR NOT json_valid(NEW.field_diff_json)
        OR json_type(NEW.field_diff_json) <> 'object'
        OR length(NEW.field_diff_json) > 32768
        OR NOT json_valid(NEW.proposed_payload_json)
        OR json_type(NEW.proposed_payload_json) <> 'object'
        OR length(NEW.proposed_payload_json) > 65536
        OR NOT EXISTS (
        SELECT 1
        FROM email_candidates c
        JOIN email_sources original ON original.id = c.source_id
        JOIN email_sources proposed ON proposed.id = NEW.source_id
        WHERE c.id = NEW.candidate_id
          AND c.owner_user_id = NEW.owner_user_id
          AND original.owner_user_id = NEW.owner_user_id
          AND proposed.owner_user_id = NEW.owner_user_id
          AND proposed.connection_id = original.connection_id
          AND proposed.provider_thread_id = original.provider_thread_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'email candidate update owner mismatch');
      END
    ''');
  }

  Future<void> _ensureEmailConfirmationInfrastructure() async {
    if (!await _tableExists('email_schedule_entity_links') ||
        !await _tableExists('notification_schedule_requests') ||
        !await _tableExists('email_candidates') ||
        !await _tableExists('email_sources')) {
      return;
    }
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_schedule_links_owner_entity_idx
      ON email_schedule_entity_links(owner_user_id, entity_type, entity_id)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS notification_requests_owner_state_idx
      ON notification_schedule_requests(owner_user_id, state, anchor_at)
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_confirmed_state_guard_insert
      BEFORE INSERT ON email_candidates
      FOR EACH ROW
      WHEN (
          NEW.review_state = 'confirmed'
          AND (
            NEW.candidate_type NOT IN ('assignment', 'exam', 'event')
            OR NEW.linked_entity_type IS NULL
            OR NEW.linked_entity_id IS NULL
            OR NEW.linked_entity_type <> NEW.candidate_type
            OR trim(NEW.linked_entity_id) = ''
            OR NEW.confirmation_idempotency_key IS NULL
            OR trim(NEW.confirmation_idempotency_key) = ''
            OR length(NEW.confirmation_idempotency_key) > 200
            OR NEW.confirmed_at IS NULL
            OR NEW.dismissed_at IS NOT NULL
          )
        )
        OR (
          NEW.review_state <> 'confirmed'
          AND (
            NEW.linked_entity_type IS NOT NULL
            OR NEW.linked_entity_id IS NOT NULL
            OR NEW.confirmation_idempotency_key IS NOT NULL
            OR NEW.confirmed_at IS NOT NULL
          )
        )
        OR (NEW.review_state = 'dismissed' AND NEW.dismissed_at IS NULL)
        OR (NEW.review_state <> 'dismissed' AND NEW.dismissed_at IS NOT NULL)
      BEGIN
        SELECT RAISE(ABORT, 'invalid confirmed email candidate state');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_confirmed_state_guard_update
      BEFORE UPDATE ON email_candidates
      FOR EACH ROW
      WHEN (
          NEW.review_state = 'confirmed'
          AND (
            NEW.candidate_type NOT IN ('assignment', 'exam', 'event')
            OR NEW.linked_entity_type IS NULL
            OR NEW.linked_entity_id IS NULL
            OR NEW.linked_entity_type <> NEW.candidate_type
            OR trim(NEW.linked_entity_id) = ''
            OR NEW.confirmation_idempotency_key IS NULL
            OR trim(NEW.confirmation_idempotency_key) = ''
            OR length(NEW.confirmation_idempotency_key) > 200
            OR NEW.confirmed_at IS NULL
            OR NEW.dismissed_at IS NOT NULL
          )
        )
        OR (
          NEW.review_state <> 'confirmed'
          AND (
            NEW.linked_entity_type IS NOT NULL
            OR NEW.linked_entity_id IS NOT NULL
            OR NEW.confirmation_idempotency_key IS NOT NULL
            OR NEW.confirmed_at IS NOT NULL
          )
        )
        OR (NEW.review_state = 'dismissed' AND NEW.dismissed_at IS NULL)
        OR (NEW.review_state <> 'dismissed' AND NEW.dismissed_at IS NOT NULL)
      BEGIN
        SELECT RAISE(ABORT, 'invalid confirmed email candidate state');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_schedule_links_guard_insert
      BEFORE INSERT ON email_schedule_entity_links
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR trim(NEW.source_id) = ''
        OR trim(NEW.candidate_id) = ''
        OR NEW.entity_type NOT IN ('assignment', 'exam', 'event')
        OR trim(NEW.entity_id) = ''
        OR trim(NEW.confirmation_idempotency_key) = ''
        OR NOT EXISTS (
          SELECT 1
          FROM email_candidates c
          JOIN email_sources s ON s.id = c.source_id
          WHERE c.id = NEW.candidate_id
            AND c.owner_user_id = NEW.owner_user_id
            AND c.source_id = NEW.source_id
            AND c.review_state = 'confirmed'
            AND c.linked_entity_type = NEW.entity_type
            AND c.linked_entity_id = NEW.entity_id
            AND c.confirmation_idempotency_key =
              NEW.confirmation_idempotency_key
            AND s.id = NEW.source_id
            AND s.owner_user_id = NEW.owner_user_id
        )
        OR (
          NEW.entity_type = 'assignment'
          AND NOT EXISTS (
            SELECT 1 FROM assignments a
            WHERE a.id = NEW.entity_id
              AND a.owner_user_id = NEW.owner_user_id
          )
        )
        OR (
          NEW.entity_type = 'exam'
          AND NOT EXISTS (
            SELECT 1 FROM exams e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
          )
        )
        OR (
          NEW.entity_type = 'event'
          AND NOT EXISTS (
            SELECT 1 FROM events e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email schedule entity link');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_schedule_links_immutable
      BEFORE UPDATE ON email_schedule_entity_links
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'email schedule entity links are immutable');
      END
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS notification_requests_guard_insert',
    );
    await customStatement('''
      CREATE TRIGGER notification_requests_guard_insert
      BEFORE INSERT ON notification_schedule_requests
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.entity_type NOT IN ('assignment', 'exam', 'event')
        OR trim(NEW.entity_id) = ''
        OR NEW.source_type NOT IN (
          'email_confirmation', 'document_confirmation'
        )
        OR trim(NEW.source_id) = ''
        OR trim(NEW.idempotency_key) = ''
        OR NEW.all_day NOT IN (0, 1)
        OR trim(NEW.timezone) = ''
        OR length(NEW.timezone) > 64
        OR NEW.target_path <> CASE NEW.entity_type
          WHEN 'assignment' THEN '/assignment/' || NEW.entity_id || '/edit'
          WHEN 'exam' THEN '/exam/' || NEW.entity_id || '/edit'
          WHEN 'event' THEN '/event/' || NEW.entity_id || '/edit'
        END
        OR NEW.state NOT IN ('pending', 'scheduled', 'cancelled', 'failed')
        OR NOT json_valid(NEW.reminders_minutes_json)
        OR json_type(NEW.reminders_minutes_json) <> 'array'
        OR length(NEW.reminders_minutes_json) > 512
        OR json_array_length(NEW.reminders_minutes_json) > 8
        OR EXISTS (
          SELECT 1
          FROM json_each(NEW.reminders_minutes_json) item
          WHERE item.type <> 'integer'
            OR item.value < 0
            OR item.value > 40320
        )
        OR (
          SELECT count(*) FROM json_each(NEW.reminders_minutes_json)
        ) <> (
          SELECT count(DISTINCT item.value)
          FROM json_each(NEW.reminders_minutes_json) item
        )
        OR (
          NEW.source_type = 'email_confirmation'
          AND NOT EXISTS (
            SELECT 1
            FROM email_candidates c
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
              AND c.review_state = 'confirmed'
              AND c.linked_entity_type = NEW.entity_type
              AND c.linked_entity_id = NEW.entity_id
              AND c.confirmation_idempotency_key = NEW.idempotency_key
          )
        )
        OR (
          NEW.source_type = 'document_confirmation'
          AND NOT EXISTS (
            SELECT 1
            FROM document_candidates_cache c
            JOIN document_schedule_entity_links link
              ON link.candidate_cache_id = c.id
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
              AND c.review_state = 'confirmed'
              AND c.linked_entity_type = NEW.entity_type
              AND c.linked_entity_id = NEW.entity_id
              AND link.owner_user_id = NEW.owner_user_id
              AND link.entity_type = NEW.entity_type
              AND link.entity_id = NEW.entity_id
              AND link.confirmation_idempotency_key = NEW.idempotency_key
          )
        )
        OR (
          NEW.entity_type = 'assignment'
          AND NOT EXISTS (
            SELECT 1 FROM assignments a
            WHERE a.id = NEW.entity_id
              AND a.owner_user_id = NEW.owner_user_id
          )
        )
        OR (
          NEW.entity_type = 'exam'
          AND NOT EXISTS (
            SELECT 1 FROM exams e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
          )
        )
        OR (
          NEW.entity_type = 'event'
          AND NOT EXISTS (
            SELECT 1 FROM events e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid notification schedule request');
      END
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS notification_requests_guard_update',
    );
    await customStatement('''
      CREATE TRIGGER notification_requests_guard_update
      BEFORE UPDATE ON notification_schedule_requests
      FOR EACH ROW
      WHEN NEW.id <> OLD.id
        OR NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.entity_type <> OLD.entity_type
        OR NEW.entity_id <> OLD.entity_id
        OR NEW.source_type <> OLD.source_type
        OR NEW.source_id <> OLD.source_id
        OR NEW.idempotency_key <> OLD.idempotency_key
        OR NEW.target_path <> OLD.target_path
        OR NEW.created_at <> OLD.created_at
        OR NEW.all_day NOT IN (0, 1)
        OR trim(NEW.timezone) = ''
        OR length(NEW.timezone) > 64
        OR NEW.state NOT IN ('pending', 'scheduled', 'cancelled', 'failed')
        OR NOT json_valid(NEW.reminders_minutes_json)
        OR json_type(NEW.reminders_minutes_json) <> 'array'
        OR length(NEW.reminders_minutes_json) > 512
        OR json_array_length(NEW.reminders_minutes_json) > 8
        OR EXISTS (
          SELECT 1
          FROM json_each(NEW.reminders_minutes_json) item
          WHERE item.type <> 'integer'
            OR item.value < 0
            OR item.value > 40320
        )
        OR (
          SELECT count(*) FROM json_each(NEW.reminders_minutes_json)
        ) <> (
          SELECT count(DISTINCT item.value)
          FROM json_each(NEW.reminders_minutes_json) item
        )
        OR (
          NEW.source_type = 'email_confirmation'
          AND EXISTS (
            SELECT 1
            FROM email_candidates c
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM email_candidates c
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
              AND c.review_state = 'confirmed'
              AND c.linked_entity_type = NEW.entity_type
              AND c.linked_entity_id = NEW.entity_id
              AND c.confirmation_idempotency_key = NEW.idempotency_key
          )
        )
        OR (
          NEW.source_type = 'document_confirmation'
          AND EXISTS (
            SELECT 1
            FROM document_candidates_cache c
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM document_candidates_cache c
            JOIN document_schedule_entity_links link
              ON link.candidate_cache_id = c.id
            WHERE c.id = NEW.source_id
              AND c.owner_user_id = NEW.owner_user_id
              AND c.review_state = 'confirmed'
              AND c.linked_entity_type = NEW.entity_type
              AND c.linked_entity_id = NEW.entity_id
              AND link.owner_user_id = NEW.owner_user_id
              AND link.entity_type = NEW.entity_type
              AND link.entity_id = NEW.entity_id
              AND link.confirmation_idempotency_key = NEW.idempotency_key
          )
          AND NOT EXISTS (
            SELECT 1
            FROM sync_queue_entries mutation
            WHERE mutation.owner_user_id = NEW.owner_user_id
              AND mutation.idempotency_key = NEW.idempotency_key
              AND mutation.entity_type = NEW.entity_type
              AND mutation.entity_id = NEW.entity_id
              AND mutation.operation = 'create'
          )
        )
        OR (
          NEW.entity_type = 'assignment'
          AND NOT EXISTS (
            SELECT 1 FROM assignments a
            WHERE a.id = NEW.entity_id
              AND a.owner_user_id = NEW.owner_user_id
              AND (NEW.state = 'cancelled' OR a.deleted_at IS NULL)
          )
        )
        OR (
          NEW.entity_type = 'exam'
          AND NOT EXISTS (
            SELECT 1 FROM exams e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
              AND (NEW.state = 'cancelled' OR e.deleted_at IS NULL)
          )
        )
        OR (
          NEW.entity_type = 'event'
          AND NOT EXISTS (
            SELECT 1 FROM events e
            WHERE e.id = NEW.entity_id
              AND e.owner_user_id = NEW.owner_user_id
              AND (NEW.state = 'cancelled' OR e.deleted_at IS NULL)
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid notification schedule request update');
      END
    ''');
  }

  Future<void> _ensureEmailDedupeInfrastructure() async {
    if (!await _tableExists('email_dismissal_tombstones') ||
        !await _columnExists(
          'email_candidate_updates',
          'base_entity_version',
        )) {
      return;
    }
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_sources_owner_thread_content_idx
      ON email_sources(
        owner_user_id,
        connection_id,
        provider_thread_id,
        sanitized_content_hash
      )
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_candidates_owner_fingerprint_idx
      ON email_candidates(owner_user_id, semantic_fingerprint)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidate_updates_source_idx
      ON email_candidate_updates(source_id)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidate_updates_semantic_idx
      ON email_candidate_updates(candidate_id, semantic_fingerprint)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidate_updates_pending_idx
      ON email_candidate_updates(candidate_id)
      WHERE state = 'pending'
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS email_candidate_updates_resolution_idx
      ON email_candidate_updates(resolution_idempotency_key)
      WHERE resolution_idempotency_key IS NOT NULL
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_dismissals_owner_message_idx
      ON email_dismissal_tombstones(
        owner_user_id,
        provider,
        provider_account_hash,
        provider_message_id_hash
      )
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_dismissals_owner_thread_idx
      ON email_dismissal_tombstones(
        owner_user_id,
        provider,
        provider_account_hash,
        provider_thread_id_hash,
        semantic_fingerprint
      )
    ''');
    // Reinstall this schema-v14-compatible guard so a content-free failed
    // source may be upgraded in place after an explicit targeted retry. The
    // owner/connection/message identity remains immutable; only metadata that
    // could not be validated during the failed attempt may be replaced.
    await customStatement(
      'DROP TRIGGER IF EXISTS email_sources_v12_identity_immutable',
    );
    await customStatement('''
      CREATE TRIGGER email_sources_v12_identity_immutable
      BEFORE UPDATE ON email_sources
      FOR EACH ROW
      WHEN NEW.connection_id <> OLD.connection_id
        OR NEW.provider_message_id <> OLD.provider_message_id
        OR (
          (
            OLD.processing_state <> 'failed'
            OR NEW.processing_state NOT IN ('failed', 'processed', 'ignored')
          )
          AND (
            NEW.provider_thread_id <> OLD.provider_thread_id
            OR NEW.received_at <> OLD.received_at
            OR NEW.sanitized_content_hash <> OLD.sanitized_content_hash
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'email source identity is immutable');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_dismissals_guard_insert
      BEFORE INSERT ON email_dismissal_tombstones
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.provider <> 'gmail'
        OR length(NEW.provider_account_hash) <> 64
        OR NEW.provider_account_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.provider_message_id_hash) <> 64
        OR NEW.provider_message_id_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.provider_thread_id_hash) <> 64
        OR NEW.provider_thread_id_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.sanitized_content_hash) <> 64
        OR NEW.sanitized_content_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.semantic_fingerprint) <> 64
        OR NEW.semantic_fingerprint GLOB '*[^0-9a-f]*'
      BEGIN
        SELECT RAISE(ABORT, 'invalid email dismissal tombstone');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_dismissals_immutable
      BEFORE UPDATE ON email_dismissal_tombstones
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'email dismissal tombstones are immutable');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_v12_source_exclusive_insert
      BEFORE INSERT ON email_candidates
      FOR EACH ROW
      WHEN EXISTS (
        SELECT 1 FROM email_candidate_updates proposal
        WHERE proposal.source_id = NEW.source_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'email source already owns an update proposal');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidates_v12_source_exclusive_update
      BEFORE UPDATE ON email_candidates
      FOR EACH ROW
      WHEN EXISTS (
        SELECT 1 FROM email_candidate_updates proposal
        WHERE proposal.source_id = NEW.source_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'email source already owns an update proposal');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_candidate_updates_v12_guard_insert
      BEFORE INSERT ON email_candidate_updates
      FOR EACH ROW
      WHEN length(NEW.semantic_fingerprint) <> 64
        OR NEW.semantic_fingerprint GLOB '*[^0-9a-f]*'
        OR NEW.base_entity_version < 1
        OR NEW.state <> 'pending'
        OR NEW.error_category IS NOT NULL
        OR NEW.resolution_idempotency_key IS NOT NULL
        OR NEW.resolved_at IS NOT NULL
        OR NOT json_valid(NEW.field_diff_json)
        OR json_type(NEW.field_diff_json) <> 'object'
        OR (SELECT count(*) FROM json_each(NEW.field_diff_json)) = 0
        OR EXISTS (
          SELECT 1 FROM json_each(NEW.field_diff_json) field
          WHERE field.key NOT IN (
            'title', 'due_at', 'start_at', 'end_at',
            'location', 'submission_url', 'summary',
            'due_all_day', 'due_timezone',
            'suggested_reminders_minutes'
          )
        )
        OR NOT json_valid(NEW.proposed_payload_json)
        OR json_type(NEW.proposed_payload_json) <> 'object'
        OR json_extract(NEW.proposed_payload_json, '\$.schema_version') <> '1.0'
        OR EXISTS (
          SELECT 1 FROM email_candidates proposed_candidate
          WHERE proposed_candidate.source_id = NEW.source_id
        )
        OR NOT EXISTS (
          SELECT 1
          FROM email_candidates candidate
          JOIN email_sources original_source
            ON original_source.id = candidate.source_id
          JOIN email_sources proposed_source
            ON proposed_source.id = NEW.source_id
          JOIN email_schedule_entity_links link
            ON link.candidate_id = candidate.id
          WHERE candidate.id = NEW.candidate_id
            AND candidate.owner_user_id = NEW.owner_user_id
            AND candidate.review_state = 'confirmed'
            AND candidate.semantic_fingerprint <> NEW.semantic_fingerprint
            AND candidate.source_id <> NEW.source_id
            AND original_source.owner_user_id = NEW.owner_user_id
            AND proposed_source.owner_user_id = NEW.owner_user_id
            AND proposed_source.connection_id = original_source.connection_id
            AND proposed_source.provider_thread_id =
              original_source.provider_thread_id
            AND link.owner_user_id = NEW.owner_user_id
            AND link.entity_type = candidate.linked_entity_type
            AND link.entity_id = candidate.linked_entity_id
            AND json_extract(
              NEW.proposed_payload_json,
              '\$.candidate_type'
            ) = candidate.candidate_type
            AND (
              (
                candidate.linked_entity_type = 'assignment'
                AND EXISTS (
                  SELECT 1 FROM assignments assignment
                  WHERE assignment.id = candidate.linked_entity_id
                    AND assignment.owner_user_id = NEW.owner_user_id
                    AND assignment.deleted_at IS NULL
                    AND assignment.version = NEW.base_entity_version
                )
              )
              OR (
                candidate.linked_entity_type = 'exam'
                AND EXISTS (
                  SELECT 1 FROM exams exam
                  WHERE exam.id = candidate.linked_entity_id
                    AND exam.owner_user_id = NEW.owner_user_id
                    AND exam.deleted_at IS NULL
                    AND exam.version = NEW.base_entity_version
                )
              )
              OR (
                candidate.linked_entity_type = 'event'
                AND EXISTS (
                  SELECT 1 FROM events event
                  WHERE event.id = candidate.linked_entity_id
                    AND event.owner_user_id = NEW.owner_user_id
                    AND event.deleted_at IS NULL
                    AND event.version = NEW.base_entity_version
                )
              )
            )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email candidate update proposal');
      END
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS email_candidate_updates_v12_guard_update',
    );
    await customStatement('''
      CREATE TRIGGER email_candidate_updates_v12_guard_update
      BEFORE UPDATE ON email_candidate_updates
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.candidate_id <> OLD.candidate_id
        OR NEW.source_id <> OLD.source_id
        OR NEW.field_diff_json <> OLD.field_diff_json
        OR NEW.proposed_payload_json <> OLD.proposed_payload_json
        OR NEW.semantic_fingerprint <> OLD.semantic_fingerprint
        OR NEW.base_entity_version <> OLD.base_entity_version
        OR NEW.created_at <> OLD.created_at
        OR NOT (
          (
            OLD.state = 'pending'
            AND NEW.state IN ('accepted', 'rejected', 'superseded', 'failed')
            AND (
              (
                NEW.state IN ('accepted', 'rejected', 'superseded')
                AND NEW.resolution_idempotency_key IS NOT NULL
                AND trim(NEW.resolution_idempotency_key) <> ''
                AND length(NEW.resolution_idempotency_key) <= 200
                AND NEW.resolved_at IS NOT NULL
                AND NEW.error_category IS NULL
              )
              OR (
                NEW.state = 'failed'
                AND NEW.error_category IS NOT NULL
                AND NEW.resolution_idempotency_key IS NULL
                AND NEW.resolved_at IS NOT NULL
              )
            )
          )
          OR (
            OLD.state = 'accepted'
            AND NEW.state = 'superseded'
            AND OLD.resolution_idempotency_key IS NOT NULL
            AND OLD.resolved_at IS NOT NULL
            AND OLD.error_category IS NULL
            AND NEW.resolution_idempotency_key IS NOT NULL
            AND trim(NEW.resolution_idempotency_key) <> ''
            AND length(NEW.resolution_idempotency_key) <= 200
            AND NEW.resolution_idempotency_key <>
                  OLD.resolution_idempotency_key
            AND NEW.resolution_idempotency_key =
                  'email-update-server-wins-reject:' || OLD.id
            AND NEW.resolved_at IS NOT NULL
            AND NEW.error_category IS NULL
            AND NEW.updated_at >= OLD.updated_at
            AND EXISTS (
              SELECT 1
              FROM email_candidates candidate
              JOIN email_reconciliation_receipts receipt
                ON receipt.owner_user_id = OLD.owner_user_id
               AND receipt.action = 'update'
               AND receipt.local_reference_id = OLD.id
              JOIN sync_queue_entries mutation
                ON mutation.owner_user_id = OLD.owner_user_id
               AND mutation.client_mutation_id =
                     receipt.required_sync_mutation_id
              WHERE candidate.id = OLD.candidate_id
                AND candidate.owner_user_id = OLD.owner_user_id
                AND candidate.review_state = 'confirmed'
                AND receipt.state = 'pending'
                AND receipt.resolution = 'accepted'
                AND receipt.schedule_acked_at IS NULL
                AND receipt.idempotency_key =
                      OLD.resolution_idempotency_key
                AND receipt.entity_type = candidate.linked_entity_type
                AND receipt.entity_id = candidate.linked_entity_id
                AND mutation.status = 'conflict'
                AND mutation.operation = 'update'
                AND mutation.idempotency_key =
                      OLD.resolution_idempotency_key
                AND mutation.entity_type = candidate.linked_entity_type
                AND mutation.entity_id = candidate.linked_entity_id
            )
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email candidate update transition');
      END
    ''');
  }

  Future<void> _ensureEmailReconciliationInfrastructure() async {
    if (!await _tableExists('email_reconciliation_receipts')) return;
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_reconciliation_owner_pending_idx
      ON email_reconciliation_receipts(
        owner_user_id, state, next_retry_at, created_at
      )
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS email_reconciliation_values_guard_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS email_reconciliation_values_guard_update',
    );
    await customStatement('''
      CREATE TRIGGER email_reconciliation_values_guard_insert
      BEFORE INSERT ON email_reconciliation_receipts
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR trim(NEW.connection_id) = ''
        OR trim(NEW.local_reference_id) = ''
        OR NEW.provider <> 'gmail'
        OR NEW.action NOT IN ('confirmation', 'dismissal', 'update')
        OR length(NEW.provider_account_hash) <> 64
        OR NEW.provider_account_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.provider_message_id_hash) <> 64
        OR NEW.provider_message_id_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.provider_thread_id_hash) <> 64
        OR NEW.provider_thread_id_hash GLOB '*[^0-9a-f]*'
        OR length(NEW.sanitized_content_hash) <> 64
        OR NEW.sanitized_content_hash GLOB '*[^0-9a-f]*'
        OR trim(NEW.idempotency_key) = ''
        OR length(NEW.idempotency_key) > 200
        OR NEW.attempt_count < 0
        OR NEW.state NOT IN ('pending', 'succeeded')
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.action = 'confirmation'
          AND (
            NEW.reviewed_payload_json IS NULL
            OR NOT json_valid(NEW.reviewed_payload_json)
            OR json_type(NEW.reviewed_payload_json) <> 'object'
            OR length(NEW.reviewed_payload_json) > 32768
            OR NEW.resolution IS NOT NULL
            OR NEW.entity_type NOT IN ('assignment', 'exam', 'event')
            OR trim(COALESCE(NEW.entity_id, '')) = ''
            OR trim(COALESCE(NEW.required_sync_mutation_id, '')) = ''
          )
        )
        OR (
          NEW.action = 'dismissal'
          AND (
            NEW.reviewed_payload_json IS NOT NULL
            OR NEW.resolution IS NOT NULL
            OR NEW.entity_type IS NOT NULL
            OR NEW.entity_id IS NOT NULL
            OR NEW.required_sync_mutation_id IS NOT NULL
            OR NEW.schedule_acked_at IS NOT NULL
          )
        )
        OR (
          NEW.action = 'update'
          AND (
            NEW.reviewed_payload_json IS NOT NULL
            OR NEW.resolution NOT IN ('accepted', 'rejected')
            OR NEW.entity_type NOT IN ('assignment', 'exam', 'event')
            OR trim(COALESCE(NEW.entity_id, '')) = ''
            OR (
              NEW.resolution = 'accepted'
              AND trim(COALESCE(NEW.required_sync_mutation_id, '')) = ''
            )
            OR (
              NEW.resolution = 'rejected'
              AND (
                NEW.required_sync_mutation_id IS NOT NULL
                OR NEW.schedule_acked_at IS NOT NULL
              )
            )
          )
        )
        OR (
          NEW.state = 'pending'
          AND (NEW.reconciled_at IS NOT NULL OR NEW.replayed IS NOT NULL)
        )
        OR (
          NEW.schedule_acked_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM sync_queue_entries mutation
            WHERE mutation.owner_user_id = NEW.owner_user_id
              AND mutation.client_mutation_id =
                    NEW.required_sync_mutation_id
              AND mutation.status = 'synced'
              AND mutation.completion_provenance =
                    '$scheduleSyncCompletionRemoteApplied'
              AND mutation.synced_at IS NOT NULL
              AND mutation.server_version IS NOT NULL
              AND mutation.idempotency_key = NEW.idempotency_key
              AND mutation.entity_type = NEW.entity_type
              AND mutation.entity_id = NEW.entity_id
              AND (
                (NEW.action = 'confirmation' AND NEW.resolution IS NULL
                  AND mutation.operation = 'create')
                OR
                (NEW.action = 'update' AND NEW.resolution = 'accepted'
                  AND mutation.operation = 'update')
              )
          )
        )
        OR (
          NEW.state = 'succeeded'
          AND (
            NEW.reconciled_at IS NULL
            OR NEW.replayed IS NULL
            OR NEW.error_category IS NOT NULL
            OR NEW.next_retry_at IS NOT NULL
            OR (
              NEW.required_sync_mutation_id IS NOT NULL
              AND NEW.schedule_acked_at IS NULL
            )
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email reconciliation receipt');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER email_reconciliation_values_guard_update
      BEFORE UPDATE ON email_reconciliation_receipts
      FOR EACH ROW
      WHEN NEW.id <> OLD.id
        OR NEW.owner_user_id <> OLD.owner_user_id
        OR NEW.connection_id <> OLD.connection_id
        OR NEW.action <> OLD.action
        OR NEW.local_reference_id <> OLD.local_reference_id
        OR NEW.provider <> OLD.provider
        OR NEW.provider_account_hash <> OLD.provider_account_hash
        OR NEW.provider_message_id_hash <> OLD.provider_message_id_hash
        OR NEW.provider_thread_id_hash <> OLD.provider_thread_id_hash
        OR NEW.sanitized_content_hash <> OLD.sanitized_content_hash
        OR NEW.reviewed_payload_json IS NOT OLD.reviewed_payload_json
        OR NEW.resolution IS NOT OLD.resolution
        OR NEW.entity_type IS NOT OLD.entity_type
        OR NEW.entity_id IS NOT OLD.entity_id
        OR NEW.idempotency_key <> OLD.idempotency_key
        OR NEW.required_sync_mutation_id IS NOT OLD.required_sync_mutation_id
        OR (
          NEW.schedule_acked_at IS NOT OLD.schedule_acked_at
          AND (
            OLD.schedule_acked_at IS NOT NULL
            OR NEW.schedule_acked_at IS NULL
            OR NOT EXISTS (
              SELECT 1
              FROM sync_queue_entries mutation
              WHERE mutation.owner_user_id = NEW.owner_user_id
                AND mutation.client_mutation_id =
                      NEW.required_sync_mutation_id
                AND mutation.status = 'synced'
                AND mutation.completion_provenance =
                      '$scheduleSyncCompletionRemoteApplied'
                AND mutation.synced_at IS NOT NULL
                AND mutation.server_version IS NOT NULL
                AND mutation.idempotency_key = NEW.idempotency_key
                AND mutation.entity_type = NEW.entity_type
                AND mutation.entity_id = NEW.entity_id
                AND (
                  (NEW.action = 'confirmation' AND NEW.resolution IS NULL
                    AND mutation.operation = 'create')
                  OR
                  (NEW.action = 'update' AND NEW.resolution = 'accepted'
                    AND mutation.operation = 'update')
                )
            )
          )
        )
        OR NEW.attempt_count < OLD.attempt_count
        OR NEW.state NOT IN ('pending', 'succeeded')
        OR (OLD.state = 'succeeded' AND NEW.state <> 'succeeded')
        OR (
          NEW.error_category IS NOT NULL
          AND NEW.error_category NOT IN (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
        )
        OR (
          NEW.state = 'pending'
          AND (NEW.reconciled_at IS NOT NULL OR NEW.replayed IS NOT NULL)
        )
        OR (
          NEW.state = 'succeeded'
          AND (
            NEW.reconciled_at IS NULL
            OR NEW.replayed IS NULL
            OR NEW.error_category IS NOT NULL
            OR NEW.next_retry_at IS NOT NULL
            OR (
              NEW.required_sync_mutation_id IS NOT NULL
              AND NEW.schedule_acked_at IS NULL
            )
          )
        )
        OR (
          NEW.required_sync_mutation_id IS NULL
          AND NEW.schedule_acked_at IS NOT NULL
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email reconciliation receipt update');
      END
    ''');
    if (await _tableExists('sync_queue_entries') &&
        await _columnExists(
          'sync_queue_entries',
          'completion_provenance',
        )) {
      await customStatement(
        'DROP TRIGGER IF EXISTS email_reconciliation_sync_ack_insert',
      );
      await customStatement(
        'DROP TRIGGER IF EXISTS email_reconciliation_sync_ack_update',
      );
      await customStatement('''
        CREATE TRIGGER email_reconciliation_sync_ack_insert
        AFTER INSERT ON sync_queue_entries
        FOR EACH ROW
        WHEN NEW.status = 'synced'
          AND NEW.completion_provenance =
                '$scheduleSyncCompletionRemoteApplied'
          AND NEW.synced_at IS NOT NULL
          AND NEW.server_version IS NOT NULL
      BEGIN
        UPDATE email_reconciliation_receipts
        SET schedule_acked_at = COALESCE(
              schedule_acked_at,
              NEW.synced_at,
              CAST(strftime('%s', 'now') AS INTEGER)
            ),
            updated_at = COALESCE(
              NEW.synced_at,
              CAST(strftime('%s', 'now') AS INTEGER)
            )
        WHERE owner_user_id = NEW.owner_user_id
          AND required_sync_mutation_id = NEW.client_mutation_id
          AND idempotency_key = NEW.idempotency_key
          AND entity_type = NEW.entity_type
          AND entity_id = NEW.entity_id
          AND (
            (action = 'confirmation' AND resolution IS NULL
              AND NEW.operation = 'create')
            OR
            (action = 'update' AND resolution = 'accepted'
              AND NEW.operation = 'update')
          )
          AND state = 'pending';
      END
      ''');
      await customStatement('''
        CREATE TRIGGER email_reconciliation_sync_ack_update
        AFTER UPDATE OF status, synced_at, completion_provenance
          ON sync_queue_entries
        FOR EACH ROW
        WHEN NEW.status = 'synced'
          AND NEW.completion_provenance =
                '$scheduleSyncCompletionRemoteApplied'
          AND NEW.synced_at IS NOT NULL
          AND NEW.server_version IS NOT NULL
      BEGIN
        UPDATE email_reconciliation_receipts
        SET schedule_acked_at = COALESCE(
              schedule_acked_at,
              NEW.synced_at,
              CAST(strftime('%s', 'now') AS INTEGER)
            ),
            updated_at = COALESCE(
              NEW.synced_at,
              CAST(strftime('%s', 'now') AS INTEGER)
            )
        WHERE owner_user_id = NEW.owner_user_id
          AND required_sync_mutation_id = NEW.client_mutation_id
          AND idempotency_key = NEW.idempotency_key
          AND entity_type = NEW.entity_type
          AND entity_id = NEW.entity_id
          AND (
            (action = 'confirmation' AND resolution IS NULL
              AND NEW.operation = 'create')
            OR
            (action = 'update' AND resolution = 'accepted'
              AND NEW.operation = 'update')
          )
          AND state = 'pending';
      END
      ''');
    }
  }

  Future<void> _ensureEmailScheduleEditReceiptInfrastructure() async {
    if (!await _tableExists('email_schedule_edit_receipts')) return;
    await customStatement('''
      CREATE INDEX IF NOT EXISTS email_schedule_edit_receipts_entity_idx
      ON email_schedule_edit_receipts(
        owner_user_id, candidate_id, entity_type, entity_id, entity_version
      )
    ''');
    await customStatement(
      'DROP TRIGGER IF EXISTS email_schedule_edit_receipts_guard_insert',
    );
    await customStatement(
      'DROP TRIGGER IF EXISTS email_schedule_edit_receipts_immutable',
    );
    await customStatement('''
      CREATE TRIGGER email_schedule_edit_receipts_guard_insert
      BEFORE INSERT ON email_schedule_edit_receipts
      FOR EACH ROW
      WHEN trim(NEW.mutation_id) = ''
        OR trim(NEW.owner_user_id) = ''
        OR NEW.entity_type NOT IN ('assignment', 'exam', 'event')
        OR trim(NEW.entity_id) = ''
        OR NEW.provenance NOT IN (
          'confirmation', 'accepted_update', 'user_edit', 'server_wins',
          'remote_apply', 'remote_ack', 'legacy_trusted_tip'
        )
        OR NEW.base_entity_version < 0
        OR NEW.entity_version < 1
        OR (
          NEW.provenance = 'confirmation'
          AND (
            NEW.base_entity_version <> 0
            OR NEW.entity_version <> 1
          )
        )
        OR (
          NEW.provenance IN ('accepted_update', 'user_edit')
          AND NEW.entity_version <> NEW.base_entity_version + 1
        )
        OR (
          NEW.provenance = 'server_wins'
          AND NEW.entity_version < NEW.base_entity_version
        )
        OR (
          NEW.provenance IN ('remote_apply', 'legacy_trusted_tip')
          AND NEW.entity_version <= NEW.base_entity_version
        )
        OR (
          NEW.provenance = 'remote_ack'
          AND NEW.entity_version <> NEW.base_entity_version
        )
        OR length(NEW.base_payload_fingerprint) <> 43
        OR NEW.base_payload_fingerprint GLOB '*[^A-Za-z0-9_-]*'
        OR length(NEW.payload_fingerprint) <> 43
        OR NEW.payload_fingerprint GLOB '*[^A-Za-z0-9_-]*'
        OR length(NEW.candidate_payload_fingerprint) <> 43
        OR NEW.candidate_payload_fingerprint GLOB '*[^A-Za-z0-9_-]*'
        OR NOT EXISTS (
          SELECT 1
          FROM email_schedule_entity_links link
          JOIN email_candidates candidate ON candidate.id = link.candidate_id
          WHERE link.id = NEW.link_id
            AND link.owner_user_id = NEW.owner_user_id
            AND link.candidate_id = NEW.candidate_id
            AND link.entity_type = NEW.entity_type
            AND link.entity_id = NEW.entity_id
            AND candidate.owner_user_id = NEW.owner_user_id
            AND candidate.review_state = 'confirmed'
            AND candidate.linked_entity_type = NEW.entity_type
            AND candidate.linked_entity_id = NEW.entity_id
        )
        OR (
          NEW.provenance NOT IN (
            'remote_apply', 'remote_ack', 'legacy_trusted_tip'
          )
          AND NOT EXISTS (
            SELECT 1
            FROM sync_queue_entries mutation
            WHERE (
                mutation.client_mutation_id = NEW.mutation_id
                OR (
                  NEW.provenance = 'server_wins'
                  AND NEW.mutation_id =
                        'server-wins:' || mutation.client_mutation_id
                )
              )
              AND mutation.owner_user_id = NEW.owner_user_id
              AND mutation.entity_type = NEW.entity_type
              AND mutation.entity_id = NEW.entity_id
              AND (
                (NEW.provenance = 'confirmation'
                  AND mutation.operation = 'create'
                  AND mutation.base_version IS NULL)
                OR
                (NEW.provenance = 'accepted_update'
                  AND mutation.operation = 'update'
                  AND mutation.base_version = NEW.base_entity_version)
                OR
                (NEW.provenance = 'user_edit'
                  AND mutation.operation IN ('update', 'delete')
                  AND mutation.base_version = NEW.base_entity_version)
                OR
                (NEW.provenance = 'server_wins'
                  AND mutation.operation IN ('create', 'update', 'delete'))
              )
              AND mutation.payload_json <> '{}'
              AND json_valid(mutation.payload_json)
              AND json_extract(mutation.payload_json, '\$.version') =
                    CASE
                      WHEN NEW.provenance = 'server_wins'
                        AND NEW.mutation_id =
                              'server-wins:' || mutation.client_mutation_id
                        THEN NEW.base_entity_version
                      WHEN NEW.provenance = 'server_wins'
                        THEN NEW.base_entity_version + 1
                      ELSE NEW.entity_version
                    END
              AND mutation.status = CASE NEW.provenance
                WHEN 'server_wins' THEN 'conflict'
                ELSE 'pending'
              END
          )
        )
        OR (
          NEW.provenance IN (
            'confirmation', 'accepted_update', 'user_edit', 'remote_apply',
            'remote_ack', 'legacy_trusted_tip'
          )
          AND NOT (
            (
              NEW.entity_type = 'assignment'
              AND EXISTS (
                SELECT 1 FROM assignments entity
                WHERE entity.id = NEW.entity_id
                  AND entity.owner_user_id = NEW.owner_user_id
                  AND entity.version = NEW.entity_version
                  AND entity.updated_at = NEW.entity_updated_at
              )
            )
            OR (
              NEW.entity_type = 'exam'
              AND EXISTS (
                SELECT 1 FROM exams entity
                WHERE entity.id = NEW.entity_id
                  AND entity.owner_user_id = NEW.owner_user_id
                  AND entity.version = NEW.entity_version
                  AND entity.updated_at = NEW.entity_updated_at
              )
            )
            OR (
              NEW.entity_type = 'event'
              AND EXISTS (
                SELECT 1 FROM events entity
                WHERE entity.id = NEW.entity_id
                  AND entity.owner_user_id = NEW.owner_user_id
                  AND entity.version = NEW.entity_version
                  AND entity.updated_at = NEW.entity_updated_at
              )
            )
          )
        )
      BEGIN
        SELECT RAISE(ABORT, 'invalid email schedule edit receipt');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER email_schedule_edit_receipts_immutable
      BEFORE UPDATE ON email_schedule_edit_receipts
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'email schedule edit receipts are immutable');
      END
    ''');
  }

  Future<void> _ensureSyncQueueInfrastructure() async {
    final hasEnqueueSequence =
        await _columnExists('sync_queue_entries', 'enqueue_sequence');
    final hasSequenceState = await _tableExists('sync_queue_sequence_states');
    if (hasEnqueueSequence && hasSequenceState) {
      await _ensureSyncQueueSequenceState();
      await customStatement('''
        CREATE UNIQUE INDEX IF NOT EXISTS sync_queue_enqueue_sequence_idx
        ON sync_queue_entries(enqueue_sequence)
        WHERE enqueue_sequence > 0
      ''');
      await customStatement('''
        CREATE INDEX IF NOT EXISTS sync_queue_claim_order_idx
        ON sync_queue_entries(owner_user_id, status, enqueue_sequence)
      ''');
      await customStatement('''
        CREATE TRIGGER IF NOT EXISTS sync_queue_assign_enqueue_sequence
        AFTER INSERT ON sync_queue_entries
        FOR EACH ROW
        WHEN NEW.enqueue_sequence = 0
        BEGIN
          UPDATE sync_queue_entries
          SET enqueue_sequence = (
            SELECT next_value
            FROM sync_queue_sequence_states
            WHERE id = 1
          )
          WHERE client_mutation_id = NEW.client_mutation_id;
          UPDATE sync_queue_sequence_states
          SET next_value = next_value + 1
          WHERE id = 1;
        END
      ''');
    }
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS sync_queue_idempotency_key_idx
      ON sync_queue_entries(idempotency_key)
      WHERE idempotency_key IS NOT NULL
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS sync_queue_due_idx
      ON sync_queue_entries(owner_user_id, status, next_retry_at, created_at)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS sync_queue_acknowledged_idx
      ON sync_queue_entries(status, synced_at)
    ''');
    await customStatement('''
      CREATE INDEX IF NOT EXISTS sync_queue_entity_active_idx
      ON sync_queue_entries(
        owner_user_id,
        entity_type,
        entity_id,
        status,
        created_at,
        client_mutation_id
      )
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS sync_queue_fill_idempotency_key
      AFTER INSERT ON sync_queue_entries
      FOR EACH ROW
      WHEN NEW.idempotency_key IS NULL OR NEW.idempotency_key = ''
      BEGIN
        UPDATE sync_queue_entries
        SET idempotency_key = NEW.client_mutation_id
        WHERE client_mutation_id = NEW.client_mutation_id;
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS sync_queue_require_owner
      BEFORE INSERT ON sync_queue_entries
      FOR EACH ROW
      WHEN trim(NEW.owner_user_id) = ''
        OR NEW.owner_user_id = '$legacyQuarantinedOwnerId'
      BEGIN
        SELECT RAISE(ABORT, 'sync queue owner_user_id is required');
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS sync_queue_owner_immutable
      BEFORE UPDATE OF owner_user_id ON sync_queue_entries
      FOR EACH ROW
      WHEN NEW.owner_user_id <> OLD.owner_user_id
      BEGIN
        SELECT RAISE(ABORT, 'sync queue owner_user_id is immutable');
      END
    ''');
    if (await _columnExists(
      'sync_queue_entries',
      'completion_provenance',
    )) {
      await customStatement(
        'DROP TRIGGER IF EXISTS sync_queue_completion_guard_insert',
      );
      await customStatement(
        'DROP TRIGGER IF EXISTS sync_queue_completion_guard_update',
      );
      await customStatement('''
        CREATE TRIGGER sync_queue_completion_guard_insert
        BEFORE INSERT ON sync_queue_entries
        FOR EACH ROW
        WHEN NEW.completion_provenance IS NOT NULL
          AND (
            NEW.completion_provenance NOT IN (
              '$scheduleSyncCompletionRemoteApplied',
              '$scheduleSyncCompletionServerWins'
            )
            OR NEW.status <> 'synced'
            OR NEW.synced_at IS NULL
            OR NEW.server_version IS NULL
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid sync completion provenance');
        END
      ''');
      await customStatement('''
        CREATE TRIGGER sync_queue_completion_guard_update
        BEFORE UPDATE OF
          client_mutation_id, idempotency_key, entity_type, entity_id,
          operation, status, server_version, synced_at, completion_provenance
        ON sync_queue_entries
        FOR EACH ROW
        WHEN (
            NEW.completion_provenance IS NOT NULL
            AND (
              NEW.completion_provenance NOT IN (
                '$scheduleSyncCompletionRemoteApplied',
                '$scheduleSyncCompletionServerWins'
              )
              OR NEW.status <> 'synced'
              OR NEW.synced_at IS NULL
              OR NEW.server_version IS NULL
            )
          )
          OR (
            OLD.completion_provenance IS NOT NULL
            AND (
              NEW.client_mutation_id <> OLD.client_mutation_id
              OR NEW.idempotency_key IS NOT OLD.idempotency_key
              OR NEW.entity_type <> OLD.entity_type
              OR NEW.entity_id <> OLD.entity_id
              OR NEW.operation <> OLD.operation
              OR NEW.status <> OLD.status
              OR NEW.server_version IS NOT OLD.server_version
              OR NEW.synced_at IS NOT OLD.synced_at
              OR NEW.completion_provenance IS NOT OLD.completion_provenance
            )
          )
          OR (
            NEW.completion_provenance =
                  '$scheduleSyncCompletionRemoteApplied'
            AND OLD.completion_provenance IS NULL
            AND OLD.status <> 'processing'
          )
          OR (
            NEW.completion_provenance =
                  '$scheduleSyncCompletionServerWins'
            AND OLD.completion_provenance IS NULL
            AND OLD.status <> 'conflict'
          )
        BEGIN
          SELECT RAISE(ABORT, 'invalid sync completion transition');
        END
      ''');
    }
  }

  Future<void> _migrateToV9(Migrator m) async {
    if (!await _tableExists('sync_queue_entries')) {
      await m.createTable(syncQueueEntries);
    } else {
      await _addColumnIfMissing(
        m,
        'sync_queue_entries',
        syncQueueEntries,
        syncQueueEntries.enqueueSequence,
      );
    }
    await _createTableIfMissing(
      m,
      'sync_queue_sequence_states',
      syncQueueSequenceStates,
    );
    await _ensureSyncQueueSequenceState();
  }

  Future<void> _ensureSyncQueueSequenceState() async {
    await customStatement('''
      UPDATE sync_queue_entries
      SET enqueue_sequence = rowid
      WHERE enqueue_sequence = 0
    ''');
    await customStatement('''
      INSERT INTO sync_queue_sequence_states (id, next_value)
      VALUES (
        1,
        COALESCE((SELECT MAX(enqueue_sequence) + 1 FROM sync_queue_entries), 1)
      )
      ON CONFLICT(id) DO UPDATE SET
        next_value = MAX(next_value, excluded.next_value)
    ''');
  }

  Future<void> _migrateToV7() async {
    if (!await _tableExists('event_exceptions')) return;

    // SQLite cannot add a NOT NULL column without a default to an existing
    // table. Quarantine an unresolvable legacy row rather than letting it be
    // attributed to the currently signed-in user by a future sync pass.
    if (!await _columnExists('event_exceptions', 'owner_user_id')) {
      await customStatement('''
        ALTER TABLE event_exceptions
        ADD COLUMN owner_user_id TEXT NOT NULL
        DEFAULT '$legacyQuarantinedOwnerId'
      ''');
    }
    if (!await _columnExists('event_exceptions', 'updated_at')) {
      await customStatement('''
        ALTER TABLE event_exceptions
        ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0
      ''');
    }
    if (!await _columnExists('event_exceptions', 'deleted_at')) {
      await customStatement(
        'ALTER TABLE event_exceptions ADD COLUMN deleted_at INTEGER',
      );
    }
    if (!await _columnExists('event_exceptions', 'version')) {
      await customStatement('''
        ALTER TABLE event_exceptions
        ADD COLUMN version INTEGER NOT NULL DEFAULT 1
      ''');
    }

    if (await _tableExists('events') &&
        await _columnExists('events', 'owner_user_id')) {
      await customStatement('''
        UPDATE event_exceptions
        SET owner_user_id = (
          SELECT events.owner_user_id
          FROM events
          WHERE events.id = event_exceptions.event_id
        )
        WHERE owner_user_id = '$legacyQuarantinedOwnerId'
          AND EXISTS (
            SELECT 1
            FROM events
            WHERE events.id = event_exceptions.event_id
              AND events.owner_user_id IS NOT NULL
          )
      ''');
    }
  }

  Future<void> _ensureEventExceptionInfrastructure() async {
    if (!await _tableExists('event_exceptions') ||
        !await _columnExists('event_exceptions', 'owner_user_id') ||
        !await _columnExists('event_exceptions', 'deleted_at')) {
      return;
    }
    await customStatement('''
      CREATE INDEX IF NOT EXISTS event_exceptions_owner_event_active_idx
      ON event_exceptions(owner_user_id, event_id, recurrence_id)
      WHERE deleted_at IS NULL
    ''');
  }

  Future<void> _migrateToV5(Migrator m) async {
    if (await _tableExists('profiles')) {
      await _addColumnIfMissing(m, 'profiles', profiles, profiles.userType);
      await _addColumnIfMissing(m, 'profiles', profiles, profiles.campusId);
      await _addColumnIfMissing(m, 'profiles', profiles, profiles.facultyId);
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.departmentId,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.activeTermId,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.primaryCalendarId,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.entryAcademicYear,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.onboardingStatus,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.onboardingStep,
      );
      await _addColumnIfMissing(
        m,
        'profiles',
        profiles,
        profiles.onboardingCompletedAt,
      );
      await _addColumnIfMissing(m, 'profiles', profiles, profiles.version);
    }

    if (await _tableExists('universities')) {
      await _addColumnIfMissing(
        m,
        'universities',
        universities,
        universities.officialWebDomain,
      );
      await _addColumnIfMissing(
        m,
        'universities',
        universities,
        universities.timezone,
      );
      await _addColumnIfMissing(
        m,
        'universities',
        universities,
        universities.status,
      );
      await _addColumnIfMissing(
        m,
        'universities',
        universities,
        universities.deletedAt,
      );
      await _addColumnIfMissing(
        m,
        'universities',
        universities,
        universities.version,
      );
    }

    if (await _tableExists('terms')) {
      await _addColumnIfMissing(m, 'terms', terms, terms.configKey);
      await _addColumnIfMissing(m, 'terms', terms, terms.ownerUserId);
      await _addColumnIfMissing(m, 'terms', terms, terms.sourceTemplateId);
      await _addColumnIfMissing(
        m,
        'terms',
        terms,
        terms.instructionStartDate,
      );
      await _addColumnIfMissing(
        m,
        'terms',
        terms,
        terms.instructionEndDate,
      );
      await _addColumnIfMissing(m, 'terms', terms, terms.isTemplate);
      await _addColumnIfMissing(m, 'terms', terms, terms.status);
      if (!await _columnExists('terms', 'updated_at')) {
        await customStatement(
          'ALTER TABLE terms ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0',
        );
      }
      await _addColumnIfMissing(m, 'terms', terms, terms.deletedAt);
      await _addColumnIfMissing(m, 'terms', terms, terms.version);
    }

    if (await _tableExists('period_settings')) {
      if (!await _columnExists('period_settings', 'university_id')) {
        await customStatement('''
          ALTER TABLE period_settings
          ADD COLUMN university_id TEXT NOT NULL
          DEFAULT '$legacyUnknownUniversityId'
        ''');
      }
      if (!await _columnExists('period_settings', 'term_id')) {
        await customStatement('''
          ALTER TABLE period_settings
          ADD COLUMN term_id TEXT NOT NULL DEFAULT '$legacyUnknownTermId'
        ''');
      }
      await _addColumnIfMissing(
        m,
        'period_settings',
        periodSettings,
        periodSettings.sourceTemplateSetId,
      );
      if (!await _columnExists('period_settings', 'updated_at')) {
        await customStatement('''
          ALTER TABLE period_settings
          ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0
        ''');
      }
      await _addColumnIfMissing(
        m,
        'period_settings',
        periodSettings,
        periodSettings.deletedAt,
      );
      await _addColumnIfMissing(
        m,
        'period_settings',
        periodSettings,
        periodSettings.version,
      );

      if (await _tableExists('user_courses')) {
        await customStatement('''
          UPDATE period_settings
          SET term_id = COALESCE(
            (
              SELECT MIN(uc.term_id)
              FROM user_courses uc
              WHERE uc.owner_user_id = period_settings.owner_user_id
            ),
            term_id
          )
          WHERE term_id = '$legacyUnknownTermId'
        ''');
      }
      if (await _tableExists('terms')) {
        await customStatement('''
          UPDATE period_settings
          SET university_id = COALESCE(
            (
              SELECT t.university_id
              FROM terms t
              WHERE t.id = period_settings.term_id
              LIMIT 1
            ),
            university_id
          )
          WHERE university_id = '$legacyUnknownUniversityId'
        ''');
      }
    }

    await _createTableIfMissing(m, 'campuses', campuses);
    await _createTableIfMissing(m, 'faculties', faculties);
    await _createTableIfMissing(m, 'departments', departments);
    await _createTableIfMissing(m, 'university_domains', universityDomains);
    await _createTableIfMissing(
      m,
      'period_template_sets',
      periodTemplateSets,
    );
    await _createTableIfMissing(m, 'period_templates', periodTemplates);
    await _createTableIfMissing(m, 'onboarding_drafts', onboardingDrafts);

    if (!await _columnExists('sync_queue_entries', 'owner_user_id')) {
      await customStatement('''
        ALTER TABLE sync_queue_entries
        ADD COLUMN owner_user_id TEXT NOT NULL
        DEFAULT '$legacyQuarantinedOwnerId'
      ''');
    }
    await customStatement('''
      UPDATE sync_queue_entries
      SET owner_user_id = COALESCE(
        NULLIF(
          trim(CAST(
            CASE WHEN json_valid(payload_json)
              THEN json_extract(payload_json, '\$.ownerUserId') END
            AS TEXT
          )),
          ''
        ),
        NULLIF(
          trim(CAST(
            CASE WHEN json_valid(payload_json)
              THEN json_extract(payload_json, '\$.owner_user_id') END
            AS TEXT
          )),
          ''
        ),
        NULLIF(
          trim(CAST(
            CASE WHEN json_valid(payload_json)
              THEN json_extract(payload_json, '\$.userId') END
            AS TEXT
          )),
          ''
        ),
        owner_user_id
      )
      WHERE owner_user_id = '$legacyQuarantinedOwnerId'
    ''');
    await customStatement('''
      UPDATE sync_queue_entries
      SET status = 'quarantined',
          payload_json = '{}',
          error_message = NULL,
          next_retry_at = NULL,
          claimed_at = NULL,
          synced_at = COALESCE(synced_at, created_at)
      WHERE owner_user_id = '$legacyQuarantinedOwnerId'
    ''');

    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS campuses_config_key_idx
      ON campuses(config_key)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS faculties_config_key_idx
      ON faculties(config_key)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS departments_config_key_idx
      ON departments(config_key)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS university_domains_config_key_idx
      ON university_domains(config_key)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS period_template_sets_config_key_idx
      ON period_template_sets(config_key)
    ''');
    await customStatement('''
      CREATE UNIQUE INDEX IF NOT EXISTS period_templates_slot_idx
      ON period_templates(template_set_id, day_of_week, period_no)
    ''');
    if (await _tableExists('period_settings')) {
      await customStatement('''
        CREATE INDEX IF NOT EXISTS period_settings_context_idx
        ON period_settings(owner_user_id, university_id, term_id, day_of_week, period_no)
        WHERE deleted_at IS NULL
      ''');
    }
  }

  Future<void> _addColumnIfMissing<T extends Table, C>(
    Migrator m,
    String tableName,
    TableInfo<T, C> table,
    GeneratedColumn<Object> column,
  ) async {
    if (!await _columnExists(tableName, column.$name)) {
      await m.addColumn(table, column);
    }
  }

  Future<void> _createTableIfMissing<T extends Table, C>(
    Migrator m,
    String tableName,
    TableInfo<T, C> table,
  ) async {
    if (!await _tableExists(tableName)) {
      await m.createTable(table);
    }
  }

  Future<bool> _tableExists(String tableName) async {
    final row = await customSelect(
      'SELECT 1 AS present FROM sqlite_master '
      'WHERE type = ? AND name = ? LIMIT 1',
      variables: [Variable.withString('table'), Variable.withString(tableName)],
    ).getSingleOrNull();
    return row != null;
  }

  Future<bool> _columnExists(String tableName, String columnName) async {
    final columns = await customSelect('PRAGMA table_info("$tableName")')
        .map((row) => row.read<String>('name'))
        .get();
    return columns.contains(columnName);
  }
}

const legacyQuarantinedOwnerId = '__legacy_quarantine__';
const legacyUnknownUniversityId = '__legacy_unknown_university__';
const legacyUnknownTermId = '__legacy_unknown_term__';
