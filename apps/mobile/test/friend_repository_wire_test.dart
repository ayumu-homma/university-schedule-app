import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/friends/data/supabase_friend_repository.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';

void main() {
  test('username discovery uses only RPC and binds confirmation identity',
      () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = await _client((request) async {
      final function = request.url.pathSegments.last;
      final decodedBody =
          request.body.isEmpty ? null : jsonDecode(request.body);
      final body = decodedBody is Map
          ? Map<String, dynamic>.from(decodedBody)
          : <String, dynamic>{};
      calls[function] = body;
      final payload = switch (function) {
        'get_my_friend_username' => {
            'username': 'my_user',
            'searchable_by_username': false,
          },
        'set_my_friend_username' => {
            'username': 'my_user',
            'searchable_by_username': true,
          },
        'find_friend_by_username' => [
            {
              'user_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'username': 'friend_user',
              'display_name': 'Friend',
            },
            {
              'user_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              'username': 'friend_user',
              'display_name': 'Unexpected second result',
            },
          ],
        'request_friend_by_username' => {
            'friendship_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'status': 'pending',
            'requester_user_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'addressee_user_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            'incarnation': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            'revision': 1,
          },
        _ => {},
      };
      return http.Response(jsonEncode(payload), 200,
          headers: {'content-type': 'application/json'});
    });
    final repository = SupabaseFriendRepository(client);

    expect((await repository.getMyFriendUsername())?.username, 'my_user');
    expect(
      (await repository.setMyFriendUsername(
        username: 'my_user',
        searchable: true,
      ))
          .searchable,
      isTrue,
    );
    final matches = await repository.findFriendByUsername('FRIEND_USER');
    expect(matches, hasLength(1));
    expect(matches.single.userId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    final relationship = await repository.requestFriendByUsername(
      target: matches.single,
      shownUsername: 'friend_user',
      operationId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
    );
    expect(relationship.isRequester, isTrue);
    expect(calls['request_friend_by_username'], {
      'p_target_user_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'p_shown_username': 'friend_user',
      'p_operation_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
    });
    expect(
      calls.keys,
      containsAll([
        'get_my_friend_username',
        'set_my_friend_username',
        'find_friend_by_username',
        'request_friend_by_username',
      ]),
    );
    await client.dispose();
  });

  test(
      'terminal relationships are not displayed as actionable pending requests',
      () async {
    final client = await _client((request) async => http.Response(
        jsonEncode([
          for (final status in [
            'pending',
            'accepted',
            'rejected',
            'blocked',
            'cancelled',
            'unknown'
          ])
            {
              'friendship_id': status,
              'other_user_id': 'friend',
              'status': status
            },
        ]),
        200,
        headers: {'content-type': 'application/json'}));
    final rows = await SupabaseFriendRepository(client).listRelationships();
    expect(rows.map((r) => r.status),
        [FriendshipStatus.pending, FriendshipStatus.accepted]);
    await client.dispose();
  });

  test('Phase 8 RPC wire shapes and retry receipts stay stable', () async {
    final calls = <String, List<Map<String, dynamic>>>{};
    final attempts = <String, int>{};
    final client = await _client((request) async {
      final function = request.url.pathSegments.last;
      final decoded = request.body.isEmpty ? null : jsonDecode(request.body);
      final body = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      calls.putIfAbsent(function, () => []).add(body);
      final attempt =
          attempts.update(function, (value) => value + 1, ifAbsent: () => 1);
      if (attempt == 1 &&
          const {
            'create_friend_invite',
            'request_friend_from_invite',
            'accept_friend_request',
            'set_friend_visibility',
          }.contains(function)) {
        throw const SocketException('connection reset');
      }
      final payload = switch (function) {
        'create_friend_invite' => {
            'invite_id': '11111111-1111-4111-8111-111111111111',
            'token': List.filled(64, 'a').join(),
            'expires_at': '2026-10-01T00:00:00Z',
          },
        'request_friend_from_invite' => {
            'friendship_id': '22222222-2222-4222-8222-222222222222',
            'status': 'pending',
            'issuer_user_id': '33333333-3333-4333-8333-333333333333',
            'incarnation': '44444444-4444-4444-8444-444444444444',
            'revision': 1,
          },
        'accept_friend_request' => {
            'friendship_id': '22222222-2222-4222-8222-222222222222',
            'status': 'accepted',
            'incarnation': '44444444-4444-4444-8444-444444444444',
            'revision': 2,
          },
        'set_friend_visibility' => {
            'friendship_id': '22222222-2222-4222-8222-222222222222',
            'revision': 3,
          },
        'list_friend_invites' => [
            {
              'invite_id': '11111111-1111-4111-8111-111111111111',
              'expires_at': '2026-10-01T00:00:00Z',
              'claimed': true,
              'revoked': false,
              'accepted': false,
            },
          ],
        'preview_friend_invite' => {'state': 'invalid'},
        'get_friend_schedule' => {
            'allowed': true,
            'revision': 9,
            'rows': {
              'items': [
                {
                  'item_id': 'opaque-occurrence-1',
                  'start_at': '2026-10-05T01:00:00Z',
                  'end_at': '2026-10-05T02:00:00Z',
                  'title': '数学',
                  'kind': 'course',
                  'location': 'A101',
                  'description': null,
                  'visibility_level': 'FULL',
                  'instructor_name': '先生',
                },
              ],
            },
          },
        _ => {},
      };
      return http.Response(jsonEncode(payload), 200, headers: {
        'content-type': 'application/json',
      });
    });
    final repository = SupabaseFriendRepository(client);
    final relationship = const FriendRelationship(
      id: '22222222-2222-4222-8222-222222222222',
      otherUserId: '33333333-3333-4333-8333-333333333333',
      otherDisplayName: '相手',
      status: FriendshipStatus.pending,
      isRequester: false,
      incarnation: '44444444-4444-4444-8444-444444444444',
      revision: 1,
    );

    final expires = DateTime.utc(2026, 10);
    await expectLater(
      repository.createInvitation(expiresAt: expires),
      throwsA(isA<SocketException>()),
    );
    final invite = await repository.createInvitation(expiresAt: expires);
    expect(invite.id, '11111111-1111-4111-8111-111111111111');
    expect(calls['create_friend_invite']![0]['p_operation_id'],
        calls['create_friend_invite']![1]['p_operation_id']);
    expect(calls['create_friend_invite']![0]['p_secret'],
        calls['create_friend_invite']![1]['p_secret']);
    expect(calls['create_friend_invite']![0]['p_expires_at'],
        calls['create_friend_invite']![1]['p_expires_at']);

    final preview =
        await repository.previewInvitation(List.filled(64, 'b').join());
    expect(preview.status, 'invalid');
    expect(preview.issuerUserId, isNull);
    expect((await repository.listInvitations()).single.claimed, isTrue);

    await expectLater(
      repository.requestInvitation(List.filled(64, 'c').join()),
      throwsA(isA<SocketException>()),
    );
    final requested =
        await repository.requestInvitation(List.filled(64, 'c').join());
    expect(requested.isRequester, isTrue);
    expect(calls['request_friend_from_invite']![0]['p_operation_id'],
        calls['request_friend_from_invite']![1]['p_operation_id']);

    final acceptedRelationship =
        relationship.copyWith(status: FriendshipStatus.pending);
    await expectLater(
      repository.respondToRequest(
          relationship: acceptedRelationship, accept: true),
      throwsA(isA<SocketException>()),
    );
    expect(
        (await repository.respondToRequest(
          relationship: acceptedRelationship,
          accept: true,
        ))
            .isAccepted,
        isTrue);
    expect(calls['accept_friend_request']![0]['p_operation_id'],
        calls['accept_friend_request']![1]['p_operation_id']);

    await expectLater(
      repository.setVisibility(
        relationship: relationship,
        friendUserId: relationship.otherUserId,
        level: 'FULL',
        targetKind: 'default',
      ),
      throwsA(isA<SocketException>()),
    );
    await repository.setVisibility(
      relationship: relationship,
      friendUserId: relationship.otherUserId,
      level: 'FULL',
      targetKind: 'default',
    );
    expect(calls['set_friend_visibility']![0]['p_operation_id'],
        calls['set_friend_visibility']![1]['p_operation_id']);

    final schedule = await repository.fetchSchedule(
      friendUserId: relationship.otherUserId,
      termId: '55555555-5555-4555-8555-555555555555',
      rangeStart: DateTime.utc(2026, 10),
      rangeEnd: DateTime.utc(2026, 11),
    );
    expect(schedule.rows.single.instructorName, '先生');
    await client.dispose();
  });

  test('malformed typed schedule envelope fails closed', () async {
    final client = await _client((request) async {
      return http.Response(
        jsonEncode({
          'allowed': true,
          'revision': 1,
          'rows': {'courses': []}
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repository = SupabaseFriendRepository(client);
    await expectLater(
      repository.fetchSchedule(
        friendUserId: '33333333-3333-4333-8333-333333333333',
        termId: '55555555-5555-4555-8555-555555555555',
        rangeStart: DateTime.utc(2026, 10),
        rangeEnd: DateTime.utc(2026, 11),
      ),
      throwsA(isA<Exception>()),
    );
    await client.dispose();
  });

  test('self invite rejection is translated without broad 22023 mapping',
      () async {
    final selfInviteClient = await _client((request) async {
      return http.Response(
        jsonEncode({
          'code': '22023',
          'message': 'cannot invite yourself',
          'details': null,
          'hint': null,
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });
    final selfInviteRepository = SupabaseFriendRepository(selfInviteClient);
    await expectLater(
      selfInviteRepository.requestInvitation(List.filled(64, 'a').join()),
      throwsA(
        isA<ValidationError>().having(
          (error) => error.message,
          'message',
          '自分自身には友だち申請を送れません。',
        ),
      ),
    );
    await selfInviteClient.dispose();

    final otherValidationClient = await _client((request) async {
      return http.Response(
        jsonEncode({
          'code': '22023',
          'message': 'valid token and operation id are required',
          'details': null,
          'hint': null,
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });
    final otherValidationRepository =
        SupabaseFriendRepository(otherValidationClient);
    await expectLater(
      otherValidationRepository.requestInvitation(List.filled(64, 'b').join()),
      throwsA(
        isA<PostgrestException>().having(
          (error) => error.code,
          'code',
          '22023',
        ),
      ),
    );
    await otherValidationClient.dispose();
  });
}

Future<SupabaseClient> _client(
  Future<http.Response> Function(http.Request) handler,
) async {
  final client = SupabaseClient(
    'https://test.supabase.co',
    'test-publishable-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      final response = await handler(request);
      return http.Response(
        response.body,
        response.statusCode,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
        request: request,
      );
    }),
  );
  final session = Session(
    accessToken: 'test-access-token',
    tokenType: 'bearer',
    user: User(
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.utc(2026, 8, 10).toIso8601String(),
    ),
  );
  await client.auth.recoverSession(jsonEncode(session.toJson()));
  return client;
}
