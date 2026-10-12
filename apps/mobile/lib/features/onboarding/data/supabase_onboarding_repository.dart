import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_error.dart';
import 'drift_onboarding_local_store.dart';
import '../domain/onboarding_models.dart';
import '../domain/onboarding_repository.dart';

class SupabaseOnboardingRepository implements OnboardingRepository {
  const SupabaseOnboardingRepository(
    this._client, {
    required DriftOnboardingLocalStore localStore,
  }) : _localStore = localStore;

  final SupabaseClient _client;
  final DriftOnboardingLocalStore _localStore;

  @override
  Future<OnboardingProfile> loadProfile(String userId) async {
    try {
      return await _guard(() => _loadProfile(userId));
    } on NetworkError {
      final cachedProfile = await _localStore.loadCachedProfile(userId);
      if (cachedProfile != null) return cachedProfile;
      rethrow;
    }
  }

  @override
  Future<OnboardingCatalog> loadCatalog() {
    return _guard(_loadCatalog);
  }

  @override
  Future<OnboardingProfile> completeOnboarding({
    required String userId,
    required OnboardingCompletion completion,
  }) {
    return _guard(() async {
      try {
        completion.validate();
      } on ArgumentError {
        throw const ValidationError('選択したオンボーディング設定を確認してください');
      }

      final response = await _client.rpc(
        'complete_onboarding',
        params: {
          'p_idempotency_key': completion.idempotencyKey,
          'p_user_type': completion.userType.wireName,
          'p_university_id': completion.universityId.trim(),
          'p_campus_id': completion.campusId,
          'p_faculty_id': null,
          'p_department_id': null,
          'p_entry_academic_year': completion.entryAcademicYear,
          'p_term_template_id': completion.termTemplateId?.trim(),
          'p_custom_term_name': completion.customTerm?.name.trim(),
          'p_custom_academic_year': completion.customTerm?.academicYear,
          'p_custom_start_date': completion.customTerm?.startDateWire,
          'p_custom_end_date': completion.customTerm?.endDateWire,
          'p_custom_term_type': completion.customTerm?.type.wireName,
          'p_period_template_set_id': completion.periodTemplateSetId?.trim(),
          'p_custom_periods': completion.customPeriodsRpc,
        },
      );
      final result = _firstRow(response);
      final termId = _requiredString(result, 'term_id');
      final calendarId = _requiredString(result, 'calendar_id');
      final profile = await _loadProfile(userId);
      if (!profile.hasActiveSchedule ||
          profile.activeTerm?.id != termId ||
          profile.primaryCalendarId != calendarId) {
        throw const UnknownAppError('オンボーディング完了後の設定を復元できませんでした');
      }
      return profile;
    });
  }

  Future<OnboardingProfile> _loadProfile(String userId) async {
    if (userId.trim().isEmpty) {
      throw const PermissionError('認証セッションが無効です');
    }
    final row = await _client
        .from('profiles')
        .select(
          'user_id,display_name,user_type,username,university_id,campus_id,'
          'faculty_id,department_id,entry_academic_year,grade,'
          'university_verified,searchable_by_username,default_visibility,'
          'onboarding_status,onboarding_step,onboarding_completed_at,'
          'updated_at,version,active_term_id,primary_calendar_id',
        )
        .eq('user_id', userId)
        .maybeSingle();
    if (row == null) {
      throw const UnknownAppError('プロフィールを復元できませんでした');
    }

    final activeTermId = _nullableString(row, 'active_term_id');
    Map<String, dynamic>? termRow;
    ActiveTermSummary? activeTerm;
    if (activeTermId != null) {
      termRow = await _client
          .from('terms')
          .select(
            'id,university_id,config_key,owner_user_id,source_template_id,'
            'name,academic_year,start_date,end_date,instruction_start_date,'
            'instruction_end_date,term_type,is_template,status,updated_at,'
            'deleted_at,version',
          )
          .eq('id', activeTermId)
          .eq('owner_user_id', userId)
          .maybeSingle();
      if (termRow != null) {
        activeTerm = ActiveTermSummary(
          id: _requiredString(termRow, 'id'),
          name: _requiredString(termRow, 'name'),
          academicYear: _requiredInt(termRow, 'academic_year'),
        );
      }
    }

    final profile = OnboardingProfile(
      userId: _requiredString(row, 'user_id'),
      status: _statusFromWire(_requiredString(row, 'onboarding_status')),
      displayName: _requiredString(row, 'display_name'),
      userType: _userTypeFromWire(_requiredString(row, 'user_type')),
      username: _nullableString(row, 'username'),
      universityId: _nullableString(row, 'university_id'),
      campusId: _nullableString(row, 'campus_id'),
      facultyId: _nullableString(row, 'faculty_id'),
      departmentId: _nullableString(row, 'department_id'),
      entryAcademicYear: _nullableInt(row, 'entry_academic_year'),
      grade: _nullableInt(row, 'grade'),
      universityVerified: row['university_verified'] == true,
      searchableByUsername: row['searchable_by_username'] == true,
      defaultVisibility: _requiredString(row, 'default_visibility'),
      onboardingStep: _requiredString(row, 'onboarding_step'),
      onboardingCompletedAt: _nullableDateTime(
        row,
        'onboarding_completed_at',
      ),
      updatedAt: _requiredDateTime(row, 'updated_at'),
      version: _requiredInt(row, 'version'),
      activeTerm: activeTerm,
      primaryCalendarId: _nullableString(row, 'primary_calendar_id'),
    );
    if (profile.userId != userId) {
      throw const PermissionError('別のユーザー設定は復元できません');
    }
    if (profile.status == OnboardingStatus.complete &&
        !profile.hasActiveSchedule) {
      throw const UnknownAppError('完了済みの初期設定を復元できませんでした');
    }
    if (!profile.hasActiveSchedule) {
      await _localStore.replaceBootstrap(
        OnboardingBootstrapPayload(profile: profile),
      );
      return profile;
    }

    final universityId = profile.universityId!;
    final calendarId = profile.primaryCalendarId!;
    if (termRow == null ||
        _requiredString(termRow, 'university_id') != universityId ||
        termRow['is_template'] == true ||
        _nullableString(termRow, 'deleted_at') != null) {
      throw const UnknownAppError('有効な学期設定を復元できませんでした');
    }
    final calendarRow = await _client
        .from('calendars')
        .select(
          'id,owner_user_id,name,default_visibility,updated_at,deleted_at',
        )
        .eq('id', calendarId)
        .eq('owner_user_id', userId)
        .maybeSingle();
    if (calendarRow == null ||
        _nullableString(calendarRow, 'deleted_at') != null) {
      throw const UnknownAppError('有効なカレンダーを復元できませんでした');
    }
    final periodRows = await _client
        .from('period_settings')
        .select(
          'id,owner_user_id,university_id,term_id,'
          'source_template_set_id,day_of_week,period_no,start_time,end_time,'
          'updated_at,deleted_at,version',
        )
        .eq('owner_user_id', userId)
        .eq('university_id', universityId)
        .eq('term_id', activeTermId!);
    final activePeriodRows = periodRows
        .where((period) => _nullableString(period, 'deleted_at') == null)
        .toList(growable: false);
    if (activePeriodRows.isEmpty) {
      throw const UnknownAppError('時限設定を復元できませんでした');
    }

    await _localStore.replaceBootstrap(
      OnboardingBootstrapPayload(
        profile: profile,
        term: _termRecord(termRow),
        calendar: OnboardingCalendarRecord(
          id: _requiredString(calendarRow, 'id'),
          ownerUserId: _requiredString(calendarRow, 'owner_user_id'),
          name: _requiredString(calendarRow, 'name'),
          defaultVisibility: _nullableString(
            calendarRow,
            'default_visibility',
          ),
          updatedAt: _requiredDateTime(calendarRow, 'updated_at'),
        ),
        periodSettings: [
          for (final period in activePeriodRows) _periodRecord(period),
        ],
      ),
    );
    return profile;
  }

  Future<OnboardingCatalog> _loadCatalog() async {
    final universityRows =
        await _client.from('universities').select('id,name').order('name');
    final campusRows = await _client
        .from('campuses')
        .select('id,university_id,name,is_main')
        .order('name');
    final termRows = await _client
        .from('terms')
        .select('id,university_id,name,academic_year')
        .eq('is_template', true)
        .order('academic_year', ascending: false)
        .order('name');
    final periodSetRows = await _client
        .from('period_template_sets')
        .select(
          'id,university_id,campus_id,name,academic_year,user_type,'
          'is_default',
        )
        .order('name');

    return OnboardingCatalog(
      universities: [
        for (final row in universityRows)
          UniversityOption(
            id: _requiredString(row, 'id'),
            name: _requiredString(row, 'name'),
          ),
      ],
      campuses: [
        for (final row in campusRows)
          CampusOption(
            id: _requiredString(row, 'id'),
            universityId: _requiredString(row, 'university_id'),
            name: _requiredString(row, 'name'),
            isMain: row['is_main'] == true,
          ),
      ],
      termTemplates: [
        for (final row in termRows)
          TermTemplateOption(
            id: _requiredString(row, 'id'),
            universityId: _requiredString(row, 'university_id'),
            name: _requiredString(row, 'name'),
            academicYear: _requiredInt(row, 'academic_year'),
          ),
      ],
      periodTemplateSets: [
        for (final row in periodSetRows)
          PeriodTemplateSetOption(
            id: _requiredString(row, 'id'),
            universityId: _requiredString(row, 'university_id'),
            campusId: _nullableString(row, 'campus_id'),
            name: _requiredString(row, 'name'),
            academicYear: _nullableInt(row, 'academic_year'),
            isDefault: row['is_default'] == true,
            userType: _nullableUserType(row, 'user_type'),
          ),
      ],
    );
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AppError {
      rethrow;
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        throw const PermissionError('この設定を更新する権限がありません');
      }
      if (error.code == '22023' || error.code == '23505') {
        throw const ValidationError('選択した設定を確認してもう一度お試しください');
      }
      throw const UnknownAppError('オンボーディング設定の取得に失敗しました');
    } on SocketException {
      throw const NetworkError('ネットワーク接続を確認してください。');
    } on TimeoutException {
      throw const NetworkError('通信が完了しませんでした。もう一度お試しください。');
    } on Object {
      throw const UnknownAppError('オンボーディング設定の取得に失敗しました');
    }
  }

  Map<String, dynamic> _firstRow(Object? value) {
    final Object? row =
        value is List ? (value.isEmpty ? null : value.first) : value;
    if (row is Map<String, dynamic>) return row;
    if (row is Map) return Map<String, dynamic>.from(row);
    throw const UnknownAppError('オンボーディング完了結果が不正です');
  }

  String _requiredString(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value;
    throw UnknownAppError('$key is missing from the onboarding response.');
  }

  String? _nullableString(Map<String, dynamic> row, String key) {
    final value = row[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  int _requiredInt(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw UnknownAppError('$key is missing from the onboarding response.');
  }

  int? _nullableInt(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  OnboardingUserType? _nullableUserType(
    Map<String, dynamic> row,
    String key,
  ) {
    return switch (row[key]) {
      'undergraduate' => OnboardingUserType.undergraduate,
      'graduate' => OnboardingUserType.graduate,
      'other' => OnboardingUserType.other,
      _ => null,
    };
  }

  OnboardingUserType _userTypeFromWire(String value) {
    return switch (value) {
      'undergraduate' => OnboardingUserType.undergraduate,
      'graduate' => OnboardingUserType.graduate,
      'other' => OnboardingUserType.other,
      _ => throw const UnknownAppError('プロフィールのユーザー種別が不正です'),
    };
  }

  DateTime _requiredDateTime(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw UnknownAppError('$key is missing from the onboarding response.');
  }

  DateTime? _nullableDateTime(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  OnboardingTermRecord _termRecord(Map<String, dynamic> row) {
    return OnboardingTermRecord(
      id: _requiredString(row, 'id'),
      universityId: _requiredString(row, 'university_id'),
      ownerUserId: _requiredString(row, 'owner_user_id'),
      configKey: _nullableString(row, 'config_key'),
      sourceTemplateId: _nullableString(row, 'source_template_id'),
      name: _requiredString(row, 'name'),
      academicYear: _requiredInt(row, 'academic_year'),
      startDate: _requiredDateTime(row, 'start_date'),
      endDate: _requiredDateTime(row, 'end_date'),
      instructionStartDate: _nullableDateTime(row, 'instruction_start_date'),
      instructionEndDate: _nullableDateTime(row, 'instruction_end_date'),
      termType: _requiredString(row, 'term_type'),
      updatedAt: _requiredDateTime(row, 'updated_at'),
      version: _requiredInt(row, 'version'),
    );
  }

  OnboardingPeriodSettingRecord _periodRecord(Map<String, dynamic> row) {
    return OnboardingPeriodSettingRecord(
      id: _requiredString(row, 'id'),
      ownerUserId: _requiredString(row, 'owner_user_id'),
      universityId: _requiredString(row, 'university_id'),
      termId: _requiredString(row, 'term_id'),
      sourceTemplateSetId: _nullableString(row, 'source_template_set_id'),
      dayOfWeek: _requiredInt(row, 'day_of_week'),
      periodNo: _requiredInt(row, 'period_no'),
      startTimeMinutes: _timeMinutes(row, 'start_time'),
      endTimeMinutes: _timeMinutes(row, 'end_time'),
      updatedAt: _requiredDateTime(row, 'updated_at'),
      version: _requiredInt(row, 'version'),
    );
  }

  int _timeMinutes(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is! String) {
      throw UnknownAppError('$key is missing from the onboarding response.');
    }
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$')
        .firstMatch(value.trim());
    final hour = int.tryParse(match?.group(1) ?? '');
    final minute = int.tryParse(match?.group(2) ?? '');
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 24 ||
        minute < 0 ||
        minute > 59 ||
        (hour == 24 && minute != 0)) {
      throw UnknownAppError('$key is invalid in the onboarding response.');
    }
    return hour * 60 + minute;
  }

  OnboardingStatus _statusFromWire(String value) {
    return switch (value) {
      'not_started' => OnboardingStatus.notStarted,
      'in_progress' => OnboardingStatus.inProgress,
      'complete' => OnboardingStatus.complete,
      _ => throw const UnknownAppError('プロフィールの進捗状態が不正です'),
    };
  }
}
