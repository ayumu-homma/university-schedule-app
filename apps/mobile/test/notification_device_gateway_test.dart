import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/features/notification/data/supabase_notification_device_gateway.dart';

void main() {
  test('uses the authenticated notification generation RPC contract', () async {
    final calls = <String, Map<String, dynamic>>{};
    final client = SupabaseClient(
      'http://127.0.0.1:55321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final name = request.url.pathSegments.last;
        final decoded = jsonDecode(request.body);
        calls[name] = Map<String, dynamic>.from(decoded as Map);
        final response = switch (name) {
          'register_notification_device' => [
              {'binding_generation': 4, 'accepted': true},
            ],
          'revoke_notification_device' => true,
          _ => throw StateError('unexpected RPC: $name'),
        };
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);
    final userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final session = Session(
      accessToken: 'notification-test-access-token',
      tokenType: 'bearer',
      user: User(
        id: userId,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: DateTime.utc(2026, 9, 24).toIso8601String(),
      ),
    );
    await client.auth.recoverSession(jsonEncode(session.toJson()));
    final gateway = SupabaseNotificationDeviceGateway(client);

    final bindingGeneration = await gateway.register(
      expectedUserId: userId,
      installationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      clientGeneration: 7,
      platform: 'android',
      token: 'test-fcm-registration-token-1234567890',
    );
    expect(bindingGeneration, 4);
    expect(calls['register_notification_device'], {
      'p_installation_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'p_client_generation': 7,
      'p_platform': 'android',
      'p_token': 'test-fcm-registration-token-1234567890',
      'p_app_version': null,
      'p_device_id': null,
    });

    final revoked = await gateway.revoke(
      expectedUserId: userId,
      installationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      clientGeneration: 7,
      bindingGeneration: 4,
    );
    expect(revoked, isTrue);
    expect(calls['revoke_notification_device'], {
      'p_installation_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'p_client_generation': 7,
      'p_binding_generation': 4,
    });
  });

  test('does not call the registration RPC for a replaced account', () async {
    final client = SupabaseClient(
      'http://127.0.0.1:55321',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient:
          MockClient((request) async => throw StateError('must not call')),
    );
    addTearDown(client.dispose);
    final userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final session = Session(
      accessToken: 'notification-test-access-token',
      tokenType: 'bearer',
      user: User(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: DateTime.utc(2026, 9, 24).toIso8601String(),
      ),
    );
    await client.auth.recoverSession(jsonEncode(session.toJson()));

    final result = await SupabaseNotificationDeviceGateway(client).register(
      expectedUserId: userId,
      installationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      clientGeneration: 1,
      platform: 'ios',
      token: 'test-fcm-registration-token-1234567890',
    );
    expect(result, isNull);
  });
}
