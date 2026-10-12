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
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

const _baseUrl = 'http://127.0.0.1:59228';
const _allowedRpc = {
  'list_my_groups',
  'get_group',
  'list_group_members',
  'list_group_member_blocked_users',
  'list_group_events',
  'list_group_invites',
  'get_group_event_ugc',
  'validate_group_event_ugc',
};

class _P153Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final responses = <String, List<String>>{};

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59228) {
      throw StateError('P153 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    if (authPath &&
        (uri.path != '/auth/v1/token' ||
            uri.query == 'grant_type=password' ||
            uri.query == 'grant_type=refresh_token')) {
      return;
    }
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
      throw StateError('P153 blocked an unexpected local API route.');
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
    final responseText = utf8.decode(bytes, allowMalformed: true);
    if (rpc != null) responses.putIfAbsent(rpc, () => []).add(responseText);
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

class _P153HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P153Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P153Storage extends LocalStorage {
  const _P153Storage();
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
      'P153 PRIVATE group event is shown to its member in the connected route',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P153_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final viewer = fixture['users']['member'] as Map<String, dynamic>;
      final groupId = fixture['group_id'] as String;
      final eventId = fixture['event_id'] as String;
      final anonKey = fixture['anon_key'] as String;
      final title = fixture['event_title'] as String;
      final location = fixture['event_location'] as String;
      final description = fixture['event_description'] as String;
      final transport = _P153Transport();
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
          sessionStorage: const _P153Storage(),
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

        await tester.pumpWidget(UncontrolledProviderScope(
          container: providerContainer,
          child: MaterialApp(home: GroupDetailScreen(groupId: groupId)),
        ));
        final loaded = await _waitForEvent(tester, transport, eventId);
        expect(loaded, isTrue);
        expect(transport.calls, contains('list_group_events:200'));
        final eventBodies = transport.responses['list_group_events'] ?? [];
        expect(eventBodies.join('\n'), contains(title));
        expect(eventBodies.join('\n'), contains(location));
        expect(eventBodies.join('\n'), contains(description));
        expect(find.text(title), findsOneWidget);
        expect(find.byKey(Key('group-event-$eventId')), findsOneWidget);

        await tester.tap(find.byKey(Key('group-event-$eventId')));
        expect(await _waitForRpc(tester, transport, 'get_group_event_ugc'),
            isTrue);
        expect(transport.calls, contains('get_group_event_ugc:200'));
        expect(await _waitForRpc(tester, transport, 'validate_group_event_ugc'),
            isTrue);
        expect(transport.calls, contains('validate_group_event_ugc:200'));
        await tester.pumpAndSettle();
        expect(find.text('場所: $location'), findsOneWidget);
        expect(find.text(description), findsOneWidget);
        expect(tester.takeException(), isNull);
        debugPrint(
          'P153: real local GoTrue session; production GroupDetailScreen/repository/controller; PRIVATE group event list details and UGC validation returned HTTP 200; member UI rendered title/location/description; credentials omitted',
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
    }, _P153HttpOverrides());
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

Future<bool> _waitForEvent(
  WidgetTester tester,
  _P153Transport transport,
  String eventId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    if (transport.calls.contains('list_group_events:200') &&
        find.byKey(Key('group-event-$eventId')).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Future<bool> _waitForRpc(
  WidgetTester tester,
  _P153Transport transport,
  String rpc,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    if (transport.calls.any((call) => call.startsWith('$rpc:'))) return true;
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P153 denied unexpected Realtime traffic.');
