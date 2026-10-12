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

const _baseUrl = 'http://127.0.0.1:59222';
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

class _P145Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final availabilityBodies = <String>[];
  String? _findGeneration;
  bool? validationGenerationMatches;
  bool? validationCurrentGenerationMatches;
  bool? validationHasGeneration;
  int? findMemberCount;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59222) {
      throw StateError('P145 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
        throw StateError('P145 blocked an unexpected local API route.');
      }
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final requestBody = request is http.Request ? request.body : '';
    final rpcName = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    if (rpcName == 'find_group_availability') {
      try {
        final sent = jsonDecode(requestBody);
        if (sent is Map && sent['p_member_ids'] is List) {
          findMemberCount = (sent['p_member_ids'] as List).length;
        }
      } on FormatException {
        findMemberCount = null;
      }
    }
    final streamed = await _client.send(request);
    final path = request.url.path;
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(path)?.group(1);
    final bytes = await streamed.stream.toBytes();
    calls.add('${rpc ?? path}:${streamed.statusCode}');
    if ((rpc == 'find_group_availability' ||
            rpc == 'validate_group_availability') &&
        streamed.statusCode == 200) {
      availabilityBodies.add(utf8.decode(bytes));
      try {
        final response = jsonDecode(utf8.decode(bytes));
        if (rpc == 'find_group_availability' && response is Map) {
          _findGeneration = response['generation']?.toString();
        } else if (rpc == 'validate_group_availability' && response is Map) {
          final sent = jsonDecode(requestBody);
          validationGenerationMatches = sent is Map &&
              sent['p_generation']?.toString() == _findGeneration;
          final current = response['generation'];
          validationHasGeneration = current is String;
          validationCurrentGenerationMatches =
              current is String && current == _findGeneration;
        }
      } on FormatException {
        validationGenerationMatches = false;
      }
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

class _P145Overrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P145Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P145Storage extends LocalStorage {
  const _P145Storage();
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

  testWidgets('P145 live group availability reaches API and rendered result',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P145_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final owner = (fixture['users'] as Map<String, dynamic>)['owner']
          as Map<String, dynamic>;
      final groupId = fixture['group_id'] as String;
      final anonKey = fixture['anon_key'] as String;
      final transport = _P145Transport();
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
          sessionStorage: const _P145Storage(),
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
        // Load through the production controller before mounting the route. The
        // screen sees a current, block-projection-complete selection on mount
        // and therefore does not race its own automatic initial load.
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
        await _waitForGroup(tester, providerContainer, groupId, transport);

        await tester.tap(find.byKey(const Key('group-availability-search')));
        await tester.pumpAndSettle();
        expect(find.text('共通空き時間の条件'), findsOneWidget);
        final fixtureUsers = fixture['users'] as Map<String, dynamic>;
        for (final key in ['blocker', 'blocked']) {
          final person = fixtureUsers[key] as Map<String, dynamic>;
          await tester.tap(find.widgetWithText(
              CheckboxListTile, person['display_name'] as String));
          await tester.pump();
        }
        await tester.tap(find.text('検索'));
        await tester.pump();
        final completed =
            await _waitForAvailability(tester, providerContainer, transport);
        debugPrint(
          'P145 diagnostic: calls=${transport.calls.join(',')}; result=${providerContainer.read(groupsControllerProvider).valueOrNull?.availabilityResult != null}; selectedMemberCount=${transport.findMemberCount}; validationValid=${_validationValid(transport)}; requestGenerationMatch=${transport.validationGenerationMatches}; currentGenerationPresent=${transport.validationHasGeneration}; currentGenerationMatch=${transport.validationCurrentGenerationMatches}; membershipChangedError=${providerContainer.read(groupsControllerProvider).valueOrNull?.errorMessage == 'メンバー構成が変わったため、空き時間を再検索してください。'}; resultDialog=${find.text('共通空き時間').evaluate().isNotEmpty};',
        );
        expect(completed, isTrue);
        expect(
          transport.calls,
          contains('find_group_availability:200'),
        );
        expect(
          transport.calls,
          contains('validate_group_availability:200'),
        );
        expect(transport.availabilityBodies, hasLength(2));
        final memberUsers = (fixture['users'] as Map<String, dynamic>)
            .values
            .cast<Map<String, dynamic>>();
        for (final user in memberUsers) {
          expect(transport.availabilityBodies.join(),
              isNot(contains(user['display_name'])));
        }
        expect(find.text('共通空き時間'), findsOneWidget);
        expect(
            container
                .read(groupsControllerProvider)
                .valueOrNull
                ?.availabilityResult,
            isNotNull);
        expect(tester.takeException(), isNull);
        // The production controller expires availability results after one
        // minute; advance test time so its intended timer is not left pending.
        await tester.pump(const Duration(seconds: 60));
        await tester.pump();
        debugPrint(
          'P145: production GoTrue session, group detail route, find_group_availability and validation HTTP 200, rendered result; credentials omitted',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container?.dispose();
        await tester.runAsync(() async {
          try {
            await client.dispose().timeout(const Duration(seconds: 8));
          } on TimeoutException {
            // The transport below is explicitly closed even if Auth disposal
            // does not settle within the bounded widget-test window.
          }
        });
        transport.close();
      }
    }, _P145Overrides());
  }, timeout: const Timeout(Duration(seconds: 90)));
}

bool _validationValid(_P145Transport transport) {
  for (final body in transport.availabilityBodies.reversed) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['valid'] is bool) {
        return decoded['valid'] as bool;
      }
    } on FormatException {
      return false;
    }
  }
  return false;
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

Future<void> _waitForGroup(
  WidgetTester tester,
  ProviderContainer container,
  String groupId,
  _P145Transport transport,
) async {
  final ready = await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      final state = container.read(groupsControllerProvider).valueOrNull;
      if (transport.calls.contains('list_group_members:200') &&
          state?.selected?.id == groupId &&
          state?.members.isNotEmpty == true) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  });
  if (ready != true) {
    debugPrint(
        'P145 group-load diagnostic: calls=${transport.calls.join(',')}');
  }
  expect(ready, isTrue, reason: 'production group route did not load members');
}

Future<bool> _waitForAvailability(
  WidgetTester tester,
  ProviderContainer container,
  _P145Transport transport,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(groupsControllerProvider).valueOrNull;
    if (transport.calls.contains('find_group_availability:200') &&
        transport.calls.contains('validate_group_availability:200') &&
        state?.availabilityResult != null &&
        find.text('共通空き時間').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P145 denied unexpected realtime network traffic.');
