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
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';

const _baseUrl = 'http://127.0.0.1:59220';
const _expectedRpc = {
  'list_my_groups',
  'get_group',
  'list_group_members',
  'list_group_member_blocked_users',
  'list_group_events',
};

class _P142Client extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 12
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final memberResponses = <String>[];

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59220) {
      throw StateError('P142 blocked a request outside its loopback bridge.');
    }
    final authPath =
        uri.path == '/auth/v1/token' || uri.path == '/auth/v1/user';
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (!authPath ||
        uri.path == '/auth/v1/token' &&
            uri.query != 'grant_type=password' &&
            uri.query != 'grant_type=refresh_token') {
      if (rpc == null || !_expectedRpc.contains(rpc.group(1))) {
        throw StateError('P142 blocked an unexpected local API route.');
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
      memberResponses.add(utf8.decode(bytes));
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

class _P142Overrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P142Client._validate(uri);
    return 'DIRECT';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P142 P61 bidirectional blocked-member masking through GoTrue and Flutter',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final fixturePath = Platform.environment['P142_FLUTTER_FIXTURE_PATH'];
        expect(fixturePath, isNotNull);
        final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
            as Map<String, dynamic>;
        final users = fixture['users'] as Map<String, dynamic>;
        final blocker = users['blocker'] as Map<String, dynamic>;
        final blocked = users['blocked'] as Map<String, dynamic>;
        final groupId = fixture['group_id'] as String;
        final transport = _P142Client();
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
          expect(transport.calls, contains('/auth/v1/token:200'));
          debugPrint('P142:GoTrue-login-complete');

          final authSessionState = StateProvider<AppAuthSession?>(
            (ref) => AppAuthSession(userId: signedIn!.user!.id),
          );
          final providerContainer = ProviderContainer(overrides: [
            supabaseClientProvider.overrideWithValue(client),
            appConfigProvider.overrideWithValue(AppConfig.validated(
              environment: 'local',
              demoMode: false,
              supabaseUrl: _baseUrl,
              legacySupabaseAnonKey: fixture['anon_key'] as String,
            )),
            currentAuthSessionProvider.overrideWith(
              (ref) => ref.watch(authSessionState),
            ),
            friendsControllerProvider.overrideWith(
              _P142EmptyFriendsController.new,
            ),
          ]);
          container = providerContainer;
          await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.future)
                .timeout(const Duration(seconds: 15)),
          );
          final blockerOpened = await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.notifier)
                .open(groupId)
                .timeout(const Duration(seconds: 20)),
          );
          final blockerState =
              providerContainer.read(groupsControllerProvider).valueOrNull;
          debugPrint(
              'P142:first-open=$blockerOpened;loading=${blockerState?.loading};selected=${blockerState?.selected?.id == groupId};projection=${blockerState?.blockedMemberStatusLoaded};viewer=${blockerState?.blockedMemberStatusViewerUserId == blocker['id']};error=${blockerState?.errorMessage != null}');
          expect(blockerOpened, isTrue);
          expect(blockerState?.blockedMemberStatusViewerUserId, blocker['id']);
          expect(blockerState?.blockedMemberStatusLoaded, isTrue);
          expect(blockerState?.selected?.id, groupId);
          debugPrint('P142:widget-mount-start');
          await tester.pumpWidget(UncontrolledProviderScope(
            container: providerContainer,
            child: MaterialApp(home: GroupDetailScreen(groupId: groupId)),
          ));
          debugPrint('P142:widget-mount-complete');

          expect(
              transport.calls.where((call) =>
                  call.endsWith(':200') &&
                  call.startsWith('list_group_member_blocked_users')),
              hasLength(1));
          expect(transport.memberResponses, hasLength(1));
          expect(transport.memberResponses.single,
              contains(blocked['display_name']));
          expect(find.text(blocker['display_name'] as String), findsOneWidget);
          expect(find.text(blocked['display_name'] as String), findsNothing);
          expect(find.text('ブロック中のメンバー'), findsOneWidget);
          expect(find.text('member'), findsNWidgets(2));
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          final beforeSwitchCalls = transport.calls.length;
          final switched = await tester.runAsync(
            () => client.auth.signInWithPassword(
              email: blocked['email'] as String,
              password: blocked['password'] as String,
            ),
          );
          expect(switched?.user?.id, blocked['id']);
          providerContainer.read(authSessionState.notifier).state =
              AppAuthSession(userId: switched!.user!.id);
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.future)
                .timeout(const Duration(seconds: 15)),
          );
          final reverseOpened = await tester.runAsync(
            () => providerContainer
                .read(groupsControllerProvider.notifier)
                .open(groupId)
                .timeout(const Duration(seconds: 20)),
          );
          expect(reverseOpened, isTrue);
          final reverseState =
              providerContainer.read(groupsControllerProvider).valueOrNull;
          expect(reverseState?.blockedMemberStatusViewerUserId, blocked['id']);
          expect(reverseState?.blockedMemberStatusLoaded, isTrue);
          expect(reverseState?.selected?.id, groupId);

          await tester.pumpWidget(UncontrolledProviderScope(
            container: providerContainer,
            child: MaterialApp(home: GroupDetailScreen(groupId: groupId)),
          ));
          await tester.pump();

          expect(transport.calls.skip(beforeSwitchCalls),
              contains('/auth/v1/token:200'));
          expect(
              transport.calls.skip(beforeSwitchCalls).where((call) =>
                  call.startsWith('list_group_member_blocked_users:200')),
              hasLength(1));
          expect(transport.memberResponses, hasLength(2));
          expect(transport.memberResponses.last,
              contains(blocker['display_name']));
          expect(find.text(blocked['display_name'] as String), findsOneWidget);
          expect(find.text(blocker['display_name'] as String), findsNothing);
          expect(find.text('ブロック中のメンバー'), findsOneWidget);
          expect(find.text('member'), findsNWidgets(2));
          expect(tester.takeException(), isNull);

          debugPrint(
              'P142:GoTrue token=2x200;group RPC=${transport.calls.where((c) => c.startsWith('get_group:') || c.startsWith('list_group_members:') || c.startsWith('list_group_member_blocked_users:') || c.startsWith('list_group_events:')).join(',')};both directions masked;second principal reloaded and rendered scoped projection');
        } finally {
          debugPrint('P142:cleanup-unmount-start');
          await tester.pumpWidget(const SizedBox.shrink());
          debugPrint('P142:cleanup-unmount-complete');
          await tester.pump();
          debugPrint('P142:cleanup-pump-complete');
          container?.dispose();
          debugPrint('P142:cleanup-container-complete');
          await tester.pump(const Duration(milliseconds: 1));
          debugPrint('P142:cleanup-container-refresh-complete');
          final clientDisposed = await tester.runAsync(() async {
            try {
              await client.dispose().timeout(const Duration(seconds: 8));
              return true;
            } on TimeoutException {
              return false;
            }
          });
          debugPrint(clientDisposed == true
              ? 'P142:cleanup-client-complete'
              : 'P142:cleanup-client-dispose-timeout;injected-transport-closed');
          transport.close();
          debugPrint('P142:cleanup-transport-complete');
        }
      }, _P142Overrides());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

class _P142EmptyFriendsController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState();
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P142 REST-only test blocked Realtime.');
