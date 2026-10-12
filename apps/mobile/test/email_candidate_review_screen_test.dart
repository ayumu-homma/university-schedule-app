import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/deep_link_controller.dart';
import 'package:university_schedule_mobile/app/navigation_guard.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_update_repository.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_timezone.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_candidate_inbox_screen.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_candidate_review_screen.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_import_settings_screen.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_review_labels.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  test('email date formatters render the requested IANA civil clock', () {
    final instant = DateTime.utc(2030, 1, 1, 15, 5);

    expect(formatEmailDateTime(instant), '2030/01/02 00:05');
    expect(formatEmailInputDateTime(instant), '2030-01-02 00:05');
    expect(
      formatEmailDateTime(instant, timeZone: 'America/New_York'),
      '2030/01/01 10:05',
    );
    expect(
      formatEmailInputDateTime(instant, timeZone: 'America/New_York'),
      '2030-01-01 10:05',
    );
  });

  test('email civil parser rejects DST gaps and preserves repeated instants',
      () {
    expect(
      parseEmailCivilDateTime(
        '2026-03-08 02:30',
        timeZone: 'America/New_York',
      ),
      isNull,
    );
    final secondOccurrence = DateTime.utc(2026, 11, 1, 6, 30);
    expect(
      parseEmailCivilDateTime(
        '2026-11-01 01:30',
        timeZone: 'America/New_York',
        referenceInstant: secondOccurrence,
      ),
      secondOccurrence,
    );
  });

  testWidgets('flag-off screen is inert and does not read email boundaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
          currentAuthSessionProvider.overrideWithValue(_session),
          emailReviewStoreProvider.overrideWith((ref) {
            throw StateError('flag-off UI must not construct the store');
          }),
          emailReviewRemoteActionsProvider.overrideWith((ref) {
            throw StateError('flag-off UI must not construct remote actions');
          }),
        ],
        child: const MaterialApp(home: EmailImportSettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('メール取込は現在利用できません'), findsOneWidget);
    expect(find.byKey(const Key('email-connect-button')), findsNothing);
  });

  testWidgets('inbox exposes loading, empty and offline states safely', (
    tester,
  ) async {
    final loadingStore = _FakeEmailReviewStore(holdCandidates: true);
    await tester.pumpWidget(
      _Harness(store: loadingStore, online: false).widget('/email-import'),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('オフラインです'), findsOneWidget);

    await tester.pumpWidget(
      _Harness(store: _FakeEmailReviewStore(), online: false)
          .widget('/email-import'),
    );
    await tester.pumpAndSettle();
    expect(find.text('確認待ちの候補はありません'), findsOneWidget);
    expect(find.text('オフラインです'), findsOneWidget);
    final refresh = tester.widget<IconButton>(
      find.byKey(const Key('email-inbox-refresh-button')),
    );
    expect(refresh.onPressed, isNull);
  });

  testWidgets(
      'link hint with unreachable backend renders the real offline banner',
      (tester) async {
    final connectivity = _FakeEmailConnectivityHintSource();
    addTearDown(connectivity.close);

    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(),
        connectivityHintSource: connectivity,
        backendReachabilityProbe: () async => false,
      ).widget('/email-import'),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('email-offline-banner')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('email-inbox-refresh-button')),
          )
          .onPressed,
      isNull,
    );
  });

  test('default backend probe times out and closes a fresh client per attempt',
      () async {
    final clients = <_TrackingHttpClient>[];
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.validated(
            environment: 'test',
            demoMode: true,
            supabaseUrl: 'http://127.0.0.1:54321',
          ),
        ),
        emailBackendReachabilityTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 10),
        ),
        emailBackendReachabilityHttpClientFactoryProvider.overrideWithValue(
          () {
            final client = _TrackingHttpClient();
            clients.add(client);
            return client;
          },
        ),
      ],
    );
    final probe = container.read(emailBackendReachabilityProbeProvider);

    await expectLater(probe(), throwsA(isA<TimeoutException>()));
    await expectLater(probe(), throwsA(isA<TimeoutException>()));

    expect(clients, hasLength(2));
    expect(clients.every((client) => client.isClosed), isTrue);
    expect(
      clients.map((client) => client.requestedUri?.path),
      everyElement('/auth/v1/health'),
    );
    container.dispose();
  });

  test('backend probe errors and timeouts fail closed', () async {
    final probes = <EmailBackendReachabilityProbe>[
      () async => throw StateError('private backend failure'),
      () => Completer<bool>().future,
    ];

    for (final probe in probes) {
      final connectivity = _FakeEmailConnectivityHintSource();
      final container = ProviderContainer(
        overrides: [
          emailConnectivityHintSourceProvider.overrideWithValue(connectivity),
          emailBackendReachabilityProbeProvider.overrideWithValue(probe),
          emailBackendReachabilityTimeoutProvider.overrideWithValue(
            const Duration(milliseconds: 10),
          ),
        ],
      );
      expect(
        await container
            .read(emailNetworkAvailableProvider.future)
            .timeout(const Duration(seconds: 1)),
        isFalse,
      );
      container.dispose();
      await connectivity.close();
    }
  });

  test('production backend retry delays follow the bounded schedule', () {
    final container = ProviderContainer();
    final retryDelay =
        container.read(emailBackendReachabilityRetryDelayProvider);

    expect(
      List<Duration>.generate(7, retryDelay),
      const [
        Duration(seconds: 2),
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 5),
        Duration(minutes: 5),
      ],
    );
    container.dispose();
  });

  test('backend recovery retries without a new connectivity event', () async {
    final connectivity = _FakeEmailConnectivityHintSource();
    var probeCalls = 0;
    final container = ProviderContainer(
      overrides: [
        emailConnectivityHintSourceProvider.overrideWithValue(connectivity),
        emailBackendReachabilityProbeProvider.overrideWithValue(() async {
          probeCalls++;
          return probeCalls > 1;
        }),
        emailBackendReachabilityRetryDelayProvider.overrideWithValue(
          (_) => const Duration(milliseconds: 5),
        ),
      ],
    );
    final subscription = container.listen(
      emailNetworkAvailableProvider,
      (_, __) {},
      fireImmediately: true,
    );

    await _waitForEmailNetworkValue(container, false);
    await _waitForEmailNetworkValue(container, true);

    expect(probeCalls, 2);
    subscription.close();
    container.dispose();
    await connectivity.close();
  });

  test('none and disposal stop scheduled backend retries', () async {
    final connectivity = _FakeEmailConnectivityHintSource();
    var probeCalls = 0;
    var retryDelayCalls = 0;
    final container = ProviderContainer(
      overrides: [
        emailConnectivityHintSourceProvider.overrideWithValue(connectivity),
        emailBackendReachabilityProbeProvider.overrideWithValue(() async {
          probeCalls++;
          return false;
        }),
        emailBackendReachabilityRetryDelayProvider.overrideWithValue((_) {
          retryDelayCalls++;
          return const Duration(milliseconds: 20);
        }),
      ],
    );
    final subscription = container.listen(
      emailNetworkAvailableProvider,
      (_, __) {},
      fireImmediately: true,
    );

    await _waitForEmailNetworkValue(container, false);
    expect(retryDelayCalls, 1);
    connectivity.add(const [ConnectivityResult.none]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(probeCalls, 1);

    connectivity.add(const [ConnectivityResult.wifi]);
    await _waitForTestCondition(
      () => retryDelayCalls == 2,
      label: 'the second backend retry to be scheduled',
    );
    expect(probeCalls, 2);
    subscription.close();
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(probeCalls, 2);
    await connectivity.close();
  });

  test('a stale successful probe cannot overwrite a newer offline result',
      () async {
    final initialCheck = Completer<List<ConnectivityResult>>();
    final staleProbe = Completer<bool>();
    final connectivity = _FakeEmailConnectivityHintSource(
      initialCheck: initialCheck.future,
    );
    var probeCalls = 0;
    final container = ProviderContainer(
      overrides: [
        emailConnectivityHintSourceProvider.overrideWithValue(connectivity),
        emailBackendReachabilityProbeProvider.overrideWithValue(() {
          probeCalls++;
          return staleProbe.future;
        }),
      ],
    );
    final subscription = container.listen(
      emailNetworkAvailableProvider,
      (_, __) {},
      fireImmediately: true,
    );

    connectivity.add(const [ConnectivityResult.wifi]);
    await _waitForTestCondition(
      () => probeCalls == 1,
      label: 'the first backend probe to start',
    );
    connectivity.add(const [ConnectivityResult.none]);
    await _waitForEmailNetworkValue(container, false);

    staleProbe.complete(true);
    initialCheck.complete(const [ConnectivityResult.wifi]);
    await _drainTestMicrotasks();

    expect(container.read(emailNetworkAvailableProvider).valueOrNull, isFalse);
    expect(probeCalls, 1);
    subscription.close();
    container.dispose();
    await connectivity.close();
  });

  testWidgets('inbox stream errors never expose private diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(
          candidateError: StateError('private provider payload'),
        ),
      ).widget('/email-import'),
    );
    await tester.pumpAndSettle();

    expect(find.text('メール候補を読み込めませんでした'), findsOneWidget);
    expect(find.textContaining('private provider payload'), findsNothing);
  });

  testWidgets('connection states show reauth, rate limit and timeout messages',
      (
    tester,
  ) async {
    for (final testCase in [
      (
        connection: _connection(EmailConnectionStatus.reauthRequired),
        message: 'Gmail の認証が切れています。再接続してください。',
      ),
      (
        connection: _connection(
          EmailConnectionStatus.rateLimited,
          retryAfter: DateTime.utc(2030, 4, 1, 1),
        ),
        message: 'しばらく待って再試行',
      ),
      (
        connection: _connection(
          EmailConnectionStatus.failed,
          error: EmailErrorCategory.timeout,
        ),
        message: '通信が時間内に完了しませんでした。もう一度お試しください。',
      ),
    ]) {
      await tester.pumpWidget(
        _Harness(
          store: _FakeEmailReviewStore(
            connections: [testCase.connection],
          ),
        ).widget('/settings/email-import'),
      );
      await tester.pumpAndSettle();
      expect(find.text(testCase.message), findsWidgets);
      switch (testCase.connection.status) {
        case EmailConnectionStatus.reauthRequired:
          expect(find.byKey(const Key('email-reauth-button')), findsOneWidget);
        case EmailConnectionStatus.rateLimited:
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('email-manual-refresh-button')),
                )
                .onPressed,
            isNull,
          );
        case EmailConnectionStatus.failed:
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('email-manual-refresh-button')),
                )
                .onPressed,
            isNotNull,
          );
        case EmailConnectionStatus.disconnected ||
              EmailConnectionStatus.connecting ||
              EmailConnectionStatus.connected ||
              EmailConnectionStatus.disconnecting:
          fail('Unexpected connection state in test case.');
      }
    }
  });

  testWidgets('connecting state explains OAuth handoff and checks safe status',
      (tester) async {
    final remote = _FakeRemoteActions();
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(
          connections: [_connection(EmailConnectionStatus.connecting)],
        ),
        remote: remote,
      ).widget('/settings/email-import'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('email-authorization-handoff-message')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('email-authorization-check-button')),
    );
    await tester.pumpAndSettle();

    expect(remote.authorizationChecks, 1);
    expect(find.text('Gmail に接続しました'), findsOneWidget);
  });

  testWidgets(
      'callback check forwards exact UUID correlation once and strips it',
      (tester) async {
    const requestedConnectionId = '22222222-2222-4222-8222-222222222222';
    const callbackCorrelationId = '33333333-3333-4333-8333-333333333333';
    final remote = _CorrelatedFakeRemoteActions();
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(
          connections: [
            _connection(
              EmailConnectionStatus.connecting,
              id: requestedConnectionId,
            ),
          ],
        ),
        remote: remote,
      ).widget(
        '/settings/email-import?oauth_connection_id='
        '$requestedConnectionId&oauth_correlation_id=$callbackCorrelationId',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('email-authorization-check-button')),
    );
    await tester.pumpAndSettle();

    expect(remote.correlatedChecks, 1);
    expect(remote.requestedConnectionId, requestedConnectionId);
    expect(remote.callbackCorrelationId, callbackCorrelationId);
    expect(remote.authorizationChecks, 0);
    final context = tester.element(
      find.byKey(const Key('email-import-settings-list')),
    );
    expect(
      GoRouter.of(context).routeInformationProvider.value.uri.toString(),
      '/settings/email-import',
    );
  });

  testWidgets('account email-data deletion has a separate explicit dialog',
      (tester) async {
    final remote = _FakeRemoteActions();
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(),
        remote: remote,
      ).widget('/settings/email-import'),
    );
    await tester.pumpAndSettle();

    final deleteButton = find.byKey(
      const Key('email-account-data-delete-button'),
    );
    await tester.scrollUntilVisible(
      deleteButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(
      find.byKey(const Key('email-import-settings-list')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('メール取込データを削除しますか？'), findsOneWidget);
    expect(find.textContaining('追加済みの課題・テスト・予定は削除されません'), findsOneWidget);
    expect(remote.accountDataDeleteCalls, 0);

    await tester.tap(
      find.byKey(const Key('confirm-email-account-data-delete-button')),
    );
    await tester.pumpAndSettle();

    expect(remote.accountDataDeleteCalls, 1);
    expect(find.text('メール取込データを削除しました'), findsOneWidget);
  });

  testWidgets('account email-data deletion is disabled while offline',
      (tester) async {
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(),
        online: false,
      ).widget('/settings/email-import'),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('email-import-settings-list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('email-account-data-delete-button')),
    );
    expect(button.onPressed, isNull);
  });

  test('controller treats a validated OAuth launch as expected handoff',
      () async {
    final now = DateTime.utc(2030, 4, 1);
    final remote = _FakeRemoteActions()
      ..connectResult = EmailConnectionState(
        provider: EmailProvider.gmail,
        status: EmailConnectionStatus.connecting,
        oauthChallenge: EmailOAuthAuthorizationChallenge(
          authorizationUri: Uri.parse(
            'https://accounts.google.com/o/oauth2/v2/auth?public=challenge',
          ),
          codeChallenge: 'c' * 43,
          expiresAt: now.add(const Duration(minutes: 10)),
        ),
      );
    final controller = EmailReviewActionController(
      store: _FakeEmailReviewStore(),
      remoteActions: remote,
      confirmationGateway: _FakeConfirmationGateway(),
    );
    addTearDown(controller.dispose);

    expect(await controller.connect(_session.userId), isTrue);
    expect(controller.state.success, EmailReviewSuccess.authorizationOpened);
    expect(
      controller.state.connectionStatus,
      EmailConnectionStatus.connecting,
    );
    expect(controller.state.failureCategory, isNull);
  });

  testWidgets(
    'review edits, links an owned course and confirms only after acknowledgement',
    (tester) async {
      final candidate = _candidate(
        id: 'candidate-assignment',
        payload: _payload(
          warnings: const ['ambiguous_course'],
          evidence: const [
            EmailCandidateEvidence(
              field: 'due.at',
              text: '締切は7月31日 23時59分です',
            ),
          ],
        ),
      );
      final store = _FakeEmailReviewStore(candidates: [candidate]);
      final confirmation = _FakeConfirmationGateway();
      await tester.pumpWidget(
        _Harness(
          store: store,
          confirmation: confirmation,
          courses: const [
            EmailOwnedCourseOption(id: 'course-1', title: '情報工学'),
          ],
        ).widget('/email-import/${candidate.id}'),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('email-candidate-title-field')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('email-candidate-title-field')),
        '編集したレポート',
      );
      await tester.scrollUntilVisible(
        find.text('授業を確認してください'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('授業を確認してください'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('締切は7月31日 23時59分です'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('締切は7月31日 23時59分です'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('email-candidate-owned-course-field')),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, 180),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('email-candidate-owned-course-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('情報工学').last);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('email-review-acknowledgement')),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      var addButton = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-email-candidate-button')),
      );
      expect(addButton.onPressed, isNull);
      await tester.tap(
        find.byKey(const Key('email-review-acknowledgement')),
      );
      await tester.pump();
      addButton = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-email-candidate-button')),
      );
      expect(addButton.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('confirm-email-candidate-button')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('confirm-private-email-add-button')));
      await tester.pumpAndSettle();

      expect(store.savedPayload?.title, '編集したレポート');
      expect(store.savedPayload?.warnings, ['ambiguous_course']);
      expect(confirmation.calls, 1);
      expect(confirmation.courseId, 'course-1');
    },
  );

  testWidgets(
    'due field preserves its validated IANA timezone and absolute instant',
    (tester) async {
      final instant = DateTime.utc(2026, 3, 8, 6, 30);
      final candidate = _candidate(
        id: 'candidate-new-york-roundtrip',
        timezone: 'America/New_York',
        payload: _payload(
          dueAt: instant,
          dueTimezone: 'America/New_York',
        ),
      );
      final store = _FakeEmailReviewStore(candidates: [candidate]);
      await tester.pumpWidget(
        _Harness(store: store).widget('/email-import/${candidate.id}'),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('email-candidate-due-field')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      final dueField = tester.widget<TextFormField>(
        find.byKey(const Key('email-candidate-due-field')),
      );
      expect(dueField.controller?.text, '2026-03-08 01:30');

      await tester.scrollUntilVisible(
        find.byKey(const Key('email-candidate-timezone-field')),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      final timezoneField = tester.widget<TextFormField>(
        find.byKey(const Key('email-candidate-timezone-field')),
      );
      expect(timezoneField.controller?.text, 'America/New_York');
      final timezoneEditor = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('email-candidate-timezone-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(timezoneEditor.readOnly, isTrue);

      await tester.tap(find.byKey(const Key('save-email-candidate-button')));
      await tester.pumpAndSettle();

      expect(store.savedPayload?.due.at, instant);
      expect(store.savedPayload?.due.at?.isUtc, isTrue);
      expect(store.savedPayload?.due.timezone, 'America/New_York');
    },
  );

  testWidgets('New York DST gap is rejected and a valid edit stores UTC', (
    tester,
  ) async {
    final candidate = _candidate(
      id: 'candidate-new-york-dst-edit',
      timezone: 'America/New_York',
      payload: _payload(
        dueAt: DateTime.utc(2026, 3, 8, 6, 30),
        dueTimezone: 'America/New_York',
      ),
    );
    final store = _FakeEmailReviewStore(candidates: [candidate]);
    await tester.pumpWidget(
      _Harness(store: store).widget('/email-import/${candidate.id}'),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('email-candidate-due-field')),
      150,
      scrollable: find.byType(Scrollable).first,
    );

    await tester.enterText(
      find.byKey(const Key('email-candidate-due-field')),
      '2026-03-08 02:30',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('save-email-candidate-button')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('email-candidate-due-field')),
      '2026-03-08 03:30',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-email-candidate-button')));
    await tester.pumpAndSettle();
    expect(store.savedPayload?.due.at, DateTime.utc(2026, 3, 8, 7, 30));
    expect(store.savedPayload?.due.timezone, 'America/New_York');
  });

  testWidgets(
      'an open review freezes its editing timezone across cache updates',
      (tester) async {
    final instant = DateTime.utc(2026, 3, 8, 6, 30);
    final initial = _candidate(
      id: 'candidate-timezone-stream-race',
      timezone: 'America/New_York',
      payload: _payload(
        dueAt: instant,
        dueTimezone: 'America/New_York',
      ),
    );
    final store = _MutableTimezoneEmailReviewStore(candidates: [initial]);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      _Harness(store: store).widget('/email-import/${initial.id}'),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('email-candidate-due-field')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('email-candidate-due-field')),
          )
          .controller
          ?.text,
      '2026-03-08 01:30',
    );

    store.emit(
      _candidate(
        id: initial.id,
        timezone: 'America/Los_Angeles',
        payload: initial.payload,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-email-candidate-button')));
    await tester.pumpAndSettle();

    expect(store.savedPayload?.due.at, instant);
    expect(store.savedPayload?.due.timezone, 'America/New_York');
  });

  testWidgets('editing a Japan wall time stores the matching UTC instant', (
    tester,
  ) async {
    final candidate = _candidate(id: 'candidate-japan-edit');
    final store = _FakeEmailReviewStore(candidates: [candidate]);
    await tester.pumpWidget(
      _Harness(store: store).widget('/email-import/${candidate.id}'),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('email-candidate-due-field')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.byKey(const Key('email-candidate-due-field')),
      '2030-01-02 03:04',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-email-candidate-button')));
    await tester.pumpAndSettle();

    expect(store.savedPayload?.due.at, DateTime.utc(2030, 1, 1, 18, 4));
    expect(store.savedPayload?.due.timezone, JapanTime.timeZone);
  });

  testWidgets('save failure cannot invoke confirmation or expose diagnostics', (
    tester,
  ) async {
    final candidate = _candidate(id: 'candidate-save-fails');
    final store = _FakeEmailReviewStore(
      candidates: [candidate],
      saveError: StateError('sensitive sqlite diagnostic'),
    );
    final confirmation = _FakeConfirmationGateway();
    await tester.pumpWidget(
      _Harness(store: store, confirmation: confirmation)
          .widget('/email-import/${candidate.id}'),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('email-review-acknowledgement')),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('email-review-acknowledgement')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-email-candidate-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-private-email-add-button')));
    await tester.pumpAndSettle();

    expect(confirmation.calls, 0);
    expect(find.textContaining('sensitive sqlite diagnostic'), findsNothing);
    expect(find.text('処理を完了できませんでした。もう一度お試しください。'), findsOneWidget);
  });

  testWidgets('unknown and malformed candidates cannot be confirmed', (
    tester,
  ) async {
    final unknown = _candidate(
      id: 'unknown',
      payload: _payload(type: EmailCandidateType.unknown),
    );
    final malformed = EmailReviewCandidate(
      id: 'malformed',
      state: EmailCandidateReviewState.failed,
      errorCategory: EmailErrorCategory.unsafeContent,
      updatedAt: DateTime.utc(2030),
    );
    final harness = _Harness(
      store: _FakeEmailReviewStore(candidates: [unknown, malformed]),
    );
    await tester.pumpWidget(harness.widget('/email-import/unknown'));
    await tester.pumpAndSettle();
    expect(find.textContaining('この種類のままでは追加できません'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('confirm-email-candidate-button')),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('confirm-email-candidate-button')),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(harness.widget('/email-import/malformed'));
    await tester.pumpAndSettle();
    expect(find.text('この候補は安全に表示できませんでした'), findsOneWidget);
    expect(
        find.byKey(const Key('confirm-email-candidate-button')), findsNothing);
    expect(
      find.byKey(const Key('retry-malformed-email-candidate-button')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('dismiss-malformed-email-candidate-button')),
      findsOneWidget,
    );
  });

  testWidgets('transient failed candidate exposes online targeted retry', (
    tester,
  ) async {
    final failed = EmailReviewCandidate(
      id: 'transient-failure',
      state: EmailCandidateReviewState.failed,
      errorCategory: EmailErrorCategory.timeout,
      updatedAt: DateTime.utc(2030),
    );
    final remote = _FakeRemoteActions();
    await tester.pumpWidget(
      _Harness(
        store: _FakeEmailReviewStore(candidates: [failed]),
        remote: remote,
      ).widget('/email-import/${failed.id}'),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('retry-malformed-email-candidate-button')),
    );
    await tester.pumpAndSettle();
    expect(remote.retryCalls, 1);
  });

  testWidgets('confirmed and dismissed candidates stay out of the new inbox', (
    tester,
  ) async {
    final store = _FakeEmailReviewStore(candidates: [
      _candidate(id: 'new', title: '確認する候補'),
      _candidate(
        id: 'confirmed',
        title: '追加済み候補',
        state: EmailCandidateReviewState.confirmed,
      ),
      _candidate(
        id: 'dismissed',
        title: '除外済み候補',
        state: EmailCandidateReviewState.dismissed,
      ),
    ]);
    await tester.pumpWidget(_Harness(store: store).widget('/email-import'));
    await tester.pumpAndSettle();

    expect(find.text('確認する候補'), findsOneWidget);
    expect(find.text('追加済み候補'), findsNothing);
    expect(find.text('除外済み候補'), findsNothing);
    await tester.tap(find.text('履歴 (2)'));
    await tester.pumpAndSettle();
    expect(find.text('確認する候補'), findsNothing);
    expect(find.text('追加済み候補'), findsOneWidget);
    expect(find.text('除外済み候補'), findsOneWidget);
  });

  testWidgets('minimal dismissed history has no retry or dismiss actions', (
    tester,
  ) async {
    final dismissed = EmailReviewCandidate(
      id: 'minimal-dismissed',
      state: EmailCandidateReviewState.dismissed,
      updatedAt: DateTime.utc(2030),
    );
    await tester.pumpWidget(
      _Harness(store: _FakeEmailReviewStore(candidates: [dismissed]))
          .widget('/email-import'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('履歴 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('除外した候補'), findsOneWidget);
    expect(find.text('内容は削除済み'), findsOneWidget);

    await tester.tap(find.text('除外した候補'));
    await tester.pumpAndSettle();
    expect(find.text('この候補は除外済みです'), findsOneWidget);
    expect(find.textContaining('最小限の識別情報だけを保持'), findsOneWidget);
    expect(find.byKey(const Key('retry-malformed-email-candidate-button')),
        findsNothing);
    expect(find.byKey(const Key('dismiss-malformed-email-candidate-button')),
        findsNothing);
  });

  testWidgets('long press starts visible selection and bulk dismisses safely', (
    tester,
  ) async {
    final store = _FakeEmailReviewStore(candidates: [
      _candidate(id: 'first', title: '候補A'),
      _candidate(id: 'second', title: '候補B'),
    ]);
    await tester.pumpWidget(_Harness(store: store).widget('/email-import'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('候補A'));
    await tester.pump();
    expect(find.text('1件を選択中'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('bulk-dismiss-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-bulk-dismiss-button')));
    await tester.pumpAndSettle();
    expect(store.dismissedIds, ['first']);
  });

  testWidgets('narrow Android review layout has no overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final candidate = _candidate(
      id: 'narrow',
      title: '狭い画面でも折り返される長い課題タイトル',
      payload: _payload(
        title: '狭い画面でも折り返される長い課題タイトル',
        warnings: const ['ambiguous_date', 'ambiguous_course'],
      ),
    );
    await tester.pumpWidget(
      _Harness(store: _FakeEmailReviewStore(candidates: [candidate]))
          .widget('/email-import/narrow'),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('email-candidate-review-narrow')),
      findsOneWidget,
    );
    expect(
        find.byKey(const Key('email-candidate-review-list')), findsOneWidget);
  });

  test('email routes remain protected by the authenticated navigation guard',
      () {
    for (final route in [
      '/settings/email-import',
      '/email-import',
      '/email-import/candidate-1',
    ]) {
      expect(
        resolveAppRedirect(
          authStatus: AuthGateStatus.signedOut,
          onboardingStatus: OnboardingGateStatus.required,
          currentLocation: route,
          pendingLinks: PendingDeepLinkStore(),
          normalizer: DeepLinkNormalizer(AppConfig.demoForTesting()),
        ),
        '/sign-in',
      );
    }
  });

  test('event confirmation drops a stale course selection at the controller',
      () async {
    final eventPayload = _payload(type: EmailCandidateType.event);
    final store = _FakeEmailReviewStore(
      candidates: [
        _candidate(id: 'event-candidate', payload: eventPayload),
      ],
    );
    final confirmation = _FakeConfirmationGateway();
    final controller = EmailReviewActionController(
      store: store,
      remoteActions: _FakeRemoteActions(),
      confirmationGateway: confirmation,
    );
    addTearDown(controller.dispose);

    expect(
      await controller.saveAndConfirm(
        ownerUserId: _session.userId,
        candidateId: 'event-candidate',
        payload: eventPayload,
        warningsAcknowledged: true,
        courseId: 'stale-course-id',
      ),
      isTrue,
    );
    expect(confirmation.calls, 1);
    expect(confirmation.courseId, isNull);
  });
}

const _session = AppAuthSession(
  userId: '11111111-1111-4111-8111-111111111111',
  email: 'student@example.invalid',
);

class _Harness {
  _Harness({
    required this.store,
    this.online = true,
    this.connectivityHintSource,
    this.backendReachabilityProbe,
    _FakeRemoteActions? remote,
    _FakeConfirmationGateway? confirmation,
    this.courses = const [],
  })  : assert(
          (connectivityHintSource == null) ==
              (backendReachabilityProbe == null),
        ),
        remote = remote ?? _FakeRemoteActions(),
        confirmation = confirmation ?? _FakeConfirmationGateway();

  final _FakeEmailReviewStore store;
  final bool online;
  final EmailConnectivityHintSource? connectivityHintSource;
  final EmailBackendReachabilityProbe? backendReachabilityProbe;
  final _FakeRemoteActions remote;
  final _FakeConfirmationGateway confirmation;
  final List<EmailOwnedCourseOption> courses;

  Widget widget(String initialLocation) {
    // The production update repository is intentionally backed by the
    // prepared database provider. Keep this fixture explicit so review-screen
    // tests do not accidentally depend on the application's bootstrap.
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/settings/email-import',
          builder: (_, state) {
            final callback =
                EmailAuthorizationCallbackParameters.fromInternalUri(state.uri);
            return EmailImportSettingsScreen(
              callbackRequestedConnectionId: callback?.requestedConnectionId,
              callbackCorrelationId: callback?.correlationId,
            );
          },
        ),
        GoRoute(
          path: '/email-import',
          builder: (_, __) => const EmailCandidateInboxScreen(),
        ),
        GoRoute(
          path: '/email-import/:id',
          builder: (_, state) => EmailCandidateReviewScreen(
            candidateId: state.pathParameters['id']!,
          ),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
        appDatabaseProvider.overrideWithValue(db),
        currentAuthSessionProvider.overrideWithValue(_session),
        emailImportPresentationEnabledProvider.overrideWithValue(true),
        emailReviewStoreProvider.overrideWithValue(store),
        emailCandidateUpdatesProvider(_session.userId).overrideWith(
          (ref) => Stream.value(const <EmailCandidateUpdateProposal>[]),
        ),
        emailReviewRemoteActionsProvider.overrideWithValue(remote),
        emailCandidateConfirmationGatewayProvider.overrideWithValue(
          confirmation,
        ),
        if (connectivityHintSource == null)
          emailNetworkAvailableProvider.overrideWith(
            (ref) => Stream.value(online),
          )
        else ...[
          emailConnectivityHintSourceProvider.overrideWithValue(
            connectivityHintSource!,
          ),
          emailBackendReachabilityProbeProvider.overrideWithValue(
            backendReachabilityProbe!,
          ),
        ],
        emailOwnedCoursesProvider.overrideWithValue(courses),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }
}

class _FakeEmailConnectivityHintSource implements EmailConnectivityHintSource {
  _FakeEmailConnectivityHintSource({
    Future<List<ConnectivityResult>>? initialCheck,
  }) : _initialCheck =
            initialCheck ?? Future.value(const [ConnectivityResult.wifi]);

  final Future<List<ConnectivityResult>> _initialCheck;
  final StreamController<List<ConnectivityResult>> _changes =
      StreamController<List<ConnectivityResult>>.broadcast(sync: true);

  @override
  Future<List<ConnectivityResult>> checkConnectivity() => _initialCheck;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

  void add(List<ConnectivityResult> results) => _changes.add(results);

  Future<void> close() => _changes.close();
}

class _TrackingHttpClient extends http.BaseClient {
  bool isClosed = false;
  Uri? requestedUri;
  Completer<http.StreamedResponse>? _pendingResponse;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requestedUri = request.url;
    final completer = Completer<http.StreamedResponse>();
    _pendingResponse = completer;
    return completer.future;
  }

  @override
  void close() {
    isClosed = true;
    final pendingResponse = _pendingResponse;
    if (pendingResponse != null && !pendingResponse.isCompleted) {
      pendingResponse.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 503),
      );
    }
    super.close();
  }
}

Future<void> _waitForEmailNetworkValue(
  ProviderContainer container,
  bool expected,
) {
  return _waitForTestCondition(
    () => container.read(emailNetworkAvailableProvider).valueOrNull == expected,
    label: 'Email network availability to become $expected',
  );
}

Future<void> _waitForTestCondition(
  bool Function() condition, {
  required String label,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for $label.');
}

Future<void> _drainTestMicrotasks() async {
  for (var index = 0; index < 10; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeEmailReviewStore implements EmailReviewStore {
  _FakeEmailReviewStore({
    List<EmailConnectionSummary>? connections,
    List<EmailReviewCandidate>? candidates,
    this.holdCandidates = false,
    this.candidateError,
    this.saveError,
  })  : connections = [...?connections],
        candidates = [...?candidates];

  final List<EmailConnectionSummary> connections;
  final List<EmailReviewCandidate> candidates;
  final bool holdCandidates;
  final Object? candidateError;
  final Object? saveError;
  final dismissedIds = <String>[];
  EmailCandidatePayload? savedPayload;

  @override
  Stream<List<EmailConnectionSummary>> watchConnections(String ownerUserId) {
    return Stream.value(List.unmodifiable(connections));
  }

  @override
  Stream<List<EmailReviewCandidate>> watchCandidates(String ownerUserId) {
    if (candidateError != null) return Stream.error(candidateError!);
    if (holdCandidates) return const Stream.empty();
    return Stream.value(List.unmodifiable(candidates));
  }

  @override
  Future<EmailReviewCandidate?> loadCandidate({
    required String ownerUserId,
    required String candidateId,
  }) async {
    return candidates.where((item) => item.id == candidateId).firstOrNull;
  }

  @override
  Future<void> saveDraft({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
  }) async {
    if (saveError != null) throw saveError!;
    savedPayload = payload;
    final index = candidates.indexWhere((item) => item.id == candidateId);
    if (index < 0) {
      throw const EmailReviewActionException(
        EmailErrorCategory.validationFailed,
      );
    }
    candidates[index] = EmailReviewCandidate(
      id: candidateId,
      state: EmailCandidateReviewState.readyForReview,
      payload: payload,
      updatedAt: DateTime.utc(2030, 4, 1),
      timezone: candidates[index].timezone,
    );
  }

  @override
  Future<void> dismiss({
    required String ownerUserId,
    required String candidateId,
  }) async {
    dismissedIds.add(candidateId);
  }
}

class _MutableTimezoneEmailReviewStore extends _FakeEmailReviewStore {
  _MutableTimezoneEmailReviewStore({required super.candidates});

  final _updates = StreamController<List<EmailReviewCandidate>>.broadcast();

  @override
  Stream<List<EmailReviewCandidate>> watchCandidates(
      String ownerUserId) async* {
    yield List.unmodifiable(candidates);
    yield* _updates.stream;
  }

  void emit(EmailReviewCandidate candidate) {
    final index = candidates.indexWhere((item) => item.id == candidate.id);
    candidates[index] = candidate;
    _updates.add(List.unmodifiable(candidates));
  }

  Future<void> dispose() => _updates.close();
}

class _FakeRemoteActions implements EmailReviewRemoteActions {
  EmailConnectionState connectResult = const EmailConnectionState(
    provider: EmailProvider.gmail,
    status: EmailConnectionStatus.connected,
  );
  int refreshCalls = 0;
  int retryCalls = 0;
  int disconnectCalls = 0;
  int authorizationChecks = 0;
  int accountDataDeleteCalls = 0;

  @override
  Future<EmailConnectionState> connect({required String ownerUserId}) async {
    return connectResult;
  }

  @override
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  }) async {
    authorizationChecks++;
    return connectResult;
  }

  @override
  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) async {
    disconnectCalls++;
  }

  @override
  Future<void> deleteAccountData({required String ownerUserId}) async {
    accountDataDeleteCalls++;
  }

  @override
  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  }) async {
    refreshCalls++;
  }

  @override
  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  }) async {
    retryCalls++;
  }
}

class _CorrelatedFakeRemoteActions extends _FakeRemoteActions
    implements CorrelatedEmailAuthorizationActions {
  int correlatedChecks = 0;
  String? requestedConnectionId;
  String? callbackCorrelationId;

  @override
  Future<EmailConnectionState> checkCorrelatedAuthorization({
    required String ownerUserId,
    required String requestedConnectionId,
    required String callbackCorrelationId,
  }) async {
    correlatedChecks++;
    this.requestedConnectionId = requestedConnectionId;
    this.callbackCorrelationId = callbackCorrelationId;
    return connectResult;
  }
}

class _FakeConfirmationGateway implements EmailCandidateConfirmationGateway {
  int calls = 0;
  String? courseId;

  @override
  Future<EmailCandidateConfirmationResult> confirm({
    required String ownerUserId,
    required String candidateId,
    String? courseId,
  }) async {
    calls++;
    this.courseId = courseId;
    return EmailCandidateConfirmationResult(
      candidateId: candidateId,
      entityType: EmailCandidateType.assignment,
      entityId: 'entity-1',
      replayed: false,
    );
  }
}

EmailConnectionSummary _connection(
  EmailConnectionStatus status, {
  String id = '22222222-2222-4222-8222-222222222222',
  EmailErrorCategory? error,
  DateTime? retryAfter,
}) {
  return EmailConnectionSummary(
    id: id,
    provider: EmailProvider.gmail,
    status: status,
    errorCategory: error,
    retryAfter: retryAfter,
    updatedAt: DateTime.utc(2030, 4, 1),
  );
}

EmailReviewCandidate _candidate({
  required String id,
  String? title,
  EmailCandidateReviewState state = EmailCandidateReviewState.readyForReview,
  EmailCandidatePayload? payload,
  String timezone = JapanTime.timeZone,
}) {
  return EmailReviewCandidate(
    id: id,
    state: state,
    payload: payload ?? _payload(title: title),
    updatedAt: DateTime.utc(2030, 4, 1),
    timezone: timezone,
  );
}

EmailCandidatePayload _payload({
  EmailCandidateType type = EmailCandidateType.assignment,
  String? title,
  List<String> warnings = const [],
  List<EmailCandidateEvidence> evidence = const [],
  DateTime? dueAt,
  String? dueTimezone = JapanTime.timeZone,
}) {
  return EmailCandidatePayload(
    schemaVersion: '1.0',
    candidateType: type,
    title: title ?? '情報工学レポート',
    courseHint: const EmailCourseHint(name: '情報工学', code: 'CS101'),
    due: EmailDueCandidate(
      at: dueAt ?? DateTime.utc(2030, 4, 10, 14, 59),
      timezone: dueTimezone,
      rawText: '4月10日 23:59',
    ),
    startAt: type == EmailCandidateType.exam || type == EmailCandidateType.event
        ? DateTime.utc(2030, 4, 12, 1)
        : null,
    endAt: type == EmailCandidateType.exam || type == EmailCandidateType.event
        ? DateTime.utc(2030, 4, 12, 2)
        : null,
    location: 'A101',
    submissionUrl: type == EmailCandidateType.assignment
        ? 'https://classroom.example.invalid/submit'
        : null,
    summary: '合成テスト用の候補です',
    suggestedRemindersMinutes: const [1440, 180],
    confidence: const EmailCandidateConfidence(
      overall: 0.74,
      title: 0.9,
      course: 0.6,
      dateTime: 0.7,
    ),
    evidence: evidence,
    warnings: warnings,
    requiresUserConfirmation: true,
  );
}
