enum VisibilityLevel {
  private('PRIVATE'),
  busyOnly('BUSY_ONLY'),
  titleOnly('TITLE_ONLY'),
  full('FULL');

  const VisibilityLevel(this.wireName);

  final String wireName;

  static VisibilityLevel fromWire(String value) {
    return VisibilityLevel.values.firstWhere(
      (level) => level.wireName == value,
      orElse: () => VisibilityLevel.private,
    );
  }
}

enum UserType { undergraduate, graduate, other }

enum TermType { semester, quarter, custom, intensive, yearRound }

enum AssignmentStatus { notStarted, inProgress, submitted, overdue }

enum EventKind { normal, routine, course, assignmentDeadline, exam, group }

enum RecurrenceFrequency { none, daily, weekly, monthly, nthWeekday, weekdays }

enum EventExceptionMode { cancelled, modified }

enum FriendshipStatus { pending, accepted, rejected, blocked }

enum GroupRole { owner, admin, member }

enum GroupType { friends, course, club, seminar, lab, partTimeJob, other }

enum ParticipationStatus { attending, declined, tentative, unanswered }

enum NotificationChannel { local, push }

enum WidgetPrivacyMode { title, titleAndRoom, busyOnly }
