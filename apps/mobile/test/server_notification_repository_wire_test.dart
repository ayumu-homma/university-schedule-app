import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/features/notification/data/supabase_server_notification_repository.dart';

void main() {
  test('server inbox, targeted invitations, and read/respond RPCs are scoped',
      () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = await _client((request) async {
      final name = request.url.pathSegments.last;
      final decoded = request.body.isEmpty ? null : jsonDecode(request.body);
      final body = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      calls[name] = body;
      final response = switch (name) {
        'list_server_notification_inbox' => [
            {
              'inbox_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'notification_type': 'group_event_updated',
              'group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'event_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              'invitation_id': null,
              'created_at': '2026-09-23T10:00:00Z',
              'read_at': null,
            },
          ],
        'mark_server_notification_read' => true,
        'list_my_targeted_group_invitations' => [
            {
              'invitation_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              'group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'group_name': 'Seminar group',
              'inviter_user_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              'inviter_display_name': 'Friend',
              'created_at': '2026-09-23T10:00:00Z',
              'expires_at': '2026-09-25T10:00:00Z',
              'status': 'pending',
            },
          ],
        'create_targeted_group_invitation' => [
            {
              'invitation_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
              'group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'invitee_user_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              'status': 'pending',
              'expires_at': '2026-09-25T10:00:00Z',
            },
          ],
        'respond_targeted_group_invitation' => [
            {
              'invitation_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              'group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'status': 'accepted',
            },
          ],
        _ => throw StateError('unexpected RPC $name'),
      };
      return http.Response(jsonEncode(response), 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    final repository = SupabaseServerNotificationRepository(client);
    final before = DateTime.utc(2026, 9, 24);
    final rows = await repository.list(before: before, limit: 17);
    expect(rows.single.groupId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(rows.single.type, 'group_event_updated');
    expect(rows.single.eventId, 'cccccccc-cccc-4ccc-8ccc-cccccccccccc');
    expect(calls['list_server_notification_inbox'], {
      'p_before': before.toIso8601String(),
      'p_limit': 17,
      'p_before_id': null,
    });

    await repository.list(before: before, beforeId: rows.single.id, limit: 17);
    expect(calls['list_server_notification_inbox'], {
      'p_before': before.toIso8601String(),
      'p_limit': 17,
      'p_before_id': rows.single.id,
    });

    expect(await repository.markRead(rows.single.id), isTrue);
    final invitations = await repository.listInvitations();
    expect(invitations.single.groupName, 'Seminar group');
    final expiresAt = DateTime.utc(2026, 9, 25, 10);
    await repository.inviteFriendToGroup(
      groupId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      inviteeUserId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      expiresAt: expiresAt,
    );
    await repository.respondToInvitation(invitations.single.id, accept: true);
    expect(
        calls['mark_server_notification_read'], {'p_inbox_id': rows.single.id});
    expect(calls['respond_targeted_group_invitation'], {
      'p_invitation_id': invitations.single.id,
      'p_accept': true,
    });
    expect(calls['create_targeted_group_invitation'], {
      'p_group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'p_invitee_user_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      'p_expires_at': expiresAt.toIso8601String(),
    });
    await client.dispose();
  });

  test('unknown notification types and malformed identifiers fail closed',
      () async {
    final client = await _client((request) async => http.Response(
          jsonEncode([
            {
              'inbox_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'notification_type': 'secret_message',
              'group_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'event_id': null,
              'invitation_id': null,
              'created_at': '2026-09-23T10:00:00Z',
              'read_at': null,
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ));
    final repository = SupabaseServerNotificationRepository(client);
    await expectLater(repository.list(), throwsFormatException);
    await client.dispose();
  });
}

Future<SupabaseClient> _client(
    Future<http.Response> Function(http.Request) handler) async {
  return SupabaseClient(
    'http://127.0.0.1:55321',
    'public-anon-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response(response.body, response.statusCode,
          headers: {'content-type': 'application/json'}, request: request);
    }),
  );
}
