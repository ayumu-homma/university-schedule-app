import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';

void main() {
  test('create invite keeps secret and operation across transport retry',
      () async {
    final calls = <Map<String, dynamic>>[];
    var attempt = 0;
    final client = await _client((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      calls.add(body);
      if (++attempt == 1) throw const SocketException('reset');
      return http.Response(
          jsonEncode({
            'invite_id': 'invite-1',
            'token': 'token-1',
            'expires_at': '2026-10-01T00:00:00Z',
          }),
          200);
    });
    final repo = SupabaseGroupRepository(client);
    final expires = DateTime.utc(2026, 10);
    await expectLater(repo.createInvite(groupId: 'group-1', expiresAt: expires),
        throwsA(isA<SocketException>()));
    await repo.createInvite(groupId: 'group-1', expiresAt: expires);
    expect(calls[0]['p_secret'], calls[1]['p_secret']);
    expect(calls[0]['p_operation_id'], calls[1]['p_operation_id']);
    await client.dispose();
  });

  test(
      'group event and RSVP RPC wire contracts carry versions and operation IDs',
      () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = await _client((request) async {
      final fn = request.url.pathSegments.last;
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      calls[fn] = body;
      final payload = switch (fn) {
        'list_group_events' => [],
        'create_group_event' => {
            'event_id': 'event-1',
            'group_id': 'group-1',
            'title': 'Seminar',
            'start_at': '2026-10-01T01:00:00Z',
            'end_at': '2026-10-01T02:00:00Z',
            'created_by': 'user-1',
            'version': 1,
            'cancelled': false,
          },
        'set_group_event_rsvp' => {
            'event_id': 'event-1',
            'user_id': 'user-1',
            'status': 'attending',
            'updated_at': '2026-10-01T00:00:00Z',
          },
        _ => [],
      };
      return http.Response(jsonEncode(payload), 200);
    });
    final repo = SupabaseGroupRepository(client);
    expect(await repo.listGroupEvents('group-1'), isEmpty);
    final event = await repo.createGroupEvent(
        groupId: 'group-1',
        title: 'Seminar',
        startAt: DateTime.utc(2026, 10, 1, 1),
        endAt: DateTime.utc(2026, 10, 1, 2));
    expect(event.version, 1);
    await repo.setGroupEventRsvp('event-1', 'attending');
    expect(calls['create_group_event']!['p_operation_id'], isNotNull);
    expect(calls['create_group_event']!['p_group_id'], 'group-1');
    expect(calls['set_group_event_rsvp']!['p_status'], 'attending');
    await client.dispose();
  });
  test('group availability uses dedicated RPC and preserves non-friend IDs',
      () async {
    Map<String, dynamic>? requestBody;
    final client = await _client((request) async {
      requestBody = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      return http.Response(
          jsonEncode({
            'query_id': 'query-1',
            'generation': 'generation-1',
            'member_ids': ['viewer', 'member-a'],
            'rows': [
              {
                'start_at': '2026-10-01T01:00:00Z',
                'end_at': '2026-10-01T02:00:00Z',
                'visibility_level': 'BUSY_ONLY'
              },
            ],
          }),
          200);
    });
    final repo = SupabaseGroupRepository(client);
    final result = await repo.findGroupAvailability(
        groupId: 'group-1',
        memberIds: const ['viewer', 'member-a'],
        rangeStart: DateTime.utc(2026, 10, 1),
        rangeEnd: DateTime.utc(2026, 10, 1, 9),
        minimumDurationMinutes: 60);
    expect(result.rows.single.memberId, 'group');
    expect(requestBody!['p_member_ids'], ['viewer', 'member-a']);
    expect(requestBody!['p_minimum_duration_minutes'], 60);
    await client.dispose();
  });

  test('group visibility reads and saves through member-scoped RPCs', () async {
    final calls = <String>[];
    Map<String, dynamic>? setBody;
    var visibility = 'FULL';
    final client = await _client((request) async {
      final fn = request.url.pathSegments.last;
      calls.add(fn);
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      if (fn == 'set_group_default_visibility') {
        setBody = body;
        visibility = body['p_default_visibility'] as String;
        return http.Response(
            jsonEncode([
              {'group_id': 'group-1', 'default_visibility': visibility}
            ]),
            200);
      }
      if (fn == 'get_group_default_visibility') {
        return http.Response(jsonEncode(visibility), 200);
      }
      if (fn == 'get_group') {
        return http.Response(
            jsonEncode([
              {
                'group_id': 'group-1',
                'name': 'Seminar',
                'owner_user_id': 'user-1',
                'type': 'seminar',
                'event_create_policy': 'member',
                'role': 'owner',
              }
            ]),
            200);
      }
      throw StateError('Unexpected RPC in focused visibility wire test.');
    });
    final repo = SupabaseGroupRepository(client);

    expect((await repo.getGroup('group-1')).defaultVisibility, 'FULL');
    final updated = await repo.setGroupDefaultVisibility(
        groupId: 'group-1', visibility: 'BUSY_ONLY');
    expect(updated, 'BUSY_ONLY');
    expect(setBody!['p_group_id'], 'group-1');
    expect(setBody!['p_default_visibility'], 'BUSY_ONLY');
    expect(setBody!['p_operation_id'], isNotNull);
    expect(calls, [
      'get_group',
      'get_group_default_visibility',
      'set_group_default_visibility',
    ]);
    await client.dispose();
  });

  test('event UGC RPC wire contracts carry actor-scoped operation IDs',
      () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = await _client((request) async {
      final fn = request.url.pathSegments.last;
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      calls[fn] = body;
      final payload = switch (fn) {
        'list_group_event_comments' => [
            {
              'comment_id': 'comment-1',
              'event_id': 'event-1',
              'author_user_id': 'user-1',
              'body': 'hello',
              'created_at': '2026-10-01T00:00:00Z',
              'updated_at': '2026-10-01T00:00:00Z',
              'version': 1,
            }
          ],
        'create_group_event_comment' => {
            'comment_id': 'comment-1',
            'event_id': 'event-1',
            'author_user_id': 'user-1',
            'body': 'hello',
            'created_at': '2026-10-01T00:00:00Z',
            'updated_at': '2026-10-01T00:00:00Z',
            'version': 1,
          },
        'list_group_event_reactions' => [
            {'reaction': 'ok', 'reaction_count': 1, 'reacted_by_me': true}
          ],
        'get_group_event_ugc' => {
            'event_id': 'event-1',
            'group_id': 'group-1',
            'generation': 'generation-1',
            'rsvps': [
              {
                'user_id': 'user-1',
                'status': 'unanswered',
                'updated_at': null,
              }
            ],
            'comments': [
              {
                'comment_id': 'comment-1',
                'event_id': 'event-1',
                'author_user_id': 'user-1',
                'body': 'hello',
                'created_at': '2026-10-01T00:00:00Z',
                'updated_at': '2026-10-01T00:00:00Z',
                'version': 1,
              }
            ],
            'reactions': [
              {'reaction': 'ok', 'reaction_count': 1, 'reacted_by_me': true}
            ],
          },
        'validate_group_event_ugc' => {
            'valid': true,
            'generation': 'generation-1',
          },
        _ => {'event_id': 'event-1', 'reaction': 'ok', 'reacted': true},
      };
      return http.Response(jsonEncode(payload), 200);
    });
    final repo = SupabaseGroupRepository(client);
    final content = await repo.getGroupEventContent('event-1');
    expect(content.groupId, 'group-1');
    expect(content.generation, 'generation-1');
    expect(content.comments.single.body, 'hello');
    expect(
        await repo.validateGroupEventContent(
            eventId: 'event-1', generation: 'generation-1'),
        isTrue);
    expect(calls['validate_group_event_ugc']!['p_event_id'], 'event-1');
    expect(calls['validate_group_event_ugc']!['p_generation'], 'generation-1');
    expect((await repo.listGroupEventComments('event-1')).single.body, 'hello');
    await repo.createGroupEventComment(eventId: 'event-1', body: 'hello');
    expect((await repo.listGroupEventReactions('event-1')).single.reactedByMe,
        isTrue);
    await repo.setGroupEventReaction(eventId: 'event-1', reaction: 'ok');
    await repo.reportGroupContent(
        targetType: 'comment', targetId: 'comment-1', reason: 'review');
    expect(calls['create_group_event_comment']!['p_operation_id'], isNotNull);
    expect(calls['set_group_event_reaction']!['p_reaction'], 'ok');
    expect(calls['create_group_content_report']!['p_target_type'], 'comment');
    expect(calls['create_group_content_report']!['p_operation_id'], isNotNull);
    await client.dispose();
  });
}

Future<SupabaseClient> _client(
    Future<http.Response> Function(http.Request) handler) async {
  final client = SupabaseClient('https://test.supabase.co', 'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
    final response = await handler(request);
    return http.Response(response.body, response.statusCode,
        headers: {'content-type': 'application/json'}, request: request);
  }));
  final session = Session(
    accessToken: 'access',
    tokenType: 'bearer',
    user: User(
        id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: DateTime.utc(2026, 8).toIso8601String()),
  );
  await client.auth.recoverSession(jsonEncode(session.toJson()));
  return client;
}
