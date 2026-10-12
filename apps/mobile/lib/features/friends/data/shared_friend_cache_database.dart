import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'shared_friend_cache_database.g.dart';

class SharedFriendCacheRows extends Table {
  TextColumn get cacheKey => text().named('cache_key')();
  TextColumn get partitionKey => text().named('partition_key')();
  TextColumn get viewerUserId => text().named('viewer_user_id')();
  TextColumn get sourceOwnerUserId => text().named('source_owner_user_id')();
  TextColumn get sourceType => text().named('source_type')();
  TextColumn get sourceId => text().named('source_id')();
  TextColumn get contextKey => text().named('context_key')();
  TextColumn get regionId => text().named('region_id')();
  TextColumn get ownerHash => text().named('owner_hash')();
  TextColumn get activationToken => text().named('activation_token')();
  IntColumn get generation => integer()();
  TextColumn get accessMode => text().named('access_mode')();
  TextColumn get effectiveViewerUserId =>
      text().named('effective_viewer_user_id')();
  IntColumn get requestEpoch => integer().named('request_epoch')();
  TextColumn get revision => text()();
  TextColumn get visibilityLevel => text().named('visibility_level')();
  IntColumn get startAtMs => integer().named('start_at_ms')();
  IntColumn get endAtMs => integer().named('end_at_ms')();
  TextColumn get title => text().nullable()();
  TextColumn get kind => text().nullable()();
  TextColumn get instructorName => text().named('instructor_name').nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get description => text().nullable()();
  IntColumn get fetchedAtMs => integer().named('fetched_at_ms')();

  @override
  Set<Column<Object>> get primaryKey => {cacheKey};
}

class SharedFriendCacheStates extends Table {
  TextColumn get partitionKey => text().named('partition_key')();
  TextColumn get viewerUserId => text().named('viewer_user_id')();
  TextColumn get sourceOwnerUserId => text().named('source_owner_user_id')();
  TextColumn get contextKey => text().named('context_key')();
  TextColumn get regionId => text().named('region_id')();
  TextColumn get ownerHash => text().named('owner_hash')();
  TextColumn get activationToken => text().named('activation_token')();
  IntColumn get generation => integer()();
  TextColumn get accessMode => text().named('access_mode')();
  TextColumn get effectiveViewerUserId =>
      text().named('effective_viewer_user_id')();
  IntColumn get requestEpoch => integer().named('request_epoch')();
  TextColumn get revision => text().nullable()();
  BoolColumn get allowed => boolean()();
  IntColumn get fetchedAtMs => integer().named('fetched_at_ms')();

  @override
  Set<Column<Object>> get primaryKey => {partitionKey};
}

@DriftDatabase(tables: [SharedFriendCacheRows, SharedFriendCacheStates])
class SharedFriendCacheDatabase extends _$SharedFriendCacheDatabase {
  SharedFriendCacheDatabase(String path)
      : super(NativeDatabase.createInBackground(File(path)));

  SharedFriendCacheDatabase.forExecutor(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'CREATE TABLE IF NOT EXISTS shared_friend_cache_region '
            '(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), '
            'region_id TEXT NOT NULL)',
          );
        },
      );

  Future<void> initializeRegion(String regionId) async {
    final existing = await customSelect(
      'SELECT region_id FROM shared_friend_cache_region WHERE singleton = 1',
    ).getSingleOrNull();
    if (existing != null && existing.read<String>('region_id') != regionId) {
      await transaction(() async {
        await delete(sharedFriendCacheRows).go();
        await delete(sharedFriendCacheStates).go();
        await customStatement('DELETE FROM shared_friend_cache_region');
        await customStatement(
          'INSERT INTO shared_friend_cache_region(singleton, region_id) '
          'VALUES (1, ?)',
          [regionId],
        );
      });
      return;
    }
    if (existing == null) {
      await customStatement(
        'INSERT INTO shared_friend_cache_region(singleton, region_id) '
        'VALUES (1, ?)',
        [regionId],
      );
    }
  }

  Future<void> replaceSnapshot({
    required FriendCachePartition partition,
    required bool allowed,
    required String revision,
    required int requestEpoch,
    required List<SharedFriendCacheRowsCompanion> rows,
    required int fetchedAtMs,
  }) async {
    await transaction(() async {
      await (delete(sharedFriendCacheRows)
            ..where((row) =>
                row.viewerUserId.equals(partition.viewerUserId) &
                row.sourceOwnerUserId.equals(partition.sourceOwnerUserId) &
                row.accessMode.equals(partition.accessMode) &
                row.effectiveViewerUserId
                    .equals(partition.effectiveViewerUserId)))
          .go();
      await (delete(sharedFriendCacheStates)
            ..where((state) =>
                state.viewerUserId.equals(partition.viewerUserId) &
                state.sourceOwnerUserId.equals(partition.sourceOwnerUserId) &
                state.accessMode.equals(partition.accessMode) &
                state.effectiveViewerUserId
                    .equals(partition.effectiveViewerUserId)))
          .go();
      await into(sharedFriendCacheStates).insertOnConflictUpdate(
        SharedFriendCacheStatesCompanion.insert(
          partitionKey: partition.key,
          viewerUserId: partition.viewerUserId,
          sourceOwnerUserId: partition.sourceOwnerUserId,
          contextKey: partition.contextKey,
          regionId: partition.regionId,
          ownerHash: partition.ownerHash,
          activationToken: partition.activationToken,
          generation: partition.generation,
          accessMode: partition.accessMode,
          effectiveViewerUserId: partition.effectiveViewerUserId,
          requestEpoch: requestEpoch,
          revision: Value(revision),
          allowed: allowed,
          fetchedAtMs: fetchedAtMs,
        ),
      );
      if (rows.isNotEmpty) {
        await batch((batch) => batch.insertAll(sharedFriendCacheRows, rows));
      }
    });
  }

  /// Replaces the complete partition only while [isCurrent] still identifies
  /// the active authenticated request.  The guard is checked between every
  /// awaited write so invalidation/account changes roll the transaction back
  /// before stale rows can become visible.
  Future<bool> replaceSnapshotIfCurrent({
    required FriendCachePartition partition,
    required bool allowed,
    required String revision,
    required int requestEpoch,
    required List<SharedFriendCacheRowsCompanion> rows,
    required int fetchedAtMs,
    required bool Function() isCurrent,
  }) async {
    try {
      await transaction(() async {
        if (!isCurrent()) throw const _StaleFriendSnapshot();
        await (delete(sharedFriendCacheRows)
              ..where((row) =>
                  row.viewerUserId.equals(partition.viewerUserId) &
                  row.sourceOwnerUserId.equals(partition.sourceOwnerUserId) &
                  row.accessMode.equals(partition.accessMode) &
                  row.effectiveViewerUserId
                      .equals(partition.effectiveViewerUserId)))
            .go();
        if (!isCurrent()) throw const _StaleFriendSnapshot();
        await (delete(sharedFriendCacheStates)
              ..where((state) =>
                  state.viewerUserId.equals(partition.viewerUserId) &
                  state.sourceOwnerUserId.equals(partition.sourceOwnerUserId) &
                  state.accessMode.equals(partition.accessMode) &
                  state.effectiveViewerUserId
                      .equals(partition.effectiveViewerUserId)))
            .go();
        if (!isCurrent()) throw const _StaleFriendSnapshot();
        await into(sharedFriendCacheStates).insertOnConflictUpdate(
          SharedFriendCacheStatesCompanion.insert(
            partitionKey: partition.key,
            viewerUserId: partition.viewerUserId,
            sourceOwnerUserId: partition.sourceOwnerUserId,
            contextKey: partition.contextKey,
            regionId: partition.regionId,
            ownerHash: partition.ownerHash,
            activationToken: partition.activationToken,
            generation: partition.generation,
            accessMode: partition.accessMode,
            effectiveViewerUserId: partition.effectiveViewerUserId,
            requestEpoch: requestEpoch,
            revision: Value(revision),
            allowed: allowed,
            fetchedAtMs: fetchedAtMs,
          ),
        );
        if (!isCurrent()) throw const _StaleFriendSnapshot();
        if (rows.isNotEmpty) {
          await batch((batch) => batch.insertAll(sharedFriendCacheRows, rows));
        }
        if (!isCurrent()) throw const _StaleFriendSnapshot();
      });
      return true;
    } on _StaleFriendSnapshot {
      return false;
    }
  }

  Future<List<SharedFriendCacheRow>> rowsFor(String partitionKey) {
    return (select(sharedFriendCacheRows)
          ..where((row) => row.partitionKey.equals(partitionKey))
          ..orderBy([(row) => OrderingTerm.asc(row.startAtMs)]))
        .get();
  }

  Future<void> clearPartition(String partitionKey) async {
    await transaction(() async {
      await (delete(sharedFriendCacheRows)
            ..where((row) => row.partitionKey.equals(partitionKey)))
          .go();
      await (delete(sharedFriendCacheStates)
            ..where((row) => row.partitionKey.equals(partitionKey)))
          .go();
    });
  }

  Future<void> clearViewer(String viewerUserId) async {
    await transaction(() async {
      await (delete(sharedFriendCacheRows)
            ..where((row) => row.viewerUserId.equals(viewerUserId)))
          .go();
      await (delete(sharedFriendCacheStates)
            ..where((row) => row.viewerUserId.equals(viewerUserId)))
          .go();
    });
  }
}

class _StaleFriendSnapshot implements Exception {
  const _StaleFriendSnapshot();
}

class FriendCachePartition {
  const FriendCachePartition({
    required this.viewerUserId,
    required this.sourceOwnerUserId,
    required this.contextKey,
    required this.regionId,
    required this.ownerHash,
    required this.activationToken,
    required this.generation,
    required this.accessMode,
    required this.effectiveViewerUserId,
  });

  final String viewerUserId;
  final String sourceOwnerUserId;
  final String contextKey;
  final String regionId;
  final String ownerHash;
  final String activationToken;
  final int generation;
  final String accessMode;
  final String effectiveViewerUserId;

  String get key => [
        viewerUserId,
        sourceOwnerUserId,
        contextKey,
        regionId,
        ownerHash,
        activationToken,
        generation,
        accessMode,
        effectiveViewerUserId,
      ].join('|');
}
