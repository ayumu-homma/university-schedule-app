import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/features/today/domain/today_briefing.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_screen.dart';

const _baseUrl = 'http://127.0.0.1:59230';
const _allowedRpc = {'list_my_groups', 'list_group_events'};

class _P156Transport extends http.BaseClient {
  final _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = 8
    ..findProxy = (uri) {
      _validate(uri);
      return 'DIRECT';
    });
  final calls = <String>[];
  final responses = <String, List<String>>{};

  static void _validate(Uri uri) {
    if (uri.scheme != 'http' || uri.host != '127.0.0.1' || uri.port != 59230) {
      throw StateError('P156 blocked a request outside its loopback bridge.');
    }
    final authPath = uri.path == '/auth/v1/token' ||
        uri.path == '/auth/v1/user' ||
        uri.path == '/auth/v1/logout';
    if (authPath &&
        (uri.path != '/auth/v1/token' ||
            uri.query == 'grant_type=password' ||
            uri.query == 'grant_type=refresh_token')) {
      return;
    }
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$').firstMatch(uri.path);
    if (rpc == null || !_allowedRpc.contains(rpc.group(1))) {
      throw StateError('P156 blocked an unexpected local API route.');
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _validate(request.url);
    if (request.url.path == '/auth/v1/logout' && request.method != 'POST') {
      throw StateError('P156 denied an unexpected Auth method.');
    }
    final rpc = RegExp(r'^/rest/v1/rpc/([a-z_]+)$')
        .firstMatch(request.url.path)
        ?.group(1);
    final response = await _client.send(request);
    final bytes = await response.stream.toBytes();
    final body = utf8.decode(bytes, allowMalformed: true);
    if (rpc != null) responses.putIfAbsent(rpc, () => []).add(body);
    calls.add('${rpc ?? request.url.path}:${response.statusCode}');
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _client.close();
    super.close();
  }
}

class _P156HttpOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri uri, Map<String, String>? environment) {
    _P156Transport._validate(uri);
    return 'DIRECT';
  }
}

class _P156Storage extends LocalStorage {
  const _P156Storage();
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
      'Today renders current group events from live Auth/API and clears on account switch',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final fixturePath = Platform.environment['P156_FLUTTER_FIXTURE_PATH'];
      expect(fixturePath, isNotNull);
      final fixture = jsonDecode(File(fixturePath!).readAsStringSync())
          as Map<String, dynamic>;
      final users = fixture['users'] as Map<String, dynamic>;
      final member = users['member'] as Map<String, dynamic>;
      final outsider = users['outsider'] as Map<String, dynamic>;
      final anonKey = fixture['anon_key'] as String;
      final title = fixture['today_title'] as String;
      final location = fixture['today_location'] as String;
      final description = fixture['today_description'] as String;
      final tomorrowTitle = fixture['tomorrow_title'] as String;
      final eventId = fixture['today_event_id'] as String;
      final transport = _P156Transport();
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
      GoRouter? router;
      try {
        final signedIn = await tester.runAsync(() => client.auth
            .signInWithPassword(
                email: member['email'] as String,
                password: member['password'] as String));
        expect(signedIn?.user?.id, member['id']);
        debugPrint('P156 checkpoint: member sign-in completed');

        final config = AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: _baseUrl,
          legacySupabaseAnonKey: anonKey,
        );
        final authRepository = SupabaseAuthRepository(
          client: client,
          config: config,
          sessionStorage: const _P156Storage(),
        );
        final providerContainer = ProviderContainer(overrides: [
          supabaseClientProvider.overrideWithValue(client),
          appConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(authRepository),
          activeScheduleContextProvider
              .overrideWithValue(const ActiveScheduleContext(
            ownerUserId: 'synthetic-local-owner',
            universityId: 'synthetic-university',
            termId: 'synthetic-term',
            academicYear: 2026,
            primaryCalendarId: 'synthetic-calendar',
          )),
          todayBriefingProvider.overrideWithValue(AsyncData(_briefing)),
        ]);
        container = providerContainer;
        final authSubscription = providerContainer.listen(
          currentAuthSessionProvider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(authSubscription.close);
        await _waitForViewer(tester, providerContainer, member['id'] as String);
        debugPrint('P156 checkpoint: member Auth stream completed');

        router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, __) => const TodayScreen()),
          GoRoute(
            path: '/group/:id',
            builder: (_, state) => Scaffold(
              body: Text('group:${state.pathParameters['id']}'),
            ),
          ),
        ]);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: providerContainer,
          child: MaterialApp.router(routerConfig: router),
        ));
        debugPrint('P156 checkpoint: TodayScreen mounted');
        await tester.scrollUntilVisible(
          find.text('今日のグループ予定'),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        debugPrint('P156 checkpoint: group section visible');
        expect(await _waitForTodayEvent(tester, transport, eventId), isTrue);
        debugPrint('P156 checkpoint: live Today event rendered');
        final bodies =
            (transport.responses['list_group_events'] ?? []).join('\n');
        expect(bodies, contains(title));
        expect(bodies, contains(location));
        expect(bodies, contains(description));
        expect(bodies, contains(tomorrowTitle));
        expect(find.text(title), findsOneWidget);
        expect(find.text(tomorrowTitle), findsNothing);
        expect(find.text(location), findsNothing);
        expect(find.text(description), findsNothing);
        expect(transport.calls, contains('list_my_groups:200'));
        expect(transport.calls, contains('list_group_events:200'));

        await tester.runAsync(
            () => providerContainer.read(authRepositoryProvider).signOut());
        await _waitForViewer(tester, providerContainer, null);
        await tester.pump();
        debugPrint('P156 checkpoint: member signed out');
        final switched = await tester.runAsync(() => client.auth
            .signInWithPassword(
                email: outsider['email'] as String,
                password: outsider['password'] as String));
        expect(switched?.user?.id, outsider['id']);
        debugPrint('P156 checkpoint: outsider sign-in completed');
        await _waitForViewer(
            tester, providerContainer, outsider['id'] as String);
        debugPrint('P156 checkpoint: outsider Auth stream completed');
        expect(await _waitForEmptyToday(tester, transport), isTrue);
        debugPrint('P156 checkpoint: prior event cleared');
        expect(find.text(title), findsNothing);
        expect(
            transport.calls
                .where((call) => call == 'list_my_groups:200')
                .length,
            2);
        expect(
            transport.calls
                .where((call) => call == 'list_group_events:200')
                .length,
            1);
        expect(tester.takeException(), isNull);
        debugPrint(
          'P156: real GoTrue sessions and Auth stream; TodayScreen production route used actual group list/event RPCs; only current noncancelled event rendered; prior result cleared after account switch; credentials omitted',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        router?.dispose();
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
    }, _P156HttpOverrides());
  }, timeout: const Timeout(Duration(seconds: 90)));
}

final _briefing = TodayBriefing(
  generatedAt: DateTime.utc(2026, 10, 14, 2),
  dayStart: DateTime.utc(2026, 10, 13, 15),
  dayEnd: DateTime.utc(2026, 10, 14, 15),
  courses: const [],
  currentCourse: null,
  nextCourse: null,
  dueTodayAssignments: const [],
  overdueAssignments: const [],
  exams: const [],
  personalEvents: const [],
  routines: const [],
  otherCalendarOccurrences: const [],
  calendarOccurrences: const [],
);

Future<void> _waitForViewer(
  WidgetTester tester,
  ProviderContainer container,
  String? expected,
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

Future<bool> _waitForTodayEvent(
  WidgetTester tester,
  _P156Transport transport,
  String eventId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    final key = find.byKey(Key('today-group-event-$eventId'));
    if (transport.calls.contains('list_group_events:200') &&
        key.evaluate().isNotEmpty) {
      await tester.ensureVisible(key);
      return true;
    }
  }
  return false;
}

Future<bool> _waitForEmptyToday(
  WidgetTester tester,
  _P156Transport transport,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 10));
    if (transport.calls.where((call) => call == 'list_my_groups:200').length >=
            2 &&
        find.text('今日のグループ予定はありません。').evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

Never _denyRealtime(String url, Map<String, String> headers) =>
    throw StateError('P156 denied unexpected Realtime traffic.');
