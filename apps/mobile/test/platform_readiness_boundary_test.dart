import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_platform.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';
import 'package:university_schedule_mobile/features/widget_bridge/application/widget_snapshot_repository.dart';

void main() {
  test('iOS morning alarm fails closed until native integration exists',
      () async {
    final platform = morningAlarmPlatformFor(TargetPlatform.iOS);

    expect(platform, isA<UnsupportedMorningAlarmPlatform>());
    expect(
      await platform.synchronizeOwner(null),
      const MorningAlarmPlatformState.signedOut(),
    );
    await expectLater(
      platform.synchronizeOwner('synthetic-owner'),
      throwsUnsupportedError,
    );
  });

  test('iOS widget bridge never substitutes an in-memory production success',
      () async {
    final repository = widgetSnapshotRepositoryFor(TargetPlatform.iOS);

    expect(repository, isA<UnsupportedWidgetSnapshotRepository>());
    await expectLater(repository.readLatestSnapshot(), throwsUnsupportedError);
  });

  test('desktop fake requires an explicit debug/test allowance', () {
    expect(
      morningAlarmPlatformFor(
        TargetPlatform.windows,
        allowDesktopTestFallback: false,
      ),
      isA<UnsupportedMorningAlarmPlatform>(),
    );
    expect(
      widgetSnapshotRepositoryFor(
        TargetPlatform.windows,
        allowDesktopTestFallback: false,
      ),
      isA<UnsupportedWidgetSnapshotRepository>(),
    );
    expect(
      morningAlarmPlatformFor(
        TargetPlatform.windows,
        allowDesktopTestFallback: true,
      ),
      isA<InMemoryMorningAlarmPlatform>(),
    );
    expect(
      widgetSnapshotRepositoryFor(
        TargetPlatform.windows,
        allowDesktopTestFallback: true,
      ),
      isA<InMemoryWidgetSnapshotRepository>(),
    );
  });
}
