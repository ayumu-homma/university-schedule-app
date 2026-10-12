import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:sqlite3/sqlite3.dart' as sql;

import '../domain/local_notification_models.dart';
import '../../../core/native/sqlite_identity_handshake.dart';
import '../../../core/storage/sqlite_storage_guard.dart';

final Object _beforeReadZoneKey = Object();

final class LocalNotificationStorageIntegrityException implements Exception {
  const LocalNotificationStorageIntegrityException(this.detail);

  final Object detail;

  @override
  String toString() => 'LocalNotificationStorageIntegrityException($detail)';
}

final class LocalNotificationSnapshotCleanupException implements Exception {
  const LocalNotificationSnapshotCleanupException({
    required this.primary,
    required this.primaryStack,
    required this.cleanup,
    required this.cleanupStack,
  });

  final Object primary;
  final StackTrace primaryStack;
  final Object cleanup;
  final StackTrace cleanupStack;

  @override
  String toString() =>
      'LocalNotificationSnapshotCleanupException(primary: $primary, cleanup: $cleanup)';
}

final class CanonicalStorageLatchedException implements Exception {
  const CanonicalStorageLatchedException({
    required this.original,
    required this.originalStack,
  });

  final Object original;
  final StackTrace originalStack;

  @override
  String toString() => 'CanonicalStorageLatchedException($original)';
}

/// The context values used by native CAS validation.  The flags are kept as
/// raw values deliberately: a headless run must prove that the profile,
/// term, and calendar it read are still the active, non-deleted rows when the
/// native writer publishes the projection.
class LocalNotificationContextTuple {
  const LocalNotificationContextTuple({
    required this.ownerUserId,
    required this.universityId,
    required this.termId,
    required this.academicYear,
    required this.primaryCalendarId,
    required this.profileOnboardingStatus,
    required this.profileActive,
    required this.profileDeleted,
    required this.termOwnerUserId,
    required this.termStatus,
    required this.termIsTemplate,
    required this.termDeleted,
    required this.calendarDeleted,
  });

  final String ownerUserId;
  final String universityId;
  final String termId;
  final int academicYear;
  final String primaryCalendarId;
  final String profileOnboardingStatus;
  final bool profileActive;
  final bool profileDeleted;
  final String termOwnerUserId;
  final String termStatus;
  final bool termIsTemplate;
  final bool termDeleted;
  final bool calendarDeleted;

  Map<String, Object?> toJson() => {
        'ownerUserId': ownerUserId,
        'universityId': universityId,
        'termId': termId,
        'academicYear': academicYear,
        'primaryCalendarId': primaryCalendarId,
        'profileOnboardingStatus': profileOnboardingStatus,
        'profileActive': profileActive,
        'profileDeleted': profileDeleted,
        'termOwnerUserId': termOwnerUserId,
        'termStatus': termStatus,
        'termIsTemplate': termIsTemplate,
        'termDeleted': termDeleted,
        'calendarDeleted': calendarDeleted,
      };
}

/// A committed canonical read-only view.  It contains everything the pure
/// planner needs and no Drift database handle.  Native is the only writer of
/// the durable projection for headless runs.
class LocalNotificationReadonlySnapshot {
  const LocalNotificationReadonlySnapshot({
    required this.context,
    required this.settings,
    required this.courses,
    required this.periodSettings,
    required this.assignments,
    required this.assignmentStates,
    required this.exams,
    required this.events,
    required this.eventExceptions,
    required this.importedReminderRules,
    required this.sourceEpoch,
    required this.previousProjectionEpoch,
    required this.termStart,
    required this.termEnd,
    required this.instructionStart,
    required this.instructionEnd,
  });

  final LocalNotificationContextTuple context;
  final LocalNotificationSettingsValue settings;
  final List<domain.UserCourse> courses;
  final List<domain.PeriodSetting> periodSettings;
  final List<domain.Assignment> assignments;
  final Map<String, domain.AssignmentUserState> assignmentStates;
  final List<domain.Exam> exams;
  final List<domain.ScheduleEvent> events;
  final List<domain.EventException> eventExceptions;
  final Map<String, List<int>> importedReminderRules;
  final int sourceEpoch;
  final int previousProjectionEpoch;
  final DateTime termStart;
  final DateTime termEnd;
  final DateTime? instructionStart;
  final DateTime? instructionEnd;

  Map<String, Object?> contextJson() => context.toJson();
}

class LocalNotificationReadonlySnapshotRequest {
  const LocalNotificationReadonlySnapshotRequest({
    required this.databasePath,
    required this.regionId,
    required this.ownerUserId,
    required this.ownerHash,
    required this.nowUtc,
    this.expectedPreviousProjectionEpoch,
    this.activationToken,
    this.generation,
    this.jobRunToken,
  });

  final String databasePath;
  final String regionId;
  final String ownerUserId;
  final String ownerHash;
  final DateTime nowUtc;
  final int? expectedPreviousProjectionEpoch;
  final String? activationToken;
  final int? generation;
  final String? jobRunToken;
}

/// Runs the complete canonical snapshot read away from the caller isolate.
/// The worker initializes the background messenger before the identity and
/// health handshake, then uses the guarded loader so no production caller can
/// accidentally fall back to the synchronous raw reader.
Future<LocalNotificationReadonlySnapshot> loadReadonlySnapshotInBackground(
  LocalNotificationReadonlySnapshotRequest request, {
  bool allowNonCanonicalPath = false,
  RootIsolateToken? rootIsolateToken,
}) {
  final token =
      Platform.isAndroid ? rootIsolateToken ?? RootIsolateToken.instance : null;
  return Isolate.run(() async {
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }
    return LocalNotificationReadonlySnapshotLoader(
      allowNonCanonicalPath: allowNonCanonicalPath,
    ).loadGuarded(request);
  });
}

class LocalNotificationReadonlySnapshotLoader {
  const LocalNotificationReadonlySnapshotLoader({
    this.allowNonCanonicalPath = false,
  });

  /// Production calls must use the native canonical path.  The opt-out is
  /// only for isolated fixture databases in unit tests.
  final bool allowNonCanonicalPath;

  LocalNotificationReadonlySnapshot load(
    LocalNotificationReadonlySnapshotRequest request,
  ) {
    SqliteIdentityHandshake.requireVerified();
    _validateRequest(request);
    final committedReceipt = _validateCommittedManifest(request);
    late sql.Database database;
    var databaseOpened = false;
    var transactionStarted = false;
    LocalNotificationReadonlySnapshot? snapshot;
    Object? primaryError;
    StackTrace? primaryStack;
    Object? cleanupError;
    StackTrace? cleanupStack;
    try {
      _beforeRead();
      database = sql.sqlite3.open(
        request.databasePath,
        mode: sql.OpenMode.readOnly,
      );
      databaseOpened = true;
      database.execute('PRAGMA busy_timeout = $sqliteBusyTimeoutMilliseconds');
      _validateStorage(database);
      _validateRegionMarker(database, request.regionId, committedReceipt);
      _beforeRead();
      database.execute('BEGIN');
      transactionStarted = true;
      final profile = _profileForRequest(database, request);
      if (profile == null) throw StateError('profile_unavailable');
      final resolvedOwner = _requiredString(profile['user_id']);
      final universityId = _string(profile['university_id']);
      final termId = _string(profile['active_term_id']);
      final calendarId = _string(profile['primary_calendar_id']);
      if (universityId == null || termId == null || calendarId == null) {
        throw StateError('context_incomplete');
      }
      final term = _single(
        database,
        'SELECT id, university_id, academic_year, start_date, end_date, '
        'instruction_start_date, instruction_end_date, term_type, '
        'is_template, status, deleted_at, owner_user_id FROM terms '
        'WHERE id = ? AND university_id = ? AND owner_user_id = ? LIMIT 1',
        [termId, universityId, resolvedOwner],
      );
      final calendar = _single(
        database,
        'SELECT id, owner_user_id FROM calendars '
        'WHERE id = ? AND owner_user_id = ? LIMIT 1',
        [calendarId, resolvedOwner],
      );
      if (term == null || calendar == null) {
        throw StateError('context_unavailable');
      }
      final academicYear = _integer(term['academic_year']) ??
          (throw StateError('context_incomplete'));
      final context = LocalNotificationContextTuple(
        ownerUserId: resolvedOwner,
        universityId: universityId,
        termId: termId,
        academicYear: academicYear,
        primaryCalendarId: calendarId,
        profileOnboardingStatus:
            _string(profile['onboarding_status']) ?? 'unknown',
        profileActive: _string(profile['onboarding_status']) == 'complete',
        profileDeleted: false,
        termOwnerUserId: _requiredString(term['owner_user_id']),
        termStatus: _string(term['status']) ?? 'unknown',
        termIsTemplate: _boolean(term['is_template']),
        termDeleted: term['deleted_at'] != null,
        calendarDeleted: false,
      );
      if (!context.profileActive ||
          context.termDeleted ||
          context.termIsTemplate ||
          context.termStatus != 'active') {
        throw StateError('context_inactive');
      }
      final expectedHash = sha256.convert(utf8.encode(resolvedOwner));
      if (request.ownerHash.isNotEmpty &&
          request.ownerHash != expectedHash.toString()) {
        throw StateError('owner_scope_mismatch');
      }
      final sourceEpoch = _integer(_single(
            database,
            'SELECT epoch FROM local_notification_source_revisions '
            'WHERE id = 1 LIMIT 1',
            const [],
          )?['epoch']) ??
          (throw StateError('source_unavailable'));
      final previousProjectionEpoch = _integer(_single(
            database,
            'SELECT projection_epoch FROM local_notification_projection_states '
            'WHERE owner_user_id = ? LIMIT 1',
            [resolvedOwner],
          )?['projection_epoch']) ??
          0;
      if (request.expectedPreviousProjectionEpoch != null &&
          previousProjectionEpoch != request.expectedPreviousProjectionEpoch) {
        throw StateError('projection_epoch_changed');
      }
      final settings = _settings(database, resolvedOwner);
      final courses = _courses(database, resolvedOwner, termId);
      final periods = _periods(database, resolvedOwner, universityId, termId);
      final assignments = _assignments(database, resolvedOwner);
      final states = _assignmentStates(database, resolvedOwner);
      final exams = _exams(database, resolvedOwner);
      final events = _events(database, resolvedOwner);
      final eventIds = events.map((event) => event.id).toSet();
      final exceptions = _exceptions(database, resolvedOwner, eventIds);
      snapshot = LocalNotificationReadonlySnapshot(
        context: context,
        settings: settings,
        courses: courses,
        periodSettings: periods,
        assignments: assignments,
        assignmentStates: states,
        exams: exams,
        events: events,
        eventExceptions: exceptions,
        importedReminderRules: _importedRules(database, resolvedOwner),
        sourceEpoch: sourceEpoch,
        previousProjectionEpoch: previousProjectionEpoch,
        termStart: _date(term['start_date']),
        termEnd: _date(term['end_date']),
        instructionStart: _nullableDate(term['instruction_start_date']),
        instructionEnd: _nullableDate(term['instruction_end_date']),
      );
    } catch (error, stack) {
      primaryError = error;
      primaryStack = stack;
    } finally {
      if (transactionStarted && databaseOpened) {
        try {
          database.execute('ROLLBACK');
        } catch (error, stack) {
          cleanupError ??= error;
          cleanupStack ??= stack;
        }
      }
      if (databaseOpened) {
        try {
          database.close();
        } catch (error, stack) {
          cleanupError = cleanupError == null
              ? error
              : LocalNotificationSnapshotCleanupException(
                  primary: cleanupError,
                  primaryStack: cleanupStack ?? stack,
                  cleanup: error,
                  cleanupStack: stack,
                );
          cleanupStack = stack;
        }
      }
    }
    if (primaryError != null) {
      if (cleanupError != null) {
        throw LocalNotificationSnapshotCleanupException(
          primary: primaryError,
          primaryStack: primaryStack ?? StackTrace.current,
          cleanup: cleanupError,
          cleanupStack: cleanupStack ?? StackTrace.current,
        );
      }
      Error.throwWithStackTrace(
        primaryError,
        primaryStack ?? StackTrace.current,
      );
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(
        cleanupError,
        cleanupStack ?? StackTrace.current,
      );
    }
    return snapshot!;
  }

  /// Production headless entrypoints must use this asynchronous boundary.
  /// The synchronous [load] method remains available for isolated fixture
  /// tests, while this method verifies native identity/health before opening,
  /// checks the durable marker before every query, and verifies health again
  /// before the projection can be published.
  Future<LocalNotificationReadonlySnapshot> loadGuarded(
    LocalNotificationReadonlySnapshotRequest request, {
    StorageHealthChecker? checkHealth,
    StorageCorruptionRecorder? recordCorruption,
    void Function()? beforeRead,
  }) async {
    final health = checkHealth ??
        ((region) => const SqliteIdentityHandshake().checkHealth(region));
    final record = recordCorruption ??
        ((region, reason) => const SqliteIdentityHandshake()
            .recordCorruption(region, reason: reason));
    await const SqliteIdentityHandshake().verify(force: true);
    await health(request.regionId);
    try {
      final snapshot = runZoned(
        () => load(request),
        zoneValues: <Object?, Object?>{
          _beforeReadZoneKey: beforeRead ?? () => _checkDurableMarker(request),
        },
      );
      await health(request.regionId);
      return snapshot;
    } catch (error, stack) {
      final corruption = _corruptionFrom(error);
      if (corruption == null) {
        Error.throwWithStackTrace(error, stack);
      }
      try {
        await record(request.regionId, corruption.reason);
      } catch (markerError, markerStack) {
        Error.throwWithStackTrace(
          SqliteStorageCorruptionException(
            original: error,
            originalStack: stack,
            markerCause: markerError,
            markerStack: markerStack,
          ),
          stack,
        );
      }
      Error.throwWithStackTrace(
        CanonicalStorageLatchedException(
          original: error,
          originalStack: stack,
        ),
        stack,
      );
    }
  }

  void _checkDurableMarker(LocalNotificationReadonlySnapshotRequest request) {
    if (!Platform.isAndroid || allowNonCanonicalPath) return;
    final normalized = request.databasePath.replaceAll('\\', '/');
    final appFlutter = normalized.substring(
      0,
      normalized.length - '/spaces/${request.regionId}/app.sqlite'.length,
    );
    final appData = Directory(appFlutter).parent.path;
    final marker = File(
      '${appData.replaceAll('\\', '/')}/no_backup/storage-health/${request.regionId}.corrupt',
    );
    if (marker.existsSync()) {
      throw SqliteStorageLatchedException(request.regionId);
    }
  }

  void _beforeRead() {
    final check = Zone.current[_beforeReadZoneKey];
    if (check is void Function()) check();
  }

  ({Object error, StackTrace stack, String reason})? _corruptionFrom(
    Object error,
  ) {
    if (error is LocalNotificationSnapshotCleanupException) {
      return _corruptionFrom(error.primary) ?? _corruptionFrom(error.cleanup);
    }
    final original = error;
    final originalStack = StackTrace.current;
    if (SqliteStorageGuard.isCorruption(original)) {
      final code = (original as sql.SqliteException).resultCode;
      return (
        error: original,
        stack: originalStack,
        reason: 'sqlite_result_$code'
      );
    }
    if (original is LocalNotificationStorageIntegrityException) {
      return (
        error: original,
        stack: originalStack,
        reason: 'integrity_check_failed',
      );
    }
    return null;
  }

  void _validateRequest(LocalNotificationReadonlySnapshotRequest request) {
    if (request.databasePath.trim().isEmpty ||
        request.regionId.trim().isEmpty ||
        request.ownerHash.trim().isEmpty ||
        request.nowUtc.isUtc == false ||
        request.expectedPreviousProjectionEpoch != null &&
            request.expectedPreviousProjectionEpoch! < 0) {
      throw StateError('invalid_snapshot_request');
    }
    if (!allowNonCanonicalPath) {
      final normalized = request.databasePath.replaceAll('\\', '/');
      final expected = RegExp(
        r'/app_flutter/spaces/' +
            RegExp.escape(request.regionId) +
            r'/app\.sqlite$',
      );
      if (!expected.hasMatch(normalized)) {
        throw StateError('noncanonical_storage_path');
      }
    }
  }

  Map<String, Object?>? _profileForRequest(
    sql.Database database,
    LocalNotificationReadonlySnapshotRequest request,
  ) {
    final rows = _rows(
      database,
      'SELECT user_id, university_id, active_term_id, '
      'primary_calendar_id, onboarding_status FROM profiles',
      const [],
    );
    for (final row in rows) {
      final userId = _string(row['user_id']);
      if (userId == null) continue;
      if (request.ownerUserId.isNotEmpty && userId != request.ownerUserId) {
        continue;
      }
      if (sha256.convert(utf8.encode(userId)).toString() == request.ownerHash) {
        return row;
      }
    }
    return null;
  }

  void _validateStorage(sql.Database database) {
    final version = _integer(
        _single(database, 'PRAGMA user_version', const [])?['user_version']);
    if (version != 18) {
      throw StateError('unsupported_storage_schema');
    }
    final integrity = _rows(database, 'PRAGMA integrity_check', const []);
    final result = integrity.isEmpty ? null : integrity.first.values.first;
    if (result != 'ok') {
      throw LocalNotificationStorageIntegrityException(result ?? 'missing');
    }
  }

  String? _validateCommittedManifest(
    LocalNotificationReadonlySnapshotRequest request,
  ) {
    if (allowNonCanonicalPath) return null;
    final manifestPath = request.databasePath.replaceFirst(
      RegExp(r'app\.sqlite$'),
      'committed-v1.json',
    );
    final file = File(manifestPath);
    if (!file.existsSync()) throw StateError('storage_not_committed');
    final decoded = _jsonDecode(file.readAsStringSync());
    if (decoded is! Map ||
        decoded['format'] != 'storage-publication-v1' ||
        decoded['phase'] != 'COMMITTED' ||
        decoded['regionId'] != request.regionId ||
        decoded['importedLegacy'] is! bool ||
        decoded['candidateSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(decoded['candidateSha256'] as String)) {
      throw StateError('storage_not_committed');
    }
    final receipt = _string(decoded['sourceReceiptSha256']);
    if (receipt != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt)) {
      throw StateError('storage_receipt_invalid');
    }
    if ((decoded['importedLegacy'] == true) != (receipt != null)) {
      throw StateError('storage_provenance_mismatch');
    }
    return receipt;
  }

  void _validateRegionMarker(
    sql.Database database,
    String regionId,
    String? receipt,
  ) {
    final rows = _rows(
      database,
      'SELECT singleton, region_id, receipt_sha256 '
      'FROM local_storage_region_v1 LIMIT 2',
      const [],
    );
    if (rows.length != 1 ||
        _integer(rows.single['singleton']) != 1 ||
        rows.single['region_id'] != regionId ||
        rows.single['receipt_sha256'] != receipt) {
      throw StateError('storage_region_mismatch');
    }
  }

  List<Map<String, Object?>> _rows(
    sql.Database db,
    String query,
    List<Object?> args,
  ) {
    _beforeRead();
    return db
        .select(query, args)
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  }

  Map<String, Object?>? _single(
      sql.Database db, String query, List<Object?> args) {
    final rows = _rows(db, query, args);
    return rows.isEmpty ? null : rows.first;
  }

  LocalNotificationSettingsValue _settings(sql.Database db, String owner) {
    final row = _single(
        db,
        'SELECT * FROM local_notification_settings '
        'WHERE owner_user_id = ? LIMIT 1',
        [owner]);
    if (row == null) return const LocalNotificationSettingsValue();
    return LocalNotificationSettingsValue(
      enabled: _boolean(row['enabled']),
      courseEnabled: _boolean(row['course_enabled']),
      assignmentEnabled: _boolean(row['assignment_enabled']),
      examEnabled: _boolean(row['exam_enabled']),
      eventEnabled: _boolean(row['event_enabled']),
      routineEnabled: _boolean(row['routine_enabled']),
      personalEnabled: _boolean(row['personal_enabled']),
      courseReminderMinutes: _integer(row['course_reminder_minutes']) ?? -10,
      assignmentReminderMinutes:
          _integer(row['assignment_reminder_minutes']) ?? -180,
      examReminderMinutes: _integer(row['exam_reminder_minutes']) ?? -10080,
      eventReminderMinutes: _integer(row['event_reminder_minutes']) ?? -60,
      examDayHour: _integer(row['exam_day_hour']) ?? 8,
      examDayMinute: _integer(row['exam_day_minute']) ?? 0,
      quietStartMinutes: _nullableInteger(row['quiet_start_minutes']),
      quietEndMinutes: _nullableInteger(row['quiet_end_minutes']),
    );
  }

  List<domain.UserCourse> _courses(
          sql.Database db, String owner, String term) =>
      _rows(
              db,
              'SELECT * FROM user_courses WHERE owner_user_id = ? AND '
              'term_id = ? AND deleted_at IS NULL',
              [owner, term])
          .map((row) => domain.UserCourse(
                id: _requiredString(row['id']),
                ownerUserId: owner,
                termId: term,
                title: _requiredString(row['title']),
                normalizedTitle: _requiredString(row['normalized_title']),
                sourceTemplateId: _string(row['source_template_id']),
                instructorName: _string(row['instructor_name']),
                normalizedInstructorName:
                    _string(row['normalized_instructor_name']),
                dayOfWeek: _nullableInteger(row['day_of_week']),
                periodNo: _nullableInteger(row['period_no']),
                room: _string(row['room']),
                color: _string(row['color']),
                visibilityLevel: domain.VisibilityLevel.fromWire(
                    _string(row['visibility_level']) ?? 'PRIVATE'),
                version: _integer(row['version']) ?? 1,
              ))
          .toList(growable: false);

  List<domain.PeriodSetting> _periods(
          sql.Database db, String owner, String university, String term) =>
      _rows(
              db,
              'SELECT * FROM period_settings WHERE owner_user_id = ? AND '
              'university_id = ? AND term_id = ? AND deleted_at IS NULL',
              [owner, university, term])
          .map((row) => domain.PeriodSetting(
                id: _requiredString(row['id']),
                ownerUserId: owner,
                dayOfWeek: _integer(row['day_of_week']) ?? 0,
                periodNo: _integer(row['period_no']) ?? 0,
                startTimeMinutes: _integer(row['start_time_minutes']) ?? 0,
                endTimeMinutes: _integer(row['end_time_minutes']) ?? 0,
              ))
          .toList(growable: false);

  List<domain.Assignment> _assignments(sql.Database db, String owner) => _rows(
          db,
          'SELECT * FROM assignments WHERE owner_user_id = ? AND deleted_at IS NULL',
          [owner])
      .map((row) => domain.Assignment(
            id: _requiredString(row['id']),
            ownerUserId: owner,
            title: _requiredString(row['title']),
            dueAt: _date(row['due_at']),
            courseId: _string(row['course_id']),
            description: _string(row['description']),
            submissionUrl: _string(row['submission_url']),
            priority: _string(row['priority']),
            visibilityLevel: domain.VisibilityLevel.fromWire(
                _string(row['visibility_level']) ?? 'PRIVATE'),
            version: _integer(row['version']) ?? 1,
          ))
      .toList(growable: false);

  Map<String, domain.AssignmentUserState> _assignmentStates(
      sql.Database db, String owner) {
    final result = <String, domain.AssignmentUserState>{};
    for (final row in _rows(
        db,
        'SELECT * FROM assignment_user_states WHERE user_id = ? AND deleted_at IS NULL',
        [owner])) {
      final id = _requiredString(row['assignment_id']);
      result[id] = domain.AssignmentUserState(
        assignmentId: id,
        userId: owner,
        status: domain.AssignmentStatus.values.firstWhere(
            (item) => item.name == _string(row['status']),
            orElse: () => domain.AssignmentStatus.notStarted),
        submittedAt: _nullableDate(row['submitted_at']),
        note: _string(row['note']),
        version: _integer(row['version']) ?? 1,
      );
    }
    return result;
  }

  List<domain.Exam> _exams(sql.Database db, String owner) => _rows(
          db,
          'SELECT * FROM exams WHERE owner_user_id = ? AND deleted_at IS NULL',
          [owner])
      .map((row) => domain.Exam(
            id: _requiredString(row['id']),
            ownerUserId: owner,
            title: _requiredString(row['title']),
            startAt: _date(row['start_at']),
            endAt: _date(row['end_at']),
            courseId: _string(row['course_id']),
            room: _string(row['room']),
            scope: _string(row['scope']),
            memo: _string(row['memo']),
            examType: _string(row['exam_type']),
            visibilityLevel: domain.VisibilityLevel.fromWire(
                _string(row['visibility_level']) ?? 'PRIVATE'),
            version: _integer(row['version']) ?? 1,
          ))
      .toList(growable: false);

  List<domain.ScheduleEvent> _events(sql.Database db, String owner) => _rows(
          db,
          'SELECT * FROM events WHERE owner_user_id = ? AND deleted_at IS NULL',
          [owner])
      .map((row) => domain.ScheduleEvent(
            id: _requiredString(row['id']),
            ownerUserId: owner,
            calendarId: _requiredString(row['calendar_id']),
            title: _requiredString(row['title']),
            kind: domain.EventKind.values.firstWhere(
                (item) => item.name == _string(row['kind']),
                orElse: () => domain.EventKind.normal),
            startAt: _date(row['start_at']),
            endAt: _date(row['end_at']),
            isAllDay: _boolean(row['is_all_day']),
            groupId: _string(row['group_id']),
            location: _string(row['location']),
            description: _string(row['description']),
            recurrenceRule: _decodeRule(_string(row['rrule']),
                _string(row['timezone']) ?? 'Asia/Tokyo'),
            timezone: _string(row['timezone']) ?? 'Asia/Tokyo',
            visibilityLevel: domain.VisibilityLevel.fromWire(
                _string(row['visibility_level']) ?? 'PRIVATE'),
            version: _integer(row['version']) ?? 1,
          ))
      .toList(growable: false);

  List<domain.EventException> _exceptions(
          sql.Database db, String owner, Set<String> eventIds) =>
      _rows(
          db,
          'SELECT * FROM event_exceptions WHERE owner_user_id = ? AND deleted_at IS NULL',
          [
            owner
          ]).where((row) => eventIds.contains(_string(row['event_id']))).map(
          (row) {
        final payload = _jsonObject(_string(row['override_payload_json']));
        return domain.EventException(
          id: _requiredString(row['id']),
          eventId: _requiredString(row['event_id']),
          recurrenceId: _date(row['recurrence_id']),
          mode: domain.EventExceptionMode.values.firstWhere(
              (item) => item.name == _string(row['mode']),
              orElse: () => domain.EventExceptionMode.modified),
          overrideStartAt: _nullableDate(row['override_start_at']),
          overrideEndAt: _nullableDate(row['override_end_at']),
          overrideTitle: _string(payload['title']),
          overrideLocation: _string(payload['location']),
          overrideDescription: _string(payload['description']),
          overrideVisibility: payload['visibilityLevel'] is String
              ? domain.VisibilityLevel.fromWire(
                  payload['visibilityLevel'] as String)
              : null,
        );
      }).toList(growable: false);

  Map<String, List<int>> _importedRules(sql.Database db, String owner) {
    final result = <String, List<int>>{};
    for (final row in _rows(
        db,
        'SELECT entity_id, reminders_minutes_json FROM notification_schedule_requests WHERE owner_user_id = ? AND state IN (\'pending\', \'scheduled\')',
        [owner])) {
      final decoded = _jsonDecode(_string(row['reminders_minutes_json']));
      if (decoded is! List) continue;
      final values = decoded
          .whereType<num>()
          .map((item) => item.toInt())
          .toList(growable: false);
      if (values.isNotEmpty) result[_requiredString(row['entity_id'])] = values;
    }
    return result;
  }

  domain.RecurrenceRule? _decodeRule(String? raw, String timezone) {
    if (raw == null || raw.isEmpty) return null;
    final parts = <String, String>{};
    for (final segment in raw.split(';')) {
      final index = segment.indexOf('=');
      if (index > 0) {
        parts[segment.substring(0, index).toUpperCase()] =
            segment.substring(index + 1);
      }
    }
    final frequency = domain.RecurrenceFrequency.values.firstWhere(
        (item) => item.name.toUpperCase() == parts['FREQ'],
        orElse: () => domain.RecurrenceFrequency.none);
    final untilRaw = parts['UNTIL'];
    DateTime? until;
    if (untilRaw != null) {
      final parsed = DateTime.tryParse(untilRaw);
      if (parsed != null) {
        until = parsed.isUtc
            ? parsed
            : (domain.JapanTime.isSupportedTimeZone(timezone)
                ? domain.JapanTime.fromCivil(parsed)
                : null);
      }
    }
    return domain.RecurrenceRule(
      frequency: frequency,
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      byWeekdays: parts['BYDAY']
              ?.split(',')
              .map(int.tryParse)
              .whereType<int>()
              .toList() ??
          const [],
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: until,
      monthDay: int.tryParse(parts['MONTHDAY'] ?? ''),
      nth: int.tryParse(parts['NTH'] ?? ''),
      weekday: int.tryParse(parts['WEEKDAY'] ?? ''),
    );
  }

  static DateTime _date(Object? value) => DateTime.fromMillisecondsSinceEpoch(
      (_integer(value) ?? (throw StateError('invalid_timestamp'))) * 1000,
      isUtc: true);
  static DateTime? _nullableDate(Object? value) =>
      value == null ? null : _date(value);
  static int? _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  static int? _nullableInteger(Object? value) =>
      value == null ? null : _integer(value);
  static bool _boolean(Object? value) =>
      value == true || value == 1 || value == '1' || value == 'true';
  static String? _string(Object? value) => value?.toString();
  static String _requiredString(Object? value) =>
      _string(value) ?? (throw StateError('invalid_text'));
  static Object? _jsonDecode(String? value) {
    if (value == null) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> _jsonObject(String? value) {
    final decoded = _jsonDecode(value);
    return decoded is Map
        ? decoded.map((key, value) => MapEntry(key.toString(), value))
        : const {};
  }
}
