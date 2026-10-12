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

const _baseUrl = 'http://127.0.0.1:59223';

class _P158Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 8
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  String? friendshipsBody;

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59223) {
      throw StateError('P158 rejected a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath && (rpc == null || rpc.group(1) != 'list_friendships')) {
      throw StateError('P158 rejected an unexpected API route.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    final streamed = await _client.send(request);
    final bytes = await streamed.stream.toBytes();
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    calls.add('${rpc ?? request.url.path}:${streamed.statusCode}');
    if (rpc == 'list_friendships' && streamed.statusCode == 200) {
      friendshipsBody = utf8.decode(bytes);
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

class _P158HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P158Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P158Storage extends LocalStorage {
  const _P158Storage();
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

class _P158NativeScope implements NativeScopeBridge {
  const _P158NativeScope(this.scope);
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
    'P158 blocker sees no blocked friend in availability search',
    (tester) => _verifyBlockedAvailabilityRoute(tester,
        viewerKey: 'owner', targetKey: 'friend'),
  );
  testWidgets(
    'P158 blocked user sees no blocker in availability search',
    (tester) => _verifyBlockedAvailabilityRoute(tester,
        viewerKey: 'friend', targetKey: 'owner'),
  );
}

Future<void> _verifyBlockedAvailabilityRoute(
  WidgetTester tester, {
  required String viewerKey,
  required String targetKey,
}) async {
  await HttpOverrides.runWithHttpOverrides(() async {
    final fixturePath = Platform.environment['P158_FLUTTER_FIXTURE_PATH'];
    expect(fixturePath, isNotNull);
    final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
        as Map<String, dynamic>;
    final users = fixture['users'] as Map<String, dynamic>;
    final viewer = users[viewerKey] as Map<String, dynamic>;
    final target = users[targetKey] as Map<String, dynamic>;
    final anonKey = fixture['anon_key'] as String;
    final transport = _P158Transport();
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
        activationToken: 'p158-synthetic-scope',
        generation: 1,
        active: true,
      );
      final authRepository = SupabaseAuthRepository(
        client: client,
        config: config,
        sessionStorage: const _P158Storage(),
      );
      final providerContainer = ProviderContainer(overrides: [
        supabaseClientProvider.overrideWithValue(client),
        appConfigProvider.overrideWithValue(config),
        storageRegionProvider.overrideWithValue(region),
        authRepositoryProvider.overrideWithValue(authRepository),
        nativeScopeBridgeProvider
            .overrideWith((ref) => _P158NativeScope(nativeScope)),
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
      final ready = await _waitForAvailability(
          tester, providerContainer, transport, target['id'] as String);

      expect(ready, isTrue);
      expect(transport.calls, contains('list_friendships:200'));
      expect(transport.friendshipsBody, isNotNull);
      expect(
          transport.friendshipsBody, isNot(contains(target['display_name'])));
      expect(transport.friendshipsBody, contains('ブロック中の利用者'));
      expect(
          transport.calls.where((call) =>
              call.contains('list_friend_terms') ||
              call.contains('get_friend_schedule')),
          isEmpty);
      expect(find.text('選択できる友だちがいません'), findsOneWidget);
      expect(find.text(target['display_name'] as String), findsNothing);
      expect(
          find.byKey(Key('availability-friend-${target['id']}')), findsNothing);
      final searchFinder = find.byKey(const Key('availability-search'));
      await tester.scrollUntilVisible(
        searchFinder,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final search = tester.widget<FilledButton>(searchFinder);
      expect(search.onPressed, isNull);
      expect(
        container
            .read(availabilityControllerProvider)
            .valueOrNull
            ?.acceptedFriends
            .any((friend) => friend.otherUserId == target['id']),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'P158: production GoTrue Auth, list_friendships API and AvailabilityScreen; blocked peer absent from HTTP-visible identity and participant selection; no schedule RPC ($viewerKey)',
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
  }, _P158HttpOverrides());
}

Future<bool> _waitForAvailability(
  WidgetTester tester,
  ProviderContainer container,
  _P158Transport transport,
  String targetId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final state = container.read(availabilityControllerProvider).valueOrNull;
    if (transport.calls.contains('list_friendships:200') &&
        state?.status == AvailabilityStatus.ready &&
        state?.acceptedFriends
                .every((friend) => friend.otherUserId != targetId) ==
            true &&
        find.text('選択できる友だちがいません').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P158 denied unexpected Realtime traffic.');
