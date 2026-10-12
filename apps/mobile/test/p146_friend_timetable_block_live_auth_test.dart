import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/shared_friend_cache_database.dart';
import 'package:university_schedule_mobile/features/friends/presentation/friend_timetable_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

const _baseUrl = 'http://127.0.0.1:59223';
const _allowedRpc = {
  'list_friendships',
  'list_blocked_users',
  'list_friend_invites',
  'get_my_friend_username',
  'list_friend_visibility_rules',
  'list_friend_terms',
  'get_friend_schedule',
};

class _P146Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  String? friendshipsBody;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59223) {
      throw StateError('P146 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P146 blocked an unexpected local API route.');
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final streamed = await _client.send(request);
    final path = request.url.path;
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(path)?.group(1);
    final bytes = await streamed.stream.toBytes();
    calls.add('${rpc ?? path}:${streamed.statusCode}');
    if (rpc == 'list_friendships' && streamed.statusCode == 200) {
      friendshipsBody = utf8.decode(bytes);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      streamed.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  @override
  void close() {
    _client.close();
    super.close();
  }
}

class _P146HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P146Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P146Storage extends LocalStorage {
  const _P146Storage();
  @override
  Future<String?> accessToken() async => null;
  @override
  Future<bool> hasAccessToken() async => false;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
  @override
  Future<void> removePersistedSession() async {}
}

class _P146NativeScope implements NativeScopeBridge {
  const _P146NativeScope(this.scope);
  final NativeScopeState scope;
  @override
  bool get isSupported => true;
  @override
  Future<NativeScopeState> current() async => scope;
  @override
  Future<NativeScopeState> activate(
          StorageRegion region, String ownerUserId) async =>
      scope;
  @override
  Future<NativeScopeState> deactivate() async =>
      const NativeScopeState.inactive();
  @override
  Future<NativeScopeState> prepare(StorageRegion region) async => scope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'P146 blocker cannot load or render blocked friend timetable',
      (tester) => _verifyBlockedFriendRoute(tester,
          viewerKey: 'owner', targetKey: 'friend'));
  testWidgets(
      'P146 blocked user cannot load or render blocker timetable',
      (tester) => _verifyBlockedFriendRoute(tester,
          viewerKey: 'friend', targetKey: 'owner'));
}

Future<void> _verifyBlockedFriendRoute(
  WidgetTester tester, {
  required String viewerKey,
  required String targetKey,
}) async {
  await HttpOverrides.runWithHttpOverrides(() async {
    final fixturePath = Platform.environment['P146_FLUTTER_FIXTURE_PATH'];
    expect(fixturePath, isNotNull);
    final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
        as Map<String, dynamic>;
    final users = fixture['users'] as Map<String, dynamic>;
    final viewer = users[viewerKey] as Map<String, dynamic>;
    final target = users[targetKey] as Map<String, dynamic>;
    final anonKey = fixture['anon_key'] as String;
    final transport = _P146Transport();
    final client = SupabaseClient(
      _baseUrl,
      anonKey,
      httpClient: transport,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      realtimeClientOptions: const RealtimeClientOptions(
        transport: _denyRealtime,
      ),
    );
    ProviderContainer? container;
    SharedFriendCacheDatabase? cache;
    try {
      final signedIn = await tester.runAsync(() => client.auth
          .signInWithPassword(
              email: viewer['email'] as String,
              password: viewer['password'] as String));
      expect(signedIn?.user?.id, viewer['id']);

      final config = AppConfig.validated(
        environment: 'local',
        demoMode: false,
        supabaseUrl: _baseUrl,
        legacySupabaseAnonKey: anonKey,
      );
      final region = StorageRegion.fromConfig(config);
      final nativeScope = NativeScopeState(
        regionId: region.id,
        ownerHash:
            sha256.convert(utf8.encode(viewer['id'] as String)).toString(),
        activationToken: 'p146-synthetic-scope',
        generation: 1,
        active: true,
      );
      cache = SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
      final authRepository = SupabaseAuthRepository(
        client: client,
        config: config,
        sessionStorage: const _P146Storage(),
      );
      final providerContainer = ProviderContainer(overrides: [
        supabaseClientProvider.overrideWithValue(client),
        appConfigProvider.overrideWithValue(config),
        storageRegionProvider.overrideWithValue(region),
        authRepositoryProvider.overrideWithValue(authRepository),
        activeScheduleContextProvider.overrideWithValue(ActiveScheduleContext(
          ownerUserId: viewer['id'] as String,
          universityId: (fixture['context'] as Map)['university_id'] as String,
          termId: (fixture['context'] as Map)['term_id'] as String,
          academicYear: (fixture['context'] as Map)['academic_year'] as int,
          primaryCalendarId:
              (fixture['context'] as Map)['calendar_id'] as String,
        )),
        nativeScopeBridgeProvider
            .overrideWith((ref) => _P146NativeScope(nativeScope)),
        sharedFriendCacheDatabaseProvider.overrideWithValue(cache),
      ]);
      container = providerContainer;
      final authSubscription = providerContainer.listen(
        currentAuthSessionProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(authSubscription.close);
      await _waitForViewer(tester, providerContainer, viewer['id'] as String);
      await tester.runAsync(() => providerContainer
          .read(friendsControllerProvider.future)
          .timeout(const Duration(seconds: 20)));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: providerContainer,
        child: MaterialApp(
          home: FriendTimetableScreen(friendUserId: target['id'] as String),
        ),
      ));
      final ready =
          await _waitForFriendLoad(tester, providerContainer, transport);

      expect(ready, isTrue);
      expect(transport.calls, contains('list_friendships:200'));
      expect(transport.calls, contains('list_blocked_users:200'));
      expect(
          transport.calls.where((x) => x == 'list_friend_terms:200'), isEmpty);
      expect(transport.calls.where((x) => x == 'get_friend_schedule:200'),
          isEmpty);
      expect(find.text('友だちの時間割'), findsOneWidget);
      expect(transport.friendshipsBody, isNotNull);
      expect(
          transport.friendshipsBody, isNot(contains(target['display_name'])));
      expect(transport.friendshipsBody, contains('ブロック中の利用者'));
      expect(find.text(target['display_name'] as String), findsNothing);
      expect(find.text('共有されている予定はありません'), findsOneWidget);
      expect(
          container
              .read(friendsControllerProvider)
              .valueOrNull
              ?.relationships
              .any((r) => r.otherUserId == target['id']),
          isFalse);
      expect(tester.takeException(), isNull);
      debugPrint(
        'P146: production GoTrue Auth stream; blocked friendship name redacted in HTTP; route omitted by production controller; no friend terms/schedule RPC; no peer name or schedule rendered ($viewerKey)',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container?.dispose();
      if (cache != null) {
        await cache.close().timeout(const Duration(seconds: 10));
      }
      await tester.runAsync(() async {
        try {
          await client.dispose().timeout(const Duration(seconds: 8));
        } on TimeoutException {
          // The HTTP transport is force-closed below.
        }
      });
      transport.close();
    }
  }, _P146HttpOverrides());
}

Future<void> _waitForViewer(
  WidgetTester tester,
  ProviderContainer container,
  String expected,
) async {
  final ready = await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (container.read(currentAuthSessionProvider)?.userId == expected) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  });
  expect(ready, isTrue, reason: 'production GoTrue Auth stream did not settle');
}

Future<bool> _waitForFriendLoad(
  WidgetTester tester,
  ProviderContainer container,
  _P146Transport transport,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(friendsControllerProvider).valueOrNull;
    if (transport.calls.contains('list_friendships:200') &&
        transport.calls.contains('list_blocked_users:200') &&
        state?.blockStatusLoaded == true &&
        state?.blockStatusViewerUserId != null &&
        find.text('共有されている予定はありません').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P146 denied unexpected Realtime traffic.');
