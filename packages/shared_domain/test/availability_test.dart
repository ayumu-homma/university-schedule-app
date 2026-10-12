import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  test('time windows reject ranges where end is before start', () {
    expect(
      () => TimeWindow(
        startAt: DateTime(2026, 6, 29, 12),
        endAt: DateTime(2026, 6, 29, 11),
      ),
      throwsArgumentError,
    );
  });

  test('half-open boundaries and adjacent busy windows are merged', () {
    final service = FreeTimeSearchService();
    final free = service.findCommonFreeWindows(
      rangeStart: DateTime(2026, 6, 29, 9),
      rangeEnd: DateTime(2026, 6, 29, 15),
      visibleEvents: [
        _event('a', 10, 11),
        _event('b', 11, 12),
        _event('edge', 15, 16),
      ],
      minimumDuration: const Duration(minutes: 30),
    );

    expect(
      free.map((window) => [window.startAt.hour, window.endAt.hour]),
      [
        [9, 10],
        [12, 15],
      ],
    );
  });

  test('clips overnight busy windows and ignores zero-duration deadlines', () {
    final free = FreeTimeSearchService().findCommonFreeWindows(
      rangeStart: DateTime(2026, 6, 29, 9),
      rangeEnd: DateTime(2026, 6, 29, 12),
      visibleEvents: [
        _eventAt(
          'overnight',
          DateTime(2026, 6, 29, 8),
          DateTime(2026, 6, 29, 10),
        ),
        _eventAt(
          'deadline',
          DateTime(2026, 6, 29, 10),
          DateTime(2026, 6, 29, 10),
        ),
      ],
      minimumDuration: const Duration(minutes: 30),
    );

    expect(free.single.duration, const Duration(hours: 2));
    expect(free.single.startAt.hour, 10);
  });

  test('private-only and busy-only projections use time, not secret fields',
      () {
    final free = FreeTimeSearchService().findCommonFreeWindows(
      rangeStart: DateTime(2026, 6, 29, 9),
      rangeEnd: DateTime(2026, 6, 29, 12),
      visibleEvents: [
        VisibleEventProjection(
          eventId: 'private',
          ownerUserId: 'u1',
          startAt: DateTime(2026, 6, 29, 9),
          endAt: DateTime(2026, 6, 29, 10),
          visibilityLevel: VisibilityLevel.private,
          title: 'secret',
        ),
        _event('busy', 10, 11, VisibilityLevel.busyOnly),
      ],
      minimumDuration: const Duration(minutes: 30),
    );

    expect(free.map((window) => [window.startAt.hour, window.endAt.hour]), [
      [9, 10],
      [11, 12],
    ]);
  });

  test('exact duration matches are included and invalid ranges are actionable',
      () {
    final service = FreeTimeSearchService();
    expect(
      service
          .findCommonFreeWindows(
            rangeStart: DateTime(2026, 6, 29, 9),
            rangeEnd: DateTime(2026, 6, 29, 10),
            visibleEvents: const [],
            minimumDuration: const Duration(hours: 1),
          )
          .single
          .duration,
      const Duration(hours: 1),
    );
    expect(
      () => service.findCommonFreeWindows(
        rangeStart: DateTime(2026, 6, 29, 10),
        rangeEnd: DateTime(2026, 6, 29, 9),
        visibleEvents: const [],
      ),
      throwsArgumentError,
    );
  });

  test('free-time search uses visible busy projections only', () {
    final service = FreeTimeSearchService();
    final free = service.findCommonFreeWindows(
      rangeStart: DateTime(2026, 6, 29, 9),
      rangeEnd: DateTime(2026, 6, 29, 12),
      visibleEvents: [
        VisibleEventProjection(
          eventId: 'busy',
          ownerUserId: 'u1',
          startAt: DateTime(2026, 6, 29, 10),
          endAt: DateTime(2026, 6, 29, 11),
          visibilityLevel: VisibilityLevel.busyOnly,
          title: '予定あり',
        ),
      ],
      minimumDuration: const Duration(minutes: 30),
    );

    expect(free.map((window) => [window.startAt.hour, window.endAt.hour]), [
      [9, 10],
      [11, 12],
    ]);
  });
}

VisibleEventProjection _event(
  String id,
  int startHour,
  int endHour, [
  VisibilityLevel level = VisibilityLevel.full,
]) =>
    _eventAt(
      id,
      DateTime(2026, 6, 29, startHour),
      DateTime(2026, 6, 29, endHour),
      level,
    );

VisibleEventProjection _eventAt(
  String id,
  DateTime startAt,
  DateTime endAt, [
  VisibilityLevel level = VisibilityLevel.full,
]) =>
    VisibleEventProjection(
      eventId: id,
      ownerUserId: 'u1',
      startAt: startAt,
      endAt: endAt,
      visibilityLevel: level,
      title: level == VisibilityLevel.busyOnly ? '予定あり' : 'visible',
    );
