import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../auth/application/auth_providers.dart';
import '../../groups/application/group_providers.dart';
import '../../groups/domain/group_models.dart';

class TodayGroupEvent {
  const TodayGroupEvent({required this.group, required this.event});

  final GroupSummary group;
  final GroupEventSummary event;
}

final todayGroupEventsProvider =
    FutureProvider.autoDispose<List<TodayGroupEvent>>((ref) async {
  if (ref.watch(appConfigProvider).demoMode) return const [];
  if (ref.watch(currentAuthSessionProvider) == null) return const [];

  final repository = ref.watch(groupRepositoryProvider);
  final groups = await repository.listGroups();
  final groupEvents = await Future.wait(groups.map((group) async {
    final events = await repository.listGroupEvents(group.id);
    return [
      for (final event in events)
        if (event.groupId == group.id && !event.cancelled)
          TodayGroupEvent(group: group, event: event),
    ];
  }));
  final result = groupEvents.expand((events) => events).toList()
    ..sort((left, right) {
      final byStart = left.event.startAt.compareTo(right.event.startAt);
      if (byStart != 0) return byStart;
      final byGroup = left.group.name.compareTo(right.group.name);
      if (byGroup != 0) return byGroup;
      return left.event.eventId.compareTo(right.event.eventId);
    });
  return List.unmodifiable(result);
});

List<TodayGroupEvent> groupEventsInRange(
  Iterable<TodayGroupEvent> events, {
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) =>
    List.unmodifiable(events.where((item) =>
        item.event.startAt.isBefore(rangeEnd) &&
        item.event.endAt.isAfter(rangeStart) &&
        !item.event.cancelled));
