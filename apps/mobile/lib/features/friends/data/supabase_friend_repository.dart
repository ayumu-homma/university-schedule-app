import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../domain/friend_models.dart';
import '../domain/friend_repository.dart';

/// The friend API is deliberately RPC-only.  The client never writes the
/// friendship, invitation, block, or visibility tables directly.
class SupabaseFriendRepository implements FriendRepository {
  SupabaseFriendRepository(this._client);

  final SupabaseClient _client;
  String? _pendingCreateSecret;
  String? _pendingCreateOperationId;
  DateTime? _pendingCreateExpiresAt;
  String? _pendingCreateSessionId;
  final Map<String, String> _pendingOperationIds = {};

  @override
  Future<FriendUsernameProfile?> getMyFriendUsername() async {
    final result = await _client.rpc('get_my_friend_username');
    if (result is! Map) return null;
    return _usernameProfile(Map<String, Object?>.from(result));
  }

  @override
  Future<FriendUsernameProfile> setMyFriendUsername({
    required String? username,
    required bool searchable,
  }) async {
    final result = await _client.rpc('set_my_friend_username', params: {
      'p_username': username,
      'p_searchable': searchable,
    });
    if (result is! Map) {
      throw const UnknownAppError('サーバー応答の形式を確認できませんでした');
    }
    return _usernameProfile(Map<String, Object?>.from(result));
  }

  @override
  Future<List<FriendUsernameMatch>> findFriendByUsername(
    String username,
  ) async {
    final result = await _client.rpc('find_friend_by_username', params: {
      'p_username': username,
    });
    final rows = _rows(result);
    return rows
        .take(1)
        .map((row) => FriendUsernameMatch(
              userId: _requiredString(row, 'user_id'),
              username: _requiredString(row, 'username'),
              displayName: _requiredString(row, 'display_name'),
            ))
        .toList(growable: false);
  }

  @override
  Future<FriendRelationship> requestFriendByUsername({
    required FriendUsernameMatch target,
    required String shownUsername,
    required String operationId,
  }) async {
    final result = await _client.rpc(
      'request_friend_by_username',
      params: {
        'p_target_user_id': target.userId,
        'p_shown_username': shownUsername,
        'p_operation_id': operationId,
      },
    );
    final rows = _rows(result);
    if (rows.isEmpty) {
      throw const UnknownAppError('サーバー応答を確認できませんでした');
    }
    final row = rows.first;
    final status = FriendshipStatus.values.firstWhere(
      (value) => value.name == row['status']?.toString(),
      orElse: () => FriendshipStatus.pending,
    );
    return FriendRelationship(
      id: _requiredString(row, 'friendship_id'),
      otherUserId: target.userId,
      otherDisplayName: target.displayName,
      status: status,
      isRequester: row['requester_user_id'] == _client.auth.currentUser?.id,
      incarnation: _optionalString(row, 'incarnation'),
      revision: _int(row['revision']),
    );
  }

  FriendUsernameProfile _usernameProfile(Map<String, Object?> row) =>
      FriendUsernameProfile(
        username: _optionalString(row, 'username'),
        searchable: row['searchable_by_username'] == true,
      );

  @override
  Future<FriendInvitation> createInvitation({
    required DateTime expiresAt,
  }) async {
    final sessionId = _client.auth.currentUser?.id;
    if (_pendingCreateSessionId != sessionId ||
        (_pendingCreateExpiresAt != null &&
            !_pendingCreateExpiresAt!.isAtSameMomentAs(expiresAt))) {
      _pendingCreateSecret = null;
      _pendingCreateOperationId = null;
      _pendingCreateExpiresAt = null;
    }
    _pendingCreateSessionId = sessionId;
    _pendingCreateExpiresAt ??= expiresAt;
    final secret = _pendingCreateSecret ??= _newSecret();
    final operationId = _pendingCreateOperationId ??= const Uuid().v4();
    try {
      final row = await _single('create_friend_invite', {
        'p_secret': secret,
        'p_operation_id': operationId,
        'p_expires_at': _pendingCreateExpiresAt!.toUtc().toIso8601String(),
      });
      final invitation = FriendInvitation(
        id: _requiredString(row, 'invite_id'),
        token: _requiredString(row, 'token'),
        expiresAt: _date(row, 'expires_at'),
      );
      _pendingCreateSecret = null;
      _pendingCreateOperationId = null;
      _pendingCreateExpiresAt = null;
      _pendingCreateSessionId = null;
      return invitation;
    } catch (error) {
      if (_isTerminalMutationError(error)) {
        _pendingCreateSecret = null;
        _pendingCreateOperationId = null;
        _pendingCreateExpiresAt = null;
        _pendingCreateSessionId = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> revokeInvitation(String invitationId) async {
    await _mutation<void>(
      'revoke_friend_invite',
      {'invite_id': invitationId},
      (operationId) => _client.rpc('revoke_friend_invite', params: {
        'p_invite_id': invitationId,
        'p_operation_id': operationId,
      }),
    );
  }

  @override
  Future<List<FriendInvitationSummary>> listInvitations() async {
    final result = await _client.rpc('list_friend_invites');
    return _rows(result)
        .map(
          (row) => FriendInvitationSummary(
            id: _requiredString(row, 'invite_id', fallback: 'invitation_id'),
            expiresAt: _date(row, 'expires_at'),
            // The RPC intentionally returns booleans so the invite list never
            // exposes claim timestamps or any token material.
            claimed: row['claimed'] == true ||
                row['accepted'] == true ||
                row['claimed_at'] != null ||
                row['accepted_at'] != null,
            revoked: row['revoked'] == true || row['revoked_at'] != null,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<FriendInvitationPreview> previewInvitation(String token) async {
    final row = await _single('preview_friend_invite', {
      'p_token': token,
    });
    return FriendInvitationPreview(
      invitationId: _optionalString(row, 'invitation_id') ??
          _optionalString(row, 'invite_id') ??
          _optionalString(row, 'id'),
      issuerUserId: _optionalString(row, 'issuer_user_id'),
      issuerDisplayName: _optionalString(row, 'issuer_display_name') ??
          _optionalString(row, 'display_name'),
      expiresAt: _optionalDate(row, 'expires_at'),
      status: _requiredString(row, 'status', fallback: 'state'),
    );
  }

  @override
  Future<FriendRelationship> requestInvitation(String token) async {
    final row = await _mutation<Map<String, Object?>>(
      'request_friend_from_invite',
      {'token_digest': _digest(token)},
      (operationId) => _single('request_friend_from_invite', {
        'p_token': token,
        'p_operation_id': operationId,
      }),
    );
    if (row['other_user_id'] == null && row['friend_user_id'] == null) {
      return FriendRelationship(
        id: _requiredString(row, 'friendship_id', fallback: 'id'),
        otherUserId: _requiredString(row, 'issuer_user_id'),
        otherDisplayName: '友だち',
        status: FriendshipStatus.values.firstWhere(
          (value) => value.name == row['status']?.toString(),
          orElse: () => FriendshipStatus.pending,
        ),
        isRequester: true,
        incarnation: row['incarnation']?.toString(),
        revision: _int(row['revision']),
      );
    }
    return _relationship(row);
  }

  @override
  Future<FriendRelationship> respondToRequest({
    required FriendRelationship relationship,
    required bool accept,
  }) async {
    final function = accept ? 'accept_friend_request' : 'reject_friend_request';
    final args = {
      'friendship_id': relationship.id,
      'incarnation': relationship.incarnation,
      'expected_revision': relationship.revision,
    };
    final row = await _mutation<Map<String, Object?>>(
      function,
      args,
      (operationId) => _single(function, {
        'p_friendship_id': relationship.id,
        'p_incarnation': relationship.incarnation,
        'p_expected_revision': relationship.revision,
        'p_operation_id': operationId,
      }),
    );
    if (row['other_user_id'] == null && row['friend_user_id'] == null) {
      return relationship.copyWith(
        status: FriendshipStatus.values.firstWhere(
          (value) => value.name == row['status']?.toString(),
          orElse: () =>
              accept ? FriendshipStatus.accepted : FriendshipStatus.rejected,
        ),
        incarnation: row['incarnation']?.toString(),
        revision: _int(row['revision']),
      );
    }
    return _relationship(row);
  }

  @override
  Future<void> cancelRequest(FriendRelationship relationship) async {
    await _mutation<void>(
      'cancel_friend_request',
      {
        'friendship_id': relationship.id,
        'incarnation': relationship.incarnation,
        'expected_revision': relationship.revision,
      },
      (operationId) => _client.rpc('cancel_friend_request', params: {
        'p_friendship_id': relationship.id,
        'p_incarnation': relationship.incarnation,
        'p_expected_revision': relationship.revision,
        'p_operation_id': operationId,
      }),
    );
  }

  @override
  Future<List<FriendRelationship>> listRelationships() async {
    final result = await _client.rpc('list_friendships');
    return _rows(result)
        .where(
            (row) => row['status'] == 'pending' || row['status'] == 'accepted')
        .map(_relationship)
        .toList(growable: false);
  }

  @override
  Future<void> setVisibility({
    required FriendRelationship relationship,
    required String friendUserId,
    required String level,
    required String targetKind,
    String? targetId,
    String? targetValue,
    bool inherit = false,
  }) async {
    final params = <String, Object?>{
      'p_friendship_id': relationship.id,
      'p_incarnation': relationship.incarnation,
      'p_friend_user_id': friendUserId,
      'p_target_kind': targetKind,
      'p_target_id': targetId,
      'p_target_value': targetValue,
      'p_expected_revision': relationship.revision,
    };
    if (inherit) {
      await _mutation<void>(
        'inherit_friend_visibility',
        {...params, 'level': level, 'inherit': true},
        (operationId) => _client.rpc(
          'inherit_friend_visibility',
          params: {...params, 'p_operation_id': operationId},
        ),
      );
    } else {
      await _mutation<void>(
        'set_friend_visibility',
        {...params, 'level': level, 'inherit': false},
        (operationId) => _client.rpc(
          'set_friend_visibility',
          params: {
            ...params,
            'p_visibility_level': level,
            'p_operation_id': operationId,
          },
        ),
      );
    }
  }

  @override
  Future<List<FriendVisibilityRule>> listVisibilityRules(
    FriendRelationship relationship,
  ) async {
    final result = await _client.rpc('list_friend_visibility_rules', params: {
      'p_friendship_id': relationship.id,
      'p_friend_user_id': relationship.otherUserId,
      'p_incarnation': relationship.incarnation,
    });
    return _rows(result)
        .map(
          (row) => FriendVisibilityRule(
            targetKind: (row['target_kind'] ?? 'default').toString(),
            targetId: _optionalString(row, 'target_id'),
            targetValue: _optionalString(row, 'target_value'),
            level: VisibilityLevel.fromWire(
              (row['visibility_level'] ?? 'PRIVATE').toString(),
            ),
            inherited: row['mode']?.toString() == 'inherit',
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<FriendScheduleSnapshot> fetchSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    return _schedule(
      'get_friend_schedule',
      friendUserId,
      termId,
      rangeStart,
      rangeEnd,
    );
  }

  @override
  Future<FriendScheduleSnapshot> previewSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    return _schedule(
      'preview_friend_schedule',
      friendUserId,
      termId,
      rangeStart,
      rangeEnd,
    );
  }

  @override
  Future<List<FriendTerm>> listFriendTerms(String friendUserId) async {
    final result = await _client.rpc('list_friend_terms', params: {
      'p_owner_user_id': friendUserId,
    });
    return _rows(result)
        .map(
          (row) => FriendTerm(
            id: _requiredString(row, 'term_id', fallback: 'id'),
            name: (row['name'] ?? '学期').toString(),
            academicYear: _int(row['academic_year']) ?? 0,
            startDate: _date(row, 'start_date'),
            endDate: _date(row, 'end_date'),
          ),
        )
        .toList(growable: false);
  }

  Future<T> _mutation<T>(
    String name,
    Map<String, Object?> intent,
    Future<T> Function(String operationId) invoke,
  ) async {
    final key = _mutationKey(name, intent);
    final operationId = _pendingOperationIds[key] ??= const Uuid().v4();
    try {
      final value = await invoke(operationId);
      _pendingOperationIds.remove(key);
      return value;
    } on PostgrestException catch (error) {
      // Transport failures are deliberately retained for a same-intent
      // retry.  Server-side validation/conflict failures are terminal and
      // must not replay a stale receipt on the next user action.
      if (_isTerminalMutationError(error)) _pendingOperationIds.remove(key);
      if (name == 'request_friend_from_invite' &&
          error.code == '22023' &&
          error.message == 'cannot invite yourself') {
        throw const ValidationError('自分自身には友だち申請を送れません。');
      }
      rethrow;
    }
  }

  String _mutationKey(String name, Map<String, Object?> intent) {
    final sessionId = _client.auth.currentUser?.id ?? 'signed-out';
    final canonical = _canonical(intent);
    return '$sessionId|$name|${_digest(jsonEncode(canonical))}';
  }

  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

  Object? _canonical(Object? value) {
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((a, b) => '${a.key}'.compareTo('${b.key}'));
      return <String, Object?>{
        for (final entry in entries) '${entry.key}': _canonical(entry.value),
      };
    }
    if (value is Iterable) return value.map(_canonical).toList(growable: false);
    return value;
  }

  bool _isTerminalMutationError(Object error) {
    if (error is! PostgrestException) return false;
    return const {'22023', 'PT409', '42501'}.contains(error.code);
  }

  @override
  Future<void> removeFriend(FriendRelationship relationship) async {
    await _mutation<void>(
      'unfriend',
      {
        'friendship_id': relationship.id,
        'incarnation': relationship.incarnation,
        'expected_revision': relationship.revision,
      },
      (operationId) => _client.rpc('unfriend', params: {
        'p_friendship_id': relationship.id,
        'p_incarnation': relationship.incarnation,
        'p_expected_revision': relationship.revision,
        'p_operation_id': operationId,
      }),
    );
  }

  @override
  Future<void> blockUser(String userId) async {
    await _mutation<void>(
      'block_user',
      {'user_id': userId},
      (operationId) => _client.rpc('block_user', params: {
        'p_user_id': userId,
        'p_operation_id': operationId,
      }),
    );
  }

  @override
  Future<void> unblockUser(String userId) async {
    await _mutation<void>(
      'unblock_user',
      {'user_id': userId},
      (operationId) => _client.rpc('unblock_user', params: {
        'p_user_id': userId,
        'p_operation_id': operationId,
      }),
    );
  }

  @override
  Future<Map<String, String>> listBlockedUsers() async {
    final result = await _client.rpc('list_blocked_users');
    return Map<String, String>.fromEntries(
      _rows(result).map((row) {
        final id = (row['blocked_user_id'] ?? row['user_id']).toString();
        final name = (row['display_name'] ?? 'ブロック中の利用者').toString();
        return MapEntry(id, name);
      }).where((entry) => entry.key.isNotEmpty),
    );
  }

  Future<FriendScheduleSnapshot> _schedule(
    String function,
    String friendUserId,
    String termId,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) async {
    final result = await _client.rpc(function, params: {
      function == 'get_friend_schedule'
          ? 'p_owner_user_id'
          : 'p_friend_user_id': friendUserId,
      'p_term_id': termId,
      'p_range_start': rangeStart.toUtc().toIso8601String(),
      'p_range_end': rangeEnd.toUtc().toIso8601String(),
    });
    if (result is! Map ||
        result['allowed'] is! bool ||
        result['revision'] == null) {
      throw const UnknownAppError('共有予定の応答を確認できませんでした');
    }
    final envelope = Map<String, Object?>.from(result);
    final rowsPayload = envelope['rows'];
    if (rowsPayload is! Map || rowsPayload['items'] is! List) {
      throw const UnknownAppError('共有予定の応答を確認できませんでした');
    }
    final rows = _rows(rowsPayload['items']);
    if (rows.length != (rowsPayload['items'] as List).length ||
        rows.any((row) =>
            row['item_id'] is! String ||
            (row['item_id'] as String).trim().isEmpty)) {
      throw const UnknownAppError('共有予定の応答を確認できませんでした');
    }
    final allowed = envelope['allowed'] as bool;
    if (!allowed && rows.isNotEmpty) {
      throw const UnknownAppError('共有予定の応答を確認できませんでした');
    }
    final revision = envelope['revision'].toString();
    return FriendScheduleSnapshot(
      allowed: allowed,
      revision: revision,
      rows: rows
          .map(
            (row) => _event(
              row,
              function == 'preview_friend_schedule'
                  ? (_client.auth.currentUser?.id ?? friendUserId)
                  : friendUserId,
            ),
          )
          .toList(growable: false),
    );
  }

  FriendSharedEvent _event(
    Map<String, Object?> row,
    String fallbackOwnerUserId,
  ) {
    return FriendSharedEvent(
      eventId: _requiredString(
        row,
        'item_id',
      ),
      ownerUserId: _optionalString(row, 'owner_user_id') ??
          _optionalString(row, 'source_owner_user_id') ??
          fallbackOwnerUserId,
      startAt: _date(row, 'start_at'),
      endAt: _date(row, 'end_at'),
      visibilityLevel: VisibilityLevel.fromWire(
        _requiredString(row, 'visibility_level'),
      ),
      title: row['title'] as String?,
      kind: row['kind'] as String?,
      instructorName: row['instructor_name'] as String?,
      location: row['location'] as String?,
      description: row['description'] as String?,
    );
  }

  FriendRelationship _relationship(Map<String, Object?> row) {
    final status = FriendshipStatus.values.firstWhere(
      (value) => value.name == (row['status'] ?? '').toString(),
      orElse: () => FriendshipStatus.pending,
    );
    return FriendRelationship(
      id: _requiredString(row, 'friendship_id', fallback: 'id'),
      otherUserId: _requiredString(
        row,
        'other_user_id',
        fallback: 'friend_user_id',
      ),
      otherDisplayName:
          (row['other_display_name'] ?? row['display_name'] ?? '友だち')
              .toString(),
      status: status,
      visibilityLevel: VisibilityLevel.fromWire(
        (row['visibility_level'] ?? 'PRIVATE').toString(),
      ),
      isRequester: (row['is_requester'] == true) ||
          row['viewer_role']?.toString() == 'requester',
      incarnation: row['incarnation']?.toString(),
      revision: _int(row['revision']),
    );
  }

  Future<Map<String, Object?>> _single(
    String function,
    Map<String, Object?> params,
  ) async {
    final result = await _client.rpc(function, params: params);
    final rows = _rows(result);
    if (rows.isEmpty) throw const UnknownAppError('サーバー応答を確認できませんでした');
    return rows.first;
  }

  List<Map<String, Object?>> _rows(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList(growable: false);
    }
    if (value is Map) return [Map<String, Object?>.from(value)];
    return const [];
  }

  String _requiredString(
    Map<String, Object?> row,
    String key, {
    String? fallback,
  }) {
    final value = row[key] ?? (fallback == null ? null : row[fallback]);
    if (value is! String || value.trim().isEmpty) {
      throw const UnknownAppError('サーバー応答の形式を確認できませんでした');
    }
    return value;
  }

  String? _optionalString(Map<String, Object?> row, String key) {
    final value = row[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  String _newSecret() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  int? _int(Object? value) => value is int ? value : int.tryParse('$value');

  DateTime _date(Map<String, Object?> row, String key) {
    final value = row[key];
    final parsed = value is DateTime ? value : DateTime.tryParse('$value');
    if (parsed == null) {
      throw const UnknownAppError('サーバー応答の日時を確認できませんでした');
    }
    return parsed.toUtc();
  }

  DateTime? _optionalDate(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value == null) return null;
    final parsed = value is DateTime ? value : DateTime.tryParse('$value');
    return parsed?.toUtc();
  }
}

class UnavailableFriendRepository implements FriendRepository {
  const UnavailableFriendRepository();

  Never _fail() => throw const NetworkError('共有機能へ接続できません');

  @override
  Future<FriendUsernameProfile?> getMyFriendUsername() async => null;

  @override
  Future<FriendUsernameProfile> setMyFriendUsername({
    required String? username,
    required bool searchable,
  }) =>
      Future.error(_fail());

  @override
  Future<List<FriendUsernameMatch>> findFriendByUsername(String username) =>
      Future.error(_fail());

  @override
  Future<FriendRelationship> requestFriendByUsername({
    required FriendUsernameMatch target,
    required String shownUsername,
    required String operationId,
  }) =>
      Future.error(_fail());

  @override
  Future<FriendInvitation> createInvitation({required DateTime expiresAt}) =>
      Future.error(_fail());
  @override
  Future<void> revokeInvitation(String invitationId) => Future.error(_fail());
  @override
  Future<List<FriendInvitationSummary>> listInvitations() =>
      Future.error(_fail());
  @override
  Future<FriendInvitationPreview> previewInvitation(String token) =>
      Future.error(_fail());
  @override
  Future<FriendRelationship> requestInvitation(String token) =>
      Future.error(_fail());
  @override
  Future<FriendRelationship> respondToRequest({
    required FriendRelationship relationship,
    required bool accept,
  }) =>
      Future.error(_fail());
  @override
  Future<void> cancelRequest(FriendRelationship relationship) =>
      Future.error(_fail());
  @override
  Future<List<FriendRelationship>> listRelationships() => Future.error(_fail());
  @override
  Future<void> setVisibility(
          {required FriendRelationship relationship,
          required String friendUserId,
          required String level,
          required String targetKind,
          String? targetId,
          String? targetValue,
          bool inherit = false}) =>
      Future.error(_fail());
  @override
  Future<List<FriendVisibilityRule>> listVisibilityRules(
    FriendRelationship relationship,
  ) =>
      Future.error(_fail());
  @override
  Future<FriendScheduleSnapshot> fetchSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) =>
      Future.error(_fail());
  @override
  Future<FriendScheduleSnapshot> previewSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) =>
      Future.error(_fail());
  @override
  Future<List<FriendTerm>> listFriendTerms(String friendUserId) =>
      Future.error(_fail());
  @override
  Future<void> removeFriend(FriendRelationship relationship) =>
      Future.error(_fail());
  @override
  Future<void> blockUser(String userId) => Future.error(_fail());
  @override
  Future<void> unblockUser(String userId) => Future.error(_fail());
  @override
  Future<Map<String, String>> listBlockedUsers() => Future.error(_fail());
}
