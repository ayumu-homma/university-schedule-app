import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../../../core/native/native_scope_bridge.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database_provider.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import 'morning_alarm_controller.dart';
import 'local_notification_platform.dart';
import '../data/local_notification_readonly_snapshot.dart';
import 'local_notification_projection.dart';

final localNotificationRuntimeProvider = AsyncNotifierProvider<
    LocalNotificationRuntime, LocalNotificationPlatformState>(
  LocalNotificationRuntime.new,
);

class LocalNotificationRuntime
    extends AsyncNotifier<LocalNotificationPlatformState> {
  var _generation = 0;

  @override
  Future<LocalNotificationPlatformState> build() async {
    // The schedule stream is a wakeup only.  The planner below always reloads
    // canonical rows and certifies the same source epoch before publishing.
    ref.onDispose(() => _generation += 1);
    ref.watch(demoAppControllerProvider);
    var exhaustedReason = 'source_busy';
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _reconcile();
      } on sql.SqliteException catch (error) {
        // The readonly snapshot loader has already unwound its transaction
        // and closed the handle before this reaches the runtime. Retry only a
        // primary SQLITE_BUSY result; cleanup failures and corruption wrappers
        // must retain their original error path.
        if ((error.resultCode & 0xff) != 5) rethrow;
        exhaustedReason = 'storage_busy';
        await Future<void>.delayed(
          Duration(milliseconds: 60 * (attempt + 1)),
        );
      } on StateError catch (error) {
        final message = error.message.toString();
        if (message == 'storage_busy') {
          exhaustedReason = 'storage_busy';
          await Future<void>.delayed(
            Duration(milliseconds: 60 * (attempt + 1)),
          );
          continue;
        }
        if (!message.contains('Notification source changed') &&
            !message.contains('projection_epoch_changed') &&
            !message.contains('context changed')) {
          rethrow;
        }
        exhaustedReason = 'source_busy';
        await Future<void>.value();
      }
    }
    return LocalNotificationPlatformState(
      permission: 'blocked',
      exactAlarm: 'unknown',
      scheduledCount: 0,
      blockedReason: exhaustedReason,
    );
  }

  Future<LocalNotificationPlatformState> _reconcile() async {
    final generation = ++_generation;
    final context = ref.watch(activeScheduleContextProvider);
    if (context == null) {
      return const LocalNotificationPlatformState(
        permission: 'inactive',
        exactAlarm: 'inactive',
        scheduledCount: 0,
      );
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const LocalNotificationPlatformState(
        permission: 'unsupported',
        exactAlarm: 'unsupported',
        scheduledCount: 0,
      );
    }
    final alarm = ref.watch(morningAlarmControllerProvider).valueOrNull;
    final scope =
        alarm?.scope ?? await ref.read(nativeScopeBridgeProvider).current();
    if (!scope.matchesOwner(context.ownerUserId)) {
      return const LocalNotificationPlatformState(
        permission: 'blocked',
        exactAlarm: 'blocked',
        scheduledCount: 0,
        blockedReason: 'scope_inactive',
      );
    }
    final now = ref.read(appClockProvider).now().toUtc();
    final snapshot = await loadReadonlySnapshotInBackground(
      LocalNotificationReadonlySnapshotRequest(
        databasePath: ref.read(appDatabasePathProvider),
        regionId: scope.regionId!,
        ownerUserId: context.ownerUserId,
        ownerHash: scope.ownerHash!,
        nowUtc: now,
      ),
    );
    if (snapshot.context.universityId != context.universityId ||
        snapshot.context.termId != context.termId ||
        snapshot.context.academicYear != context.academicYear ||
        snapshot.context.primaryCalendarId != context.primaryCalendarId) {
      throw StateError('Notification context changed while planning.');
    }
    final projection = const LocalNotificationProjectionComputer().compute(
      snapshot,
      nowUtc: now,
    );
    _assertCurrent(generation, context.ownerUserId);
    final result =
        await ref.read(localNotificationPlatformProvider).publishProjection(
              payload: projection.toPublicationPayload(
                databasePath: ref.read(appDatabasePathProvider),
                regionId: scope.regionId!,
                ownerHash: scope.ownerHash!,
                generation: scope.generation,
                activationToken: scope.activationToken!,
              ),
            );
    _assertCurrent(generation, context.ownerUserId);
    if (result.blockedReason == 'stale_projection' ||
        result.blockedReason == 'source_changed' ||
        result.blockedReason == 'context_changed') {
      throw StateError('Notification source changed while publishing.');
    }
    if (result.blockedReason == 'storage_busy') {
      // Both the readonly transaction and native publication transaction have
      // ended before this status is returned. Retry a fresh reconciliation
      // from the bounded outer loop, never an individual SQL statement.
      throw StateError('storage_busy');
    }
    return result;
  }

  void _assertCurrent(int generation, String ownerUserId) {
    if (generation != _generation ||
        ref.read(activeScheduleContextProvider)?.ownerUserId != ownerUserId) {
      throw StateError('Notification planning was superseded.');
    }
  }
}
