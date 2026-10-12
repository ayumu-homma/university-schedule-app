import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/time/app_clock.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../domain/today_briefing.dart';

Duration durationUntilNextTodayRefresh(DateTime now) {
  final utc = now.toUtc();
  final nextMinute = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
    utc.hour,
    utc.minute + 1,
  );
  final delay = nextMinute.difference(utc);
  return delay <= Duration.zero ? const Duration(seconds: 1) : delay;
}

/// Emits immediately and then at wall-clock minute boundaries. Re-reading the
/// injected clock whenever the provider is invalidated avoids retaining a
/// stale `now` captured at app startup. Visible Today surfaces own the refresh
/// timer so its lifetime is tied synchronously to their widget lifecycle.
final todayTimeProvider = StreamProvider.autoDispose<DateTime>((ref) {
  final clock = ref.watch(appClockProvider);
  return Stream.value(clock.now());
});

/// Schedules Today refreshes while a Today surface is visible.
///
/// Keeping this timer in the owning widget (instead of a long-lived provider)
/// guarantees it is cancelled immediately on navigation, logout, and test
/// teardown. Each tick reads the clock again before calculating the next wall-
/// clock boundary, so delayed resume and civil-time changes converge safely.
class TodayRefreshTimer {
  Timer? _timer;
  bool _disposed = false;

  void start({
    required AppClock clock,
    required void Function() onRefresh,
  }) {
    _timer?.cancel();

    void schedule() {
      if (_disposed) return;
      final now = clock.now();
      _timer = Timer(durationUntilNextTodayRefresh(now), () {
        if (_disposed) return;
        onRefresh();
        schedule();
      });
    }

    schedule();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

final todayBriefingServiceProvider = Provider<TodayBriefingService>((ref) {
  return TodayBriefingService();
});

final todayBriefingProvider =
    Provider.autoDispose<AsyncValue<TodayBriefing>>((ref) {
  final schedule = ref.watch(demoAppControllerProvider);
  final time = ref.watch(todayTimeProvider);

  return time.when(
    data: (now) => schedule.when(
      data: (state) => AsyncData(
        ref.watch(todayBriefingServiceProvider).build(
              now: now,
              courses: state.courses,
              periodSettings: state.periodSettings,
              assignments: state.assignments,
              assignmentStates: state.assignmentStates,
              exams: state.exams,
              events: state.events,
              eventExceptions: state.eventExceptions,
            ),
      ),
      loading: () => const AsyncLoading(),
      error: AsyncError.new,
    ),
    loading: () => const AsyncLoading(),
    error: AsyncError.new,
  );
});
