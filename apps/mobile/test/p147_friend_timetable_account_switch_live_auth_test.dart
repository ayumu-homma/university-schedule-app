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

const _baseUrl = 'http://127.0.0.1:59224';
const _allowedRpc = {
  'list_friendships',
  'list_blocked_users',
  'list_friend_invites',
  'get_my_friend_username',
  'list_friend_visibility_rules',
  'list_friend_terms',
  'get_friend_schedule',
};
const _allowedAuthPaths = {
  '/auth/v1/token',
  '/auth/v1/user',
  '/auth/v1/logout',
};

class _P147Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  String? friendshipsBody;
  String? scheduleBody;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59224) {
      throw StateError('P147 blocked a request outside its loopback bridge.');
    }
    final authPath = _allowedAuthPaths.contains(uri.path);
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P147 blocked an unexpected local API route.');
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
    if (rpc == 'get_friend_schedule' && streamed.statusCode == 200) {
      scheduleBody = utf8.decode(bytes);
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

class _P147HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P147Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P147Storage extends LocalStorage {
  const _P147Storage();
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

class _P147NativeScope implements NativeScopeBridge {
  const _P147NativeScope(this.scope);
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
    'P147 removes a prior viewer schedule after a production Auth account switch',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P147_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
            as Map<String, dynamic>;
        final users = fixture['users'] as Map<String, dynamic>;
        final viewer = users['viewer'] as Map<String, dynamic>;
        final friend = users['friend'] as Map<String, dynamic>;
        final stranger = users['stranger'] as Map<String, dynamic>;
        final eventTitle = fixture['event_title'] as String;
        final anonKey = fixture['anon_key'] as String;
        final transport = _P147Transport();
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
          final firstLogin = await tester.runAsync(() => client.auth
              .signInWithPassword(
                  email: viewer['email'] as String,
                  password: viewer['password'] as String));
          expect(firstLogin?.user?.id, viewer['id']);

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
            activationToken: 'p147-synthetic-scope',
            generation: 1,
            active: true,
          );
          cache =
              SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
          final authRepository = SupabaseAuthRepository(
            client: client,
            config: config,
            sessionStorage: const _P147Storage(),
          );
          final providerContainer = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(client),
            appConfigProvider.overrideWithValue(config),
            storageRegionProvider.overrideWithValue(region),
            authRepositoryProvider.overrideWithValue(authRepository),
            activeScheduleContextProvider
                .overrideWithValue(ActiveScheduleContext(
              ownerUserId: viewer['id'] as String,
              universityId: fixture['university_id'] as String,
              termId: fixture['viewer_term_id'] as String,
              academicYear: 2026,
              primaryCalendarId: fixture['viewer_calendar_id'] as String,
            )),
            nativeScopeBridgeProvider
                .overrideWith((ref) => _P147NativeScope(nativeScope)),
            sharedFriendCacheDatabaseProvider.overrideWithValue(cache),
          ]);
          container = providerContainer;
          final authSubscription = providerContainer.listen(
            currentAuthSessionProvider,
            (_, __) {},
            fireImmediately: true,
          );
          addTearDown(authSubscription.close);
          await _waitForViewer(
              tester, providerContainer, viewer['id'] as String);
          await tester.runAsync(() => providerContainer
              .read(friendsControllerProvider.future)
              .timeout(const Duration(seconds: 20)));
          await tester.pumpWidget(UncontrolledProviderScope(
            container: providerContainer,
            child: MaterialApp(
              home: FriendTimetableScreen(friendUserId: friend['id'] as String),
            ),
          ));

          final visible = await _waitForSchedule(
            tester,
            providerContainer,
            transport,
            eventTitle,
          );
          final initialState =
              providerContainer.read(friendsControllerProvider).valueOrNull;
          expect(
            visible,
            isTrue,
            reason:
                'schedule_http_200=${transport.calls.contains('get_friend_schedule:200')}; '
                'body_contains_canary=${transport.scheduleBody?.contains(eventTitle) == true}; '
                'allowed=${initialState?.scheduleAllowed}; loading=${initialState?.isLoading}; '
                'rows=${initialState?.schedule.length}; rendered=${find.text(eventTitle).evaluate().isNotEmpty}',
          );
          expect(transport.scheduleBody, isNotNull);
          expect(transport.scheduleBody, contains(eventTitle));
          expect(find.text(eventTitle), findsOneWidget);
          expect(find.text(friend['display_name'] as String), findsOneWidget);
          final scheduleRequestsBeforeSwitch = transport.calls
              .where((call) => call == 'get_friend_schedule:200')
              .length;
          expect(scheduleRequestsBeforeSwitch, 1);

          await tester.runAsync(() => authRepository.signOut());
          await _waitForViewer(tester, providerContainer, null);
          await tester.pump();
          expect(find.text(eventTitle), findsNothing,
              reason:
                  'previous viewer schedule remained visible after sign-out');

          final switchedLogin = await tester.runAsync(() => client.auth
              .signInWithPassword(
                  email: stranger['email'] as String,
                  password: stranger['password'] as String));
          expect(switchedLogin?.user?.id, stranger['id']);
          await _waitForViewer(
              tester, providerContainer, stranger['id'] as String);
          await tester.pump();

          expect(find.text(eventTitle), findsNothing,
              reason:
                  'previous viewer schedule remained visible after Auth changed');
          expect(find.text(friend['display_name'] as String), findsNothing);
          final strangerReady = await _waitForStrangerRelationships(
            tester,
            providerContainer,
            transport,
            stranger['id'] as String,
          );
          expect(strangerReady, isTrue);
          final state =
              providerContainer.read(friendsControllerProvider).valueOrNull;
          expect(state?.relationships.any((r) => r.otherUserId == friend['id']),
              isFalse);
          expect(state?.schedule, isEmpty);
          expect(state?.scheduleAllowed, isFalse);
          expect(transport.friendshipsBody,
              isNot(contains(friend['display_name'])));
          expect(
            transport.calls.where((call) => call == 'get_friend_schedule:200'),
            hasLength(scheduleRequestsBeforeSwitch),
            reason:
                'unauthorized switched viewer triggered another schedule request',
          );
          expect(tester.takeException(), isNull);
          debugPrint(
            'P147: actual GoTrue switch; initial friend schedule HTTP 200 and rendered; previous name/canary absent after switch; no second schedule RPC',
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
              // The injected loopback transport is force-closed below.
            }
          });
          transport.close();
        }
      }, _P147HttpOverrides());
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

Future<void> _waitForViewer(
  WidgetTester tester,
  ProviderContainer container,
  String? expected,
) async {
  var ready = false;
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    if (container.read(currentAuthSessionProvider)?.userId == expected) {
      ready = true;
      break;
    }
  }
  expect(ready, isTrue, reason: 'production GoTrue Auth stream did not settle');
}

Future<bool> _waitForSchedule(
  WidgetTester tester,
  ProviderContainer container,
  _P147Transport transport,
  String eventTitle,
) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(friendsControllerProvider).valueOrNull;
    if (transport.calls.contains('list_friend_terms:200') &&
        transport.calls.contains('get_friend_schedule:200') &&
        state?.scheduleAllowed == true &&
        !state!.isLoading &&
        state.schedule.any((row) => row.title == eventTitle) &&
        find.text(eventTitle).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Future<bool> _waitForStrangerRelationships(
  WidgetTester tester,
  ProviderContainer container,
  _P147Transport transport,
  String strangerId,
) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(friendsControllerProvider).valueOrNull;
    if (state?.blockStatusLoaded == true &&
        state?.blockStatusViewerUserId == strangerId &&
        transport.calls
                .where((call) => call == 'list_friendships:200')
                .length >=
            2) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P147 denied unexpected Realtime traffic.');
