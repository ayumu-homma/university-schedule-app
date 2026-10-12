import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/storage/storage_database.dart';
import 'package:university_schedule_mobile/core/storage/sqlite_storage_guard.dart';

import 'support/competing_sqlite_lock.dart';
import 'support/sqlite_profiler_control.dart';

void main() {
  final region = 'a' * 64;

  test('latches a corruption result and rejects queued operations', () async {
    final recorded = <String>[];
    final guard = SqliteStorageGuard(
      regionId: region,
      recordCorruption: (scope, reason) async {
        recorded.add('$scope:$reason');
      },
    );
    final inner = _ThrowingExecutor();

    await expectLater(
      guard.runSelect(inner, 'SELECT broken', const []),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(guard.isLatched, isTrue);
    expect(recorded, ['$region:sqlite_result_11']);
    await expectLater(
      guard.runSelect(inner, 'SELECT queued', const []),
      throwsA(isA<SqliteStorageLatchedException>()),
    );
    expect(inner.selectCalls, 1);
  });

  test('rollback and close remain available after the latch', () async {
    final guard = SqliteStorageGuard(
      regionId: region,
      recordCorruption: (_, __) async {},
    );
    final inner = _ThrowingExecutor();
    await expectLater(
      guard.runSelect(inner, 'SELECT broken', const []),
      throwsA(isA<sqlite.SqliteException>()),
    );

    final transaction = _RecordingTransaction();
    await guard.rollbackTransaction(transaction);
    await guard.close(inner);
    expect(transaction.rollbackCalls, 1);
    expect(inner.closeCalls, 1);
  });

  test('authoritative health failure blocks before queued SQL reaches SQLite',
      () async {
    var healthChecks = 0;
    final guard = SqliteStorageGuard(
      regionId: region,
      checkHealth: (_) async {
        healthChecks++;
        if (healthChecks > 1) throw StateError('durable latch is set');
      },
      recordCorruption: (_, __) async {},
    );
    final inner = _ThrowingExecutor()..throwCorruption = false;
    await guard.runSelect(inner, 'SELECT first', const []);
    await expectLater(
      guard.runSelect(inner, 'SELECT queued', const []),
      throwsA(isA<StateError>()),
    );
    expect(inner.selectCalls, 1);
    expect(healthChecks, 2);
  });

  test('keeps the original sqlite error visible when marker persistence fails',
      () async {
    final guard = SqliteStorageGuard(
      regionId: region,
      recordCorruption: (_, __) async {
        throw StateError('marker unavailable');
      },
    );
    final inner = _ThrowingExecutor();
    await expectLater(
      guard.runSelect(inner, 'SELECT broken', const []),
      throwsA(isA<SqliteStorageCorruptionException>()),
    );
    expect(guard.latchFailure, isNot(equals(null)));
    await expectLater(
      guard.runSelect(inner, 'SELECT queued', const []),
      throwsA(isA<SqliteStorageLatchedException>()),
    );
  });

  test('opens the actual Drift worker executor behind the storage guard',
      () async {
    final root = await Directory.systemTemp.createTemp('storage-worker-test-');
    addTearDown(() => root.delete(recursive: true));
    final region = StorageRegion.fromConfig(AppConfig.demoForTesting());
    final database = await openStorageDatabaseInBackground(
      file: File('${root.path}${Platform.pathSeparator}app.sqlite'),
      region: region,
    );
    addTearDown(database.close);

    expect(
      (await database.customSelect('SELECT 1 AS value').getSingle())
          .read<int>('value'),
      1,
    );
  });

  test(
      'worker busy timeout waits for a competing connection to release',
      () => withoutSqliteProfilerInterference(() async {
            final root =
                await Directory.systemTemp.createTemp('storage-worker-busy-');
            addTearDown(() => root.delete(recursive: true));
            final file =
                File('${root.path}${Platform.pathSeparator}app.sqlite');
            final region = StorageRegion.fromConfig(AppConfig.demoForTesting());

            final database = await openStorageDatabaseInBackground(
              file: file,
              region: region,
            );
            addTearDown(database.close);
            await database.customSelect('SELECT 1').get();
            final timeout =
                await database.customSelect('PRAGMA busy_timeout').getSingle();
            expect(timeout.read<int>('timeout'), sqliteBusyTimeoutMilliseconds);

            final writer = await CompetingSqliteLock.acquire(file);
            addTearDown(writer.release);

            var settled = false;
            Object? queryFailure;
            final stopwatch = Stopwatch()..start();
            final query = database
                .customSelect('SELECT COUNT(*) AS value FROM profiles')
                .getSingle();
            query.then<void>(
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
            final row = await query.timeout(const Duration(seconds: 2));
            stopwatch.stop();

            expect(row.read<int>('value'), 0);
            expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
          }));
}

class _ThrowingExecutor implements QueryExecutor {
  int selectCalls = 0;
  int closeCalls = 0;
  bool throwCorruption = true;

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => true;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async {
    selectCalls++;
    if (!throwCorruption) return const [];
    throw sqlite.SqliteException(
      extendedResultCode: 11,
      message: 'database disk image is malformed',
    );
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => 0;

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => 0;

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {}

  @override
  Future<void> runBatched(BatchedStatements statements) async {}

  @override
  TransactionExecutor beginTransaction() => _RecordingTransaction();

  @override
  QueryExecutor beginExclusive() => this;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _RecordingTransaction extends _ThrowingExecutor
    implements TransactionExecutor {
  int rollbackCalls = 0;
  int commitCalls = 0;

  @override
  bool get supportsNestedTransactions => true;

  @override
  Future<void> rollback() async {
    rollbackCalls++;
  }

  @override
  Future<void> send() async {
    commitCalls++;
  }
}
