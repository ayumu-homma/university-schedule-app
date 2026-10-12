import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/auth/secure_auth_storage.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';

void main() {
  test('remote sign-out failure still clears verified local session', () async {
    var logoutRequests = 0;
    var cleanupPrepared = false;
    final client = await _authenticatedClient((request) async {
      expect(cleanupPrepared, isTrue);
      logoutRequests += 1;
      expect(request.url.path, '/auth/v1/logout');
      expect(request.url.queryParameters['scope'], 'local');
      return http.Response('{"message":"temporarily unavailable"}', 503);
    });
    addTearDown(client.dispose);
    final secure = _RepositorySecureStore()
      ..values['secure-session'] = 'persisted-refresh-session';
    final legacy = _RepositoryLegacyStorage();
    final storage = SecureAuthLocalStorage(
      secureStore: secure,
      secureKey: 'secure-session',
      legacyStorage: legacy,
    );
    await storage.initialize();
    final repository = SupabaseAuthRepository(
      client: client,
      config: _config,
      sessionStorage: storage,
      beforeSignOut: () async {
        cleanupPrepared = true;
      },
    );

    await expectLater(
      repository.signOut(),
      throwsA(
        isA<AuthError>().having(
          (error) => error.message,
          'message',
          '端末ではログアウトしましたが、サーバー側のセッション無効化は確認できませんでした。',
        ),
      ),
    );

    expect(logoutRequests, 1);
    expect(cleanupPrepared, isTrue);
    expect(client.auth.currentSession, isNull);
    expect(secure.values, isEmpty);
    final nextLaunch = SecureAuthLocalStorage(
      secureStore: secure,
      secureKey: 'secure-session',
      legacyStorage: legacy,
    );
    await nextLaunch.initialize();
    expect(await nextLaunch.hasAccessToken(), isFalse);
    expect(await nextLaunch.accessToken(), isNull);
  });

  test('account-replacement cleanup runs before OTP and resumes on failure',
      () async {
    var sequence = 0;
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'test-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/auth/v1/otp');
        expect(sequence, 1);
        return http.Response('{"message":"temporarily unavailable"}', 503,
            request: request);
      }),
    );
    addTearDown(client.dispose);
    final secure = _RepositorySecureStore();
    final storage = SecureAuthLocalStorage(
      secureStore: secure,
      secureKey: 'secure-session',
      legacyStorage: _RepositoryLegacyStorage(),
    );
    await storage.initialize();
    final repository = SupabaseAuthRepository(
      client: client,
      config: _config,
      sessionStorage: storage,
      beforeAccountChange: () async {
        sequence = 1;
      },
      resumeAfterAuthFlowFailure: () async {
        sequence = 2;
      },
    );

    await expectLater(repository.sendMagicLink('student@example.edu'),
        throwsA(isA<AuthError>()));
    expect(sequence, 2);
  });

  test('verified local deletion failure is surfaced by sign-out', () async {
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'test-publishable-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final secure = _RepositorySecureStore(failDeletes: true)
      ..values['secure-session'] = 'persisted-refresh-session';
    final storage = SecureAuthLocalStorage(
      secureStore: secure,
      secureKey: 'secure-session',
      legacyStorage: _RepositoryLegacyStorage(),
    );
    await storage.initialize();
    final repository = SupabaseAuthRepository(
      client: client,
      config: _config,
      sessionStorage: storage,
    );

    await expectLater(
      repository.signOut(),
      throwsA(
        isA<AuthError>().having(
          (error) => error.message,
          'message',
          '端末の認証情報を安全に削除できませんでした。もう一度お試しください',
        ),
      ),
    );
    expect(secure.values['secure-session'], 'persisted-refresh-session');
  });
}

final _config = AppConfig.validated(
  environment: 'local',
  demoMode: false,
  supabaseUrl: 'http://127.0.0.1:54321',
  supabasePublishableKey: 'test-publishable-key',
);

Future<SupabaseClient> _authenticatedClient(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final client = SupabaseClient(
    'http://127.0.0.1:54321',
    'test-publishable-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(handler),
  );
  final session = Session(
    accessToken: 'test-access-token',
    tokenType: 'bearer',
    user: User(
      id: '11111111-1111-4111-8111-111111111111',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.utc(2026, 8, 22).toIso8601String(),
    ),
  );
  await client.auth.recoverSession(jsonEncode(session.toJson()));
  return client;
}

class _RepositorySecureStore implements SecureValueStore {
  _RepositorySecureStore({this.failDeletes = false});

  final bool failDeletes;
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    if (!failDeletes) values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _RepositoryLegacyStorage extends LocalStorage {
  String? value;

  @override
  Future<String?> accessToken() async => value;

  @override
  Future<bool> hasAccessToken() async => value != null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> persistSession(String persistSessionString) async {
    value = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    value = null;
  }
}
