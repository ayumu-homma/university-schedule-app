import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database.dart';
import '../../../local_db/email_import_identity.dart';
import '../domain/email_review_models.dart';
import 'email_connector_binding.dart';
import 'email_import_sync_service.dart';
import 'supabase_email_connector.dart';

typedef EmailReviewConnectorFactory = EmailConnector Function(
  String connectionId,
);
typedef EmailConnectionMetadataLoader = Future<Map<String, dynamic>?> Function(
  String connectionId,
);
typedef EmailAuthorizationResolutionLoader
    = Future<EmailAuthorizationResolution> Function(
  String requestedConnectionId,
  String callbackCorrelationId,
);
typedef EmailAuthorizationLauncher = Future<bool> Function(Uri uri);
typedef EmailAccountDataDeleter = Future<void> Function();

/// Production-only network adapter for review UI actions.
///
/// No connector is constructed while the feature flag is disabled. A future
/// successful OAuth response is accepted only after the authenticated client
/// can read back a matching safe metadata row; otherwise connection fails
/// closed instead of inventing provider account metadata locally.
class ProductionEmailReviewRemoteActions
    implements EmailReviewRemoteActions, CorrelatedEmailAuthorizationActions {
  ProductionEmailReviewRemoteActions({
    required this.db,
    required this.config,
    required this.client,
    required this.authenticatedUserId,
    this.lease,
    DateTime Function()? clock,
    Uuid uuid = const Uuid(),
    EmailReviewConnectorFactory? connectorFactory,
    EmailConnectionMetadataLoader? metadataLoader,
    EmailAuthorizationResolutionLoader? authorizationResolutionLoader,
    EmailAuthorizationLauncher? authorizationLauncher,
    EmailAccountDataDeleter? accountDataDeleter,
  })  : _clock = clock ?? DateTime.now,
        _uuid = uuid,
        _connectorFactory = connectorFactory,
        _metadataLoader = metadataLoader,
        _authorizationResolutionLoader = authorizationResolutionLoader,
        _authorizationLauncher =
            authorizationLauncher ?? _launchAuthorizationExternally,
        _accountDataDeleter = accountDataDeleter;

  final AppDatabase db;
  final AppConfig config;
  final SupabaseClient? client;
  final String? Function() authenticatedUserId;
  final ScopedContextLease? lease;
  final DateTime Function() _clock;
  final Uuid _uuid;
  final EmailReviewConnectorFactory? _connectorFactory;
  final EmailConnectionMetadataLoader? _metadataLoader;
  final EmailAuthorizationResolutionLoader? _authorizationResolutionLoader;
  final EmailAuthorizationLauncher _authorizationLauncher;
  final EmailAccountDataDeleter? _accountDataDeleter;

  @override
  Future<EmailConnectionState> connect({required String ownerUserId}) async {
    _requireEnabledOwner(ownerUserId);
    final connectionId = _uuid.v4();
    final state = await _connector(connectionId).connect();
    if (state.status == EmailConnectionStatus.connected) {
      return _hydrateConnectionMetadata(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        allowedStatuses: const {EmailConnectionStatus.connected},
      );
    }
    if (state.status == EmailConnectionStatus.connecting) {
      final challenge = state.oauthChallenge;
      if (challenge == null) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final persisted = await _hydrateConnectionMetadata(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        allowedStatuses: const {
          EmailConnectionStatus.connecting,
          EmailConnectionStatus.connected,
        },
      );
      _requireEnabledOwner(ownerUserId);
      final launched = await _authorizationLauncher(
        challenge.authorizationUri,
      );
      _requireEnabledOwner(ownerUserId);
      if (!launched) {
        throw const EmailReviewActionException(EmailErrorCategory.unsafeUrl);
      }
      return persisted.status == EmailConnectionStatus.connected
          ? persisted
          : state;
    }
    return state;
  }

  @override
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  }) {
    _requireEnabledOwner(ownerUserId);
    return _hydrateConnectionMetadata(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
      allowedStatuses: const {
        EmailConnectionStatus.connecting,
        EmailConnectionStatus.connected,
        EmailConnectionStatus.reauthRequired,
        EmailConnectionStatus.rateLimited,
        EmailConnectionStatus.failed,
        EmailConnectionStatus.disconnected,
      },
    );
  }

  @override
  Future<EmailConnectionState> checkCorrelatedAuthorization({
    required String ownerUserId,
    required String requestedConnectionId,
    required String callbackCorrelationId,
  }) async {
    _requireEnabledOwner(ownerUserId);
    final injectedLoader = _authorizationResolutionLoader;
    final resolution = injectedLoader != null
        ? await injectedLoader(
            requestedConnectionId,
            callbackCorrelationId,
          )
        : await _productionConnector(requestedConnectionId).checkAuthorization(
            callbackCorrelationId: callbackCorrelationId,
          );
    _requireEnabledOwner(ownerUserId);
    final hydrated = await _hydrateConnectionMetadata(
      ownerUserId: ownerUserId,
      connectionId: resolution.effectiveConnectionId,
      allowedStatuses: const {
        EmailConnectionStatus.connecting,
        EmailConnectionStatus.connected,
        EmailConnectionStatus.reauthRequired,
        EmailConnectionStatus.rateLimited,
        EmailConnectionStatus.failed,
        EmailConnectionStatus.disconnected,
      },
      staleRequestedConnectionId: requestedConnectionId,
    );
    if (hydrated.status != resolution.connection.status) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return hydrated;
  }

  @override
  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  }) async {
    _requireEnabledOwner(ownerUserId);
    final connector = _connector(connectionId);
    await EmailImportSyncService(
      db: db,
      connector: connector,
      clock: _clock,
      authenticatedUserId: authenticatedUserId,
      lease: lease,
    ).synchronize(ownerUserId: ownerUserId, connectionId: connectionId);
  }

  @override
  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  }) async {
    _requireEnabledOwner(ownerUserId);
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: candidateId,
    );
    if (candidate == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final EmailErrorCategory failureCategory;
    try {
      failureCategory = EmailErrorCategory.fromWire(candidate.errorCategory!);
    } on Object {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    if (candidate.reviewState != EmailCandidateReviewState.failed.wireName ||
        !failureCategory.isCandidateRetryable) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final source = await db.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: candidate.sourceId,
    );
    if (source == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final connection = await db.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: source.connectionId,
    );
    if (connection == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final retryIdempotencyKey = emailProviderIdentifierHash(
      kind: 'candidate-retry-idempotency',
      provider: connection.provider,
      providerAccountHash: connection.providerAccountHash,
      // Bind the key to every durable input that defines this retry. A lost
      // response reuses the key while local state is unchanged, but either a
      // source-content change or a persisted retry result advances the key.
      rawIdentifier: [
        connection.id,
        source.id,
        source.providerMessageId,
        source.sanitizedContentHash,
        candidate.id,
        candidate.updatedAt.toUtc().toIso8601String(),
      ].join('\u0000'),
    );
    final providerMessageIdHash = emailProviderIdentifierHash(
      kind: 'message',
      provider: connection.provider,
      providerAccountHash: connection.providerAccountHash,
      rawIdentifier: source.providerMessageId,
    );
    final connector = _connector(source.connectionId);
    if (connector is! TargetedEmailRetryConnector) {
      throw const EmailReviewActionException(
        EmailErrorCategory.configurationMissing,
      );
    }
    final targetedConnector = connector as TargetedEmailRetryConnector;
    final retryResult = await targetedConnector.retryCandidate(
      providerMessageId: source.providerMessageId,
      expectedProviderMessageIdHash: providerMessageIdHash,
      expectedSanitizedContentHash: source.sanitizedContentHash,
      retryIdempotencyKey: retryIdempotencyKey,
    );
    _requireEnabledOwner(ownerUserId);
    final nextCandidateVersionAt =
        candidate.updatedAt.toUtc().add(const Duration(seconds: 1));
    final syncService = EmailImportSyncService(
      db: db,
      connector: connector,
      clock: () {
        final now = _clock().toUtc();
        return now.isBefore(nextCandidateVersionAt)
            ? nextCandidateVersionAt
            : now;
      },
      authenticatedUserId: authenticatedUserId,
      lease: lease,
    );
    switch (retryResult.outcome) {
      case TargetedEmailRetryOutcome.persisted:
        await syncService.persistTargetedRetryItem(
          ownerUserId: ownerUserId,
          connectionId: source.connectionId,
          item: retryResult.item!,
        );
      case TargetedEmailRetryOutcome.suppressed:
        await syncService.persistTargetedRetrySuppression(
          ownerUserId: ownerUserId,
          connectionId: source.connectionId,
          suppression: retryResult.suppression!,
        );
    }
  }

  @override
  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) async {
    _requireEnabledOwner(ownerUserId);
    await _connector(connectionId).disconnect(
      deleteDerivedData: deleteDerivedData,
    );
    _requireEnabledOwner(ownerUserId);
    if (deleteDerivedData) {
      await db.emailImportDao.deleteDerivedDataForConnection(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      );
      return;
    }
    final now = _clock().toUtc();
    final updated = await (db.update(db.emailConnections)
          ..where(
            (row) =>
                row.id.equals(connectionId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .write(
      EmailConnectionsCompanion(
        state: Value(EmailConnectionStatus.disconnected.wireName),
        cursor: const Value(null),
        errorCategory: const Value(null),
        retryAfter: const Value(null),
        disconnectedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    if (updated != 1) {
      throw const EmailReviewActionException(
        EmailErrorCategory.internalError,
      );
    }
  }

  @override
  Future<void> deleteAccountData({required String ownerUserId}) async {
    _requireEnabledOwner(ownerUserId);
    final injectedDeleter = _accountDataDeleter;
    if (injectedDeleter != null) {
      await injectedDeleter();
    } else {
      final safeClient = client;
      if (safeClient == null) {
        throw const EmailReviewActionException(
          EmailErrorCategory.configurationMissing,
        );
      }
      await SupabaseEmailConnector(
        emailImportEnabled: true,
        connectionId: _uuid.v4(),
        client: safeClient,
        expectedOAuthClientId: config.emailImportGmailClientId,
        expectedOAuthRedirectUri: config.emailImportOAuthRedirectUri,
      ).deleteAccountData();
    }
    _requireEnabledOwner(ownerUserId);
    await db.transaction(() async {
      _requireEnabledOwner(ownerUserId);
      final connections = await (db.select(db.emailConnections)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get();
      for (final connection in connections) {
        await db.emailImportDao.deleteDerivedDataForConnection(
          ownerUserId: ownerUserId,
          connectionId: connection.id,
        );
      }
      await (db.delete(db.emailDismissalTombstones)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .go();
      await (db.delete(db.emailReconciliationReceipts)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .go();
      // A changed active account rolls the local cleanup back. Canonical
      // Assignment, Exam and Event tables are never touched by this action.
      _requireEnabledOwner(ownerUserId);
    });
  }

  EmailConnector _connector(String connectionId) {
    final connectorFactory = _connectorFactory;
    if (connectorFactory != null) return connectorFactory(connectionId);
    final safeClient = client;
    if (safeClient == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.configurationMissing,
      );
    }
    return _productionConnector(connectionId);
  }

  SupabaseEmailConnector _productionConnector(String connectionId) {
    final safeClient = client;
    if (safeClient == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.configurationMissing,
      );
    }
    return SupabaseEmailConnector(
      emailImportEnabled: true,
      connectionId: connectionId,
      client: safeClient,
      expectedOAuthClientId: config.emailImportGmailClientId,
      expectedOAuthRedirectUri: config.emailImportOAuthRedirectUri,
    );
  }

  Future<EmailConnectionState> _hydrateConnectionMetadata({
    required String ownerUserId,
    required String connectionId,
    required Set<EmailConnectionStatus> allowedStatuses,
    String? staleRequestedConnectionId,
  }) async {
    final metadataLoader = _metadataLoader;
    final safeClient = client;
    if (metadataLoader == null && safeClient == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.configurationMissing,
      );
    }
    try {
      final raw = metadataLoader != null
          ? await metadataLoader(connectionId)
          : await safeClient!
              .from('email_connections')
              .select(_metadataSelection)
              .eq('id', connectionId)
              .maybeSingle();
      _requireEnabledOwner(ownerUserId);
      if (raw == null) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final safeRaw = raw;
      final status = _connectionStatus(safeRaw['connection_state']);
      final effectiveConnectionId = _connectionId(safeRaw['id']);
      if (safeRaw['owner_user_id'] != ownerUserId ||
          effectiveConnectionId != connectionId ||
          !allowedStatuses.contains(status) ||
          safeRaw['provider'] != EmailProvider.gmail.wireName) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      final accountHash = _boundedHash(safeRaw['provider_account_hash']);
      final scopes = _boundedScopes(safeRaw['authorized_scopes']);
      final createdAt = _timestamp(safeRaw['created_at']);
      final updatedAt = _timestamp(safeRaw['updated_at']);
      final errorCategory =
          _optionalErrorCategory(safeRaw['last_error_category']);
      final retryAfter = _optionalTimestamp(safeRaw['retry_after_at']);
      if ((status == EmailConnectionStatus.rateLimited) !=
          (retryAfter != null)) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      if (status == EmailConnectionStatus.failed && errorCategory == null) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      await db.transaction(() async {
        _requireEnabledOwner(ownerUserId);
        await db.emailImportDao.upsertConnection(
          ownerUserId: ownerUserId,
          connection: EmailConnectionsCompanion.insert(
            id: effectiveConnectionId,
            ownerUserId: ownerUserId,
            provider: EmailProvider.gmail.wireName,
            providerAccountHash: accountHash,
            scopesJson: Value(jsonEncode(scopes)),
            cursor: Value(_optionalBoundedString(safeRaw['sync_cursor'], 4096)),
            state: Value(status.wireName),
            errorCategory: Value(errorCategory?.wireName),
            retryAfter: Value(retryAfter),
            lastSyncedAt: Value(_optionalTimestamp(safeRaw['last_synced_at'])),
            disconnectedAt: Value(
              _optionalTimestamp(safeRaw['disconnected_at']),
            ),
            createdAt: Value(createdAt),
            updatedAt: Value(updatedAt),
          ),
        );
        if (staleRequestedConnectionId != null &&
            staleRequestedConnectionId != effectiveConnectionId) {
          await (db.delete(db.emailConnections)
                ..where(
                  (row) =>
                      row.id.equals(staleRequestedConnectionId) &
                      row.ownerUserId.equals(ownerUserId),
                ))
              .go();
        }
        // Throwing here rolls the transaction back if the active account
        // changed while Drift yielded during the local persistence step.
        _requireEnabledOwner(ownerUserId);
      });
      final rawRetryDuration = retryAfter?.difference(_clock().toUtc());
      final retryDuration =
          rawRetryDuration != null && rawRetryDuration.isNegative
              ? Duration.zero
              : rawRetryDuration;
      return EmailConnectionState(
        provider: EmailProvider.gmail,
        status: status,
        errorCategory:
            status == EmailConnectionStatus.failed ? errorCategory : null,
        retryAfter: retryDuration,
        connectedAt: _optionalTimestamp(safeRaw['connected_at']),
      );
    } on EmailReviewActionException {
      rethrow;
    } on Object {
      throw const EmailReviewActionException(
        EmailErrorCategory.providerUnavailable,
      );
    }
  }

  String _connectionId(Object? value) {
    if (value is! String || !_uuidPattern.hasMatch(value)) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return value;
  }

  EmailConnectionStatus _connectionStatus(Object? value) {
    if (value is! String) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    try {
      return EmailConnectionStatus.fromWire(value);
    } on Object {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
  }

  EmailErrorCategory? _optionalErrorCategory(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    try {
      return EmailErrorCategory.fromWire(value);
    } on Object {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
  }

  String _boundedHash(Object? value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return value;
  }

  List<String> _boundedScopes(Object? value) {
    if (value is! List || value.length != 1) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final scopes = <String>[];
    for (final scope in value) {
      if (scope is! String ||
          scope.isEmpty ||
          scope != scope.trim() ||
          scope.length > 256) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      scopes.add(scope);
    }
    if (scopes.single != _gmailReadonlyScope) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return scopes;
  }

  String? _optionalBoundedString(Object? value, int maximumCharacters) {
    if (value == null) return null;
    if (value is! String ||
        value.isEmpty ||
        value != value.trim() ||
        value.length > maximumCharacters) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return value;
  }

  DateTime _timestamp(Object? value) {
    final timestamp = _optionalTimestamp(value);
    if (timestamp == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return timestamp;
  }

  DateTime? _optionalTimestamp(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    final timestamp = DateTime.tryParse(value);
    if (timestamp == null) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    return timestamp.toUtc();
  }

  void _requireEnabledOwner(String ownerUserId) {
    try {
      lease?.check(ownerUserId: ownerUserId, database: db);
    } on ScopedContextLeaseException {
      throw const EmailReviewActionException(
        EmailErrorCategory.authorizationRevoked,
      );
    }
    if (!config.emailImportEnabled) {
      throw const EmailReviewActionException(
        EmailErrorCategory.configurationMissing,
      );
    }
    if (ownerUserId.trim().isEmpty || authenticatedUserId() != ownerUserId) {
      throw const EmailReviewActionException(
        EmailErrorCategory.authorizationRevoked,
      );
    }
  }

  static const _metadataSelection =
      'id,owner_user_id,provider,provider_account_hash,'
      'authorized_scopes,sync_cursor,connection_state,'
      'last_error_category,retry_after_at,connected_at,'
      'last_synced_at,disconnected_at,created_at,updated_at';
  static const _gmailReadonlyScope =
      'https://www.googleapis.com/auth/gmail.readonly';

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
}

Future<bool> _launchAuthorizationExternally(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
