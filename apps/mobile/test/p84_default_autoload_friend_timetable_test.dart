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

const _titleCanary = 'P84 P112 title-only event';
const _locationCanary = 'P84 P112 private location canary';
const _descriptionCanary = 'P84 P112 private description canary';

class _LoopbackOnlyClient extends http.BaseClient {
  late final HttpClient _httpClient = _newHttpClient();
  late final IOClient _delegate = IOClient(_httpClient);
  final calls = <String>[];

  static HttpClient _newHttpClient() {
    return HttpClient()
      ..maxConnectionsPerHost = 20
      ..findProxy = (uri) {
        _validate(uri);
        return 'DIRECT';
      };
  }

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port != 58492 ||
        !uri.path.startsWith('/rest/v1/rpc/')) {
      throw StateError(
          'Test blocked a request outside loopback RPC projection.');
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
      throw StateError('Test blocked an unexpected local API route.');
    }
    calls.add('start:$name');
    _mark('rpc_start:$name');
    try {
      final response = await _delegate.send(request);
      calls.add('$name:${response.statusCode}');
      _mark('rpc:$name:${response.statusCode}');
      return response;
    } catch (error) {
      calls.add('error:${error.runtimeType}:$name');
      _mark('rpc_error:${error.runtimeType}:$name');
      rethrow;
    }
  }

  @override
  void close() {
    _httpClient.close(force: true);
    _delegate.close();
    super.close();
  }
}

class _LoopbackOnlyHttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(
    Uri uri,
    Map<String, String>? environment,
  ) {
    _LoopbackOnlyClient._validate(uri);
    return 'DIRECT';
  }
}

class _SyntheticNativeScopeBridge implements NativeScopeBridge {
  const _SyntheticNativeScopeBridge(this.scope);

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

void _mark(String value) {
  final path = Platform.environment['P84_FLUTTER_PROGRESS'];
  if (path != null) {
    File(path).writeAsStringSync('$value\n', mode: FileMode.append);
  }
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('Realtime is outside this REST-only test.');

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Expected local RPC did not complete.');
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
    'default timetable startup renders only the TITLE_ONLY friend projection',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixtureText = Platform.environment['P84_FLUTTER_FIXTURE_JSON'];
        expect(fixtureText, isNotNull);
        final fixture = jsonDecode(fixtureText!) as Map<String, dynamic>;
        final friendId = fixture['friend_id'] as String;
        final universityId = fixture['university_id'] as String;
        final termId = fixture['term_id'] as String;
        final calendarId = fixture['calendar_id'] as String;
        final url = fixture['url'] as String;
        final anonKey = fixture['anon_key'] as String;
        final transport = _LoopbackOnlyClient();
        final client = SupabaseClient(
          url,
          anonKey,
          httpClient: transport,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          realtimeClientOptions: const RealtimeClientOptions(
            transport: _denyRealtime,
          ),
        );
        addTearDown(() async {
          await client
              .dispose()
              .timeout(const Duration(seconds: 5), onTimeout: () {});
        });

        final recovered = await tester.runAsync(
          () => client.auth
              .recoverSession(jsonEncode(fixture['auth_session']))
              .timeout(const Duration(seconds: 10)),
        );
        expect(recovered?.session, isNotNull);
        final viewerId = recovered!.session!.user.id;
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
          activationToken: 'p84-p112-synthetic-scope',
          generation: 1,
          active: true,
        );
        final cache =
            SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
        final container = ProviderContainer(overrides: [
          supabaseClientProvider.overrideWithValue(client),
          currentAuthSessionProvider
              .overrideWithValue(AppAuthSession(userId: viewerId)),
          activeScheduleContextProvider.overrideWithValue(
            ActiveScheduleContext(
              ownerUserId: viewerId,
              universityId: universityId,
              termId: termId,
              academicYear: 2026,
              primaryCalendarId: calendarId,
            ),
          ),
          appConfigProvider.overrideWithValue(appConfig),
          storageRegionProvider.overrideWithValue(region),
          nativeScopeBridgeProvider.overrideWith(
            (ref) => _SyntheticNativeScopeBridge(nativeScope),
          ),
          sharedFriendCacheDatabaseProvider.overrideWithValue(cache),
        ]);
        addTearDown(container.dispose);
        addTearDown(cache.close);

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
        addTearDown(router.dispose);

        final apiClient = transport;
        _mark('default_widget_start');
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ));
        _mark('widget_pump_finished');
        await tester.pump();
        _mark('first_frame_pumped');

        await _pumpUntil(
          tester,
          () =>
              apiClient.calls.contains('list_friend_terms:200') &&
              apiClient.calls.contains('get_friend_schedule:200'),
        );
        await tester.pump();

        expect(apiClient.calls, contains('list_friend_terms:200'));
        expect(apiClient.calls, contains('get_friend_schedule:200'));
        expect(
          apiClient.calls.every((call) => !call.startsWith('error:')),
          isTrue,
        );
        expect(
          find.text('友だちの時間割'),
          findsOneWidget,
        );
        expect(find.text(_titleCanary), findsOneWidget);
        expect(find.text('10/1（木） 10:00〜11:00'), findsOneWidget);
        expect(find.byIcon(Icons.event_outlined), findsOneWidget);
        expect(find.text(_locationCanary), findsNothing);
        expect(find.text(_descriptionCanary), findsNothing);
        expect(tester.takeException(), isNull);

        final firstScheduleCalls = apiClient.calls
            .where((call) => call == 'get_friend_schedule:200')
            .length;
        await tester.tap(find.text(_titleCanary));
        await tester.pump(const Duration(milliseconds: 400));
        await _pumpUntil(
          tester,
          () =>
              apiClient.calls
                  .where((call) => call == 'get_friend_schedule:200')
                  .length >
              firstScheduleCalls,
        );
        await tester.pump();

        expect(find.text(_titleCanary), findsNWidgets(2));
        expect(find.text(_locationCanary), findsNothing);
        expect(find.text(_descriptionCanary), findsNothing);
        expect(
          apiClient.calls.any((call) => call.contains('/events')),
          isFalse,
        );
        _mark(
          'rendered=title,time,kind;private_fields=absent;rpc_only=true',
        );
        transport.close();
        _mark('transport_force_closed');
        expect(tester.takeException(), isNull);
      }, _LoopbackOnlyHttpOverrides());
    },
  );
}
