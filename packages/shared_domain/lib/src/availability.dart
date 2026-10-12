import 'visibility.dart';

class TimeWindow {
  TimeWindow({
    required this.startAt,
    required this.endAt,
  }) {
    if (endAt.isBefore(startAt)) {
      throw ArgumentError.value(endAt, 'endAt', 'must not be before startAt');
    }
  }

  final DateTime startAt;
  final DateTime endAt;

  Duration get duration => endAt.difference(startAt);

  bool overlaps(TimeWindow other) {
    return startAt.isBefore(other.endAt) && endAt.isAfter(other.startAt);
  }
}

class FreeTimeSearchService {
  List<TimeWindow> findCommonFreeWindows({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required Iterable<VisibleEventProjection> visibleEvents,
    Duration minimumDuration = const Duration(minutes: 30),
  }) {
    if (!rangeEnd.isAfter(rangeStart)) {
      throw ArgumentError.value(
        rangeEnd,
        'rangeEnd',
        'must be after rangeStart',
      );
    }
    if (minimumDuration.isNegative) {
      throw ArgumentError.value(
        minimumDuration,
        'minimumDuration',
        'must not be negative',
      );
    }

    final busy = visibleEvents
        .where((event) => event.blocksAvailability)
        // Assignment deadlines are intentionally represented as zero-duration
        // points by the projection contract. They are not busy intervals.
        .where((event) => event.endAt.isAfter(event.startAt))
        .where((event) =>
            event.startAt.isBefore(rangeEnd) && event.endAt.isAfter(rangeStart))
        .map((event) {
      final start =
          event.startAt.isBefore(rangeStart) ? rangeStart : event.startAt;
      final end = event.endAt.isAfter(rangeEnd) ? rangeEnd : event.endAt;
      return TimeWindow(startAt: start, endAt: end);
    }).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));

    final merged = <TimeWindow>[];
    for (final window in busy) {
      if (merged.isEmpty || merged.last.endAt.isBefore(window.startAt)) {
        merged.add(window);
      } else {
        final last = merged.removeLast();
        merged.add(
          TimeWindow(
            startAt: last.startAt,
            endAt: last.endAt.isAfter(window.endAt) ? last.endAt : window.endAt,
          ),
        );
      }
    }

    final free = <TimeWindow>[];
    var cursor = rangeStart;
    for (final window in merged) {
      if (window.startAt.isAfter(cursor) &&
          window.startAt.difference(cursor) >= minimumDuration) {
        free.add(TimeWindow(startAt: cursor, endAt: window.startAt));
      }
      if (window.endAt.isAfter(cursor)) cursor = window.endAt;
    }
    if (rangeEnd.isAfter(cursor) &&
        rangeEnd.difference(cursor) >= minimumDuration) {
      free.add(TimeWindow(startAt: cursor, endAt: rangeEnd));
    }
    return free;
  }
}
