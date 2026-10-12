import 'dart:async';
import 'dart:io';

import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'email_connector_binding.dart';
import 'email_import_failure.dart';

typedef EmailFunctionInvoker = Future<Object?> Function(
  Map<String, Object?> body,
);

/// Authenticated mobile adapter for the trusted `email-import` Edge endpoint.
///
/// The request never includes an owner ID, OAuth material, addresses or email
/// content. Supabase binds the caller with its current access token; the
/// endpoint returns only validated candidate JSON and bounded source metadata.
class SupabaseEmailConnector
    implements
        EmailConnector,
        ConnectionBoundEmailConnector,
        TargetedEmailRetryConnector {
  SupabaseEmailConnector({
    required this.emailImportEnabled,
    required this.connectionId,
    SupabaseClient? client,
    EmailFunctionInvoker? invokeOverride,
    String? Function()? authenticatedUserIdOverride,
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
    DateTime Function()? clock,
    String? expectedOAuthClientId,
    Uri? expectedOAuthRedirectUri,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _client = client,
        _invokeOverride = invokeOverride,
        _authenticatedUserIdOverride = authenticatedUserIdOverride,
        _candidateCodec = candidateCodec,
        _clock = clock ?? DateTime.now,
        _expectedOAuthClientId = expectedOAuthClientId,
        _expectedOAuthRedirectUri = expectedOAuthRedirectUri,
        assert(client != null || invokeOverride != null);

  static const functionName = 'email-import';
  static const maximumPageItems = 100;
  static const maximumOpaqueIdentifierCharacters = 1024;
  static const maximumCursorCharacters = 4096;
  static const maximumEvidenceExcerpts = 8;
  static const maximumEvidenceExcerptCharacters = 512;
  static const maximumAuthorizationUriCharacters = 4096;
  static const maximumOAuthLifetime = Duration(minutes: 15);

  final bool emailImportEnabled;
  @override
  final String connectionId;
  final Duration requestTimeout;
  final SupabaseClient? _client;
  final EmailFunctionInvoker? _invokeOverride;
  final String? Function()? _authenticatedUserIdOverride;
  final EmailCandidatePayloadCodec _candidateCodec;
  final DateTime Function() _clock;
  final String? _expectedOAuthClientId;
  final Uri? _expectedOAuthRedirectUri;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async {
    if (!emailImportEnabled) {
      return const EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.disconnected,
      );
    }
    try {
      _boundedOpaque(connectionId, maximumOpaqueIdentifierCharacters);
      final response = await _invoke({
        'action': 'connect',
        'connectionId': connectionId,
      });
      final envelope = _decodeEnvelope(response);
      if (envelope.page != null) _invalidResponse();
      if (envelope.connection.status == EmailConnectionStatus.connecting &&
          envelope.connection.oauthChallenge == null) {
        _invalidResponse();
      }
      if (envelope.connection.status != EmailConnectionStatus.connecting &&
          envelope.connection.oauthChallenge != null) {
        _invalidResponse();
      }
      return envelope.connection;
    } on EmailImportFailure catch (failure) {
      return EmailConnectionState(
        provider: EmailProvider.gmail,
        status: failure.connectionStatus,
        errorCategory: failure.errorCategory,
        retryAfter: failure.retryAfter,
      );
    }
  }

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async {
    if (!emailImportEnabled) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.configurationMissing,
      );
    }
    _boundedOpaque(connectionId, maximumOpaqueIdentifierCharacters);
    if (cursor != null) _boundedOpaque(cursor, maximumCursorCharacters);
    final envelope = _decodeEnvelope(
      await _invoke({
        'action': 'fetch_delta',
        'connectionId': connectionId,
        'cursor': cursor,
      }),
    );
    final page = envelope.page;
    if (page != null) {
      if (envelope.connection.status != EmailConnectionStatus.connected ||
          envelope.connection.oauthChallenge != null) {
        throw const EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: EmailErrorCategory.validationFailed,
        );
      }
      return page;
    }
    throw _failureFromState(envelope.connection);
  }

  /// Reprocesses one already-known provider message without advancing or
  /// replacing the connection's incremental cursor.
  @override
  Future<TargetedEmailRetryResult> retryCandidate({
    required String providerMessageId,
    required String expectedProviderMessageIdHash,
    required String expectedSanitizedContentHash,
    required String retryIdempotencyKey,
  }) async {
    if (!emailImportEnabled) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.configurationMissing,
      );
    }
    _boundedOpaque(connectionId, maximumOpaqueIdentifierCharacters);
    _boundedOpaque(
      providerMessageId,
      maximumOpaqueIdentifierCharacters,
    );
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedProviderMessageIdHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSanitizedContentHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(retryIdempotencyKey)) {
      _invalidResponse();
    }
    final envelope = _decodeEnvelope(
      await _invoke({
        'action': 'retry_candidate',
        'connectionId': connectionId,
        'providerMessageId': providerMessageId,
        'expectedSanitizedContentHash': expectedSanitizedContentHash,
        'retryIdempotencyKey': retryIdempotencyKey,
      }),
      retryResponse: true,
    );
    final page = envelope.page;
    if (page == null) throw _failureFromState(envelope.connection);
    if (envelope.connection.status != EmailConnectionStatus.connected ||
        envelope.connection.oauthChallenge != null ||
        page.nextCursor != null ||
        page.hasMore) {
      _invalidResponse();
    }
    switch (envelope.retryOutcome) {
      case TargetedEmailRetryOutcome.persisted:
        if (page.items.length != 1 ||
            page.suppressions.isNotEmpty ||
            page.items.single.providerMessageId != providerMessageId) {
          _invalidResponse();
        }
        return TargetedEmailRetryResult.persisted(page.items.single);
      case TargetedEmailRetryOutcome.suppressed:
        if (page.items.isNotEmpty ||
            page.suppressions.length != 1 ||
            page.suppressions.single.providerMessageIdHash !=
                expectedProviderMessageIdHash) {
          _invalidResponse();
        }
        return TargetedEmailRetryResult.suppressed(
          page.suppressions.single,
        );
      case null:
        _invalidResponse();
    }
  }

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {
    if (!emailImportEnabled) return;
    _boundedOpaque(connectionId, maximumOpaqueIdentifierCharacters);
    final envelope = _decodeEnvelope(
      await _invoke({
        'action': 'disconnect',
        'connectionId': connectionId,
        'deleteDerivedData': deleteDerivedData,
      }),
    );
    if (envelope.page != null ||
        envelope.connection.oauthChallenge != null ||
        envelope.connection.status != EmailConnectionStatus.disconnected) {
      throw _failureFromState(envelope.connection);
    }
  }

  /// Removes every provider-derived row for the authenticated owner. This is
  /// intentionally separate from disconnecting one Gmail connection.
  Future<void> deleteAccountData() async {
    if (!emailImportEnabled) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.configurationMissing,
      );
    }
    final envelope = _decodeEnvelope(
      await _invoke(const {'action': 'delete_account_data'}),
    );
    if (envelope.page != null ||
        envelope.connection.oauthChallenge != null ||
        envelope.connection.status != EmailConnectionStatus.disconnected) {
      throw _failureFromState(envelope.connection);
    }
  }

  /// Resolves one browser callback against the server's authenticated,
  /// single-use OAuth-attempt receipt. Both UUIDs are opaque and the response
  /// contains no provider account, address, credential, or message data.
  Future<EmailAuthorizationResolution> checkAuthorization({
    required String callbackCorrelationId,
  }) async {
    if (!emailImportEnabled) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.configurationMissing,
      );
    }
    _uuid(connectionId);
    _uuid(callbackCorrelationId);
    final root = _record(
      await _invoke({
        'action': 'check_authorization',
        'connectionId': connectionId,
        'callbackCorrelationId': callbackCorrelationId,
      }),
    );
    _exactKeys(root, const {'connection', 'page', 'authorization'});
    if (root['page'] != null) _invalidResponse();
    final state = _decodeConnection(root['connection']);
    final authorization = _record(root['authorization']);
    _exactKeys(authorization, const {'effectiveConnectionId'});
    final effectiveConnectionId = _string(
      authorization['effectiveConnectionId'],
    );
    _uuid(effectiveConnectionId);
    return EmailAuthorizationResolution(
      effectiveConnectionId: effectiveConnectionId,
      connection: state,
    );
  }

  Future<Object?> _invoke(Map<String, Object?> body) async {
    _requireAuthenticatedSession();
    try {
      final override = _invokeOverride;
      if (override != null) return await override(body).timeout(requestTimeout);
      final response = await _client!.functions
          .invoke(functionName, body: body)
          .timeout(requestTimeout);
      return response.data;
    } on EmailImportFailure {
      rethrow;
    } on TimeoutException {
      throw EmailImportFailure.timeout();
    } on SocketException {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.networkUnavailable,
      );
    } on FunctionException catch (error) {
      try {
        return _decodeFunctionFailure(error.details);
      } on EmailImportFailure {
        rethrow;
      }
    } catch (_) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.providerUnavailable,
      );
    }
  }

  Never _decodeFunctionFailure(Object? details) {
    try {
      final envelope = _decodeEnvelope(details);
      throw _failureFromState(envelope.connection);
    } on EmailImportFailure {
      rethrow;
    } catch (_) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.providerUnavailable,
      );
    }
  }

  void _requireAuthenticatedSession() {
    final userId =
        _authenticatedUserIdOverride?.call() ?? _client?.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.reauthRequired,
      );
    }
  }

  _EmailEndpointEnvelope _decodeEnvelope(
    Object? raw, {
    bool retryResponse = false,
  }) {
    try {
      final root = _record(raw);
      if (retryResponse) {
        _exactKeys(root, const {'connection', 'page', 'retryOutcome'});
      } else {
        final keys = root.keys.toSet();
        if (keys.length != 2 && keys.length != 3) _invalidResponse();
        if (!keys.containsAll(const {'connection', 'page'}) ||
            keys.difference(const {'connection', 'page', 'oauth'}).isNotEmpty) {
          _invalidResponse();
        }
      }
      final decodedConnection = _decodeConnection(root['connection']);
      final rawPage = root['page'];
      final challenge = !retryResponse && root.containsKey('oauth')
          ? _decodeOAuthChallenge(root['oauth'])
          : null;
      if (challenge != null &&
          (rawPage != null ||
              decodedConnection.status != EmailConnectionStatus.connecting)) {
        _invalidResponse();
      }
      final connection = challenge == null
          ? decodedConnection
          : EmailConnectionState(
              provider: decodedConnection.provider,
              status: decodedConnection.status,
              errorCategory: decodedConnection.errorCategory,
              retryAfter: decodedConnection.retryAfter,
              connectedAt: decodedConnection.connectedAt,
              oauthChallenge: challenge,
            );
      return _EmailEndpointEnvelope(
        connection: connection,
        page: rawPage == null ? null : _decodePage(rawPage),
        retryOutcome: retryResponse
            ? switch (_string(root['retryOutcome'])) {
                'persisted' => TargetedEmailRetryOutcome.persisted,
                'suppressed' => TargetedEmailRetryOutcome.suppressed,
                _ => _invalidResponse(),
              }
            : null,
      );
    } on EmailImportFailure {
      rethrow;
    } catch (_) {
      _invalidResponse();
    }
  }

  EmailOAuthAuthorizationChallenge _decodeOAuthChallenge(Object? raw) {
    final map = _record(raw);
    _exactKeys(
      map,
      const {'authorizationUri', 'codeChallenge', 'expiresAt'},
    );
    final authorizationText = _string(map['authorizationUri']);
    if (authorizationText.isEmpty ||
        authorizationText != authorizationText.trim() ||
        authorizationText.runes.length > maximumAuthorizationUriCharacters ||
        authorizationText.runes.any((rune) => rune < 0x21 || rune == 0x7f)) {
      _invalidResponse(EmailErrorCategory.unsafeUrl);
    }
    final authorizationUri = Uri.tryParse(authorizationText);
    if (authorizationUri == null ||
        authorizationUri.scheme != 'https' ||
        authorizationUri.host.toLowerCase() != 'accounts.google.com' ||
        authorizationUri.hasPort ||
        authorizationUri.userInfo.isNotEmpty ||
        authorizationUri.fragment.isNotEmpty ||
        authorizationUri.path != '/o/oauth2/v2/auth') {
      _invalidResponse(EmailErrorCategory.unsafeUrl);
    }

    final query = authorizationUri.queryParametersAll;
    const expectedQueryKeys = {
      'client_id',
      'redirect_uri',
      'response_type',
      'scope',
      'state',
      'code_challenge',
      'code_challenge_method',
      'access_type',
      'prompt',
      'include_granted_scopes',
    };
    if (query.keys.toSet().difference(expectedQueryKeys).isNotEmpty ||
        expectedQueryKeys.difference(query.keys.toSet()).isNotEmpty ||
        query.values.any((values) => values.length != 1)) {
      _invalidResponse(EmailErrorCategory.unsafeUrl);
    }
    String parameter(String key) => query[key]!.single;
    final clientId = parameter('client_id');
    final expectedClientId = _expectedOAuthClientId;
    final expectedRedirectUri = _expectedOAuthRedirectUri;
    if (expectedClientId == null || expectedRedirectUri == null) {
      _invalidResponse(EmailErrorCategory.configurationMissing);
    }
    _boundedOpaque(expectedClientId, 512);
    if (!_isTrustedOAuthRedirect(expectedRedirectUri)) {
      _invalidResponse(EmailErrorCategory.configurationMissing);
    }
    final redirectUri = Uri.tryParse(parameter('redirect_uri'));
    if (redirectUri == null ||
        redirectUri.scheme != 'https' ||
        _isForbiddenNetworkHost(redirectUri.host) ||
        redirectUri.hasPort ||
        redirectUri.userInfo.isNotEmpty ||
        redirectUri.hasQuery ||
        redirectUri.fragment.isNotEmpty ||
        redirectUri.path != '/functions/v1/email-import' ||
        clientId != expectedClientId ||
        parameter('redirect_uri') != expectedRedirectUri.toString()) {
      _invalidResponse(EmailErrorCategory.unsafeUrl);
    }
    final codeChallenge = _string(map['codeChallenge']);
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(codeChallenge) ||
        parameter('code_challenge') != codeChallenge ||
        parameter('response_type') != 'code' ||
        parameter('scope') !=
            'https://www.googleapis.com/auth/gmail.readonly' ||
        !RegExp(r'^[A-Za-z0-9_-]{32,256}$').hasMatch(parameter('state')) ||
        parameter('code_challenge_method') != 'S256' ||
        parameter('access_type') != 'offline' ||
        parameter('prompt') != 'consent' ||
        parameter('include_granted_scopes') != 'false') {
      _invalidResponse();
    }

    final expiresAt = _timestamp(map['expiresAt']);
    final now = _clock().toUtc();
    if (!expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(maximumOAuthLifetime))) {
      _invalidResponse();
    }
    return EmailOAuthAuthorizationChallenge(
      authorizationUri: authorizationUri,
      codeChallenge: codeChallenge,
      expiresAt: expiresAt,
    );
  }

  EmailConnectionState _decodeConnection(Object? raw) {
    final map = _record(raw);
    _exactKeys(map, const {
      'provider',
      'status',
      'errorCategory',
      'retryAfterSeconds',
      'connectedAt',
    });
    final provider = EmailProvider.fromWire(_string(map['provider']));
    if (provider != EmailProvider.gmail) _invalidResponse();
    final status = EmailConnectionStatus.fromWire(_string(map['status']));
    final errorCategory = map['errorCategory'] == null
        ? null
        : EmailErrorCategory.fromWire(_string(map['errorCategory']));
    if (status != EmailConnectionStatus.failed && errorCategory != null) {
      _invalidResponse();
    }
    final retrySeconds = map['retryAfterSeconds'];
    if (retrySeconds != null &&
        (retrySeconds is! int || retrySeconds < 0 || retrySeconds > 86400)) {
      _invalidResponse();
    }
    if (status != EmailConnectionStatus.rateLimited && retrySeconds != null) {
      _invalidResponse();
    }
    final connectedAt = _optionalTimestamp(map['connectedAt']);
    return EmailConnectionState(
      provider: provider,
      status: status,
      errorCategory: errorCategory,
      retryAfter:
          retrySeconds == null ? null : Duration(seconds: retrySeconds as int),
      connectedAt: connectedAt,
    );
  }

  EmailFetchPage _decodePage(Object? raw) {
    final map = _record(raw);
    _exactKeys(
      map,
      const {'items', 'suppressions', 'nextCursor', 'hasMore'},
    );
    final rawItems = map['items'];
    if (rawItems is! List || rawItems.length > maximumPageItems) {
      _invalidResponse(EmailErrorCategory.oversizedContent);
    }
    final rawSuppressions = map['suppressions'];
    if (rawSuppressions is! List ||
        rawSuppressions.length > maximumPageItems ||
        rawItems.length + rawSuppressions.length > maximumPageItems) {
      _invalidResponse(EmailErrorCategory.oversizedContent);
    }
    final nextCursor = map['nextCursor'];
    if (nextCursor != null) {
      _boundedOpaque(_string(nextCursor), maximumCursorCharacters);
    }
    final hasMore = map['hasMore'];
    if (hasMore is! bool || (hasMore && nextCursor == null)) {
      _invalidResponse();
    }
    final items = rawItems.map(_decodeItem).toList(growable: false);
    final suppressions =
        rawSuppressions.map(_decodeSuppression).toList(growable: false);
    final itemIds = items.map((item) => item.providerMessageId).toSet();
    final suppressionHashes =
        suppressions.map((item) => item.providerMessageIdHash).toSet();
    if (itemIds.length != items.length ||
        suppressionHashes.length != suppressions.length) {
      _invalidResponse();
    }
    return EmailFetchPage(
      items: items,
      nextCursor: nextCursor as String?,
      hasMore: hasMore,
      suppressions: suppressions,
    );
  }

  EmailFetchSuppression _decodeSuppression(Object? raw) {
    final map = _record(raw);
    _exactKeys(map, const {'providerMessageIdHash', 'reason'});
    final providerMessageIdHash = _string(map['providerMessageIdHash']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(providerMessageIdHash)) {
      _invalidResponse();
    }
    return EmailFetchSuppression(
      providerMessageIdHash: providerMessageIdHash,
      reason: EmailFetchSuppressionReason.fromWire(_string(map['reason'])),
    );
  }

  EmailFetchItem _decodeItem(Object? raw) {
    final map = _record(raw);
    _exactKeys(map, const {
      'providerMessageId',
      'providerThreadId',
      'receivedAt',
      'sanitizedContentHash',
      'evidenceExcerpts',
      'candidate',
      'errorCategory',
    });
    final messageId = _string(map['providerMessageId']);
    final threadId = map['providerThreadId'] == null
        ? null
        : _string(map['providerThreadId']);
    _boundedOpaque(messageId, maximumOpaqueIdentifierCharacters);
    if (threadId != null) {
      _boundedOpaque(threadId, maximumOpaqueIdentifierCharacters);
    }
    final hash = _string(map['sanitizedContentHash']);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) _invalidResponse();
    final rawEvidence = map['evidenceExcerpts'];
    if (rawEvidence is! List || rawEvidence.length > maximumEvidenceExcerpts) {
      _invalidResponse(EmailErrorCategory.oversizedContent);
    }
    final evidence = rawEvidence.map((value) {
      final excerpt = _string(value);
      if (excerpt.isEmpty ||
          excerpt != excerpt.trim() ||
          excerpt.runes.length > maximumEvidenceExcerptCharacters ||
          excerpt.runes.any((rune) => rune < 0x20 && rune != 0x0a)) {
        _invalidResponse();
      }
      return excerpt;
    }).toList(growable: false);

    final errorCategory = map['errorCategory'] == null
        ? null
        : EmailErrorCategory.fromWire(_string(map['errorCategory']));
    final rawCandidate = map['candidate'];
    if ((rawCandidate == null) == (errorCategory == null) ||
        (rawCandidate == null && evidence.isNotEmpty) ||
        (rawCandidate != null && threadId == null)) {
      _invalidResponse();
    }
    EmailCandidatePayload? candidate;
    if (rawCandidate != null) {
      try {
        candidate = _candidateCodec.decodeObject(rawCandidate);
      } on EmailCandidateValidationException catch (error) {
        _invalidResponse(error.errorCategory);
      }
    }
    return EmailFetchItem(
      providerMessageId: messageId,
      providerThreadId: threadId,
      receivedAt: _timestamp(map['receivedAt']),
      sanitizedContentHash: hash,
      evidenceExcerpts: evidence,
      candidate: candidate,
      errorCategory: errorCategory,
    );
  }

  EmailImportFailure _failureFromState(EmailConnectionState state) {
    switch (state.status) {
      case EmailConnectionStatus.reauthRequired:
        return EmailImportFailure.authorizationRevoked();
      case EmailConnectionStatus.rateLimited:
        return EmailImportFailure.rateLimited(
          state.retryAfter ?? const Duration(seconds: 60),
        );
      case EmailConnectionStatus.failed:
        return EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory:
              state.errorCategory ?? EmailErrorCategory.providerUnavailable,
        );
      case EmailConnectionStatus.disconnected:
      case EmailConnectionStatus.connecting:
      case EmailConnectionStatus.connected:
      case EmailConnectionStatus.disconnecting:
        return const EmailImportFailure(
          connectionStatus: EmailConnectionStatus.failed,
          errorCategory: EmailErrorCategory.providerUnavailable,
        );
    }
  }

  Map<String, Object?> _record(Object? value) {
    if (value is! Map) _invalidResponse();
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) _invalidResponse();
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  void _exactKeys(Map<String, Object?> map, Set<String> expected) {
    if (map.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(map.keys.toSet()).isNotEmpty) {
      _invalidResponse();
    }
  }

  String _string(Object? value) {
    if (value is! String) _invalidResponse();
    return value;
  }

  void _boundedOpaque(String value, int maximumCharacters) {
    if (value.isEmpty ||
        value != value.trim() ||
        value.runes.length > maximumCharacters ||
        value.runes.any((rune) => rune < 0x21 || rune == 0x7f)) {
      _invalidResponse();
    }
  }

  void _uuid(String value) {
    if (!_uuidPattern.hasMatch(value)) _invalidResponse();
  }

  bool _isTrustedOAuthRedirect(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        !_isForbiddenNetworkHost(uri.host) &&
        !uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        uri.fragment.isEmpty &&
        uri.path == '/functions/v1/email-import';
  }

  bool _isForbiddenNetworkHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized.isEmpty ||
        normalized == 'localhost' ||
        normalized.endsWith('.localhost')) {
      return true;
    }
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(normalized);
    if (ipv4 != null) {
      final octets = [
        for (var index = 1; index <= 4; index++) int.parse(ipv4.group(index)!),
      ];
      if (octets.any((value) => value > 255)) return true;
      final first = octets[0];
      final second = octets[1];
      return first == 0 ||
          first == 10 ||
          first == 127 ||
          first >= 224 ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168);
    }
    if (normalized.contains(':')) {
      return normalized == '::' ||
          normalized == '::1' ||
          normalized.startsWith('fc') ||
          normalized.startsWith('fd') ||
          normalized.startsWith('fe8') ||
          normalized.startsWith('fe9') ||
          normalized.startsWith('fea') ||
          normalized.startsWith('feb');
    }
    return false;
  }

  DateTime? _optionalTimestamp(Object? value) {
    if (value == null) return null;
    return _timestamp(value);
  }

  DateTime _timestamp(Object? value) {
    final text = _string(value);
    final match = _rfc3339.firstMatch(text);
    if (match == null) {
      _invalidResponse();
    }
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    final offsetHour = int.tryParse(match.group(9) ?? '0') ?? 0;
    final offsetMinute = int.tryParse(match.group(10) ?? '0') ?? 0;
    if (!_validDate(year, month, day) ||
        hour > 23 ||
        minute > 59 ||
        second > 59 ||
        offsetHour > 14 ||
        offsetMinute > 59 ||
        (offsetHour == 14 && offsetMinute != 0)) {
      _invalidResponse();
    }
    final parsed = DateTime.tryParse(text);
    if (parsed == null) _invalidResponse();
    return parsed.toUtc();
  }

  bool _validDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1) return false;
    final nextMonth =
        month == 12 ? DateTime.utc(year + 1, 1) : DateTime.utc(year, month + 1);
    return day <= nextMonth.subtract(const Duration(days: 1)).day;
  }

  Never _invalidResponse([
    EmailErrorCategory category = EmailErrorCategory.validationFailed,
  ]) {
    throw EmailImportFailure(
      connectionStatus: EmailConnectionStatus.failed,
      errorCategory: category,
    );
  }

  static final _rfc3339 = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
    r'(\.\d{1,9})?(Z|[+-](\d{2}):(\d{2}))$',
  );

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
}

class EmailAuthorizationResolution {
  const EmailAuthorizationResolution({
    required this.effectiveConnectionId,
    required this.connection,
  });

  final String effectiveConnectionId;
  final EmailConnectionState connection;
}

class _EmailEndpointEnvelope {
  const _EmailEndpointEnvelope({
    required this.connection,
    this.page,
    this.retryOutcome,
  });

  final EmailConnectionState connection;
  final EmailFetchPage? page;
  final TargetedEmailRetryOutcome? retryOutcome;
}
