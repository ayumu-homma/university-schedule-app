import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/competing_sqlite_lock.dart';
import 'support/sqlite_profiler_control.dart';

void main() {
  test('SQLite runtime timeout diagnostics', () async {
    await _measureTimeout('baseline');
    if ((await developer.Service.getInfo()).serverUri == null &&
        !Platform.isLinux) {
      return;
    }
    await withoutSqliteProfilerInterference(
      () => _measureTimeout('profiler_disabled'),
    );
  });
}

Future<void> _measureTimeout(String mode) async {
  final directory = await Directory.systemTemp.createTemp('sqlite-control-');
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}/control.sqlite');
  final db = sqlite3.open(file.path);
  addTearDown(db.close);
  db.execute('CREATE TABLE timeout_control (value INTEGER)');
  db.execute('INSERT INTO timeout_control VALUES (1)');
  db.execute('PRAGMA busy_timeout = 250');
  final configuredTimeout = db.select('PRAGMA busy_timeout').single['timeout'];
  const optionPrefixes = [
    'THREADSAFE=',
    'HAVE_USLEEP',
    'ENABLE_SETLK_TIMEOUT',
    'OMIT_SHARED_CACHE',
    'DEFAULT_LOCKING_MODE=',
    'ENABLE_UNLOCK_NOTIFY',
  ];
  final options = db
      .select('PRAGMA compile_options')
      .map((row) => row['compile_options'] as String)
      .where((option) => optionPrefixes.any(option.startsWith))
      .toList();
  final statement = db.prepare('SELECT value FROM timeout_control');
  addTearDown(statement.close);
  final writer = await CompetingSqliteLock.acquire(file);
  addTearDown(writer.release);
  Object? failure;
  final watch = Stopwatch()..start();
  try {
    statement.select();
  } catch (error) {
    failure = error;
  } finally {
    watch.stop();
    await writer.release();
  }
  // Public package APIs only: sqlite3_sleep is not an exported symbol on
  // every bundled platform. Report a separate synchronous timeout control;
  // this does not replace the production worker acceptance assertions.
  // ignore: avoid_print
  print(jsonEncode({
    'sqlite_runtime_diagnostic': true,
    'mode': mode,
    'platform': Platform.operatingSystem,
    'sqlite_version': sqlite3.version.libVersion,
    'busy_timeout_ms': configuredTimeout,
    'exclusive_lock_query_elapsed_ms': watch.elapsedMilliseconds,
    'failure': safeSqliteFailureSummary(failure),
    'known_compile_options': options,
  }));
  expect(configuredTimeout, 250);
  expect(failure, isA<SqliteException>());
  expect((failure as SqliteException).resultCode, 5);
}
