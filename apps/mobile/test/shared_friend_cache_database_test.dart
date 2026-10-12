import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:university_schedule_mobile/features/friends/data/shared_friend_cache_database.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';

void main() {
  test('stale guarded snapshot is rolled back before it can be read', () async {
    final database =
        SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
    addTearDown(database.close);
    await database.initializeRegion('region-a');
    const partition = FriendCachePartition(
      viewerUserId: 'viewer',
      sourceOwnerUserId: 'friend',
      contextKey: 'context',
      regionId: 'region-a',
      ownerHash: 'owner-hash',
      activationToken: 'activation',
      generation: 7,
      accessMode: 'friend',
      effectiveViewerUserId: 'viewer',
    );

    final written = await database.replaceSnapshotIfCurrent(
      partition: partition,
      allowed: true,
      revision: 'revision-1',
      requestEpoch: 1,
      rows: const [],
      fetchedAtMs: 1,
      isCurrent: () => false,
    );

    expect(written, isFalse);
    expect(await database.rowsFor(partition.key), isEmpty);
  });

  test('a guard that expires during replacement leaves no partial snapshot',
      () async {
    final database =
        SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
    addTearDown(database.close);
    await database.initializeRegion('region-a');
    const partition = FriendCachePartition(
      viewerUserId: 'viewer',
      sourceOwnerUserId: 'friend',
      contextKey: 'context',
      regionId: 'region-a',
      ownerHash: 'owner-hash',
      activationToken: 'activation',
      generation: 7,
      accessMode: 'friend',
      effectiveViewerUserId: 'viewer',
    );
    var checks = 0;
    final written = await database.replaceSnapshotIfCurrent(
      partition: partition,
      allowed: true,
      revision: 'revision-1',
      requestEpoch: 1,
      rows: const [],
      fetchedAtMs: 1,
      isCurrent: () => ++checks < 3,
    );

    expect(written, isFalse);
    expect(await database.rowsFor(partition.key), isEmpty);
  });

  test('preview and friend scopes cannot share a cache partition', () {
    final friend = const FriendScheduleScope(
      viewerUserId: 'viewer',
      sourceOwnerUserId: 'owner',
      contextKey: 'context',
      regionId: 'region-a',
      ownerHash: 'owner-hash',
      activationToken: 'activation',
      generation: 7,
      accessMode: 'friend',
      effectiveViewerUserId: 'viewer',
    );
    final preview = const FriendScheduleScope(
      viewerUserId: 'viewer',
      sourceOwnerUserId: 'viewer',
      contextKey: 'context',
      regionId: 'region-a',
      ownerHash: 'owner-hash',
      activationToken: 'activation',
      generation: 7,
      accessMode: 'owner-preview',
      effectiveViewerUserId: 'owner',
    );

    expect(friend.partitionKey, isNot(preview.partitionKey));
  });

  test('replacement purges prior generations for one authorization audience',
      () async {
    final database =
        SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
    addTearDown(database.close);
    await database.initializeRegion('region-a');

    final oldContext = _partition(generation: 11, contextKey: 'old-context');
    final oldGeneration = _partition(generation: 20, contextKey: 'new-context');
    final current = _partition(generation: 28, contextKey: 'current-context');
    final unrelatedViewer = _partition(
      viewerUserId: 'other-viewer',
      effectiveViewerUserId: 'other-viewer',
      generation: 20,
    );
    final unrelatedOwner = _partition(
      sourceOwnerUserId: 'other-owner',
      generation: 20,
    );
    final preview = _partition(
      sourceOwnerUserId: 'viewer',
      accessMode: 'owner-preview',
      effectiveViewerUserId: 'owner',
      generation: 20,
    );

    await database.replaceSnapshot(
      partition: oldContext,
      allowed: true,
      revision: 'old-11',
      requestEpoch: 11,
      rows: [_row(oldContext, title: 'FULL old 11')],
      fetchedAtMs: 11,
    );
    await database.replaceSnapshot(
      partition: oldGeneration,
      allowed: true,
      revision: 'old-20',
      requestEpoch: 20,
      rows: [_row(oldGeneration, title: 'FULL old 20')],
      fetchedAtMs: 20,
    );
    for (final keep in [unrelatedViewer, unrelatedOwner, preview]) {
      await database.replaceSnapshot(
        partition: keep,
        allowed: true,
        revision: 'keep',
        requestEpoch: keep.generation,
        rows: [_row(keep, title: 'KEEP ${keep.accessMode}')],
        fetchedAtMs: keep.generation,
      );
    }

    await database.replaceSnapshot(
      partition: current,
      allowed: false,
      revision: 'title-only',
      requestEpoch: current.generation,
      rows: [_row(current, title: 'TITLE_ONLY', visibilityLevel: 'title_only')],
      fetchedAtMs: current.generation,
    );

    final rows = await database.select(database.sharedFriendCacheRows).get();
    final states =
        await database.select(database.sharedFriendCacheStates).get();
    expect(rows.map((row) => row.title), contains('TITLE_ONLY'));
    expect(rows.map((row) => row.title), isNot(contains('FULL old 11')));
    expect(rows.map((row) => row.title), isNot(contains('FULL old 20')));
    expect(rows.map((row) => row.title), contains('KEEP friend'));
    expect(rows.map((row) => row.title), contains('KEEP owner-preview'));
    expect(rows.map((row) => row.partitionKey), contains(unrelatedViewer.key));
    expect(rows.map((row) => row.partitionKey), contains(unrelatedOwner.key));
    expect(rows.map((row) => row.partitionKey), contains(preview.key));
    expect(states.map((state) => state.partitionKey), contains(current.key));
    expect(states.map((state) => state.partitionKey),
        isNot(contains(oldContext.key)));
    expect(states.map((state) => state.partitionKey),
        isNot(contains(oldGeneration.key)));
    expect(
      states.singleWhere((state) => state.partitionKey == current.key).allowed,
      isFalse,
    );
  });

  test('stale guarded replacement rolls back an audience purge', () async {
    final database =
        SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
    addTearDown(database.close);
    await database.initializeRegion('region-a');
    final old = _partition(generation: 11, contextKey: 'old-context');
    final current = _partition(generation: 28, contextKey: 'current-context');
    await database.replaceSnapshot(
      partition: old,
      allowed: true,
      revision: 'old',
      requestEpoch: old.generation,
      rows: [_row(old, title: 'FULL old')],
      fetchedAtMs: old.generation,
    );

    var checks = 0;
    final written = await database.replaceSnapshotIfCurrent(
      partition: current,
      allowed: false,
      revision: 'new',
      requestEpoch: current.generation,
      rows: [_row(current, title: 'TITLE_ONLY')],
      fetchedAtMs: current.generation,
      isCurrent: () => ++checks < 3,
    );

    expect(written, isFalse);
    expect((await database.rowsFor(old.key)).single.title, 'FULL old');
    expect(await database.rowsFor(current.key), isEmpty);
    final states =
        await database.select(database.sharedFriendCacheStates).get();
    expect(states.map((state) => state.partitionKey), contains(old.key));
    expect(states.map((state) => state.partitionKey),
        isNot(contains(current.key)));
  });
}

FriendCachePartition _partition({
  String viewerUserId = 'viewer',
  String sourceOwnerUserId = 'owner',
  String contextKey = 'context',
  String regionId = 'region-a',
  String ownerHash = 'owner-hash',
  String activationToken = 'activation',
  int generation = 28,
  String accessMode = 'friend',
  String effectiveViewerUserId = 'viewer',
}) =>
    FriendCachePartition(
      viewerUserId: viewerUserId,
      sourceOwnerUserId: sourceOwnerUserId,
      contextKey: contextKey,
      regionId: regionId,
      ownerHash: ownerHash,
      activationToken: activationToken,
      generation: generation,
      accessMode: accessMode,
      effectiveViewerUserId: effectiveViewerUserId,
    );

SharedFriendCacheRowsCompanion _row(
  FriendCachePartition partition, {
  required String title,
  String visibilityLevel = 'full',
}) =>
    SharedFriendCacheRowsCompanion.insert(
      cacheKey: '${partition.key}|event',
      partitionKey: partition.key,
      viewerUserId: partition.viewerUserId,
      sourceOwnerUserId: partition.sourceOwnerUserId,
      sourceType: 'event',
      sourceId: 'event-1',
      contextKey: partition.contextKey,
      regionId: partition.regionId,
      ownerHash: partition.ownerHash,
      activationToken: partition.activationToken,
      generation: partition.generation,
      accessMode: partition.accessMode,
      effectiveViewerUserId: partition.effectiveViewerUserId,
      requestEpoch: partition.generation,
      revision: 'revision-${partition.generation}',
      visibilityLevel: visibilityLevel,
      startAtMs: 1,
      endAtMs: 2,
      title: Value(title),
      fetchedAtMs: partition.generation,
    );
