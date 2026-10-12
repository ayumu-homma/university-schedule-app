import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
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
import 'package:university_schedule_mobile/features/visibility/presentation/visibility_settings_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

const _baseUrl = 'http://127.0.0.1:59231';
const _allowedRpc = {
  'list_friendships',
  'list_blocked_users',
  'list_friend_invites',
  'get_my_friend_username',
  'list_friend_visibility_rules',
  'list_friend_terms',
  'get_friend_schedule',
  'set_friend_visibility',
};
const _allowedAuthPaths = {
  '/auth/v1/token',
  '/auth/v1/user',
  '/auth/v1/logout',
};

class _P163Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  String? friendshipsBody;
  String? scheduleBody;
  String? savedTargetKind;
  String? savedVisibilityLevel;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59231) {
      throw StateError('P163 blocked a request outside its loopback bridge.');
    }
    final authPath = _allowedAuthPaths.contains(uri.path);
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P163 blocked an unexpected local API route.');
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final requestBody = request is http.Request ? request.body : null;
    final streamed = await _client.send(request);
    final path = request.url.path;
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(path)?.group(1);
    final bytes = await streamed.stream.toBytes();
    calls.add('${rpc ?? path}:${streamed.statusCode}');
    if (rpc == 'set_friend_visibility' && requestBody != null) {
      final params = jsonDecode(requestBody) as Map<String, dynamic>;
      savedTargetKind = params['p_target_kind']?.toString();
      savedVisibilityLevel = params['p_visibility_level']?.toString();
    }
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

class _P163HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P163Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P163Storage extends LocalStorage {
  const _P163Storage();
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

class _P163NativeScope implements NativeScopeBridge {
  const _P163NativeScope(this.scope);
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
    'P163 owner saves PRIVATE and recipient receives no private event projection',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P163_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
            as Map<String, dynamic>;
        final users = fixture['users'] as Map<String, dynamic>;
        final owner = users['owner'] as Map<String, dynamic>;
        final friend = users['friend'] as Map<String, dynamic>;
        final title = fixture['event_title'] as String;
        final location = fixture['event_location'] as String;
        final description = fixture['event_description'] as String;
        final anonKey = fixture['anon_key'] as String;
        final config = AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: _baseUrl,
          legacySupabaseAnonKey: anonKey,
        );

        // Owner changes the real production friend-specific default through UI.
        final ownerTransport = _P163Transport();
        final ownerClient = SupabaseClient(
          _baseUrl,
          anonKey,
          httpClient: ownerTransport,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          realtimeClientOptions:
              const RealtimeClientOptions(transport: _denyRealtime),
        );
        ProviderContainer? ownerContainer;
        SharedFriendCacheDatabase? ownerCache;
        GoRouter? ownerRouter;
        try {
          final login =
              await tester.runAsync(() => ownerClient.auth.signInWithPassword(
                    email: owner['email'] as String,
                    password: owner['password'] as String,
                  ));
          expect(login?.user?.id, owner['id']);
          final region = StorageRegion.fromConfig(config);
          final ownerScope = NativeScopeState(
            regionId: region.id,
            ownerHash:
                sha256.convert(utf8.encode(owner['id'] as String)).toString(),
            activationToken: 'p163-owner-scope',
            generation: 1,
            active: true,
          );
          ownerCache =
              SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
          final authRepository = SupabaseAuthRepository(
            client: ownerClient,
            config: config,
            sessionStorage: const _P163Storage(),
          );
          final container = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(ownerClient),
            appConfigProvider.overrideWithValue(config),
            storageRegionProvider.overrideWithValue(region),
            authRepositoryProvider.overrideWithValue(authRepository),
            activeScheduleContextProvider
                .overrideWithValue(ActiveScheduleContext(
              ownerUserId: owner['id'] as String,
              universityId: fixture['university_id'] as String,
              termId: fixture['owner_term_id'] as String,
              academicYear: 2026,
              primaryCalendarId: fixture['owner_calendar_id'] as String,
            )),
            nativeScopeBridgeProvider
                .overrideWith((ref) => _P163NativeScope(ownerScope)),
            sharedFriendCacheDatabaseProvider.overrideWithValue(ownerCache),
          ]);
          ownerContainer = container;
          final authSubscription = container.listen(
              currentAuthSessionProvider, (_, __) {},
              fireImmediately: true);
          addTearDown(authSubscription.close);
          await _waitForViewer(tester, container, owner['id'] as String);
          await tester.runAsync(() => container
              .read(friendsControllerProvider.future)
              .timeout(const Duration(seconds: 20)));
          ownerRouter = GoRouter(
            initialLocation: '/visibility/friend/${friend['id']}',
            routes: [
              GoRoute(
                path: '/visibility/friend/:userId',
                builder: (context, state) => VisibilitySettingsScreen(
                  friendUserId: state.pathParameters['userId'],
                ),
              ),
              GoRoute(
                path: '/shared/friend/:userId',
                builder: (context, state) => FriendTimetableScreen(
                  friendUserId: state.pathParameters['userId']!,
                ),
              ),
            ],
          );
          await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: ownerRouter),
          ));
          expect(find.text(friend['display_name'] as String), findsOneWidget);
          final titleRadio =
              find.widgetWithText(RadioListTile<VisibilityLevel>, '自分のみ');
          await tester.ensureVisible(titleRadio);
          await tester.pumpAndSettle();
          final titleRadioTile =
              tester.widget<RadioListTile<VisibilityLevel>>(titleRadio);
          final selectedBeforeTap =
              RadioGroup.maybeOf<VisibilityLevel>(tester.element(titleRadio))
                  ?.groupValue;
          await tester.tap(titleRadio);
          await tester.pumpAndSettle();
          final selectedAfterTap =
              RadioGroup.maybeOf<VisibilityLevel>(tester.element(titleRadio))
                  ?.groupValue;
          expect(
            selectedAfterTap,
            VisibilityLevel.private,
            reason: 'visibility UI selection did not change; '
                'before=${selectedBeforeTap?.wireName}; '
                'after=${selectedAfterTap?.wireName}; '
                'enabled=${titleRadioTile.enabled}; '
                'edit_label=${find.text('編集中: 自分のみ').evaluate().isNotEmpty}',
          );
          final save = find.widgetWithText(FilledButton, '保存');
          await tester.ensureVisible(save);
          await tester.tap(save);

          final saved = await _waitForSavedVisibility(
            tester,
            ownerTransport,
          );
          expect(saved, isTrue);
          expect(
              ownerTransport.calls
                  .where((c) => c == 'set_friend_visibility:200'),
              hasLength(1));
          expect(ownerTransport.savedTargetKind, 'default');
          expect(ownerTransport.savedVisibilityLevel, 'PRIVATE');
          expect(find.text('公開範囲を保存しました'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          ownerRouter?.dispose();
          ownerContainer?.dispose();
          if (ownerCache != null) {
            await ownerCache.close().timeout(const Duration(seconds: 10));
          }
          await tester.runAsync(() async {
            try {
              await ownerClient.dispose().timeout(const Duration(seconds: 8));
            } on TimeoutException {
              /* The strict loopback transport is closed below. */
            }
          });
          ownerTransport.close();
        }

        // A separate real GoTrue recipient session reads the saved server rule.
        final friendTransport = _P163Transport();
        final friendClient = SupabaseClient(
          _baseUrl,
          anonKey,
          httpClient: friendTransport,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          realtimeClientOptions:
              const RealtimeClientOptions(transport: _denyRealtime),
        );
        ProviderContainer? friendContainer;
        SharedFriendCacheDatabase? friendCache;
        GoRouter? friendRouter;
        try {
          final login =
              await tester.runAsync(() => friendClient.auth.signInWithPassword(
                    email: friend['email'] as String,
                    password: friend['password'] as String,
                  ));
          expect(login?.user?.id, friend['id']);
          final region = StorageRegion.fromConfig(config);
          final friendScope = NativeScopeState(
            regionId: region.id,
            ownerHash:
                sha256.convert(utf8.encode(friend['id'] as String)).toString(),
            activationToken: 'p163-friend-scope',
            generation: 1,
            active: true,
          );
          friendCache =
              SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
          final authRepository = SupabaseAuthRepository(
            client: friendClient,
            config: config,
            sessionStorage: const _P163Storage(),
          );
          final container = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(friendClient),
            appConfigProvider.overrideWithValue(config),
            storageRegionProvider.overrideWithValue(region),
            authRepositoryProvider.overrideWithValue(authRepository),
            activeScheduleContextProvider
                .overrideWithValue(ActiveScheduleContext(
              ownerUserId: friend['id'] as String,
              universityId: fixture['university_id'] as String,
              termId: fixture['viewer_term_id'] as String,
              academicYear: 2026,
              primaryCalendarId: fixture['viewer_calendar_id'] as String,
            )),
            nativeScopeBridgeProvider
                .overrideWith((ref) => _P163NativeScope(friendScope)),
            sharedFriendCacheDatabaseProvider.overrideWithValue(friendCache),
          ]);
          friendContainer = container;
          final authSubscription = container.listen(
              currentAuthSessionProvider, (_, __) {},
              fireImmediately: true);
          addTearDown(authSubscription.close);
          await _waitForViewer(tester, container, friend['id'] as String);
          await tester.runAsync(() => container
              .read(friendsControllerProvider.future)
              .timeout(const Duration(seconds: 20)));
          friendRouter = GoRouter(
            initialLocation: '/shared/friend/${owner['id']}',
            routes: [
              GoRoute(
                path: '/shared/friend/:userId',
                builder: (context, state) => FriendTimetableScreen(
                  friendUserId: state.pathParameters['userId']!,
                ),
              ),
            ],
          );
          await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: friendRouter),
          ));
          final settled = await _waitForPrivateProjection(
            tester,
            container,
            friendTransport,
          );
          final response = friendTransport.scheduleBody == null
              ? const <String, dynamic>{}
              : jsonDecode(friendTransport.scheduleBody!)
                  as Map<String, dynamic>;
          final responseRows =
              ((response['rows'] as Map?)?['items'] as List?) ?? const [];
          final currentState =
              container.read(friendsControllerProvider).valueOrNull;
          expect(
            settled,
            isTrue,
            reason:
                'schedule HTTP 200=${friendTransport.calls.contains('get_friend_schedule:200')}; '
                'state loading=${currentState?.isLoading}; '
                'state row count=${currentState?.schedule.length}; '
                'empty state=${find.text('共有されている予定はありません').evaluate().isNotEmpty}',
          );
          expect(
              friendTransport.calls
                  .where((c) => c == 'get_friend_schedule:200'),
              hasLength(1));
          expect(friendTransport.scheduleBody, isNot(contains(title)));
          expect(friendTransport.scheduleBody, isNot(contains(location)));
          expect(friendTransport.scheduleBody, isNot(contains(description)));
          expect(responseRows, isEmpty);
          expect(currentState?.schedule, isEmpty);
          expect(currentState?.isLoading, isFalse);
          expect(currentState?.errorMessage, isNull);
          expect(find.text(title), findsNothing);
          expect(find.textContaining(location), findsNothing);
          expect(find.textContaining(description), findsNothing);
          expect(find.text('共有されている予定はありません'), findsOneWidget);
          expect(tester.takeException(), isNull);
          debugPrint(
              'P163: actual visibility UI saved PRIVATE; separate GoTrue viewer received an empty schedule projection and rendered the private empty state');
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          friendRouter?.dispose();
          friendContainer?.dispose();
          if (friendCache != null) {
            await friendCache.close().timeout(const Duration(seconds: 10));
          }
          await tester.runAsync(() async {
            try {
              await friendClient.dispose().timeout(const Duration(seconds: 8));
            } on TimeoutException {
              /* The strict loopback transport is closed below. */
            }
          });
          friendTransport.close();
        }
      }, _P163HttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 2)),
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

Future<bool> _waitForSavedVisibility(
  WidgetTester tester,
  _P163Transport transport,
) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final friendshipsRefreshed =
        transport.calls.where((c) => c == 'list_friendships:200').length >= 2;
    final rulesRefreshed = transport.calls
            .where((c) => c == 'list_friend_visibility_rules:200')
            .length >=
        2;
    if (transport.calls.contains('set_friend_visibility:200') &&
        friendshipsRefreshed &&
        rulesRefreshed &&
        find.text('公開範囲を保存しました').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Future<bool> _waitForPrivateProjection(
  WidgetTester tester,
  ProviderContainer container,
  _P163Transport transport,
) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(friendsControllerProvider).valueOrNull;
    if (transport.calls.contains('get_friend_schedule:200') &&
        state?.isLoading == false &&
        state?.schedule.isEmpty == true &&
        find.text('共有されている予定はありません').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P163 denied unexpected Realtime traffic.');
