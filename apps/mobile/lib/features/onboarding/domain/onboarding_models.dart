enum OnboardingStatus { notStarted, inProgress, complete }

enum OnboardingUserType {
  undergraduate('undergraduate', '学部生'),
  graduate('graduate', '大学院生'),
  other('other', 'その他');

  const OnboardingUserType(this.wireName, this.label);

  final String wireName;
  final String label;
}

enum OnboardingCustomTermType {
  semester('semester', '前期・後期'),
  quarter('quarter', 'クォーター'),
  custom('custom', 'カスタム'),
  intensive('intensive', '集中講義'),
  yearRound('year_round', '通年');

  const OnboardingCustomTermType(this.wireName, this.label);

  final String wireName;
  final String label;
}

class ActiveTermSummary {
  const ActiveTermSummary({
    required this.id,
    required this.name,
    required this.academicYear,
  });

  final String id;
  final String name;
  final int academicYear;
}

class OnboardingProfile {
  const OnboardingProfile({
    required this.userId,
    required this.status,
    this.displayName = '',
    this.userType = OnboardingUserType.other,
    this.username,
    this.universityId,
    this.campusId,
    this.facultyId,
    this.departmentId,
    this.entryAcademicYear,
    this.grade,
    this.universityVerified = false,
    this.searchableByUsername = false,
    this.defaultVisibility = 'PRIVATE',
    this.onboardingStep = 'profile',
    this.onboardingCompletedAt,
    this.updatedAt,
    this.version = 1,
    this.activeTerm,
    this.primaryCalendarId,
  });

  final String userId;
  final OnboardingStatus status;
  final String displayName;
  final OnboardingUserType userType;
  final String? username;
  final String? universityId;
  final String? campusId;
  final String? facultyId;
  final String? departmentId;
  final int? entryAcademicYear;
  final int? grade;
  final bool universityVerified;
  final bool searchableByUsername;
  final String defaultVisibility;
  final String onboardingStep;
  final DateTime? onboardingCompletedAt;
  final DateTime? updatedAt;
  final int version;
  final ActiveTermSummary? activeTerm;
  final String? primaryCalendarId;

  bool get hasActiveSchedule =>
      status == OnboardingStatus.complete &&
      universityId != null &&
      activeTerm != null &&
      primaryCalendarId != null;
}

class OnboardingTermRecord {
  const OnboardingTermRecord({
    required this.id,
    required this.universityId,
    required this.ownerUserId,
    required this.name,
    required this.academicYear,
    required this.startDate,
    required this.endDate,
    required this.termType,
    required this.updatedAt,
    required this.version,
    this.configKey,
    this.sourceTemplateId,
    this.instructionStartDate,
    this.instructionEndDate,
  });

  final String id;
  final String universityId;
  final String ownerUserId;
  final String? configKey;
  final String? sourceTemplateId;
  final String name;
  final int academicYear;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime? instructionStartDate;
  final DateTime? instructionEndDate;
  final String termType;
  final DateTime updatedAt;
  final int version;
}

class OnboardingPeriodSettingRecord {
  const OnboardingPeriodSettingRecord({
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

class OnboardingCalendarRecord {
  const OnboardingCalendarRecord({
    required this.id,
    required this.ownerUserId,
    required this.name,
    required this.defaultVisibility,
    required this.updatedAt,
  });

  final String id;
  final String ownerUserId;
  final String name;
  final String? defaultVisibility;
  final DateTime updatedAt;
}

class OnboardingBootstrapPayload {
  const OnboardingBootstrapPayload({
    required this.profile,
    this.term,
    this.calendar,
    this.periodSettings = const [],
  });

  final OnboardingProfile profile;
  final OnboardingTermRecord? term;
  final OnboardingCalendarRecord? calendar;
  final List<OnboardingPeriodSettingRecord> periodSettings;
}

class UniversityOption {
  const UniversityOption({required this.id, required this.name});

  final String id;
  final String name;
}

class CampusOption {
  const CampusOption({
    required this.id,
    required this.universityId,
    required this.name,
    required this.isMain,
  });

  final String id;
  final String universityId;
  final String name;
  final bool isMain;
}

class TermTemplateOption {
  const TermTemplateOption({
    required this.id,
    required this.universityId,
    required this.name,
    required this.academicYear,
  });

  final String id;
  final String universityId;
  final String name;
  final int academicYear;
}

class PeriodTemplateSetOption {
  const PeriodTemplateSetOption({
    required this.id,
    required this.universityId,
    required this.name,
    required this.isDefault,
    this.campusId,
    this.academicYear,
    this.userType,
  });

  final String id;
  final String universityId;
  final String? campusId;
  final String name;
  final int? academicYear;
  final bool isDefault;
  final OnboardingUserType? userType;
}

class OnboardingCustomTerm {
  const OnboardingCustomTerm({
    required this.name,
    required this.academicYear,
    required this.startDate,
    required this.endDate,
    required this.type,
  });

  final String name;
  final int academicYear;
  final DateTime startDate;
  final DateTime endDate;
  final OnboardingCustomTermType type;

  String get startDateWire => _dateOnly(startDate);

  String get endDateWire => _dateOnly(endDate);

  void validate() {
    if (name.trim().isEmpty ||
        name.trim().length > 100 ||
        academicYear < 1900 ||
        academicYear > 2200 ||
        endDate.isBefore(startDate)) {
      throw ArgumentError('The custom term is incomplete.');
    }
  }
}

class OnboardingPeriodDraft {
  const OnboardingPeriodDraft({
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
}

class OnboardingCatalog {
  const OnboardingCatalog({
    required this.universities,
    required this.campuses,
    required this.termTemplates,
    required this.periodTemplateSets,
  });

  final List<UniversityOption> universities;
  final List<CampusOption> campuses;
  final List<TermTemplateOption> termTemplates;
  final List<PeriodTemplateSetOption> periodTemplateSets;

  List<CampusOption> campusesFor(String universityId) => campuses
      .where((option) => option.universityId == universityId)
      .toList(growable: false);

  List<TermTemplateOption> termsFor(String universityId) => termTemplates
      .where((option) => option.universityId == universityId)
      .toList(growable: false);

  List<PeriodTemplateSetOption> periodSetsFor({
    required String universityId,
    required String? campusId,
    required int academicYear,
    required OnboardingUserType userType,
  }) {
    return periodTemplateSets
        .where((option) => option.universityId == universityId)
        .where(
          (option) =>
              option.academicYear == null ||
              option.academicYear == academicYear,
        )
        .where(
          (option) => option.campusId == null || option.campusId == campusId,
        )
        .where(
          (option) => option.userType == null || option.userType == userType,
        )
        .toList(growable: false);
  }
}

class OnboardingCompletion {
  const OnboardingCompletion({
    required this.idempotencyKey,
    required this.userType,
    required this.universityId,
    required this.entryAcademicYear,
    this.campusId,
    this.termTemplateId,
    this.customTerm,
    this.periodTemplateSetId,
    this.customPeriods,
  });

  final String idempotencyKey;
  final OnboardingUserType userType;
  final String universityId;
  final String? campusId;
  final int entryAcademicYear;
  final String? termTemplateId;
  final OnboardingCustomTerm? customTerm;
  final String? periodTemplateSetId;
  final List<OnboardingPeriodDraft>? customPeriods;

  bool get usesTermTemplate => _hasText(termTemplateId);

  bool get usesPeriodTemplate => _hasText(periodTemplateSetId);

  List<Map<String, Object>>? get customPeriodsRpc => customPeriods
      ?.map((period) => period.toRpcJson())
      .toList(growable: false);

  void validate() {
    if (idempotencyKey.trim().isEmpty ||
        universityId.trim().isEmpty ||
        entryAcademicYear < 1900 ||
        entryAcademicYear > 2200) {
      throw ArgumentError('Onboarding selection is incomplete.');
    }

    if (usesTermTemplate == (customTerm != null) ||
        usesPeriodTemplate == (customPeriods != null)) {
      throw ArgumentError('Choose one source for each onboarding setting.');
    }
    customTerm?.validate();

    final periods = customPeriods;
    if (periods == null) return;
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

    final byDay = <int, List<OnboardingPeriodDraft>>{};
    for (final period in periods) {
      (byDay[period.dayOfWeek] ??= []).add(period);
    }
    for (final dayPeriods in byDay.values) {
      dayPeriods.sort(
        (left, right) =>
            left.startTimeMinutes.compareTo(right.startTimeMinutes),
      );
      for (var index = 1; index < dayPeriods.length; index++) {
        if (dayPeriods[index].startTimeMinutes <
            dayPeriods[index - 1].endTimeMinutes) {
          throw ArgumentError('Period settings must not overlap.');
        }
      }
    }
  }
}

bool _hasText(String? value) => value?.trim().isNotEmpty == true;

String _dateOnly(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _timeText(int minutes) {
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}
