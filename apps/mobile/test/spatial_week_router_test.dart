import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/app/router.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_flag.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_canvas.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  test('normal compile-time build defaults to disabled', () {
    final container = ProviderContainer();
    try {
      expect(container.read(spatialWeekEnabledProvider), isFalse);
    } finally {
      container.dispose();
    }
  });

  for (final enabled in [false, true]) {
    testWidgets('actual router direct path with spatial flag $enabled',
        (tester) async {
      final auth = FakeAuthRepository(
        initialSession: const AppAuthSession(userId: demoUserId),
      );
      final container = ProviderContainer(overrides: [
        appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
        authRepositoryProvider.overrideWithValue(auth),
        activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
        demoAppControllerProvider.overrideWith(_EmptySchedule.new),
        spatialWeekEnabledProvider.overrideWithValue(enabled),
      ]);
      try {
        await container.read(authStateProvider.future);
        final router = container.read(routerProvider);
        router.go('/spatial-week');
        await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router)));
        await tester.pumpAndSettle();
        expect(router.state.uri.path, enabled ? '/spatial-week' : '/timetable');
        expect(find.byType(SpatialWeekScreen),
            enabled ? findsOneWidget : findsNothing);
        expect(find.byType(SpatialWeekCanvas),
            enabled ? findsOneWidget : findsNothing);
        if (!enabled) {
          expect(find.byKey(const Key('open-spatial-week')), findsNothing);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await auth.dispose();
      }
    });
  }

  testWidgets('enabled experimental route still requires authentication',
      (tester) async {
    final auth = FakeAuthRepository();
    final container = ProviderContainer(overrides: [
      appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
      authRepositoryProvider.overrideWithValue(auth),
      spatialWeekEnabledProvider.overrideWithValue(true),
    ]);
    try {
      await container.read(authStateProvider.future);
      final router = container.read(routerProvider);
      router.go('/spatial-week');
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/sign-in');
      expect(find.byType(SpatialWeekScreen), findsNothing);
      expect(find.byType(SpatialWeekCanvas), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await auth.dispose();
    }
  });
}

class _EmptySchedule extends DemoAppController {
  @override
  Stream<DemoAppState> build() => Stream.value(
        DemoAppState.empty(now: DateTime.utc(2026, 6, 29)),
      );
}
