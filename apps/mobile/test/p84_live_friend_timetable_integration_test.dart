// ignore_for_file: unnecessary_overrides

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

class _LocalhostOnlyClient extends http.BaseClient {
  final HttpClient _httpClient = HttpClient()
    ..maxConnectionsPerHost = 20
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    };
  late final IOClient _delegate = IOClient(_httpClient);

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port != 58491 ||
        !uri.path.startsWith('/rest/v1/rpc/')) {
      throw StateError('Integration test attempted a non-loopback request.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest original) async {
    final uri = original.url;
    _validate(uri);
    _mark('transport:${original.method}:${uri.host}:${uri.port}:${uri.path}');

    try {
      final response = await _delegate.send(original);
      final call = uri.path.split('/').last;
      _mark('rpc:$call:${response.statusCode}');
      return response;
    } catch (error) {
      _mark('transport_error:${error.runtimeType}:${uri.path}');
      rethrow;
    }
  }
}

class _LoopbackOnlyHttpOverrides extends HttpOverrides {
  // Bypass TestWidgetsFlutterBinding's HTTP stub with a real local-only client.
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);

  @override
  String findProxyFromEnvironment(
    Uri uri,
    Map<String, String>? environment,
  ) {
    _LocalhostOnlyClient._validate(uri);
    return 'DIRECT';
  }
}

class _SyntheticNativeScopeBridge implements NativeScopeBridge {
  _SyntheticNativeScopeBridge(this._scope);

  final NativeScopeState _scope;

  @override
  bool get isSupported => true;

  @override
  Future<NativeScopeState> current() async => _scope;

  @override
  Future<NativeScopeState> activate(
          StorageRegion region, String ownerUserId) async =>
      _scope;

  @override
  Future<NativeScopeState> deactivate() async =>
      const NativeScopeState.inactive();

  @override
  Future<NativeScopeState> prepare(StorageRegion region) async => _scope;
}

void _mark(String value) {
  final path = Platform.environment['P84_FLUTTER_PROGRESS'];
  if (path != null) {
    File(path).writeAsStringSync('$value\n', mode: FileMode.append);
  }
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('Realtime is outside this REST-only acceptance test.');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GoTrue friend projection is rendered in the timetable screen',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P84_FLUTTER_FIXTURE'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final friendId = fixture['friend_id'] as String;
      final url = fixture['url'] as String;
      final client = SupabaseClient(
        url,
        fixture['anon_key'] as String,
        httpClient: _LocalhostOnlyClient(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        realtimeClientOptions: const RealtimeClientOptions(
          transport: _denyRealtime,
        ),
      );
      addTearDown(() async {
        _mark('client_dispose_started');
        await client
            .dispose()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
        _mark('client_dispose_finished_or_timed_out');
      });

      _mark('test_started');
      final recovered = await tester.runAsync(
        () => client.auth
            .recoverSession(jsonEncode(fixture['auth_session']))
            .timeout(const Duration(seconds: 10)),
      );
      expect(recovered?.session, isNotNull);
      _mark('go_true_session_recovered');
      final viewerId = recovered!.session!.user.id;
      final appConfig = AppConfig.validated(
        environment: 'local',
        demoMode: false,
        supabaseUrl: url,
        legacySupabaseAnonKey: fixture['anon_key'] as String,
      );
      final region = StorageRegion.fromConfig(appConfig);
      final ownerHash = sha256.convert(utf8.encode(viewerId)).toString();
      final nativeScope = NativeScopeState(
        regionId: region.id,
        ownerHash: ownerHash,
        activationToken: 'p84-synthetic-test-scope',
        generation: 1,
        active: true,
      );
      final cache =
          SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
      final container = ProviderContainer(overrides: [
        supabaseClientProvider.overrideWithValue(client),
        currentAuthSessionProvider
            .overrideWithValue(AppAuthSession(userId: viewerId)),
        activeScheduleContextProvider.overrideWithValue(ActiveScheduleContext(
          ownerUserId: viewerId,
          universityId: 'p84-synthetic-university',
          termId: '8d846410-8400-4410-8400-000000000001',
          academicYear: 2026,
          primaryCalendarId: '8d846410-8400-4410-8400-000000000002',
        )),
        appConfigProvider.overrideWithValue(appConfig),
        storageRegionProvider.overrideWithValue(region),
        nativeScopeBridgeProvider
            .overrideWith((ref) => _SyntheticNativeScopeBridge(nativeScope)),
        sharedFriendCacheDatabaseProvider.overrideWithValue(cache),
      ]);
      addTearDown(container.dispose);
      addTearDown(cache.close);
      _mark('controller_build_started');
      await tester.runAsync(
        () => container
            .read(friendsControllerProvider.future)
            .timeout(const Duration(seconds: 20)),
      );
      _mark('controller_build_complete');
      final repository = container.read(friendRepositoryProvider);
      final listTerms = await tester.runAsync(
        () => repository
            .listFriendTerms(friendId)
            .timeout(const Duration(seconds: 10)),
      );
      expect(listTerms, isNotEmpty);
      _mark(
        'repository_list_friend_terms_preflight=completed;rows=${listTerms!.length}',
      );

      final router = GoRouter(
        initialLocation: '/shared/friend/$friendId',
        routes: [
          GoRoute(
            path: '/shared/friend/:userId',
            builder: (context, state) => FriendTimetableScreen(
              friendUserId: state.pathParameters['userId']!,
              loadOnInit: false,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      _mark('widget_pumped');
      final relationship = container
          .read(friendsControllerProvider)
          .value!
          .relationships
          .firstWhere((item) => item.otherUserId == friendId);
      await tester.runAsync(
        () => container
            .read(friendsControllerProvider.notifier)
            .selectFriend(
              relationship,
              rangeStart: DateTime.utc(2026, 10, 1),
              rangeEnd: DateTime.utc(2026, 10, 2),
            )
            .timeout(const Duration(seconds: 20)),
      );
      _mark('controller_select_friend_completed');
      await tester.pump();

      final state = container.read(friendsControllerProvider).valueOrNull;
      _mark(
        'result:allowed=${state?.scheduleAllowed};loading=${state?.isLoading};offline=${state?.isOffline};error=${state?.errorMessage ?? 'none'};rows=${state?.schedule.length ?? -1}',
      );
      expect(state?.scheduleAllowed, isTrue);
      expect(state?.scheduleFriendId, friendId);
      expect(state?.schedule.map((row) => row.title),
          contains('P84 rendered event canary'));
      expect(find.text('友だちの時間割'), findsOneWidget);
      expect(find.text('P84 rendered event canary'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, _LoopbackOnlyHttpOverrides());
  });
}
