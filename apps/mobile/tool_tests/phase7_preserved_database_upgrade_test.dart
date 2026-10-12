import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/storage/storage_preparation.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';

// Run only on the private, stopped/quiescent Phase7 backup. Never opens the
// emulator DB or auth preferences. This is separate from portable unit tests.
void main() {
  final snapshot = Platform.environment['PHASE7_UPGRADE_SNAPSHOT'];
  final manifests = Platform.environment['PHASE7_UPGRADE_MANIFEST_DIRECTORY'];
  test('captured committed schema17 upgrades retaining every original row',
      () async {
    final source = File(snapshot!);
    final beforeHash = _hash(source);
    final before = _rows(source);
    final original = sql.sqlite3.open(source.path, mode: sql.OpenMode.readOnly);
    expect(original.select('PRAGMA user_version').single.values.single, 17);
    original.close();
    final region = StorageRegion.fromConfig(AppConfig.validated(
      environment: 'local',
      demoMode: false,
      supabaseUrl: 'http://127.0.0.1:55321',
      supabasePublishableKey: 'synthetic-unused-no-network',
    ));
    final temporary = await Directory.systemTemp.createTemp('phase7-upgrade-');
    addTearDown(() async {
      expect(p.basename(temporary.path), startsWith('phase7-upgrade-'));
      await temporary.delete(recursive: true);
    });
    final targetDirectory =
        Directory(p.join(temporary.path, 'spaces', region.id));
    await targetDirectory.create(recursive: true);
    final target =
        await source.copy(p.join(targetDirectory.path, 'app.sqlite'));
    final manifestHashes = <String, String>{};
    for (final name in ['prepared-v1.json', 'committed-v1.json']) {
      final file = File(p.join(manifests!, name));
      manifestHashes[name] = _hash(file);
      await file.copy(p.join(targetDirectory.path, name));
    }
    final prepared =
        await const StoragePreparation().prepare(temporary, region);
    expect(prepared.databasePath, target.path);
    final db = AppDatabase(NativeDatabase(target));
    await db.customSelect('SELECT 1').get();
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        18);
    await db.close();
    final after = _rows(target);
    for (final table in before.keys) {
      expect(after[table], before[table],
          reason: 'Original table changed: $table');
    }
    expect(after.keys, contains('local_notification_occurrences'));
    final reopened =
        await const StoragePreparation().prepare(temporary, region);
    expect(reopened.databasePath, target.path);
    for (final name in manifestHashes.keys) {
      expect(_hash(File(p.join(targetDirectory.path, name))),
          manifestHashes[name]);
      expect(_hash(File(p.join(manifests!, name))), manifestHashes[name]);
    }
    expect(_hash(source), beforeHash);
  },
      skip: snapshot == null || manifests == null
          ? 'Requires the explicitly preserved local Phase7 backup; no server access'
          : false);
}

String _hash(File file) => sha256.convert(file.readAsBytesSync()).toString();

Map<String, List<String>> _rows(File file) {
  final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
  try {
    expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
    expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    final tables = db.select(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
    return {
      for (final row in tables)
        row['name'] as String: db
            .select(
                'SELECT * FROM "${(row['name'] as String).replaceAll('"', '""')}"')
            .map((row) => jsonEncode(row.values.toList()))
            .toList()
          ..sort(),
    };
  } finally {
    db.close();
  }
}
