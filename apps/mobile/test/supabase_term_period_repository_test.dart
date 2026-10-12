import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/term_period/data/supabase_term_period_repository.dart';
import 'package:university_schedule_mobile/features/term_period/domain/term_period_models.dart';

void main() {
  const ownerUserId = '11111111-1111-4111-8111-111111111111';
  const universityId = '22222222-2222-4222-8222-222222222222';
  const sourceTermId = '33333333-3333-4333-8333-333333333333';
  const periodSetId = '44444444-4444-4444-8444-444444444444';
  const personalTermId = '55555555-5555-4555-8555-555555555555';

  test('template creation maps only the authenticated term and period inputs',
      () async {
    String? rpcName;
    Map<String, Object?>? rpcParameters;
    final repository = _repository(
      rpc: (name, parameters) async {
        rpcName = name;
        rpcParameters = parameters;
        return [
          {
            'term_id': personalTermId,
            'active_term_id': personalTermId,
          },
        ];
      },
    );

    final mutation = await repository.createTerm(
      const PersonalTermCreateInput.fromTemplate(
        termTemplateId: sourceTermId,
        periodSettings: PeriodTemplateSettingsInput(periodSetId),
      ),
    );

    expect(rpcName, 'create_personal_term');
    expect(rpcParameters, {
      'p_term_template_id': sourceTermId,
      'p_custom_term_name': null,
      'p_custom_academic_year': null,
      'p_custom_start_date': null,
      'p_custom_end_date': null,
      'p_custom_term_type': null,
      'p_period_template_set_id': periodSetId,
      'p_custom_periods': null,
      'p_make_active': true,
    });
    expect(mutation.termId, personalTermId);
    expect(mutation.activeTermId, personalTermId);
  });

  test('custom terms preserve date-only values and replace period snapshots',
      () async {
    final calls = <String>[];
    final parameters = <Map<String, Object?>>[];
    final repository = _repository(
      rpc: (name, values) async {
        calls.add(name);
        parameters.add(values);
        if (name == 'create_personal_term') {
          return [
            {
              'term_id': personalTermId,
              'active_term_id': personalTermId,
            },
          ];
        }
        return 2;
      },
    );
    const periods = CustomPeriodSettingsInput([
      PersonalPeriodDraft(
        dayOfWeek: 1,
        periodNo: 1,
        startTimeMinutes: 9 * 60,
        endTimeMinutes: 10 * 60 + 20,
      ),
      PersonalPeriodDraft(
        dayOfWeek: 1,
        periodNo: 2,
        startTimeMinutes: 10 * 60 + 30,
        endTimeMinutes: 11 * 60 + 50,
      ),
    ]);

    await repository.createTerm(
      PersonalTermCreateInput.custom(
        customName: '夏学期',
        customAcademicYear: 2026,
        customStartDate: DateTime(2026, 8, 1),
        customEndDate: DateTime(2026, 9, 15),
        customType: PersonalTermType.quarter,
        periodSettings: periods,
        makeActive: false,
      ),
    );
    final replacementCount = await repository.replacePeriods(
      termId: personalTermId,
      input: periods,
    );

    expect(calls, [
      'create_personal_term',
      'replace_personal_period_settings',
    ]);
    expect(parameters.first['p_custom_term_name'], '夏学期');
    expect(parameters.first['p_custom_academic_year'], 2026);
    expect(parameters.first['p_custom_start_date'], '2026-08-01');
    expect(parameters.first['p_custom_end_date'], '2026-09-15');
    expect(parameters.first['p_custom_term_type'], 'quarter');
    expect(parameters.first['p_period_template_set_id'], isNull);
    expect(parameters.first['p_custom_periods'], [
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
    expect(parameters.last, {
      'p_term_id': personalTermId,
      'p_period_template_set_id': null,
      'p_custom_periods': parameters.first['p_custom_periods'],
    });
    expect(replacementCount, 2);
  });

  test('invalid overlapping periods are rejected before any remote mutation',
      () async {
    var called = false;
    final repository = _repository(
      rpc: (_, __) async {
        called = true;
        return 1;
      },
    );
    const overlapping = CustomPeriodSettingsInput([
      PersonalPeriodDraft(
        dayOfWeek: 1,
        periodNo: 1,
        startTimeMinutes: 9 * 60,
        endTimeMinutes: 10 * 60 + 30,
      ),
      PersonalPeriodDraft(
        dayOfWeek: 1,
        periodNo: 2,
        startTimeMinutes: 10 * 60,
        endTimeMinutes: 11 * 60,
      ),
    ]);

    await expectLater(
      repository.replacePeriods(termId: personalTermId, input: overlapping),
      throwsA(isA<ValidationError>()),
    );
    expect(called, isFalse);
  });

  test('owner-filtered reads map a complete active snapshot and its periods',
      () async {
    final repository = _repository(
      profile: (_) async => {
        'user_id': ownerUserId,
        'university_id': universityId,
        'active_term_id': personalTermId,
      },
      terms: (_) async => [
        {
          'id': personalTermId,
          'owner_user_id': ownerUserId,
          'university_id': universityId,
          'name': '2026 前期',
          'academic_year': 2026,
          'start_date': '2026-04-01',
          'end_date': '2026-09-30',
          'instruction_start_date': null,
          'instruction_end_date': null,
          'term_type': 'semester',
          'source_template_id': sourceTermId,
          'is_template': false,
          'status': 'active',
          'deleted_at': null,
          'updated_at': '2026-07-18T12:00:00Z',
          'version': 1,
        },
      ],
      periods: ({required userId, required termId}) async => [
        {
          'id': '66666666-6666-4666-8666-666666666666',
          'owner_user_id': userId,
          'university_id': universityId,
          'term_id': termId,
          'source_template_set_id': periodSetId,
          'day_of_week': 1,
          'period_no': 1,
          'start_time': '09:00:00',
          'end_time': '10:20:00',
          'updated_at': '2026-07-18T12:00:00Z',
          'version': 1,
          'deleted_at': null,
        },
      ],
    );

    final snapshot = await repository.load();
    final periods = await repository.loadPeriods(personalTermId);

    expect(snapshot.ownerUserId, ownerUserId);
    expect(snapshot.activeTerm?.sourceTemplateId, sourceTermId);
    expect(snapshot.activeTerm?.type, PersonalTermType.semester);
    expect(periods.single.sourceTemplateSetId, periodSetId);
    expect(periods.single.startTimeMinutes, 9 * 60);
    expect(periods.single.endTimeMinutes, 10 * 60 + 20);
  });

  test('maps intensive and year-round personal terms from valid backend rows',
      () async {
    const intensiveTermId = '77777777-7777-4777-8777-777777777777';
    const yearRoundTermId = '88888888-8888-4888-8888-888888888888';
    final repository = _repository(
      profile: (_) async => {
        'user_id': ownerUserId,
        'university_id': universityId,
        'active_term_id': intensiveTermId,
      },
      terms: (_) async => [
        {
          'id': intensiveTermId,
          'owner_user_id': ownerUserId,
          'university_id': universityId,
          'name': '集中講義',
          'academic_year': 2026,
          'start_date': '2026-08-01',
          'end_date': '2026-08-14',
          'instruction_start_date': null,
          'instruction_end_date': null,
          'term_type': 'intensive',
          'source_template_id': sourceTermId,
          'is_template': false,
          'status': 'active',
          'deleted_at': null,
          'updated_at': '2026-07-18T12:00:00Z',
          'version': 1,
        },
        {
          'id': yearRoundTermId,
          'owner_user_id': ownerUserId,
          'university_id': universityId,
          'name': '通年',
          'academic_year': 2026,
          'start_date': '2026-04-01',
          'end_date': '2027-03-31',
          'instruction_start_date': null,
          'instruction_end_date': null,
          'term_type': 'year_round',
          'source_template_id': null,
          'is_template': false,
          'status': 'active',
          'deleted_at': null,
          'updated_at': '2026-07-18T12:00:00Z',
          'version': 1,
        },
      ],
    );

    final snapshot = await repository.load();

    expect(snapshot.activeTerm?.type, PersonalTermType.intensive);
    expect(
      snapshot.terms.singleWhere((term) => term.id == yearRoundTermId).type,
      PersonalTermType.yearRound,
    );
  });

  test('a mismatched remote owner is not accepted as a personal snapshot',
      () async {
    final repository = _repository(
      profile: (_) async => {
        'user_id': ownerUserId,
        'university_id': universityId,
        'active_term_id': null,
      },
      terms: (_) async => [
        {
          'id': personalTermId,
          'owner_user_id': 'another-user',
          'university_id': universityId,
          'name': 'Forged',
          'academic_year': 2026,
          'start_date': '2026-04-01',
          'end_date': '2026-09-30',
          'instruction_start_date': null,
          'instruction_end_date': null,
          'term_type': 'semester',
          'source_template_id': null,
          'is_template': false,
          'status': 'active',
          'deleted_at': null,
          'updated_at': '2026-07-18T12:00:00Z',
          'version': 1,
        },
      ],
    );

    await expectLater(repository.load(), throwsA(isA<PermissionError>()));
  });
}

SupabaseTermPeriodRepository _repository({
  TermPeriodRpc? rpc,
  TermPeriodProfileLookup? profile,
  PersonalTermRowsLookup? terms,
  PersonalPeriodRowsLookup? periods,
}) {
  return SupabaseTermPeriodRepository(
    userId: '11111111-1111-4111-8111-111111111111',
    rpcOverride: rpc ?? (_, __) async => null,
    authenticatedUserIdOverride: () => '11111111-1111-4111-8111-111111111111',
    profileLookupOverride: profile ??
        (_) async => {
              'user_id': '11111111-1111-4111-8111-111111111111',
              'university_id': '22222222-2222-4222-8222-222222222222',
              'active_term_id': null,
            },
    termRowsLookupOverride: terms ?? (_) async => const [],
    periodRowsLookupOverride:
        periods ?? ({required userId, required termId}) async => const [],
  );
}
