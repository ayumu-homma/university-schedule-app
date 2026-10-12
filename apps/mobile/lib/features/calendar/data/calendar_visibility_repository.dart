import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database.dart';
import '../../auth/application/auth_providers.dart';
import '../../timetable/data/local_schedule_repository.dart';

final calendarVisibilityRepositoryProvider =
    Provider<CalendarVisibilityRepository>((ref) {
  return CalendarVisibilityRepository(
    database: ref.watch(appDatabaseProvider),
    client: ref.watch(supabaseClientProvider),
    demoMode: ref.watch(appConfigProvider).demoMode,
    ownerUserId: ref.watch(requiredActiveScheduleContextProvider).ownerUserId,
    calendarId:
        ref.watch(requiredActiveScheduleContextProvider).primaryCalendarId,
    currentUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    currentScheduleOwnerId: () =>
        ref.read(activeScheduleContextProvider)?.ownerUserId,
    clock: ref.watch(appClockProvider).now,
  );
});

class CalendarVisibilityRepository {
  CalendarVisibilityRepository({
    required this.database,
    required this.client,
    required this.demoMode,
    required this.ownerUserId,
    required this.calendarId,
    required this.currentUserId,
    required this.currentScheduleOwnerId,
    required this.clock,
  });

  final AppDatabase database;
  final SupabaseClient? client;
  final bool demoMode;
  final String ownerUserId;
  final String calendarId;
  final String? Function() currentUserId;
  final String? Function() currentScheduleOwnerId;
  final DateTime Function() clock;

  Future<VisibilityLevel?> load() async {
    final row = await _ownedPersonalCalendar();
    return _parseVisibility(row.defaultVisibility);
  }

  Future<void> save(VisibilityLevel? visibility) async {
    final row = await _ownedPersonalCalendar();
    if (demoMode) {
      await _persist(row, visibility);
      return;
    }

    final supabase = client;
    if (supabase == null ||
        currentUserId() != ownerUserId ||
        supabase.auth.currentUser?.id != ownerUserId) {
      throw StateError('The authenticated calendar owner is unavailable.');
    }
    await supabase.rpc(
      'set_personal_calendar_default_visibility',
      params: {
        'p_calendar_id': calendarId,
        'p_visibility': visibility?.wireName,
      },
    );
    if (currentUserId() != ownerUserId ||
        currentScheduleOwnerId() != ownerUserId) {
      throw StateError('The active account changed while saving.');
    }
    await _persist(row, visibility);
  }

  Future<Calendar> _ownedPersonalCalendar() async {
    if (ownerUserId.isEmpty ||
        calendarId.isEmpty ||
        currentScheduleOwnerId() != ownerUserId) {
      throw StateError('The active calendar context is unavailable.');
    }
    final row = await (database.select(database.calendars)
          ..where((calendar) =>
              calendar.id.equals(calendarId) &
              calendar.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (row == null || row.groupId != null) {
      throw StateError('Only the owner personal calendar can be changed.');
    }
    return row;
  }

  Future<void> _persist(
    Calendar row,
    VisibilityLevel? visibility,
  ) async {
    final updated = await (database.update(database.calendars)
          ..where((calendar) =>
              calendar.id.equals(row.id) &
              calendar.ownerUserId.equals(ownerUserId) &
              calendar.groupId.isNull()))
        .write(
      CalendarsCompanion(
        defaultVisibility: Value(visibility?.wireName),
        updatedAt: Value(clock().toUtc()),
      ),
    );
    if (updated != 1) {
      throw StateError('The personal calendar changed before it was saved.');
    }
  }

  VisibilityLevel? _parseVisibility(String? value) {
    if (value == null) return null;
    return VisibilityLevel.fromWire(value);
  }
}
