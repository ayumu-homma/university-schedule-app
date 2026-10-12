import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sync_queue.dart';

const scheduleSyncEntityTypes = <String>{
  'user_course',
  'assignment',
  'assignment_user_state',
  'exam',
  'event',
  'event_exception',
  // Phase 16 owner-scoped catalog operations share the durable queue, but
  // never enter the schedule delta stream.
  'course_template_publish',
  'course_template_update_apply',
};

enum ScheduleMutationOutcome { applied, conflict }

class ScheduleMutationAck {
  const ScheduleMutationAck({
    required this.clientMutationId,
    required this.outcome,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.change,
    required this.replayed,
  });

  final String clientMutationId;
  final ScheduleMutationOutcome outcome;
  final String entityType;
  final String entityId;
  final SyncOperation operation;
  final ScheduleDeltaChange change;
  final bool replayed;

  bool get isConflict => outcome == ScheduleMutationOutcome.conflict;
  int get serverVersion => change.serverVersion;
  int get changeCursor => change.changeCursor;
  DateTime? get deletedAt => change.deletedAt;
}

enum ScheduleDeltaOperation { upsert, delete }

class ScheduleDeltaChange {
  const ScheduleDeltaChange({
    required this.changeCursor,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.serverVersion,
    required this.payload,
    this.deletedAt,
  });

  final int changeCursor;
  final String entityType;
  final String entityId;
  final ScheduleDeltaOperation operation;
  final int serverVersion;
  final DateTime? deletedAt;
  final Map<String, Object?> payload;
}

class ScheduleDeltaPage {
  const ScheduleDeltaPage({
    required this.afterCursor,
    required this.nextCursor,
    required this.hasMore,
    required this.changes,
  });

  final int afterCursor;
  final int nextCursor;
  final bool hasMore;
  final List<ScheduleDeltaChange> changes;
}

class RemoteScheduleCall {
  const RemoteScheduleCall({
    required this.table,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.clientMutationId,
    required this.idempotencyKey,
    this.baseVersion,
  });

  factory RemoteScheduleCall.fromMutation(PendingMutation mutation) {
    final entityType = _canonicalEntityType(mutation.entityType);
    return RemoteScheduleCall(
      table: _tableForEntityType(mutation.entityType),
      action: _mutationRpcForEntityType(entityType),
      entityType: entityType,
      entityId: mutation.entityId,
      operation: mutation.operation,
      payload: mutation.payload,
      clientMutationId: mutation.clientMutationId,
      idempotencyKey: mutation.idempotencyKey,
      baseVersion: mutation.baseVersion,
    );
  }

  final String table;
  final String action;
  final String entityType;
  final String entityId;
  final SyncOperation operation;
  final Map<String, Object?> payload;
  final String clientMutationId;
  final String idempotencyKey;
  final int? baseVersion;

  String get label => '$table.$action';
}

class RemoteSchedulePullCall {
  const RemoteSchedulePullCall({
    required this.ownerUserId,
    required this.afterCursor,
    required this.limit,
  });

  final String ownerUserId;
  final int afterCursor;
  final int limit;
}

abstract interface class RemoteScheduleGateway {
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation);

  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  });
}

class RemoteScheduleException implements Exception {
  const RemoteScheduleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RemoteScheduleTransientException extends RemoteScheduleException {
  const RemoteScheduleTransientException(super.message);
}

class RemoteScheduleAuthenticationException extends RemoteScheduleException {
  const RemoteScheduleAuthenticationException(super.message);
}

class RemoteScheduleProtocolException extends RemoteScheduleException {
  const RemoteScheduleProtocolException(super.message);
}

class RemoteScheduleConflictException extends RemoteScheduleException {
  const RemoteScheduleConflictException(
    super.message, {
    this.serverVersion,
    this.changeCursor,
  });

  final int? serverVersion;
  final int? changeCursor;
}

class DisabledRemoteScheduleGateway implements RemoteScheduleGateway {
  const DisabledRemoteScheduleGateway();

  Never _disabled() {
    throw const RemoteScheduleException(
      'Remote schedule sync is disabled until Phase 3.',
    );
  }

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async =>
      _disabled();

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async =>
      _disabled();
}

typedef FakeScheduleAckFactory = ScheduleMutationAck Function(
  PendingMutation mutation,
  int callNumber,
);
typedef FakeScheduleDeltaFactory = ScheduleDeltaPage Function(
  RemoteSchedulePullCall call,
);

class FakeRemoteScheduleGateway implements RemoteScheduleGateway {
  FakeRemoteScheduleGateway({
    this.shouldFail,
    this.failureFor,
    this.ackFor,
    this.deltaFor,
  });

  final bool Function(RemoteScheduleCall call)? shouldFail;
  final Object? Function(RemoteScheduleCall call)? failureFor;
  final FakeScheduleAckFactory? ackFor;
  final FakeScheduleDeltaFactory? deltaFor;
  final List<RemoteScheduleCall> calls = [];
  final List<RemoteSchedulePullCall> pullCalls = [];

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    final call = RemoteScheduleCall.fromMutation(mutation);
    calls.add(call);
    final failure = failureFor?.call(call);
    if (failure != null) throw failure;
    if (shouldFail?.call(call) ?? false) {
      throw RemoteScheduleTransientException(
        'Fake gateway failed ${call.label}',
      );
    }
    return ackFor?.call(mutation, calls.length) ??
        ScheduleMutationAck(
          clientMutationId: mutation.clientMutationId,
          outcome: ScheduleMutationOutcome.applied,
          entityType: _canonicalEntityType(mutation.entityType),
          entityId: mutation.entityId,
          operation: mutation.operation,
          change: _changeForMutation(mutation, calls.length),
          replayed: false,
        );
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async {
    final call = RemoteSchedulePullCall(
      ownerUserId: ownerUserId,
      afterCursor: afterCursor,
      limit: limit,
    );
    pullCalls.add(call);
    return deltaFor?.call(call) ??
        ScheduleDeltaPage(
          afterCursor: afterCursor,
          nextCursor: afterCursor,
          hasMore: false,
          changes: const [],
        );
  }
}

typedef RemoteScheduleRpc = Future<Object?> Function(
  String functionName,
  Map<String, Object?> parameters,
);

/// Kept for the Phase 2 composition test while callers migrate to [RemoteScheduleRpc].
typedef RemoteScheduleUpsert = Future<void> Function(
  String table,
  Map<String, Object?> payload,
);

class SupabaseScheduleGateway implements RemoteScheduleGateway {
  SupabaseScheduleGateway({
    SupabaseClient? client,
    RemoteScheduleRpc? rpcOverride,
    RemoteScheduleUpsert? upsertOverride,
  })  : _client = client,
        _rpcOverride = rpcOverride,
        _legacyUpsertOverride = upsertOverride,
        assert(client != null || rpcOverride != null || upsertOverride != null);

  final SupabaseClient? _client;
  final RemoteScheduleRpc? _rpcOverride;
  final RemoteScheduleUpsert? _legacyUpsertOverride;

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    _validateMutation(mutation);
    final legacyOverride = _legacyUpsertOverride;
    if (legacyOverride != null && _rpcOverride == null) {
      await legacyOverride(
        _tableForEntityType(mutation.entityType),
        _jsonSafeMap(mutation.payload),
      );
      return ScheduleMutationAck(
        clientMutationId: mutation.clientMutationId,
        outcome: ScheduleMutationOutcome.applied,
        entityType: _canonicalEntityType(mutation.entityType),
        entityId: mutation.entityId,
        operation: mutation.operation,
        change: _changeForMutation(mutation, 0),
        replayed: false,
      );
    }

    _assertAuthenticatedOwner(mutation.ownerUserId);
    final entityType = _canonicalEntityType(mutation.entityType);
    final response = await _guardRemoteCall(
      () => _rpc(
        _mutationRpcForEntityType(entityType),
        _mutationParameters(mutation, entityType),
      ),
    );
    if (entityType == 'course_template_publish' ||
        entityType == 'course_template_update_apply') {
      return _parseTemplateOperationAck(response, mutation);
    }
    return _parseMutationAck(
      response,
      mutation,
      rpcName: _mutationRpcForEntityType(entityType),
    );
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) async {
    if (afterCursor < 0) {
      throw ArgumentError.value(afterCursor, 'afterCursor', 'Must be >= 0.');
    }
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 500.');
    }
    _assertAuthenticatedOwner(ownerUserId);
    final response = await _guardRemoteCall(
      () => _rpc(
        'get_schedule_delta',
        {
          'p_after_cursor': afterCursor,
          'p_limit': limit,
        },
      ),
    );
    return _parseDeltaPage(
      response,
      afterCursor: afterCursor,
    );
  }

  Future<Object?> _rpc(
    String functionName,
    Map<String, Object?> parameters,
  ) {
    final override = _rpcOverride;
    if (override != null) return override(functionName, parameters);
    final client = _client;
    if (client == null) {
      throw const RemoteScheduleAuthenticationException(
        'Supabase client is unavailable.',
      );
    }
    return client.rpc(functionName, params: parameters);
  }

  void _assertAuthenticatedOwner(String ownerUserId) {
    if (ownerUserId.trim().isEmpty || ownerUserId != ownerUserId.trim()) {
      throw const RemoteScheduleAuthenticationException(
        'A normalized schedule owner is required.',
      );
    }
    if (_rpcOverride != null) return;
    final authenticatedUserId = _client?.auth.currentUser?.id;
    if (authenticatedUserId == null || authenticatedUserId != ownerUserId) {
      throw const RemoteScheduleAuthenticationException(
        'The authenticated user does not own this sync operation.',
      );
    }
  }

  void _validateMutation(PendingMutation mutation) {
    if (mutation.clientMutationId.trim().isEmpty ||
        mutation.idempotencyKey.trim().isEmpty ||
        mutation.entityId.trim().isEmpty ||
        mutation.ownerUserId.trim().isEmpty) {
      throw const RemoteScheduleProtocolException(
        'Mutation identity fields are required.',
      );
    }
    final entityType = _canonicalEntityType(mutation.entityType);
    if (!scheduleSyncEntityTypes.contains(entityType)) {
      throw RemoteScheduleProtocolException(
        'Unsupported schedule entity type: ${mutation.entityType}',
      );
    }
    final payloadOwner = mutation.payload['ownerUserId'];
    final payloadUser = mutation.payload['userId'];
    if ((payloadOwner != null && payloadOwner != mutation.ownerUserId) ||
        (entityType == 'assignment_user_state' &&
            payloadUser != null &&
            payloadUser != mutation.ownerUserId)) {
      throw const RemoteScheduleAuthenticationException(
        'Mutation payload owner does not match the authenticated owner.',
      );
    }
    final payloadId = entityType == 'assignment_user_state'
        ? mutation.payload['assignmentId']
        : mutation.payload['id'];
    if (payloadId != null && payloadId != mutation.entityId) {
      throw const RemoteScheduleProtocolException(
        'Mutation entity ID does not match its payload.',
      );
    }
    if (mutation.operation == SyncOperation.create &&
        mutation.baseVersion != null) {
      throw const RemoteScheduleProtocolException(
        'Create mutations cannot carry a base version.',
      );
    }
    if ((mutation.operation == SyncOperation.update ||
            mutation.operation == SyncOperation.delete) &&
        (mutation.baseVersion == null || mutation.baseVersion! < 1)) {
      throw const RemoteScheduleProtocolException(
        'Update and delete mutations require a positive base version.',
      );
    }
    if (mutation.operation == SyncOperation.submit) {
      final supportedSubmit = entityType == 'assignment_user_state' ||
          entityType == 'course_template_publish' ||
          entityType == 'course_template_update_apply';
      if (!supportedSubmit ||
          entityType == 'assignment_user_state' &&
              mutation.baseVersion != null &&
              mutation.baseVersion! < 1) {
        throw const RemoteScheduleProtocolException(
          'Submit mutation has an invalid entity type or base version.',
        );
      }
    }
    if ((entityType == 'course_template_publish' ||
            entityType == 'course_template_update_apply') &&
        mutation.operation != SyncOperation.submit) {
      throw const RemoteScheduleProtocolException(
        'Template operations must be submit mutations.',
      );
    }
  }

  ScheduleMutationAck _parseMutationAck(
    Object? response,
    PendingMutation mutation, {
    required String rpcName,
  }) {
    final row = _singleRow(response, rpcName);
    final outcome = switch (_requiredString(row, 'outcome')) {
      'applied' => ScheduleMutationOutcome.applied,
      'conflict' => ScheduleMutationOutcome.conflict,
      final value => throw RemoteScheduleProtocolException(
          'Unknown mutation outcome: $value',
        ),
    };
    final entityType =
        _canonicalEntityType(_requiredString(row, 'entity_type'));
    final entityId = _requiredString(row, 'entity_id');
    final operation = _syncOperation(_requiredString(row, 'operation'));
    if (entityType != _canonicalEntityType(mutation.entityType) ||
        entityId != mutation.entityId ||
        operation != mutation.operation) {
      throw const RemoteScheduleProtocolException(
        'Mutation acknowledgement identity does not match the request.',
      );
    }
    final change = _parseDeltaChange(
      _objectMap(row['change'], 'mutation acknowledgement change'),
      afterCursor: -1,
      maximumCursor: null,
    );
    final envelopeVersion = row.containsKey('server_version')
        ? _requiredInt(row, 'server_version')
        : change.serverVersion;
    final envelopeCursor = row.containsKey('change_cursor')
        ? _requiredInt(row, 'change_cursor')
        : change.changeCursor;
    final envelopeDeletedAt = row.containsKey('deleted_at')
        ? _nullableDateTime(row['deleted_at'])
        : change.deletedAt;
    final expectedAppliedOperation = operation == SyncOperation.delete
        ? ScheduleDeltaOperation.delete
        : ScheduleDeltaOperation.upsert;
    if (change.entityType != entityType ||
        change.entityId != entityId ||
        envelopeVersion != change.serverVersion ||
        envelopeCursor != change.changeCursor ||
        envelopeDeletedAt != change.deletedAt ||
        (outcome == ScheduleMutationOutcome.applied &&
            change.operation != expectedAppliedOperation)) {
      throw const RemoteScheduleProtocolException(
        'Canonical acknowledgement change does not match the mutation.',
      );
    }
    return ScheduleMutationAck(
      clientMutationId: mutation.clientMutationId,
      outcome: outcome,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      change: change,
      replayed: _requiredBool(row, 'replayed'),
    );
  }

  ScheduleDeltaPage _parseDeltaPage(
    Object? response, {
    required int afterCursor,
  }) {
    final row = _singleRow(response, 'get_schedule_delta');
    final nextCursor = _requiredInt(row, 'next_cursor');
    final hasMore = _requiredBool(row, 'has_more');
    final rawChanges = row['changes'];
    if (rawChanges is! List) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta changes must be a list.',
      );
    }
    final changes = <ScheduleDeltaChange>[];
    var previousCursor = afterCursor;
    for (final value in rawChanges) {
      final parsed = _parseDeltaChange(
        _objectMap(value, 'schedule delta change'),
        afterCursor: previousCursor,
        maximumCursor: nextCursor,
      );
      changes.add(parsed);
      previousCursor = parsed.changeCursor;
    }
    if (nextCursor < afterCursor ||
        (hasMore && nextCursor == afterCursor) ||
        (changes.isNotEmpty && changes.last.changeCursor != nextCursor)) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta cursor envelope is invalid.',
      );
    }
    return ScheduleDeltaPage(
      afterCursor: afterCursor,
      nextCursor: nextCursor,
      hasMore: hasMore,
      changes: List.unmodifiable(changes),
    );
  }

  ScheduleMutationAck _parseTemplateOperationAck(
    Object? response,
    PendingMutation mutation,
  ) {
    final row = _singleRow(response, 'course template operation');
    final operationId = _requiredString(
      row,
      row.containsKey('personal_course_id')
          ? 'personal_course_id'
          : 'course_id',
    );
    if (operationId != mutation.entityId) {
      throw const RemoteScheduleProtocolException(
        'Template operation acknowledgement escaped its course scope.',
      );
    }
    final version = row['course_version'] is num
        ? (row['course_version']! as num).toInt()
        : (_payloadVersion(mutation.payload) ?? 1);
    final payload = <String, Object?>{
      ..._jsonSafeMap(mutation.payload),
      ..._jsonSafeMap(row),
      'id': mutation.entityId,
      'ownerUserId': mutation.ownerUserId,
      'version': version,
      'deletedAt': null,
    };
    final change = ScheduleDeltaChange(
      changeCursor: 0,
      entityType: _canonicalEntityType(mutation.entityType),
      entityId: mutation.entityId,
      operation: ScheduleDeltaOperation.upsert,
      serverVersion: version,
      payload: payload,
    );
    return ScheduleMutationAck(
      clientMutationId: mutation.clientMutationId,
      outcome: ScheduleMutationOutcome.applied,
      entityType: _canonicalEntityType(mutation.entityType),
      entityId: mutation.entityId,
      operation: mutation.operation,
      change: change,
      replayed: row['replayed'] == true,
    );
  }

  ScheduleDeltaChange _parseDeltaChange(
    Map<String, Object?> change, {
    required int afterCursor,
    required int? maximumCursor,
  }) {
    final changeCursor = _requiredInt(change, 'changeCursor');
    if (changeCursor <= afterCursor ||
        (maximumCursor != null && changeCursor > maximumCursor)) {
      throw const RemoteScheduleProtocolException(
        'Schedule delta cursors are not strictly ordered.',
      );
    }
    final entityType = _canonicalEntityType(
      _requiredString(change, 'entityType'),
    );
    if (!scheduleSyncEntityTypes.contains(entityType)) {
      throw RemoteScheduleProtocolException(
        'Unsupported delta entity type: $entityType',
      );
    }
    final operation = switch (_requiredString(change, 'operation')) {
      'upsert' => ScheduleDeltaOperation.upsert,
      'delete' => ScheduleDeltaOperation.delete,
      final value => throw RemoteScheduleProtocolException(
          'Unsupported delta operation: $value',
        ),
    };
    return ScheduleDeltaChange(
      changeCursor: changeCursor,
      entityType: entityType,
      entityId: _requiredString(change, 'entityId'),
      operation: operation,
      serverVersion: _requiredInt(change, 'serverVersion'),
      deletedAt: _nullableDateTime(change['deletedAt']),
      payload: _objectMap(change['payload'], 'schedule delta payload'),
    );
  }

  Future<T> _guardRemoteCall<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on RemoteScheduleException {
      rethrow;
    } on AuthException {
      throw const RemoteScheduleAuthenticationException(
        'The Supabase session is unavailable for schedule sync.',
      );
    } on TimeoutException {
      throw const RemoteScheduleTransientException(
        'The schedule sync request timed out.',
      );
    } on SocketException {
      throw const RemoteScheduleTransientException(
        'The schedule sync network is unavailable.',
      );
    } on http.RequestAbortedException {
      throw const RemoteScheduleTransientException(
        'The schedule sync request timed out.',
      );
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'PGRST301') {
        throw const RemoteScheduleAuthenticationException(
          'The schedule sync request is not authorized.',
        );
      }
      if (_isTransientPostgrestCode(error.code)) {
        throw const RemoteScheduleTransientException(
          'The schedule sync service is temporarily unavailable.',
        );
      }
      throw RemoteScheduleException(
        sanitizeSyncErrorMessage(error.message) ??
            'The schedule sync request failed.',
      );
    } on Object catch (error) {
      throw RemoteScheduleTransientException(
        sanitizeSyncErrorMessage(error.runtimeType.toString()) ??
            'The schedule sync request failed.',
      );
    }
  }
}

bool _isTransientPostgrestCode(String? rawCode) {
  final code = rawCode?.trim().toUpperCase();
  if (code == null || code.isEmpty) return true;
  final httpStatus = int.tryParse(code);
  if (httpStatus == 408 ||
      httpStatus == 429 ||
      (httpStatus != null && httpStatus >= 500 && httpStatus <= 599)) {
    return true;
  }
  return code.startsWith('08') ||
      code.startsWith('53') ||
      code.startsWith('PGRST0') ||
      code == '40001' ||
      code == '40P01' ||
      code == '55P03' ||
      code == '57014' ||
      code == '57P01' ||
      code == '57P02' ||
      code == '57P03' ||
      code == '58000' ||
      code == 'PGRSTX00';
}

Map<String, Object?> _singleRow(Object? value, String operation) {
  final Object? row = switch (value) {
    List() when value.length == 1 => value.single,
    Map() => value,
    _ => null,
  };
  if (row == null) {
    throw RemoteScheduleProtocolException(
      '$operation must return exactly one row.',
    );
  }
  return _objectMap(row, '$operation response');
}

Map<String, Object?> _objectMap(Object? value, String label) {
  if (value is! Map) {
    throw RemoteScheduleProtocolException('$label must be an object.');
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _requiredString(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw RemoteScheduleProtocolException('$key is missing from sync response.');
}

int _requiredInt(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw RemoteScheduleProtocolException('$key is missing from sync response.');
}

bool _requiredBool(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is bool) return value;
  throw RemoteScheduleProtocolException('$key is missing from sync response.');
}

SyncOperation _syncOperation(String value) {
  return SyncOperation.values.firstWhere(
    (operation) => operation.name == value,
    orElse: () => throw RemoteScheduleProtocolException(
      'Unsupported mutation operation: $value',
    ),
  );
}

String _canonicalEntityType(String value) {
  return switch (value) {
    'assignment_state' => 'assignment_user_state',
    _ => value,
  };
}

String _mutationRpcForEntityType(String value) {
  return switch (_canonicalEntityType(value)) {
    'course_template_publish' => 'publish_course_template',
    'course_template_update_apply' => 'review_course_template_update',
    // Event exceptions have a deliberately narrow RPC because their parent
    // routine and owner scope must be verified together on the server.
    'event_exception' => 'apply_event_exception_mutation',
    _ => 'apply_schedule_mutation',
  };
}

Map<String, Object?> _mutationParameters(
  PendingMutation mutation,
  String entityType,
) {
  final payload = _jsonSafeMap(mutation.payload);
  if (entityType == 'event_exception') {
    return {
      'p_idempotency_key': mutation.idempotencyKey,
      'p_entity_id': mutation.entityId,
      'p_operation': mutation.operation.name,
      'p_base_version': mutation.baseVersion,
      'p_payload': payload,
    };
  }
  if (entityType == 'course_template_publish') {
    return {
      'p_user_course_id': mutation.entityId,
      'p_operation_id': mutation.idempotencyKey,
    };
  }
  if (entityType == 'course_template_update_apply') {
    return {
      'p_user_course_id': mutation.entityId,
      'p_action': mutation.payload['action'] ?? 'apply',
      'p_expected_template_version':
          mutation.payload['expectedTemplateVersion'],
      'p_expected_course_version': mutation.baseVersion,
      'p_operation_id': mutation.idempotencyKey,
    };
  }
  return {
    'p_idempotency_key': mutation.idempotencyKey,
    'p_entity_type': entityType,
    'p_entity_id': mutation.entityId,
    'p_operation': mutation.operation.name,
    'p_base_version': mutation.baseVersion,
    'p_payload': payload,
  };
}

String _tableForEntityType(String value) {
  return switch (_canonicalEntityType(value)) {
    'course_template_publish' => 'course_templates',
    'course_template_update_apply' => 'user_courses',
    'user_course' => 'user_courses',
    'assignment' => 'assignments',
    'assignment_user_state' => 'assignment_user_states',
    'exam' => 'exams',
    'event' => 'events',
    'event_exception' => 'event_exceptions',
    _ => value,
  };
}

int? _payloadVersion(Map<String, Object?> payload) {
  final value = payload['version'];
  return value is int
      ? value
      : value is num
          ? value.toInt()
          : null;
}

ScheduleDeltaChange _changeForMutation(
  PendingMutation mutation,
  int changeCursor,
) {
  return ScheduleDeltaChange(
    changeCursor: changeCursor,
    entityType: _canonicalEntityType(mutation.entityType),
    entityId: mutation.entityId,
    operation: mutation.operation == SyncOperation.delete
        ? ScheduleDeltaOperation.delete
        : ScheduleDeltaOperation.upsert,
    serverVersion:
        _payloadVersion(mutation.payload) ?? ((mutation.baseVersion ?? 0) + 1),
    deletedAt: _optionalDateTime(mutation.payload['deletedAt']),
    payload: _jsonSafeMap(mutation.payload),
  );
}

DateTime? _optionalDateTime(Object? value) => _nullableDateTime(value);

DateTime? _nullableDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    final normalized = value.trim();
    if (!_hasExplicitUtcOffset(normalized)) {
      throw const RemoteScheduleProtocolException(
        'A sync timestamp must include an explicit UTC offset.',
      );
    }
    final parsed = DateTime.tryParse(normalized);
    if (parsed != null) return parsed.toUtc();
  }
  throw const RemoteScheduleProtocolException(
    'A sync timestamp is malformed.',
  );
}

bool _hasExplicitUtcOffset(String value) {
  return RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(value);
}

Map<String, Object?> _jsonSafeMap(Map<String, Object?> source) {
  return {
    for (final entry in source.entries) entry.key: _jsonSafeValue(entry.value),
  };
}

Object? _jsonSafeValue(Object? value) {
  return switch (value) {
    DateTime() => value.toUtc().toIso8601String(),
    Map<String, Object?>() => _jsonSafeMap(value),
    Map() => {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafeValue(entry.value),
      },
    Iterable() => [for (final item in value) _jsonSafeValue(item)],
    _ => value,
  };
}
