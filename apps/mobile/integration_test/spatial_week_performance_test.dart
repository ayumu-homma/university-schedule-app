// Diagnostic emulator comparison, using a separate in-memory synthetic Drift
// dataset. This is not physical-device performance or human usability evidence.
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/native/sqlite_identity_handshake.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/course_template/presentation/course_detail_screen.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_flag.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_projection.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/timetable_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/main.dart' as app_entry;

import 'support/spatial_frame_metrics.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('fixed synthetic week paired 2D and spatial diagnostics',
      (tester) async {
    await const SqliteIdentityHandshake().verify(force: true);
    final now = DateTime.utc(2026, 6, 29, 0);
    final db = local.AppDatabase(NativeDatabase.memory());
    final repository =
        DriftScheduleRepository(db, enableDemoData: true, clock: () => now);
    await repository.ensureDemoDataSeeded();
    await repository.createEvent(
        ownerUserId: demoUserId,
        input: EventInput(
          title: '合成データの自習',
          calendarId: demoPersonalCalendarId,
          startAt: DateTime.utc(2026, 6, 30, 3),
          endAt: DateTime.utc(2026, 6, 30, 4),
        ));
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      scheduleRepositoryProvider.overrideWithValue(repository),
      activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
      spatialWeekEnabledProvider.overrideWithValue(true),
      appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
      appClockProvider.overrideWithValue(_FixedClock(now)),
    ]);
    final router = GoRouter(initialLocation: '/spatial-week', routes: [
      GoRoute(
          path: '/spatial-week', builder: (_, __) => const SpatialWeekScreen()),
      GoRoute(path: '/timetable', builder: (_, __) => const TimetableScreen()),
      GoRoute(
          path: '/course/:id',
          builder: (_, state) =>
              CourseDetailScreen(courseId: state.pathParameters['id']!)),
    ]);
    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> batch) => frames.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(collect);
    final windows = <Map<String, Object?>>[];
    try {
      Future<({int? frameNumber, int? presentationMicros})> boundary() async {
        int? stamp;
        int? frameNumber;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          frameNumber = SchedulerBinding
              .instance.platformDispatcher.frameData.frameNumber;
          stamp = SchedulerBinding
              .instance.currentSystemFrameTimeStamp.inMicroseconds;
        });
        await tester.pump();
        expect(stamp, isNotNull);
        return (frameNumber: frameNumber, presentationMicros: stamp);
      }

      Future<void> record(String label, Future<void> Function() action) async {
        // Late frame batches are flushed outside the timed window.
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
        final start = await boundary();
        final elapsed = Stopwatch()..start();
        await action();
        final end = await boundary();
        elapsed.stop();
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
        windows.add({
          'label': label,
          ...summarizeSpatialFrames(
            frames: frames,
            startFrameNumber: start.frameNumber,
            endFrameNumber: end.frameNumber,
            startPresentationMicros: start.presentationMicros,
            endPresentationMicros: end.presentationMicros,
            elapsedMicros: elapsed.elapsedMicroseconds,
          )
        });
      }

      await record('first_entry_separate', () async {
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
                theme: AppTheme.light(), routerConfig: router)));
        await tester.pumpAndSettle();
      });
      final state = await container.read(demoAppControllerProvider.future);
      final snapshot = buildSpatialWeekSnapshot(
          state: state, context: demoScheduleContext, now: now);
      final courseKey = snapshot.entries
          .firstWhere((entry) => entry.sourceId == 'course-algo')
          .key;
      final row = find.byKey(ValueKey<String>('spatial-entry-$courseKey'));
      final scrollable = find.descendant(
        of: find.byKey(const Key('spatial-page-scroll')),
        matching: find.byType(Scrollable),
      );
      Future<void> visible(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      Future<void> prepare(bool flat) async {
        final clear = find.byKey(const Key('spatial-clear-selection'));
        if (clear.evaluate().isNotEmpty) {
          await visible(clear);
          await tester.tap(clear);
          await tester.pumpAndSettle();
        }
        await visible(find.byKey(const Key('spatial-reset')));
        await tester.tap(find.byKey(const Key('spatial-reset')));
        final mode =
            find.byKey(Key(flat ? 'spatial-mode-2d' : 'spatial-mode-depth'));
        await visible(mode);
        await tester.tap(mode);
        await tester.pumpAndSettle();
        // Reset comparison scrolling and camera before each window.
        final scrollState = tester.state<ScrollableState>(scrollable);
        scrollState.position.jumpTo(0);
        await tester.pumpAndSettle();
      }

      Future<void> commonJourney() async {
        await visible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        final open = find.byKey(const Key('spatial-open-detail'));
        await visible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.byType(CourseDetailScreen), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.byType(SpatialWeekScreen), findsOneWidget);
      }

      for (final flat in [true, false]) {
        await prepare(flat);
        await commonJourney(); // One warmup per mode, excluded from samples.
      }
      for (var trial = 1; trial <= 3; trial++) {
        final order = trial.isOdd ? [true, false] : [false, true];
        for (final flat in order) {
          await prepare(flat);
          await record(
              'trial_${trial}_${flat ? '2d' : 'spatial'}', commonJourney);
        }
      }
      await prepare(false);
      await record('spatial_orbit_zoom_separate', () async {
        for (var step = 0; step < 6; step++) {
          await tester.tap(find.byKey(const Key('spatial-turn-left')));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.tap(find.byKey(const Key('spatial-zoom-in')));
        await tester.pumpAndSettle();
      });
      binding.reportData = {
        'schema': 'spatial-week-diagnostics-v2-frame-identity',
        'build_mode': kProfileMode
            ? 'profile'
            : kReleaseMode
                ? 'release'
                : 'debug',
        'dataset': 'isolated in-memory Drift demo + one personal event',
        'fixed_now_utc': now.toIso8601String(),
        'context': 'synthetic demo current term and personal calendar',
        'week_start_utc': snapshot.weekStart.toIso8601String(),
        'entry_count': snapshot.entries.length,
        'screen_logical_size':
            tester.view.physicalSize / tester.view.devicePixelRatio,
        'windows': windows,
        'limitations':
            'Warmed same-list/detail journeys, with mode setup outside each window. First viewer entry follows fixture setup, not cold process launch. No geometric lookup, physical FPS, peak/leak proof, human usability or TalkBack E2E.',
      };
      // Size is not JSON-native; serialize explicitly.
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      binding.reportData!['screen_logical_size'] = {
        'width': size.width,
        'height': size.height
      };
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      container.dispose();
      await db.close();
    }
  });
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

// Keep the ordinary guarded native background entrypoints in this test
// binary. They retain their normal read-only/identity verification behavior.
@pragma('vm:entry-point')
Future<void> phase71HeadlessEntryPoint() =>
    app_entry.phase71HeadlessEntryPoint();

@pragma('vm:entry-point')
Future<void> phase8SqliteProofEntryPoint() =>
    app_entry.phase8SqliteProofEntryPoint();
