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
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

const _baseUrl = 'http://127.0.0.1:59221';
const _allowedRpc = {
  'list_my_groups',
  'get_group',
  'list_group_members',
  'list_group_member_blocked_users',
  'list_group_events',
};

class _P143Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final memberBodies = <String>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59221) {
      throw StateError('P143 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P143 blocked an unexpected local API route.');
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
    if (rpc == 'list_group_members' && streamed.statusCode == 200) {
      memberBodies.add(utf8.decode(bytes));
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

class _P143Overrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P143Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P143Storage extends LocalStorage {
  const _P143Storage();

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
    'P143 blocked group profile name is redacted by RPC through production auth stream',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P143_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
            as Map<String, dynamic>;
        final users = fixture['users'] as Map<String, dynamic>;
        final blocker = users['blocker'] as Map<String, dynamic>;
        final blocked = users['blocked'] as Map<String, dynamic>;
        final groupId = fixture['group_id'] as String;
        final transport = _P143Transport();
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
          final blockerAuth = await tester.runAsync(
            () => client.auth.signInWithPassword(
              email: blocker['email'] as String,
              password: blocker['password'] as String,
            ),
          );
          expect(blockerAuth?.user?.id, blocker['id']);
          expect(transport.calls, contains('/auth/v1/token:200'));

          final authRepository = SupabaseAuthRepository(
            client: client,
            config: AppConfig.validated(
              environment: 'local',
              demoMode: false,
              supabaseUrl: _baseUrl,
              legacySupabaseAnonKey: fixture['anon_key'] as String,
            ),
            sessionStorage: const _P143Storage(),
          );
          final providerContainer = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(client),
            appConfigProvider.overrideWithValue(AppConfig.validated(
              environment: 'local',
              demoMode: false,
              supabaseUrl: _baseUrl,
              legacySupabaseAnonKey: fixture['anon_key'] as String,
            )),
            authRepositoryProvider.overrideWithValue(authRepository),
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
          await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.future)
                .timeout(const Duration(seconds: 20)),
          );
          await tester.pumpWidget(UncontrolledProviderScope(
            container: providerContainer,
            child: MaterialApp(home: GroupDetailScreen(groupId: groupId)),
          ));
          final initialOpen = await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.notifier)
                .open(groupId)
                .timeout(const Duration(seconds: 20)),
          );
          expect(initialOpen, isTrue);
          await tester.pump();
          await _waitForGroupProjection(tester, providerContainer, groupId,
              blocker['id'] as String, transport,
              expectedResponses: 1);

          expect(transport.memberBodies, hasLength(1));
          expect(transport.memberBodies.single, contains('ブロック中のメンバー'));
          expect(transport.memberBodies.single,
              isNot(contains(blocked['display_name'])));
          expect(find.text(blocker['display_name'] as String), findsOneWidget);
          expect(find.text(blocked['display_name'] as String), findsNothing);
          expect(find.text('ブロック中のメンバー'), findsOneWidget);

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
          await _waitForGroupProjection(tester, providerContainer, groupId,
              blocked['id'] as String, transport,
              expectedResponses: 2);

          expect(transport.memberBodies, hasLength(2));
          expect(transport.memberBodies.last, contains('ブロック中のメンバー'));
          expect(transport.memberBodies.last,
              isNot(contains(blocker['display_name'])));
          expect(find.text(blocked['display_name'] as String), findsOneWidget);
          expect(find.text(blocker['display_name'] as String), findsNothing);
          expect(find.text('ブロック中のメンバー'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(
            transport.calls.where((call) => call == '/auth/v1/token:200'),
            hasLength(2),
          );

          debugPrint(
            'P143: production Auth stream switched GoTrue principal; list_group_members HTTP 200 redacted blocked display name in both directions; screen remained mounted; no credentials emitted',
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
            debugPrint('P143: client disposal exceeded bounded wait');
          }
          transport.close();
        }
      }, _P143Overrides());
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

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

Future<void> _waitForGroupProjection(
  WidgetTester tester,
  ProviderContainer container,
  String groupId,
  String viewerId,
  _P143Transport transport, {
  required int expectedResponses,
}) async {
  final result = await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final state = container.read(groupsControllerProvider).valueOrNull;
      if (transport.memberBodies.length >= expectedResponses &&
          state?.selected?.id == groupId &&
          state?.blockedMemberStatusLoaded == true &&
          state?.blockedMemberStatusViewerUserId == viewerId) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  });
  await tester.pump();
  expect(result, isTrue, reason: 'live group block projection did not settle');
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P143 REST-only test blocked Realtime.');
