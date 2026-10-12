import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/shared_friend_cache_database.dart';
import 'package:university_schedule_mobile/features/friends/presentation/friend_timetable_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

class _P118LoopbackClient extends http.BaseClient {
  late final HttpClient _httpClient = HttpClient()
    ..maxConnectionsPerHost = 20
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    };
  late final IOClient _delegate = IOClient(_httpClient);
  final calls = <String>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port != 59418 ||
        !uri.path.startsWith('/rest/v1/rpc/')) {
      throw StateError('P118 test blocked a request outside loopback RPC.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final name = request.url.path.split('/').last;
    if (!const {
      'list_friendships',
      'list_blocked_users',
      'list_friend_invites',
      'get_my_friend_username',
      'list_friend_visibility_rules',
      'list_friend_terms',
      'get_friend_schedule',
    }.contains(name)) {
      throw StateError('P118 test blocked an unexpected local API route.');
    }
    calls.add('start:$name');
    final response = await _delegate.send(request);
    calls.add('$name:${response.statusCode}');
    return response;
  }

  @override
  void close() {
    _httpClient.close(force: true);
    _delegate.close();
    super.close();
  }
}

class _P118HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(
    Uri uri,
    Map<String, String>? environment,
  ) {
    _P118LoopbackClient._validate(uri);
    return 'DIRECT';
  }
}

class _P118NativeScopeBridge implements NativeScopeBridge {
  const _P118NativeScopeBridge(this.scope);

  final NativeScopeState scope;

  @override
  bool get isSupported => true;

  @override
  Future<NativeScopeState> current() async => scope;

  @override
  Future<NativeScopeState> activate(
    StorageRegion region,
    String ownerUserId,
  ) async =>
      scope;

  @override
  Future<NativeScopeState> deactivate() async =>
      const NativeScopeState.inactive();

  @override
  Future<NativeScopeState> prepare(StorageRegion region) async => scope;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('P118 local API route did not complete.');
    }
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P118 inherited friend defaults render through local GoTrue/PostgREST',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P118_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(
          File(fixturePath!).readAsStringSync(),
        ) as Map<String, dynamic>;
        final scenarios = fixture['scenarios'] as List<dynamic>;

        for (final raw in scenarios) {
          final scenario = raw as Map<String, dynamic>;
          final viewerId = scenario['viewer_id'] as String;
          final friendId = scenario['owner_id'] as String;
          final url = fixture['url'] as String;
          final anonKey = fixture['anon_key'] as String;
          final transport = _P118LoopbackClient();
          final client = SupabaseClient(
            url,
            anonKey,
            httpClient: transport,
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            realtimeClientOptions: const RealtimeClientOptions(
              transport: _denyRealtime,
            ),
          );
          final recovered = await tester.runAsync(
            () => client.auth
                .recoverSession(jsonEncode(scenario['auth_session']))
                .timeout(const Duration(seconds: 10)),
          );
          expect(recovered?.session?.user.id, viewerId);

          final appConfig = AppConfig.validated(
            environment: 'local',
            demoMode: false,
            supabaseUrl: url,
            legacySupabaseAnonKey: anonKey,
          );
          final region = StorageRegion.fromConfig(appConfig);
          final nativeScope = NativeScopeState(
            regionId: region.id,
            ownerHash: sha256.convert(utf8.encode(viewerId)).toString(),
            activationToken: 'p118-synthetic-scope',
            generation: 1,
            active: true,
          );
          final cache = SharedFriendCacheDatabase.forExecutor(
            NativeDatabase.memory(),
          );
          final container = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(client),
            currentAuthSessionProvider
                .overrideWithValue(AppAuthSession(userId: viewerId)),
            activeScheduleContextProvider.overrideWithValue(
              ActiveScheduleContext(
                ownerUserId: viewerId,
                universityId: fixture['university_id'] as String,
                termId: scenario['context_term_id'] as String,
                academicYear: 2026,
                primaryCalendarId: scenario['context_calendar_id'] as String,
              ),
            ),
            appConfigProvider.overrideWithValue(appConfig),
            storageRegionProvider.overrideWithValue(region),
            nativeScopeBridgeProvider.overrideWith(
              (ref) => _P118NativeScopeBridge(nativeScope),
            ),
            sharedFriendCacheDatabaseProvider.overrideWithValue(cache),
          ]);
          final router = GoRouter(
            initialLocation: '/shared/friend/$friendId',
            routes: [
              GoRoute(
                path: '/shared/friend/:userId/event/:eventId',
                builder: (context, state) => FriendTimetableScreen(
                  friendUserId: state.pathParameters['userId']!,
                  eventId: state.pathParameters['eventId'],
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
            child: MaterialApp.router(routerConfig: router),
          ));
          await tester.pump();
          await _pumpUntil(
            tester,
            () =>
                transport.calls.contains('list_friend_terms:200') &&
                transport.calls.contains('get_friend_schedule:200'),
          );
          await tester.pump();

          expect(transport.calls, contains('list_friend_terms:200'));
          expect(transport.calls, contains('get_friend_schedule:200'));
          expect(transport.calls.any((call) => call.contains(':401')), isFalse);
          expect(transport.calls.any((call) => call.contains(':403')), isFalse);
          expect(find.text('友だちの時間割'), findsOneWidget);
          final expected = scenario['expected'] as String;
          if (expected == 'FULL') {
            expect(find.text(scenario['title'] as String), findsOneWidget);
            expect(
                find.textContaining('private location canary'), findsOneWidget);
            expect(
              find.textContaining('private description canary'),
              findsOneWidget,
            );
          } else {
            expect(find.text('予定あり'), findsOneWidget);
            expect(
                find.textContaining('private location canary'), findsNothing);
            expect(
              find.textContaining('private description canary'),
              findsNothing,
            );
            expect(find.textContaining('title canary'), findsNothing);
          }
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          router.dispose();
          container.dispose();
          await cache.close();
          transport.close();
          await client.dispose();
        }
      }, _P118HttpOverrides());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('Realtime is outside the P118 REST-only test.');
