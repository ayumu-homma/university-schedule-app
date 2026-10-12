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

const _baseUrl = 'http://127.0.0.1:59234';
const _allowedRpc = {
  'get_group',
  'get_group_default_visibility',
  'set_group_default_visibility',
  'list_group_members',
  'list_group_member_blocked_users',
  'list_group_events',
  'list_group_invites',
  'create_group_event',
  'get_visible_events',
};

class _P166Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final visibleEventResponses = <List<dynamic>>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59234) {
      throw StateError('P166 blocked a request outside its loopback bridge.');
    }
    final authPath = uri.path == '/auth/v1/token' ||
        uri.path == '/auth/v1/user' ||
        uri.path == '/auth/v1/logout';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath && (rpc == null || !_allowedRpc.contains(rpc.group(1)))) {
      throw StateError('P166 blocked an unexpected local API route.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    final streamed = await _client.send(request);
    final bytes = await streamed.stream.toBytes();
    calls.add('${rpc ?? request.url.path}:${streamed.statusCode}');
    if (rpc == 'get_visible_events' && streamed.statusCode == 200) {
      visibleEventResponses
          .add((jsonDecode(utf8.decode(bytes)) as List).cast<dynamic>());
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

class _P166HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P166Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P166Storage extends LocalStorage {
  const _P166Storage();
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
      'P166 owner saves group visibility and member receives redacted projection',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P166_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final users = fixture['users'] as Map<String, dynamic>;
      final owner = users['owner'] as Map<String, dynamic>;
      final member = users['member'] as Map<String, dynamic>;
      final groupId = fixture['group_id'] as String;
      final anonKey = fixture['anon_key'] as String;
      final transport = _P166Transport();
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
      try {
        final signedIn = await tester.runAsync(() => client.auth
            .signInWithPassword(
                email: owner['email'] as String,
                password: owner['password'] as String));
        expect(signedIn?.user?.id, owner['id']);

        final config = AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: _baseUrl,
          legacySupabaseAnonKey: anonKey,
        );
        final authRepository = SupabaseAuthRepository(
          client: client,
          config: config,
          sessionStorage: const _P166Storage(),
        );
        final providerContainer = ProviderContainer(overrides: [
          supabaseClientProvider.overrideWithValue(client),
          appConfigProvider.overrideWithValue(config),
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
        await _waitForViewer(tester, providerContainer, owner['id'] as String);
        await tester.runAsync(() => providerContainer
            .read(groupsControllerProvider.future)
            .timeout(const Duration(seconds: 20)));
        final opened = await tester.runAsync(() => providerContainer
            .read(groupsControllerProvider.notifier)
            .open(groupId)
            .timeout(const Duration(seconds: 20)));
        expect(opened, isTrue);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: providerContainer,
          child: MaterialApp(home: GroupDetailScreen(groupId: groupId)),
        ));
        await tester.pump();
        expect(
            await _waitForGroup(
                tester, providerContainer, groupId, 'TITLE_ONLY'),
            isTrue);
        expect(find.text('タイトルのみ'), findsOneWidget);

        await tester
            .tap(find.byKey(const Key('edit-group-default-visibility')));
        await tester.pumpAndSettle();
        expect(find.text('共有時間割と空き時間検索での公開範囲です。グループ詳細の予定閲覧権限は変わりません。'),
            findsOneWidget);
        await tester.tap(find.byKey(const Key('group-visibility-choice')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('予定あり').last);
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const Key('save-group-default-visibility')));
        await tester.pumpAndSettle();
        expect(find.text('共有時間割と空き時間検索での公開範囲です。グループ詳細の予定閲覧権限は変わりません。'),
            findsNothing);
        final visibilityUpdated = await _waitForGroup(
            tester, providerContainer, groupId, 'BUSY_ONLY');
        final afterSave =
            providerContainer.read(groupsControllerProvider).valueOrNull;
        final rpcCalls = transport.calls
            .where((call) => !call.startsWith('/auth/'))
            .toList(growable: false);
        expect(visibilityUpdated, isTrue,
            reason:
                'P166 state selected=${afterSave?.selected?.defaultVisibility ?? "none"}, mutating=${afterSave?.mutating ?? false}, hasError=${afterSave?.errorMessage != null}; RPC calls=${rpcCalls.join(",")}');
        expect(transport.calls, contains('set_group_default_visibility:200'));
        expect(transport.calls, contains('get_group_default_visibility:200'));
        expect(find.text('予定あり'), findsOneWidget);

        final start = DateTime.now().toUtc().add(const Duration(days: 2));
        final eventResponse = await tester.runAsync(() => client.rpc(
              'create_group_event',
              params: {
                'p_group_id': groupId,
                'p_title': 'P166 private-title-canary',
                'p_start_at': start.toIso8601String(),
                'p_end_at':
                    start.add(const Duration(hours: 1)).toIso8601String(),
                'p_location': 'P166 private-location-canary',
                'p_description': 'P166 private-description-canary',
                'p_operation_id': '8f660000-8400-4900-8600-000000000004',
              },
            ));
        expect(eventResponse, isNotEmpty);

        await tester.runAsync(() => client.auth.signOut());
        final memberSignIn = await tester.runAsync(() => client.auth
            .signInWithPassword(
                email: member['email'] as String,
                password: member['password'] as String));
        expect(memberSignIn?.user?.id, member['id']);
        expect(
            await _waitForViewer(
                tester, providerContainer, member['id'] as String),
            isTrue);
        expect(
            await _waitForGroup(
                tester, providerContainer, groupId, 'BUSY_ONLY'),
            isTrue);
        expect(find.byKey(const Key('edit-group-default-visibility')),
            findsNothing);

        final rangeStart = start.subtract(const Duration(hours: 1));
        final response = await tester.runAsync(() => client.rpc(
              'get_visible_events',
              params: {
                'viewer_id': member['id'],
                'range_start': rangeStart.toIso8601String(),
                'range_end':
                    start.add(const Duration(hours: 2)).toIso8601String(),
              },
            ));
        final rows = (response as List).cast<Map<String, dynamic>>();
        final projected = rows.single;
        expect(projected['visibility_level'], 'BUSY_ONLY');
        expect(projected['title'], '予定あり');
        expect(projected['location'], isNull);
        expect(projected['description'], isNull);
        expect(jsonEncode(rows), isNot(contains('P166 private-title-canary')));
        expect(
            jsonEncode(rows), isNot(contains('P166 private-location-canary')));
        expect(jsonEncode(rows),
            isNot(contains('P166 private-description-canary')));
        expect(transport.calls, contains('get_visible_events:200'));
        expect(tester.takeException(), isNull);
        debugPrint(
            'P166: production GoTrue and RPC setting flow; owner saved BUSY_ONLY, member read it after account switch and API omitted private event fields; canaries omitted');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container?.dispose();
        await tester.runAsync(() async {
          try {
            await client.dispose().timeout(const Duration(seconds: 8));
          } on TimeoutException {
            // The restricted transport below is explicitly closed.
          }
        });
        transport.close();
      }
    }, _P166HttpOverrides());
  }, timeout: const Timeout(Duration(seconds: 120)));
}

Future<bool> _waitForViewer(
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
  return ready == true;
}

Future<bool> _waitForGroup(WidgetTester tester, ProviderContainer container,
    String groupId, String visibility) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(groupsControllerProvider).valueOrNull;
    final group = state?.selected;
    if (group?.id == groupId &&
        group?.defaultVisibility == visibility &&
        state?.mutating == false) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P166 denied unexpected Realtime traffic.');
