import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

void main() {
  group('VisibilityProjector', () {
    final projector = VisibilityProjector();
    final event = ScheduleEvent(
      id: 'e1',
      ownerUserId: 'owner',
      calendarId: 'cal',
      title: 'バイト',
      kind: EventKind.normal,
      startAt: DateTime(2026, 6, 29, 18),
      endAt: DateTime(2026, 6, 29, 22),
      location: '駅前店',
      description: 'レジ担当',
    );

    test('private hides the event and treats it as free', () {
      final projected = projector.project(
        event,
        const VisibilityContext(ownerDefault: VisibilityLevel.private),
      );
      expect(projected, isNull);
    });

    test('busy only returns a busy block without details', () {
      final projected = projector.project(
        event,
        const VisibilityContext(ownerDefault: VisibilityLevel.busyOnly),
      );
      expect(projected, isNotNull);
      expect(projected!.title, equals('予定あり'));
      expect(projected.location, isNull);
      expect(projected.description, isNull);
      expect(projected.blocksAvailability, isTrue);
    });

    test('title only returns title and time only', () {
      final projected = projector.project(
        event,
        const VisibilityContext(
            ownerDefault: VisibilityLevel.private,
            friendLevel: VisibilityLevel.titleOnly),
      );
      expect(projected!.title, equals('バイト'));
      expect(projected.location, isNull);
    });

    test('event override wins over group and friend defaults', () {
      final projected = projector.project(
        event,
        const VisibilityContext(
          ownerDefault: VisibilityLevel.private,
          friendLevel: VisibilityLevel.full,
          groupLevel: VisibilityLevel.full,
          eventLevel: VisibilityLevel.busyOnly,
        ),
      );
      expect(projected!.visibilityLevel, equals(VisibilityLevel.busyOnly));
    });

    test('blocked viewer sees nothing', () {
      final projected = projector.project(
        event,
        const VisibilityContext(
          ownerDefault: VisibilityLevel.full,
          isBlocked: true,
        ),
      );
      expect(projected, isNull);
    });
  });
}
