import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error.dart';
import '../../../core/sync/drift_sync_queue.dart';
import '../../../core/sync/remote_schedule_gateway.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../local_db/app_database.dart' as local;
import '../../timetable/data/local_schedule_repository.dart';

typedef CourseTemplateRpc = Future<Object?> Function(
  String functionName,
  Map<String, Object?> parameters,
);

typedef CopiedCourseLookup = Future<Map<String, Object?>> Function({
  required String courseId,
  required String ownerUserId,
});

/// Authenticated production adapter for the server-owned course catalog.
///
/// Search results and copied courses are cached in Drift so the rest of the
/// schedule UI continues to have one reactive local source of truth. Copying
/// itself is performed only by the same-university Supabase RPC; its resulting
/// snapshot is read through the authenticated schedule-delta RPC, never a
/// direct Table API grant. This adapter never queues a duplicate create.
class SupabaseCourseTemplateRepository
    implements CourseTemplateRepository, CourseTemplateContributionRepository {
  SupabaseCourseTemplateRepository({
    required this.db,
    required this.context,
    required this.clock,
    SupabaseClient? client,
    CourseTemplateRpc? rpcOverride,
    CopiedCourseLookup? copiedCourseLookupOverride,
    RemoteScheduleGateway? scheduleGateway,
    String? Function()? authenticatedUserIdOverride,
    domain.CourseNormalizer? normalizer,
    this.offlineFirst = false,
  })  : _client = client,
        _rpcOverride = rpcOverride,
        _copiedCourseLookupOverride = copiedCourseLookupOverride,
        _scheduleGateway = scheduleGateway,
        _authenticatedUserIdOverride = authenticatedUserIdOverride,
        _normalizer = normalizer ?? domain.CourseNormalizer(),
        assert(client != null || rpcOverride != null),
        assert(
          client != null ||
              copiedCourseLookupOverride != null ||
              scheduleGateway != null,
        );

  final local.AppDatabase db;
  final ActiveScheduleContext context;
  final DateTime Function() clock;
  final SupabaseClient? _client;
  final CourseTemplateRpc? _rpcOverride;
  final CopiedCourseLookup? _copiedCourseLookupOverride;
  final RemoteScheduleGateway? _scheduleGateway;
  final String? Function()? _authenticatedUserIdOverride;
  final domain.CourseNormalizer _normalizer;
  final bool offlineFirst;

  @override
  Future<List<domain.CourseTemplate>> searchTemplates({
    required String universityId,
    required int academicYear,
    String? termId,
    String query = '',
    String instructor = '',
    int? weekday,
    int? period,
  }) async {
    _requireActiveSearchContext(
      universityId: universityId,
      academicYear: academicYear,
      termId: termId,
    );
    _validateOptionalSlot(weekday, 'weekday');
    _validateOptionalSlot(period, 'period');

    final response = await _guardRemoteCall(
      () => _rpc(
        'search_course_templates',
        {
          'query_text': query.trim(),
          'target_university_id': context.universityId,
          'target_academic_year': context.academicYear,
          'target_term_id': termId,
          'target_day_of_week': weekday,
          'target_period_no': period,
          'target_instructor_name': instructor.trim(),
          'limit_count': 50,
        },
      ),
    );
    final rows = _responseRows(response);
    final templates = rows.map(_templateFromRpcRow).toList(growable: false);
    await _cacheTemplates(templates);
    return templates;
  }

  @override
  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  }) async {
    _requireAuthenticatedOwner(ownerUserId);
    if (termId != context.termId) {
      throw const PermissionError(
        '選択中ではない学期へ授業をコピーすることはできません。',
      );
    }
    if (templateId.trim().isEmpty || templateId != templateId.trim()) {
      throw const ValidationError('コピーする授業テンプレートが不正です。');
    }

    final response = await _guardRemoteCall(
      () => _rpc(
        'copy_course_template',
        {
          'template_id': templateId,
          'target_term_id': context.termId,
        },
      ),
    );
    final copiedCourseId = response is String ? response : null;
    if (copiedCourseId == null || copiedCourseId.trim().isEmpty) {
      throw const UnknownAppError(
        '授業コピーの応答を確認できませんでした。もう一度お試しください。',
      );
    }

    final copiedRow = await _guardRemoteCall(
      () => _lookupCopiedCourse(
        courseId: copiedCourseId,
        ownerUserId: ownerUserId,
      ),
    );
    await _cacheCopiedCourse(
      copiedRow,
      expectedCourseId: copiedCourseId,
      expectedTemplateId: templateId,
      expectedOwnerUserId: ownerUserId,
      expectedTermId: termId,
    );
    return copiedCourseId;
  }

  @override
  Future<Map<String, Object?>> publishTemplate({
    required String courseId,
    String? operationId,
  }) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    if (offlineFirst) {
      return _queueTemplateOperation(
        entityType: 'course_template_publish',
        courseId: courseId,
        operationId: operationId ?? const Uuid().v4(),
      );
    }
    final response = await _guardRemoteCall(
      () => _rpc('publish_course_template', {
        'p_user_course_id': courseId,
        'p_operation_id': operationId ?? const Uuid().v4(),
      }),
    );
    return _responseMap(response);
  }

  @override
  Future<Map<String, Object?>> submitEditProposal({
    required String templateId,
    required Map<String, Object?> proposedPayload,
    required int expectedVersion,
    String? operationId,
  }) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    if (templateId.trim().isEmpty || proposedPayload.isEmpty) {
      throw const ValidationError('修正内容を入力してください。');
    }
    final response = await _guardRemoteCall(
      () => _rpc('submit_course_template_edit_proposal', {
        'p_template_id': templateId,
        'p_proposed_payload': proposedPayload,
        'p_expected_version': expectedVersion,
        'p_operation_id': operationId ?? const Uuid().v4(),
      }),
    );
    return _responseMap(response);
  }

  @override
  Future<Map<String, Object?>> reportTemplate({
    required String templateId,
    required String reason,
    String? operationId,
  }) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    if (templateId.trim().isEmpty || reason.trim().isEmpty) {
      throw const ValidationError('通報理由を入力してください。');
    }
    final response = await _guardRemoteCall(
      () => _rpc('report_course_template', {
        'p_template_id': templateId,
        'p_reason': reason.trim(),
        'p_operation_id': operationId ?? const Uuid().v4(),
      }),
    );
    return _responseMap(response);
  }

  @override
  Future<Map<String, Object?>> templateDetails(String templateId) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    final response = await _guardRemoteCall(
      () => _rpc('get_course_template_for_user', {
        'p_template_id': templateId,
      }),
    );
    return _responseMap(response);
  }

  @override
  Future<Map<String, Object?>> templateUpdate(String courseId) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    final response = await _guardRemoteCall(
      () => _rpc('get_course_template_update', {
        'p_user_course_id': courseId,
      }),
    );
    return _responseMap(response);
  }

  @override
  Future<Map<String, Object?>> reviewTemplateUpdate({
    required String courseId,
    required String action,
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  }) async {
    _requireAuthenticatedOwner(context.ownerUserId);
    if (action != 'apply' && action != 'ignore') {
      throw const ValidationError('更新の反映方法が不正です。');
    }
    if (offlineFirst) {
      return _queueTemplateOperation(
        entityType: 'course_template_update_apply',
        courseId: courseId,
        operationId: const Uuid().v4(),
        action: action,
        expectedTemplateVersion: expectedTemplateVersion,
        expectedCourseVersion: expectedCourseVersion,
      );
    }
    final response = await _guardRemoteCall(
      () => _rpc('review_course_template_update', {
        'p_user_course_id': courseId,
        'p_action': action,
        'p_expected_template_version': expectedTemplateVersion,
        'p_expected_course_version': expectedCourseVersion,
        'p_operation_id': const Uuid().v4(),
      }),
    );
    return _responseMap(response);
  }

  Future<Map<String, Object?>> _queueTemplateOperation({
    required String entityType,
    required String courseId,
    required String operationId,
    String action = 'apply',
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  }) async {
    final row = await (db.select(db.userCourses)
          ..where((course) =>
              course.id.equals(courseId) &
              course.ownerUserId.equals(context.ownerUserId)))
        .getSingleOrNull();
    if (row == null || row.deletedAt != null) {
      throw const PermissionError('対象の個人授業が見つかりません。');
    }
    final now = clock().toUtc();
    await DriftSyncQueue(db, ownerUserId: context.ownerUserId).enqueue(
      PendingMutation(
        clientMutationId: operationId,
        ownerUserId: context.ownerUserId,
        entityType: entityType,
        entityId: courseId,
        operation: SyncOperation.submit,
        baseVersion: entityType == 'course_template_update_apply'
            ? (expectedCourseVersion ?? row.version)
            : null,
        payload: {
          'id': row.id,
          'ownerUserId': row.ownerUserId,
          'termId': row.termId,
          'title': row.title,
          'normalizedTitle': row.normalizedTitle,
          'instructorName': row.instructorName,
          'normalizedInstructorName': row.normalizedInstructorName,
          'dayOfWeek': row.dayOfWeek,
          'periodNo': row.periodNo,
          'room': row.room,
          'color': row.color,
          'visibilityLevel': row.visibilityLevel,
          'updatedAt': row.updatedAt,
          'version': row.version,
          if (expectedTemplateVersion != null)
            'expectedTemplateVersion': expectedTemplateVersion,
          'action': action,
        },
        createdAt: now,
      ),
    );
    return {
      'course_id': courseId,
      'personal_course_id': courseId,
      'status': 'queued',
      'operation_id': operationId,
    };
  }

  void _requireActiveSearchContext({
    required String universityId,
    required int academicYear,
    required String? termId,
  }) {
    _requireAuthenticatedOwner(context.ownerUserId);
    if (universityId != context.universityId ||
        academicYear != context.academicYear ||
        (termId != null && termId != context.termId)) {
      throw const PermissionError(
        '選択中の大学・学期以外の授業は検索できません。',
      );
    }
  }

  void _requireAuthenticatedOwner(String ownerUserId) {
    context.validate();
    if (ownerUserId != context.ownerUserId) {
      throw const PermissionError('別の利用者の時間割は操作できません。');
    }
    final authenticatedUserId =
        _authenticatedUserIdOverride?.call() ?? _client?.auth.currentUser?.id;
    if (authenticatedUserId != context.ownerUserId) {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    }
  }

  void _validateOptionalSlot(int? value, String argumentName) {
    if (value != null && (value < 1 || value > 9)) {
      throw ValidationError('$argumentName は 1〜9 の範囲で指定してください。');
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

  Future<Map<String, Object?>> _lookupCopiedCourse({
    required String courseId,
    required String ownerUserId,
  }) async {
    final override = _copiedCourseLookupOverride;
    if (override != null) {
      return override(courseId: courseId, ownerUserId: ownerUserId);
    }
    final client = _client;
    final gateway = _scheduleGateway;
    if (client == null && gateway == null) {
      throw const AuthError('Supabase クライアントを利用できません。');
    }
    final cached = await db.timetableDao.courseById(courseId, ownerUserId);
    if (cached != null) return _rowFromCachedCourse(cached);

    return _findCopiedCourseInScheduleDelta(
      gateway ?? SupabaseScheduleGateway(client: client!),
      courseId: courseId,
      ownerUserId: ownerUserId,
    );
  }

  Future<Map<String, Object?>> _findCopiedCourseInScheduleDelta(
    RemoteScheduleGateway gateway, {
    required String courseId,
    required String ownerUserId,
  }) async {
    var afterCursor = 0;
    while (true) {
      final page = await gateway.pullDelta(
        ownerUserId: ownerUserId,
        afterCursor: afterCursor,
        limit: 500,
      );
      for (final change in page.changes) {
        if (change.entityType == 'user_course' &&
            change.entityId == courseId &&
            change.operation == ScheduleDeltaOperation.upsert) {
          return _rowFromScheduleDelta(change);
        }
      }
      if (!page.hasMore) break;
      if (page.nextCursor <= afterCursor) {
        throw const UnknownAppError('授業同期データの継続位置を確認できませんでした。');
      }
      afterCursor = page.nextCursor;
    }
    throw const PermissionError('コピーした授業を確認できませんでした。');
  }

  Map<String, Object?> _rowFromScheduleDelta(ScheduleDeltaChange change) {
    final payload = change.payload;
    if (change.deletedAt != null || payload['deletedAt'] != null) {
      throw const PermissionError('コピーした授業は利用できません。');
    }
    if (_nullableString(payload['id']) != change.entityId ||
        _nullableInt(payload['version']) != change.serverVersion) {
      throw const UnknownAppError('コピーした授業の同期データを確認できませんでした。');
    }
    return {
      'id': payload['id'],
      'owner_user_id': payload['ownerUserId'],
      'term_id': payload['termId'],
      'source_template_id': payload['sourceTemplateId'],
      'title': payload['title'],
      'normalized_title': payload['normalizedTitle'],
      'instructor_name': payload['instructorName'],
      'normalized_instructor_name': payload['normalizedInstructorName'],
      'day_of_week': payload['dayOfWeek'],
      'period_no': payload['periodNo'],
      'room': payload['room'],
      'color': payload['color'],
      'visibility_level': payload['visibilityLevel'],
      'updated_at': _requiredOffsetDateTime(payload['updatedAt']),
      'deleted_at': null,
      'version': change.serverVersion,
    };
  }

  Map<String, Object?> _rowFromCachedCourse(local.UserCourse course) {
    return {
      'id': course.id,
      'owner_user_id': course.ownerUserId,
      'term_id': course.termId,
      'source_template_id': course.sourceTemplateId,
      'title': course.title,
      'normalized_title': course.normalizedTitle,
      'instructor_name': course.instructorName,
      'normalized_instructor_name': course.normalizedInstructorName,
      'day_of_week': course.dayOfWeek,
      'period_no': course.periodNo,
      'room': course.room,
      'color': course.color,
      'visibility_level': course.visibilityLevel,
      'updated_at': course.updatedAt,
      'deleted_at': course.deletedAt,
      'version': course.version,
    };
  }

  List<Map<String, Object?>> _responseRows(Object? response) {
    if (response is! List) {
      throw const UnknownAppError(
        '授業検索の応答を確認できませんでした。もう一度お試しください。',
      );
    }
    return response.map((row) {
      if (row is! Map) {
        throw const UnknownAppError(
          '授業検索の応答を確認できませんでした。もう一度お試しください。',
        );
      }
      return Map<String, Object?>.from(row);
    }).toList(growable: false);
  }

  Map<String, Object?> _responseMap(Object? response) {
    if (response is! Map) {
      throw const UnknownAppError('授業テンプレートの応答を確認できませんでした。');
    }
    return Map<String, Object?>.from(response);
  }

  domain.CourseTemplate _templateFromRpcRow(Map<String, Object?> row) {
    final id = _requiredString(row, 'id');
    final title = _requiredString(row, 'title');
    final universityId = _requiredString(row, 'university_id');
    final academicYear = _requiredInt(row, 'academic_year');
    if (universityId != context.universityId ||
        academicYear != context.academicYear) {
      throw const PermissionError(
        '検索結果に選択中の大学・年度以外の授業が含まれています。',
      );
    }
    return domain.CourseTemplate(
      id: id,
      universityId: universityId,
      academicYear: academicYear,
      termId: _nullableString(row['term_id']),
      title: title,
      normalizedTitle: _nullableString(row['normalized_title']) ??
          _normalizer.normalizeTitle(title),
      instructorName: _nullableString(row['instructor_name']),
      normalizedInstructorName:
          _nullableString(row['normalized_instructor_name']) ??
              _normalizer.normalizeInstructor(
                _nullableString(row['instructor_name']) ?? '',
              ),
      dayOfWeek: _nullableInt(row['day_of_week']),
      periodNo: _nullableInt(row['period_no']),
      room: _nullableString(row['room']),
      normalizedRoom: _nullableString(row['normalized_room']),
      creditCount: row['credit_count'] as num?,
      syllabusUrl: _nullableString(row['syllabus_url']),
      externalCourseCode: _nullableString(row['external_course_code']),
      copyCountTotal: _nullableInt(row['copy_count_total']) ?? 0,
      copyCountTerm: _nullableInt(row['copy_count_term']) ?? 0,
      trustScore: _nullableNum(row['trust_score']) ?? 0,
      duplicateKey: _nullableString(row['duplicate_key']),
      rankScore: _nullableNum(row['rank_score']),
    );
  }

  Future<void> _cacheTemplates(
    List<domain.CourseTemplate> templates,
  ) async {
    if (templates.isEmpty) return;
    final cachedAt = clock();
    await db.transaction(() async {
      for (final template in templates) {
        await db.courseTemplateDao.upsertTemplate(
          local.CourseTemplatesCacheCompanion.insert(
            id: template.id,
            universityId: template.universityId,
            academicYear: template.academicYear,
            termId: Value(template.termId),
            title: template.title,
            normalizedTitle: template.normalizedTitle,
            instructorName: Value(template.instructorName),
            normalizedInstructorName: Value(template.normalizedInstructorName),
            dayOfWeek: Value(template.dayOfWeek),
            periodNo: Value(template.periodNo),
            room: Value(template.room),
            normalizedRoom: Value(template.normalizedRoom),
            copyCountTotal: Value(template.copyCountTotal),
            copyCountTerm: Value(template.copyCountTerm),
            trustScore: Value(template.trustScore.toDouble()),
            cachedAt: Value(cachedAt),
          ),
        );
      }
    });
  }

  Future<void> _cacheCopiedCourse(
    Map<String, Object?> row, {
    required String expectedCourseId,
    required String expectedTemplateId,
    required String expectedOwnerUserId,
    required String expectedTermId,
  }) async {
    final id = _requiredString(row, 'id');
    final ownerUserId = _requiredString(row, 'owner_user_id');
    final termId = _requiredString(row, 'term_id');
    final sourceTemplateId = _requiredString(row, 'source_template_id');
    if (id != expectedCourseId ||
        ownerUserId != expectedOwnerUserId ||
        termId != expectedTermId ||
        sourceTemplateId != expectedTemplateId ||
        row['deleted_at'] != null) {
      throw const PermissionError(
        'コピーした授業の所有者または学期を確認できませんでした。',
      );
    }

    final title = _requiredString(row, 'title');
    final version = _requiredInt(row, 'version');
    final updatedAt = _requiredOffsetDateTime(row['updated_at']);
    final existing = await db.timetableDao.courseById(id, ownerUserId);
    if (existing != null && existing.version > version) return;
    await db.timetableDao.upsertCourse(
      local.UserCoursesCompanion.insert(
        id: id,
        ownerUserId: ownerUserId,
        termId: termId,
        sourceTemplateId: Value(sourceTemplateId),
        title: title,
        normalizedTitle: _nullableString(row['normalized_title']) ??
            _normalizer.normalizeTitle(title),
        instructorName: Value(_nullableString(row['instructor_name'])),
        normalizedInstructorName:
            Value(_nullableString(row['normalized_instructor_name'])),
        dayOfWeek: Value(_nullableInt(row['day_of_week'])),
        periodNo: Value(_nullableInt(row['period_no'])),
        room: Value(_nullableString(row['room'])),
        color: Value(_nullableString(row['color'])),
        visibilityLevel: Value(
          _nullableString(row['visibility_level']) ?? 'PRIVATE',
        ),
        updatedAt: Value(updatedAt),
        version: Value(version),
      ),
    );
  }

  Future<T> _guardRemoteCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AppError {
      rethrow;
    } on RemoteScheduleAuthenticationException {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    } on RemoteScheduleTransientException {
      throw const NetworkError('ネットワーク接続を確認してください。');
    } on RemoteScheduleProtocolException {
      throw const UnknownAppError('授業データの形式を確認できませんでした。');
    } on RemoteScheduleException {
      throw const UnknownAppError(
        '授業データを取得できませんでした。しばらくしてからお試しください。',
      );
    } on AuthException {
      throw const AuthError('ログイン状態を確認して、もう一度お試しください。');
    } on PostgrestException catch (error) {
      if (error.code == 'PT409' || error.code == '40001') {
        throw const ConflictError('授業テンプレートが更新されています。内容を確認して再試行してください。');
      }
      if (error.code == '42501' || error.code == 'PGRST301') {
        throw const PermissionError('この授業を表示またはコピーする権限がありません。');
      }
      throw const UnknownAppError(
        '授業データを取得できませんでした。しばらくしてからお試しください。',
      );
    } on SocketException {
      throw const NetworkError('ネットワーク接続を確認してください。');
    } on TimeoutException {
      throw const NetworkError('通信が完了しませんでした。もう一度お試しください。');
    } catch (_) {
      throw const UnknownAppError(
        '授業データを取得できませんでした。しばらくしてからお試しください。',
      );
    }
  }

  String _requiredString(Map<String, Object?> row, String key) {
    final value = _nullableString(row[key]);
    if (value == null) {
      throw const UnknownAppError('授業データの形式を確認できませんでした。');
    }
    return value;
  }

  int _requiredInt(Map<String, Object?> row, String key) {
    final value = _nullableInt(row[key]);
    if (value == null) {
      throw const UnknownAppError('授業データの形式を確認できませんでした。');
    }
    return value;
  }

  String? _nullableString(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  int? _nullableInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  num? _nullableNum(Object? value) {
    if (value == null) return null;
    if (value is num) return value;
    return num.tryParse(value.toString());
  }

  DateTime _requiredOffsetDateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    final text = value?.toString().trim() ?? '';
    if (!RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false)
            .hasMatch(text) ||
        DateTime.tryParse(text) == null) {
      throw const UnknownAppError('授業データの日時形式を確認できませんでした。');
    }
    return DateTime.parse(text).toUtc();
  }
}
