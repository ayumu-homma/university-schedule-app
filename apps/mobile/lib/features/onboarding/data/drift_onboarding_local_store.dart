import 'package:drift/drift.dart';

import '../../../local_db/app_database.dart' as local;
import '../domain/onboarding_models.dart';

class DriftOnboardingLocalStore {
  DriftOnboardingLocalStore(
    this._database, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final local.AppDatabase _database;
  final DateTime Function() _clock;

  /// Restores a previously validated bootstrap only for [userId].
  ///
  /// This is deliberately a read-through fallback for an already
  /// authenticated session, not an alternative source for onboarding or
  /// authorization. A completed bootstrap remains usable only when its
  /// profile, active term, calendar, and period settings are internally
  /// consistent and scoped to the same user.
  Future<OnboardingProfile?> loadCachedProfile(String userId) async {
    if (userId.trim().isEmpty) return null;
    final profile = await (_database.select(_database.profiles)
          ..where((row) => row.userId.equals(userId)))
        .getSingleOrNull();
    if (profile == null || profile.userId != userId) return null;

    final status = _onboardingStatus(profile.onboardingStatus);
    final userType = _userType(profile.userType);
    if (status == null ||
        userType == null ||
        profile.displayName.trim().isEmpty ||
        profile.defaultVisibility.trim().isEmpty ||
        profile.onboardingStep.trim().isEmpty) {
      return null;
    }

    ActiveTermSummary? activeTerm;
    if (status == OnboardingStatus.complete) {
      final universityId = profile.universityId;
      final activeTermId = profile.activeTermId;
      final calendarId = profile.primaryCalendarId;
      if (_isBlank(universityId) ||
          _isBlank(activeTermId) ||
          _isBlank(calendarId)) {
        return null;
      }

      final term = await (_database.select(_database.terms)
            ..where(
              (row) =>
                  row.id.equals(activeTermId!) &
                  row.ownerUserId.equals(userId) &
                  row.universityId.equals(universityId!) &
                  row.isTemplate.equals(false) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (term == null || term.status != 'active') return null;

      final calendar = await (_database.select(_database.calendars)
            ..where(
              (row) =>
                  row.id.equals(calendarId!) & row.ownerUserId.equals(userId),
            ))
          .getSingleOrNull();
      if (calendar == null) return null;

      final periods = await (_database.select(_database.periodSettings)
            ..where(
              (row) =>
                  row.ownerUserId.equals(userId) &
                  row.universityId.equals(universityId!) &
                  row.termId.equals(activeTermId!) &
                  row.deletedAt.isNull(),
            ))
          .get();
      if (periods.isEmpty ||
          periods.any(
            (period) =>
                period.ownerUserId != userId ||
                period.universityId != universityId ||
                period.termId != activeTermId ||
                period.dayOfWeek < 1 ||
                period.dayOfWeek > 7 ||
                period.periodNo < 1 ||
                period.periodNo > 9 ||
                period.startTimeMinutes < 0 ||
                period.endTimeMinutes > 24 * 60 ||
                period.endTimeMinutes <= period.startTimeMinutes,
          )) {
        return null;
      }
      activeTerm = ActiveTermSummary(
        id: term.id,
        name: term.name,
        academicYear: term.academicYear,
      );
    }

    return OnboardingProfile(
      userId: profile.userId,
      status: status,
      displayName: profile.displayName,
      userType: userType,
      username: profile.username,
      universityId: profile.universityId,
      campusId: profile.campusId,
      facultyId: profile.facultyId,
      departmentId: profile.departmentId,
      entryAcademicYear: profile.entryAcademicYear,
      grade: profile.grade,
      universityVerified: profile.universityVerified,
      searchableByUsername: profile.searchableByUsername,
      defaultVisibility: profile.defaultVisibility,
      onboardingStep: profile.onboardingStep,
      onboardingCompletedAt: profile.onboardingCompletedAt,
      updatedAt: profile.updatedAt,
      version: profile.version,
      activeTerm: activeTerm,
      primaryCalendarId: profile.primaryCalendarId,
    );
  }

  Future<void> replaceBootstrap(OnboardingBootstrapPayload payload) async {
    _validate(payload);
    final profile = payload.profile;
    await _database.transaction(() async {
      final term = payload.term;
      if (term != null) {
        await _database.into(_database.terms).insertOnConflictUpdate(
              local.TermsCompanion.insert(
                id: term.id,
                universityId: term.universityId,
                configKey: Value(term.configKey),
                ownerUserId: Value(term.ownerUserId),
                sourceTemplateId: Value(term.sourceTemplateId),
                name: term.name,
                academicYear: term.academicYear,
                startDate: term.startDate,
                endDate: term.endDate,
                instructionStartDate: Value(term.instructionStartDate),
                instructionEndDate: Value(term.instructionEndDate),
                termType: term.termType,
                isTemplate: const Value(false),
                status: const Value('active'),
                updatedAt: Value(term.updatedAt),
                deletedAt: const Value(null),
                version: Value(term.version),
              ),
            );
      }

      final calendar = payload.calendar;
      if (calendar != null) {
        await _database.into(_database.calendars).insertOnConflictUpdate(
              local.CalendarsCompanion.insert(
                id: calendar.id,
                ownerUserId: calendar.ownerUserId,
                name: calendar.name,
                defaultVisibility: Value(calendar.defaultVisibility),
                updatedAt: Value(calendar.updatedAt),
              ),
            );
      }

      if (term != null) {
        await (_database.delete(_database.periodSettings)
              ..where(
                (row) =>
                    row.ownerUserId.equals(profile.userId) &
                    row.termId.equals(term.id),
              ))
            .go();
        await _database.batch((batch) {
          batch.insertAllOnConflictUpdate(
            _database.periodSettings,
            [
              for (final period in payload.periodSettings)
                local.PeriodSettingsCompanion.insert(
                  id: period.id,
                  ownerUserId: period.ownerUserId,
                  universityId: period.universityId,
                  termId: period.termId,
                  sourceTemplateSetId: Value(period.sourceTemplateSetId),
                  dayOfWeek: period.dayOfWeek,
                  periodNo: period.periodNo,
                  startTimeMinutes: period.startTimeMinutes,
                  endTimeMinutes: period.endTimeMinutes,
                  updatedAt: Value(period.updatedAt),
                  deletedAt: const Value(null),
                  version: Value(period.version),
                ),
            ],
          );
        });
      }

      await _database.into(_database.profiles).insertOnConflictUpdate(
            local.ProfilesCompanion.insert(
              userId: profile.userId,
              displayName: profile.displayName,
              userType: Value(profile.userType.wireName),
              username: Value(profile.username),
              universityId: Value(profile.universityId),
              campusId: Value(profile.campusId),
              facultyId: Value(profile.facultyId),
              departmentId: Value(profile.departmentId),
              activeTermId: Value(profile.activeTerm?.id),
              primaryCalendarId: Value(profile.primaryCalendarId),
              entryAcademicYear: Value(profile.entryAcademicYear),
              grade: Value(profile.grade),
              universityVerified: Value(profile.universityVerified),
              searchableByUsername: Value(profile.searchableByUsername),
              defaultVisibility: Value(profile.defaultVisibility),
              onboardingStatus: Value(_statusWireName(profile.status)),
              onboardingStep: Value(profile.onboardingStep),
              onboardingCompletedAt: Value(profile.onboardingCompletedAt),
              updatedAt: Value(profile.updatedAt ?? _clock()),
              version: Value(profile.version),
            ),
          );
    });
  }

  void _validate(OnboardingBootstrapPayload payload) {
    final profile = payload.profile;
    if (profile.userId.trim().isEmpty || profile.displayName.trim().isEmpty) {
      throw StateError('The authenticated profile bootstrap is incomplete.');
    }
    if (profile.status != OnboardingStatus.complete) {
      if (payload.term != null ||
          payload.calendar != null ||
          payload.periodSettings.isNotEmpty) {
        throw StateError('An incomplete profile cannot activate a schedule.');
      }
      return;
    }

    final universityId = profile.universityId;
    final term = payload.term;
    final calendar = payload.calendar;
    if (!profile.hasActiveSchedule ||
        universityId == null ||
        term == null ||
        calendar == null ||
        payload.periodSettings.isEmpty ||
        term.id != profile.activeTerm?.id ||
        term.ownerUserId != profile.userId ||
        term.universityId != universityId ||
        calendar.id != profile.primaryCalendarId ||
        calendar.ownerUserId != profile.userId) {
      throw StateError('The active schedule bootstrap is inconsistent.');
    }
    for (final period in payload.periodSettings) {
      if (period.ownerUserId != profile.userId ||
          period.universityId != universityId ||
          period.termId != term.id ||
          period.dayOfWeek < 1 ||
          period.dayOfWeek > 7 ||
          period.periodNo < 1 ||
          period.periodNo > 9 ||
          period.startTimeMinutes < 0 ||
          period.endTimeMinutes > 24 * 60 ||
          period.endTimeMinutes <= period.startTimeMinutes) {
        throw StateError('A period setting escaped its authenticated scope.');
      }
    }
  }

  String _statusWireName(OnboardingStatus status) {
    return switch (status) {
      OnboardingStatus.notStarted => 'not_started',
      OnboardingStatus.inProgress => 'in_progress',
      OnboardingStatus.complete => 'complete',
    };
  }

  OnboardingStatus? _onboardingStatus(String value) {
    return switch (value) {
      'not_started' => OnboardingStatus.notStarted,
      'in_progress' => OnboardingStatus.inProgress,
      'complete' => OnboardingStatus.complete,
      _ => null,
    };
  }

  OnboardingUserType? _userType(String value) {
    return switch (value) {
      'undergraduate' => OnboardingUserType.undergraduate,
      'graduate' => OnboardingUserType.graduate,
      'other' => OnboardingUserType.other,
      _ => null,
    };
  }

  bool _isBlank(String? value) => value == null || value.trim().isEmpty;
}
