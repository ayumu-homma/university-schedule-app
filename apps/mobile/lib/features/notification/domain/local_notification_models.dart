import 'package:shared_domain/shared_domain.dart' as domain;

class LocalNotificationSettingsValue {
  const LocalNotificationSettingsValue({
    this.enabled = true,
    this.courseEnabled = true,
    this.assignmentEnabled = true,
    this.examEnabled = true,
    this.eventEnabled = true,
    this.routineEnabled = true,
    this.personalEnabled = true,
    this.courseReminderMinutes = -10,
    this.assignmentReminderMinutes = -180,
    this.examReminderMinutes = -10080,
    this.eventReminderMinutes = -60,
    this.examDayHour = 8,
    this.examDayMinute = 0,
    this.quietStartMinutes,
    this.quietEndMinutes,
  });

  final bool enabled;
  final bool courseEnabled;
  final bool assignmentEnabled;
  final bool examEnabled;
  final bool eventEnabled;
  final bool routineEnabled;
  final bool personalEnabled;
  final int courseReminderMinutes;
  final int assignmentReminderMinutes;
  final int examReminderMinutes;
  final int eventReminderMinutes;
  final int examDayHour;
  final int examDayMinute;
  final int? quietStartMinutes;
  final int? quietEndMinutes;

  LocalNotificationSettingsValue copyWith({
    bool? enabled,
    bool? courseEnabled,
    bool? assignmentEnabled,
    bool? examEnabled,
    bool? eventEnabled,
    bool? routineEnabled,
    bool? personalEnabled,
    int? courseReminderMinutes,
    int? assignmentReminderMinutes,
    int? examReminderMinutes,
    int? eventReminderMinutes,
    int? examDayHour,
    int? examDayMinute,
    int? quietStartMinutes,
    int? quietEndMinutes,
    bool clearQuietStartMinutes = false,
    bool clearQuietEndMinutes = false,
    bool clearQuietHours = false,
  }) =>
      LocalNotificationSettingsValue(
        enabled: enabled ?? this.enabled,
        courseEnabled: courseEnabled ?? this.courseEnabled,
        assignmentEnabled: assignmentEnabled ?? this.assignmentEnabled,
        examEnabled: examEnabled ?? this.examEnabled,
        eventEnabled: eventEnabled ?? this.eventEnabled,
        routineEnabled: routineEnabled ?? this.routineEnabled,
        personalEnabled: personalEnabled ?? this.personalEnabled,
        courseReminderMinutes:
            courseReminderMinutes ?? this.courseReminderMinutes,
        assignmentReminderMinutes:
            assignmentReminderMinutes ?? this.assignmentReminderMinutes,
        examReminderMinutes: examReminderMinutes ?? this.examReminderMinutes,
        eventReminderMinutes: eventReminderMinutes ?? this.eventReminderMinutes,
        examDayHour: examDayHour ?? this.examDayHour,
        examDayMinute: examDayMinute ?? this.examDayMinute,
        quietStartMinutes: clearQuietHours || clearQuietStartMinutes
            ? null
            : quietStartMinutes ?? this.quietStartMinutes,
        quietEndMinutes: clearQuietHours || clearQuietEndMinutes
            ? null
            : quietEndMinutes ?? this.quietEndMinutes,
      );
}

class LocalNotificationPlan {
  const LocalNotificationPlan({
    required this.id,
    required this.ownerUserId,
    required this.kind,
    required this.sourceEntityId,
    required this.occurrenceAt,
    required this.triggerAt,
    required this.targetPath,
    required this.title,
    required this.body,
    required this.rule,
    required this.fingerprint,
    required this.sourceEpoch,
    required this.projectionEpoch,
    this.reason = 'eligible',
  });

  final String id;
  final String ownerUserId;
  final String kind;
  final String sourceEntityId;
  final DateTime occurrenceAt;
  final DateTime triggerAt;
  final String targetPath;
  final String title;
  final String body;
  final String rule;
  final String fingerprint;
  final int sourceEpoch;
  final int projectionEpoch;
  final String reason;

  bool get eligible => reason == 'eligible';

  Map<String, Object?> toJson() => {
        'id': id,
        'ownerUserId': ownerUserId,
        'kind': kind,
        'sourceEntityId': sourceEntityId,
        'occurrenceAt': occurrenceAt.toUtc().toIso8601String(),
        'triggerAt': triggerAt.toUtc().toIso8601String(),
        'targetPath': targetPath,
        'title': title,
        'body': body,
        'rule': rule,
        'fingerprint': fingerprint,
        'sourceEpoch': sourceEpoch,
        'projectionEpoch': projectionEpoch,
        'reason': reason,
      };
}

extension NotificationKind on domain.EventKind {
  String get notificationName {
    switch (this) {
      case domain.EventKind.course:
        return 'course';
      case domain.EventKind.assignmentDeadline:
        return 'assignment';
      case domain.EventKind.exam:
        return 'exam';
      case domain.EventKind.routine:
        return 'routine';
      case domain.EventKind.normal:
      case domain.EventKind.group:
        return 'event';
    }
  }
}
