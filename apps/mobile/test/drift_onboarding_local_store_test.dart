import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/onboarding/data/drift_onboarding_local_store.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';

void main() {
  late AppDatabase database;
  late DriftOnboardingLocalStore store;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    store = DriftOnboardingLocalStore(database);
  });

  tearDown(() => database.close());

  test('restores a complete bootstrap only for its authenticated owner',
      () async {
    await _writeCompleteBootstrap(store);

    final restored = await store.loadCachedProfile(_ownerUserId);

    expect(restored, isNotNull);
    expect(restored!.userId, _ownerUserId);
    expect(restored.status, OnboardingStatus.complete);
    expect(restored.activeTerm?.id, _termId);
    expect(restored.activeTerm?.academicYear, 2026);
    expect(restored.primaryCalendarId, _calendarId);
    expect(await store.loadCachedProfile('another-user'), isNull);
  });

  test('rejects a complete bootstrap missing its active period settings',
      () async {
    await _writeCompleteBootstrap(store);
    await database.delete(database.periodSettings).go();

    expect(await store.loadCachedProfile(_ownerUserId), isNull);
  });
}

const _ownerUserId = 'offline-owner';
const _universityId = 'university-offline';
const _termId = 'term-offline';
const _calendarId = 'calendar-offline';

Future<void> _writeCompleteBootstrap(DriftOnboardingLocalStore store) {
  final updatedAt = DateTime.utc(2026, 4, 1, 0, 0);
  return store.replaceBootstrap(
    OnboardingBootstrapPayload(
      profile: OnboardingProfile(
        userId: _ownerUserId,
        status: OnboardingStatus.complete,
        displayName: 'オフライン学生',
        userType: OnboardingUserType.undergraduate,
        universityId: _universityId,
        entryAcademicYear: 2026,
        onboardingStep: 'complete',
        onboardingCompletedAt: updatedAt,
        updatedAt: updatedAt,
        activeTerm: const ActiveTermSummary(
          id: _termId,
          name: '2026年度 前学期',
          academicYear: 2026,
        ),
        primaryCalendarId: _calendarId,
      ),
      term: OnboardingTermRecord(
        id: _termId,
        universityId: _universityId,
        ownerUserId: _ownerUserId,
        name: '2026年度 前学期',
        academicYear: 2026,
        startDate: DateTime.utc(2026, 4, 1),
        endDate: DateTime.utc(2026, 9, 30),
        termType: 'semester',
        updatedAt: updatedAt,
        version: 1,
      ),
      calendar: OnboardingCalendarRecord(
        id: _calendarId,
        ownerUserId: _ownerUserId,
        name: '個人予定',
        defaultVisibility: 'PRIVATE',
        updatedAt: updatedAt,
      ),
      periodSettings: [
        OnboardingPeriodSettingRecord(
          id: 'period-offline',
          ownerUserId: _ownerUserId,
          universityId: _universityId,
          termId: _termId,
          dayOfWeek: DateTime.monday,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60 + 30,
          updatedAt: updatedAt,
          version: 1,
        ),
      ],
    ),
  );
}
