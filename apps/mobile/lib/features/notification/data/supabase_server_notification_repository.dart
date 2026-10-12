import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/server_notification.dart';
import '../domain/server_notification_repository.dart';

class SupabaseServerNotificationRepository
    implements ServerNotificationRepository {
  SupabaseServerNotificationRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ServerNotification>> list({
    DateTime? before,
    String? beforeId,
    int limit = 30,
  }) async {
    final response = await _client.rpc(
      'list_server_notification_inbox',
      params: {
        'p_before': before?.toUtc().toIso8601String(),
        'p_limit': limit,
        'p_before_id': beforeId,
      },
    );
    if (response is! List) {
      throw const FormatException('Invalid server notification page.');
    }
    return response
        .map((row) => ServerNotification.fromJson(
              Map<String, dynamic>.from(row as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<bool> markRead(String inboxId) async {
    final result = await _client.rpc(
      'mark_server_notification_read',
      params: {'p_inbox_id': inboxId},
    );
    if (result is! bool) {
      throw const FormatException('Invalid notification read response.');
    }
    return result;
  }

  @override
  Future<List<TargetedGroupInvitation>> listInvitations() async {
    final response = await _client.rpc('list_my_targeted_group_invitations');
    if (response is! List) {
      throw const FormatException('Invalid targeted invitation page.');
    }
    return response
        .map((row) => TargetedGroupInvitation.fromJson(
              Map<String, dynamic>.from(row as Map),
            ))
        .toList(growable: false);
  }

  @override
  Future<void> inviteFriendToGroup({
    required String groupId,
    required String inviteeUserId,
    required DateTime expiresAt,
  }) async {
    final response = await _client.rpc(
      'create_targeted_group_invitation',
      params: {
        'p_group_id': groupId,
        'p_invitee_user_id': inviteeUserId,
        'p_expires_at': expiresAt.toUtc().toIso8601String(),
      },
    );
    if (response is! List || response.length != 1) {
      throw const FormatException('Invalid targeted invitation response.');
    }
    final result = Map<String, dynamic>.from(response.single as Map);
    if (result['status'] != 'pending' ||
        result['group_id'] != groupId ||
        result['invitee_user_id'] != inviteeUserId ||
        result['invitation_id'] is! String) {
      throw const FormatException('Targeted invitation was not created.');
    }
  }

  @override
  Future<void> respondToInvitation(String invitationId,
      {required bool accept}) async {
    final response = await _client.rpc(
      'respond_targeted_group_invitation',
      params: {'p_invitation_id': invitationId, 'p_accept': accept},
    );
    if (response is! List || response.length != 1) {
      throw const FormatException('Invalid invitation response.');
    }
    final result = Map<String, dynamic>.from(response.single as Map);
    final status = result['status'];
    if (status != (accept ? 'accepted' : 'declined')) {
      throw const FormatException('Invitation state did not update.');
    }
  }
}
