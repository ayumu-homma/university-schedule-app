import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:university_schedule_mobile/core/storage/sqlite_storage_guard.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_readonly_snapshot.dart';
import 'package:university_schedule_mobile/features/notification/application/local_notification_projection.dart';

import 'support/competing_sqlite_lock.dart';
import 'support/sqlite_profiler_control.dart';

void main() {
  test('reads preserved committed schema18 fixture without changing it',
      skip: _fixtureAvailable()
          ? null
          : 'private preserved fixture unavailable', () {
    final fixture = _fixture();
    final beforeDatabaseHash =
        sha256.convert(fixture.database.readAsBytesSync());
    final beforeManifestHash =
        sha256.convert(fixture.manifest.readAsBytesSync());
    final db =
        sql.sqlite3.open(fixture.database.path, mode: sql.OpenMode.readOnly);
    late String owner;
    late int beforeProfileCount;
    late int beforeProjectionCount;
    try {
      expect(db.select('PRAGMA user_version').single.values.single, 18);
      expect(
        db
            .select('PRAGMA journal_mode')
            .single
            .values
            .single
            .toString()
            .toLowerCase(),
        'delete',
      );
      owner = db
          .select(
            "SELECT user_id FROM profiles WHERE onboarding_status = 'complete' LIMIT 1",
          )
          .single['user_id'] as String;
      beforeProfileCount = db
          .select('SELECT COUNT(*) AS count FROM profiles')
          .single['count'] as int;
      beforeProjectionCount = db
          .select(
            'SELECT COUNT(*) AS count FROM local_notification_occurrences',
          )
          .single['count'] as int;
    } finally {
      db.close();
    }
    final ownerHash = sha256.convert(utf8.encode(owner)).toString();
    final request = LocalNotificationReadonlySnapshotRequest(
      databasePath: fixture.database.path,
      regionId: fixture.regionId,
      ownerUserId: owner,
      ownerHash: ownerHash,
      nowUtc: DateTime.utc(2026, 9, 20, 9),
    );
    final snapshot =
        const LocalNotificationReadonlySnapshotLoader().load(request);
    expect(snapshot.context.profileOnboardingStatus, 'complete');
    expect(snapshot.context.profileActive, isTrue);
    expect(snapshot.context.termDeleted, isFalse);
    expect(snapshot.sourceEpoch, greaterThanOrEqualTo(0));
    expect(snapshot.settings, isNotNull);
    expect(snapshot.importedReminderRules, isA<Map<String, List<int>>>());

    expect(
        sha256.convert(fixture.database.readAsBytesSync()), beforeDatabaseHash);
    expect(
        sha256.convert(fixture.manifest.readAsBytesSync()), beforeManifestHash);
    final after =
        sql.sqlite3.open(fixture.database.path, mode: sql.OpenMode.readOnly);
    try {
      expect(
          after
              .select('SELECT COUNT(*) AS count FROM profiles')
              .single['count'],
          beforeProfileCount);
      expect(
        after
            .select(
                'SELECT COUNT(*) AS count FROM local_notification_occurrences')
            .single['count'],
        beforeProjectionCount,
      );
    } finally {
      after.close();
    }
  });

  test('rejects owner mismatch and unsupported schema on a temporary copy',
      skip: _fixtureAvailable()
          ? null
          : 'private preserved fixture unavailable', () {
    final fixture = _fixture();
    final db =
        sql.sqlite3.open(fixture.database.path, mode: sql.OpenMode.readOnly);
    late String owner;
    try {
      owner = db
          .select('SELECT user_id FROM profiles LIMIT 1')
          .single['user_id'] as String;
    } finally {
      db.close();
    }
    final base = LocalNotificationReadonlySnapshotRequest(
      databasePath: fixture.database.path,
      regionId: fixture.regionId,
      ownerUserId: owner,
      ownerHash: '0' * 64,
      nowUtc: DateTime.utc(2026, 9, 20, 9),
    );
    expect(
      () => const LocalNotificationReadonlySnapshotLoader().load(base),
      throwsA(isA<StateError>()),
    );

    final temp = Directory.systemTemp.createTempSync('phase71-loader-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final copyPath = p.join(temp.path, 'app.sqlite');
    File(fixture.database.path).copySync(copyPath);
    final copy = sql.sqlite3.open(copyPath);
    try {
      copy.execute('PRAGMA user_version = 17');
    } finally {
      copy.close();
    }
    expect(
      () => const LocalNotificationReadonlySnapshotLoader(
        allowNonCanonicalPath: true,
      ).load(
        LocalNotificationReadonlySnapshotRequest(
          databasePath: copyPath,
          regionId: fixture.regionId,
          ownerUserId: owner,
          ownerHash: sha256.convert(utf8.encode(owner)).toString(),
          nowUtc: DateTime.utc(2026, 9, 20, 9),
        ),
      ),
      throwsA(isA<StateError>()),
    );

    final canonicalDirectory = Directory(
      p.join(temp.path, 'app_flutter', 'spaces', fixture.regionId),
    )..createSync(recursive: true);
    final canonicalPath = p.join(canonicalDirectory.path, 'app.sqlite');
    final canonicalManifest =
        p.join(canonicalDirectory.path, 'committed-v1.json');
    File(fixture.database.path).copySync(canonicalPath);
    final manifest = Map<String, Object?>.from(
      jsonDecode(fixture.manifest.readAsStringSync()) as Map,
    );
    manifest['candidateSha256'] = 'invalid';
    File(canonicalManifest).writeAsStringSync(jsonEncode(manifest));
    expect(
      () => const LocalNotificationReadonlySnapshotLoader().load(
        LocalNotificationReadonlySnapshotRequest(
          databasePath: canonicalPath,
          regionId: fixture.regionId,
          ownerUserId: owner,
          ownerHash: sha256.convert(utf8.encode(owner)).toString(),
          nowUtc: DateTime.utc(2026, 9, 20, 9),
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('loads an independently generated committed schema18 fixture', () {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final owner = 'portable-owner';
    final snapshot = const LocalNotificationReadonlySnapshotLoader().load(
      LocalNotificationReadonlySnapshotRequest(
        databasePath: fixture.database.path,
        regionId: fixture.regionId,
        ownerUserId: owner,
        ownerHash: sha256.convert(utf8.encode(owner)).toString(),
        nowUtc: DateTime.utc(2026, 9, 20, 9),
      ),
    );
    expect(snapshot.context.profileOnboardingStatus, 'complete');
    expect(snapshot.context.termOwnerUserId, owner);
    expect(snapshot.sourceEpoch, 3);
    expect(snapshot.previousProjectionEpoch, 5);
    expect(snapshot.settings.enabled, isTrue);
  });

  test('real SQLite recurrence, exceptions, imported leads and settings refill',
      () {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    const owner = 'portable-owner';
    final now = DateTime.utc(2026, 9, 20, 9);
    final first = now.add(const Duration(days: 60));
    final moved = first.add(const Duration(days: 3, hours: 2));
    int seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
    final db = sql.sqlite3.open(fixture.database.path);
    try {
      db.execute('''INSERT INTO events
        (id,owner_user_id,calendar_id,title,kind,start_at,end_at,is_all_day,
         rrule,timezone,visibility_level,version)
        VALUES (?,?,?,?,?,?,?,0,?,?,?,1)''', [
        'series',
        owner,
        'portable-calendar',
        'DB series',
        'normal',
        seconds(first),
        seconds(first.add(const Duration(hours: 1))),
        'FREQ=DAILY;COUNT=4',
        'Asia/Tokyo',
        'PRIVATE',
      ]);
      db.execute('''INSERT INTO event_exceptions
        (id,owner_user_id,event_id,recurrence_id,mode,version)
        VALUES (?,?,?,?,?,1)''', [
        'cancel',
        owner,
        'series',
        seconds(first.add(const Duration(days: 1))),
        'cancelled',
      ]);
      db.execute('''INSERT INTO event_exceptions
        (id,owner_user_id,event_id,recurrence_id,mode,override_start_at,
         override_end_at,override_payload_json,version)
        VALUES (?,?,?,?,?,?,?,?,1)''', [
        'move',
        owner,
        'series',
        seconds(first.add(const Duration(days: 2))),
        'modified',
        seconds(moved),
        seconds(moved.add(const Duration(hours: 1))),
        jsonEncode({'title': 'Moved DB instance'}),
      ]);
      db.execute('INSERT INTO notification_schedule_requests VALUES (?,?,?,?)',
          ['series', owner, '[-20160]', 'pending']);
    } finally {
      db.close();
    }
    LocalNotificationReadonlySnapshot load(DateTime at) =>
        const LocalNotificationReadonlySnapshotLoader().load(
          LocalNotificationReadonlySnapshotRequest(
            databasePath: fixture.database.path,
            regionId: fixture.regionId,
            ownerUserId: owner,
            ownerHash: sha256.convert(utf8.encode(owner)).toString(),
            nowUtc: at,
          ),
        );
    const computer = LocalNotificationProjectionComputer();
    expect(computer.compute(load(now), nowUtc: now).plans, isEmpty);
    final advanced = now.add(const Duration(days: 6));
    final refill = computer.compute(load(advanced), nowUtc: advanced);
    expect(refill.plans, hasLength(3));
    expect(
        refill.plans.map((p) => p.triggerAt),
        unorderedEquals([
          first.subtract(const Duration(days: 14)),
          first.add(const Duration(days: 3)).subtract(const Duration(days: 14)),
          moved.subtract(const Duration(days: 14)),
        ]));
    expect(refill.plans.map((p) => p.title), contains('Moved DB instance'));
    expect(refill.plans.map((p) => p.id).toSet(), hasLength(3));
    final update = sql.sqlite3.open(fixture.database.path);
    try {
      update.execute('UPDATE local_notification_settings SET enabled=0');
      update.execute('UPDATE local_notification_source_revisions SET epoch=4');
    } finally {
      update.close();
    }
    final disabled = load(advanced);
    expect(disabled.sourceEpoch, 4);
    expect(computer.compute(disabled, nowUtc: advanced).plans, isEmpty);
  });

  test('guarded loader does not latch unrelated schema errors', () async {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final database = sql.sqlite3.open(fixture.database.path);
    try {
      database.execute('PRAGMA user_version = 17');
    } finally {
      database.close();
    }
    final recorded = <String>[];
    await expectLater(
      const LocalNotificationReadonlySnapshotLoader(
        allowNonCanonicalPath: true,
      ).loadGuarded(
        _portableRequest(fixture),
        checkHealth: (_) async {},
        recordCorruption: (_, reason) async => recorded.add(reason),
      ),
      throwsA(isA<StateError>()),
    );
    expect(recorded, isEmpty);
  });

  test('guarded loader latches malformed canonical bytes', () async {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    fixture.database.writeAsBytesSync(List<int>.filled(64, 0xff));
    final recorded = <String>[];
    await expectLater(
      const LocalNotificationReadonlySnapshotLoader(
        allowNonCanonicalPath: true,
      ).loadGuarded(
        _portableRequest(fixture),
        checkHealth: (_) async {},
        recordCorruption: (_, reason) async => recorded.add(reason),
      ),
      throwsA(isA<CanonicalStorageLatchedException>()),
    );
    expect(recorded, contains('sqlite_result_26'));
  });

  test('guarded loader checks native health before opening', () async {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    var opened = false;
    await expectLater(
      const LocalNotificationReadonlySnapshotLoader(
        allowNonCanonicalPath: true,
      ).loadGuarded(
        _portableRequest(fixture),
        checkHealth: (_) async {
          opened = true;
          throw StateError('native health latch');
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(opened, isTrue);
  });

  test('guarded loader exposes marker persistence failure', () async {
    final fixture = _portableFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    fixture.database.writeAsBytesSync(List<int>.filled(64, 0xff));
    final markerFailure = StateError('marker unavailable');
    await expectLater(
      const LocalNotificationReadonlySnapshotLoader(
        allowNonCanonicalPath: true,
      ).loadGuarded(
        _portableRequest(fixture),
        checkHealth: (_) async {},
        recordCorruption: (_, __) async => throw markerFailure,
      ),
      throwsA(
        isA<SqliteStorageCorruptionException>().having(
          (error) => error.markerCause,
          'markerCause',
          same(markerFailure),
        ),
      ),
    );
  });

  test(
      'background loader waits for a competing database connection',
      () => withoutSqliteProfilerInterference(() async {
            final fixture = _portableFixture();
            addTearDown(() => fixture.root.deleteSync(recursive: true));
            final writer = await CompetingSqliteLock.acquire(fixture.database);
            addTearDown(writer.release);

            var settled = false;
            Object? queryFailure;
            final stopwatch = Stopwatch()..start();
            final future = loadReadonlySnapshotInBackground(
              _portableRequest(fixture),
              allowNonCanonicalPath: true,
            );
            future.then<void>(
              (_) => settled = true,
              onError: (Object error, StackTrace _) {
                queryFailure = error;
                settled = true;
              },
            );
            try {
              await Future<void>.delayed(const Duration(milliseconds: 150));
              expect(settled, isFalse,
                  reason: 'elapsed_ms=${stopwatch.elapsedMilliseconds}; '
                      '${safeSqliteFailureSummary(queryFailure)}');
            } finally {
              await writer.release();
            }
            final snapshot = await future.timeout(const Duration(seconds: 2));
            expect(snapshot.context.ownerUserId, 'portable-owner');
          }));
}

LocalNotificationReadonlySnapshotRequest _portableRequest(
  ({Directory root, File database, String regionId}) fixture,
) =>
    LocalNotificationReadonlySnapshotRequest(
      databasePath: fixture.database.path,
      regionId: fixture.regionId,
      ownerUserId: 'portable-owner',
      ownerHash: sha256.convert(utf8.encode('portable-owner')).toString(),
      nowUtc: DateTime.utc(2026, 9, 20, 9),
    );

bool _fixtureAvailable() {
  final fixture = _fixture();
  return fixture.database.existsSync() && fixture.manifest.existsSync();
}

({Directory root, File database, String regionId}) _portableFixture() {
  final regionId = List.filled(64, 'a').join();
  const owner = 'portable-owner';
  final root = Directory.systemTemp.createTempSync('phase71-portable-');
  final directory = Directory(
    p.join(root.path, 'app_flutter', 'spaces', regionId),
  )..createSync(recursive: true);
  final databaseFile = File(p.join(directory.path, 'app.sqlite'));
  final db = sql.sqlite3.open(databaseFile.path);
  try {
    db.execute('PRAGMA user_version = 18');
    db.execute('''CREATE TABLE local_storage_region_v1 (
      singleton INTEGER PRIMARY KEY, region_id TEXT NOT NULL,
      receipt_sha256 TEXT)''');
    db.execute('''CREATE TABLE profiles (
      user_id TEXT PRIMARY KEY, university_id TEXT, active_term_id TEXT,
      primary_calendar_id TEXT, onboarding_status TEXT)''');
    db.execute('''CREATE TABLE terms (
      id TEXT PRIMARY KEY, university_id TEXT, owner_user_id TEXT,
      academic_year INTEGER, start_date INTEGER, end_date INTEGER,
      instruction_start_date INTEGER, instruction_end_date INTEGER,
      term_type TEXT, is_template INTEGER, status TEXT, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE calendars (
      id TEXT PRIMARY KEY, owner_user_id TEXT)''');
    db.execute('''CREATE TABLE local_notification_source_revisions (
      id INTEGER PRIMARY KEY, epoch INTEGER)''');
    db.execute('''CREATE TABLE local_notification_projection_states (
      owner_user_id TEXT PRIMARY KEY, projection_epoch INTEGER)''');
    db.execute('''CREATE TABLE local_notification_settings (
      owner_user_id TEXT PRIMARY KEY, enabled INTEGER, course_enabled INTEGER,
      assignment_enabled INTEGER, exam_enabled INTEGER, event_enabled INTEGER,
      routine_enabled INTEGER, personal_enabled INTEGER,
      course_reminder_minutes INTEGER, assignment_reminder_minutes INTEGER,
      exam_reminder_minutes INTEGER, event_reminder_minutes INTEGER,
      exam_day_hour INTEGER, exam_day_minute INTEGER,
      quiet_start_minutes INTEGER, quiet_end_minutes INTEGER)''');
    db.execute('''CREATE TABLE period_settings (
      id TEXT PRIMARY KEY, owner_user_id TEXT, university_id TEXT, term_id TEXT,
      day_of_week INTEGER, period_no INTEGER, start_time_minutes INTEGER,
      end_time_minutes INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE user_courses (
      id TEXT PRIMARY KEY, owner_user_id TEXT, term_id TEXT,
      source_template_id TEXT, title TEXT, normalized_title TEXT,
      instructor_name TEXT, normalized_instructor_name TEXT,
      day_of_week INTEGER, period_no INTEGER, room TEXT, color TEXT,
      visibility_level TEXT, version INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE assignments (
      id TEXT PRIMARY KEY, owner_user_id TEXT, course_id TEXT, title TEXT,
      description TEXT, submission_url TEXT, priority TEXT, due_at INTEGER,
      visibility_level TEXT, version INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE assignment_user_states (
      assignment_id TEXT, user_id TEXT, status TEXT, submitted_at INTEGER,
      note TEXT, version INTEGER, deleted_at INTEGER,
      PRIMARY KEY (assignment_id, user_id))''');
    db.execute('''CREATE TABLE exams (
      id TEXT PRIMARY KEY, owner_user_id TEXT, course_id TEXT, title TEXT,
      start_at INTEGER, end_at INTEGER, room TEXT, scope TEXT, memo TEXT,
      exam_type TEXT, visibility_level TEXT, version INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE events (
      id TEXT PRIMARY KEY, owner_user_id TEXT, calendar_id TEXT, group_id TEXT,
      title TEXT, kind TEXT, start_at INTEGER, end_at INTEGER, is_all_day INTEGER,
      location TEXT, description TEXT, rrule TEXT, timezone TEXT,
      visibility_level TEXT, version INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE event_exceptions (
      id TEXT PRIMARY KEY, owner_user_id TEXT, event_id TEXT, recurrence_id INTEGER,
      mode TEXT, override_start_at INTEGER, override_end_at INTEGER,
      override_payload_json TEXT, version INTEGER, deleted_at INTEGER)''');
    db.execute('''CREATE TABLE notification_schedule_requests (
      entity_id TEXT, owner_user_id TEXT, reminders_minutes_json TEXT, state TEXT)''');
    db.execute(
      'INSERT INTO local_storage_region_v1 VALUES (1, ?, NULL)',
      [regionId],
    );
    db.execute(
      'INSERT INTO profiles VALUES (?, ?, ?, ?, ?)',
      [
        owner,
        'portable-university',
        'portable-term',
        'portable-calendar',
        'complete'
      ],
    );
    final start = DateTime.utc(2026, 4, 1).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime.utc(2027, 3, 31).millisecondsSinceEpoch ~/ 1000;
    db.execute(
      'INSERT INTO terms VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, 0, ?, NULL)',
      [
        'portable-term',
        'portable-university',
        owner,
        2026,
        start,
        end,
        'semester',
        'active'
      ],
    );
    db.execute(
        'INSERT INTO calendars VALUES (?, ?)', ['portable-calendar', owner]);
    db.execute('INSERT INTO local_notification_source_revisions VALUES (1, 3)');
    db.execute(
      'INSERT INTO local_notification_projection_states VALUES (?, 5)',
      [owner],
    );
    db.execute(
      'INSERT INTO local_notification_settings VALUES (?, 1, 1, 1, 1, 1, 1, 1, -10, -180, -10080, -60, 8, 0, NULL, NULL)',
      [owner],
    );
  } finally {
    db.close();
  }
  final manifest = File(p.join(directory.path, 'committed-v1.json'));
  manifest.writeAsStringSync(jsonEncode({
    'format': 'storage-publication-v1',
    'phase': 'COMMITTED',
    'regionId': regionId,
    'candidateName': 'app.sqlite',
    'candidateSha256':
        sha256.convert(databaseFile.readAsBytesSync()).toString(),
    'sourceReceiptSha256': null,
    'importedLegacy': false,
  }));
  return (root: root, database: databaseFile, regionId: regionId);
}

({File database, File manifest, String regionId}) _fixture() {
  final root = Directory.current.parent.parent.path;
  const regionId =
      '2f509946d2c4720842dddc0c8373f6e4710be87f343c73b13c0bbb2dd3f4a375';
  final directory = p.join(
    root,
    '.env.phase71-private',
    'emulator-5556-before',
    'app_flutter',
    'spaces',
    regionId,
  );
  return (
    database: File(p.join(directory, 'app.sqlite')),
    manifest: File(p.join(directory, 'committed-v1.json')),
    regionId: regionId,
  );
}
