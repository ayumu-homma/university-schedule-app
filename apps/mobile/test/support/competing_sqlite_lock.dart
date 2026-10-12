import 'dart:convert';
import 'dart:io';

import 'package:drift/isolate.dart';
import 'package:sqlite3/sqlite3.dart';

String safeSqliteFailureSummary(Object? error) {
  if (error is DriftRemoteException) error = error.remoteCause;
  if (error is! SqliteException) return 'type=${error.runtimeType}';
  const operations = {
    'preparing statement',
    'executing statement',
    'selecting from statement',
    'iterating through statement',
    'executing',
    'opening the database',
  };
  final operation =
      operations.contains(error.operation) ? error.operation : 'other';
  return 'sqlite_code=${error.extendedResultCode}; operation=$operation';
}

/// A different process makes this an OS file-lock test on Windows and POSIX,
/// independent of SQLite libraries loaded by the Flutter test and worker.
/// Python 3 is already required by the repository's local test runner.
final class CompetingSqliteLock {
  CompetingSqliteLock._(this._process);

  final Process _process;
  bool _released = false;

  static Future<CompetingSqliteLock> acquire(File syntheticDatabase) async {
    final process = await Process.start(
      Platform.isWindows ? 'python' : 'python3',
      [
        '-u',
        '-c',
        '''
import sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=2.5)
if db.execute("PRAGMA journal_mode").fetchone()[0] != "delete":
    raise RuntimeError("This test requires rollback-journal locking")
db.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
sys.stdin.readline()
db.rollback()
db.close()
''',
        syntheticDatabase.path,
      ],
    );
    // Drain diagnostics without publishing arbitrary child output.
    process.stderr.drain<void>();
    try {
      final ready = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      if (ready != 'locked') throw StateError('SQLite lock was not acquired');
      return CompetingSqliteLock._(process);
    } catch (_) {
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _process.stdin.writeln('release');
    await _process.stdin.close();
    final exitCode = await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill();
        throw StateError('SQLite lock process did not exit');
      },
    );
    if (exitCode != 0) throw StateError('SQLite lock release failed');
  }
}
