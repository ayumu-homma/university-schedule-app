import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/app/app.dart';
import 'package:university_schedule_mobile/app/router.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/data/supabase_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/onboarding/application/onboarding_providers.dart';
import 'package:university_schedule_mobile/features/onboarding/data/drift_onboarding_local_store.dart';
import 'package:university_schedule_mobile/features/onboarding/data/supabase_onboarding_repository.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_repository.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/university/application/university_settings_providers.dart';
import 'package:university_schedule_mobile/features/university/domain/university_settings_models.dart';
import 'package:university_schedule_mobile/features/university/domain/university_settings_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('non-demo composition injects production repositories and gateway',
      () async {
    final client = _testSupabaseClient();
    final database = local.AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_productionTestConfig()),
        supabaseClientProvider.overrideWithValue(client),
        secureAuthLocalStorageProvider.overrideWithValue(
          const _TestLocalStorage(),
        ),
        appDatabaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      await client.dispose();
    });

    expect(
      container.read(authRepositoryProvider),
      isA<SupabaseAuthRepository>(),
    );
    expect(
      container.read(onboardingRepositoryProvider),
      isA<SupabaseOnboardingRepository>(),
    );
    expect(
      container.read(scheduleRepositoryProvider),
      isA<DriftScheduleRepository>(),
    );
    expect(
      container.read(remoteScheduleGatewayProvider),
      isA<SupabaseScheduleGateway>(),
    );
    expect(
      container.read(remoteScheduleGatewayProvider),
      isNot(isA<DisabledRemoteScheduleGateway>()),
    );
  });

  test('late onboarding error from user A is not published for user B',
      () async {
    const userA = AppAuthSession(userId: 'user-a');
    const userB = AppAuthSession(userId: 'user-b');
    final authRepository = FakeAuthRepository(initialSession: userA);
    final onboardingRepository = _SessionSwitchOnboardingRepository();
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_productionTestConfig()),
        authRepositoryProvider.overrideWithValue(authRepository),
        onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await authRepository.dispose();
    });

    await container.read(authStateProvider.future);
    final profileA = await container.read(onboardingControllerProvider.future);
    expect(profileA?.userId, userA.userId);
    final completionFuture = container
        .read(onboardingControllerProvider.notifier)
        .completeOnboarding(
          const OnboardingCompletion(
            idempotencyKey: 'request-a',
            userType: OnboardingUserType.undergraduate,
            universityId: 'university-a',
            entryAcademicYear: 2024,
            termTemplateId: 'term-a',
            periodTemplateSetId: 'periods-a',
          ),
        );
    await onboardingRepository.completionStarted.future;

    authRepository.restoreSession(userB);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    onboardingRepository.completion.completeError(
      const ValidationError('late user A failure'),
    );
    await completionFuture;

    final profileB = await container.read(onboardingControllerProvider.future);
    expect(profileB?.userId, userB.userId);
    expect(container.read(onboardingControllerProvider).hasError, isFalse);
  });

  testWidgets(
    'initial production session hydrates Drift, completes onboarding, and opens real Home',
    (tester) async {
      const restoredSession = AppAuthSession(
        userId: _FakeOnboardingRepository.userId,
        email: 'student@example.test',
      );
      final authRepository = FakeAuthRepository(
        initialSession: restoredSession,
        autoAuthenticateOAuth: false,
      );
      final database = local.AppDatabase(NativeDatabase.memory());
      final onboardingRepository = _FakeOnboardingRepository(
        DriftOnboardingLocalStore(database),
      );
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(_productionTestConfig()),
          appDatabaseProvider.overrideWithValue(database),
          authRepositoryProvider.overrideWithValue(authRepository),
          onboardingRepositoryProvider.overrideWithValue(
            onboardingRepository,
          ),
          remoteScheduleGatewayProvider.overrideWithValue(
            SupabaseScheduleGateway(
              upsertOverride: (table, payload) async {},
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await authRepository.dispose();
        await database.close();
      });

      final restoredAuth = await container.read(authStateProvider.future);
      expect(restoredAuth.event, AuthEvent.initialSession);
      expect(restoredAuth.session, restoredSession);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const UniversityScheduleApp(),
        ),
      );
      await _pumpUntil(
        tester,
        finder: find.text('初期設定'),
        label: 'restored profile routes to onboarding',
      );

      expect(find.text('初期設定'), findsOneWidget);
      expect(find.text('金沢工業大学'), findsOneWidget);
      await _scrollOnboardingFormTo(tester, find.text('扇が丘'));
      expect(find.text('扇が丘'), findsOneWidget);

      await _scrollOnboardingFormTo(
        tester,
        find.byKey(const Key('onboarding-entry-year')),
      );
      await tester.enterText(
        find.byKey(const Key('onboarding-entry-year')),
        '2024',
      );
      await _selectTerm(
        tester,
        currentId: null,
        label: '2026年度 後学期',
      );
      expect(_entryYearText(tester), '2024');
      await _selectTerm(
        tester,
        currentId: _FakeOnboardingRepository.fallTermTemplateId,
        label: '2026年度 前学期',
      );
      expect(_entryYearText(tester), '2024');

      await _scrollOnboardingFormTo(tester, find.text('時限設定'));
      expect(find.text('時限設定'), findsOneWidget);

      final completeButton = find.byKey(
        const Key('complete-onboarding-button'),
      );
      await _scrollOnboardingFormTo(tester, completeButton);
      await tester.tap(completeButton);
      await _pumpUntil(
        tester,
        finder: find.text('2026 年度'),
        label: 'completed onboarding routes to Home',
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('ホーム'), findsWidgets);
      expect(find.text('2026 年度'), findsOneWidget);
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .path,
        '/',
      );
      expect(onboardingRepository.completion?.entryAcademicYear, 2024);
      expect(
        onboardingRepository.completion?.periodTemplateSetId,
        _FakeOnboardingRepository.periodTemplateSetId,
      );

      final profiles = await database.select(database.profiles).get();
      final terms = await database.select(database.terms).get();
      final periods = await database.select(database.periodSettings).get();
      final calendars = await database.select(database.calendars).get();
      expect(profiles.single.userId, _FakeOnboardingRepository.userId);
      expect(profiles.single.entryAcademicYear, 2024);
      expect(terms.single.id, _FakeOnboardingRepository.activeTermId);
      expect(periods, hasLength(2));
      expect(
        periods.every(
          (period) =>
              period.ownerUserId == _FakeOnboardingRepository.userId &&
              period.termId == _FakeOnboardingRepository.activeTermId,
        ),
        isTrue,
      );
      expect(calendars.single.id, _FakeOnboardingRepository.calendarId);

      final maybeActiveContext = container.read(activeScheduleContextProvider);
      expect(maybeActiveContext, isNotNull);
      final activeContext = maybeActiveContext!;
      expect(activeContext.ownerUserId, _FakeOnboardingRepository.userId);
      expect(
        activeContext.ownerUserId,
        isNot(equals(demoScheduleContext.ownerUserId)),
      );
      expect(
        activeContext.universityId,
        _FakeOnboardingRepository.universityId,
      );
      expect(activeContext.termId, _FakeOnboardingRepository.activeTermId);
      expect(activeContext.primaryCalendarId,
          _FakeOnboardingRepository.calendarId);

      expect(find.byKey(const Key('first-course-continuation-card')),
          findsOneWidget);
      expect(
        find.text('保存後に、必要に応じて通知設定の案内が表示されます。'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('first-course-continuation-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('授業を作成'), findsOneWidget);
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .queryParameters['firstCourse'],
        'true',
      );

      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'オンボーディング初回授業',
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.tap(find.byKey(const Key('course-save')));
        await _pumpUntil(
          tester,
          finder: find.text('予定通知について'),
          label: 'contextual notification explanation after the first course',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(
        find.text(
          '授業・課題・試験・予定の開始前に、この端末で通知します。'
          '端末の通知設定と正確なアラーム設定が必要です。',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('後で'));
      await _pumpUntil(
        tester,
        finder: find.text('2026 年度'),
        label: 'first course completes and returns to Home',
      );
      await tester.pumpAndSettle();
      expect(find.text('最初の授業を登録しましょう'), findsNothing);
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .path,
        '/',
      );
      final firstCourses = await database.select(database.userCourses).get();
      expect(firstCourses.single.title, 'オンボーディング初回授業');
      expect(firstCourses.single.ownerUserId, _FakeOnboardingRepository.userId);

      final eventId =
          await container.read(demoAppControllerProvider.notifier).createEvent(
                EventInput(
                  title: 'オンボーディング後の予定',
                  startAt: DateTime(2026, 7, 13, 10),
                  endAt: DateTime(2026, 7, 13, 11),
                ),
              );
      final event = await (database.select(database.events)
            ..where((row) => row.id.equals(eventId)))
          .getSingle();
      expect(event.ownerUserId, _FakeOnboardingRepository.userId);
      expect(event.calendarId, _FakeOnboardingRepository.calendarId);
      expect(
        container.read(remoteScheduleGatewayProvider),
        isA<SupabaseScheduleGateway>(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'incomplete onboarding can request an unregistered university without completing its profile',
    (tester) async {
      const restoredSession = AppAuthSession(
        userId: _FakeOnboardingRepository.userId,
        email: 'unregistered@example.test',
      );
      final authRepository = FakeAuthRepository(
        initialSession: restoredSession,
        autoAuthenticateOAuth: false,
      );
      final database = local.AppDatabase(NativeDatabase.memory());
      final onboardingRepository = _FakeOnboardingRepository(
        DriftOnboardingLocalStore(database),
      );
      final universityRepository = _RecordingUniversitySettingsRepository();
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(_productionTestConfig()),
          appDatabaseProvider.overrideWithValue(database),
          authRepositoryProvider.overrideWithValue(authRepository),
          onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
          universitySettingsRepositoryProvider.overrideWithValue(
            universityRepository,
          ),
          remoteScheduleGatewayProvider.overrideWithValue(
            SupabaseScheduleGateway(upsertOverride: (table, payload) async {}),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await authRepository.dispose();
        await database.close();
      });

      await container.read(authStateProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const UniversityScheduleApp(),
        ),
      );
      await _pumpUntil(
        tester,
        finder: find.text('初期設定'),
        label: 'the incomplete onboarding form',
      );

      final requestButton = find.byKey(
        const Key('onboarding-request-university-button'),
      );
      await _scrollOnboardingFormTo(tester, requestButton);
      await tester.tap(requestButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('university-request-name')),
        '  未登録テスト大学  ',
      );
      await tester.enterText(
        find.byKey(const Key('university-request-prefecture')),
        '石川県',
      );
      await tester.enterText(
        find.byKey(const Key('university-request-url')),
        'https://unregistered.example.test',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('submit-university-request-button')),
      );
      await _pumpUntil(
        tester,
        finder: find.text('大学追加申請を受け付けました。審査後に大学を選択できます。'),
        label: 'the onboarding university-request acknowledgement',
      );

      expect(universityRepository.submitted, isNotNull);
      expect(universityRepository.submitted!.name, '未登録テスト大学');
      expect(universityRepository.submitted!.prefecture, '石川県');
      expect(
        universityRepository.submitted!.officialUrl,
        'https://unregistered.example.test',
      );
      expect(
        container
            .read(routerProvider)
            .routerDelegate
            .currentConfiguration
            .uri
            .path,
        '/onboarding',
      );
      expect(
        container
            .read(onboardingControllerProvider)
            .valueOrNull
            ?.hasActiveSchedule,
        isFalse,
      );
      expect(container.read(activeScheduleContextProvider), isNull);
      expect(onboardingRepository.completion, isNull);
      expect(find.text('ホーム'), findsNothing);
    },
  );

  testWidgets(
    'unsupported campus completes onboarding with a custom term and manual periods',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const restoredSession = AppAuthSession(
        userId: _FakeOnboardingRepository.userId,
        email: 'fallback@example.test',
      );
      final authRepository = FakeAuthRepository(
        initialSession: restoredSession,
        autoAuthenticateOAuth: false,
      );
      final database = local.AppDatabase(NativeDatabase.memory());
      final onboardingRepository = _FakeOnboardingRepository(
        DriftOnboardingLocalStore(database),
      );
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(_productionTestConfig()),
          appDatabaseProvider.overrideWithValue(database),
          authRepositoryProvider.overrideWithValue(authRepository),
          onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
          remoteScheduleGatewayProvider.overrideWithValue(
            SupabaseScheduleGateway(upsertOverride: (table, payload) async {}),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await authRepository.dispose();
        await database.close();
      });

      await container.read(authStateProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const UniversityScheduleApp(),
        ),
      );
      await _pumpUntil(
        tester,
        finder: find.text('初期設定'),
        label: 'the fallback onboarding form',
      );

      final campusDropdown = _onboardingSelector('onboarding-campus-');
      await tester.tap(campusDropdown);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('やつかほリサーチ').last);
      await tester.pumpAndSettle();

      final customTermSource = find.text('学期を手入力');
      await _scrollOnboardingFormTo(tester, customTermSource);
      await tester.tap(customTermSource);
      await tester.pumpAndSettle();
      final customTermName = find.byKey(
        const Key('onboarding-custom-term-name'),
      );
      await _scrollOnboardingFormTo(tester, customTermName);
      await tester.enterText(
        customTermName,
        '虎ノ門カスタム学期',
      );
      final customTermYear = find.byKey(
        const Key('onboarding-custom-term-year'),
      );
      await _scrollOnboardingFormTo(tester, customTermYear);
      await tester.enterText(
        customTermYear,
        '2026',
      );
      final customTermStart = find.byKey(
        const Key('onboarding-custom-term-start-date'),
      );
      await _scrollOnboardingFormTo(tester, customTermStart);
      await tester.enterText(
        customTermStart,
        '2026-08-01',
      );
      final customTermEnd = find.byKey(
        const Key('onboarding-custom-term-end-date'),
      );
      await _scrollOnboardingFormTo(tester, customTermEnd);
      await tester.enterText(
        customTermEnd,
        '2026-08-31',
      );
      final typeSelector = find.byKey(const Key('onboarding-custom-term-type'));
      await _scrollOnboardingFormTo(tester, typeSelector);
      await tester.tap(typeSelector);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('カスタム').last);
      await tester.pumpAndSettle();

      final addPeriod = find.byKey(
        const Key('onboarding-add-custom-period-button'),
      );
      await _scrollOnboardingFormTo(tester, addPeriod);
      await tester.tap(addPeriod);
      await tester.pump();
      final periodDay = find.byKey(
        const ValueKey('onboarding-period-draft-day-0'),
      );
      await _scrollOnboardingFormTo(tester, periodDay);
      await tester.enterText(
        periodDay,
        '1',
      );
      final periodNumber = find.byKey(
        const ValueKey('onboarding-period-draft-number-0'),
      );
      await _scrollOnboardingFormTo(tester, periodNumber);
      await tester.enterText(
        periodNumber,
        '1',
      );
      final periodStart = find.byKey(
        const ValueKey('onboarding-period-draft-start-0'),
      );
      await _scrollOnboardingFormTo(tester, periodStart);
      await tester.enterText(
        periodStart,
        '09:00',
      );
      final periodEnd = find.byKey(
        const ValueKey('onboarding-period-draft-end-0'),
      );
      await _scrollOnboardingFormTo(tester, periodEnd);
      await tester.enterText(
        periodEnd,
        '10:20',
      );
      final entryYear = find.byKey(const Key('onboarding-entry-year'));
      await _scrollOnboardingFormTo(tester, entryYear);
      await tester.enterText(entryYear, '2026');

      final completeButton = find.byKey(
        const Key('complete-onboarding-button'),
      );
      await _scrollOnboardingFormTo(tester, completeButton);
      await tester.tap(completeButton);
      await _pumpUntil(
        tester,
        finder: find.text('2026 年度'),
        label: 'Home after unsupported-campus onboarding',
      );

      final completion = onboardingRepository.completion;
      expect(
          completion?.campusId, _FakeOnboardingRepository.unavailableCampusId);
      expect(completion?.termTemplateId, isNull);
      expect(completion?.customTerm?.name, '虎ノ門カスタム学期');
      expect(completion?.customTerm?.type, OnboardingCustomTermType.custom);
      expect(completion?.periodTemplateSetId, isNull);
      final customPeriod = completion?.customPeriods?.single;
      expect(customPeriod?.dayOfWeek, 1);
      expect(customPeriod?.periodNo, 1);
      expect(customPeriod?.startTimeMinutes, 9 * 60);
      expect(customPeriod?.endTimeMinutes, 10 * 60 + 20);

      final term = await database.select(database.terms).getSingle();
      final periods = await database.select(database.periodSettings).get();
      expect(term.sourceTemplateId, isNull);
      expect(term.name, '虎ノ門カスタム学期');
      expect(term.termType, 'custom');
      expect(periods, hasLength(1));
      expect(periods.single.sourceTemplateSetId, isNull);
      expect(periods.single.startTimeMinutes, 9 * 60);
      expect(periods.single.endTimeMinutes, 10 * 60 + 20);
      expect(
        container.read(activeScheduleContextProvider)?.termId,
        _FakeOnboardingRepository.activeTermId,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
      'logout and magic-link relogin do not read a disposed Settings ref',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const session = AppAuthSession(
      userId: _FakeOnboardingRepository.userId,
      email: 'student@example.test',
    );
    final authRepository = FakeAuthRepository(
      initialSession: session,
      authenticatedUserId: _FakeOnboardingRepository.userId,
    );
    final database = local.AppDatabase(NativeDatabase.memory());
    final onboardingRepository = _FakeOnboardingRepository(
      DriftOnboardingLocalStore(database),
    );
    await onboardingRepository.completeOnboarding(
      userId: _FakeOnboardingRepository.userId,
      completion: const OnboardingCompletion(
        idempotencyKey: 'logout-ref-lifecycle',
        userType: OnboardingUserType.undergraduate,
        universityId: _FakeOnboardingRepository.universityId,
        campusId: _FakeOnboardingRepository.campusId,
        entryAcademicYear: 2026,
        termTemplateId: _FakeOnboardingRepository.springTermTemplateId,
        periodTemplateSetId: _FakeOnboardingRepository.periodTemplateSetId,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_deployedProductionTestConfig()),
        appDatabaseProvider.overrideWithValue(database),
        authRepositoryProvider.overrideWithValue(authRepository),
        onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
        remoteScheduleGatewayProvider.overrideWithValue(
          SupabaseScheduleGateway(upsertOverride: (table, payload) async {}),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await authRepository.dispose();
      await database.close();
    });

    await container.read(authStateProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const UniversityScheduleApp(),
      ),
    );
    await _pumpUntil(
      tester,
      finder: find.text('2026 年度'),
      label: 'Home before logout',
    );
    container.read(routerProvider).go('/settings');
    await tester.pumpAndSettle();
    final settingsList = tester.widget<ListView>(find.byType(ListView));
    final settingsChildren =
        (settingsList.childrenDelegate as SliverChildListDelegate).children;
    expect(
      settingsChildren.any(
        (child) => child.key == const Key('settings-environment-mode'),
      ),
      isFalse,
    );
    await tester.scrollUntilVisible(
      find.text('ログアウト'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await _pumpUntil(tester, finder: find.text('ログアウト'), label: 'Settings');
    await tester.tap(find.text('ログアウト'));
    await _pumpUntil(
      tester,
      finder: find.byKey(const Key('sign-in-email')),
      label: 'the sign-in screen after logout',
    );
    expect(container.read(activeScheduleContextProvider), isNull);

    await tester.enterText(
      find.byKey(const Key('sign-in-email')),
      session.email!,
    );
    await tester.tap(find.byKey(const Key('sign-in-email-button')));
    await _pumpUntil(
      tester,
      finder: find.text('2026 年度'),
      label: 'Home after a magic-link login following logout',
    );
    expect(
      container.read(activeScheduleContextProvider)?.ownerUserId,
      _FakeOnboardingRepository.userId,
    );
  });
}

Finder _onboardingSelector(String keyPrefix) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(keyPrefix),
    description: 'Onboarding selector with key prefix $keyPrefix',
  );
}

Future<void> _scrollOnboardingFormTo(
  WidgetTester tester,
  Finder target,
) async {
  final list = find.byType(ListView);
  for (var attempt = 0; attempt < 30; attempt++) {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target);
      return;
    }
    await tester.drag(list.first, const Offset(0, -280));
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Onboarding form did not build the requested field.');
}

Future<void> _selectTerm(
  WidgetTester tester, {
  required String? currentId,
  required String label,
}) async {
  final selector = find.byKey(ValueKey('onboarding-term-$currentId'));
  await _scrollOnboardingFormTo(tester, selector);
  await tester.tap(selector);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label).last);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpUntil(
  WidgetTester tester, {
  required Finder finder,
  required String label,
}) async {
  for (var index = 0; index < 50; index++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for: $label');
}

String _entryYearText(WidgetTester tester) {
  return tester
      .widget<TextFormField>(find.byKey(const Key('onboarding-entry-year')))
      .controller!
      .text;
}

AppConfig _productionTestConfig() {
  return AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: 'http://127.0.0.1:54321',
    supabasePublishableKey: 'test-publishable-key',
  );
}

AppConfig _deployedProductionTestConfig() {
  return AppConfig.validated(
    environment: 'production',
    demoMode: false,
    supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
    supabasePublishableKey: 'sb_publishable_mobile_test',
    productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
    webBaseUrl: 'https://schedule.example.edu',
    privacyPolicyUrl: 'https://policy.example.edu/privacy',
    termsUrl: 'https://policy.example.edu/terms',
    accountDeletionUrl: 'https://policy.example.edu/account-deletion',
    supportUrl: 'https://support.example.edu/help',
    isReleaseMode: true,
  );
}

SupabaseClient _testSupabaseClient() {
  return SupabaseClient(
    'http://127.0.0.1:54321',
    'test-publishable-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

class _TestLocalStorage extends LocalStorage {
  const _TestLocalStorage();

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

class _FakeOnboardingRepository implements OnboardingRepository {
  _FakeOnboardingRepository(this._localStore);

  static const userId = '4b139415-53cc-4f40-b3ef-c790f2f8cd86';
  static const universityId = '26a72fcd-6e61-5d0f-9c77-350762f2562f';
  static const campusId = '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74';
  static const unavailableCampusId = 'a575fbd2-ee27-54a1-9775-f6ec464e369a';
  static const springTermTemplateId = '657f0bb3-7c10-510d-a8d2-133f0114a2f9';
  static const fallTermTemplateId = '512f0647-9bad-5af7-a66a-4d6070c0f294';
  static const periodTemplateSetId = '253ef732-d142-5abc-bb3a-17a12ff3820b';
  static const activeTermId = '64a38d03-3e69-4334-80e5-cfb230f6387d';
  static const calendarId = '3a9b960b-b885-42cf-bec8-9c22ca2fc916';

  final DriftOnboardingLocalStore _localStore;
  OnboardingProfile _profile = const OnboardingProfile(
    userId: userId,
    status: OnboardingStatus.notStarted,
    displayName: '学生',
  );
  OnboardingCompletion? completion;

  @override
  Future<OnboardingProfile> loadProfile(String requestedUserId) async {
    expect(requestedUserId, userId);
    if (!_profile.hasActiveSchedule) {
      await _localStore.replaceBootstrap(
        OnboardingBootstrapPayload(profile: _profile),
      );
    }
    return _profile;
  }

  @override
  Future<OnboardingCatalog> loadCatalog() async {
    return const OnboardingCatalog(
      universities: [
        UniversityOption(id: universityId, name: '金沢工業大学'),
      ],
      campuses: [
        CampusOption(
          id: campusId,
          universityId: universityId,
          name: '扇が丘',
          isMain: true,
        ),
        CampusOption(
          id: unavailableCampusId,
          universityId: universityId,
          name: 'やつかほリサーチ',
          isMain: false,
        ),
      ],
      termTemplates: [
        TermTemplateOption(
          id: springTermTemplateId,
          universityId: universityId,
          name: '2026年度 前学期',
          academicYear: 2026,
        ),
        TermTemplateOption(
          id: fallTermTemplateId,
          universityId: universityId,
          name: '2026年度 後学期',
          academicYear: 2026,
        ),
      ],
      periodTemplateSets: [
        PeriodTemplateSetOption(
          id: periodTemplateSetId,
          universityId: universityId,
          campusId: campusId,
          name: '2026年度 主時間割（標準）',
          academicYear: 2026,
          isDefault: true,
        ),
      ],
    );
  }

  @override
  Future<OnboardingProfile> completeOnboarding({
    required String userId,
    required OnboardingCompletion completion,
  }) async {
    expect(userId, _FakeOnboardingRepository.userId);
    completion.validate();
    this.completion = completion;
    final now = DateTime.utc(2026, 7, 10, 3);
    final customTerm = completion.customTerm;
    final customPeriods = completion.customPeriods;
    final activeTermName = customTerm?.name ?? '2026年度 前学期';
    final activeTermYear = customTerm?.academicYear ?? 2026;
    _profile = OnboardingProfile(
      userId: _FakeOnboardingRepository.userId,
      status: OnboardingStatus.complete,
      displayName: '学生',
      userType: completion.userType,
      universityId: universityId,
      campusId: completion.campusId,
      entryAcademicYear: completion.entryAcademicYear,
      onboardingStep: 'complete',
      onboardingCompletedAt: now,
      updatedAt: now,
      activeTerm: ActiveTermSummary(
        id: activeTermId,
        name: activeTermName,
        academicYear: activeTermYear,
      ),
      primaryCalendarId: calendarId,
    );
    await _localStore.replaceBootstrap(
      OnboardingBootstrapPayload(
        profile: _profile,
        term: OnboardingTermRecord(
          id: activeTermId,
          universityId: universityId,
          ownerUserId: _FakeOnboardingRepository.userId,
          sourceTemplateId: completion.termTemplateId,
          name: activeTermName,
          academicYear: activeTermYear,
          startDate: customTerm?.startDate ?? DateTime(2026, 4),
          endDate: customTerm?.endDate ?? DateTime(2026, 9, 30),
          termType: customTerm?.type.wireName ?? 'semester',
          updatedAt: now,
          version: 1,
        ),
        calendar: OnboardingCalendarRecord(
          id: calendarId,
          ownerUserId: _FakeOnboardingRepository.userId,
          name: 'マイカレンダー',
          defaultVisibility: 'PRIVATE',
          updatedAt: now,
        ),
        periodSettings: customPeriods == null
            ? [
                OnboardingPeriodSettingRecord(
                  id: 'period-1',
                  ownerUserId: _FakeOnboardingRepository.userId,
                  universityId: universityId,
                  termId: activeTermId,
                  sourceTemplateSetId: completion.periodTemplateSetId,
                  dayOfWeek: 1,
                  periodNo: 1,
                  startTimeMinutes: 8 * 60 + 40,
                  endTimeMinutes: 10 * 60 + 20,
                  updatedAt: now,
                  version: 1,
                ),
                OnboardingPeriodSettingRecord(
                  id: 'period-2',
                  ownerUserId: _FakeOnboardingRepository.userId,
                  universityId: universityId,
                  termId: activeTermId,
                  sourceTemplateSetId: completion.periodTemplateSetId,
                  dayOfWeek: 1,
                  periodNo: 2,
                  startTimeMinutes: 10 * 60 + 35,
                  endTimeMinutes: 12 * 60 + 15,
                  updatedAt: now,
                  version: 1,
                ),
              ]
            : [
                for (var index = 0; index < customPeriods.length; index++)
                  OnboardingPeriodSettingRecord(
                    id: 'custom-period-$index',
                    ownerUserId: _FakeOnboardingRepository.userId,
                    universityId: universityId,
                    termId: activeTermId,
                    sourceTemplateSetId: completion.periodTemplateSetId,
                    dayOfWeek: customPeriods[index].dayOfWeek,
                    periodNo: customPeriods[index].periodNo,
                    startTimeMinutes: customPeriods[index].startTimeMinutes,
                    endTimeMinutes: customPeriods[index].endTimeMinutes,
                    updatedAt: now,
                    version: 1,
                  ),
              ],
      ),
    );
    return _profile;
  }
}

class _RecordingUniversitySettingsRepository
    implements UniversitySettingsRepository {
  UniversityRequestInput? submitted;

  @override
  Future<void> changeUniversity(String universityId) async {}

  @override
  Future<List<UniversityRequestRecord>> loadRequests() async => const [];

  @override
  Future<String> submitRequest(UniversityRequestInput input) async {
    input.validate();
    submitted = input.normalized();
    return '77777777-7777-4777-8777-777777777777';
  }
}

class _SessionSwitchOnboardingRepository implements OnboardingRepository {
  final completionStarted = Completer<void>();
  final completion = Completer<OnboardingProfile>();

  @override
  Future<OnboardingProfile> loadProfile(String userId) async {
    return OnboardingProfile(
      userId: userId,
      status: OnboardingStatus.notStarted,
      displayName: userId,
    );
  }

  @override
  Future<OnboardingCatalog> loadCatalog() async {
    return const OnboardingCatalog(
      universities: [],
      campuses: [],
      termTemplates: [],
      periodTemplateSets: [],
    );
  }

  @override
  Future<OnboardingProfile> completeOnboarding({
    required String userId,
    required OnboardingCompletion completion,
  }) {
    if (!completionStarted.isCompleted) completionStarted.complete();
    return this.completion.future;
  }
}
