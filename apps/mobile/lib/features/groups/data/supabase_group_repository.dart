// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../domain/group_models.dart';
import '../domain/group_repository.dart';

class SupabaseGroupRepository implements GroupRepository {
  SupabaseGroupRepository(this._client);
  final SupabaseClient _client;
  final Map<String, String> _pending = {};
  String? _inviteAttemptKey;
  String? _inviteSecret;
  String? _inviteOperationId;

  @override
  Future<List<GroupSummary>> listGroups() async {
    final rows = _rows(await _client.rpc('list_my_groups'));
    return rows.map(_group).toList(growable: false);
  }

  @override
  Future<GroupSummary> createGroup(
          {required String name,
          required String type,
          String? description,
          required String eventCreatePolicy}) =>
      _mutate(
          'create_group',
          {
            'name': name,
            'type': type,
            'description': description,
            'event_create_policy': eventCreatePolicy
          },
          (op) async => _group(_one(await _client.rpc('create_group', params: {
                'p_name': name,
                'p_type': type,
                'p_description': description,
                'p_event_create_policy': eventCreatePolicy,
                'p_operation_id': op
              }))));

  @override
  Future<GroupSummary> getGroup(String groupId) async {
    final group =
        _one(await _client.rpc('get_group', params: {'p_group_id': groupId}));
    final visibility = await _client
        .rpc('get_group_default_visibility', params: {'p_group_id': groupId});
    if (visibility is! String ||
        !const {'PRIVATE', 'BUSY_ONLY', 'TITLE_ONLY', 'FULL'}
            .contains(visibility)) {
      throw const UnknownAppError('グループ公開範囲を確認できませんでした');
    }
    return _group(group, defaultVisibility: visibility);
  }

  @override
  Future<String> setGroupDefaultVisibility({
    required String groupId,
    required String visibility,
  }) =>
      _mutate(
        'set_group_default_visibility',
        {'group_id': groupId, 'default_visibility': visibility},
        (op) async {
          final result =
              await _client.rpc('set_group_default_visibility', params: {
            'p_group_id': groupId,
            'p_default_visibility': visibility,
            'p_operation_id': op,
          });
          final row = _one(result);
          final returnedVisibility = _string(row, 'default_visibility');
          if (!const {'PRIVATE', 'BUSY_ONLY', 'TITLE_ONLY', 'FULL'}
              .contains(returnedVisibility)) {
            throw const UnknownAppError('グループ公開範囲を確認できませんでした');
          }
          return returnedVisibility;
        },
      );

  @override
  Future<GroupSummary> updateGroup(
          {required String groupId,
          required String name,
          required String type,
          String? description,
          required String eventCreatePolicy}) =>
      _mutate(
          'update_group',
          {
            'group_id': groupId,
            'name': name,
            'type': type,
            'description': description,
            'event_create_policy': eventCreatePolicy
          },
          (op) async => _group(_one(await _client.rpc('update_group', params: {
                'p_group_id': groupId,
                'p_name': name,
                'p_type': type,
                'p_description': description,
                'p_event_create_policy': eventCreatePolicy,
                'p_operation_id': op
              }))));

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async =>
      _rows(await _client
              .rpc('list_group_members', params: {'p_group_id': groupId}))
          .map(_member)
          .toList(growable: false);

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) async {
    final response = await _client.rpc('list_group_member_blocked_users',
        params: {'p_group_id': groupId});
    if (response is! List) {
      throw const UnknownAppError('グループ応答の形式を確認できませんでした');
    }
    final userIds = <String>{};
    final uuidPattern = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
    for (final value in response) {
      if (value is! Map) {
        throw const UnknownAppError('グループ応答の形式を確認できませんでした');
      }
      final userId = value['user_id'];
      if (userId is! String || !uuidPattern.hasMatch(userId)) {
        throw const UnknownAppError('グループ応答の形式を確認できませんでした');
      }
      userIds.add(userId);
    }
    return userIds;
  }

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async =>
      _rows(await _client
              .rpc('list_group_invites', params: {'p_group_id': groupId}))
          .map((r) => GroupInviteSummary(
              id: _string(r, 'invite_id'),
              expiresAt: _date(r, 'expires_at'),
              maxUses: _int(r['max_uses']),
              usedCount: _int(r['used_count']) ?? 0,
              revoked: r['revoked'] == true || r['revoked_at'] != null))
          .toList(growable: false);

  @override
  Future<GroupInviteCreated> createInvite(
          {required String groupId,
          required DateTime expiresAt,
          int? maxUses}) =>
      _createInviteWithStableAttempt(groupId, expiresAt, maxUses);

  Future<GroupInviteCreated> _createInviteWithStableAttempt(
      String groupId, DateTime expiresAt, int? maxUses) async {
    final key =
        '${_client.auth.currentUser?.id}|$groupId|${expiresAt.toUtc().toIso8601String()}|$maxUses';
    if (_inviteAttemptKey != key ||
        _inviteSecret == null ||
        _inviteOperationId == null) {
      _inviteAttemptKey = key;
      _inviteSecret = _secret();
      _inviteOperationId = const Uuid().v4();
    }
    try {
      final row = _one(await _client.rpc('create_group_invite', params: {
        'p_group_id': groupId,
        'p_secret': _inviteSecret,
        'p_expires_at': expiresAt.toUtc().toIso8601String(),
        'p_max_uses': maxUses,
        'p_operation_id': _inviteOperationId
      }));
      final result = GroupInviteCreated(
          id: _string(row, 'invite_id'),
          token: _string(row, 'token', fallback: 'secret'),
          expiresAt: _date(row, 'expires_at'));
      _inviteAttemptKey = null;
      _inviteSecret = null;
      _inviteOperationId = null;
      return result;
    } on PostgrestException catch (e) {
      if (const {'22023', 'PT409', '42501', '40001'}.contains(e.code)) {
        _inviteAttemptKey = null;
        _inviteSecret = null;
        _inviteOperationId = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> revokeInvite(String groupId, String invitationId) => _mutate(
          'revoke_group_invite',
          {'group_id': groupId, 'invite_id': invitationId}, (op) async {
        await _client.rpc('revoke_group_invite', params: {
          'p_group_id': groupId,
          'p_invite_id': invitationId,
          'p_operation_id': op
        });
      });

  @override
  Future<GroupInvitePreview> previewInvite(String token) async {
    final r = _one(
        await _client.rpc('preview_group_invite', params: {'p_token': token}));
    return GroupInvitePreview(
        invitationId: _string(r, 'invite_id'),
        groupId: _string(r, 'group_id'),
        groupName: _string(r, 'group_name'),
        expiresAt: _date(r, 'expires_at'),
        status: _string(r, 'status'));
  }

  @override
  Future<GroupSummary> joinInvite(String token) => _mutate(
      'join_group_invite',
      {'token': _digest(token)},
      (op) async => _group(_one(await _client.rpc('join_group_invite',
          params: {'p_token': token, 'p_operation_id': op}))));

  @override
  Future<void> leaveGroup(String groupId) =>
      _mutate('leave_group', {'group_id': groupId}, (op) async {
        await _client.rpc('leave_group',
            params: {'p_group_id': groupId, 'p_operation_id': op});
      });
  @override
  Future<void> removeMember(String groupId, String userId) =>
      _mutate('remove_group_member', {'group_id': groupId, 'user_id': userId},
          (op) async {
        await _client.rpc('remove_group_member', params: {
          'p_group_id': groupId,
          'p_user_id': userId,
          'p_operation_id': op
        });
      });
  @override
  Future<void> changeMemberRole(
          String groupId, String userId, GroupRole role) =>
      _mutate('change_group_member_role', {
        'group_id': groupId,
        'user_id': userId,
        'role': role.name
      }, (op) async {
        await _client.rpc('change_group_member_role', params: {
          'p_group_id': groupId,
          'p_user_id': userId,
          'p_role': role.name,
          'p_operation_id': op
        });
      });
  @override
  Future<void> transferOwnership(String groupId, String userId) => _mutate(
          'transfer_group_ownership', {'group_id': groupId, 'user_id': userId},
          (op) async {
        await _client.rpc('transfer_group_ownership', params: {
          'p_group_id': groupId,
          'p_user_id': userId,
          'p_operation_id': op
        });
      });
  @override
  Future<void> deleteGroup(String groupId) =>
      _mutate('delete_group', {'group_id': groupId}, (op) async {
        await _client.rpc('delete_group',
            params: {'p_group_id': groupId, 'p_operation_id': op});
      });

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      _rows(await _client
              .rpc('list_group_events', params: {'p_group_id': groupId}))
          .map(_event)
          .toList(growable: false);

  @override
  Future<GroupEventSummary> getGroupEvent(String eventId) async => _event(_one(
      await _client.rpc('get_group_event', params: {'p_event_id': eventId})));

  @override
  Future<List<GroupEventRsvp>> listGroupEventRsvps(String eventId) async =>
      _rows(await _client
              .rpc('list_group_event_rsvps', params: {'p_event_id': eventId}))
          .map(_rsvp)
          .toList(growable: false);

  @override
  Future<GroupEventSummary> createGroupEvent(
          {required String groupId,
          required String title,
          required DateTime startAt,
          required DateTime endAt,
          String? location,
          String? description}) =>
      _mutate(
          'create_group_event',
          {
            'group_id': groupId,
            'title': title,
            'start_at': startAt.toUtc().toIso8601String(),
            'end_at': endAt.toUtc().toIso8601String(),
            'location': location,
            'description': description,
          },
          (op) async =>
              _event(_one(await _client.rpc('create_group_event', params: {
                'p_group_id': groupId,
                'p_title': title,
                'p_start_at': startAt.toUtc().toIso8601String(),
                'p_end_at': endAt.toUtc().toIso8601String(),
                'p_location': location,
                'p_description': description,
                'p_operation_id': op,
              }))));

  @override
  Future<GroupEventSummary> updateGroupEvent(
          {required String eventId,
          required String title,
          required DateTime startAt,
          required DateTime endAt,
          String? location,
          String? description,
          required int expectedVersion}) =>
      _mutate(
          'update_group_event',
          {
            'event_id': eventId,
            'title': title,
            'start_at': startAt.toUtc().toIso8601String(),
            'end_at': endAt.toUtc().toIso8601String(),
            'location': location,
            'description': description,
            'expected_version': expectedVersion
          },
          (op) async =>
              _event(_one(await _client.rpc('update_group_event', params: {
                'p_event_id': eventId,
                'p_title': title,
                'p_start_at': startAt.toUtc().toIso8601String(),
                'p_end_at': endAt.toUtc().toIso8601String(),
                'p_location': location,
                'p_description': description,
                'p_expected_version': expectedVersion,
                'p_operation_id': op,
              }))),
          conflictMessage: '予定が更新されています。最新版を確認して再編集してください。');

  @override
  Future<void> cancelGroupEvent(String eventId, int expectedVersion) => _mutate(
          'cancel_group_event',
          {'event_id': eventId, 'expected_version': expectedVersion},
          (op) async {
        await _client.rpc('cancel_group_event', params: {
          'p_event_id': eventId,
          'p_expected_version': expectedVersion,
          'p_operation_id': op,
        });
      });

  @override
  Future<GroupEventRsvp> setGroupEventRsvp(String eventId, String status) =>
      _mutate(
          'set_group_event_rsvp',
          {'event_id': eventId, 'status': status},
          (op) async =>
              _rsvp(_one(await _client.rpc('set_group_event_rsvp', params: {
                'p_event_id': eventId,
                'p_status': status,
                'p_operation_id': op,
              }))));

  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) async {
    final row = _one(await _client.rpc('get_group_event_ugc', params: {
      'p_event_id': eventId,
    }));
    final content = GroupEventContent(
      eventId: _string(row, 'event_id'),
      groupId: _string(row, 'group_id'),
      generation: _string(row, 'generation'),
      rsvps: _jsonRows(row['rsvps']).map(_rsvp).toList(growable: false),
      comments:
          _jsonRows(row['comments']).map(_comment).toList(growable: false),
      reactions:
          _jsonRows(row['reactions']).map(_reaction).toList(growable: false),
    );
    if (content.eventId != eventId || content.generation.isEmpty) {
      throw const PermissionError('予定の表示権限を確認できませんでした');
    }
    return content;
  }

  @override
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  }) async {
    final row = _one(await _client.rpc('validate_group_event_ugc', params: {
      'p_event_id': eventId,
      'p_generation': generation,
    }));
    return row['valid'] == true && row['generation'] == generation;
  }

  @override
  Future<List<GroupEventComment>> listGroupEventComments(
          String eventId) async =>
      _rows(await _client.rpc('list_group_event_comments', params: {
        'p_event_id': eventId,
      }))
          .map(_comment)
          .toList(growable: false);

  @override
  Future<GroupEventComment> createGroupEventComment(
          {required String eventId, required String body}) =>
      _mutate(
          'create_group_event_comment',
          {'event_id': eventId, 'body': body},
          (op) async => _comment(
                  _one(await _client.rpc('create_group_event_comment', params: {
                'p_event_id': eventId,
                'p_body': body,
                'p_operation_id': op,
              }))));

  @override
  Future<GroupEventComment> updateGroupEventComment({
    required String commentId,
    required String body,
    required int expectedVersion,
  }) =>
      _mutate(
          'update_group_event_comment',
          {
            'comment_id': commentId,
            'body': body,
            'expected_version': expectedVersion
          },
          (op) async => _comment(
                  _one(await _client.rpc('update_group_event_comment', params: {
                'p_comment_id': commentId,
                'p_body': body,
                'p_expected_version': expectedVersion,
                'p_operation_id': op,
              }))),
          conflictMessage: 'コメントが更新されています。最新版を確認して再編集してください。');

  @override
  Future<void> deleteGroupEventComment(
          {required String commentId, required int expectedVersion}) =>
      _mutate('delete_group_event_comment', {
        'comment_id': commentId,
        'expected_version': expectedVersion
      }, (op) async {
        await _client.rpc('delete_group_event_comment', params: {
          'p_comment_id': commentId,
          'p_expected_version': expectedVersion,
          'p_operation_id': op,
        });
      });

  @override
  Future<void> moderateDeleteGroupEventComment(String commentId) =>
      _mutate('moderate_delete_group_event_comment', {'comment_id': commentId},
          (op) async {
        await _client.rpc('moderate_delete_group_event_comment', params: {
          'p_comment_id': commentId,
          'p_operation_id': op,
        });
      });

  @override
  Future<List<GroupEventReaction>> listGroupEventReactions(
          String eventId) async =>
      _rows(await _client.rpc('list_group_event_reactions', params: {
        'p_event_id': eventId,
      }))
          .map(_reaction)
          .toList(growable: false);

  @override
  Future<void> setGroupEventReaction(
          {required String eventId, required String reaction}) =>
      _mutate('set_group_event_reaction',
          {'event_id': eventId, 'reaction': reaction}, (op) async {
        await _client.rpc('set_group_event_reaction', params: {
          'p_event_id': eventId,
          'p_reaction': reaction,
          'p_operation_id': op,
        });
      });

  @override
  Future<void> removeGroupEventReaction(
          {required String eventId, required String reaction}) =>
      _mutate('remove_group_event_reaction',
          {'event_id': eventId, 'reaction': reaction}, (op) async {
        await _client.rpc('remove_group_event_reaction', params: {
          'p_event_id': eventId,
          'p_reaction': reaction,
          'p_operation_id': op,
        });
      });

  @override
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) =>
      _mutate('create_group_content_report', {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason
      }, (op) async {
        await _client.rpc('create_group_content_report', params: {
          'p_target_type': targetType,
          'p_target_id': targetId,
          'p_reason': reason,
          'p_operation_id': op,
        });
      });

  @override
  Future<GroupAvailabilityResult> findGroupAvailability(
      {required String groupId,
      required List<String> memberIds,
      required DateTime rangeStart,
      required DateTime rangeEnd,
      required int minimumDurationMinutes}) async {
    final result = await _client.rpc('find_group_availability', params: {
      'p_group_id': groupId,
      'p_member_ids': memberIds,
      'p_range_start': rangeStart.toUtc().toIso8601String(),
      'p_range_end': rangeEnd.toUtc().toIso8601String(),
      'p_minimum_duration_minutes': minimumDurationMinutes,
    });
    if (result is! Map ||
        result['query_id'] == null ||
        result['generation'] is! String ||
        result['rows'] is! List) {
      throw const UnknownAppError('空き時間応答を確認できませんでした');
    }
    final rows = _rows(result['rows']);
    return GroupAvailabilityResult(
        memberIds: memberIds,
        queryId: result['query_id'].toString(),
        generation: result['generation'] as String,
        rows: rows
            .map((r) => GroupAvailabilityRow(
                  // The server deliberately aggregates busy intervals without
                  // member attribution. Keep the domain row shape stable for
                  // the existing free-time service, but never surface an
                  // identity inferred from the response payload.
                  memberId: (r['member_id'] ?? 'group').toString(),
                  startAt: _date(r, 'start_at'),
                  endAt: _date(r, 'end_at'),
                  visibility: _string(r, 'visibility_level'),
                ))
            .toList(growable: false));
  }

  @override
  Future<bool> validateGroupAvailability(
      {required String groupId,
      required List<String> memberIds,
      required String generation}) async {
    final result = await _client.rpc('validate_group_availability', params: {
      'p_group_id': groupId,
      'p_member_ids': memberIds,
      'p_generation': generation,
    });
    return result is Map &&
        result['valid'] == true &&
        result['generation'] == generation;
  }

  Future<T> _mutate<T>(
      String name, Map<String, Object?> intent, Future<T> Function(String) call,
      {String? conflictMessage}) async {
    final key =
        '${_client.auth.currentUser?.id}|$name|${_digest(jsonEncode(intent))}';
    final op = _pending[key] ??= const Uuid().v4();
    try {
      final value = await call(op);
      _pending.remove(key);
      return value;
    } on PostgrestException catch (e) {
      if (const {'22023', 'PT409', '42501', '40001'}.contains(e.code))
        _pending.remove(key);
      if (e.code == '40001' && conflictMessage != null) {
        throw ConflictError(conflictMessage);
      }
      rethrow;
    }
  }

  GroupSummary _group(Map<String, Object?> r,
          {String defaultVisibility = 'TITLE_ONLY'}) =>
      GroupSummary(
          id: _string(r, 'group_id', fallback: 'id'),
          name: _string(r, 'name'),
          ownerUserId: _string(r, 'owner_user_id'),
          type: _groupType(r['type']),
          description: r['description'] as String?,
          eventCreatePolicy: (r['event_create_policy'] ?? 'member').toString(),
          defaultVisibility: defaultVisibility,
          role: _role(r['role']));
  GroupMemberSummary _member(Map<String, Object?> r) => GroupMemberSummary(
      groupId: _string(r, 'group_id'),
      userId: _string(r, 'user_id'),
      displayName: (r['display_name'] ?? '利用者').toString(),
      role: _role(r['role']));
  GroupEventSummary _event(Map<String, Object?> r) => GroupEventSummary(
      eventId: _string(r, 'event_id'),
      groupId: _string(r, 'group_id'),
      title: _string(r, 'title'),
      startAt: _date(r, 'start_at'),
      endAt: _date(r, 'end_at'),
      location: r['location'] as String?,
      description: r['description'] as String?,
      createdBy: _string(r, 'created_by'),
      version: _int(r['version']) ?? 1,
      cancelled: r['cancelled'] == true);
  GroupEventRsvp _rsvp(Map<String, Object?> r) => GroupEventRsvp(
      userId: _string(r, 'user_id'),
      status: _string(r, 'status'),
      updatedAt: _dateOrNull(r['updated_at']));
  GroupEventComment _comment(Map<String, Object?> r) => GroupEventComment(
      commentId: _string(r, 'comment_id'),
      eventId: _string(r, 'event_id'),
      authorUserId: _string(r, 'author_user_id'),
      body: _string(r, 'body'),
      createdAt: _date(r, 'created_at'),
      updatedAt: _date(r, 'updated_at'),
      version: _int(r['version']) ?? 1);
  GroupEventReaction _reaction(Map<String, Object?> r) => GroupEventReaction(
      reaction: _string(r, 'reaction'),
      reactionCount: _int(r['reaction_count']) ?? 0,
      reactedByMe: r['reacted_by_me'] == true);
  List<Map<String, Object?>> _jsonRows(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map((e) => Map<String, Object?>.from(e))
          .toList(growable: false)
      : const [];
  GroupType _groupType(Object? v) => GroupType.values.firstWhere(
      (e) =>
          e.name == '$v' ||
          (e == GroupType.partTimeJob && v == 'part_time_job'),
      orElse: () => GroupType.other);
  GroupRole _role(Object? v) => GroupRole.values
      .firstWhere((e) => e.name == '$v', orElse: () => GroupRole.member);
  List<Map<String, Object?>> _rows(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map((e) => Map<String, Object?>.from(e))
          .toList(growable: false)
      : value is Map
          ? [Map<String, Object?>.from(value)]
          : const [];
  Map<String, Object?> _one(Object? value) {
    final rows = _rows(value);
    if (rows.isEmpty) throw const UnknownAppError('グループ応答を確認できませんでした');
    return rows.first;
  }

  String _string(Map<String, Object?> r, String key, {String? fallback}) {
    final v = r[key] ?? (fallback == null ? null : r[fallback]);
    if (v is! String || v.trim().isEmpty)
      throw const UnknownAppError('グループ応答の形式を確認できませんでした');
    return v;
  }

  int? _int(Object? v) => v is int ? v : int.tryParse('$v');
  DateTime _date(Map<String, Object?> r, String key) {
    final v = DateTime.tryParse('${r[key]}');
    if (v == null) throw const UnknownAppError('日時を確認できませんでした');
    return v.toUtc();
  }

  DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.tryParse('$value')?.toUtc();

  String _secret() =>
      List<int>.generate(32, (_) => Random.secure().nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
  String _digest(String value) =>
      sha256.convert(utf8.encode(value.toLowerCase())).toString();
}

class UnavailableGroupRepository implements GroupRepository {
  const UnavailableGroupRepository();
  Never _fail() => throw const NetworkError('グループ機能へ接続できません');
  @override
  Future<List<GroupSummary>> listGroups() => Future.error(_fail());
  @override
  Future<GroupSummary> createGroup(
          {required String name,
          required String type,
          String? description,
          required String eventCreatePolicy}) =>
      Future.error(_fail());
  @override
  Future<GroupSummary> getGroup(String groupId) => Future.error(_fail());
  @override
  Future<String> setGroupDefaultVisibility(
          {required String groupId, required String visibility}) =>
      Future.error(_fail());
  @override
  Future<GroupSummary> updateGroup(
          {required String groupId,
          required String name,
          required String type,
          String? description,
          required String eventCreatePolicy}) =>
      Future.error(_fail());
  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) =>
      Future.error(_fail());
  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) =>
      Future.error(_fail());
  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) =>
      Future.error(_fail());
  @override
  Future<GroupInviteCreated> createInvite(
          {required String groupId,
          required DateTime expiresAt,
          int? maxUses}) =>
      Future.error(_fail());
  @override
  Future<void> revokeInvite(String groupId, String invitationId) =>
      Future.error(_fail());
  @override
  Future<GroupInvitePreview> previewInvite(String token) =>
      Future.error(_fail());
  @override
  Future<GroupSummary> joinInvite(String token) => Future.error(_fail());
  @override
  Future<void> leaveGroup(String groupId) => Future.error(_fail());
  @override
  Future<void> removeMember(String groupId, String userId) =>
      Future.error(_fail());
  @override
  Future<void> changeMemberRole(
          String groupId, String userId, GroupRole role) =>
      Future.error(_fail());
  @override
  Future<void> transferOwnership(String groupId, String userId) =>
      Future.error(_fail());
  @override
  Future<void> deleteGroup(String groupId) => Future.error(_fail());
  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) =>
      Future.error(_fail());
  @override
  Future<GroupEventSummary> getGroupEvent(String eventId) =>
      Future.error(_fail());
  @override
  Future<List<GroupEventRsvp>> listGroupEventRsvps(String eventId) =>
      Future.error(_fail());
  @override
  Future<GroupEventSummary> createGroupEvent(
          {required String groupId,
          required String title,
          required DateTime startAt,
          required DateTime endAt,
          String? location,
          String? description}) =>
      Future.error(_fail());
  @override
  Future<GroupEventSummary> updateGroupEvent(
          {required String eventId,
          required String title,
          required DateTime startAt,
          required DateTime endAt,
          String? location,
          String? description,
          required int expectedVersion}) =>
      Future.error(_fail());
  @override
  Future<void> cancelGroupEvent(String eventId, int expectedVersion) =>
      Future.error(_fail());
  @override
  Future<GroupEventRsvp> setGroupEventRsvp(String eventId, String status) =>
      Future.error(_fail());
  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) =>
      Future.error(_fail());
  @override
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  }) =>
      Future.error(_fail());
  @override
  Future<List<GroupEventComment>> listGroupEventComments(String eventId) =>
      Future.error(_fail());
  @override
  Future<GroupEventComment> createGroupEventComment(
          {required String eventId, required String body}) =>
      Future.error(_fail());
  @override
  Future<GroupEventComment> updateGroupEventComment({
    required String commentId,
    required String body,
    required int expectedVersion,
  }) =>
      Future.error(_fail());
  @override
  Future<void> deleteGroupEventComment(
          {required String commentId, required int expectedVersion}) =>
      Future.error(_fail());
  @override
  Future<void> moderateDeleteGroupEventComment(String commentId) =>
      Future.error(_fail());
  @override
  Future<List<GroupEventReaction>> listGroupEventReactions(String eventId) =>
      Future.error(_fail());
  @override
  Future<void> setGroupEventReaction(
          {required String eventId, required String reaction}) =>
      Future.error(_fail());
  @override
  Future<void> removeGroupEventReaction(
          {required String eventId, required String reaction}) =>
      Future.error(_fail());
  @override
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) =>
      Future.error(_fail());
  @override
  Future<GroupAvailabilityResult> findGroupAvailability(
          {required String groupId,
          required List<String> memberIds,
          required DateTime rangeStart,
          required DateTime rangeEnd,
          required int minimumDurationMinutes}) =>
      Future.error(_fail());
  @override
  Future<bool> validateGroupAvailability(
          {required String groupId,
          required List<String> memberIds,
          required String generation}) =>
      Future.error(_fail());
}
