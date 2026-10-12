import 'enums.dart';
import 'models.dart';

class VisibilityContext {
  const VisibilityContext({
    required this.ownerDefault,
    this.friendLevel,
    this.groupLevel,
    this.calendarLevel,
    this.eventLevel,
    this.isBlocked = false,
    this.viewerIsOwner = false,
  });

  final VisibilityLevel ownerDefault;
  final VisibilityLevel? friendLevel;
  final VisibilityLevel? groupLevel;
  final VisibilityLevel? calendarLevel;
  final VisibilityLevel? eventLevel;
  final bool isBlocked;
  final bool viewerIsOwner;
}

class VisibleEventProjection {
  const VisibleEventProjection({
    required this.eventId,
    required this.ownerUserId,
    required this.startAt,
    required this.endAt,
    required this.visibilityLevel,
    this.title,
    this.location,
    this.description,
    this.kind,
  });

  final String eventId;
  final String ownerUserId;
  final DateTime startAt;
  final DateTime endAt;
  final VisibilityLevel visibilityLevel;
  final String? title;
  final String? location;
  final String? description;
  final EventKind? kind;

  bool get blocksAvailability => visibilityLevel != VisibilityLevel.private;
}

class VisibilityProjector {
  VisibilityLevel resolve(VisibilityContext context) {
    if (context.viewerIsOwner) return VisibilityLevel.full;
    if (context.isBlocked) return VisibilityLevel.private;
    return context.eventLevel ??
        context.calendarLevel ??
        context.groupLevel ??
        context.friendLevel ??
        context.ownerDefault;
  }

  VisibleEventProjection? project(
      ScheduleEvent event, VisibilityContext context) {
    final level = resolve(context);
    if (level == VisibilityLevel.private) return null;
    return switch (level) {
      VisibilityLevel.busyOnly => VisibleEventProjection(
          eventId: event.id,
          ownerUserId: event.ownerUserId,
          startAt: event.startAt,
          endAt: event.endAt,
          visibilityLevel: level,
          title: '予定あり',
        ),
      VisibilityLevel.titleOnly => VisibleEventProjection(
          eventId: event.id,
          ownerUserId: event.ownerUserId,
          startAt: event.startAt,
          endAt: event.endAt,
          visibilityLevel: level,
          title: event.title,
          kind: event.kind,
        ),
      VisibilityLevel.full => VisibleEventProjection(
          eventId: event.id,
          ownerUserId: event.ownerUserId,
          startAt: event.startAt,
          endAt: event.endAt,
          visibilityLevel: level,
          title: event.title,
          location: event.location,
          description: event.description,
          kind: event.kind,
        ),
      VisibilityLevel.private => null,
    };
  }
}
