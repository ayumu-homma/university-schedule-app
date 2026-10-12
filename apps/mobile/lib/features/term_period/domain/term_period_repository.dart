import 'term_period_models.dart';

abstract interface class TermPeriodRepository {
  Future<PersonalTermPeriodSnapshot> load();

  Future<List<PersonalPeriodSetting>> loadPeriods(String termId);

  Future<PersonalTermMutation> createTerm(PersonalTermCreateInput input);

  Future<void> activateTerm(String termId);

  Future<int> replacePeriods({
    required String termId,
    required PeriodSettingsInput input,
  });
}
