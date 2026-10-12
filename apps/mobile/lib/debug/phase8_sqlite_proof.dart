@ffi.DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:sqlite3/unstable/ffi_bindings.dart' as sqlite_bindings;

import '../core/config/app_config.dart';
import '../core/config/storage_region.dart';
import '../core/native/sqlite_identity_handshake.dart';
import '../core/storage/storage_database.dart';

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)>(
  symbol: 'sqlite3_vfs_find',
)
external ffi.Pointer<ffi.Void> phase8Sqlite3VfsFind(ffi.Pointer<ffi.Char> name);

const phase8SqliteProofChannelName =
    'jp.universityschedule.app/phase8_sqlite_proof';

class _Phase8ServicesBinding extends BindingBase
    with SchedulerBinding, ServicesBinding {}

/// Debug-only cache proof entrypoint. The production worker keeps this
/// delegate in main.dart so the entrypoint remains discoverable by the VM,
/// while all proof behavior stays isolated from normal bootstrap.
@pragma('vm:entry-point')
Future<void> phase8SqliteProofEntryPoint() async {
  try {
    ServicesBinding.instance;
  } on Object {
    _Phase8ServicesBinding();
  }

  const identity = MethodChannel(sqliteIdentityChannelName);
  const proof = MethodChannel(phase8SqliteProofChannelName);
  Map<Object?, Object?>? identityReport;
  try {
    await const SqliteIdentityHandshake().verify(force: true);
    final addresses = <int>[
      sqlite_bindings.addresses.sqlite3_open_v2.address,
      sqlite_bindings.addresses.sqlite3_prepare_v2.address,
      sqlite_bindings.addresses.sqlite3_step.address,
      sqlite_bindings.addresses.sqlite3_finalize.address,
      sqlite_bindings.addresses.sqlite3_close_v2.address,
      phase8Sqlite3VfsFind(ffi.nullptr).address,
    ];
    final raw = await identity.invokeMethod<Object?>('verify', {
      'dartAddresses': addresses,
      'binding': 'package:sqlite3-3.3.4',
    });
    if (raw is! Map) throw const FormatException('identity report missing');
    identityReport = Map<Object?, Object?>.from(raw);
  } on Object catch (error) {
    await proof.invokeMethod<void>('result', {
      'ok': false,
      'error': error.toString(),
    });
    return;
  }

  final release = Completer<void>();
  final nativeContenderStarted = Completer<void>();
  proof.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'run':
        try {
          final raw = call.arguments;
          if (raw is! Map || raw['databasePath'] is! String) {
            throw const FormatException('proof database path missing');
          }
          final args = Map<Object?, Object?>.from(raw);
          final result = await _runDartWriter(
            path: args['databasePath'] as String,
            createSchema: args['createSchema'] == true,
            holdForNative: args['holdForNative'] == true,
            release: release,
            healthContention: args['healthContention'] == true,
            healthRegion: args['healthRegion'] as String?,
            nativeContenderStarted: nativeContenderStarted,
          );
          result['identity'] = identityReport;
          result['dartAddresses'] = <int>[
            sqlite_bindings.addresses.sqlite3_open_v2.address,
            sqlite_bindings.addresses.sqlite3_prepare_v2.address,
            sqlite_bindings.addresses.sqlite3_step.address,
            sqlite_bindings.addresses.sqlite3_finalize.address,
            sqlite_bindings.addresses.sqlite3_close_v2.address,
            phase8Sqlite3VfsFind(ffi.nullptr).address,
          ];
          result['dartVfsAddress'] = phase8Sqlite3VfsFind(ffi.nullptr).address;
          await proof.invokeMethod<void>('result', result);
        } on Object catch (error) {
          final message = error.toString();
          final busy =
              error is sqlite3.SqliteException && error.resultCode == 5;
          await proof.invokeMethod<void>('result', {
            'ok': false,
            'error': message,
            'busy': busy,
            'resultCode':
                error is sqlite3.SqliteException ? error.resultCode : null,
            'identity': identityReport,
            'dartAddresses': <int>[
              sqlite_bindings.addresses.sqlite3_open_v2.address,
              sqlite_bindings.addresses.sqlite3_prepare_v2.address,
              sqlite_bindings.addresses.sqlite3_step.address,
              sqlite_bindings.addresses.sqlite3_finalize.address,
              sqlite_bindings.addresses.sqlite3_close_v2.address,
              phase8Sqlite3VfsFind(ffi.nullptr).address,
            ],
            'dartVfsAddress': phase8Sqlite3VfsFind(ffi.nullptr).address,
          });
        }
        return null;
      case 'release':
        if (!release.isCompleted) release.complete();
        return null;
      case 'nativeContenderStarted':
        if (!nativeContenderStarted.isCompleted) {
          nativeContenderStarted.complete();
        }
        return null;
      default:
        return null;
    }
  });
  await proof.invokeMethod<void>('ready', {'schemaVersion': 1});
}

Future<Map<String, Object?>> _runDartWriter({
  required String path,
  required bool createSchema,
  required bool holdForNative,
  required Completer<void> release,
  required bool healthContention,
  required String? healthRegion,
  required Completer<void> nativeContenderStarted,
}) async {
  if (healthContention) {
    return _runHealthDriftWriter(
      path: path,
      healthRegion: healthRegion,
      nativeContenderStarted: nativeContenderStarted,
    );
  }
  final database = sqlite3.sqlite3.open(path);
  try {
    // This is intentionally a query: PRAGMA journal_mode returns a row.
    final journalMode =
        database.select('PRAGMA journal_mode').single.values.single;
    database.execute('PRAGMA busy_timeout = 5000');
    if (createSchema) {
      database.execute(
        'CREATE TABLE IF NOT EXISTS values_fixture ('
        'id INTEGER PRIMARY KEY, text_value TEXT NOT NULL, '
        'int_value INTEGER, real_value REAL, blob_value BLOB, '
        'null_value TEXT)',
      );
    }
    if (holdForNative) {
      database.execute('BEGIN IMMEDIATE');
      database.execute(
        'INSERT INTO values_fixture(text_value,int_value,real_value,blob_value,null_value) '
        'VALUES(?,?,?,?,?)',
        [
          'dart-engine-0\u0000🎓',
          9223372036854775807,
          3.25,
          Uint8List.fromList(<int>[0, 1, 2, 127, 255]),
          null
        ],
      );
      await const MethodChannel(phase8SqliteProofChannelName)
          .invokeMethod<void>('dartLockAcquired');
      await release.future;
      database.execute('COMMIT');
    } else {
      database.execute(
        'INSERT INTO values_fixture(text_value,int_value,real_value,blob_value,null_value) '
        'VALUES(?,?,?,?,?)',
        [
          'dart-engine\u0000🎓',
          9223372036854775807,
          3.25,
          Uint8List.fromList(<int>[0, 1, 2, 127, 255]),
          null
        ],
      );
    }
    if (!healthContention) {
      final rowsBeforeRollback = database
          .select(
            'SELECT COUNT(*) AS count FROM values_fixture',
          )
          .single['count'];
      database.execute('BEGIN IMMEDIATE');
      database.execute(
        'INSERT INTO values_fixture(text_value) VALUES(?)',
        ['dart-rollback-marker'],
      );
      database.execute('ROLLBACK');
      final rowsAfterRollback = database
          .select(
            'SELECT COUNT(*) AS count FROM values_fixture',
          )
          .single['count'];
      if (rowsAfterRollback != rowsBeforeRollback) {
        throw StateError('dart rollback changed row count');
      }
    }
    final rows = database.select(
      'SELECT text_value,int_value,real_value,blob_value,null_value '
      'FROM values_fixture ORDER BY id',
    );
    if (rows.isEmpty) throw StateError('dart proof row missing');
    if (!createSchema) {
      final nativeRows = rows
          .where((row) => row['text_value'] == 'native-seed\u0000🎓')
          .toList();
      if (nativeRows.length != 1) {
        throw StateError('native typed row missing in Dart');
      }
      final nativeRow = nativeRows.single;
      if (nativeRow['int_value'] != 9223372036854775807 ||
          (nativeRow['real_value'] as num).toDouble() != 3.25 ||
          !listEquals(nativeRow['blob_value'] as Uint8List,
              Uint8List.fromList(<int>[0, 1, 2, 127, 255])) ||
          nativeRow['null_value'] != null) {
        throw StateError('native typed values mismatch in Dart');
      }
    }
    final expectedDartText = 'dart-engine${holdForNative ? '-0' : ''}\u0000🎓';
    final dartRows =
        rows.where((row) => row['text_value'] == expectedDartText).toList();
    if (dartRows.length != 1) {
      throw StateError('Dart typed row missing or duplicated');
    }
    final dartRow = dartRows.single;
    if (dartRow['int_value'] != 9223372036854775807 ||
        (dartRow['real_value'] as num).toDouble() != 3.25 ||
        !listEquals(dartRow['blob_value'] as Uint8List,
            Uint8List.fromList(<int>[0, 1, 2, 127, 255])) ||
        dartRow['null_value'] != null) {
      throw StateError('dart typed values mismatch');
    }
    return <String, Object?>{
      'ok': true,
      'dartRows': rows.length,
      'journalMode': journalMode?.toString(),
      'heldBeginImmediate': holdForNative,
      'rollback': true,
    };
  } finally {
    database.close();
  }
}

/// Exercises the production Drift opener and its background SQLite worker.
/// The transaction callback itself remains in the root isolate, while every
/// SQL statement is executed by the [NativeDatabase] owned by DriftIsolate.
Future<Map<String, Object?>> _runHealthDriftWriter({
  required String path,
  required String? healthRegion,
  required Completer<void> nativeContenderStarted,
}) async {
  if (healthRegion == null) {
    throw const FormatException('health contention region missing');
  }
  final factoryRegion = StorageRegion.fromConfig(AppConfig.demoForTesting());
  final database = await openStorageDatabaseInBackground(
    file: File(path),
    region: factoryRegion,
  );
  try {
    // The native seed normally creates this table. Keeping the statement here
    // makes the proof self-describing while still running through Drift's
    // actual worker executor.
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS values_fixture ('
      'id INTEGER PRIMARY KEY, text_value TEXT NOT NULL, '
      'int_value INTEGER, real_value REAL, blob_value BLOB, null_value TEXT)',
    );
    final journalMode =
        (await database.customSelect('PRAGMA journal_mode').getSingle())
            .read<String>('journal_mode');
    var healthElapsedMs = 0;
    await database.transaction(() async {
      await database.customStatement(
        'INSERT INTO values_fixture(text_value,int_value,real_value,blob_value,null_value) '
        'VALUES(?,?,?,?,?)',
        [
          'dart-health-0\u0000🎓',
          9223372036854775807,
          3.25,
          Uint8List.fromList(<int>[0, 1, 2, 127, 255]),
          null,
        ],
      );
      await const MethodChannel(phase8SqliteProofChannelName)
          .invokeMethod<void>('dartLockAcquired');
      await nativeContenderStarted.future;
      final healthStarted = DateTime.now().microsecondsSinceEpoch;
      await const SqliteIdentityHandshake().checkHealth(healthRegion);
      healthElapsedMs =
          (DateTime.now().microsecondsSinceEpoch - healthStarted) ~/ 1000;
    });

    final rows = await database
        .customSelect(
          'SELECT text_value,int_value,real_value,blob_value,null_value '
          'FROM values_fixture ORDER BY id',
        )
        .get();
    if (rows.isEmpty) throw StateError('Dart worker proof row missing');
    final dartRows = rows
        .where(
            (row) => row.read<String>('text_value') == 'dart-health-0\u0000🎓')
        .toList();
    if (dartRows.length != 1) {
      throw StateError('Dart worker typed row missing or duplicated');
    }
    final dartRow = dartRows.single;
    if (dartRow.read<int>('int_value') != 9223372036854775807 ||
        dartRow.read<double>('real_value') != 3.25 ||
        !listEquals(
          dartRow.read<Uint8List>('blob_value'),
          Uint8List.fromList(<int>[0, 1, 2, 127, 255]),
        ) ||
        dartRow.data['null_value'] != null) {
      throw StateError('Dart worker typed values mismatch');
    }
    return <String, Object?>{
      'ok': true,
      'dartRows': rows.length,
      'journalMode': journalMode,
      'heldBeginImmediate': false,
      'rollback': false,
      'healthChecked': true,
      'healthElapsedMs': healthElapsedMs,
      'dartExecutionLocation': 'root isolate',
      'driftExecutorLocation': 'DriftIsolate background worker',
      'driftDatabaseFactory': 'openStorageDatabaseInBackground',
      'driftStorageRegionId': factoryRegion.id,
      'driftDatabasePathScope': 'disposable debug cache',
      'driftTransactionWriter': true,
      'writerReservedByDriftTransaction': true,
    };
  } finally {
    await database.close();
  }
}
