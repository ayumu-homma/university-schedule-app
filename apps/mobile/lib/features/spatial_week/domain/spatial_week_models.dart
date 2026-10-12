/// Read-only presentation values for the optional geometric 2.5D experiment.
/// Thickness is decorative; the only data axes are day and real Japan time.
enum SpatialEntryKind { course, event, routine, assignment, exam }

class SpatialWeekSegment {
  const SpatialWeekSegment({
    required this.dayIndex,
    required this.startMinute,
    required this.endMinute,
  });

  final int dayIndex;
  final int startMinute;
  final int endMinute;
}

class SpatialWeekEntry {
  const SpatialWeekEntry({
    required this.key,
    required this.sourceId,
    required this.kind,
    required this.title,
    required this.detailRoute,
    required this.segments,
    this.location,
    this.startAt,
    this.endAt,
    this.isAllDay = false,
    this.unplacedReason,
  });

  final String key;
  final String sourceId;
  final SpatialEntryKind kind;
  final String title;
  final String detailRoute;
  final List<SpatialWeekSegment> segments;
  final String? location;
  final DateTime? startAt;
  final DateTime? endAt;
  final bool isAllDay;
  final String? unplacedReason;

  bool get isDeadline => kind == SpatialEntryKind.assignment;
  bool get isPlaced => segments.isNotEmpty;
}

class SpatialWeekSnapshot {
  const SpatialWeekSnapshot({
    required this.contextKey,
    required this.weekStart,
    required this.entries,
  });

  final String contextKey;
  final DateTime weekStart;
  final List<SpatialWeekEntry> entries;

  int get placedCount => entries.where((entry) => entry.isPlaced).length;
  int get unplacedCount => entries.length - placedCount;
}
