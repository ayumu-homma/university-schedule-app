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

const _baseUrl = 'http://127.0.0.1:59233';
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

class _P165Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final availabilityResponses = <Map<String, dynamic>>[];
  final eventCanaries = <String>[];
  List<String>? finderMemberIds;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59233) {
      throw StateError('P165 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P165 blocked an unexpected local API route.');
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    if (rpc == 'find_group_availability' && request is http.Request) {
      final sent = jsonDecode(request.body);
      if (sent is Map && sent['p_member_ids'] is List) {
        finderMemberIds = (sent['p_member_ids'] as List)
            .map((value) => value.toString())
            .toList(growable: false);
      }
    }
    final streamed = await _client.send(request);
    final bytes = await streamed.stream.toBytes();
    final responseText = utf8.decode(bytes, allowMalformed: true);
    for (final canary in eventCanaries) {
      if (canary.isNotEmpty && responseText.contains(canary)) {
        throw StateError(
            'P165 blocked a private event canary in an API response.');
      }
    }
    if (rpc == 'find_group_availability' && streamed.statusCode == 200) {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        availabilityResponses.add(decoded);
      }
    }
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

class _P165HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P165Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P165Storage extends LocalStorage {
  const _P165Storage();
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
      'P165 mixed PRIVATE and BUSY_ONLY member rows stay redacted through connected availability UI',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P165_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final users = fixture['users'] as Map<String, dynamic>;
      final owner = users['owner'] as Map<String, dynamic>;
      final busyMember = users['busy_member'] as Map<String, dynamic>;
      final privateMember = users['private_member'] as Map<String, dynamic>;
      final groupId = fixture['group_id'] as String;
      final anonKey = fixture['anon_key'] as String;
      final transport = _P165Transport()
        ..eventCanaries
            .addAll((fixture['event_canaries'] as List).cast<String>());
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
          sessionStorage: const _P165Storage(),
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
        await tester.pump(const Duration(milliseconds: 1));
        await _waitForMembers(tester, providerContainer, groupId, transport);

        await tester.tap(find.byKey(const Key('group-availability-search')));
        await tester.pumpAndSettle();
        expect(find.text('共通空き時間の条件'), findsOneWidget);
        await tester.tap(find.text('検索'));
        final completed = await _waitForAvailability(tester, providerContainer);
        expect(completed, isTrue);
        expect(transport.calls, contains('find_group_availability:200'));
        expect(transport.calls, contains('validate_group_availability:200'));
        expect(transport.finderMemberIds, hasLength(3));
        expect(transport.finderMemberIds, contains(owner['id']));
        expect(transport.finderMemberIds, contains(busyMember['id']));
        expect(transport.finderMemberIds, contains(privateMember['id']));
        expect(transport.availabilityResponses, hasLength(1));

        final response = transport.availabilityResponses.single;
        final rows = (response['rows'] as List).cast<Map<String, dynamic>>();
        expect(rows, hasLength(2));
        expect(
            rows.map((row) => row['visibility_level']).toSet(), {'BUSY_ONLY'});
        expect(rows.every((row) => !row.containsKey('member_id')), isTrue);
        expect(
          rows.every((row) =>
              !row.containsKey('title') &&
              !row.containsKey('location') &&
              !row.containsKey('description') &&
              !row.containsKey('event_id') &&
              !row.containsKey('owner_user_id')),
          isTrue,
        );
        expect(
          rows
              .map((row) =>
                  DateTime.parse(row['start_at'] as String).toLocal().hour)
              .toSet(),
          {10, 12},
        );
        final state =
            providerContainer.read(groupsControllerProvider).valueOrNull!;
        expect(
          state.availabilityWindows
              .map((window) => (
                    window.startAt.toLocal().hour,
                    window.startAt.toLocal().minute,
                    window.endAt.toLocal().hour,
                    window.endAt.toLocal().minute,
                  ))
              .toSet(),
          {(9, 0, 10, 0), (11, 0, 12, 0), (13, 0, 18, 0)},
        );
        expect(find.text('共通空き時間'), findsOneWidget);
        expect(find.textContaining(' 09:00 - 10:00'), findsOneWidget);
        expect(find.textContaining(' 11:00 - 12:00'), findsOneWidget);
        expect(find.textContaining(' 13:00 - 18:00'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 60));
        await tester.pump();
        debugPrint(
          'P165: three-member production GoTrue/API/Flutter path; self PRIVATE and capped BUSY_ONLY intervals constrain candidates, third-party PRIVATE interval is absent; canaries omitted',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container?.dispose();
        await tester.runAsync(() async {
          try {
            await client.dispose().timeout(const Duration(seconds: 8));
          } on TimeoutException {
            // The injected transport below is explicitly closed.
          }
        });
        transport.close();
      }
    }, _P165HttpOverrides());
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

Future<void> _waitForMembers(
  WidgetTester tester,
  ProviderContainer container,
  String groupId,
  _P165Transport transport,
) async {
  final ready = await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final state = container.read(groupsControllerProvider).valueOrNull;
      if (transport.calls.contains('list_group_members:200') &&
          state?.selected?.id == groupId &&
          state?.members.length == 3) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  });
  expect(ready, isTrue, reason: 'three synthetic members did not load');
}

Future<bool> _waitForAvailability(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(groupsControllerProvider).valueOrNull;
    if (state?.availabilityResult != null &&
        find.text('共通空き時間').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P165 denied unexpected Realtime traffic.');
