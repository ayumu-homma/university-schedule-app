import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/email_reconciliation.dart';
import 'email_import_failure.dart';

typedef EmailReconciliationFunctionInvoker = Future<Object?> Function(
  Map<String, Object?> body,
);

/// Strict authenticated adapter for review reconciliation. Requests contain
/// only safe hashes and validated review state; responses are accepted only
/// when every acknowledgement field exactly matches the submitted decision.
class SupabaseEmailReconciliationGateway implements EmailReconciliationGateway {
  SupabaseEmailReconciliationGateway({
    required this.emailImportEnabled,
    SupabaseClient? client,
    EmailReconciliationFunctionInvoker? invokeOverride,
    String? Function()? authenticatedUserIdOverride,
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
    this.requestTimeout = const Duration(seconds: 15),
  })  : _client = client,
        _invokeOverride = invokeOverride,
        _authenticatedUserIdOverride = authenticatedUserIdOverride,
        _candidateCodec = candidateCodec,
        assert(client != null || invokeOverride != null);

  static const functionName = 'email-import';

  final bool emailImportEnabled;
  final Duration requestTimeout;
  final SupabaseClient? _client;
  final EmailReconciliationFunctionInvoker? _invokeOverride;
  final String? Function()? _authenticatedUserIdOverride;
  final EmailCandidatePayloadCodec _candidateCodec;

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    if (!emailImportEnabled) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.configurationMissing,
      );
    }
    final body = _requestBody(request);
    final root = _record(await _invoke(body));
    _exactKeys(root, const {'connection', 'page', 'reconciliation'});
    if (root['page'] != null) _invalidResponse();
    _validateConnectionState(root['connection']);
    return _decodeAcknowledgement(root['reconciliation'], request);
  }

  Map<String, Object?> _requestBody(EmailReconciliationRequest request) {
    _uuid(request.connectionId);
    if (request.provider != EmailProvider.gmail.wireName) _invalidResponse();
    _hash(request.providerAccountHash);
    _hash(request.providerMessageIdHash);
    _hash(request.providerThreadIdHash);
    _hash(request.sanitizedContentHash);
    _idempotencyKey(request.idempotencyKey);

    final common = <String, Object?>{
      'action': switch (request.action) {
        EmailReconciliationAction.confirmation => 'reconcile_confirmation',
        EmailReconciliationAction.dismissal => 'reconcile_dismissal',
        EmailReconciliationAction.update => 'reconcile_update',
      },
      'connectionId': request.connectionId,
      'provider': request.provider,
      'providerAccountHash': request.providerAccountHash,
      'providerMessageIdHash': request.providerMessageIdHash,
      'providerThreadIdHash': request.providerThreadIdHash,
      'sanitizedContentHash': request.sanitizedContentHash,
      'idempotencyKey': request.idempotencyKey,
    };
    switch (request.action) {
      case EmailReconciliationAction.confirmation:
        final entityType = _entity(request.entityType, request.entityId);
        if (request.resolution != null || request.reviewedPayload == null) {
          _invalidResponse();
        }
        final payload = _canonicalPayload(request.reviewedPayload!);
        if (payload['candidate_type'] != entityType) _invalidResponse();
        return {
          ...common,
          'reviewedPayload': payload,
          'entityType': entityType,
          'entityId': request.entityId,
        };
      case EmailReconciliationAction.dismissal:
        if (request.reviewedPayload != null ||
            request.resolution != null ||
            request.entityType != null ||
            request.entityId != null) {
          _invalidResponse();
        }
        return common;
      case EmailReconciliationAction.update:
        final entityType = _entity(request.entityType, request.entityId);
        if (request.reviewedPayload != null || request.resolution == null) {
          _invalidResponse();
        }
        return {
          ...common,
          'resolution': request.resolution!.wireName,
          'entityType': entityType,
          'entityId': request.entityId,
        };
    }
  }

  Map<String, Object?> _canonicalPayload(Map<String, Object?> raw) {
    try {
      final payload = _candidateCodec.decodeObject(raw);
      final decoded = jsonDecode(_candidateCodec.encode(payload));
      if (decoded is! Map) _invalidResponse();
      return decoded.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on EmailCandidateValidationException catch (error) {
      _invalidResponse(error.errorCategory);
    } on Object {
      _invalidResponse();
    }
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
    } on FunctionException catch (_) {
      throw const EmailImportFailure(
        connectionStatus: EmailConnectionStatus.failed,
        errorCategory: EmailErrorCategory.providerUnavailable,
      );
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

  void _validateConnectionState(Object? raw) {
    final connection = _record(raw);
    _exactKeys(connection, const {
      'provider',
      'status',
      'errorCategory',
      'retryAfterSeconds',
      'connectedAt',
    });
    final rawStatus = connection['status'];
    if (connection['provider'] != EmailProvider.gmail.wireName ||
        rawStatus is! String) {
      _invalidResponse();
    }
    final EmailConnectionStatus status;
    try {
      status = EmailConnectionStatus.fromWire(rawStatus);
    } on FormatException {
      _invalidResponse();
    }
    final rawErrorCategory = connection['errorCategory'];
    if (rawErrorCategory != null) {
      if (rawErrorCategory is! String) _invalidResponse();
      try {
        EmailErrorCategory.fromWire(rawErrorCategory);
      } on FormatException {
        _invalidResponse();
      }
    }
    if (status != EmailConnectionStatus.failed && rawErrorCategory != null) {
      _invalidResponse();
    }
    final retrySeconds = connection['retryAfterSeconds'];
    if (retrySeconds != null &&
        (retrySeconds is! int || retrySeconds < 0 || retrySeconds > 86400)) {
      _invalidResponse();
    }
    if (status != EmailConnectionStatus.rateLimited && retrySeconds != null) {
      _invalidResponse();
    }
    final connectedAt = connection['connectedAt'];
    if (connectedAt != null) _timestamp(connectedAt);
  }

  EmailReconciliationResult _decodeAcknowledgement(
    Object? raw,
    EmailReconciliationRequest request,
  ) {
    final acknowledgement = _record(raw);
    _exactKeys(acknowledgement, const {
      'connectionId',
      'idempotencyKey',
      'action',
      'outcome',
      'entityType',
      'entityId',
      'replayed',
    });
    final expectedOutcome = switch (request.action) {
      EmailReconciliationAction.confirmation =>
        EmailReconciliationOutcome.confirmed,
      EmailReconciliationAction.dismissal =>
        EmailReconciliationOutcome.dismissed,
      EmailReconciliationAction.update =>
        request.resolution == EmailReconciliationResolution.accepted
            ? EmailReconciliationOutcome.accepted
            : EmailReconciliationOutcome.rejected,
    };
    if (acknowledgement['connectionId'] != request.connectionId ||
        acknowledgement['idempotencyKey'] != request.idempotencyKey ||
        acknowledgement['action'] != request.action.wireName ||
        acknowledgement['outcome'] != expectedOutcome.wireName ||
        acknowledgement['entityType'] != request.entityType ||
        acknowledgement['entityId'] != request.entityId ||
        acknowledgement['replayed'] is! bool) {
      _invalidResponse();
    }
    return EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: expectedOutcome,
      entityType: request.entityType,
      entityId: request.entityId,
      replayed: acknowledgement['replayed']! as bool,
    );
  }

  String _entity(String? entityType, String? entityId) {
    if (!const {'assignment', 'exam', 'event'}.contains(entityType) ||
        entityId == null) {
      _invalidResponse();
    }
    _uuid(entityId);
    return entityType!;
  }

  void _uuid(String value) {
    if (!_uuidPattern.hasMatch(value)) _invalidResponse();
  }

  void _hash(String value) {
    if (!_hashPattern.hasMatch(value)) _invalidResponse();
  }

  void _idempotencyKey(String value) {
    if (value.isEmpty ||
        value != value.trim() ||
        value.runes.length > 200 ||
        value.runes.any((rune) => rune < 0x21 || rune == 0x7f)) {
      _invalidResponse();
    }
  }

  void _timestamp(Object? value) {
    if (value is! String ||
        !_rfc3339.hasMatch(value) ||
        DateTime.tryParse(value) == null) {
      _invalidResponse();
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

  Never _invalidResponse([
    EmailErrorCategory category = EmailErrorCategory.validationFailed,
  ]) {
    throw EmailImportFailure(
      connectionStatus: EmailConnectionStatus.failed,
      errorCategory: category,
    );
  }

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _rfc3339 = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$',
  );
}
