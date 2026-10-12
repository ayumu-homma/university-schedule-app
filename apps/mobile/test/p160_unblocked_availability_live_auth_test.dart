import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';
import 'package:university_schedule_mobile/features/availability/application/availability_controller.dart';
import 'package:university_schedule_mobile/features/availability/domain/availability_models.dart';
import 'package:university_schedule_mobile/features/availability/presentation/availability_screen.dart';

const _baseUrl = 'http://127.0.0.1:59227';

class _P160Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 8
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final rpcBodies = <String, List<String>>{};

  static void _validate(Uri uri, [String? method]) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59227) {
      throw StateError('P160 rejected a request outside its loopback bridge.');
    }
    final authMethod = switch (uri.path) {
      '/auth/v1/token' => 'POST',
      '/auth/v1/user' => 'GET',
      _ => null,
    };
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (authMethod != null && (method == null || method == authMethod)) return;
    if (rpc != null &&
        (method == null || method == 'POST') &&
        const {'list_friendships', 'list_friend_terms', 'get_friend_schedule'}
            .contains(rpc.group(1))) {
      return;
    }
    throw StateError('P160 rejected an unexpected API route.');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url, request.method);
    final streamed = await _client.send(request);
    final bytes = await streamed.stream.toBytes();
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    final route = rpc ?? request.url.path;
    calls.add('$route:${streamed.statusCode}');
    if (rpc != null) {
      rpcBodies.putIfAbsent(rpc, () => []).add(utf8.decode(bytes));
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

class _P160HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P160Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P160Storage extends LocalStorage {
  const _P160Storage();
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

class _P160NativeScope implements NativeScopeBridge {
  const _P160NativeScope(this.scope);
  final NativeScopeState scope;
  @override
  bool get isSupported => true;
  @override
  Future<NativeScopeState> current() async => scope;
  @override
  Future<NativeScopeState> activate(
          StorageRegion region, String ownerUserId) async =>
      scope;
  @override
  Future<NativeScopeState> deactivate() async =>
      const NativeScopeState.inactive();
  @override
  Future<NativeScopeState> prepare(StorageRegion region) async => scope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P160 accepted friend schedule completes the live availability route',
    _verifyUnblockedAvailabilityRoute,
  );
}

Future<void> _verifyUnblockedAvailabilityRoute(WidgetTester tester) async {
  await HttpOverrides.runWithHttpOverrides(() async {
    final fixturePath = Platform.environment['P160_FLUTTER_FIXTURE_PATH'];
    expect(fixturePath, isNotNull);
    final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
        as Map<String, dynamic>;
    final users = fixture['users'] as Map<String, dynamic>;
    final viewer = users['owner'] as Map<String, dynamic>;
    final friend = users['friend'] as Map<String, dynamic>;
    final anonKey = fixture['anon_key'] as String;
    final transport = _P160Transport();
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
      final region = StorageRegion.fromConfig(config);
      final nativeScope = NativeScopeState(
        regionId: region.id,
        ownerHash:
            sha256.convert(utf8.encode(viewer['id'] as String)).toString(),
        activationToken: 'p160-synthetic-scope',
        generation: 1,
        active: true,
      );
      final authRepository = SupabaseAuthRepository(
        client: client,
        config: config,
        sessionStorage: const _P160Storage(),
      );
      final providerContainer = ProviderContainer(overrides: [
        supabaseClientProvider.overrideWithValue(client),
        appConfigProvider.overrideWithValue(config),
        storageRegionProvider.overrideWithValue(region),
        authRepositoryProvider.overrideWithValue(authRepository),
        nativeScopeBridgeProvider
            .overrideWith((ref) => _P160NativeScope(nativeScope)),
      ]);
      container = providerContainer;
      final authSubscription = providerContainer.listen(
        currentAuthSessionProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(authSubscription.close);
      final sessionReady = await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline)) {
          if (providerContainer.read(currentAuthSessionProvider)?.userId ==
              viewer['id']) {
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return false;
      });
      expect(sessionReady, isTrue,
          reason: 'production Auth stream did not publish the viewer');

      await tester.pumpWidget(UncontrolledProviderScope(
        container: providerContainer,
        child: const MaterialApp(home: AvailabilityScreen()),
      ));
      final friendsReady = await _waitForFriend(
          tester, providerContainer, transport, friend['id'] as String);
      expect(friendsReady, isTrue);
      expect(find.text(friend['display_name'] as String), findsOneWidget);
      expect(
        transport.calls.where((call) => call == 'list_friendships:200').length,
        greaterThanOrEqualTo(1),
      );

      providerContainer
          .read(availabilityControllerProvider.notifier)
          .setDate(DateTime.utc(2026, 10, 14));
      final friendFinder =
          find.byKey(Key('availability-friend-${friend['id']}'));
      await tester.scrollUntilVisible(
        friendFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(friendFinder);
      await tester.pumpAndSettle();
      final searchFinder = find.byKey(const Key('availability-search'));
      await tester.scrollUntilVisible(
        searchFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(searchFinder);

      final completed = await _waitForSearch(
        tester,
        providerContainer,
        transport,
      );
      expect(completed, isTrue);
      expect(container.read(availabilityControllerProvider).valueOrNull?.status,
          AvailabilityStatus.success);
      expect(transport.calls, contains('list_friend_terms:200'));
      expect(transport.calls, contains('get_friend_schedule:200'));
      expect(
          transport.calls
              .where((call) => call == 'list_friend_terms:200')
              .length,
          2);
      expect(
          transport.calls
              .where((call) => call == 'get_friend_schedule:200')
              .length,
          2);
      final friendScheduleBodies = transport.rpcBodies['get_friend_schedule']!;
      expect(friendScheduleBodies.join('\n'), contains(fixture['event_title']));
      expect(find.text('09:00 〜 10:00'), findsOneWidget);
      expect(find.text('11:00 〜 18:00'), findsOneWidget);
      expect(
          find.textContaining(fixture['event_title'] as String), findsNothing);
      expect(find.textContaining(fixture['event_location'] as String),
          findsNothing);
      expect(find.textContaining(fixture['event_description'] as String),
          findsNothing);
      expect(tester.takeException(), isNull);
      debugPrint(
        'P160: production GoTrue Auth, list_friendships/list_friend_terms/get_friend_schedule RPCs and AvailabilityScreen rendered the expected free windows',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container?.dispose();
      await tester.runAsync(() async {
        try {
          await client.dispose().timeout(const Duration(seconds: 8));
        } on TimeoutException {
          // The strict HTTP transport is closed below.
        }
      });
      transport.close();
    }
  }, _P160HttpOverrides());
}

Future<bool> _waitForFriend(
  WidgetTester tester,
  ProviderContainer container,
  _P160Transport transport,
  String friendId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(availabilityControllerProvider).valueOrNull;
    if (transport.calls.contains('list_friendships:200') &&
        state?.status == AvailabilityStatus.ready &&
        state?.acceptedFriends.any((value) => value.otherUserId == friendId) ==
            true) {
      return true;
    }
  }
  return false;
}

Future<bool> _waitForSearch(
  WidgetTester tester,
  ProviderContainer container,
  _P160Transport transport,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(availabilityControllerProvider).valueOrNull;
    if (state?.status == AvailabilityStatus.success &&
        transport.calls
                .where((call) => call == 'get_friend_schedule:200')
                .length ==
            2) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P160 denied unexpected Realtime traffic.');
