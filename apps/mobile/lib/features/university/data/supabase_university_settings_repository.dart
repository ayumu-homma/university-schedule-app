import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error.dart';
import '../domain/university_settings_models.dart';
import '../domain/university_settings_repository.dart';

class SupabaseUniversitySettingsRepository
    implements UniversitySettingsRepository {
  SupabaseUniversitySettingsRepository({
    required SupabaseClient client,
    required String userId,
  })  : _client = client,
        _userId = userId;

  final SupabaseClient _client;
  final String _userId;
  String? _pendingRequestOperationId;

  @override
  Future<List<UniversityRequestRecord>> loadRequests() {
    return _guard(() async {
      final rows = await _client
          .from('university_requests')
          .select('id,name,prefecture,official_url,status,created_at')
          .eq('requested_by', _userId)
          .order('created_at', ascending: false);
      return [for (final row in rows) _record(row)];
    }, '大学追加申請を取得できませんでした');
  }

  @override
  Future<String> submitRequest(UniversityRequestInput input) {
    return _guard(() async {
      try {
        input.validate();
      } on ArgumentError {
        throw const ValidationError('大学名と公式URLを確認してください');
      }
      final value = input.normalized();
      final response = await _client.rpc('submit_university_request', params: {
        'p_name': value.name,
        'p_prefecture': value.prefecture,
        'p_official_url': value.officialUrl,
        'p_operation_id': _pendingRequestOperationId ??= const Uuid().v4(),
      });
      if (response is String && response.trim().isNotEmpty) {
        _pendingRequestOperationId = null;
        return response;
      }
      throw const UnknownAppError('大学追加申請の受付結果が不正です');
    }, '大学追加申請を送信できませんでした');
  }

  @override
  Future<void> changeUniversity(String universityId) {
    return _guard(() async {
      if (universityId.trim().isEmpty) {
        throw const ValidationError('大学を選択してください');
      }
      await _client.rpc(
        'change_university',
        params: {'p_university_id': universityId},
      );
    }, '大学を変更できませんでした');
  }

  UniversityRequestRecord _record(Map<String, dynamic> row) {
    return UniversityRequestRecord(
      id: _requiredString(row, 'id'),
      name: _requiredString(row, 'name'),
      prefecture: _nullableString(row, 'prefecture'),
      officialUrl: _nullableString(row, 'official_url'),
      status: UniversityRequestStatus.fromWire(
        _requiredString(row, 'status'),
      ),
      createdAt: _requiredDateTime(row, 'created_at'),
    );
  }

  Future<T> _guard<T>(
    Future<T> Function() operation,
    String fallbackMessage,
  ) async {
    try {
      return await operation();
    } on AppError {
      rethrow;
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        throw const PermissionError('大学設定を変更する権限がありません');
      }
      if (error.code == '22023' || error.code == '23505') {
        throw const ValidationError('入力内容または申請上限を確認してください');
      }
      throw UnknownAppError(fallbackMessage);
    } on Object {
      throw UnknownAppError(fallbackMessage);
    }
  }

  String _requiredString(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value;
    throw UnknownAppError('$key is missing from the university response.');
  }

  String? _nullableString(Map<String, dynamic> row, String key) {
    final value = row[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  DateTime _requiredDateTime(Map<String, dynamic> row, String key) {
    final value = row[key];
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw UnknownAppError('$key is missing from the university response.');
  }
}
