import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/presentation/shared_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

const _baseUrl = 'http://127.0.0.1:59222';
const _allowedRpc = {
  'list_my_groups',
  'list_friendships',
  'list_blocked_users',
  'list_friend_invites',
  'get_my_friend_username',
  'list_friend_visibility_rules',
  'find_friend_by_username',
};

class _P144Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final searchBodies = <String>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59222) {
      throw StateError('P144 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P144 blocked an unexpected local API route.');
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
    if (rpc == 'find_friend_by_username' && streamed.statusCode == 200) {
      searchBodies.add(utf8.decode(bytes));
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

class _P144Overrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P144Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P144Storage extends LocalStorage {
  const _P144Storage();

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P144 both block directions suppress profile search in live SharedScreen',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P144_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
            as Map<String, dynamic>;
        final users = fixture['users'] as Map<String, dynamic>;
        final blocker = users['blocker'] as Map<String, dynamic>;
        final blocked = users['blocked'] as Map<String, dynamic>;
        final blockerUsername = _username('b', blocker['id'] as String);
        final blockedUsername = _username('x', blocked['id'] as String);
        final transport = _P144Transport();
        final client = SupabaseClient(
          _baseUrl,
          fixture['anon_key'] as String,
          httpClient: transport,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          realtimeClientOptions: const RealtimeClientOptions(
            transport: _denyRealtime,
          ),
        );
        ProviderContainer? container;
        try {
          final signedIn = await tester.runAsync(
            () => client.auth.signInWithPassword(
              email: blocker['email'] as String,
              password: blocker['password'] as String,
            ),
          );
          expect(signedIn?.user?.id, blocker['id']);
          final config = AppConfig.validated(
            environment: 'local',
            demoMode: false,
            supabaseUrl: _baseUrl,
            legacySupabaseAnonKey: fixture['anon_key'] as String,
          );
          final authRepository = SupabaseAuthRepository(
            client: client,
            config: config,
            sessionStorage: const _P144Storage(),
          );
          final providerContainer = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(client),
            appConfigProvider.overrideWithValue(config),
            authRepositoryProvider.overrideWithValue(authRepository),
            friendsControllerProvider.overrideWith(
              _P144SearchFriendsController.new,
            ),
            activeScheduleContextProvider.overrideWithValue(null),
          ]);
          container = providerContainer;
          final authSubscription = providerContainer.listen(
            currentAuthSessionProvider,
            (_, __) {},
            fireImmediately: true,
          );
          addTearDown(authSubscription.close);
          await _waitForViewer(
              tester, providerContainer, blocker['id'] as String);
          await tester.pumpWidget(UncontrolledProviderScope(
            container: providerContainer,
            child: const MaterialApp(home: SharedScreen()),
          ));
          await tester.runAsync(
            () => providerContainer
                .read(friendsControllerProvider.future)
                .timeout(const Duration(seconds: 15)),
          );
          await tester.pump();
          await _search(
              tester, providerContainer, transport, blockedUsername, 1);
          expect(transport.searchBodies.single.trim(), '[]');
          expect(transport.searchBodies.single,
              isNot(contains(blocked['display_name'])));
          expect(find.byKey(const Key('friend-username-result')), findsNothing);
          expect(find.text('ユーザーが見つかりませんでした'), findsOneWidget);

          final switched = await tester.runAsync(
            () => client.auth.signInWithPassword(
              email: blocked['email'] as String,
              password: blocked['password'] as String,
            ),
          );
          expect(switched?.user?.id, blocked['id']);
          await _waitForViewer(
              tester, providerContainer, blocked['id'] as String);
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
          await _search(
              tester, providerContainer, transport, blockerUsername, 2);

          expect(transport.searchBodies, hasLength(2));
          expect(transport.searchBodies.last.trim(), '[]');
          expect(transport.searchBodies.last,
              isNot(contains(blocker['display_name'])));
          expect(find.byKey(const Key('friend-username-result')), findsNothing);
          expect(find.text('ユーザーが見つかりませんでした'), findsOneWidget);
          expect(
            transport.calls.where((call) => call == '/auth/v1/token:200'),
            hasLength(2),
          );
          expect(tester.takeException(), isNull);
          debugPrint(
            'P144: production Auth stream; SharedScreen username search; find_friend_by_username returned HTTP 200 empty for both opposite blocked viewers; no names emitted',
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          container?.dispose();
          final disposed = await tester.runAsync(() async {
            try {
              await client.dispose().timeout(const Duration(seconds: 8));
              return true;
            } on TimeoutException {
              return false;
            }
          });
          if (disposed != true) {
            debugPrint('P144: client disposal exceeded bounded wait');
          }
          transport.close();
        }
      }, _P144Overrides());
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String _username(String marker, String userId) =>
    'p144_${marker}_${userId.replaceAll('-', '').substring(0, 12)}';

Future<void> _waitForViewer(
  WidgetTester tester,
  ProviderContainer container,
  String expectedUserId,
) async {
  final result = await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (container.read(currentAuthSessionProvider)?.userId ==
          expectedUserId) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  });
  expect(result, isTrue,
      reason: 'production Auth stream did not publish viewer');
}

Future<void> _search(
  WidgetTester tester,
  ProviderContainer container,
  _P144Transport transport,
  String username,
  int expectedCount,
) async {
  await tester.enterText(
      find.byKey(const Key('friend-username-search')), username);
  await tester.pump(const Duration(milliseconds: 350));
  final stopwatch = Stopwatch()..start();
  while (transport.searchBodies.length < expectedCount &&
      stopwatch.elapsed < const Duration(seconds: 20)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  final settled = transport.searchBodies.length >= expectedCount;
  expect(settled, isTrue, reason: 'live profile search did not settle');
  expect(
    transport.calls.where((call) => call == 'find_friend_by_username:200'),
    hasLength(expectedCount),
  );
  expect(
    container.read(friendsControllerProvider).valueOrNull?.isSearchingUsername,
    isFalse,
    reason:
        'production search controller did not publish the completed request',
  );
}

class _P144SearchFriendsController extends FriendsController {
  @override
  Future<void> refreshRelationships() async {}
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P144 REST-only test blocked Realtime.');
