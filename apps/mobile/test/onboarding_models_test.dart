import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';

void main() {
  const termTemplateId = 'term-template';
  const periodTemplateSetId = 'period-template';

  test('template term with manual periods preserves RPC-safe period rows', () {
    const completion = OnboardingCompletion(
      idempotencyKey: 'template-manual-periods',
      userType: OnboardingUserType.undergraduate,
      universityId: 'university',
      entryAcademicYear: 2026,
      termTemplateId: termTemplateId,
      customPeriods: [
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60 + 20,
        ),
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 2,
          startTimeMinutes: 10 * 60 + 30,
          endTimeMinutes: 11 * 60 + 50,
        ),
      ],
    );

    expect(completion.validate, returnsNormally);
    expect(completion.usesTermTemplate, isTrue);
    expect(completion.usesPeriodTemplate, isFalse);
    expect(completion.customPeriodsRpc, [
      {
        'day_of_week': 1,
        'period_no': 1,
        'start_time': '09:00',
        'end_time': '10:20',
      },
      {
        'day_of_week': 1,
        'period_no': 2,
        'start_time': '10:30',
        'end_time': '11:50',
      },
    ]);
  });

  test('custom term with a template period set keeps date-only values', () {
    final customTerm = _customTerm();
    final completion = OnboardingCompletion(
      idempotencyKey: 'custom-term-template-periods',
      userType: OnboardingUserType.graduate,
      universityId: 'university',
      entryAcademicYear: 2026,
      customTerm: customTerm,
      periodTemplateSetId: periodTemplateSetId,
    );

    expect(completion.validate, returnsNormally);
    expect(completion.usesTermTemplate, isFalse);
    expect(completion.usesPeriodTemplate, isTrue);
    expect(customTerm.startDateWire, '2026-08-01');
    expect(customTerm.endDateWire, '2026-08-31');
  });

  test('completion rejects ambiguous term and period sources', () {
    final ambiguousTerm = OnboardingCompletion(
      idempotencyKey: 'ambiguous-term',
      userType: OnboardingUserType.undergraduate,
      universityId: 'university',
      entryAcademicYear: 2026,
      termTemplateId: termTemplateId,
      customTerm: _customTerm(),
      periodTemplateSetId: periodTemplateSetId,
    );
    const ambiguousPeriods = OnboardingCompletion(
      idempotencyKey: 'ambiguous-periods',
      userType: OnboardingUserType.undergraduate,
      universityId: 'university',
      entryAcademicYear: 2026,
      termTemplateId: termTemplateId,
      periodTemplateSetId: periodTemplateSetId,
      customPeriods: [
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60,
        ),
      ],
    );

    expect(ambiguousTerm.validate, throwsArgumentError);
    expect(ambiguousPeriods.validate, throwsArgumentError);
  });

  test('manual period validation rejects duplicate slots and overlaps', () {
    final duplicateSlot = OnboardingCompletion(
      idempotencyKey: 'duplicate-slot',
      userType: OnboardingUserType.other,
      universityId: 'university',
      entryAcademicYear: 2026,
      customTerm: _customTerm(),
      customPeriods: const [
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60,
        ),
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 1,
          startTimeMinutes: 10 * 60,
          endTimeMinutes: 11 * 60,
        ),
      ],
    );
    final overlap = OnboardingCompletion(
      idempotencyKey: 'overlap',
      userType: OnboardingUserType.other,
      universityId: 'university',
      entryAcademicYear: 2026,
      customTerm: _customTerm(),
      customPeriods: const [
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60 + 30,
        ),
        OnboardingPeriodDraft(
          dayOfWeek: 1,
          periodNo: 2,
          startTimeMinutes: 10 * 60,
          endTimeMinutes: 11 * 60,
        ),
      ],
    );
    final midnightBoundary = OnboardingCompletion(
      idempotencyKey: 'midnight-boundary',
      userType: OnboardingUserType.other,
      universityId: 'university',
      entryAcademicYear: 2026,
      customTerm: _customTerm(),
      customPeriods: const [
        OnboardingPeriodDraft(
          dayOfWeek: 7,
          periodNo: 9,
          startTimeMinutes: 23 * 60,
          endTimeMinutes: 24 * 60,
        ),
      ],
    );

    expect(duplicateSlot.validate, throwsArgumentError);
    expect(overlap.validate, throwsArgumentError);
    expect(midnightBoundary.validate, returnsNormally);
  });
}

OnboardingCustomTerm _customTerm() {
  return OnboardingCustomTerm(
    name: '集中期間',
    academicYear: 2026,
    startDate: DateTime(2026, 8, 1),
    endDate: DateTime(2026, 8, 31),
    type: OnboardingCustomTermType.intensive,
  );
}
