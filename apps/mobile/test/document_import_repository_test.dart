import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/lifecycle/scoped_context_lease.dart';
import 'package:university_schedule_mobile/features/document_import/data/drift_document_import_repository.dart';
import 'package:university_schedule_mobile/features/document_import/domain/document_import_models.dart';
import 'package:university_schedule_mobile/features/document_import/data/document_import_gateway.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  group('document file boundary', () {
    test('accepts the four allowed signatures and rejects spoofed content', () {
      expect(_textFile().mediaType, DocumentMediaType.plainText);
      expect(
        DocumentSelectedFile.validate(
          extension: 'pdf',
          declaredSize: 6,
          bytes: Uint8List.fromList('%PDF-1'.codeUnits),
        ).mediaType,
        DocumentMediaType.pdf,
      );
      expect(
        DocumentSelectedFile.validate(
          extension: 'png',
          declaredSize: 8,
          bytes: Uint8List.fromList(
            const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
          ),
        ).mediaType,
        DocumentMediaType.png,
      );
      expect(
        DocumentSelectedFile.validate(
          extension: 'jpeg',
          declaredSize: 4,
          bytes: Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xd9]),
        ).mediaType,
        DocumentMediaType.jpeg,
      );
      expect(
        () => DocumentSelectedFile.validate(
          extension: 'pdf',
          declaredSize: 5,
          bytes: Uint8List.fromList('hello'.codeUnits),
        ),
        throwsA(
          isA<DocumentImportFailure>().having(
            (error) => error.category,
            'category',
            DocumentImportErrorCategory.spoofedMediaType,
          ),
        ),
      );
    });
  });

  test(
      'three candidates stay proposal-only, then exclusion edit and bulk confirm create two atomically',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedCourse(db, owner: 'owner-a');
    final repository = _repository(db, owner: () => 'owner-a');

    final batch = await repository.analyze(_textFile());
    expect(batch.candidates, hasLength(3));
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);

    final excluded = batch.candidates[1];
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: excluded.localId,
      edit: DocumentCandidateEdit(candidate: excluded.candidate),
      action: 'exclude',
    );
    final edited = batch.candidates.first;
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: edited.localId,
      edit: DocumentCandidateEdit(
        candidate: edited.candidate.copyWith(
          title: '編集済みアルゴリズムレポート',
          dueAt: DateTime.utc(2026, 8, 21, 14, 59),
        ),
        courseId: 'course-a',
      ),
    );
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);

    final review = await repository.loadSource(
      ownerUserId: 'owner-a',
      sourceId: batch.sourceId,
    );
    final selected =
        review.candidates.where((item) => item.canConfirm).toList();
    expect(selected, hasLength(2));
    final result = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: [
        for (final item in selected)
          DocumentConfirmationItem(
            candidateId: item.localId,
            courseId: item.courseId,
          ),
      ],
    );

    expect(result.confirmed, hasLength(2));
    expect(result.failed, isEmpty);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.exams).get(), hasLength(1));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(2));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(2));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));
    expect(
        (await db.select(db.assignments).get()).single.title, '編集済みアルゴリズムレポート');
    expect((await db.select(db.assignments).get()).single.courseId, 'course-a');

    final replay = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: [
        for (final item in selected)
          DocumentConfirmationItem(
            candidateId: item.localId,
            courseId: item.courseId,
          ),
      ],
    );
    expect(replay.confirmed, hasLength(2));
    expect(replay.confirmed, everyElement(isA<DocumentConfirmationSuccess>()));
    expect(replay.confirmed.every((item) => item.replayed), isTrue);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.exams).get(), hasLength(1));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(2));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(2));

    await repository.deleteSource(
      ownerUserId: 'owner-a',
      sourceId: batch.sourceId,
    );
    expect(await db.select(db.documentSourcesCache).get(), isEmpty);
    expect(await db.select(db.documentCandidatesCache).get(), isEmpty);
    expect(await db.select(db.documentScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.exams).get(), hasLength(1));

    final reimported = await repository.analyze(_textFile());
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: reimported.candidates[1].localId,
      edit: DocumentCandidateEdit(
        candidate: reimported.candidates[1].candidate,
      ),
      action: 'exclude',
    );
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: reimported.candidates[0].localId,
      edit: DocumentCandidateEdit(
        candidate: reimported.candidates[0].candidate.copyWith(
          title: '編集済みアルゴリズムレポート portfolioA',
        ),
      ),
    );
    final retainedNotificationsUpdated =
        await (db.update(db.notificationScheduleRequests)
              ..where((row) => row.sourceType.equals('document_confirmation')))
            .write(
      local.NotificationScheduleRequestsCompanion(
        state: const Value('scheduled'),
        updatedAt: Value(DateTime.utc(2026, 8, 10, 2)),
      ),
    );
    expect(retainedNotificationsUpdated, 2);
    final reimportReview = await repository.loadSource(
      ownerUserId: 'owner-a',
      sourceId: reimported.sourceId,
    );
    final reimportResult = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: [
        for (final item in reimportReview.candidates.where(
          (candidate) => candidate.canConfirm,
        ))
          DocumentConfirmationItem(
            candidateId: item.localId,
            courseId: item.courseId,
          ),
      ],
    );
    expect(reimportResult.confirmed, hasLength(2));
    expect(reimportResult.failed, isEmpty);
    expect(
      reimportResult.confirmed
          .singleWhere((item) => item.entityType == DocumentCandidateType.exam)
          .replayed,
      isTrue,
    );
    expect(await db.select(db.assignments).get(), hasLength(2));
    expect(await db.select(db.exams).get(), hasLength(1));
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(3),
    );
    expect(await db.select(db.syncQueueEntries).get(), hasLength(3));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));

    await repository.deleteSource(
      ownerUserId: 'owner-a',
      sourceId: reimported.sourceId,
    );
    final exactReplay = await repository.analyze(_textFile());
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: exactReplay.candidates[1].localId,
      edit:
          DocumentCandidateEdit(candidate: exactReplay.candidates[1].candidate),
      action: 'exclude',
    );
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: exactReplay.candidates[0].localId,
      edit: DocumentCandidateEdit(
        candidate: exactReplay.candidates[0].candidate.copyWith(
          title: '編集済みアルゴリズムレポート portfolioA',
        ),
      ),
    );
    final exactReplayReview = await repository.loadSource(
      ownerUserId: 'owner-a',
      sourceId: exactReplay.sourceId,
    );
    final exactReplayResult = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: [
        for (final item in exactReplayReview.candidates.where(
          (candidate) => candidate.canConfirm,
        ))
          DocumentConfirmationItem(
            candidateId: item.localId,
            courseId: item.courseId,
          ),
      ],
    );
    expect(exactReplayResult.confirmed, hasLength(2));
    expect(exactReplayResult.failed, isEmpty);
    expect(exactReplayResult.confirmed.every((item) => item.replayed), isTrue);
    expect(await db.select(db.assignments).get(), hasLength(2));
    expect(await db.select(db.exams).get(), hasLength(1));
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(3),
    );
    expect(await db.select(db.syncQueueEntries).get(), hasLength(3));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));
  });

  test('review cache survives restart offline and remains owner isolated',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'document-import-restart-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}cache.sqlite');
    var activeOwner = 'owner-a';
    var db = local.AppDatabase(NativeDatabase(file));
    var repository = _repository(db, owner: () => activeOwner);
    final batch = await repository.analyze(_textFile());
    await repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: batch.candidates[1].localId,
      edit: DocumentCandidateEdit(candidate: batch.candidates[1].candidate),
      action: 'exclude',
    );
    await db.close();

    db = local.AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    repository = _repository(db, owner: () => activeOwner);
    final restored = await repository.loadLatest('owner-a');
    expect(restored, isNotNull);
    expect(restored!.candidates, hasLength(3));
    expect(
      restored.candidates
          .where((item) =>
              item.reviewState == DocumentCandidateReviewState.excluded)
          .length,
      1,
    );

    activeOwner = 'owner-b';
    expect(await repository.loadLatest('owner-b'), isNull);
    await expectLater(
      repository.loadSource(ownerUserId: 'owner-b', sourceId: batch.sourceId),
      throwsA(isA<DocumentImportFailure>()),
    );
    await expectLater(
      db.into(db.documentCandidatesCache).insert(
            local.DocumentCandidatesCacheCompanion.insert(
              id: 'wrong-owner-candidate',
              ownerUserId: 'owner-b',
              sourceId: batch.sourceId,
              candidateKey: 'wrong-owner',
              schemaVersion: '1.0',
              candidateType: 'assignment',
              normalizedPayloadJson: '{}',
            ),
          ),
      throwsA(anything),
    );
  });

  test(
      'cancellation before cache transaction leaves no local or remote cleanup side effects',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _CancelledReplayResultGateway();
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final cancellation = DocumentImportCancellation();

    await expectLater(
      repository.analyze(_textFile(), cancellation: cancellation),
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.cancelled,
        ),
      ),
    );

    expect(gateway.deleteCalls, 0);
    expect(await db.select(db.documentSourcesCache).get(), isEmpty);
    expect(await db.select(db.documentCandidatesCache).get(), isEmpty);
  });

  test('cancelling a processed replay preserves its pre-existing local cache',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _CancelledReplayResultGateway()..cancelNext = false;
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final cached = await repository.analyze(_textFile());
    final cachedCandidateIds = cached.candidates
        .map((candidate) => candidate.localId)
        .toList(growable: false);
    gateway.cancelNext = true;
    final cancellation = DocumentImportCancellation();

    await expectLater(
      repository.analyze(_textFile(), cancellation: cancellation),
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.cancelled,
        ),
      ),
    );

    final preserved = await repository.loadSource(
      ownerUserId: 'owner-a',
      sourceId: cached.sourceId,
    );
    expect(
      preserved.candidates.map((candidate) => candidate.localId),
      orderedEquals(cachedCandidateIds),
    );
    expect(gateway.deleteCalls, 0);
    expect(await db.select(db.documentSourcesCache).get(), hasLength(1));
    expect(await db.select(db.documentCandidatesCache).get(), hasLength(3));
  });

  test(
      'delayed review acknowledgement advances version and drains the later candidate action',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _DelayedReviewGateway();
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final batch = await repository.analyze(_textFile());
    final candidate = batch.candidates.first;

    final deselect = repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
      edit: DocumentCandidateEdit(candidate: candidate.candidate),
      action: 'deselect',
    );
    await gateway.firstUpdateStarted.future;
    final exclude = repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
      edit: DocumentCandidateEdit(candidate: candidate.candidate),
      action: 'exclude',
    );
    await _waitUntil(() async {
      final row = await (db.select(db.documentCandidatesCache)
            ..where((item) => item.id.equals(candidate.localId)))
          .getSingle();
      return row.remoteSyncState == 'pending_exclude';
    });
    gateway.releaseFirstUpdate.complete();
    await Future.wait([deselect, exclude]);

    expect(
      gateway.updateCalls.map((call) => call.action),
      orderedEquals(const ['deselect', 'exclude']),
    );
    expect(
      gateway.updateCalls.map((call) => call.version),
      orderedEquals(const [1, 2]),
    );
    final persisted = await (db.select(db.documentCandidatesCache)
          ..where((item) => item.id.equals(candidate.localId)))
        .getSingle();
    expect(persisted.reviewState, 'excluded');
    expect(persisted.isSelected, isFalse);
    expect(persisted.remoteSyncState, 'synced');
    expect(persisted.remoteVersion, 3);
  });

  test('a review action arriving at sync completion cannot be stranded',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _DelayedReviewGateway();
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final batch = await repository.analyze(_textFile());
    final candidate = batch.candidates.first;
    var sawFirstPending = false;
    Future<DocumentCandidateReview>? completionBoundaryAction;
    final completionBoundaryActionStarted = Completer<void>();
    final subscription = (db.select(db.documentCandidatesCache)
          ..where((row) => row.id.equals(candidate.localId)))
        .watchSingle()
        .listen((row) {
      if (row.remoteSyncState == 'pending_deselect') {
        sawFirstPending = true;
      } else if (sawFirstPending &&
          row.remoteSyncState == 'synced' &&
          completionBoundaryAction == null) {
        completionBoundaryAction = repository.updateCandidate(
          ownerUserId: 'owner-a',
          candidateLocalId: candidate.localId,
          edit: DocumentCandidateEdit(candidate: candidate.candidate),
          action: 'exclude',
        );
        completionBoundaryActionStarted.complete();
      }
    });
    addTearDown(subscription.cancel);

    final first = repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
      edit: DocumentCandidateEdit(candidate: candidate.candidate),
      action: 'deselect',
    );
    await gateway.firstUpdateStarted.future;
    await _waitUntil(() async => sawFirstPending);
    gateway.releaseFirstUpdate.complete();
    await completionBoundaryActionStarted.future;
    await first;
    await completionBoundaryAction!;

    expect(
      gateway.updateCalls.map((call) => call.action),
      orderedEquals(const ['deselect', 'exclude']),
    );
    expect(
      gateway.updateCalls.map((call) => call.version),
      orderedEquals(const [1, 2]),
    );
    final persisted = await (db.select(db.documentCandidatesCache)
          ..where((row) => row.id.equals(candidate.localId)))
        .getSingle();
    expect(persisted.reviewState, 'excluded');
    expect(persisted.remoteSyncState, 'synced');
    expect(persisted.remoteVersion, 3);
  });

  test(
      'late owner acknowledgement stays pending until a fresh owner lease retries',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _DelayedReviewGateway();
    var authenticatedOwner = 'owner-a';
    final lease = ScopedContextLease(ownerUserId: 'owner-a', database: db);
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => authenticatedOwner,
      lease: lease,
    );
    final batch = await repository.analyze(_textFile());
    final candidate = batch.candidates.first;

    final deselect = repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
      edit: DocumentCandidateEdit(candidate: candidate.candidate),
      action: 'deselect',
    );
    await gateway.firstUpdateStarted.future;
    final exclude = repository.updateCandidate(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
      edit: DocumentCandidateEdit(candidate: candidate.candidate),
      action: 'exclude',
    );
    await _waitUntil(() async {
      final row = await (db.select(db.documentCandidatesCache)
            ..where((item) => item.id.equals(candidate.localId)))
          .getSingle();
      return row.remoteSyncState == 'pending_exclude';
    });

    authenticatedOwner = 'owner-b';
    lease.revoke();
    gateway.releaseFirstUpdate.complete();
    await expectLater(
      deselect,
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.configurationMissing,
        ),
      ),
    );
    await expectLater(
      exclude,
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.configurationMissing,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(gateway.updateCalls, hasLength(1));
    expect(gateway.updateCalls.single.action, 'deselect');
    expect(gateway.updateCalls.single.version, 1);
    final persisted = await (db.select(db.documentCandidatesCache)
          ..where((row) => row.id.equals(candidate.localId)))
        .getSingle();
    expect(persisted.reviewState, 'excluded');
    expect(persisted.isSelected, isFalse);
    expect(persisted.remoteSyncState, 'pending_exclude');
    expect(persisted.remoteVersion, 1);
    await expectLater(
      repository.loadLatest('owner-b'),
      throwsA(isA<DocumentImportFailure>()),
    );

    authenticatedOwner = 'owner-a';
    await expectLater(
      repository.reconcilePending('owner-a'),
      throwsA(isA<DocumentImportFailure>()),
    );
    final freshLease = ScopedContextLease(ownerUserId: 'owner-a', database: db);
    final freshRepository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => authenticatedOwner,
      lease: freshLease,
    );
    await freshRepository.reconcilePending('owner-a');
    expect(
      gateway.updateCalls.map((call) => call.action),
      orderedEquals(const ['deselect', 'exclude']),
    );
    expect(
      gateway.updateCalls.map((call) => call.version),
      orderedEquals(const [1, 1]),
    );
    final reconciled = await (db.select(db.documentCandidatesCache)
          ..where((row) => row.id.equals(candidate.localId)))
        .getSingle();
    expect(reconciled.reviewState, 'excluded');
    expect(reconciled.remoteSyncState, 'synced');
    expect(reconciled.remoteVersion, 2);
  });

  test(
      'late confirmation keeps candidate and derived queue artifacts unchanged',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _DelayedReviewGateway()..delayConfirmation = true;
    var authenticatedOwner = 'owner-a';
    final lease = ScopedContextLease(ownerUserId: 'owner-a', database: db);
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => authenticatedOwner,
      lease: lease,
    );
    final batch = await repository.analyze(_textFile());
    final candidate = batch.candidates.first;

    final confirmation = repository.confirm(
      ownerUserId: 'owner-a',
      candidateLocalId: candidate.localId,
    );
    await gateway.confirmationStarted.future;
    authenticatedOwner = 'owner-b';
    lease.revoke();
    gateway.releaseConfirmation.complete();

    await expectLater(
      confirmation,
      throwsA(
        isA<DocumentImportFailure>().having(
          (failure) => failure.category,
          'category',
          DocumentImportErrorCategory.configurationMissing,
        ),
      ),
    );
    final persisted = await (db.select(db.documentCandidatesCache)
          ..where((row) => row.id.equals(candidate.localId)))
        .getSingle();
    expect(persisted.reviewState, 'needs_review');
    expect(persisted.isSelected, isTrue);
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.select(db.exams).get(), isEmpty);
    expect(await db.select(db.events).get(), isEmpty);
    expect(await db.select(db.documentScheduleEntityLinks).get(), isEmpty);
    expect(await db.select(db.notificationScheduleRequests).get(), isEmpty);
    expect(await db.select(db.syncQueueEntries).get(), isEmpty);
  });

  test(
      'server semantic dedupe reuses exact owner entity notification and outbox while adding candidate provenance',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _ServerSemanticDedupeGateway();
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final batch = await repository.analyze(_textFile());
    expect(batch.candidates, hasLength(2));

    final first = await repository.confirm(
      ownerUserId: 'owner-a',
      candidateLocalId: batch.candidates[0].localId,
    );
    final second = await repository.confirm(
      ownerUserId: 'owner-a',
      candidateLocalId: batch.candidates[1].localId,
    );
    expect(second.entityId, first.entityId);
    expect(second.replayed, isTrue);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(1));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));

    final replay = await repository.confirm(
      ownerUserId: 'owner-a',
      candidateLocalId: batch.candidates[1].localId,
    );
    expect(replay.replayed, isTrue);
    expect(await db.select(db.assignments).get(), hasLength(1));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));
    expect(
        await db.select(db.notificationScheduleRequests).get(), hasLength(1));
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
  });

  test(
      'server replacement entity stays authoritative after a retained canonical edit or deletion',
      () async {
    for (final scenario in const ['edited', 'deleted']) {
      final db = local.AppDatabase(NativeDatabase.memory());
      try {
        final gateway = _RotatingReplacementGateway();
        final repository = DriftDocumentImportRepository(
          db: db,
          gateway: gateway,
          clock: () => DateTime.utc(2026, 8, 10, 1),
          authenticatedUserId: () => 'owner-a',
        );
        final firstBatch = await repository.analyze(_textFile());
        final first = await repository.confirm(
          ownerUserId: 'owner-a',
          candidateLocalId: firstBatch.candidates.single.localId,
        );
        await repository.deleteSource(
          ownerUserId: 'owner-a',
          sourceId: firstBatch.sourceId,
        );
        await (db.update(db.assignments)
              ..where((row) => row.id.equals(first.entityId)))
            .write(
          local.AssignmentsCompanion(
            title: scenario == 'edited'
                ? const Value('ユーザーが編集した保持課題')
                : const Value.absent(),
            deletedAt: scenario == 'deleted'
                ? Value(DateTime.utc(2026, 8, 10, 2))
                : const Value.absent(),
          ),
        );

        final replacementBatch = await repository.analyze(_textFile());
        final replacement = await repository.confirm(
          ownerUserId: 'owner-a',
          candidateLocalId: replacementBatch.candidates.single.localId,
        );

        expect(replacement.replayed, isFalse, reason: scenario);
        expect(replacement.entityId, _RotatingReplacementGateway.replacementId,
            reason: scenario);
        expect(gateway.requestedEntityIds, hasLength(2), reason: scenario);
        expect(
            gateway.requestedEntityIds[1], isNot(gateway.requestedEntityIds[0]),
            reason: 'source/candidate rotation must change p_entity_id');
        expect(replacement.entityId, isNot(gateway.requestedEntityIds[1]),
            reason: 'the returned server entity_id is authoritative');
        final assignments = await db.select(db.assignments).get();
        expect(assignments, hasLength(2), reason: scenario);
        final newEntity = assignments.singleWhere(
          (row) => row.id == _RotatingReplacementGateway.replacementId,
        );
        expect(newEntity.title, '差し替え対象課題');
        expect(newEntity.deletedAt, isNull);
        expect(
          await db.select(db.notificationScheduleRequests).get(),
          hasLength(2),
          reason: scenario,
        );
        expect(await db.select(db.syncQueueEntries).get(), hasLength(2),
            reason: scenario);
        expect(
          await db.select(db.documentScheduleEntityLinks).get(),
          hasLength(1),
          reason: scenario,
        );
      } finally {
        await db.close();
      }
    }
  });

  test(
      'bulk partial failure reports one and retry replays success while creating only the failed candidate',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final gateway = _FlakyConfirmationGateway();
    final repository = DriftDocumentImportRepository(
      db: db,
      gateway: gateway,
      clock: () => DateTime.utc(2026, 8, 10, 1),
      authenticatedUserId: () => 'owner-a',
    );
    final batch = await repository.analyze(_textFile());
    final attempted = batch.candidates.take(2).toList(growable: false);
    final items = [
      for (final candidate in attempted)
        DocumentConfirmationItem(candidateId: candidate.localId),
    ];

    final partial = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: items,
    );
    expect(partial.confirmed, hasLength(1));
    expect(partial.failed, hasLength(1));
    expect(
      partial.failed.single.errorCategory,
      DocumentImportErrorCategory.networkUnavailable,
    );
    expect(gateway.confirmationCalls, 2);
    expect(
      (await db.select(db.assignments).get()).length +
          (await db.select(db.exams).get()).length,
      1,
    );
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(1),
    );
    expect(await db.select(db.syncQueueEntries).get(), hasLength(1));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(1));

    final retry = await repository.confirmEach(
      ownerUserId: 'owner-a',
      items: items,
    );
    expect(retry.confirmed, hasLength(2));
    expect(retry.failed, isEmpty);
    expect(
      retry.confirmed
          .singleWhere(
            (success) =>
                success.candidateId == partial.confirmed.single.candidateId,
          )
          .replayed,
      isTrue,
    );
    expect(gateway.confirmationCalls, 3);
    expect(
      (await db.select(db.assignments).get()).length +
          (await db.select(db.exams).get()).length,
      2,
    );
    expect(
      await db.select(db.notificationScheduleRequests).get(),
      hasLength(2),
    );
    expect(await db.select(db.syncQueueEntries).get(), hasLength(2));
    expect(await db.select(db.documentScheduleEntityLinks).get(), hasLength(2));
  });
}

DriftDocumentImportRepository _repository(
  local.AppDatabase db, {
  required String? Function() owner,
}) {
  return DriftDocumentImportRepository(
    db: db,
    gateway: FakeDocumentImportGateway(ownerUserId: 'owner-a'),
    clock: () => DateTime.utc(2026, 8, 10, 1),
    authenticatedUserId: owner,
  );
}

DocumentSelectedFile _textFile() {
  final bytes = Uint8List.fromList(utf8.encode('合成授業資料 fixture'));
  return DocumentSelectedFile.validate(
    extension: 'txt',
    declaredSize: bytes.length,
    bytes: bytes,
  );
}

Future<void> _seedCourse(
  local.AppDatabase db, {
  required String owner,
}) {
  return db.into(db.userCourses).insert(
        local.UserCoursesCompanion.insert(
          id: 'course-a',
          ownerUserId: owner,
          termId: 'term-a',
          title: 'アルゴリズムとデータ構造Ⅰ',
          normalizedTitle: 'アルゴリズムとデータ構造i',
        ),
      );
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for document review synchronization.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _ReviewUpdateCall {
  const _ReviewUpdateCall({required this.action, required this.version});

  final String action;
  final int version;
}

class _CancelledReplayResultGateway implements DocumentImportGateway {
  int deleteCalls = 0;
  bool cancelNext = true;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    final replay = await FakeDocumentImportGateway(
      ownerUserId: 'owner-a',
    ).analyze(file, onState: onState);
    if (cancelNext) cancellation?.cancel();
    return DocumentAnalysisResult(
      batch: replay.batch,
      storagePath: 'owner-a/${replay.batch.sourceId}/source.txt',
      remoteCandidates: const {},
      remoteSourceVersion: 3,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {
    deleteCalls++;
  }

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async =>
      identity.version + 1;

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: entityId,
      replayed: true,
    );
  }
}

class _DelayedReviewGateway implements DocumentImportGateway {
  final firstUpdateStarted = Completer<void>();
  final releaseFirstUpdate = Completer<void>();
  final confirmationStarted = Completer<void>();
  final releaseConfirmation = Completer<void>();
  final updateCalls = <_ReviewUpdateCall>[];
  bool delayConfirmation = false;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    final local = await FakeDocumentImportGateway(
      ownerUserId: 'owner-a',
    ).analyze(
      file,
      onState: onState,
      cancellation: cancellation,
    );
    return DocumentAnalysisResult(
      batch: local.batch,
      storagePath: 'owner-a/${local.batch.sourceId}/source.txt',
      remoteCandidates: {
        for (final candidate in local.batch.candidates)
          candidate.candidateId: RemoteDocumentCandidateIdentity(
            id: 'remote-${candidate.candidateId}',
            version: 1,
          ),
      },
      remoteSourceVersion: 1,
    );
  }

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async {
    updateCalls.add(_ReviewUpdateCall(
      action: action,
      version: identity.version,
    ));
    if (updateCalls.length == 1) {
      firstUpdateStarted.complete();
      await releaseFirstUpdate.future;
    }
    return identity.version + 1;
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    if (delayConfirmation) {
      confirmationStarted.complete();
      await releaseConfirmation.future;
    }
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: entityId,
      replayed: false,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {}
}

class _ServerSemanticDedupeGateway implements DocumentImportGateway {
  String? _entityId;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    const sourceId = 'semantic-source';
    onState?.call(DocumentImportState.uploading);
    onState?.call(DocumentImportState.analyzing);
    final common = DocumentScheduleCandidate(
      candidateId: '$sourceId:assignment:1',
      type: DocumentCandidateType.assignment,
      title: '同一課題',
      courseHint: const DocumentCourseHint(name: '情報セキュリティ'),
      dueAt: DateTime.utc(2026, 8, 20, 14, 59),
      allDay: false,
      timezone: DocumentCandidateBatchCodec.timezone,
      confidence: const DocumentCandidateConfidence(
        overall: 0.9,
        course: 0.9,
        dateTime: 0.9,
      ),
      evidence: const [
        DocumentCandidateEvidence(pageNumber: 1, excerpt: '同一課題の根拠'),
      ],
      warnings: const [],
      requiresUserConfirmation: true,
    );
    final duplicate = DocumentScheduleCandidate(
      candidateId: '$sourceId:assignment:2',
      type: common.type,
      title: common.title,
      courseHint: common.courseHint,
      dueAt: common.dueAt,
      allDay: common.allDay,
      timezone: common.timezone,
      confidence: common.confidence,
      evidence: const [
        DocumentCandidateEvidence(pageNumber: 2, excerpt: '同一課題の再掲'),
      ],
      warnings: const [DocumentCandidateWarning.duplicateMention],
      requiresUserConfirmation: true,
    );
    return DocumentAnalysisResult(
      batch: ScheduleCandidateBatch(
        schemaVersion: DocumentCandidateBatchCodec.schemaVersion,
        sourceId: sourceId,
        contentHash: file.contentHash,
        timezone: DocumentCandidateBatchCodec.timezone,
        candidates: [common, duplicate],
      ),
      storagePath: 'owner-a/$sourceId/source.txt',
      remoteCandidates: const {
        '$sourceId:assignment:1':
            RemoteDocumentCandidateIdentity(id: 'remote-1', version: 1),
        '$sourceId:assignment:2':
            RemoteDocumentCandidateIdentity(id: 'remote-2', version: 1),
      },
      remoteSourceVersion: 1,
    );
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    final existing = _entityId;
    if (existing != null) {
      return DocumentRemoteConfirmation(
        entityType: candidate.type,
        entityId: existing,
        replayed: true,
      );
    }
    _entityId = entityId;
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: entityId,
      replayed: false,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {}

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async =>
      identity.version + 1;
}

class _FlakyConfirmationGateway implements DocumentImportGateway {
  int confirmationCalls = 0;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    final local = await FakeDocumentImportGateway(
      ownerUserId: 'owner-a',
    ).analyze(
      file,
      onState: onState,
      cancellation: cancellation,
    );
    return DocumentAnalysisResult(
      batch: local.batch,
      storagePath: 'owner-a/${local.batch.sourceId}/source.txt',
      remoteCandidates: {
        for (final candidate in local.batch.candidates)
          candidate.candidateId: RemoteDocumentCandidateIdentity(
            id: 'remote-${candidate.candidateId}',
            version: 1,
          ),
      },
      remoteSourceVersion: 1,
    );
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    confirmationCalls++;
    if (confirmationCalls == 2) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.networkUnavailable,
      );
    }
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: entityId,
      replayed: false,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {}

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async =>
      identity.version + 1;
}

class _RotatingReplacementGateway implements DocumentImportGateway {
  static const replacementId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  static const _sourceIds = [
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  ];

  final requestedEntityIds = <String>[];
  int _analysisCount = 0;

  @override
  bool get confirmsOnServer => true;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final sourceId = _sourceIds[_analysisCount++];
    final candidate = DocumentScheduleCandidate(
      candidateId: '$sourceId:assignment:1',
      type: DocumentCandidateType.assignment,
      title: '差し替え対象課題',
      courseHint: const DocumentCourseHint(name: '情報科学'),
      dueAt: DateTime.utc(2026, 8, 20, 14, 59),
      allDay: false,
      timezone: DocumentCandidateBatchCodec.timezone,
      confidence: const DocumentCandidateConfidence(
        overall: 0.9,
        course: 0.9,
        dateTime: 0.9,
      ),
      evidence: const [
        DocumentCandidateEvidence(pageNumber: 1, excerpt: '課題の提出期限'),
      ],
      warnings: const [],
      requiresUserConfirmation: true,
    );
    return DocumentAnalysisResult(
      batch: ScheduleCandidateBatch(
        schemaVersion: DocumentCandidateBatchCodec.schemaVersion,
        sourceId: sourceId,
        contentHash: file.contentHash,
        timezone: DocumentCandidateBatchCodec.timezone,
        candidates: [candidate],
      ),
      storagePath: 'owner-a/$sourceId/source.txt',
      remoteCandidates: {
        candidate.candidateId: RemoteDocumentCandidateIdentity(
          id: 'remote-${_analysisCount.toString()}',
          version: 1,
        ),
      },
      remoteSourceVersion: 1,
    );
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async {
    requestedEntityIds.add(entityId);
    return DocumentRemoteConfirmation(
      entityType: candidate.type,
      entityId: requestedEntityIds.length == 1 ? entityId : replacementId,
      replayed: false,
    );
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {}

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async =>
      identity.version + 1;
}
