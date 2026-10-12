import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/onboarding/application/onboarding_providers.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_repository.dart';
import 'package:university_schedule_mobile/features/university/application/university_settings_providers.dart';
import 'package:university_schedule_mobile/features/university/domain/university_settings_models.dart';
import 'package:university_schedule_mobile/features/university/domain/university_settings_repository.dart';
import 'package:university_schedule_mobile/features/university/presentation/university_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  test('university request input normalizes and validates HTTPS URL', () {
    const input = UniversityRequestInput(
      name: '  北陸テスト大学  ',
      prefecture: '  石川県 ',
      officialUrl: ' https://university.example.test ',
    );

    input.validate();
    final normalized = input.normalized();
    expect(normalized.name, '北陸テスト大学');
    expect(normalized.prefecture, '石川県');
    expect(normalized.officialUrl, 'https://university.example.test');
    expect(
      () => const UniversityRequestInput(
        name: '北陸テスト大学',
        officialUrl: 'http://university.example.test',
      ).validate(),
      throwsArgumentError,
    );
  });

  testWidgets(
    'renders authenticated university data and submits a bounded request',
    (tester) async {
      final repository = _FakeUniversitySettingsRepository();
      final harness = _UniversityHarness(repository);
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.widget());
      await _pumpUntil(tester, find.text('金沢工業大学'));

      expect(find.text('金沢工業大学'), findsOneWidget);
      expect(find.text('扇が丘'), findsOneWidget);
      expect(find.text('認証済み'), findsOneWidget);
      expect(find.textContaining('2026年度 前学期'), findsOneWidget);
      expect(find.text('東京サンプル大学'), findsNothing);
      expect(find.textContaining('placeholder'), findsNothing);

      final requestButton = find.byKey(
        const Key('request-university-button'),
      );
      await tester.ensureVisible(requestButton);
      await tester.drag(
        find.byKey(const Key('university-settings-list')),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      await tester.tap(requestButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('university-request-name')),
        '  北陸テスト大学  ',
      );
      await tester.enterText(
        find.byKey(const Key('university-request-prefecture')),
        '石川県',
      );
      await tester.enterText(
        find.byKey(const Key('university-request-url')),
        'https://university.example.test',
      );
      await tester.tap(
        find.byKey(const Key('submit-university-request-button')),
      );
      await _pumpUntil(tester, find.text('大学追加申請を受け付けました'));

      expect(repository.submitted, isNotNull);
      expect(repository.submitted!.name, '北陸テスト大学');
      expect(repository.submitted!.prefecture, '石川県');
      await _pumpUntil(tester, find.text('北陸テスト大学'));
      expect(find.text('審査中'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps a failed university request in the dialog without exposing raw errors',
    (tester) async {
      final repository = _FakeUniversitySettingsRepository(
        submitError: StateError('private transport diagnostic'),
      );
      final harness = _UniversityHarness(repository);
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.widget());
      await _pumpUntil(tester, find.text('金沢工業大学'));

      final requestButton = find.byKey(
        const Key('request-university-button'),
      );
      await tester.ensureVisible(requestButton);
      await tester.drag(
        find.byKey(const Key('university-settings-list')),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      await tester.tap(requestButton);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('university-request-name')),
        '北陸テスト大学',
      );
      await tester.tap(
        find.byKey(const Key('submit-university-request-button')),
      );
      await _pumpUntil(
        tester,
        find.text('大学追加申請を送信できませんでした'),
      );

      expect(
        find.byKey(const Key('submit-university-request-button')),
        findsOneWidget,
      );
      expect(find.textContaining('private transport diagnostic'), findsNothing);
      expect(repository.submitted, isNull);
      expect(repository.requests, isEmpty);
    },
  );

  testWidgets('searches nationwide catalog and confirms university change',
      (tester) async {
    final repository = _FakeUniversitySettingsRepository();
    final harness = _UniversityHarness(repository);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget());
    await _pumpUntil(tester, find.text('金沢工業大学'));

    final changeButton = find.byKey(const Key('change-university-button'));
    await tester.ensureVisible(changeButton);
    await tester.tap(changeButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '京都');
    await tester.pumpAndSettle();
    await tester.tap(find.text('京都テスト大学'));
    await tester.pumpAndSettle();
    expect(find.text('所属大学を変更しますか？'), findsOneWidget);
    await tester.tap(find.text('変更して再設定'));
    await _pumpUntil(tester, find.text('初期設定'));

    expect(
        repository.changedUniversityId, _UniversityHarness.otherUniversityId);
  });
}

class _UniversityHarness {
  _UniversityHarness(this.universityRepository)
      : authRepository = FakeAuthRepository(
          initialSession: const AppAuthSession(
            userId: userId,
            email: 'student@example.test',
          ),
        ),
        database = AppDatabase(NativeDatabase.memory());

  static const userId = '11111111-1111-4111-8111-111111111111';
  static const universityId = '22222222-2222-4222-8222-222222222222';
  static const otherUniversityId = '33333333-3333-4333-8333-333333333333';
  static const campusId = '44444444-4444-4444-8444-444444444444';

  final _FakeUniversitySettingsRepository universityRepository;
  final FakeAuthRepository authRepository;
  final AppDatabase database;

  Widget widget() {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const UniversityScreen()),
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const Scaffold(body: Text('初期設定')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('設定')),
        ),
        GoRoute(
          path: '/courses/manual',
          builder: (_, __) => const Scaffold(body: Text('授業を追加')),
        ),
        GoRoute(
          path: '/assignments/new',
          builder: (_, __) => const Scaffold(body: Text('課題を追加')),
        ),
        GoRoute(
          path: '/exams/new',
          builder: (_, __) => const Scaffold(body: Text('テストを追加')),
        ),
        GoRoute(
          path: '/events/new',
          builder: (_, __) => const Scaffold(body: Text('予定を追加')),
        ),
        GoRoute(
          path: '/calendar',
          builder: (_, __) => const Scaffold(body: Text('カレンダー')),
        ),
        GoRoute(
          path: '/shared',
          builder: (_, __) => const Scaffold(body: Text('共有')),
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
        appDatabaseProvider.overrideWithValue(database),
        authRepositoryProvider.overrideWithValue(authRepository),
        onboardingRepositoryProvider.overrideWithValue(
          const _FakeOnboardingRepository(),
        ),
        universitySettingsRepositoryProvider.overrideWithValue(
          universityRepository,
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> dispose() async {
    await authRepository.dispose();
    await database.close();
  }
}

class _FakeOnboardingRepository implements OnboardingRepository {
  const _FakeOnboardingRepository();

  @override
  Future<OnboardingProfile> loadProfile(String userId) async {
    return OnboardingProfile(
      userId: userId,
      status: OnboardingStatus.complete,
      displayName: '学生',
      userType: OnboardingUserType.undergraduate,
      universityId: _UniversityHarness.universityId,
      campusId: _UniversityHarness.campusId,
      universityVerified: true,
      onboardingStep: 'complete',
      activeTerm: const ActiveTermSummary(
        id: '55555555-5555-4555-8555-555555555555',
        name: '2026年度 前学期',
        academicYear: 2026,
      ),
      primaryCalendarId: '66666666-6666-4666-8666-666666666666',
    );
  }

  @override
  Future<OnboardingCatalog> loadCatalog() async {
    return const OnboardingCatalog(
      universities: [
        UniversityOption(
          id: _UniversityHarness.universityId,
          name: '金沢工業大学',
        ),
        UniversityOption(
          id: _UniversityHarness.otherUniversityId,
          name: '京都テスト大学',
        ),
      ],
      campuses: [
        CampusOption(
          id: _UniversityHarness.campusId,
          universityId: _UniversityHarness.universityId,
          name: '扇が丘',
          isMain: true,
        ),
      ],
      termTemplates: [],
      periodTemplateSets: [],
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

class _FakeUniversitySettingsRepository
    implements UniversitySettingsRepository {
  _FakeUniversitySettingsRepository({this.submitError});

  final requests = <UniversityRequestRecord>[];
  final Object? submitError;
  UniversityRequestInput? submitted;
  String? changedUniversityId;

  @override
  Future<void> changeUniversity(String universityId) async {
    changedUniversityId = universityId;
  }

  @override
  Future<List<UniversityRequestRecord>> loadRequests() async {
    return List.unmodifiable(requests);
  }

  @override
  Future<String> submitRequest(UniversityRequestInput input) async {
    input.validate();
    if (submitError != null) throw submitError!;
    submitted = input.normalized();
    requests.add(
      UniversityRequestRecord(
        id: '77777777-7777-4777-8777-777777777777',
        name: submitted!.name,
        prefecture: submitted!.prefecture,
        officialUrl: submitted!.officialUrl,
        status: UniversityRequestStatus.pending,
        createdAt: DateTime.utc(2026, 7, 18),
      ),
    );
    return requests.single.id;
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for the expected widget.');
}
