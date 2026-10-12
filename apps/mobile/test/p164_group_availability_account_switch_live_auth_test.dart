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

const _baseUrl = 'http://127.0.0.1:59232';
const _allowedRpc = {
  'list_my_groups',
  'get_group',
  'list_group_members',
  'list_group_member_blocked_users',
  'list_group_events',
  'list_group_invites',
  'find_group_availability',
  'validate_group_availability',
};

class _P164Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59232) {
      throw StateError('P164 blocked a request outside its loopback bridge.');
    }
    final authPath = uri.path == '/auth/v1/token' ||
        uri.path == '/auth/v1/user' ||
        uri.path == '/auth/v1/logout';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P164 blocked an unexpected local API route.');
      }
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

class _P164HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P164Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P164Storage extends LocalStorage {
  const _P164Storage();
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
      'P164 group availability result clears after live Auth account replacement',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P164_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final users = fixture['users'] as Map<String, dynamic>;
      final viewer = users['owner'] as Map<String, dynamic>;
      final peer = users['blocked'] as Map<String, dynamic>;
      final groupId = fixture['group_id'] as String;
      final anonKey = fixture['anon_key'] as String;
      final transport = _P164Transport();
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
                email: viewer['email'] as String,
                password: viewer['password'] as String));
        expect(signedIn?.user?.id, viewer['id']);

        final config = AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: _baseUrl,
          legacySupabaseAnonKey: anonKey,
        );
        final authRepository = SupabaseAuthRepository(
          client: client,
          config: config,
          sessionStorage: const _P164Storage(),
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
        await _waitForViewer(tester, providerContainer, viewer['id'] as String);
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
        await tester.pumpAndSettle();

        expect(transport.calls, contains('list_group_members:200'));
        expect(
            transport.calls, contains('list_group_member_blocked_users:200'));
        await tester.tap(find.byKey(const Key('group-availability-search')));
        await tester.pumpAndSettle();
        final blockedTile = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'ブロック中のメンバー').last,
        );
        expect(blockedTile.value, isFalse);
        expect(blockedTile.onChanged, isNull);

        await tester.tap(find.text('検索'));
        final completed = await _waitForAvailability(tester, transport);
        expect(completed, isTrue);
        expect(transport.calls, contains('find_group_availability:200'));
        expect(transport.calls, contains('validate_group_availability:200'));
        expect(find.text('共通空き時間'), findsOneWidget);
        final beforeSwitch =
            container.read(groupsControllerProvider).valueOrNull;
        expect(beforeSwitch?.availabilityResult, isNotNull);
        final finderCount = transport.calls
            .where((call) => call == 'find_group_availability:200')
            .length;
        final validationCount = transport.calls
            .where((call) => call == 'validate_group_availability:200')
            .length;

        // Replace the owner with the second existing synthetic GoTrue member
        // while the result dialog and GroupDetailScreen remain mounted.
        await tester.runAsync(() => authRepository.signOut());
        final replacementLogin =
            await tester.runAsync(() => client.auth.signInWithPassword(
                  email: peer['email'] as String,
                  password: peer['password'] as String,
                ));
        expect(replacementLogin?.user?.id, peer['id']);
        await _waitForViewer(tester, providerContainer, peer['id'] as String);
        await tester.runAsync(() => providerContainer
            .read(groupsControllerProvider.future)
            .timeout(const Duration(seconds: 20)));
        var accountSwitchNoticeVisible = false;
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (find.text('ログイン状態が変わりました').evaluate().isNotEmpty) {
            accountSwitchNoticeVisible = true;
            break;
          }
        }
        expect(accountSwitchNoticeVisible, isTrue);

        final afterSwitch =
            container.read(groupsControllerProvider).valueOrNull;
        expect(afterSwitch?.selected, isNull);
        expect(afterSwitch?.availabilityResult, isNull);
        expect(afterSwitch?.availabilityWindows, isEmpty);
        expect(find.text('共通空き時間'), findsNothing);
        expect(find.text('ログイン状態が変わりました'), findsWidgets);
        expect(
            transport.calls
                .where((call) => call == 'find_group_availability:200')
                .length,
            finderCount);
        expect(
            transport.calls
                .where((call) => call == 'validate_group_availability:200')
                .length,
            validationCount);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 60));
        await tester.pump();
        debugPrint(
          'P164: local-scope production signout and second GoTrue login cleared the prior group availability result/dialog; no finder or validation RPC repeated',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container?.dispose();
        await tester.runAsync(() async {
          try {
            await client.dispose().timeout(const Duration(seconds: 8));
          } on TimeoutException {
            // The injected transport is explicitly closed below.
          }
        });
        transport.close();
      }
    }, _P164HttpOverrides());
  }, timeout: const Timeout(Duration(seconds: 90)));
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

Future<bool> _waitForAvailability(
  WidgetTester tester,
  _P164Transport transport,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    if (transport.calls.contains('find_group_availability:200') &&
        transport.calls.contains('validate_group_availability:200') &&
        find.text('共通空き時間').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P164 denied unexpected Realtime traffic.');
