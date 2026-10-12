import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:uuid/uuid.dart';

import '../../local_db/app_database.dart';
import '../../local_db/legacy_storage_receipt.dart';
import '../config/app_config.dart';
import '../config/storage_region.dart';
import '../native/sqlite_identity_handshake.dart';
import 'sqlite_storage_guard.dart';

typedef StoragePreparationHook = FutureOr<void> Function(String stage);

class StoragePreparationException implements Exception {
  const StoragePreparationException(this.reason);
  final String reason;
  @override
  String toString() => 'StoragePreparationException($reason)';
}

/// Keeps both failures visible when a canonical corruption is detected but
/// the durable native marker cannot be written.
final class StorageHealthLatchException extends StoragePreparationException {
  StorageHealthLatchException({
    required this.original,
    required this.originalStack,
    required this.latchError,
    required this.latchStack,
  }) : super('storage_health_latch_failed');

  final Object original;
  final StackTrace originalStack;
  final Object latchError;
  final StackTrace latchStack;

  @override
  String toString() =>
      'StorageHealthLatchException(original: $original, latch: $latchError)';
}

/// A canonical corruption that was successfully recorded in the native
/// durable latch. The stable preparation reason is retained for the startup
/// surface while the original SQLite/integrity failure remains inspectable.
final class CanonicalStorageCorruptionException
    extends StoragePreparationException {
  CanonicalStorageCorruptionException({
    required this.original,
    required this.originalStack,
  }) : super('storage_integrity_failed');

  final Object original;
  final StackTrace originalStack;
}

class PreparedStorage {
  const PreparedStorage(this.databasePath, {required this.importedLegacy});
  final String databasePath;
  final bool importedLegacy;
}

/// The only production entry point for a scoped database.
///
/// The original shared database is never opened with SQLite, changed or deleted.
/// All SQLite recovery happens on a private working copy. Publication is guarded
/// by both an isolate queue and an OS file lock, with immutable PREPARED and
/// COMMITTED records. This provides process-crash recovery, not a promise of
/// directory-entry durability under arbitrary power loss.
class StoragePreparation {
  const StoragePreparation({this.checkpoint});
  final StoragePreparationHook? checkpoint;
  static Future<void> _tail = Future<void>.value();
  static const policy = 'reviewed-local-demo-v1';
  // Legacy receipts describe the pre-Phase7 source database.  It must remain
  // schema 17 so an existing committed source can still be verified before
  // Drift opens a private copy and performs the additive v18 migration.
  static const _legacySourceSchemaVersion = 17;
  static const _currentStorageSchemaVersion = appDatabaseCurrentSchemaVersion;
  static const _legacyName = 'university_schedule.sqlite';
  static const _marker = 'local_storage_region_v1';
  static const _suffixes = {'db': '', 'wal': '-wal', 'journal': '-journal'};

  Future<PreparedStorage> prepare(Directory root, StorageRegion region) async {
    await const SqliteIdentityHandshake().verify();
    // Check the durable native latch before inspecting or opening the
    // canonical target. Scratch candidates and legacy sources are never
    // allowed to publish a region-wide corruption latch.
    await const SqliteIdentityHandshake().checkHealth(region.id);
    final prior = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await prior;
    RandomAccessFile? lock;
    var locked = false;
    try {
      await root.create(recursive: true);
      lock = await File(p.join(root.path, '.storage-preparation.lock'))
          .open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      locked = true;
      return await _prepareLocked(root, region);
    } on StoragePreparationException {
      rethrow;
    } on Object {
      // Do not disclose receipt contents, SQL rows or filesystem paths in UI.
      throw const StoragePreparationException('storage_preparation_failed');
    } finally {
      try {
        if (lock != null) {
          try {
            if (locked) await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        release.complete();
      }
    }
  }

  Future<void> _stage(String value) async => checkpoint?.call(value);

  Future<PreparedStorage> _prepareLocked(
    Directory root,
    StorageRegion region,
  ) async {
    final dir = Directory(p.join(root.path, 'spaces', region.id));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, 'app.sqlite'));
    final preparedFile = File(p.join(dir.path, 'prepared-v1.json'));
    final committedFile = File(p.join(dir.path, 'committed-v1.json'));
    if (await committedFile.exists()) {
      final manifest = await _readManifest(committedFile, region);
      _require(manifest['phase'] == 'COMMITTED', 'invalid_committed_manifest');
      _require(await target.exists(), 'committed_database_missing');
      await _verifyTarget(
        target,
        region,
        manifest['sourceReceiptSha256'] as String?,
        canonical: true,
      );
      return PreparedStorage(target.path,
          importedLegacy: manifest['importedLegacy'] == true);
    }
    if (await preparedFile.exists()) {
      final manifest = await _readManifest(preparedFile, region);
      _require(manifest['phase'] == 'PREPARED', 'invalid_prepared_manifest');
      if (manifest['importedLegacy'] == true) {
        _require(
            region.environment == AppEnvironment.local && region.mode == 'demo',
            'legacy_explicit_migration_required');
        final receiptFile =
            File(p.join(root.path, legacyStorageReceiptRelativePath));
        _require(
            await receiptFile.exists() &&
                await _hash(receiptFile) == manifest['sourceReceiptSha256'],
            'interrupted_receipt_mismatch');
        final receipt =
            LegacyStorageReceipt.decode(await receiptFile.readAsString());
        _require(
            receipt.targetRegionId == region.id &&
                receipt.policyVersion == policy &&
                receipt.sourceSchemaVersion == _legacySourceSchemaVersion,
            'legacy_receipt_scope_mismatch');
        await _verifySource(root, receipt);
      }
      if (await target.exists()) {
        // Only a byte-identical, marker-validated candidate may finish a rename
        // interrupted before COMMITTED. Bootstrap waits for preparation,
        // and both native canonical opens and the headless reader require a
        // COMMITTED manifest. No production handle can open this PREPARED-only
        // inode. Never hash a COMMITTED target: raw file close could release
        // another SQLite connection's POSIX locks.
        await _requireNoSidecars(target);
        _require(await _hash(target) == manifest['candidateSha256'],
            'interrupted_target_mismatch');
        await _verifyTarget(
          target,
          region,
          manifest['sourceReceiptSha256'] as String?,
          canonical: true,
        );
        await _commit(committedFile, manifest);
        return PreparedStorage(target.path,
            importedLegacy: manifest['importedLegacy'] == true);
      }
      final candidateName = manifest['candidateName'];
      _require(
          candidateName is String &&
              RegExp(r'^candidate-[a-f0-9-]{36}\.sqlite$')
                  .hasMatch(candidateName),
          'invalid_candidate_name');
      final candidate = File(p.join(dir.path, candidateName as String));
      _require(await candidate.exists(), 'prepared_candidate_missing');
      await _requireNoSidecars(candidate);
      _require(await _hash(candidate) == manifest['candidateSha256'],
          'prepared_candidate_mismatch');
      await _verifyTarget(
        candidate,
        region,
        manifest['sourceReceiptSha256'] as String?,
        canonical: false,
      );
      await _publish(candidate, target, committedFile, manifest);
      return PreparedStorage(target.path,
          importedLegacy: manifest['importedLegacy'] == true);
    }
    _require(!await target.exists(), 'unrecognized_existing_target');
    await _requireNoSidecars(target);
    final legacy = File(p.join(root.path, _legacyName));
    final legacyExists = await legacy.exists();
    final legacySidecars = await Future.wait(_suffixes.values
        .where((s) => s.isNotEmpty)
        .map((s) => File('${legacy.path}$s').exists()));
    _require(legacyExists || !legacySidecars.any((value) => value),
        'orphaned_legacy_sidecars');
    LegacyStorageReceipt? receipt;
    String? receiptHash;
    if (legacyExists) {
      _require(
          region.environment == AppEnvironment.local && region.mode == 'demo',
          'legacy_explicit_migration_required');
      final receiptFile =
          File(p.join(root.path, legacyStorageReceiptRelativePath));
      _require(
          await receiptFile.exists(), 'legacy_explicit_migration_required');
      final bytes = await receiptFile.readAsBytes();
      receipt = LegacyStorageReceipt.decode(utf8.decode(bytes));
      receiptHash = sha256.convert(bytes).toString();
      _require(
          receipt.policyVersion == policy &&
              receipt.sourceSchemaVersion == _legacySourceSchemaVersion &&
              receipt.targetRegionId == region.id &&
              receipt.approvedPurpose ==
                  LegacyStorageReceipt.approvedPurposeValue,
          'legacy_receipt_scope_mismatch');
      await _verifySource(root, receipt);
    }
    final candidate =
        File(p.join(dir.path, 'candidate-${const Uuid().v4()}.sqlite'));
    await _stage('before_copy');
    if (receipt != null) {
      final work = Directory(p.join(dir.path, 'work-${const Uuid().v4()}'));
      await work.create();
      for (final suffix in [..._suffixes.values, '-shm']) {
        final file = File('${legacy.path}$suffix');
        if (await file.exists()) {
          await file.copy(p.join(work.path, 'original.sqlite$suffix'));
        }
      }
      // Preserve SHM as evidence, but never trust a captured lock/index page.
      for (final suffix in _suffixes.values) {
        final file = File(p.join(work.path, 'original.sqlite$suffix'));
        if (await file.exists()) {
          await file.copy(p.join(work.path, 'working.sqlite$suffix'));
        }
      }
      await _verifySource(root, receipt);
      await _stage('after_copy');
      final source = sql.sqlite3.open(p.join(work.path, 'working.sqlite'));
      final destination = sql.sqlite3.open(candidate.path);
      try {
        await _validateLegacy(source);
        final originalRows = _logicalRows(source);
        await source.backup(destination, nPage: -1).drain<void>();
        _checkIntegrity(destination);
        _require(_logicalRows(destination) == originalRows,
            'snapshot_rows_mismatch');
        _writeMarker(destination, region, receiptHash);
        destination.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        destination.execute('PRAGMA journal_mode=DELETE');
      } finally {
        destination.close();
        source.close();
      }
      await _verifySource(root, receipt);
    } else {
      // Initialize the complete current schema before publishing an empty DB.
      final fresh = AppDatabase(NativeDatabase(candidate));
      try {
        await fresh.customSelect('SELECT 1').get();
      } finally {
        await fresh.close();
      }
      final destination = sql.sqlite3.open(candidate.path);
      try {
        _writeMarker(destination, region, null);
        destination.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        destination.execute('PRAGMA journal_mode=DELETE');
      } finally {
        destination.close();
      }
    }
    await _requireNoSidecars(candidate);
    await _verifyTarget(candidate, region, receiptHash, canonical: false);
    await _stage('after_verify');
    final candidateHandle = await candidate.open(mode: FileMode.append);
    await candidateHandle.flush();
    await candidateHandle.close();
    final manifest = <String, Object?>{
      'format': 'storage-publication-v1',
      'phase': 'PREPARED',
      'regionId': region.id,
      'candidateName': p.basename(candidate.path),
      'candidateSha256': await _hash(candidate),
      'sourceReceiptSha256': receiptHash,
      'importedLegacy': receipt != null,
      'sqliteVersion': sql.sqlite3.version.libVersion,
    };
    await _writeExclusive(preparedFile, manifest);
    await _stage('after_prepared');
    await _publish(candidate, target, committedFile, manifest);
    return PreparedStorage(target.path, importedLegacy: receipt != null);
  }

  Future<void> _publish(File candidate, File target, File committed,
      Map<String, Object?> manifest) async {
    // The same process/OS lock covers every check and rename. Dart rename can
    // replace an existing destination, so it is never used outside this lock.
    _require(!await target.exists(), 'target_already_exists');
    await _requireNoSidecars(target);
    await candidate.rename(target.path);
    await _stage('after_publish');
    await _commit(committed, manifest);
  }

  Future<void> _commit(File committed, Map<String, Object?> prepared) async {
    await _stage('before_commit');
    await _writeExclusive(committed, {...prepared, 'phase': 'COMMITTED'});
    await _stage('after_commit');
  }

  Future<void> _verifySource(
      Directory root, LegacyStorageReceipt receipt) async {
    _require(
        receipt.sourceFiles.keys.toSet().containsAll(_suffixes.keys) &&
            receipt.sourceFiles.length == _suffixes.length,
        'legacy_receipt_file_set');
    for (final entry in _suffixes.entries) {
      final approved = receipt.sourceFiles[entry.key]!;
      final expectedName = '$_legacyName${entry.value}';
      _require(approved.path == expectedName, 'legacy_receipt_path_mismatch');
      final file = File(p.join(root.path, expectedName));
      _require(await file.exists() == approved.present,
          'legacy_source_presence_mismatch');
      if (approved.present) {
        _require(await _hash(file) == approved.sha256,
            'legacy_source_hash_mismatch');
      }
    }
    _require(receipt.sourceFiles['db']!.present, 'legacy_database_missing');
  }

  Future<void> _validateLegacy(sql.Database database) async {
    _checkIntegrity(database);
    _require(
        database.select('PRAGMA user_version').single.values.single ==
            _legacySourceSchemaVersion,
        'legacy_schema_version_unsupported');
    final referenceRaw = sql.sqlite3.openInMemory();
    final reference = AppDatabase(NativeDatabase.opened(referenceRaw));
    try {
      await reference.customSelect('SELECT 1').get();
      final actualTables = _tableNames(database);
      // The in-memory reference is opened with the current schema.  Exclude
      // only Phase7's additive tables while validating the frozen v17 source;
      // every pre-existing table/column/trigger remains exact.
      final expectedTables = _tableNames(referenceRaw)
          .where((table) => !_phase7LocalNotificationTables.contains(table))
          .toList(growable: false);
      _require(jsonEncode(actualTables) == jsonEncode(expectedTables),
          'legacy_unknown_or_missing_table');
      for (final table in actualTables) {
        String columns(sql.Database db) => jsonEncode(db
            .select('PRAGMA table_info(${_quote(table)})')
            .map((r) => [r['name'], r['type'], r['notnull'], r['pk']])
            .toList()
          ..sort((a, b) => '${a[0]}'.compareTo('${b[0]}')));
        _require(columns(database) == columns(referenceRaw),
            'legacy_schema_mismatch');
      }
      String triggers(sql.Database db, {bool excludePhase7 = false}) =>
          jsonEncode(db
              .select(
                  "SELECT type, name, sql FROM sqlite_master WHERE type IN ('trigger','view') ORDER BY type,name")
              .where((r) =>
                  !excludePhase7 ||
                  !_phase7LocalNotificationTriggers.contains(r['name']))
              .map((r) => [
                    r['type'],
                    r['name'],
                    (r['sql'] as String).replaceAll(RegExp(r'\s+'), ' ').trim()
                  ])
              .toList());
      _require(
          triggers(database) == triggers(referenceRaw, excludePhase7: true),
          'legacy_trigger_mismatch');
    } finally {
      await reference.close();
    }
    const owners = {
      'terms': 'owner_user_id',
      'period_settings': 'owner_user_id',
      'user_courses': 'owner_user_id',
      'assignments': 'owner_user_id',
      'assignment_user_states': 'user_id',
      'exams': 'owner_user_id',
      'calendars': 'owner_user_id',
      'events': 'owner_user_id',
      'sync_queue_entries': 'owner_user_id',
      'local_notification_settings': 'owner_user_id',
      'local_notification_occurrences': 'owner_user_id',
      'local_notification_projection_states': 'owner_user_id',
    };
    const catalog = {
      'universities': {'demo-university'},
      'course_templates_cache': {'tmpl-algo-1', 'tmpl-english'},
    };
    for (final table in _tableNames(database)) {
      final rows = database.select('SELECT * FROM ${_quote(table)}');
      if (rows.isEmpty) continue;
      if (owners.containsKey(table)) {
        _require(rows.every((r) => r[owners[table]!] == 'demo-user'),
            'legacy_owner_mismatch');
        _require(
            rows.every(
                (r) => !r.keys.contains('group_id') || r['group_id'] == null),
            'legacy_group_data_ambiguous');
      } else if (catalog.containsKey(table)) {
        _require(rows.every((r) => catalog[table]!.contains(r['id'])),
            'legacy_catalog_ambiguous');
      } else {
        _require(
            (table == 'sync_queue_sequence_states' ||
                    table == 'local_notification_source_revisions') &&
                rows.length == 1,
            'legacy_nonempty_table_ambiguous');
      }
    }
    for (final row in database.select('SELECT * FROM sync_queue_entries')) {
      final payload = jsonDecode(row['payload_json'] as String);
      _require(payload is Map<String, dynamic>, 'legacy_queue_payload_invalid');
      final map = payload as Map<String, dynamic>;
      final identities =
          ['ownerUserId', 'userId'].where(map.containsKey).map((k) => map[k]);
      _require(
          identities.isNotEmpty && identities.every((v) => v == 'demo-user'),
          'legacy_queue_owner_mismatch');
      _require(row['server_payload_json'] == null,
          'legacy_server_payload_ambiguous');
    }
  }

  void _writeMarker(sql.Database db, StorageRegion region, String? receipt) {
    db.execute(
        'CREATE TABLE $_marker (singleton INTEGER PRIMARY KEY CHECK(singleton=1), region_id TEXT NOT NULL, receipt_sha256 TEXT)');
    db.execute('INSERT INTO $_marker VALUES (1, ?, ?)', [region.id, receipt]);
  }

  Future<void> _verifyTarget(
    File file,
    StorageRegion region,
    String? receipt, {
    required bool canonical,
  }) async {
    try {
      if (canonical) {
        await const SqliteIdentityHandshake().checkHealth(region.id);
      }
      final db = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
      try {
        if (canonical) {
          db.execute('PRAGMA busy_timeout = $sqliteBusyTimeoutMilliseconds');
        }
        _checkIntegrity(db);
        final rows = db.select('SELECT * FROM $_marker');
        _require(
            rows.length == 1 &&
                rows.single['singleton'] == 1 &&
                rows.single['region_id'] == region.id &&
                rows.single['receipt_sha256'] == receipt,
            'storage_marker_mismatch');
        _require(
            {
              _legacySourceSchemaVersion,
              _currentStorageSchemaVersion,
            }.contains(db.select('PRAGMA user_version').single.values.single),
            'storage_schema_version_unsupported');
      } finally {
        db.close();
      }
    } catch (error, stack) {
      if (!canonical || !_isCanonicalCorruption(error)) {
        Error.throwWithStackTrace(error, stack);
      }
      try {
        await const SqliteIdentityHandshake().recordCorruption(
          region.id,
          reason: _corruptionReason(error),
        );
      } catch (latchError, latchStack) {
        throw StorageHealthLatchException(
          original: error,
          originalStack: stack,
          latchError: latchError,
          latchStack: latchStack,
        );
      }
      throw CanonicalStorageCorruptionException(
        original: error,
        originalStack: stack,
      );
    }
  }

  bool _isCanonicalCorruption(Object error) {
    if (error is sql.SqliteException &&
        const {10, 11, 26}.contains(error.resultCode)) {
      return true;
    }
    return error is StoragePreparationException &&
        (error.reason == 'storage_integrity_failed' ||
            error.reason == 'storage_foreign_key_failed');
  }

  String _corruptionReason(Object error) {
    if (error is sql.SqliteException) {
      return 'sqlite_result_${error.resultCode}';
    }
    return 'integrity_check_failed';
  }

  static const _phase7LocalNotificationTables = {
    'local_notification_settings',
    'local_notification_occurrences',
    'local_notification_projection_states',
    'local_notification_source_revisions',
    'local_notification_permission_prompts',
  };

  static const _phase7LocalNotificationTriggers = {
    'local_notification_epoch_terms_insert',
    'local_notification_epoch_terms_update',
    'local_notification_epoch_terms_delete',
    'local_notification_epoch_period_settings_insert',
    'local_notification_epoch_period_settings_update',
    'local_notification_epoch_period_settings_delete',
    'local_notification_epoch_user_courses_insert',
    'local_notification_epoch_user_courses_update',
    'local_notification_epoch_user_courses_delete',
    'local_notification_epoch_assignments_insert',
    'local_notification_epoch_assignments_update',
    'local_notification_epoch_assignments_delete',
    'local_notification_epoch_assignment_user_states_insert',
    'local_notification_epoch_assignment_user_states_update',
    'local_notification_epoch_assignment_user_states_delete',
    'local_notification_epoch_exams_insert',
    'local_notification_epoch_exams_update',
    'local_notification_epoch_exams_delete',
    'local_notification_epoch_events_insert',
    'local_notification_epoch_events_update',
    'local_notification_epoch_events_delete',
    'local_notification_epoch_event_exceptions_insert',
    'local_notification_epoch_event_exceptions_update',
    'local_notification_epoch_event_exceptions_delete',
    'local_notification_epoch_notification_schedule_requests_insert',
    'local_notification_epoch_notification_schedule_requests_update',
    'local_notification_epoch_notification_schedule_requests_delete',
    'local_notification_epoch_local_notification_settings_insert',
    'local_notification_epoch_local_notification_settings_update',
    'local_notification_epoch_local_notification_settings_delete',
  };

  void _checkIntegrity(sql.Database db) {
    _require(
        db
                .select('PRAGMA integrity_check')
                .map((r) => r.values.single)
                .join() ==
            'ok',
        'storage_integrity_failed');
    _require(db.select('PRAGMA foreign_key_check').isEmpty,
        'storage_foreign_key_failed');
  }

  List<String> _tableNames(sql.Database db) => db
      .select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .map((r) => r['name'] as String)
      .toList();

  String _logicalRows(sql.Database db) => jsonEncode({
        for (final table in _tableNames(db))
          table: db
              .select('SELECT * FROM ${_quote(table)}')
              .map((row) => jsonEncode(row.values
                  .map((v) => v is Uint8List ? {'blob': base64Encode(v)} : v)
                  .toList()))
              .toList()
            ..sort(),
      });

  Future<Map<String, Object?>> _readManifest(
      File file, StorageRegion region) async {
    final value = jsonDecode(await file.readAsString());
    _require(value is Map<String, dynamic>, 'storage_manifest_invalid');
    final map = Map<String, Object?>.from(value as Map);
    _require(
        map['format'] == 'storage-publication-v1' &&
            map['regionId'] == region.id &&
            map['importedLegacy'] is bool &&
            map['candidateSha256'] is String &&
            RegExp(r'^[a-f0-9]{64}$')
                .hasMatch(map['candidateSha256'] as String) &&
            (map['sourceReceiptSha256'] == null ||
                (map['sourceReceiptSha256'] is String &&
                    RegExp(r'^[a-f0-9]{64}$')
                        .hasMatch(map['sourceReceiptSha256'] as String))),
        'storage_manifest_mismatch');
    _require(
        (map['importedLegacy'] == true) == (map['sourceReceiptSha256'] != null),
        'storage_manifest_provenance_mismatch');
    return map;
  }

  Future<void> _writeExclusive(File file, Map<String, Object?> value) async {
    _require(!await file.exists(), 'storage_manifest_already_exists');
    final pending = File('${file.path}.${const Uuid().v4()}.pending');
    await pending.writeAsString(jsonEncode(value), flush: true);
    _require(!await file.exists(), 'storage_manifest_already_exists');
    await pending.rename(file.path);
  }

  Future<void> _requireNoSidecars(File file) async {
    for (final suffix in ['-wal', '-journal', '-shm']) {
      _require(!await File('${file.path}$suffix').exists(),
          'unrecognized_target_sidecar');
    }
  }

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  String _quote(String name) => '"${name.replaceAll('"', '""')}"';
  void _require(bool condition, String reason) {
    if (!condition) throw StoragePreparationException(reason);
  }
}
