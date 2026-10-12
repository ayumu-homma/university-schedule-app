enum PersonalTermType {
  semester('semester', '前期・後期'),
  quarter('quarter', 'クォーター'),
  custom('custom', 'カスタム'),
  intensive('intensive', '集中講義'),
  yearRound('year_round', '通年');

  const PersonalTermType(this.wireName, this.label);

  final String wireName;
  final String label;

  static PersonalTermType fromWire(String value) {
    return PersonalTermType.values.firstWhere(
      (type) => type.wireName == value,
      orElse: () => throw StateError('Unknown personal term type.'),
    );
  }
}

class PersonalTerm {
  const PersonalTerm({
    required this.id,
    required this.ownerUserId,
    required this.universityId,
    required this.name,
    required this.academicYear,
    required this.startDate,
    required this.endDate,
    required this.type,
    required this.updatedAt,
    required this.version,
    this.sourceTemplateId,
    this.instructionStartDate,
    this.instructionEndDate,
  });

  final String id;
  final String ownerUserId;
  final String universityId;
  final String name;
  final int academicYear;
  final DateTime startDate;
  final DateTime endDate;
  final PersonalTermType type;
  final String? sourceTemplateId;
  final DateTime? instructionStartDate;
  final DateTime? instructionEndDate;
  final DateTime updatedAt;
  final int version;
}

class PersonalPeriodSetting {
  const PersonalPeriodSetting({
    required this.id,
    required this.ownerUserId,
    required this.universityId,
    required this.termId,
    required this.dayOfWeek,
    required this.periodNo,
    required this.startTimeMinutes,
    required this.endTimeMinutes,
    required this.updatedAt,
    required this.version,
    this.sourceTemplateSetId,
  });

  final String id;
  final String ownerUserId;
  final String universityId;
  final String termId;
  final String? sourceTemplateSetId;
  final int dayOfWeek;
  final int periodNo;
  final int startTimeMinutes;
  final int endTimeMinutes;
  final DateTime updatedAt;
  final int version;
}

class PersonalPeriodDraft {
  const PersonalPeriodDraft({
    required this.dayOfWeek,
    required this.periodNo,
    required this.startTimeMinutes,
    required this.endTimeMinutes,
  });

  final int dayOfWeek;
  final int periodNo;
  final int startTimeMinutes;
  final int endTimeMinutes;

  Map<String, Object> toRpcJson() => {
        'day_of_week': dayOfWeek,
        'period_no': periodNo,
        'start_time': _timeText(startTimeMinutes),
        'end_time': _timeText(endTimeMinutes),
      };

  static String _timeText(int minutes) {
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return '${hours.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }
}

sealed class PeriodSettingsInput {
  const PeriodSettingsInput();

  void validate();

  String? get templateSetId;

  List<Map<String, Object>>? get customPeriods;
}

class PeriodTemplateSettingsInput extends PeriodSettingsInput {
  const PeriodTemplateSettingsInput(this.templateSetId);

  @override
  final String templateSetId;

  @override
  List<Map<String, Object>>? get customPeriods => null;

  @override
  void validate() {
    if (templateSetId.trim().isEmpty) {
      throw ArgumentError('A period template set is required.');
    }
  }
}

class CustomPeriodSettingsInput extends PeriodSettingsInput {
  const CustomPeriodSettingsInput(this.periods);

  final List<PersonalPeriodDraft> periods;

  @override
  String? get templateSetId => null;

  @override
  List<Map<String, Object>> get customPeriods => [
        for (final period in periods) period.toRpcJson(),
      ];

  @override
  void validate() {
    if (periods.isEmpty || periods.length > 63) {
      throw ArgumentError(
          'Period settings must contain between 1 and 63 rows.');
    }
    final seenSlots = <(int, int)>{};
    for (final period in periods) {
      if (period.dayOfWeek < 1 ||
          period.dayOfWeek > 7 ||
          period.periodNo < 1 ||
          period.periodNo > 9 ||
          period.startTimeMinutes < 0 ||
          period.startTimeMinutes >= 24 * 60 ||
          period.endTimeMinutes < 1 ||
          period.endTimeMinutes > 24 * 60 ||
          period.endTimeMinutes <= period.startTimeMinutes ||
          !seenSlots.add((period.dayOfWeek, period.periodNo))) {
        throw ArgumentError('Period settings contain an invalid row.');
      }
    }

    final byDay = <int, List<PersonalPeriodDraft>>{};
    for (final period in periods) {
      (byDay[period.dayOfWeek] ??= []).add(period);
    }
    for (final dayPeriods in byDay.values) {
      dayPeriods.sort((left, right) =>
          left.startTimeMinutes.compareTo(right.startTimeMinutes));
      for (var index = 1; index < dayPeriods.length; index++) {
        if (dayPeriods[index].startTimeMinutes <
            dayPeriods[index - 1].endTimeMinutes) {
          throw ArgumentError('Period settings must not overlap.');
        }
      }
    }
  }
}

class PersonalTermCreateInput {
  const PersonalTermCreateInput.fromTemplate({
    required this.termTemplateId,
    required this.periodSettings,
    this.makeActive = true,
  })  : customName = null,
        customAcademicYear = null,
        customStartDate = null,
        customEndDate = null,
        customType = null;

  const PersonalTermCreateInput.custom({
    required this.customName,
    required this.customAcademicYear,
    required this.customStartDate,
    required this.customEndDate,
    required this.customType,
    required this.periodSettings,
    this.makeActive = true,
  }) : termTemplateId = null;

  final String? termTemplateId;
  final String? customName;
  final int? customAcademicYear;
  final DateTime? customStartDate;
  final DateTime? customEndDate;
  final PersonalTermType? customType;
  final PeriodSettingsInput periodSettings;
  final bool makeActive;

  void validate() {
    final hasTemplate = termTemplateId?.trim().isNotEmpty == true;
    final hasCustom = customName != null ||
        customAcademicYear != null ||
        customStartDate != null ||
        customEndDate != null ||
        customType != null;
    if (hasTemplate == hasCustom) {
      throw ArgumentError('Choose either a template or a custom term.');
    }
    if (hasTemplate) {
      periodSettings.validate();
      return;
    }
    final name = customName?.trim() ?? '';
    final year = customAcademicYear;
    final start = customStartDate;
    final end = customEndDate;
    if (name.isEmpty ||
        name.length > 100 ||
        year == null ||
        year < 1900 ||
        year > 2200 ||
        start == null ||
        end == null ||
        customType == null ||
        end.isBefore(start)) {
      throw ArgumentError('The custom term is incomplete.');
    }
    periodSettings.validate();
  }
}

class PersonalTermMutation {
  const PersonalTermMutation({
    required this.termId,
    required this.activeTermId,
  });

  final String termId;
  final String activeTermId;
}

class PersonalTermPeriodSnapshot {
  const PersonalTermPeriodSnapshot({
    required this.ownerUserId,
    required this.universityId,
    required this.terms,
    this.activeTermId,
  });

  final String ownerUserId;
  final String universityId;
  final String? activeTermId;
  final List<PersonalTerm> terms;

  PersonalTerm? get activeTerm {
    final id = activeTermId;
    if (id == null) return null;
    for (final term in terms) {
      if (term.id == id) return term;
    }
    return null;
  }
}
