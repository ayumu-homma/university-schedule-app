import 'enums.dart';
import 'japan_time.dart';

typedef JsonMap = Map<String, Object?>;

class Profile {
  const Profile({
    required this.userId,
    required this.displayName,
    required this.userType,
    this.username,
    this.universityId,
    this.grade,
    this.universityVerified = false,
    this.searchableByUsername = false,
    this.defaultVisibility = VisibilityLevel.private,
  });

  final String userId;
  final String displayName;
  final UserType userType;
  final String? username;
  final String? universityId;
  final int? grade;
  final bool universityVerified;
  final bool searchableByUsername;
  final VisibilityLevel defaultVisibility;
}

class University {
  const University({
    required this.id,
    required this.name,
    required this.normalizedName,
    this.prefecture,
    this.aliases = const [],
    this.domainHints = const [],
  });

  final String id;
  final String name;
  final String normalizedName;
  final String? prefecture;
  final List<String> aliases;
  final List<String> domainHints;
}

class Term {
  const Term({
    required this.id,
    required this.universityId,
    required this.name,
    required this.academicYear,
    required this.startDate,
    required this.endDate,
    required this.termType,
  });

  final String id;
  final String universityId;
  final String name;
  final int academicYear;
  final DateTime startDate;
  final DateTime endDate;
  final TermType termType;
}

class PeriodSetting {
  const PeriodSetting({
    required this.id,
    required this.ownerUserId,
    required this.dayOfWeek,
    required this.periodNo,
    required this.startTimeMinutes,
    required this.endTimeMinutes,
  });

  final String id;
  final String ownerUserId;
  final int dayOfWeek;
  final int periodNo;
  final int startTimeMinutes;
  final int endTimeMinutes;
}

class CourseTemplate {
  const CourseTemplate({
    required this.id,
    required this.universityId,
    required this.academicYear,
    required this.title,
    required this.normalizedTitle,
    this.termId,
    this.instructorName,
    this.normalizedInstructorName,
    this.dayOfWeek,
    this.periodNo,
    this.room,
    this.normalizedRoom,
    this.creditCount,
    this.syllabusUrl,
    this.externalCourseCode,
    this.copyCountTotal = 0,
    this.copyCountTerm = 0,
    this.trustScore = 0,
    this.duplicateKey,
    this.rankScore,
  });

  final String id;
  final String universityId;
  final int academicYear;
  final String title;
  final String normalizedTitle;
  final String? termId;
  final String? instructorName;
  final String? normalizedInstructorName;
  final int? dayOfWeek;
  final int? periodNo;
  final String? room;
  final String? normalizedRoom;
  final num? creditCount;
  final String? syllabusUrl;
  final String? externalCourseCode;
  final int copyCountTotal;
  final int copyCountTerm;
  final num trustScore;

  /// Server-generated grouping key for duplicate candidates in a catalog
  /// search. It contains no template-author information.
  final String? duplicateKey;

  /// Server-calculated relevance score for the current catalog query.
  ///
  /// This is query metadata rather than a durable template property, so local
  /// cache reads may not have a value.
  final num? rankScore;
}

class UserCourse {
  const UserCourse({
    required this.id,
    required this.ownerUserId,
    required this.termId,
    required this.title,
    required this.normalizedTitle,
    this.sourceTemplateId,
    this.instructorName,
    this.normalizedInstructorName,
    this.dayOfWeek,
    this.periodNo,
    this.room,
    this.color,
    this.visibilityLevel = VisibilityLevel.private,
    this.version = 1,
  });

  final String id;
  final String ownerUserId;
  final String termId;
  final String title;
  final String normalizedTitle;
  final String? sourceTemplateId;
  final String? instructorName;
  final String? normalizedInstructorName;
  final int? dayOfWeek;
  final int? periodNo;
  final String? room;
  final String? color;
  final VisibilityLevel visibilityLevel;
  final int version;
}

class Assignment {
  const Assignment({
    required this.id,
    required this.ownerUserId,
    required this.title,
    required this.dueAt,
    this.courseId,
    this.description,
    this.submissionUrl,
    this.priority,
    this.visibilityLevel = VisibilityLevel.private,
    this.version = 1,
  });

  final String id;
  final String ownerUserId;
  final String title;
  final DateTime dueAt;
  final String? courseId;
  final String? description;
  final String? submissionUrl;
  final String? priority;
  final VisibilityLevel visibilityLevel;
  final int version;
}

class AssignmentUserState {
  const AssignmentUserState({
    required this.assignmentId,
    required this.userId,
    this.status = AssignmentStatus.notStarted,
    this.submittedAt,
    this.note,
    this.version = 1,
  });

  final String assignmentId;
  final String userId;
  final AssignmentStatus status;
  final DateTime? submittedAt;
  final String? note;
  final int version;

  AssignmentUserState submit(DateTime submittedAt) {
    return AssignmentUserState(
      assignmentId: assignmentId,
      userId: userId,
      status: AssignmentStatus.submitted,
      submittedAt: submittedAt,
      note: note,
      version: version,
    );
  }
}

class Exam {
  const Exam({
    required this.id,
    required this.ownerUserId,
    required this.title,
    required this.startAt,
    required this.endAt,
    this.courseId,
    this.room,
    this.scope,
    this.memo,
    this.examType,
    this.visibilityLevel = VisibilityLevel.private,
    this.version = 1,
  });

  final String id;
  final String ownerUserId;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? courseId;
  final String? room;
  final String? scope;
  final String? memo;
  final String? examType;
  final VisibilityLevel visibilityLevel;
  final int version;
}

class CalendarModel {
  const CalendarModel({
    required this.id,
    required this.ownerUserId,
    required this.name,
    this.groupId,
    this.defaultVisibility = VisibilityLevel.private,
  });

  final String id;
  final String ownerUserId;
  final String name;
  final String? groupId;
  final VisibilityLevel? defaultVisibility;
}

class ScheduleEvent {
  const ScheduleEvent({
    required this.id,
    required this.ownerUserId,
    required this.calendarId,
    required this.title,
    required this.kind,
    required this.startAt,
    required this.endAt,
    this.isAllDay = false,
    this.groupId,
    this.location,
    this.description,
    this.recurrenceRule,
    this.timezone = japanTimeZone,
    this.visibilityLevel = VisibilityLevel.private,
    this.version = 1,
  });

  final String id;
  final String ownerUserId;
  final String calendarId;
  final String title;
  final EventKind kind;
  final DateTime startAt;
  final DateTime endAt;
  final bool isAllDay;
  final String? groupId;
  final String? location;
  final String? description;
  final RecurrenceRule? recurrenceRule;
  final String timezone;
  final VisibilityLevel? visibilityLevel;
  final int version;

  Duration get duration => endAt.difference(startAt);

  ScheduleEvent copyWith({
    String? id,
    String? title,
    DateTime? startAt,
    DateTime? endAt,
    bool? isAllDay,
    String? location,
    String? description,
    String? timezone,
    VisibilityLevel? visibilityLevel,
    bool clearVisibilityLevel = false,
  }) {
    return ScheduleEvent(
      id: id ?? this.id,
      ownerUserId: ownerUserId,
      calendarId: calendarId,
      title: title ?? this.title,
      kind: kind,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      isAllDay: isAllDay ?? this.isAllDay,
      groupId: groupId,
      location: location ?? this.location,
      description: description ?? this.description,
      recurrenceRule: recurrenceRule,
      timezone: timezone ?? this.timezone,
      visibilityLevel:
          clearVisibilityLevel ? null : visibilityLevel ?? this.visibilityLevel,
      version: version,
    );
  }
}

class RecurrenceRule {
  const RecurrenceRule({
    required this.frequency,
    this.interval = 1,
    this.byWeekdays = const [],
    this.count,
    this.until,
    this.monthDay,
    this.nth,
    this.weekday,
  }) : assert(interval > 0);

  final RecurrenceFrequency frequency;
  final int interval;
  final List<int> byWeekdays;
  final int? count;
  final DateTime? until;
  final int? monthDay;
  final int? nth;
  final int? weekday;
}

class EventException {
  const EventException({
    required this.id,
    required this.eventId,
    required this.recurrenceId,
    required this.mode,
    this.overrideStartAt,
    this.overrideEndAt,
    this.overrideTitle,
    this.overrideLocation,
    this.overrideDescription,
    this.overrideVisibility,
  });

  final String id;
  final String eventId;
  final DateTime recurrenceId;
  final EventExceptionMode mode;
  final DateTime? overrideStartAt;
  final DateTime? overrideEndAt;
  final String? overrideTitle;
  final String? overrideLocation;
  final String? overrideDescription;
  final VisibilityLevel? overrideVisibility;
}

class Friendship {
  const Friendship({
    required this.id,
    required this.requesterUserId,
    required this.addresseeUserId,
    required this.status,
    this.visibilityLevel,
  });

  final String id;
  final String requesterUserId;
  final String addresseeUserId;
  final FriendshipStatus status;
  final VisibilityLevel? visibilityLevel;
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.ownerUserId,
    this.type = GroupType.other,
    this.defaultVisibility = VisibilityLevel.titleOnly,
  });

  final String id;
  final String name;
  final String ownerUserId;
  final GroupType type;
  final VisibilityLevel defaultVisibility;
}

class GroupMember {
  const GroupMember({
    required this.groupId,
    required this.userId,
    required this.role,
    this.visibilityLevel,
  });

  final String groupId;
  final String userId;
  final GroupRole role;
  final VisibilityLevel? visibilityLevel;
}

class EventParticipant {
  const EventParticipant({
    required this.eventId,
    required this.userId,
    this.status = ParticipationStatus.unanswered,
  });

  final String eventId;
  final String userId;
  final ParticipationStatus status;
}

class EventComment {
  const EventComment({
    required this.id,
    required this.eventId,
    required this.authorUserId,
    required this.body,
    required this.createdAt,
    this.deletedAt,
  });

  final String id;
  final String eventId;
  final String authorUserId;
  final String body;
  final DateTime createdAt;
  final DateTime? deletedAt;
}

class EventReaction {
  const EventReaction({
    required this.eventId,
    required this.userId,
    required this.reaction,
  });

  final String eventId;
  final String userId;
  final String reaction;
}

class NotificationSetting {
  const NotificationSetting({
    required this.userId,
    this.assignmentsEnabled = true,
    this.examsEnabled = true,
    this.eventsEnabled = true,
    this.groupUpdatesEnabled = true,
    this.minutesBeforeClass = 10,
    this.minutesBeforeAssignment = 1440,
  });

  final String userId;
  final bool assignmentsEnabled;
  final bool examsEnabled;
  final bool eventsEnabled;
  final bool groupUpdatesEnabled;
  final int minutesBeforeClass;
  final int minutesBeforeAssignment;
}

class PushToken {
  const PushToken({
    required this.userId,
    required this.platform,
    required this.tokenHash,
    required this.createdAt,
  });

  final String userId;
  final String platform;
  final String tokenHash;
  final DateTime createdAt;
}
