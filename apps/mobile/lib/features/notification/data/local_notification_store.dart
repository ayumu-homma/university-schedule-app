import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../local_db/app_database.dart';
import '../domain/local_notification_models.dart';

class LocalNotificationStore {
  const LocalNotificationStore(this.db);

  static const firstCourseEducationPromptKey =
      'first_course_notification_education_v1';
  static const postRegistrationPermissionPromptKey =
      'post_registration_permission_v1';

  /// Legacy marker written when the first-course explanation also acted as
  /// the permission prompt. Keep its identity for migration-free compatibility
  /// checks, but do not let it suppress the post-registration permission step.
  static const legacyOrdinaryPermissionPromptKey = 'ordinary_permission_v1';

  final AppDatabase db;

  Future<LocalNotificationSettingsValue> settingsFor(String owner) async {
    final row = await db.customSelect(
      'SELECT * FROM local_notification_settings WHERE owner_user_id = ? LIMIT 1',
      variables: [Variable.withString(owner)],
    ).getSingleOrNull();
    if (row == null) return const LocalNotificationSettingsValue();
    int? nullableInt(String name) => row.data[name] as int?;
    return LocalNotificationSettingsValue(
      enabled: row.read<bool>('enabled'),
      courseEnabled: row.read<bool>('course_enabled'),
      assignmentEnabled: row.read<bool>('assignment_enabled'),
      examEnabled: row.read<bool>('exam_enabled'),
      eventEnabled: row.read<bool>('event_enabled'),
      routineEnabled: row.read<bool>('routine_enabled'),
      personalEnabled: row.read<bool>('personal_enabled'),
      courseReminderMinutes: row.read<int>('course_reminder_minutes'),
      assignmentReminderMinutes: row.read<int>('assignment_reminder_minutes'),
      examReminderMinutes: row.read<int>('exam_reminder_minutes'),
      eventReminderMinutes: row.read<int>('event_reminder_minutes'),
      examDayHour: row.read<int>('exam_day_hour'),
      examDayMinute: row.read<int>('exam_day_minute'),
      quietStartMinutes: nullableInt('quiet_start_minutes'),
      quietEndMinutes: nullableInt('quiet_end_minutes'),
    );
  }

  Future<bool> hasRegisteredCourse(String owner, String termId) async {
    final row = await db.customSelect(
      'SELECT 1 AS present FROM user_courses '
      'WHERE owner_user_id = ? AND term_id = ? AND deleted_at IS NULL LIMIT 1',
      variables: [
        Variable.withString(owner),
        Variable.withString(termId),
      ],
    ).getSingleOrNull();
    return row != null;
  }

  Future<void> saveSettings(
    String owner,
    LocalNotificationSettingsValue settings,
  ) async {
    final updatedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.customStatement('''
      INSERT INTO local_notification_settings
        (owner_user_id, enabled, course_enabled, assignment_enabled,
         exam_enabled, event_enabled, routine_enabled, personal_enabled,
         course_reminder_minutes, assignment_reminder_minutes,
         exam_reminder_minutes, event_reminder_minutes, exam_day_hour,
         exam_day_minute, quiet_start_minutes, quiet_end_minutes, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(owner_user_id) DO UPDATE SET
        enabled=excluded.enabled, course_enabled=excluded.course_enabled,
        assignment_enabled=excluded.assignment_enabled,
        exam_enabled=excluded.exam_enabled, event_enabled=excluded.event_enabled,
        routine_enabled=excluded.routine_enabled,
        personal_enabled=excluded.personal_enabled,
        course_reminder_minutes=excluded.course_reminder_minutes,
        assignment_reminder_minutes=excluded.assignment_reminder_minutes,
        exam_reminder_minutes=excluded.exam_reminder_minutes,
        event_reminder_minutes=excluded.event_reminder_minutes,
        exam_day_hour=excluded.exam_day_hour,
        exam_day_minute=excluded.exam_day_minute,
        quiet_start_minutes=excluded.quiet_start_minutes,
        quiet_end_minutes=excluded.quiet_end_minutes,
        updated_at=excluded.updated_at
    ''', [
      owner,
      settings.enabled ? 1 : 0,
      settings.courseEnabled ? 1 : 0,
      settings.assignmentEnabled ? 1 : 0,
      settings.examEnabled ? 1 : 0,
      settings.eventEnabled ? 1 : 0,
      settings.routineEnabled ? 1 : 0,
      settings.personalEnabled ? 1 : 0,
      settings.courseReminderMinutes,
      settings.assignmentReminderMinutes,
      settings.examReminderMinutes,
      settings.eventReminderMinutes,
      settings.examDayHour,
      settings.examDayMinute,
      settings.quietStartMinutes,
      settings.quietEndMinutes,
      updatedAt,
    ]);
  }

  Future<int> sourceEpoch() async {
    final row = await db
        .customSelect(
          'SELECT epoch FROM local_notification_source_revisions WHERE id = 1',
        )
        .getSingleOrNull();
    return row?.read<int>('epoch') ?? 0;
  }

  Future<bool> permissionPromptSeen(
    String owner, {
    required String promptKey,
  }) async {
    final row = await db.customSelect(
      'SELECT 1 AS seen FROM local_notification_permission_prompts '
      'WHERE owner_user_id = ? AND prompt_key = ? LIMIT 1',
      variables: [
        Variable.withString(owner),
        Variable.withString(promptKey),
      ],
    ).getSingleOrNull();
    return row?.read<int>('seen') == 1;
  }

  Future<void> markPermissionPromptSeen(
    String owner, {
    required String promptKey,
  }) async {
    await db.customStatement('''
      INSERT OR IGNORE INTO local_notification_permission_prompts
        (owner_user_id, prompt_key, prompted_at)
      VALUES (?, ?, ?)
    ''', [
      owner,
      promptKey,
      DateTime.now().toUtc().millisecondsSinceEpoch,
    ]);
  }

  Future<int> projectionEpoch(String owner) async {
    final row = await db.customSelect(
      'SELECT projection_epoch FROM local_notification_projection_states '
      'WHERE owner_user_id = ? LIMIT 1',
      variables: [Variable.withString(owner)],
    ).getSingleOrNull();
    return row?.read<int>('projection_epoch') ?? 0;
  }

  Future<Map<String, List<int>>> importedReminderRules(String owner) async {
    final rows = await db.customSelect(
      'SELECT entity_id, reminders_minutes_json FROM notification_schedule_requests '
      "WHERE owner_user_id = ? AND state IN ('pending', 'scheduled')",
      variables: [Variable.withString(owner)],
    ).get();
    final result = <String, List<int>>{};
    for (final row in rows) {
      Object? values;
      try {
        values = jsonDecode(row.read<String>('reminders_minutes_json'));
      } on FormatException {
        // A malformed import receipt contributes no override; it must not
        // disable unrelated ordinary reminders.
        continue;
      }
      if (values is! List) continue;
      final minutes =
          values.whereType<num>().map((value) => value.toInt()).toList();
      if (minutes.isNotEmpty) result[row.read<String>('entity_id')] = minutes;
    }
    return result;
  }

  Future<void> replaceProjection({
    required String owner,
    required int sourceEpoch,
    required int projectionEpoch,
    required bool capped,
    required List<LocalNotificationPlan> plans,
  }) async {
    await db.transaction(() async {
      final updatedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
      final current = await db
          .customSelect(
            'SELECT epoch FROM local_notification_source_revisions WHERE id = 1',
          )
          .getSingleOrNull();
      if ((current?.read<int>('epoch') ?? 0) != sourceEpoch) {
        throw StateError('Notification source changed while planning.');
      }
      await db.customStatement(
        'DELETE FROM local_notification_occurrences WHERE owner_user_id = ?',
        [owner],
      );
      for (final plan in plans) {
        await db.customStatement('''
          INSERT INTO local_notification_occurrences
            (id, owner_user_id, kind, source_entity_id, occurrence_at,
             trigger_at, target_path, title, body, rule, fingerprint,
             source_epoch, projection_epoch, status, reason, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'desired', ?, ?)
        ''', [
          plan.id,
          owner,
          plan.kind,
          plan.sourceEntityId,
          plan.occurrenceAt.toUtc().millisecondsSinceEpoch,
          plan.triggerAt.toUtc().millisecondsSinceEpoch,
          plan.targetPath,
          plan.title,
          plan.body,
          plan.rule,
          plan.fingerprint,
          sourceEpoch,
          projectionEpoch,
          plan.reason,
          updatedAt,
        ]);
      }
      await db.customStatement('''
        INSERT INTO local_notification_projection_states
          (owner_user_id, source_epoch, projection_epoch, capped,
           blocked_reason, planned_at)
        VALUES (?, ?, ?, ?, NULL, ?)
        ON CONFLICT(owner_user_id) DO UPDATE SET
          source_epoch=excluded.source_epoch,
          projection_epoch=excluded.projection_epoch,
          capped=excluded.capped, blocked_reason=NULL,
          planned_at=excluded.planned_at
      ''', [
        owner,
        sourceEpoch,
        projectionEpoch,
        capped ? 1 : 0,
        updatedAt,
      ]);
    });
  }

  Future<List<Map<String, Object?>>> desiredRows(String owner) async {
    final rows = await db.customSelect(
      'SELECT * FROM local_notification_occurrences '
      'WHERE owner_user_id = ? AND status = \'desired\'',
      variables: [Variable.withString(owner)],
    ).get();
    return rows.map((row) => row.data).toList(growable: false);
  }
}
