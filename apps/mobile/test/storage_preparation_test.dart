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
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/demo_seed.dart';
import 'package:university_schedule_mobile/local_db/legacy_storage_receipt.dart';

StorageRegion demo() => StorageRegion.fromConfig(
    AppConfig.validated(environment: 'local', demoMode: true));

StorageRegion live(String env, String url,
        {String key = 'local-publishable-key'}) =>
    StorageRegion.fromConfig(AppConfig.validated(
        environment: env,
        demoMode: false,
        supabaseUrl: url,
        supabasePublishableKey: key));

Future<String> digest(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

Future<void> approve(Directory root, StorageRegion region) async {
  final files = <String, LegacyReceiptFile>{};
  for (final entry
      in {'db': '', 'wal': '-wal', 'journal': '-journal'}.entries) {
    final name = 'university_schedule.sqlite${entry.value}';
    final file = File(p.join(root.path, name));
    final present = await file.exists();
    files[entry.key] = LegacyReceiptFile(
        path: name,
        present: present,
        sha256: present ? await digest(file) : null);
  }
  final receipt = LegacyStorageReceipt(
      approvedPurpose: 'local-demo-adoption',
      policyVersion: StoragePreparation.policy,
      // The receipt describes the frozen pre-Phase7 source.  Preparation
      // verifies schema17 before Drift copies and upgrades it to v18.
      sourceSchemaVersion: 17,
      sourceFiles: files,
      targetRegionId: region.id,
      provenanceReference: 'synthetic-test-fixture; explicit local approval');
  final file = File(p.join(root.path, legacyStorageReceiptRelativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(receipt.toJson()));
}

Future<void> seedLegacy(Directory root) async {
  final db = AppDatabase(
      NativeDatabase(File(p.join(root.path, 'university_schedule.sqlite'))));
  await DriftDemoSeeder(db).seed();
  final queue = DriftSyncQueue(db, ownerUserId: 'demo-user');
  for (var i = 0; i < 35; i++) {
    await queue.enqueue(PendingMutation(
        clientMutationId: 'legacy-$i',
        ownerUserId: 'demo-user',
        entityType: 'assignment',
        entityId: 'assignment-report-1',
        operation: SyncOperation.update,
        payload: {
          'id': 'assignment-report-1',
          'ownerUserId': 'demo-user',
          'version': i + 1
        },
        createdAt: DateTime.utc(2026, 9, 18).add(Duration(seconds: i))));
  }
  // The fixture represents the committed pre-Phase7 source.  Build it with
  // the current typed schema for stable seed helpers, then remove only the
  // additive v18 notification objects and restore the source user_version.
  final phase7Triggers = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'local_notification_epoch_%'",
      )
      .get();
  for (final row in phase7Triggers) {
    await db
        .customStatement('DROP TRIGGER IF EXISTS ${row.read<String>('name')}');
  }
  for (final table in [
    'local_notification_occurrences',
    'local_notification_projection_states',
    'local_notification_settings',
    'local_notification_source_revisions',
    'local_notification_permission_prompts',
  ]) {
    await db.customStatement('DROP TABLE IF EXISTS $table');
  }
  await db.customStatement('PRAGMA user_version = 17');
  await db.close();
}

Future<int> count(AppDatabase db, String table) async =>
    (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
        .read<int>('n');

Matcher reason(String value) =>
    isA<StoragePreparationException>().having((e) => e.reason, 'reason', value);

void main() {
  late Directory root;
  setUp(() async => root =
      await Directory.systemTemp.createTemp('storage-preparation-test-'));
  tearDown(() async => root.delete(recursive: true));

  final currentDemoSnapshot = Platform.environment['PHASE5_DEMO_SNAPSHOT'];
  test(
      'captured current development demo is compatible without changing source',
      () async {
    final source = File(currentDemoSnapshot!);
    final before = await digest(source);
    await source.copy(p.join(root.path, 'university_schedule.sqlite'));
    await approve(root, demo());
    final prepared = await const StoragePreparation().prepare(root, demo());
    final db = AppDatabase(NativeDatabase(File(prepared.databasePath)));
    expect(await count(db, 'assignments'), 5);
    expect(await count(db, 'user_courses'), 3);
    expect(await count(db, 'sync_queue_entries'), 35);
    await db.close();
    expect(await digest(source), before);
  },
      skip: currentDemoSnapshot == null
          ? 'Optional local captured-demo evidence; synthetic cases run everywhere'
          : false);

  test(
      'real Drift reopen retains rows queue cursor; all distinct regions cannot read or send them',
      () async {
    final region = demo();
    final first = await const StoragePreparation().prepare(root, region);
    var db = AppDatabase(NativeDatabase(File(first.databasePath)));
    await DriftDemoSeeder(db).seed();
    await db.customStatement(
        "INSERT INTO assignments(id,owner_user_id,title,due_at) VALUES ('private-assignment','same-owner','private same-owner row',1789772400)");
    final queue = DriftSyncQueue(db, ownerUserId: 'same-owner');
    await queue.enqueue(PendingMutation(
        clientMutationId: 'same-owner-mutation',
        ownerUserId: 'same-owner',
        entityType: 'assignment',
        entityId: 'private-assignment',
        operation: SyncOperation.create,
        payload: const {'id': 'private-assignment'},
        createdAt: DateTime.utc(2026)));
    await db.customStatement(
        "INSERT INTO sync_cursors(owner_user_id,cursor) VALUES ('same-owner',42)");
    final assignmentCount = await count(db, 'assignments');
    await db.close();
    final reopened = await const StoragePreparation().prepare(root, region);
    expect(reopened.databasePath, first.databasePath);
    db = AppDatabase(NativeDatabase(File(reopened.databasePath)));
    expect(await count(db, 'assignments'), assignmentCount);
    expect(
        (await db
                .customSelect(
                    "SELECT title FROM assignments WHERE owner_user_id='same-owner'")
                .getSingle())
            .read<String>('title'),
        'private same-owner row');
    expect(
        (await DriftSyncQueue(db, ownerUserId: 'same-owner').all()).length, 1);
    expect(
        (await db.customSelect('SELECT cursor FROM sync_cursors').getSingle())
            .read<int>('cursor'),
        42);
    await db.close();
    final others = [
      live('local', 'http://127.0.0.1:54321'),
      live('test', 'http://127.0.0.1:54321'),
      live('local', 'http://127.0.0.1:54322'),
      live('local', 'http://localhost:54321'),
      StorageRegion.fromConfig(
          AppConfig.validated(environment: 'test', demoMode: true))
    ];
    for (final project in ['abcdefghijklmnopqrst', 'zyxwvutsrqponmlkjihg']) {
      others.add(StorageRegion.fromConfig(AppConfig.validated(
        environment: 'staging',
        demoMode: false,
        supabaseUrl: 'https://$project.supabase.co',
        supabasePublishableKey: 'sb_publishable_synthetic_test_only',
        stagingSupabaseProjectRef: project,
        deepLinkScheme: 'unischedule-staging',
        webBaseUrl: 'https://policy.example.edu',
        privacyPolicyUrl: 'https://policy.example.edu/privacy',
        termsUrl: 'https://policy.example.edu/terms',
        accountDeletionUrl: 'https://policy.example.edu/account-deletion',
        supportUrl: 'https://policy.example.edu/support',
      )));
    }
    for (final other in others) {
      final prepared = await const StoragePreparation().prepare(root, other);
      expect(prepared.databasePath, isNot(first.databasePath));
      final isolated = AppDatabase(NativeDatabase(File(prepared.databasePath)));
      expect(await count(isolated, 'assignments'), 0);
      expect(await count(isolated, 'sync_cursors'), 0);
      final gateway = FakeRemoteScheduleGateway();
      await SyncWorker(
              queue: DriftSyncQueue(isolated, ownerUserId: 'same-owner'),
              dispatcher: SyncMutationDispatcher(gateway))
          .processPending();
      expect(gateway.calls, isEmpty);
      await isolated.close();
    }
    expect(
        live('local', 'http://localhost:54321', key: 'rotated-publishable-key')
            .id,
        live('local', 'http://localhost:54321').id);
    expect(() => AppConfig.validated(environment: 'nonsense', demoMode: true),
        throwsA(isA<Exception>()));
  });

  test(
      'explicit receipt imports every row and all 35 queue entries once, preserving source',
      () async {
    await seedLegacy(root);
    final file = File(p.join(root.path, 'university_schedule.sqlite'));
    final original = await digest(file);
    await approve(root, demo());
    final first = await const StoragePreparation().prepare(root, demo());
    expect(first.importedLegacy, isTrue);
    var db = AppDatabase(NativeDatabase(File(first.databasePath)));
    expect(await count(db, 'sync_queue_entries'), 35);
    final url = await db
        .customSelect(
            "SELECT submission_url FROM assignments WHERE id='assignment-report-1'")
        .getSingle();
    expect(url.readNullable<String>('submission_url'), isNotNull);
    await db.customStatement(
        "UPDATE assignments SET description='normal post-import edit' WHERE id='assignment-report-1'");
    await db.close();
    final again = await const StoragePreparation().prepare(root, demo());
    db = AppDatabase(NativeDatabase(File(again.databasePath)));
    expect(await count(db, 'sync_queue_entries'), 35);
    expect(
        (await db
                .customSelect(
                    "SELECT description FROM assignments WHERE id='assignment-report-1'")
                .getSingle())
            .read<String>('description'),
        'normal post-import edit');
    await db.close();
    expect(await digest(file), original);
  });

  test(
      'WAL snapshot preserves committed WAL data and does not checkpoint original',
      () async {
    await seedLegacy(root);
    final file = File(p.join(root.path, 'university_schedule.sqlite'));
    final connection = sql.sqlite3.open(file.path);
    try {
      connection.execute('PRAGMA journal_mode=WAL');
      connection.execute('PRAGMA wal_autocheckpoint=0');
      connection.execute(
          "UPDATE assignments SET description='committed-in-wal' WHERE id='assignment-report-1'");
      final wal = File('${file.path}-wal');
      expect(await wal.length(), greaterThan(0));
      final beforeDb = await digest(file), beforeWal = await digest(wal);
      await approve(root, demo());
      final prepared = await const StoragePreparation().prepare(root, demo());
      expect(await digest(file), beforeDb);
      expect(await digest(wal), beforeWal);
      final migrated = AppDatabase(NativeDatabase(File(prepared.databasePath)));
      expect(
          (await migrated
                  .customSelect(
                      "SELECT description FROM assignments WHERE id='assignment-report-1'")
                  .getSingle())
              .read<String>('description'),
          'committed-in-wal');
      expect(await count(migrated, 'sync_queue_entries'), 35);
      await migrated.close();
    } finally {
      connection.close();
    }
  });

  for (final stage in [
    'before_copy',
    'after_copy',
    'after_verify',
    'after_prepared',
    'after_publish',
    'before_commit',
    'after_commit'
  ]) {
    test('crash at $stage retries without loss duplicate or target overwrite',
        () async {
      await seedLegacy(root);
      await approve(root, demo());
      final file = File(p.join(root.path, 'university_schedule.sqlite'));
      final before = await digest(file);
      await expectLater(
          StoragePreparation(checkpoint: (s) {
            if (s == stage) throw StateError('injected crash');
          }).prepare(root, demo()),
          throwsA(isA<StoragePreparationException>()));
      final result = await const StoragePreparation().prepare(root, demo());
      final db = AppDatabase(NativeDatabase(File(result.databasePath)));
      expect(await count(db, 'sync_queue_entries'), 35);
      await db.close();
      expect(await digest(file), before);
    });
  }

  test('concurrent preparations serialize and preserve one target', () async {
    await seedLegacy(root);
    await approve(root, demo());
    final results = await Future.wait(List.generate(
        4, (_) => const StoragePreparation().prepare(root, demo())));
    expect(results.map((r) => r.databasePath).toSet(), hasLength(1));
    final db = AppDatabase(NativeDatabase(File(results.first.databasePath)));
    expect(await count(db, 'sync_queue_entries'), 35);
    await db.close();
  });

  test('missing approval and live adoption fail closed without empty fallback',
      () async {
    await seedLegacy(root);
    await expectLater(const StoragePreparation().prepare(root, demo()),
        throwsA(reason('legacy_explicit_migration_required')));
    await approve(root, demo());
    await expectLater(
        const StoragePreparation()
            .prepare(root, live('local', 'http://localhost:54321')),
        throwsA(reason('legacy_explicit_migration_required')));
    expect(
        await File(p.join(root.path, 'spaces', demo().id, 'app.sqlite'))
            .exists(),
        isFalse);
  });

  for (final corruption in [
    'bad-hash',
    'missing-wal',
    'mixed-owner',
    'null-owner',
    'unknown-table',
    'queue-owner'
  ]) {
    test('rejects $corruption with original and target preserved', () async {
      await seedLegacy(root);
      final legacy = File(p.join(root.path, 'university_schedule.sqlite'));
      if (corruption == 'bad-hash' || corruption == 'missing-wal') {
        await approve(root, demo());
        if (corruption == 'bad-hash') {
          final raw = sql.sqlite3.open(legacy.path);
          raw.execute("UPDATE assignments SET description='unapproved change'");
          raw.close();
        } else {
          // Receipt claims a WAL that is not present.
          final file =
              File(p.join(root.path, legacyStorageReceiptRelativePath));
          final json =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          json['sourceFiles']['wal']['present'] = true;
          json['sourceFiles']['wal']['sha256'] = 'a' * 64;
          await file.writeAsString(jsonEncode(json));
        }
      } else {
        final raw = sql.sqlite3.open(legacy.path);
        switch (corruption) {
          case 'mixed-owner':
            raw.execute("UPDATE assignments SET owner_user_id='other-user'");
          case 'null-owner':
            raw.execute('UPDATE terms SET owner_user_id=NULL');
          case 'unknown-table':
            raw.execute('CREATE TABLE unknown_private_rows(id TEXT)');
          case 'queue-owner':
            raw.execute('UPDATE sync_queue_entries SET payload_json=?', [
              jsonEncode({'ownerUserId': 'other-user'})
            ]);
        }
        raw.close();
        await approve(root, demo());
      }
      final original = await digest(legacy);
      final expected = {
        'bad-hash': 'legacy_source_hash_mismatch',
        'missing-wal': 'legacy_source_presence_mismatch',
        'mixed-owner': 'legacy_owner_mismatch',
        'null-owner': 'legacy_owner_mismatch',
        'unknown-table': 'legacy_unknown_or_missing_table',
        'queue-owner': 'legacy_queue_owner_mismatch',
      }[corruption]!;
      await expectLater(const StoragePreparation().prepare(root, demo()),
          throwsA(reason(expected)));
      expect(await digest(legacy), original);
      expect(
          await File(p.join(root.path, 'spaces', demo().id, 'app.sqlite'))
              .exists(),
          isFalse);
    });
  }

  for (final changed in ['source', 'target']) {
    test(
        'interrupted publication rejects changed $changed without overwriting it',
        () async {
      await seedLegacy(root);
      await approve(root, demo());
      await expectLater(
          StoragePreparation(checkpoint: (stage) {
            if (stage == 'after_publish') throw StateError('crash');
          }).prepare(root, demo()),
          throwsA(isA<StoragePreparationException>()));
      final file = File(changed == 'source'
          ? p.join(root.path, 'university_schedule.sqlite')
          : p.join(root.path, 'spaces', demo().id, 'app.sqlite'));
      final db = sql.sqlite3.open(file.path);
      db.execute(
          "UPDATE assignments SET description='change after interrupted import'");
      db.close();
      final before = await digest(file);
      await expectLater(
          const StoragePreparation().prepare(root, demo()),
          throwsA(reason(changed == 'source'
              ? 'legacy_source_hash_mismatch'
              : 'interrupted_target_mismatch')));
      expect(await digest(file), before);
      expect(
          await File(
                  p.join(root.path, 'spaces', demo().id, 'committed-v1.json'))
              .exists(),
          isFalse);
    });
  }

  test('unrecognized existing target is not overwritten', () async {
    final dir = Directory(p.join(root.path, 'spaces', demo().id));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, 'app.sqlite'));
    await target.writeAsString('preexisting important file');
    final before = await digest(target);
    await expectLater(const StoragePreparation().prepare(root, demo()),
        throwsA(reason('unrecognized_existing_target')));
    expect(await digest(target), before);
  });
}
