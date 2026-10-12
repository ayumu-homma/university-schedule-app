import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/app/navigation_guard.dart';
import 'package:university_schedule_mobile/app/router.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/onboarding/application/onboarding_providers.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_repository.dart';
import 'package:university_schedule_mobile/features/term_period/application/term_period_providers.dart';
import 'package:university_schedule_mobile/features/term_period/domain/term_period_models.dart';
import 'package:university_schedule_mobile/features/term_period/domain/term_period_repository.dart';
import 'package:university_schedule_mobile/features/term_period/presentation/term_period_management_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  testWidgets('shows current term periods and confirms an active-term switch',
      (tester) async {
    await _useTallSurface(tester);
    final harness = _TermPeriodHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('2026年度 前期'));
    await _pumpUntil(tester, find.text('月曜 第1時限'));

    expect(find.text('月曜 第1時限'), findsOneWidget);
    expect(find.text('09:00 〜 10:20'), findsOneWidget);
    expect(find.text('placeholder'), findsNothing);

    await _scrollPageTo(
      tester,
      find.byKey(
        const ValueKey('activate-term-${_TermPeriodHarness.fallTermId}'),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey('activate-term-${_TermPeriodHarness.fallTermId}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('この学期を有効にしますか？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-activate-personal-term')));
    await _pumpUntilCondition(
      tester,
      () => harness.repository.activeTermId == _TermPeriodHarness.fallTermId,
    );
    await _pumpUntil(
      tester,
      find.textContaining('2026年度 後期を現在の学期にしました'),
    );

    expect(harness.repository.activeTermId, _TermPeriodHarness.fallTermId);
    expect(find.textContaining('2026年度 後期を現在の学期にしました'), findsOneWidget);
  });

  testWidgets(
    'production router keeps the term-period route during active-term profile refresh',
    (tester) async {
      await _useTallSurface(tester);
      final harness = _ProductionRouterTermPeriodHarness();
      try {
        await harness.container.read(authStateProvider.future);
        final initialProfile =
            await harness.container.read(onboardingControllerProvider.future);
        expect(initialProfile?.activeTerm?.id, _TermPeriodHarness.springTermId);

        final router = harness.container.read(routerProvider);
        router.go('/university/term-periods');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: harness.container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await _pumpUntil(tester, find.text('2026年度 前期'));
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/university/term-periods',
        );

        harness.onboardingRepository.holdRefreshes = true;
        await _scrollPageTo(
          tester,
          find.byKey(
            const ValueKey('activate-term-${_TermPeriodHarness.fallTermId}'),
          ),
        );
        await tester.tap(
          find.byKey(
            const ValueKey('activate-term-${_TermPeriodHarness.fallTermId}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const Key('confirm-activate-personal-term')));
        await _pumpUntilCondition(
          tester,
          () => harness.onboardingRepository.refreshStarted.isCompleted,
        );

        expect(harness.container.read(onboardingControllerProvider).isLoading,
            isTrue);
        expect(
          harness.container.read(onboardingGateProvider).valueOrNull,
          OnboardingGateStatus.completed,
        );
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/university/term-periods',
        );

        harness.onboardingRepository.releaseRefresh();
        await _pumpUntilCondition(
          tester,
          () =>
              harness.container
                  .read(onboardingControllerProvider)
                  .valueOrNull
                  ?.activeTerm
                  ?.id ==
              _TermPeriodHarness.fallTermId,
        );
        expect(
          harness.container.read(activeScheduleContextProvider)?.termId,
          _TermPeriodHarness.fallTermId,
        );
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/university/term-periods',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await harness.dispose();
      }
    },
  );

  testWidgets('creates a custom term with manually edited period rows',
      (tester) async {
    await tester.binding.setSurfaceSize(
      const Size(1080 / 2.625, 2424 / 2.625),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = _TermPeriodHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('2026年度 前期'));

    await tester.tap(find.byKey(const Key('create-personal-term-button')));
    await tester.pumpAndSettle();
    await _scrollDialogTo(tester, find.text('カスタム入力'));
    await tester.tap(find.text('カスタム入力'));
    await tester.pumpAndSettle();
    await _scrollDialogTo(tester, find.byKey(const Key('custom-term-type')));
    await tester.tap(find.byKey(const Key('custom-term-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通年').last);
    await tester.pumpAndSettle();
    await _scrollDialogTo(tester, find.byKey(const Key('custom-term-name')));
    await tester.enterText(find.byKey(const Key('custom-term-name')), '秋の集中学期');
    await _scrollDialogTo(tester, find.byKey(const Key('custom-term-year')));
    await tester.enterText(find.byKey(const Key('custom-term-year')), '2026');
    await _scrollDialogTo(
      tester,
      find.byKey(const Key('custom-term-start-date')),
    );
    await tester.enterText(
      find.byKey(const Key('custom-term-start-date')),
      '2026-10-01',
    );
    await _scrollDialogTo(
        tester, find.byKey(const Key('custom-term-end-date')));
    await tester.enterText(
      find.byKey(const Key('custom-term-end-date')),
      '2026-12-20',
    );
    await _scrollDialogTo(tester, find.text('時限を手動編集'));
    await tester.tap(find.text('時限を手動編集'));
    await tester.pumpAndSettle();
    await _scrollDialogTo(
        tester, find.byKey(const Key('add-custom-period-button')));
    await tester.tap(find.byKey(const Key('add-custom-period-button')));
    await _scrollDialogTo(
      tester,
      find.byKey(const ValueKey('period-draft-day-0')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('period-draft-day-0')),
      '2',
    );
    await _scrollDialogTo(
      tester,
      find.byKey(const ValueKey('period-draft-number-0')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('period-draft-number-0')),
      '1',
    );
    await _scrollDialogTo(
      tester,
      find.byKey(const ValueKey('period-draft-start-0')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('period-draft-start-0')),
      '08:50',
    );
    await _scrollDialogTo(
      tester,
      find.byKey(const ValueKey('period-draft-end-0')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('period-draft-end-0')),
      '10:10',
    );
    await _scrollDialogTo(
      tester,
      find.byKey(const Key('draft-create-personal-term-button')),
    );
    await tester
        .tap(find.byKey(const Key('draft-create-personal-term-button')));
    await tester.pumpAndSettle();
    expect(find.text('新しい学期を作成しますか？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-create-personal-term')));
    await _pumpUntil(tester, find.text('秋の集中学期'));

    final created = harness.repository.createdInput;
    expect(created, isA<PersonalTermCreateInput>());
    expect(created!.customType, PersonalTermType.yearRound);
    expect(created.customName, '秋の集中学期');
    expect(created.periodSettings, isA<CustomPeriodSettingsInput>());
    final periods =
        (created.periodSettings as CustomPeriodSettingsInput).periods;
    expect(periods.single.dayOfWeek, 2);
    expect(periods.single.startTimeMinutes, 8 * 60 + 50);
  });

  testWidgets(
      'create action remains reachable after delayed full period snapshot expands active card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 732));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = _TermPeriodHarness();
    harness.repository.delayFullSpringPeriodSnapshot();
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('2026年度 前期'));
    expect(find.byType(CircularProgressIndicator), findsAtLeastNWidgets(1));

    harness.repository.releaseDelayedPeriodLoad();
    await _pumpUntil(tester, find.text('月曜 第1時限'));
    expect(find.byKey(const Key('create-personal-term-button')), findsNothing);

    await _scrollPageTo(
      tester,
      find.byKey(const Key('create-personal-term-button')),
    );
    expect(
        find.byKey(const Key('create-personal-term-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-personal-term-button')));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AlertDialog, '学期を追加'), findsOneWidget);
  });

  testWidgets(
      'replaces current term periods from an eligible template after confirmation',
      (tester) async {
    await _useTallSurface(tester);
    final harness = _TermPeriodHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('2026年度 前期'));
    await _pumpUntil(tester, find.text('月曜 第1時限'));

    await _scrollPageTo(
      tester,
      find.byKey(const Key('edit-active-period-settings')),
    );
    await tester.tap(find.byKey(const Key('edit-active-period-settings')));
    await tester.pumpAndSettle();
    expect(find.text('時限設定を編集'), findsOneWidget);
    await tester
        .tap(find.byKey(const Key('save-period-settings-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-replace-personal-periods')));
    await _pumpUntilCondition(
      tester,
      () => harness.repository.replacedInput != null,
    );

    expect(harness.repository.replacedTermId, _TermPeriodHarness.springTermId);
    expect(
        harness.repository.replacedInput, isA<PeriodTemplateSettingsInput>());
  });

  testWidgets(
      'keeps existing manual periods custom when one template is available',
      (tester) async {
    await _useTallSurface(tester);
    final harness = _TermPeriodHarness();
    harness.repository.makeSpringPeriodsManual();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('2026年度 前期'));
    await _pumpUntil(tester, find.text('月曜 第1時限'));

    await _scrollPageTo(
      tester,
      find.byKey(const Key('edit-active-period-settings')),
    );
    await tester.tap(find.byKey(const Key('edit-active-period-settings')));
    await tester.pumpAndSettle();
    expect(find.text('時限を手動編集'), findsOneWidget);
    expect(find.byKey(const Key('period-template-set-select')), findsNothing);

    await _scrollDialogTo(
      tester,
      find.byKey(const Key('save-period-settings-draft-button')),
    );
    await tester
        .tap(find.byKey(const Key('save-period-settings-draft-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-replace-personal-periods')));
    await _pumpUntilCondition(
      tester,
      () => harness.repository.replacedInput != null,
    );

    final input = harness.repository.replacedInput as CustomPeriodSettingsInput;
    expect(input.periods, hasLength(1));
    expect(input.periods.single.startTimeMinutes, 9 * 60);
    expect(input.periods.single.endTimeMinutes, 10 * 60 + 20);
  });
}

class _TermPeriodHarness {
  _TermPeriodHarness()
      : repository = _FakeTermPeriodRepository(),
        authRepository = FakeAuthRepository(
          initialSession: const AppAuthSession(
            userId: userId,
            email: 'student@example.test',
          ),
        );

  static const userId = '11111111-1111-4111-8111-111111111111';
  static const universityId = '22222222-2222-4222-8222-222222222222';
  static const campusId = '33333333-3333-4333-8333-333333333333';
  static const springTermId = '44444444-4444-4444-8444-444444444444';
  static const fallTermId = '55555555-5555-4555-8555-555555555555';
  static const periodTemplateSetId = '66666666-6666-4666-8666-666666666666';

  final _FakeTermPeriodRepository repository;
  final FakeAuthRepository authRepository;

  Widget widget() {
    final onboardingRepository = _FakeOnboardingRepository(repository);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const TermPeriodManagementScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/timetable',
          builder: (_, __) => const Scaffold(body: Text('timetable')),
        ),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const Scaffold(body: Text('assignments')),
        ),
        GoRoute(
          path: '/calendar',
          builder: (_, __) => const Scaffold(body: Text('calendar')),
        ),
        GoRoute(
          path: '/shared',
          builder: (_, __) => const Scaffold(body: Text('shared')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.validated(
            environment: 'test',
            demoMode: false,
            supabaseUrl: 'http://127.0.0.1:54321',
            supabasePublishableKey: 'test-publishable-key',
          ),
        ),
        authRepositoryProvider.overrideWithValue(authRepository),
        onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
        termPeriodRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> dispose() async {
    repository.releaseDelayedPeriodLoad();
    await authRepository.dispose();
  }
}

class _ProductionRouterTermPeriodHarness {
  _ProductionRouterTermPeriodHarness()
      : repository = _FakeTermPeriodRepository(),
        authRepository = FakeAuthRepository(
          initialSession: const AppAuthSession(
            userId: _TermPeriodHarness.userId,
            email: 'student@example.test',
          ),
        ) {
    onboardingRepository = _DelayedRefreshOnboardingRepository(repository);
    container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.validated(
            environment: 'test',
            demoMode: false,
            supabaseUrl: 'http://127.0.0.1:54321',
            supabasePublishableKey: 'test-publishable-key',
          ),
        ),
        authRepositoryProvider.overrideWithValue(authRepository),
        onboardingRepositoryProvider.overrideWithValue(onboardingRepository),
        termPeriodRepositoryProvider.overrideWithValue(repository),
      ],
    );
  }

  final _FakeTermPeriodRepository repository;
  final FakeAuthRepository authRepository;
  late final _DelayedRefreshOnboardingRepository onboardingRepository;
  late final ProviderContainer container;

  Future<void> dispose() async {
    container.dispose();
    await authRepository.dispose();
  }
}

class _FakeOnboardingRepository implements OnboardingRepository {
  const _FakeOnboardingRepository(this._termRepository);

  final _FakeTermPeriodRepository _termRepository;

  @override
  Future<OnboardingProfile> loadProfile(String userId) async {
    final active = _termRepository.activeTerm;
    return OnboardingProfile(
      userId: userId,
      status: OnboardingStatus.complete,
      userType: OnboardingUserType.undergraduate,
      universityId: _TermPeriodHarness.universityId,
      campusId: _TermPeriodHarness.campusId,
      onboardingStep: 'complete',
      activeTerm: active == null
          ? null
          : ActiveTermSummary(
              id: active.id,
              name: active.name,
              academicYear: active.academicYear,
            ),
      primaryCalendarId: '77777777-7777-4777-8777-777777777777',
    );
  }

  @override
  Future<OnboardingCatalog> loadCatalog() async {
    return const OnboardingCatalog(
      universities: [
        UniversityOption(
          id: _TermPeriodHarness.universityId,
          name: '金沢工業大学',
        ),
      ],
      campuses: [
        CampusOption(
          id: _TermPeriodHarness.campusId,
          universityId: _TermPeriodHarness.universityId,
          name: '扇が丘',
          isMain: true,
        ),
      ],
      termTemplates: [
        TermTemplateOption(
          id: '88888888-8888-4888-8888-888888888888',
          universityId: _TermPeriodHarness.universityId,
          name: '2027年度 前期',
          academicYear: 2027,
        ),
      ],
      periodTemplateSets: [
        PeriodTemplateSetOption(
          id: _TermPeriodHarness.periodTemplateSetId,
          universityId: _TermPeriodHarness.universityId,
          campusId: _TermPeriodHarness.campusId,
          name: '2026年度 主時間割（標準）',
          academicYear: 2026,
          isDefault: true,
          userType: OnboardingUserType.undergraduate,
        ),
      ],
    );
  }

  @override
  Future<OnboardingProfile> completeOnboarding({
    required String userId,
    required OnboardingCompletion completion,
  }) {
    throw UnimplementedError();
  }
}

class _DelayedRefreshOnboardingRepository extends _FakeOnboardingRepository {
  _DelayedRefreshOnboardingRepository(super._termRepository);

  final refreshStarted = Completer<void>();
  final _allowRefresh = Completer<void>();
  bool holdRefreshes = false;

  @override
  Future<OnboardingProfile> loadProfile(String userId) async {
    if (holdRefreshes) {
      if (!refreshStarted.isCompleted) refreshStarted.complete();
      await _allowRefresh.future;
    }
    return super.loadProfile(userId);
  }

  void releaseRefresh() {
    holdRefreshes = false;
    if (!_allowRefresh.isCompleted) _allowRefresh.complete();
  }
}

class _FakeTermPeriodRepository implements TermPeriodRepository {
  _FakeTermPeriodRepository()
      : _terms = [
          _term(
            id: _TermPeriodHarness.springTermId,
            name: '2026年度 前期',
            type: PersonalTermType.semester,
            start: DateTime.utc(2026, 4, 1),
            end: DateTime.utc(2026, 9, 30),
          ),
          _term(
            id: _TermPeriodHarness.fallTermId,
            name: '2026年度 後期',
            type: PersonalTermType.semester,
            start: DateTime.utc(2026, 10, 1),
            end: DateTime.utc(2027, 3, 31),
          ),
        ],
        _periods = {
          _TermPeriodHarness.springTermId: [
            PersonalPeriodSetting(
              id: '99999999-9999-4999-8999-999999999991',
              ownerUserId: _TermPeriodHarness.userId,
              universityId: _TermPeriodHarness.universityId,
              termId: _TermPeriodHarness.springTermId,
              sourceTemplateSetId: _TermPeriodHarness.periodTemplateSetId,
              dayOfWeek: 1,
              periodNo: 1,
              startTimeMinutes: 9 * 60,
              endTimeMinutes: 10 * 60 + 20,
              updatedAt: DateTime.utc(2026, 7, 18),
              version: 1,
            ),
          ],
          _TermPeriodHarness.fallTermId: [
            PersonalPeriodSetting(
              id: '99999999-9999-4999-8999-999999999992',
              ownerUserId: _TermPeriodHarness.userId,
              universityId: _TermPeriodHarness.universityId,
              termId: _TermPeriodHarness.fallTermId,
              dayOfWeek: 2,
              periodNo: 1,
              startTimeMinutes: 8 * 60 + 50,
              endTimeMinutes: 10 * 60 + 10,
              updatedAt: DateTime.utc(2026, 7, 18),
              version: 1,
            ),
          ],
        };

  final List<PersonalTerm> _terms;
  final Map<String, List<PersonalPeriodSetting>> _periods;
  Completer<void>? _periodLoadGate;
  String? activeTermId = _TermPeriodHarness.springTermId;
  PersonalTermCreateInput? createdInput;
  String? replacedTermId;
  PeriodSettingsInput? replacedInput;

  PersonalTerm? get activeTerm {
    for (final term in _terms) {
      if (term.id == activeTermId) return term;
    }
    return null;
  }

  void delayFullSpringPeriodSnapshot() {
    _periodLoadGate = Completer<void>();
    _periods[_TermPeriodHarness.springTermId] = [
      for (var index = 0; index < 25; index++)
        PersonalPeriodSetting(
          id: 'delayed-period-$index',
          ownerUserId: _TermPeriodHarness.userId,
          universityId: _TermPeriodHarness.universityId,
          termId: _TermPeriodHarness.springTermId,
          sourceTemplateSetId: _TermPeriodHarness.periodTemplateSetId,
          dayOfWeek: 1 + (index ~/ 5),
          periodNo: 1 + (index % 5),
          startTimeMinutes: 8 * 60 + (index % 5) * 90,
          endTimeMinutes: 9 * 60 + 20 + (index % 5) * 90,
          updatedAt: DateTime.utc(2026, 7, 18),
          version: 1,
        ),
    ];
  }

  void releaseDelayedPeriodLoad() {
    final gate = _periodLoadGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void makeSpringPeriodsManual() {
    _periods[_TermPeriodHarness.springTermId] = [
      PersonalPeriodSetting(
        id: '99999999-9999-4999-8999-999999999993',
        ownerUserId: _TermPeriodHarness.userId,
        universityId: _TermPeriodHarness.universityId,
        termId: _TermPeriodHarness.springTermId,
        dayOfWeek: 1,
        periodNo: 1,
        startTimeMinutes: 9 * 60,
        endTimeMinutes: 10 * 60 + 20,
        updatedAt: DateTime.utc(2026, 7, 18),
        version: 1,
      ),
    ];
  }

  @override
  Future<void> activateTerm(String termId) async {
    activeTermId = termId;
  }

  @override
  Future<PersonalTermMutation> createTerm(PersonalTermCreateInput input) async {
    createdInput = input;
    const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final term = PersonalTerm(
      id: id,
      ownerUserId: _TermPeriodHarness.userId,
      universityId: _TermPeriodHarness.universityId,
      name: input.customName ?? 'テンプレート学期',
      academicYear: input.customAcademicYear ?? 2027,
      startDate: input.customStartDate ?? DateTime.utc(2027, 4, 1),
      endDate: input.customEndDate ?? DateTime.utc(2027, 9, 30),
      type: input.customType ?? PersonalTermType.semester,
      updatedAt: DateTime.utc(2026, 7, 18),
      version: 1,
    );
    _terms.add(term);
    _periods[id] = _settingsForInput(id, input.periodSettings);
    if (input.makeActive) activeTermId = id;
    return PersonalTermMutation(termId: id, activeTermId: activeTermId!);
  }

  @override
  Future<PersonalTermPeriodSnapshot> load() async {
    return PersonalTermPeriodSnapshot(
      ownerUserId: _TermPeriodHarness.userId,
      universityId: _TermPeriodHarness.universityId,
      activeTermId: activeTermId,
      terms: List.unmodifiable(_terms),
    );
  }

  @override
  Future<List<PersonalPeriodSetting>> loadPeriods(String termId) async {
    if (termId == _TermPeriodHarness.springTermId) {
      await _periodLoadGate?.future;
    }
    return List.unmodifiable(_periods[termId] ?? const []);
  }

  @override
  Future<int> replacePeriods({
    required String termId,
    required PeriodSettingsInput input,
  }) async {
    replacedTermId = termId;
    replacedInput = input;
    _periods[termId] = _settingsForInput(termId, input);
    return _periods[termId]!.length;
  }

  List<PersonalPeriodSetting> _settingsForInput(
    String termId,
    PeriodSettingsInput input,
  ) {
    final drafts = switch (input) {
      CustomPeriodSettingsInput(:final periods) => periods,
      PeriodTemplateSettingsInput() => const [
          PersonalPeriodDraft(
            dayOfWeek: 1,
            periodNo: 1,
            startTimeMinutes: 9 * 60,
            endTimeMinutes: 10 * 60 + 20,
          ),
        ],
    };
    return [
      for (var index = 0; index < drafts.length; index++)
        PersonalPeriodSetting(
          id: 'period-$termId-$index',
          ownerUserId: _TermPeriodHarness.userId,
          universityId: _TermPeriodHarness.universityId,
          termId: termId,
          sourceTemplateSetId: input.templateSetId,
          dayOfWeek: drafts[index].dayOfWeek,
          periodNo: drafts[index].periodNo,
          startTimeMinutes: drafts[index].startTimeMinutes,
          endTimeMinutes: drafts[index].endTimeMinutes,
          updatedAt: DateTime.utc(2026, 7, 18),
          version: 1,
        ),
    ];
  }

  static PersonalTerm _term({
    required String id,
    required String name,
    required PersonalTermType type,
    required DateTime start,
    required DateTime end,
  }) {
    return PersonalTerm(
      id: id,
      ownerUserId: _TermPeriodHarness.userId,
      universityId: _TermPeriodHarness.universityId,
      name: name,
      academicYear: 2026,
      startDate: start,
      endDate: end,
      type: type,
      updatedAt: DateTime.utc(2026, 7, 18),
      version: 1,
    );
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for the expected widget.');
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for the expected state.');
}

Future<void> _scrollDialogTo(WidgetTester tester, Finder finder) {
  return tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).last,
  );
}

Future<void> _scrollPageTo(WidgetTester tester, Finder finder) {
  return tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('term-period-management-list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

Future<void> _useTallSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}
