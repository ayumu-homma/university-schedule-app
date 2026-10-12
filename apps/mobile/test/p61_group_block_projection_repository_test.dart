import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';

void main() {
  test('empty array is a valid known no-block result with group-only input',
      () async {
    late http.Request captured;
    final client = SupabaseClient(
      'https://test.supabase.co',
      'synthetic-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }),
    );
    addTearDown(client.dispose);

    final result = await SupabaseGroupRepository(client)
        .listBlockedGroupMembers('b7410000-0000-4000-8000-000000000001');

    expect(result, isEmpty);
    expect(captured.url.path, '/rest/v1/rpc/list_group_member_blocked_users');
    expect(jsonDecode(captured.body), {
      'p_group_id': 'b7410000-0000-4000-8000-000000000001',
    });
  });

  test('malformed projection responses fail instead of becoming an empty set',
      () async {
    final invalidBodies = <String>[
      'null',
      '"not-a-row-set"',
      '[null]',
      '[{}]',
      '[{"user_id":"not-a-uuid"}]',
      '[{"user_id":"a7410000-0000-4000-8000-000000000001"}, null]',
    ];
    for (final body in invalidBodies) {
      final client = SupabaseClient(
        'https://test.supabase.co',
        'synthetic-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(body, 200,
            headers: {'content-type': 'application/json'}, request: request)),
      );
      addTearDown(client.dispose);

      await expectLater(
        SupabaseGroupRepository(client)
            .listBlockedGroupMembers('b7410000-0000-4000-8000-000000000001'),
        throwsA(isA<Exception>()),
        reason: 'invalid fake RPC response must remain unknown',
      );
    }
  });
}
