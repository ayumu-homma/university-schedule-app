import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_connector_binding.dart';
import 'package:university_schedule_mobile/features/email_import/data/drift_email_review_store.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_sync_service.dart';
import 'package:university_schedule_mobile/core/lifecycle/scoped_context_lease.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/email_import_identity.dart';

void main() {
  const ownerUserId = '11111111-1111-4111-8111-111111111111';
  const connectionId = '22222222-2222-4222-8222-222222222222';
  final now = DateTime.utc(2030, 4, 5, 6, 7, 8);

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedConnection(
      db,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      now: now,
    );
  });

  tearDown(() => db.close());

  test('repeated fixture sync keeps one source and one candidate', () async {
    final item = _assignmentItem();
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [item],
        nextCursor: 'opaque-cursor-1',
        hasMore: false,
      ),
      EmailFetchPage(
        items: [item],
        nextCursor: 'opaque-cursor-2',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    final first = await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    final second = await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(first.pageCount, 1);
    expect(second.pageCount, 1);
    expect(connector.requestedCursors, [null, 'opaque-cursor-1']);
    expect(await db.select(db.emailSources).get(), hasLength(1));
    final candidates = await db.select(db.emailCandidates).get();
    expect(candidates, hasLength(1));
    expect(candidates.single.reviewState, 'ready_for_review');
    expect(candidates.single.requiresUserConfirmation, isTrue);
    expect(candidates.single.semanticFingerprint, hasLength(64));
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'opaque-cursor-2');
    expect(connection?.state, 'connected');

    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.events).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
  });

  test('delayed fetch after ABA lease switch leaves cache and cursor unchanged',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final connector = FakeEmailConnector(
      [
        EmailFetchPage(
          items: [_assignmentItem()],
          nextCursor: 'stale-cursor',
          hasMore: false,
        ),
      ],
      onFetch: () async {
        started.complete();
        await release.future;
      },
    );
    var activeOwner = ownerUserId;
    final lease = ScopedContextLease(ownerUserId: ownerUserId, database: db);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => activeOwner,
      lease: lease,
    );

    final operation = service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    await started.future;
    activeOwner = 'owner-b';
    lease.revoke();
    activeOwner = ownerUserId;
    release.complete();
    await expectLater(operation, throwsA(isA<EmailImportFailure>()));

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, isNull);
  });

  test('an expired cursor is recovered once with a bounded first sync',
      () async {
    await _seedConnection(
      db,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      now: now,
      cursor: 'expired-cursor',
    );
    final connector = FakeEmailConnector([
      EmailImportFailure.cursorExpired(),
      EmailFetchPage(
        items: [_assignmentItem()],
        nextCursor: 'recovered-cursor',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    final result = await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(result.recoveredExpiredCursor, isTrue);
    expect(result.pageCount, 1);
    expect(connector.requestedCursors, ['expired-cursor', null]);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'recovered-cursor');
    expect(connection?.state, 'connected');
  });

  test('a second expired cursor fails safely without looping', () async {
    await _seedConnection(
      db,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      now: now,
      cursor: 'expired-cursor',
    );
    final connector = FakeEmailConnector([
      EmailImportFailure.cursorExpired(),
      EmailImportFailure.cursorExpired(),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.errorCategory,
          'category',
          EmailErrorCategory.cursorExpired,
        ),
      ),
    );
    expect(connector.requestedCursors, ['expired-cursor', null]);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, 'failed');
    expect(connection?.errorCategory, 'cursor_expired');
    expect(connection?.cursor, 'expired-cursor');
  });

  test('rate limit preserves cursor and records an explicit retry state',
      () async {
    await _seedConnection(
      db,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      now: now,
      cursor: 'current-cursor',
    );
    final connector = FakeEmailConnector([
      EmailImportFailure.rateLimited(const Duration(seconds: 90)),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, 'rate_limited');
    expect(connection?.errorCategory, isNull);
    expect(
      connection?.retryAfter?.toUtc(),
      now.add(const Duration(seconds: 90)),
    );
    expect(connection?.cursor, 'current-cursor');
  });

  test('timeout and OAuth revocation become explicit safe states', () async {
    final failures = <EmailImportFailure>[
      EmailImportFailure.timeout(),
      EmailImportFailure.authorizationRevoked(),
    ];
    final expected = <(String, String?)>[
      ('failed', 'timeout'),
      ('reauth_required', null),
    ];

    for (var index = 0; index < failures.length; index += 1) {
      final service = EmailImportSyncService(
        db: db,
        connector: FakeEmailConnector([failures[index]]),
        clock: () => now,
        authenticatedUserId: () => ownerUserId,
      );
      await expectLater(
        service.synchronize(
          ownerUserId: ownerUserId,
          connectionId: connectionId,
        ),
        throwsA(isA<EmailImportFailure>()),
      );
      final connection = await db.emailImportDao.connectionById(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      );
      expect(connection?.state, expected[index].$1);
      expect(connection?.errorCategory, expected[index].$2);
    }
  });

  test('invalid pages are rejected before cache or cursor mutation', () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [_assignmentItem()],
        nextCursor: null,
        hasMore: true,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, isNull);
    expect(connection?.state, 'failed');
    expect(connection?.errorCategory, 'validation_failed');
  });

  test('an item cannot overlap a hash-only suppression ack', () async {
    final service = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector([
        EmailFetchPage(
          items: [_assignmentItem()],
          suppressions: [
            EmailFetchSuppression(
              providerMessageIdHash: _messageHash('provider-message-1'),
              reason: EmailFetchSuppressionReason.dismissed,
            ),
          ],
          nextCursor: 'must-not-commit-overlap',
          hasMore: false,
        ),
      ]),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, isNull);
  });

  test('a nonempty item or suppression page cannot clear its cursor', () async {
    final pages = <EmailFetchPage>[
      EmailFetchPage(
        items: [_assignmentItem()],
        nextCursor: null,
        hasMore: false,
      ),
      EmailFetchPage(
        items: const [],
        suppressions: [
          EmailFetchSuppression(
            providerMessageIdHash: _messageHash('provider-message-1'),
            reason: EmailFetchSuppressionReason.dismissed,
          ),
        ],
        nextCursor: null,
        hasMore: false,
      ),
    ];

    for (final page in pages) {
      await _seedConnection(
        db,
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        now: now,
        cursor: 'current-cursor',
      );
      final service = EmailImportSyncService(
        db: db,
        connector: FakeEmailConnector([page]),
        clock: () => now,
        authenticatedUserId: () => ownerUserId,
      );
      await expectLater(
        service.synchronize(
          ownerUserId: ownerUserId,
          connectionId: connectionId,
        ),
        throwsA(isA<EmailImportFailure>()),
      );
      final connection = await db.emailImportDao.connectionById(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      );
      expect(connection?.cursor, 'current-cursor');
      expect(await db.select(db.emailSources).get(), isEmpty);
    }
  });

  test('active authenticated owner is required before local sync', () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [_assignmentItem()],
        nextCursor: 'must-not-be-used',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => 'different-owner',
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.connectionStatus,
          'status',
          EmailConnectionStatus.reauthRequired,
        ),
      ),
    );
    expect(connector.requestedCursors, isEmpty);
    expect(await db.select(db.emailSources).get(), isEmpty);
  });

  test('account switch after fetch prevents the entire page commit', () async {
    var activeOwner = ownerUserId;
    final connector = FakeEmailConnector(
      [
        EmailFetchPage(
          items: [_assignmentItem()],
          nextCursor: 'must-not-commit',
          hasMore: false,
        ),
      ],
      onFetch: () => activeOwner = 'different-owner',
    );
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => activeOwner,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(
        isA<EmailImportFailure>().having(
          (error) => error.connectionStatus,
          'status',
          EmailConnectionStatus.reauthRequired,
        ),
      ),
    );
    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, isNull);
    expect(connection?.state, 'connected');
  });

  test('disconnect during fetch rolls back the page and cannot reconnect cache',
      () async {
    final disconnectedAt = now.add(const Duration(seconds: 1));
    final connector = FakeEmailConnector(
      [
        EmailFetchPage(
          items: [_assignmentItem()],
          nextCursor: 'must-not-commit',
          hasMore: false,
        ),
      ],
      onFetch: () async {
        await (db.update(db.emailConnections)
              ..where((row) =>
                  row.id.equals(connectionId) &
                  row.ownerUserId.equals(ownerUserId)))
            .write(
          EmailConnectionsCompanion(
            state: const Value('disconnected'),
            disconnectedAt: Value(disconnectedAt),
            updatedAt: Value(disconnectedAt),
          ),
        );
      },
    );
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now.add(const Duration(seconds: 2)),
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsStateError,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, 'disconnected');
    expect(connection?.cursor, isNull);
    expect(connection?.disconnectedAt?.toUtc(), disconnectedAt);
  });

  test('a concurrent cursor advance wins and rolls back the stale page',
      () async {
    final advancedAt = now.add(const Duration(seconds: 1));
    final connector = FakeEmailConnector(
      [
        EmailFetchPage(
          items: [_assignmentItem()],
          nextCursor: 'stale-next-cursor',
          hasMore: false,
        ),
      ],
      onFetch: () async {
        await (db.update(db.emailConnections)
              ..where((row) =>
                  row.id.equals(connectionId) &
                  row.ownerUserId.equals(ownerUserId)))
            .write(
          EmailConnectionsCompanion(
            cursor: const Value('newer-concurrent-cursor'),
            updatedAt: Value(advancedAt),
          ),
        );
      },
    );
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now.add(const Duration(seconds: 2)),
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsStateError,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, 'connected');
    expect(connection?.cursor, 'newer-concurrent-cursor');
  });

  test('invalid second item rolls back the first item and cursor', () async {
    final invalid = _assignmentItem(
      providerMessageId: 'provider-message-invalid',
      sanitizedContentHash: 'not-a-sha256',
    );
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [_assignmentItem(), invalid],
        nextCursor: 'must-not-commit',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, isNull);
    expect(connection?.state, 'failed');
    expect(connection?.errorCategory, 'validation_failed');
  });

  test('safe failed items persist without content and advance the page cursor',
      () async {
    final service = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector([
        EmailFetchPage(
          items: [
            _failedItem(errorCategory: EmailErrorCategory.unsafeContent),
          ],
          nextCursor: 'cursor-after-failed-message',
          hasMore: false,
        ),
      ]),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    final source = (await db.select(db.emailSources).get()).single;
    expect(source.processingState, 'failed');
    expect(source.errorCategory, 'unsafe_content');
    expect(source.evidenceExcerptsJson, '[]');
    expect(source.providerThreadId, startsWith('failed:'));
    expect(source.providerThreadId, isNot(contains('provider-message-1')));
    final candidate = (await db.select(db.emailCandidates).get()).single;
    expect(candidate.reviewState, 'failed');
    expect(candidate.errorCategory, 'unsafe_content');
    expect(candidate.normalizedPayloadJson, '{}');
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.events).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-after-failed-message');
  });

  test('dismissed suppression prunes a cached failure and keeps only a hash',
      () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [
          _failedItem(errorCategory: EmailErrorCategory.timeout),
        ],
        nextCursor: 'cursor-with-failed-message',
        hasMore: false,
      ),
      EmailFetchPage(
        items: const [],
        suppressions: [
          EmailFetchSuppression(
            providerMessageIdHash: _messageHash('provider-message-1'),
            reason: EmailFetchSuppressionReason.dismissed,
          ),
        ],
        nextCursor: 'cursor-after-suppression',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final tombstones = await db.select(db.emailDismissalTombstones).get();
    expect(tombstones, hasLength(1));
    expect(tombstones.single.providerMessageIdHash, hasLength(64));
    expect(await db.select(db.emailReconciliationReceipts).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-after-suppression');
  });

  test('dedupe suppression prunes only the cached failed source', () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [
          _failedItem(errorCategory: EmailErrorCategory.timeout),
        ],
        nextCursor: 'cursor-with-deduped-failure',
        hasMore: false,
      ),
      EmailFetchPage(
        items: const [],
        suppressions: [
          EmailFetchSuppression(
            providerMessageIdHash: _messageHash('provider-message-1'),
            reason: EmailFetchSuppressionReason.deduplicated,
          ),
        ],
        nextCursor: 'cursor-after-dedupe',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    expect(await db.select(db.emailDismissalTombstones).get(), isEmpty);
    expect(await db.select(db.emailReconciliationReceipts).get(), isEmpty);
  });

  test('suppression acks cannot delete processed or unrelated failures',
      () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [
          _assignmentItem(),
          _failedItem(
            providerMessageId: 'provider-message-failed',
            errorCategory: EmailErrorCategory.timeout,
          ),
        ],
        nextCursor: 'cursor-before-mismatched-suppression',
        hasMore: false,
      ),
      EmailFetchPage(
        items: const [],
        suppressions: [
          EmailFetchSuppression(
            providerMessageIdHash: _messageHash('provider-message-1'),
            reason: EmailFetchSuppressionReason.dismissed,
          ),
          EmailFetchSuppression(
            providerMessageIdHash: _messageHash(
              'provider-message-unrelated',
            ),
            reason: EmailFetchSuppressionReason.deduplicated,
          ),
        ],
        nextCursor: 'cursor-after-mismatched-suppression',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(await db.select(db.emailSources).get(), hasLength(2));
    final states = (await db.select(db.emailCandidates).get())
        .map((candidate) => candidate.reviewState)
        .toSet();
    expect(states, {'ready_for_review', 'failed'});
    expect(await db.select(db.emailDismissalTombstones).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-after-mismatched-suppression');
  });

  test('targeted retry upgrades one failed item without advancing cursor',
      () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [
          _failedItem(
            errorCategory: EmailErrorCategory.timeout,
            providerThreadId: 'failed:${'d' * 64}',
          ),
        ],
        nextCursor: 'cursor-before-targeted-retry',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    await service.persistTargetedRetryItem(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      item: _assignmentItem(),
    );

    expect(connector.requestedCursors, [null]);
    final source = (await db.select(db.emailSources).get()).single;
    expect(source.processingState, 'processed');
    expect(source.errorCategory, isNull);
    expect(source.providerThreadId, 'provider-thread-1');
    final candidate = (await db.select(db.emailCandidates).get()).single;
    expect(candidate.reviewState, 'ready_for_review');
    expect(candidate.errorCategory, isNull);
    expect(
      const EmailCandidatePayloadCodec()
          .decode(candidate.normalizedPayloadJson)
          .title,
      'レポート課題',
    );
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-before-targeted-retry');
  });

  test('targeted retry cannot repopulate cache after a concurrent disconnect',
      () async {
    final seedService = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector([
        EmailFetchPage(
          items: [
            _failedItem(errorCategory: EmailErrorCategory.timeout),
          ],
          nextCursor: 'cursor-before-targeted-disconnect',
          hasMore: false,
        ),
      ]),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await seedService.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    final disconnectedAt = now.add(const Duration(seconds: 1));
    Future<int>? disconnectWrite;
    var disconnectQueued = false;
    final retryService = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector(const []),
      clock: () {
        if (!disconnectQueued) {
          disconnectQueued = true;
          disconnectWrite = _disconnectConnection(
            db,
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            disconnectedAt: disconnectedAt,
          );
        }
        return now.add(const Duration(seconds: 2));
      },
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      retryService.persistTargetedRetryItem(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        item: _assignmentItem(),
      ),
      throwsStateError,
    );
    await disconnectWrite!;

    final source = (await db.select(db.emailSources).get()).single;
    expect(source.processingState, 'failed');
    expect(source.errorCategory, EmailErrorCategory.timeout.wireName);
    final candidate = (await db.select(db.emailCandidates).get()).single;
    expect(candidate.reviewState, 'failed');
    expect(candidate.errorCategory, EmailErrorCategory.timeout.wireName);
    expect(await db.select(db.emailDismissalTombstones).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, EmailConnectionStatus.disconnected.wireName);
    expect(connection?.cursor, isNull);
    expect(connection?.disconnectedAt?.toUtc(), disconnectedAt);
  });

  test(
      'targeted suppression cannot prune a failure after a concurrent disconnect',
      () async {
    final seedService = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector([
        EmailFetchPage(
          items: [
            _failedItem(errorCategory: EmailErrorCategory.timeout),
          ],
          nextCursor: 'cursor-before-suppression-disconnect',
          hasMore: false,
        ),
      ]),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await seedService.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    final disconnectedAt = now.add(const Duration(seconds: 1));
    Future<int>? disconnectWrite;
    var disconnectQueued = false;
    final retryService = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector(const []),
      clock: () {
        if (!disconnectQueued) {
          disconnectQueued = true;
          disconnectWrite = _disconnectConnection(
            db,
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            disconnectedAt: disconnectedAt,
          );
        }
        return now.add(const Duration(seconds: 2));
      },
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      retryService.persistTargetedRetrySuppression(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        suppression: EmailFetchSuppression(
          providerMessageIdHash: _messageHash('provider-message-1'),
          reason: EmailFetchSuppressionReason.dismissed,
        ),
      ),
      throwsStateError,
    );
    await disconnectWrite!;

    final source = (await db.select(db.emailSources).get()).single;
    expect(source.processingState, 'failed');
    expect(source.errorCategory, EmailErrorCategory.timeout.wireName);
    final candidate = (await db.select(db.emailCandidates).get()).single;
    expect(candidate.reviewState, 'failed');
    expect(candidate.errorCategory, EmailErrorCategory.timeout.wireName);
    expect(await db.select(db.emailDismissalTombstones).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.state, EmailConnectionStatus.disconnected.wireName);
    expect(connection?.cursor, isNull);
    expect(connection?.disconnectedAt?.toUtc(), disconnectedAt);
  });

  test(
      'ordinary success prunes a failed sibling suppressed by an offline dismissal',
      () async {
    final connector = FakeEmailConnector([
      EmailFetchPage(
        items: [
          _assignmentItem(providerMessageId: 'provider-message-a'),
          _failedItem(
            providerMessageId: 'provider-message-b',
            errorCategory: EmailErrorCategory.timeout,
          ),
        ],
        nextCursor: 'cursor-before-local-dismissal',
        hasMore: false,
      ),
      EmailFetchPage(
        items: [
          _assignmentItem(
            providerMessageId: 'provider-message-b',
            sanitizedContentHash: 'f' * 64,
          ),
        ],
        nextCursor: 'cursor-after-suppressed-success',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    final successful = (await db.select(db.emailCandidates).get()).singleWhere(
        (candidate) => candidate.reviewState == 'ready_for_review');
    await DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
      clock: () => now,
    ).dismiss(ownerUserId: ownerUserId, candidateId: successful.id);

    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final tombstones = await db.select(db.emailDismissalTombstones).get();
    expect(tombstones, hasLength(2));
    expect(
      tombstones.map((row) => row.providerMessageIdHash).toSet(),
      {
        _messageHash('provider-message-a'),
        _messageHash('provider-message-b'),
      },
    );
    expect(await db.select(db.emailReconciliationReceipts).get(), hasLength(1));
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-after-suppressed-success');
  });

  test(
      'targeted success prunes a failed sibling suppressed by an offline dismissal without advancing cursor',
      () async {
    final service = EmailImportSyncService(
      db: db,
      connector: FakeEmailConnector([
        EmailFetchPage(
          items: [
            _assignmentItem(providerMessageId: 'provider-message-a'),
            _failedItem(
              providerMessageId: 'provider-message-b',
              errorCategory: EmailErrorCategory.timeout,
            ),
          ],
          nextCursor: 'cursor-before-targeted-suppression',
          hasMore: false,
        ),
      ]),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );
    await service.synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    final successful = (await db.select(db.emailCandidates).get()).singleWhere(
        (candidate) => candidate.reviewState == 'ready_for_review');
    await DriftEmailReviewStore(
      db: db,
      authenticatedUserId: () => ownerUserId,
      clock: () => now,
    ).dismiss(ownerUserId: ownerUserId, candidateId: successful.id);

    await service.persistTargetedRetryItem(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      item: _assignmentItem(
        providerMessageId: 'provider-message-b',
        sanitizedContentHash: 'f' * 64,
      ),
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    expect(await db.select(db.emailDismissalTombstones).get(), hasLength(2));
    expect(await db.select(db.emailReconciliationReceipts).get(), hasLength(1));
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-before-targeted-suppression');
  });

  test('a connector bound to another Gmail account is rejected', () async {
    final delegate = FakeEmailConnector([
      EmailFetchPage(
        items: [_assignmentItem()],
        nextCursor: 'must-not-be-used',
        hasMore: false,
      ),
    ]);
    final service = EmailImportSyncService(
      db: db,
      connector: BoundFakeEmailConnector(
        connectionId: '33333333-3333-4333-8333-333333333333',
        delegate: delegate,
      ),
      clock: () => now,
      authenticatedUserId: () => ownerUserId,
    );

    await expectLater(
      service.synchronize(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
      throwsStateError,
    );
    expect(delegate.requestedCursors, isEmpty);
  });
}

/// Test-only fake. Production code has no fake-connector selector or fallback.
final class FakeEmailConnector implements EmailConnector {
  FakeEmailConnector(this._script, {this.onFetch});

  final List<Object> _script;
  final FutureOr<void> Function()? onFetch;
  final List<String?> requestedCursors = [];
  var _index = 0;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async => const EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.connected,
      );

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {}

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async {
    requestedCursors.add(cursor);
    if (_index >= _script.length) {
      throw StateError('Fake connector script is exhausted.');
    }
    final result = _script[_index++];
    await onFetch?.call();
    if (result is EmailImportFailure) throw result;
    return result as EmailFetchPage;
  }
}

final class BoundFakeEmailConnector
    implements EmailConnector, ConnectionBoundEmailConnector {
  BoundFakeEmailConnector({
    required this.connectionId,
    required this.delegate,
  });

  @override
  final String connectionId;
  final FakeEmailConnector delegate;

  @override
  EmailProvider get provider => delegate.provider;

  @override
  Future<EmailConnectionState> connect() => delegate.connect();

  @override
  Future<void> disconnect({required bool deleteDerivedData}) =>
      delegate.disconnect(deleteDerivedData: deleteDerivedData);

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) =>
      delegate.fetchDelta(cursor: cursor);
}

Future<void> _seedConnection(
  AppDatabase db, {
  required String ownerUserId,
  required String connectionId,
  required DateTime now,
  String? cursor,
}) {
  return db.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: ownerUserId,
      provider: 'gmail',
      providerAccountHash: 'b' * 64,
      scopesJson: const Value('["gmail.readonly"]'),
      cursor: Value(cursor),
      state: const Value('connected'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ),
  );
}

Future<int> _disconnectConnection(
  AppDatabase db, {
  required String ownerUserId,
  required String connectionId,
  required DateTime disconnectedAt,
}) {
  return (db.update(db.emailConnections)
        ..where((row) =>
            row.id.equals(connectionId) & row.ownerUserId.equals(ownerUserId)))
      .write(
    EmailConnectionsCompanion(
      state: Value(EmailConnectionStatus.disconnected.wireName),
      cursor: const Value(null),
      errorCategory: const Value(null),
      retryAfter: const Value(null),
      disconnectedAt: Value(disconnectedAt),
      updatedAt: Value(disconnectedAt),
    ),
  );
}

EmailFetchItem _assignmentItem({
  String providerMessageId = 'provider-message-1',
  String sanitizedContentHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) {
  return EmailFetchItem(
    providerMessageId: providerMessageId,
    providerThreadId: 'provider-thread-1',
    receivedAt: DateTime.utc(2030, 4, 1, 1),
    sanitizedContentHash: sanitizedContentHash,
    evidenceExcerpts: const ['締切 4月10日 23:59'],
    candidate: EmailCandidatePayload(
      schemaVersion: '1.0',
      candidateType: EmailCandidateType.assignment,
      title: 'レポート課題',
      courseHint: const EmailCourseHint(name: '情報数学', code: 'CS101'),
      due: EmailDueCandidate(
        at: DateTime.utc(2030, 4, 10, 14, 59),
        timezone: 'Asia/Tokyo',
        rawText: '4月10日 23:59',
      ),
      confidence: const EmailCandidateConfidence(
        overall: 0.9,
        title: 0.9,
        course: 0.8,
        dateTime: 0.9,
      ),
      requiresUserConfirmation: true,
      suggestedRemindersMinutes: const [1440, 180],
      evidence: const [
        EmailCandidateEvidence(field: 'due.at', text: '締切 4月10日 23:59'),
      ],
    ),
  );
}

EmailFetchItem _failedItem({
  required EmailErrorCategory errorCategory,
  String providerMessageId = 'provider-message-1',
  String? providerThreadId,
}) {
  return EmailFetchItem(
    providerMessageId: providerMessageId,
    providerThreadId: providerThreadId,
    receivedAt: DateTime.utc(2030, 4, 1, 1),
    sanitizedContentHash:
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
    evidenceExcerpts: const [],
    candidate: null,
    errorCategory: errorCategory,
  );
}

String _messageHash(String providerMessageId) {
  return emailProviderIdentifierHash(
    kind: 'message',
    provider: 'gmail',
    providerAccountHash: 'b' * 64,
    rawIdentifier: providerMessageId,
  );
}
