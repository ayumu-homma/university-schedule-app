import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';

import '../../local_db/app_database.dart';
import '../config/storage_region.dart';
import '../native/sqlite_identity_handshake.dart';
import 'sqlite_storage_guard.dart';

/// Opens the canonical database in the Drift worker that owns its SQLite
/// handle. Identity and durable region health are checked inside that worker,
/// immediately before the native database is constructed.
Future<AppDatabase> openStorageDatabaseInBackground({
  required File file,
  required StorageRegion region,
}) async {
  final rootIsolateToken = RootIsolateToken.instance;
  final databasePath = file.absolute.path;
  final regionId = region.id;
  final driftIsolate = await DriftIsolate.spawn(() {
    return LazyDatabase(() async {
      if (rootIsolateToken != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
      }
      await const SqliteIdentityHandshake().verify(force: true);
      await const SqliteIdentityHandshake().checkHealth(regionId);
      final executor = NativeDatabase(
        File(databasePath),
        setup: (database) {
          database
              .execute('PRAGMA busy_timeout = $sqliteBusyTimeoutMilliseconds');
        },
      );
      return executor.interceptWith(
        SqliteStorageGuard(regionId: regionId),
      );
    });
  });
  final connection = await driftIsolate.connect(singleClientMode: true);
  return AppDatabase(connection);
}
