import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_connector_binding.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/production_email_review_actions.dart';
import 'package:university_schedule_mobile/features/email_import/data/supabase_email_connector.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:uuid/uuid.dart';

const _gmailClientId = 'mobile-public.apps.googleusercontent.com';

void main() {
  const ownerA = '11111111-1111-4111-8111-111111111111';
  const ownerB = '22222222-2222-4222-8222-222222222222';
  final now = DateTime.utc(2030, 4, 5, 6, 7, 8);

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('account switch during connection persistence rolls back local row',
      () async {
    var ownerReads = 0;
    String? activeOwner() {
      ownerReads++;
      // connect preflight, remote readback, and transaction preflight pass;
      // the post-write check observes the simulated account switch.
      return ownerReads <= 3 ? ownerA : ownerB;
    }

    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: activeOwner,
      clock: () => now,
      connectorFactory: (_) => const _ConnectedTestConnector(),
      metadataLoader: (connectionId) async => {
        'id': connectionId,
        'owner_user_id': ownerA,
        'provider': EmailProvider.gmail.wireName,
        'provider_account_hash': List.filled(64, 'a').join(),
        'authorized_scopes': const [
          'https://www.googleapis.com/auth/gmail.readonly',
        ],
        'sync_cursor': null,
        'connection_state': EmailConnectionStatus.connected.wireName,
        'last_error_category': null,
        'retry_after_at': null,
        'connected_at': now.toIso8601String(),
        'last_synced_at': null,
        'disconnected_at': null,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
    );

    await expectLater(
      actions.connect(ownerUserId: ownerA),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.authorizationRevoked,
        ),
      ),
    );

    expect(ownerReads, 4);
    expect(await db.select(db.emailConnections).get(), isEmpty);
  });

  test('OAuth handoff launches externally and safe metadata can be refreshed',
      () async {
    var connected = false;
    Uri? launchedUri;
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      connectorFactory: (_) => _ConnectingTestConnector(now: now),
      metadataLoader: (connectionId) async => _metadata(
        connectionId: connectionId,
        ownerUserId: ownerA,
        now: now,
        status: connected
            ? EmailConnectionStatus.connected
            : EmailConnectionStatus.connecting,
      ),
      authorizationLauncher: (uri) async {
        launchedUri = uri;
        return true;
      },
    );

    final started = await actions.connect(ownerUserId: ownerA);

    expect(started.status, EmailConnectionStatus.connecting);
    expect(launchedUri?.scheme, 'https');
    expect(launchedUri?.host, 'accounts.google.com');
    final pending = await db.select(db.emailConnections).getSingle();
    expect(pending.state, EmailConnectionStatus.connecting.wireName);

    connected = true;
    final completed = await actions.checkAuthorization(
      ownerUserId: ownerA,
      connectionId: pending.id,
    );

    expect(completed.status, EmailConnectionStatus.connected);
    expect(
      (await db.select(db.emailConnections).getSingle()).state,
      EmailConnectionStatus.connected.wireName,
    );
  });

  test('account email-data deletion is distinct and clears local connections',
      () async {
    await db.emailImportDao.upsertConnection(
      ownerUserId: ownerA,
      connection: EmailConnectionsCompanion.insert(
        id: '33333333-3333-4333-8333-333333333333',
        ownerUserId: ownerA,
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: 'a' * 64,
      ),
    );
    var remoteDeleteCalls = 0;
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      accountDataDeleter: () async => remoteDeleteCalls++,
    );

    await actions.deleteAccountData(ownerUserId: ownerA);

    expect(remoteDeleteCalls, 1);
    expect(await db.select(db.emailConnections).get(), isEmpty);
  });

  test('authorization check hydrates effective duplicate-account connection',
      () async {
    const requestedId = '33333333-3333-4333-8333-333333333333';
    const effectiveId = '44444444-4444-4444-8444-444444444444';
    const unrelatedNewerId = '55555555-5555-4555-8555-555555555555';
    const callbackCorrelationId = '66666666-6666-4666-8666-666666666666';
    await db.emailImportDao.upsertConnection(
      ownerUserId: ownerA,
      connection: EmailConnectionsCompanion.insert(
        id: requestedId,
        ownerUserId: ownerA,
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: 'b' * 64,
        state: Value(EmailConnectionStatus.connecting.wireName),
      ),
    );
    await db.emailImportDao.upsertConnection(
      ownerUserId: ownerA,
      connection: EmailConnectionsCompanion.insert(
        id: unrelatedNewerId,
        ownerUserId: ownerA,
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: 'c' * 64,
        state: Value(EmailConnectionStatus.connected.wireName),
        updatedAt: Value(now.add(const Duration(hours: 1))),
      ),
    );
    final metadataReads = <String>[];
    final resolutionReads = <(String, String)>[];
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      metadataLoader: (connectionId) async {
        metadataReads.add(connectionId);
        if (connectionId != effectiveId) return null;
        return _metadata(
          connectionId: effectiveId,
          ownerUserId: ownerA,
          now: now,
          status: EmailConnectionStatus.connected,
        );
      },
      authorizationResolutionLoader: (requested, correlation) async {
        resolutionReads.add((requested, correlation));
        return const EmailAuthorizationResolution(
          effectiveConnectionId: effectiveId,
          connection: EmailConnectionState(
            provider: EmailProvider.gmail,
            status: EmailConnectionStatus.connected,
          ),
        );
      },
    );

    await expectLater(
      actions.checkAuthorization(
        ownerUserId: ownerA,
        connectionId: requestedId,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
    expect(metadataReads, [requestedId]);
    metadataReads.clear();

    final state = await actions.checkCorrelatedAuthorization(
      ownerUserId: ownerA,
      requestedConnectionId: requestedId,
      callbackCorrelationId: callbackCorrelationId,
    );

    expect(state.status, EmailConnectionStatus.connected);
    expect(resolutionReads, [(requestedId, callbackCorrelationId)]);
    expect(metadataReads, [effectiveId]);
    final localRows = await db.select(db.emailConnections).get();
    expect(localRows, hasLength(2));
    expect(localRows.map((row) => row.id), contains(unrelatedNewerId));
    expect(localRows.map((row) => row.id), isNot(contains(requestedId)));
    final local = localRows.singleWhere((row) => row.id == effectiveId);
    expect(local.id, effectiveId);
    expect(local.ownerUserId, ownerA);
    expect(local.state, EmailConnectionStatus.connected.wireName);
  });

  test('authorization status clamps an elapsed retry window to zero', () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      metadataLoader: (_) async {
        final value = _metadata(
          connectionId: connectionId,
          ownerUserId: ownerA,
          now: now,
          status: EmailConnectionStatus.rateLimited,
        );
        value['retry_after_at'] =
            now.subtract(const Duration(seconds: 1)).toIso8601String();
        return value;
      },
    );

    final state = await actions.checkAuthorization(
      ownerUserId: ownerA,
      connectionId: connectionId,
    );

    expect(state.status, EmailConnectionStatus.rateLimited);
    expect(state.retryAfter, Duration.zero);
  });

  test('feature flag fails closed before OAuth launch or account deletion',
      () async {
    var launches = 0;
    var deletions = 0;
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.demoForTesting(),
      client: null,
      authenticatedUserId: () => ownerA,
      authorizationLauncher: (_) async {
        launches++;
        return true;
      },
      accountDataDeleter: () async => deletions++,
    );

    await expectLater(
      actions.connect(ownerUserId: ownerA),
      throwsA(isA<EmailReviewActionException>()),
    );
    await expectLater(
      actions.deleteAccountData(ownerUserId: ownerA),
      throwsA(isA<EmailReviewActionException>()),
    );
    expect(launches, 0);
    expect(deletions, 0);
  });

  test('candidate retry targets one provider message without moving cursor',
      () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.timeout,
    );
    final connector = _TargetedTestConnector();
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now.add(const Duration(minutes: 1)),
      connectorFactory: (_) => connector,
    );

    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );

    expect(connector.retriedMessageIds, ['provider-message-retry']);
    expect(connector.expectedContentHashes, ['f' * 64]);
    expect(connector.retryIdempotencyKeys.single, hasLength(64));
    expect(connector.fetchDeltaCalls, 0);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerA,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-before-retry');
    final source = (await db.select(db.emailSources).get()).single;
    expect(source.processingState, 'processed');
    expect(source.errorCategory, isNull);
    final candidate = (await db.select(db.emailCandidates).get()).single;
    expect(candidate.reviewState, 'ready_for_review');
    expect(candidate.errorCategory, isNull);
  });

  test('suppressed retry prunes the failure with no reconciliation outbox',
      () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.timeout,
    );
    final connector = _TargetedTestConnector(
      suppressionReason: EmailFetchSuppressionReason.dismissed,
    );
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now.add(const Duration(minutes: 1)),
      connectorFactory: (_) => connector,
    );

    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );

    expect(await db.select(db.emailSources).get(), isEmpty);
    expect(await db.select(db.emailCandidates).get(), isEmpty);
    final tombstones = await db.select(db.emailDismissalTombstones).get();
    expect(tombstones, hasLength(1));
    expect(tombstones.single.id, candidateId);
    expect(await db.select(db.emailReconciliationReceipts).get(), isEmpty);
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerA,
      connectionId: connectionId,
    );
    expect(connection?.cursor, 'cursor-before-retry');
  });

  test('permanent unsafe-content failure cannot be retried', () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.unsafeContent,
    );
    final connector = _TargetedTestConnector();
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      connectorFactory: (_) => connector,
    );

    await expectLater(
      actions.retryCandidate(
        ownerUserId: ownerA,
        candidateId: candidateId,
      ),
      throwsA(
        isA<EmailReviewActionException>().having(
          (error) => error.category,
          'category',
          EmailErrorCategory.validationFailed,
        ),
      ),
    );
    expect(connector.retriedMessageIds, isEmpty);
    expect(connector.fetchDeltaCalls, 0);
  });

  test('lost targeted-retry response reuses the same idempotency key',
      () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.timeout,
    );
    final connector = _TargetedTestConnector(failFirstRetry: true);
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      connectorFactory: (_) => connector,
    );

    await expectLater(
      actions.retryCandidate(
        ownerUserId: ownerA,
        candidateId: candidateId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );

    expect(connector.retryIdempotencyKeys, hasLength(2));
    expect(
      connector.retryIdempotencyKeys.toSet(),
      hasLength(1),
    );
    expect(connector.expectedContentHashes.toSet(), {'f' * 64});
  });

  test('same-second source hash change rolls the retry idempotency key',
      () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.timeout,
    );
    final connector = _TargetedTestConnector(failFirstRetry: true);
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      connectorFactory: (_) => connector,
    );

    await expectLater(
      actions.retryCandidate(
        ownerUserId: ownerA,
        candidateId: candidateId,
      ),
      throwsA(isA<EmailImportFailure>()),
    );
    final source = (await db.select(db.emailSources).get()).single;
    await (db.update(db.emailSources)..where((row) => row.id.equals(source.id)))
        .write(
      EmailSourcesCompanion(
        sanitizedContentHash: Value('1' * 64),
        // Keep the timestamp deliberately unchanged: the content hash itself
        // must prevent reuse of the first server-side receipt.
        updatedAt: Value(source.updatedAt),
      ),
    );

    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );

    expect(connector.retryIdempotencyKeys, hasLength(2));
    expect(connector.retryIdempotencyKeys.toSet(), hasLength(2));
    expect(connector.expectedContentHashes, ['f' * 64, '1' * 64]);
  });

  test('persisted same-hash failure advances the manual retry key', () async {
    const connectionId = '33333333-3333-4333-8333-333333333333';
    final candidateId = await _seedFailedCandidate(
      db,
      ownerUserId: ownerA,
      connectionId: connectionId,
      now: now,
      errorCategory: EmailErrorCategory.timeout,
    );
    final connector = _TargetedTestConnector(
      persistedContentHash: 'f' * 64,
      persistedErrorCategory: EmailErrorCategory.timeout,
    );
    final actions = ProductionEmailReviewRemoteActions(
      db: db,
      config: AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: _gmailClientId,
      ),
      client: null,
      authenticatedUserId: () => ownerA,
      clock: () => now,
      connectorFactory: (_) => connector,
    );

    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );
    await actions.retryCandidate(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );

    expect(connector.retryIdempotencyKeys, hasLength(2));
    expect(connector.retryIdempotencyKeys.toSet(), hasLength(2));
    expect(connector.expectedContentHashes.toSet(), {'f' * 64});
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerA,
      candidateId: candidateId,
    );
    expect(candidate?.reviewState, EmailCandidateReviewState.failed.wireName);
    expect(
      candidate?.updatedAt.toUtc(),
      now.add(const Duration(seconds: 2)),
    );
  });
}

Future<String> _seedFailedCandidate(
  AppDatabase db, {
  required String ownerUserId,
  required String connectionId,
  required DateTime now,
  required EmailErrorCategory errorCategory,
}) async {
  const providerMessageId = 'provider-message-retry';
  const uuid = Uuid();
  final sourceId = uuid.v5(
    Namespace.url.value,
    ['source', ownerUserId, connectionId, providerMessageId].join('\u0000'),
  );
  final candidateId = uuid.v5(
    Namespace.url.value,
    ['candidate', ownerUserId, sourceId].join('\u0000'),
  );
  await db.emailImportDao.upsertConnection(
    ownerUserId: ownerUserId,
    connection: EmailConnectionsCompanion.insert(
      id: connectionId,
      ownerUserId: ownerUserId,
      provider: EmailProvider.gmail.wireName,
      providerAccountHash: 'a' * 64,
      cursor: const Value('cursor-before-retry'),
      state: Value(EmailConnectionStatus.connected.wireName),
      createdAt: Value(now),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertSource(
    ownerUserId: ownerUserId,
    source: EmailSourcesCompanion.insert(
      id: sourceId,
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      providerMessageId: providerMessageId,
      providerThreadId: 'failed:${'d' * 64}',
      receivedAt: DateTime.utc(2030, 4, 1, 1),
      sanitizedContentHash: 'f' * 64,
      evidenceExcerptsJson: const Value('[]'),
      processingState: const Value('failed'),
      errorCategory: Value(errorCategory.wireName),
      createdAt: Value(now),
      updatedAt: Value(now),
    ),
  );
  await db.emailImportDao.upsertCandidate(
    ownerUserId: ownerUserId,
    candidate: EmailCandidatesCompanion.insert(
      id: candidateId,
      ownerUserId: ownerUserId,
      sourceId: sourceId,
      schemaVersion: '1.0',
      candidateType: EmailCandidateType.unknown.wireName,
      normalizedPayloadJson: '{}',
      reviewState: Value(EmailCandidateReviewState.failed.wireName),
      semanticFingerprint: 'e' * 64,
      errorCategory: Value(errorCategory.wireName),
      createdAt: Value(now),
      updatedAt: Value(now),
    ),
  );
  return candidateId;
}

Map<String, dynamic> _metadata({
  required String connectionId,
  required String ownerUserId,
  required DateTime now,
  required EmailConnectionStatus status,
}) {
  return {
    'id': connectionId,
    'owner_user_id': ownerUserId,
    'provider': EmailProvider.gmail.wireName,
    'provider_account_hash': 'a' * 64,
    'authorized_scopes': const [
      'https://www.googleapis.com/auth/gmail.readonly',
    ],
    'sync_cursor': null,
    'connection_state': status.wireName,
    'last_error_category': null,
    'retry_after_at': null,
    'connected_at': status == EmailConnectionStatus.connected
        ? now.toIso8601String()
        : null,
    'last_synced_at': null,
    'disconnected_at': null,
    'created_at': now.toIso8601String(),
    'updated_at': now.toIso8601String(),
  };
}

final class _ConnectedTestConnector implements EmailConnector {
  const _ConnectedTestConnector();

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
  Future<EmailFetchPage> fetchDelta({String? cursor}) async =>
      const EmailFetchPage(items: [], nextCursor: null, hasMore: false);
}

final class _ConnectingTestConnector implements EmailConnector {
  const _ConnectingTestConnector({required this.now});

  final DateTime now;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async => EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.connecting,
        oauthChallenge: EmailOAuthAuthorizationChallenge(
          authorizationUri: Uri.parse(
            'https://accounts.google.com/o/oauth2/v2/auth?public=challenge',
          ),
          codeChallenge: 'c' * 43,
          expiresAt: now.add(const Duration(minutes: 10)),
        ),
      );

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {}

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async =>
      const EmailFetchPage(items: [], nextCursor: null, hasMore: false);
}

final class _TargetedTestConnector
    implements EmailConnector, TargetedEmailRetryConnector {
  _TargetedTestConnector({
    this.failFirstRetry = false,
    this.suppressionReason,
    this.persistedContentHash = _defaultPersistedContentHash,
    this.persistedErrorCategory,
  });

  static const _defaultPersistedContentHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  final bool failFirstRetry;
  final EmailFetchSuppressionReason? suppressionReason;
  final String persistedContentHash;
  final EmailErrorCategory? persistedErrorCategory;
  final retriedMessageIds = <String>[];
  final expectedContentHashes = <String>[];
  final retryIdempotencyKeys = <String>[];
  var fetchDeltaCalls = 0;

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
    fetchDeltaCalls++;
    return const EmailFetchPage(items: [], nextCursor: null, hasMore: false);
  }

  @override
  Future<TargetedEmailRetryResult> retryCandidate({
    required String providerMessageId,
    required String expectedProviderMessageIdHash,
    required String expectedSanitizedContentHash,
    required String retryIdempotencyKey,
  }) async {
    retriedMessageIds.add(providerMessageId);
    expectedContentHashes.add(expectedSanitizedContentHash);
    retryIdempotencyKeys.add(retryIdempotencyKey);
    if (failFirstRetry && retriedMessageIds.length == 1) {
      throw EmailImportFailure.timeout();
    }
    final suppression = suppressionReason;
    if (suppression != null) {
      return TargetedEmailRetryResult.suppressed(
        EmailFetchSuppression(
          providerMessageIdHash: expectedProviderMessageIdHash,
          reason: suppression,
        ),
      );
    }
    return TargetedEmailRetryResult.persisted(
      EmailFetchItem(
        providerMessageId: providerMessageId,
        providerThreadId: 'provider-thread-retry',
        receivedAt: DateTime.utc(2030, 4, 1, 1),
        sanitizedContentHash: persistedContentHash,
        evidenceExcerpts: persistedErrorCategory == null
            ? const ['締切 4月10日 23:59']
            : const [],
        candidate: persistedErrorCategory == null
            ? EmailCandidatePayload(
                schemaVersion: '1.0',
                candidateType: EmailCandidateType.assignment,
                title: '再処理された課題',
                courseHint: const EmailCourseHint(),
                due: EmailDueCandidate(
                  at: DateTime.utc(2030, 4, 10, 14, 59),
                  timezone: 'Asia/Tokyo',
                ),
                confidence: const EmailCandidateConfidence(
                  overall: 0.9,
                  title: 0.9,
                  course: 0.5,
                  dateTime: 0.9,
                ),
                requiresUserConfirmation: true,
              )
            : null,
        errorCategory: persistedErrorCategory,
      ),
    );
  }
}
