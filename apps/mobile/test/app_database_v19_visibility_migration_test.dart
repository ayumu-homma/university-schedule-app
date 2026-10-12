import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('v18 to v19 preserves values and defaults while enabling NULL',
      () async {
    final db = _version18Database();
    addTearDown(db.close);

    final version = await db
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    expect(version, 19);

    final calendar = await db
        .customSelect(
          "SELECT default_visibility FROM calendars WHERE id = 'calendar-kept'",
        )
        .getSingle();
    expect(calendar.read<String>('default_visibility'), 'BUSY_ONLY');
    final event = await db
        .customSelect(
          "SELECT visibility_level FROM events WHERE id = 'event-kept'",
        )
        .getSingle();
    expect(event.read<String>('visibility_level'), 'FULL');

    await db.customStatement('''
      INSERT INTO calendars (id, owner_user_id, group_id, name)
      VALUES ('calendar-default', 'owner', NULL, 'Default')
    ''');
    await db.customStatement('''
      INSERT INTO events (
        id, owner_user_id, calendar_id, group_id, title, kind,
        start_at, end_at, is_all_day
      ) VALUES (
        'event-default', 'owner', 'calendar-default', NULL, 'Default',
        'normal', 100, 200, 0
      )
    ''');
    final defaults = await db.customSelect('''
      SELECT calendars.default_visibility AS calendar_default,
             events.visibility_level AS event_default
      FROM calendars JOIN events ON events.calendar_id = calendars.id
      WHERE events.id = 'event-default'
    ''').getSingle();
    expect(defaults.read<String>('calendar_default'), 'PRIVATE');
    expect(defaults.read<String>('event_default'), 'PRIVATE');

    await db.customStatement('''
      UPDATE calendars SET default_visibility = NULL
      WHERE id = 'calendar-kept'
    ''');
    await db.customStatement('''
      UPDATE events SET visibility_level = NULL WHERE id = 'event-kept'
    ''');
    final nullable = await db.customSelect('''
      SELECT calendars.default_visibility AS calendar_value,
             events.visibility_level AS event_value
      FROM calendars JOIN events ON events.calendar_id = calendars.id
      WHERE events.id = 'event-kept'
    ''').getSingle();
    expect(nullable.readNullable<String>('calendar_value'), isNull);
    expect(nullable.readNullable<String>('event_value'), isNull);

    final triggers = await db.customSelect('''
      SELECT name FROM sqlite_master
      WHERE type = 'trigger' AND name = 'local_notification_epoch_events_update'
    ''').get();
    expect(triggers, hasLength(1));
    final before = await db
        .customSelect(
          'SELECT epoch FROM local_notification_source_revisions WHERE id = 1',
        )
        .map((row) => row.read<int>('epoch'))
        .getSingle();
    await db.customStatement(
      "UPDATE events SET title = 'Preserved and updated' WHERE id = 'event-kept'",
    );
    final after = await db
        .customSelect(
          'SELECT epoch FROM local_notification_source_revisions WHERE id = 1',
        )
        .map((row) => row.read<int>('epoch'))
        .getSingle();
    expect(after, before + 1);
  });
}

local.AppDatabase _version18Database() {
  return local.AppDatabase(
    NativeDatabase.memory(
      setup: (db) {
        db.execute('''
          CREATE TABLE calendars (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            group_id TEXT,
            name TEXT NOT NULL,
            default_visibility TEXT NOT NULL DEFAULT 'PRIVATE',
            updated_at INTEGER NOT NULL DEFAULT 0
          )
        ''');
        db.execute('''
          CREATE TABLE events (
            id TEXT NOT NULL PRIMARY KEY,
            owner_user_id TEXT NOT NULL,
            calendar_id TEXT NOT NULL,
            group_id TEXT,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            start_at INTEGER NOT NULL,
            end_at INTEGER NOT NULL,
            is_all_day INTEGER NOT NULL DEFAULT 0,
            location TEXT,
            description TEXT,
            rrule TEXT,
            timezone TEXT NOT NULL DEFAULT 'Asia/Tokyo',
            visibility_level TEXT NOT NULL DEFAULT 'PRIVATE',
            updated_at INTEGER NOT NULL DEFAULT 0,
            deleted_at INTEGER,
            version INTEGER NOT NULL DEFAULT 1
          )
        ''');
        db.execute('''
          INSERT INTO calendars (id, owner_user_id, name, default_visibility)
          VALUES ('calendar-kept', 'owner', 'Kept', 'BUSY_ONLY')
        ''');
        db.execute('''
          INSERT INTO events (
            id, owner_user_id, calendar_id, title, kind, start_at, end_at,
            visibility_level
          ) VALUES (
            'event-kept', 'owner', 'calendar-kept', 'Kept', 'normal',
            100, 200, 'FULL'
          )
        ''');
        db.execute('''
          CREATE TABLE sync_queue_entries (
            client_mutation_id TEXT NOT NULL PRIMARY KEY,
            idempotency_key TEXT,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            synced_at INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            error_message TEXT,
            base_version INTEGER,
            server_version INTEGER,
            server_payload_json TEXT,
            conflict_cursor INTEGER,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_retry_at INTEGER,
            last_attempt_at INTEGER,
            claimed_at INTEGER,
            owner_user_id TEXT NOT NULL,
            enqueue_sequence INTEGER NOT NULL DEFAULT 0,
            completion_provenance TEXT
          )
        ''');
        db.execute('''
          CREATE TABLE sync_queue_sequence_states (
            id INTEGER NOT NULL PRIMARY KEY,
            next_value INTEGER NOT NULL
          )
        ''');
        db.execute('''
          CREATE TABLE local_notification_settings (id TEXT PRIMARY KEY)
        ''');
        db.execute('''
          CREATE TABLE local_notification_occurrences (
            owner_user_id TEXT NOT NULL,
            trigger_at INTEGER NOT NULL,
            source_entity_id TEXT
          )
        ''');
        db.execute('''
          CREATE TABLE local_notification_projection_states (id TEXT PRIMARY KEY)
        ''');
        db.execute('PRAGMA user_version = 18');
      },
    ),
  );
}
