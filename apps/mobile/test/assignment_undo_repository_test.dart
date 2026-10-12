import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  late local.AppDatabase db;
  late DriftScheduleRepository repository;
  late int idCounter;

  setUp(() {
    idCounter = 0;
    db = local.AppDatabase(NativeDatabase.memory());
    repository = DriftScheduleRepository(
      db,
      createId: () => 'undo-mutation-${idCounter++}',
    );
  });

  tearDown(() => db.close());

  test(
      'Undo restores the exact in-progress state and enqueues one guarded update',
      () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: 'owner',
      input: AssignmentInput(
        title: '進行中から戻す課題',
        dueAt: DateTime.utc(2026, 9, 20, 12),
      ),
    );
    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: 'owner',
      status: AssignmentStatus.inProgress,
      updatedAt: DateTime.utc(2026, 9, 18, 1),
    );

    final receipt = await repository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: 'owner',
      submittedAt: DateTime.utc(2026, 9, 18, 2),
    );
    expect(receipt.previousState?.status, AssignmentStatus.inProgress);
    expect(receipt.previousState?.version, 1);
    expect(receipt.resultingVersion, 2);

    await repository.undoAssignmentSubmission(
      receipt: receipt,
      updatedAt: DateTime.utc(2026, 9, 18, 3),
    );

    final state = await repository.assignmentStatesForUser('owner');
    expect(state[assignmentId]?.status, AssignmentStatus.inProgress);
    expect(state[assignmentId]?.version, 3);
    final pending = await repository.pendingMutations(ownerUserId: 'owner');
    final undoMutation = pending.last;
    expect(undoMutation.entityId, assignmentId);
    expect(undoMutation.operation, SyncOperation.update);
    expect(undoMutation.baseVersion, 2);
    expect(undoMutation.payload['status'], 'inProgress');
  });

  test('stale or wrong-owner receipts cannot overwrite a newer state',
      () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: 'owner',
      input: AssignmentInput(
        title: '古いUndoを拒否する課題',
        dueAt: DateTime.utc(2026, 9, 20, 12),
      ),
    );
    final receipt = await repository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: 'owner',
      submittedAt: DateTime.utc(2026, 9, 18, 2),
    );
    await repository.updateAssignmentState(
      assignmentId: assignmentId,
      userId: 'owner',
      status: AssignmentStatus.inProgress,
      updatedAt: DateTime.utc(2026, 9, 18, 4),
    );

    await expectLater(
      repository.undoAssignmentSubmission(
        receipt: receipt,
        updatedAt: DateTime.utc(2026, 9, 18, 5),
      ),
      throwsA(isA<ConflictError>()),
    );
    expect(
      (await repository.assignmentStatesForUser('owner'))[assignmentId]?.status,
      AssignmentStatus.inProgress,
    );

    final wrongOwner = AssignmentUndoReceipt(
      assignmentId: receipt.assignmentId,
      ownerUserId: 'another-owner',
      previousState: receipt.previousState,
      resultingVersion: receipt.resultingVersion,
    );
    await expectLater(
      repository.undoAssignmentSubmission(
        receipt: wrongOwner,
        updatedAt: DateTime.utc(2026, 9, 18, 6),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a tombstoned prior state is not resurrected by a new Undo receipt',
      () async {
    final assignmentId = await repository.createAssignment(
      ownerUserId: 'owner',
      input: AssignmentInput(
        title: '削除済み状態を復活させない課題',
        dueAt: DateTime.utc(2026, 9, 20, 12),
      ),
    );
    final initialReceipt = await repository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: 'owner',
      submittedAt: DateTime.utc(2026, 9, 18, 1),
    );
    await db
        .update(db.assignmentUserStates)
        .write(local.AssignmentUserStatesCompanion(
          deletedAt: Value(DateTime.utc(2026, 9, 18, 2)),
          version: const Value(9),
        ));

    final receipt = await repository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: 'owner',
      submittedAt: DateTime.utc(2026, 9, 18, 3),
    );
    expect(initialReceipt.resultingVersion, 1);
    expect(receipt.previousState, isNull);
    expect(receipt.resultingVersion, 10);

    await repository.undoAssignmentSubmission(
      receipt: receipt,
      updatedAt: DateTime.utc(2026, 9, 18, 4),
    );
    expect(
      (await repository.assignmentStatesForUser('owner'))[assignmentId]?.status,
      AssignmentStatus.notStarted,
    );
  });

  test('receipts distinguish two IDs and reject an older submitted version',
      () async {
    Future<String> create(String title) => repository.createAssignment(
          ownerUserId: 'owner',
          input: AssignmentInput(
            title: title,
            dueAt: DateTime.utc(2026, 9, 20, 12),
          ),
        );
    final first = await create('課題A');
    final second = await create('課題B');
    Future<AssignmentUndoReceipt> submit(String id) =>
        repository.submitAssignmentWithReceipt(
          assignmentId: id,
          userId: 'owner',
          submittedAt: DateTime.utc(2026, 9, 18, 2),
        );
    final firstReceipt = await submit(first);
    final secondReceipt = await submit(second);
    expect(firstReceipt.resultingVersion, secondReceipt.resultingVersion);
    await repository.undoAssignmentSubmission(
      receipt: firstReceipt,
      updatedAt: DateTime.utc(2026, 9, 18, 3),
    );
    final states = await repository.assignmentStatesForUser('owner');
    expect(states[first]?.status, AssignmentStatus.notStarted);
    expect(states[second]?.status, AssignmentStatus.submitted);

    final newerReceipt = await submit(second);
    final pendingBefore =
        await repository.pendingMutations(ownerUserId: 'owner');
    await expectLater(
      repository.undoAssignmentSubmission(
        receipt: secondReceipt,
        updatedAt: DateTime.utc(2026, 9, 18, 4),
      ),
      throwsA(isA<ConflictError>()),
    );
    final latest = (await repository.assignmentStatesForUser('owner'))[second]!;
    expect(latest.status, AssignmentStatus.submitted);
    expect(latest.version, newerReceipt.resultingVersion);
    expect(await repository.pendingMutations(ownerUserId: 'owner'),
        hasLength(pendingBefore.length));
  });

  test('restored state remains after SQLite is reopened', () async {
    final directory = await Directory.systemTemp.createTemp('schedule-undo-');
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}schedule.sqlite');
    var firstDb = local.AppDatabase(NativeDatabase(file));
    var firstRepository = DriftScheduleRepository(firstDb);
    final assignmentId = await firstRepository.createAssignment(
      ownerUserId: 'owner',
      input: AssignmentInput(
        title: '再起動後も戻る課題',
        dueAt: DateTime.utc(2026, 9, 20, 12),
      ),
    );
    final receipt = await firstRepository.submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: 'owner',
      submittedAt: DateTime.utc(2026, 9, 18, 2),
    );
    await firstRepository.undoAssignmentSubmission(
      receipt: receipt,
      updatedAt: DateTime.utc(2026, 9, 18, 3),
    );
    await firstDb.close();

    final reopenedDb = local.AppDatabase(NativeDatabase(file));
    addTearDown(() => reopenedDb.close());
    final reopenedRepository = DriftScheduleRepository(reopenedDb);
    final snapshot = await reopenedRepository.loadSnapshot(
      now: DateTime.utc(2026, 9, 18),
      ownerUserId: 'owner',
      universityId: 'university',
      termId: 'term',
      academicYear: 2026,
    );
    expect(snapshot.assignments.any((item) => item.id == assignmentId), isTrue);
    expect(snapshot.assignmentStates[assignmentId]?.status,
        AssignmentStatus.notStarted);
    expect(snapshot.calendarItems.any((item) => item.sourceId == assignmentId),
        isTrue);
  });
}
