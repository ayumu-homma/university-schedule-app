import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_error.dart';
import '../domain/term_period_models.dart';
import '../domain/term_period_repository.dart';

typedef TermPeriodRpc = Future<Object?> Function(
  String functionName,
  Map<String, Object?> parameters,
);

typedef TermPeriodProfileLookup = Future<Map<String, Object?>> Function(
  String userId,
);

typedef PersonalTermRowsLookup = Future<List<Map<String, Object?>>> Function(
  String userId,
);

typedef PersonalPeriodRowsLookup = Future<List<Map<String, Object?>>> Function({
  required String userId,
  required String termId,
});

/// Authenticated adapter for private personal-term and period snapshots.
///
/// The RPCs own all mutations.  Direct reads stay owner-filtered by RLS so the
/// UI can render each private snapshot without receiving a raw write path.
class SupabaseTermPeriodRepository implements TermPeriodRepository {
  SupabaseTermPeriodRepository({
    required String userId,
    SupabaseClient? client,
    TermPeriodRpc? rpcOverride,
    TermPeriodProfileLookup? profileLookupOverride,
    PersonalTermRowsLookup? termRowsLookupOverride,
    PersonalPeriodRowsLookup? periodRowsLookupOverride,
    String? Function()? authenticatedUserIdOverride,
  })  : _userId = userId,
        _client = client,
        _rpcOverride = rpcOverride,
        _profileLookupOverride = profileLookupOverride,
        _termRowsLookupOverride = termRowsLookupOverride,
        _periodRowsLookupOverride = periodRowsLookupOverride,
        _authenticatedUserIdOverride = authenticatedUserIdOverride,
        assert(client != null || rpcOverride != null),
        assert(client != null || profileLookupOverride != null),
        assert(client != null || termRowsLookupOverride != null),
        assert(client != null || periodRowsLookupOverride != null);

  final String _userId;
  final SupabaseClient? _client;
  final TermPeriodRpc? _rpcOverride;
  final TermPeriodProfileLookup? _profileLookupOverride;
  final PersonalTermRowsLookup? _termRowsLookupOverride;
  final PersonalPeriodRowsLookup? _periodRowsLookupOverride;
  final String? Function()? _authenticatedUserIdOverride;

  @override
  Future<PersonalTermPeriodSnapshot> load() {
    return _guard(() async {
      _requireAuthenticatedUser();
      final profile = await _profileForUser();
      final ownerUserId = _requiredString(profile, 'user_id');
      final universityId = _requiredString(profile, 'university_id');
      if (ownerUserId != _userId) {
        throw const PermissionError('別の利用者の学期設定は取得できません。');
      }
      final rows = await _termsForUser();
      final terms = [
        for (final row in rows)
          _termFromRow(
            row,
            expectedUniversityId: universityId,
          ),
      ];
      final activeTermId = _nullableString(profile['active_term_id']);
      if (activeTermId != null &&
          !terms.any((term) => term.id == activeTermId)) {
        throw const PermissionError('有効な学期設定を確認できませんでした。');
      }
      return PersonalTermPeriodSnapshot(
        ownerUserId: ownerUserId,
        universityId: universityId,
        activeTermId: activeTermId,
        terms: terms,
      );
    });
  }

  @override
  Future<List<PersonalPeriodSetting>> loadPeriods(String termId) {
    return _guard(() async {
      _requireAuthenticatedUser();
      if (termId.trim().isEmpty) {
        throw const ValidationError('学期を選択してください。');
      }
      final snapshot = await load();
      if (!snapshot.terms.any((term) => term.id == termId)) {
        throw const PermissionError('選択した学期は利用できません。');
      }
      final rows = await _periodRowsForTerm(termId);
      return [
        for (final row in rows)
          _periodFromRow(
            row,
            expectedUniversityId: snapshot.universityId,
            expectedTermId: termId,
          ),
      ]..sort((left, right) {
          final day = left.dayOfWeek.compareTo(right.dayOfWeek);
          return day != 0 ? day : left.periodNo.compareTo(right.periodNo);
        });
    });
  }

  @override
  Future<PersonalTermMutation> createTerm(PersonalTermCreateInput input) {
    return _guard(() async {
      _requireAuthenticatedUser();
      try {
        input.validate();
      } on ArgumentError {
        throw const ValidationError('学期と時限の入力内容を確認してください。');
      }
      final response = await _rpc(
        'create_personal_term',
        {
          'p_term_template_id': _nullIfBlank(input.termTemplateId),
          'p_custom_term_name': _nullIfBlank(input.customName),
          'p_custom_academic_year': input.customAcademicYear,
          'p_custom_start_date': _dateText(input.customStartDate),
          'p_custom_end_date': _dateText(input.customEndDate),
          'p_custom_term_type': input.customType?.wireName,
          'p_period_template_set_id': input.periodSettings.templateSetId,
          'p_custom_periods': input.periodSettings.customPeriods,
          'p_make_active': input.makeActive,
        },
      );
      final row = _firstRow(response);
      return PersonalTermMutation(
        termId: _requiredString(row, 'term_id'),
        activeTermId: _requiredString(row, 'active_term_id'),
      );
    });
  }

  @override
  Future<void> activateTerm(String termId) {
    return _guard(() async {
      _requireAuthenticatedUser();
      if (termId.trim().isEmpty) {
        throw const ValidationError('学期を選択してください。');
      }
      await _rpc('activate_personal_term', {'p_term_id': termId});
    });
  }

  @override
  Future<int> replacePeriods({
    required String termId,
    required PeriodSettingsInput input,
  }) {
    return _guard(() async {
      _requireAuthenticatedUser();
      if (termId.trim().isEmpty) {
        throw const ValidationError('学期を選択してください。');
      }
      try {
        input.validate();
      } on ArgumentError {
        throw const ValidationError('時限の入力内容を確認してください。');
      }
      final response = await _rpc(
        'replace_personal_period_settings',
        {
          'p_term_id': termId,
          'p_period_template_set_id': input.templateSetId,
          'p_custom_periods': input.customPeriods,
        },
      );
      final value = _nullableInt(response);
      if (value == null || value < 1) {
        throw const UnknownAppError('時限設定の更新結果を確認できませんでした。');
      }
      return value;
    });
  }

  void _requireAuthenticatedUser() {
    if (_userId.trim().isEmpty) {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    }
    final authenticatedUserId =
        _authenticatedUserIdOverride?.call() ?? _client?.auth.currentUser?.id;
    if (authenticatedUserId != _userId) {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    }
  }

  Future<Object?> _rpc(
    String functionName,
    Map<String, Object?> parameters,
  ) {
    final override = _rpcOverride;
    if (override != null) return override(functionName, parameters);
    final client = _client;
    if (client == null) {
      throw const AuthError('Supabase クライアントを利用できません。');
    }
    return client.rpc(functionName, params: parameters);
  }

  Future<Map<String, Object?>> _profileForUser() async {
    final override = _profileLookupOverride;
    if (override != null) return override(_userId);
    final client = _client;
    if (client == null) {
      throw const AuthError('Supabase クライアントを利用できません。');
    }
    final row = await client
        .from('profiles')
        .select('user_id,university_id,active_term_id,onboarding_status')
        .eq('user_id', _userId)
        .maybeSingle();
    if (row == null) {
      throw const PermissionError('学期設定に必要なプロフィールがありません。');
    }
    return Map<String, Object?>.from(row);
  }

  Future<List<Map<String, Object?>>> _termsForUser() async {
    final override = _termRowsLookupOverride;
    if (override != null) return override(_userId);
    final client = _client;
    if (client == null) {
      throw const AuthError('Supabase クライアントを利用できません。');
    }
    final rows = await client
        .from('terms')
        .select(
          'id,owner_user_id,university_id,name,academic_year,start_date,'
          'end_date,instruction_start_date,instruction_end_date,term_type,'
          'source_template_id,is_template,status,deleted_at,updated_at,version',
        )
        .eq('owner_user_id', _userId)
        .eq('is_template', false)
        .eq('status', 'active')
        .isFilter('deleted_at', null)
        .order('academic_year', ascending: false)
        .order('start_date', ascending: false);
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  Future<List<Map<String, Object?>>> _periodRowsForTerm(String termId) async {
    final override = _periodRowsLookupOverride;
    if (override != null) {
      return override(userId: _userId, termId: termId);
    }
    final client = _client;
    if (client == null) {
      throw const AuthError('Supabase クライアントを利用できません。');
    }
    final rows = await client
        .from('period_settings')
        .select(
          'id,owner_user_id,university_id,term_id,source_template_set_id,'
          'day_of_week,period_no,start_time,end_time,updated_at,version,deleted_at',
        )
        .eq('owner_user_id', _userId)
        .eq('term_id', termId)
        .isFilter('deleted_at', null);
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  PersonalTerm _termFromRow(
    Map<String, Object?> row, {
    required String expectedUniversityId,
  }) {
    final ownerUserId = _requiredString(row, 'owner_user_id');
    final universityId = _requiredString(row, 'university_id');
    if (ownerUserId != _userId ||
        universityId != expectedUniversityId ||
        row['is_template'] == true ||
        row['deleted_at'] != null ||
        _requiredString(row, 'status') != 'active') {
      throw const PermissionError('学期設定の所有者または大学を確認できません。');
    }
    return PersonalTerm(
      id: _requiredString(row, 'id'),
      ownerUserId: ownerUserId,
      universityId: universityId,
      name: _requiredString(row, 'name'),
      academicYear: _requiredInt(row, 'academic_year'),
      startDate: _requiredDate(row, 'start_date'),
      endDate: _requiredDate(row, 'end_date'),
      instructionStartDate: _nullableDate(row, 'instruction_start_date'),
      instructionEndDate: _nullableDate(row, 'instruction_end_date'),
      type: PersonalTermType.fromWire(_requiredString(row, 'term_type')),
      sourceTemplateId: _nullableString(row['source_template_id']),
      updatedAt: _requiredDateTime(row, 'updated_at'),
      version: _requiredInt(row, 'version'),
    );
  }

  PersonalPeriodSetting _periodFromRow(
    Map<String, Object?> row, {
    required String expectedUniversityId,
    required String expectedTermId,
  }) {
    final ownerUserId = _requiredString(row, 'owner_user_id');
    final universityId = _requiredString(row, 'university_id');
    final termId = _requiredString(row, 'term_id');
    if (ownerUserId != _userId ||
        universityId != expectedUniversityId ||
        termId != expectedTermId ||
        row['deleted_at'] != null) {
      throw const PermissionError('時限設定の所有者または学期を確認できません。');
    }
    return PersonalPeriodSetting(
      id: _requiredString(row, 'id'),
      ownerUserId: ownerUserId,
      universityId: universityId,
      termId: termId,
      sourceTemplateSetId: _nullableString(row['source_template_set_id']),
      dayOfWeek: _requiredInt(row, 'day_of_week'),
      periodNo: _requiredInt(row, 'period_no'),
      startTimeMinutes: _timeMinutes(row, 'start_time'),
      endTimeMinutes: _timeMinutes(row, 'end_time'),
      updatedAt: _requiredDateTime(row, 'updated_at'),
      version: _requiredInt(row, 'version'),
    );
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AppError {
      rethrow;
    } on AuthException {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    } on PostgrestException catch (error) {
      if (error.code == '42501' || error.code == 'PGRST301') {
        throw const PermissionError('この学期または時限を更新する権限がありません。');
      }
      if (error.code == '22023' || error.code == '23503') {
        throw const ValidationError('学期または時限の入力内容を確認してください。');
      }
      throw const UnknownAppError('学期設定を取得または更新できませんでした。');
    } on SocketException {
      throw const NetworkError('ネットワーク接続を確認してください。');
    } on TimeoutException {
      throw const NetworkError('通信が完了しませんでした。もう一度お試しください。');
    } on Object {
      throw const UnknownAppError('学期設定を取得または更新できませんでした。');
    }
  }

  Map<String, Object?> _firstRow(Object? value) {
    final Object? row =
        value is List ? (value.isEmpty ? null : value.first) : value;
    if (row is Map) return Map<String, Object?>.from(row);
    throw const UnknownAppError('学期設定の更新結果を確認できませんでした。');
  }

  String _requiredString(Map<String, Object?> row, String key) {
    final value = _nullableString(row[key]);
    if (value == null) {
      throw const UnknownAppError('学期設定の形式を確認できませんでした。');
    }
    return value;
  }

  String? _nullableString(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  int _requiredInt(Map<String, Object?> row, String key) {
    final value = _nullableInt(row[key]);
    if (value == null) {
      throw const UnknownAppError('学期設定の形式を確認できませんでした。');
    }
    return value;
  }

  int? _nullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return value == null ? null : int.tryParse(value.toString());
  }

  DateTime _requiredDate(Map<String, Object?> row, String key) {
    final value = _nullableDate(row, key);
    if (value == null) {
      throw const UnknownAppError('学期の日付を確認できませんでした。');
    }
    return value;
  }

  DateTime? _nullableDate(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is DateTime) {
      return DateTime.utc(value.year, value.month, value.day);
    }
    final text = _nullableString(value);
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text ?? '');
    if (match == null) return null;
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) return null;
    final parsed = DateTime.utc(year, month, day);
    return parsed.year == year && parsed.month == month && parsed.day == day
        ? parsed
        : null;
  }

  DateTime _requiredDateTime(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw const UnknownAppError('学期設定の形式を確認できませんでした。');
  }

  int _timeMinutes(Map<String, Object?> row, String key) {
    final value = _nullableString(row[key]);
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$')
        .firstMatch(value ?? '');
    final hour = int.tryParse(match?.group(1) ?? '');
    final minute = int.tryParse(match?.group(2) ?? '');
    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 24 ||
        minute < 0 ||
        minute > 59 ||
        (hour == 24 && minute != 0)) {
      throw const UnknownAppError('時限の時刻を確認できませんでした。');
    }
    return hour * 60 + minute;
  }

  String? _nullIfBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String? _dateText(DateTime? value) {
    if (value == null) return null;
    return '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }
}
