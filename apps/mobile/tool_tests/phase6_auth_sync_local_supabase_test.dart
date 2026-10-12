import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_coordinator.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:uuid/uuid.dart';

void main() {
  test(
    'real local Auth assignment lifecycle survives restart and A-B-A',
    () async {
      final previousMultipleDatabaseWarning =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases =
            previousMultipleDatabaseWarning;
      });

      final environment = _LocalSupabaseEnvironment.fromProcess();
      final sessionClient = _newClient(environment);
      final peerClient = _newClient(environment);
      final tenantClient = _newClient(environment);
      final temporaryDirectory =
          await Directory.systemTemp.createTemp('phase6-assignment-');
      final databaseFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}assignment.sqlite',
      );
      local.AppDatabase? database;
      local.AppDatabase? peerDatabase;
      _AssignmentHarness? harnessA;
      _AssignmentHarness? harnessB;
      _AssignmentHarness? peerHarness;
      SyncCoordinator? coordinatorA;
      SyncCoordinator? coordinatorB;
      SyncCoordinator? peerCoordinator;

      try {
        final identity = const Uuid().v4();
        final ownerEmail = 'phase6-owner-$identity@example.test';
        final tenantEmail = 'phase6-tenant-$identity@example.test';
        final password = 'Phase6-${const Uuid().v4()}-Aa1!';
        final ownerSignUp = await sessionClient.auth.signUp(
          email: ownerEmail,
          password: password,
        );
        final ownerUserId = ownerSignUp.user?.id;
        if (ownerUserId == null) {
          throw StateError('Owner Auth user was not created.');
        }
        expect(ownerSignUp.session, isNotNull);

        final tenantSignUp = await tenantClient.auth.signUp(
          email: tenantEmail,
          password: password,
        );
        final tenantUserId = tenantSignUp.user?.id;
        if (tenantUserId == null) {
          throw StateError('Tenant Auth user was not created.');
        }
        expect(tenantSignUp.session, isNotNull);

        final firstDatabase = local.AppDatabase(NativeDatabase(databaseFile));
        database = firstDatabase;
        harnessA = _AssignmentHarness(
          database: firstDatabase,
          client: sessionClient,
          ownerUserId: ownerUserId,
        );

        final currentJst = domain.JapanTime.civil(DateTime.now().toUtc());
        final tomorrowJst = DateTime.utc(
          currentJst.year,
          currentJst.month,
          currentJst.day,
        ).add(const Duration(days: 1));
        final initialDueAt = domain.JapanTime.at(
          year: tomorrowJst.year,
          month: tomorrowJst.month,
          day: tomorrowJst.day,
          hour: 10,
        );
        final editedDueAt = domain.JapanTime.at(
          year: tomorrowJst.year,
          month: tomorrowJst.month,
          day: tomorrowJst.day,
          hour: 11,
        );
        final submittedAt = domain.JapanTime.at(
          year: tomorrowJst.year,
          month: tomorrowJst.month,
          day: tomorrowJst.day,
          hour: 8,
        );
        final undoAt = submittedAt.add(const Duration(minutes: 1));
        final assignmentId = await harnessA.repository.createAssignment(
          ownerUserId: ownerUserId,
          input: AssignmentInput(
            title: 'Offline draft',
            dueAt: initialDueAt,
            memo: 'draft memo',
            submissionUrl: 'https://classroom.example.test/draft',
            priority: 'high',
          ),
        );
        final created = (await harnessA.repository.assignmentsForUser(
          ownerUserId,
        ))
            .singleWhere((item) => item.id == assignmentId);
        expect(created.version, 1);

        await harnessA.repository.updateAssignment(
          assignmentId: assignmentId,
          ownerUserId: ownerUserId,
          expectedVersion: created.version,
          input: AssignmentInput(
            title: 'Offline edited',
            dueAt: editedDueAt,
            memo: 'edited memo',
            submissionUrl: 'https://classroom.example.test/final',
            priority: 'urgent',
          ),
        );
        final edited = (await harnessA.repository.assignmentsForUser(
          ownerUserId,
        ))
            .singleWhere((item) => item.id == assignmentId);
        expect(edited.version, 2);

        final receipt = await harnessA.repository.submitAssignmentWithReceipt(
          assignmentId: assignmentId,
          userId: ownerUserId,
          submittedAt: submittedAt,
        );
        expect(receipt.resultingVersion, 1);
        final submitted = (await harnessA.repository.assignmentStatesForUser(
          ownerUserId,
        ))[assignmentId];
        expect(submitted?.status, domain.AssignmentStatus.submitted);
        expect(submitted?.submittedAt, isNotNull);

        await harnessA.repository.undoAssignmentSubmission(
          receipt: receipt,
          updatedAt: undoAt,
        );
        final undone = (await harnessA.repository.assignmentStatesForUser(
          ownerUserId,
        ))[assignmentId];
        expect(undone?.status, domain.AssignmentStatus.notStarted);
        expect(undone?.submittedAt, isNull);
        expect(undone?.version, 2);

        final pendingBeforeSwitch = await harnessA.queue.pending();
        expect(
          pendingBeforeSwitch
              .where((mutation) => mutation.entityId == assignmentId),
          hasLength(4),
        );
        expect(
          pendingBeforeSwitch.every(
            (mutation) => mutation.ownerUserId == ownerUserId,
          ),
          isTrue,
        );

        // Reopen the file before changing Auth. This proves the durable local
        // queue and the assignment receipt state survive a process boundary.
        harnessA = null;
        await firstDatabase.close();
        final reopenedDatabase =
            local.AppDatabase(NativeDatabase(databaseFile));
        database = reopenedDatabase;
        harnessA = _AssignmentHarness(
          database: reopenedDatabase,
          client: sessionClient,
          ownerUserId: ownerUserId,
        );
        expect(
          (await harnessA.queue.pending())
              .where((mutation) => mutation.entityId == assignmentId),
          hasLength(4),
        );
        final restoredAssignment =
            (await harnessA.repository.assignmentsForUser(
          ownerUserId,
        ))
                .singleWhere((item) => item.id == assignmentId);
        expect(restoredAssignment.title, 'Offline edited');
        expect(restoredAssignment.version, 2);
        final restoredState =
            (await harnessA.repository.assignmentStatesForUser(
          ownerUserId,
        ))[assignmentId];
        expect(restoredState?.status, domain.AssignmentStatus.notStarted);
        expect(restoredState?.version, 2);

        // Explicit A -> B -> A session switching must not drain or relabel A's
        // queue. The B coordinator uses the same file but a distinct owner.
        await sessionClient.auth.signOut(scope: SignOutScope.local);
        final tenantSession = await sessionClient.auth.signInWithPassword(
          email: tenantEmail,
          password: password,
        );
        expect(tenantSession.user?.id, tenantUserId);
        harnessB = _AssignmentHarness(
          database: database,
          client: sessionClient,
          ownerUserId: tenantUserId,
        );
        expect(await harnessB.repository.assignmentsForUser(tenantUserId),
            isEmpty);
        coordinatorB = harnessB.createCoordinator();
        final tenantRun = await coordinatorB.start();
        expect(tenantRun.push.synced, 0);
        expect(await harnessB.queue.all(), isEmpty);
        expect(
          (await harnessA.queue.pending())
              .where((mutation) => mutation.entityId == assignmentId),
          hasLength(4),
        );
        await expectLater(
          harnessB.gateway.pullDelta(ownerUserId: ownerUserId, afterCursor: 0),
          throwsA(isA<RemoteScheduleAuthenticationException>()),
        );

        await sessionClient.auth.signOut(scope: SignOutScope.local);
        final ownerSession = await sessionClient.auth.signInWithPassword(
          email: ownerEmail,
          password: password,
        );
        expect(ownerSession.user?.id, ownerUserId);

        // The real RPC returns an acknowledgement, then this controlled seam
        // drops it. The server must still contain one create change and the
        // local processing lease must remain recoverable.
        var dropped = false;
        final firstRun = harnessA.createCoordinator(
          afterRemoteAck: (mutation, _) async {
            if (!dropped &&
                mutation.entityId == assignmentId &&
                mutation.operation == SyncOperation.create) {
              dropped = true;
              throw const _DroppedRemoteAck();
            }
          },
        );
        coordinatorA = firstRun;
        await expectLater(
          firstRun.start(),
          throwsA(isA<_DroppedRemoteAck>()),
        );
        final processingCreate = (await harnessA.queue.all()).singleWhere(
          (mutation) =>
              mutation.entityId == assignmentId &&
              mutation.operation == SyncOperation.create,
        );
        expect(processingCreate.status, SyncMutationStatus.processing);

        final peerSession = await peerClient.auth.signInWithPassword(
          email: ownerEmail,
          password: password,
        );
        expect(peerSession.user?.id, ownerUserId);
        final peerGateway = SupabaseScheduleGateway(client: peerClient);
        final afterDroppedAck = await peerGateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final createChanges = afterDroppedAck.changes
            .where(
              (change) =>
                  change.entityType == 'assignment' &&
                  change.entityId == assignmentId,
            )
            .toList(growable: false);
        expect(createChanges, hasLength(1));
        expect(createChanges.single.payload['title'], 'Offline draft');
        expect(createChanges.single.serverVersion, 1);

        firstRun.dispose();
        coordinatorA = null;
        harnessA = null;
        await reopenedDatabase.close();
        final replayDatabase = local.AppDatabase(NativeDatabase(databaseFile));
        database = replayDatabase;
        final replayHarness = _AssignmentHarness(
          database: replayDatabase,
          client: sessionClient,
          ownerUserId: ownerUserId,
        );
        harnessA = replayHarness;
        final replayGateway = _RecordingGateway(replayHarness.gateway);
        final replayCoordinator = replayHarness.createCoordinator(
          gateway: replayGateway,
        );
        coordinatorA = replayCoordinator;
        final replayRun = await replayCoordinator.start();
        expect(replayRun.push.failed, 0);
        expect(replayRun.push.conflicts, 0);
        expect(replayRun.push.synced, 4);
        final replayedCreate = replayGateway.acknowledgements.singleWhere(
          (ack) =>
              ack.entityId == assignmentId &&
              ack.operation == SyncOperation.create,
        );
        expect(replayedCreate.replayed, isTrue);
        final finalQueue = await replayHarness.queue.all();
        expect(
          finalQueue
              .where((mutation) => mutation.entityId == assignmentId)
              .map((mutation) => mutation.status),
          everyElement(SyncMutationStatus.synced),
        );

        final finalAssignment =
            (await replayHarness.repository.assignmentsForUser(
          ownerUserId,
        ))
                .singleWhere((item) => item.id == assignmentId);
        expect(finalAssignment.title, 'Offline edited');
        expect(finalAssignment.dueAt.toUtc(), editedDueAt);
        expect(finalAssignment.description, 'edited memo');
        expect(finalAssignment.submissionUrl,
            'https://classroom.example.test/final');
        expect(finalAssignment.priority, 'urgent');
        expect(finalAssignment.version, 2);
        final finalState =
            (await replayHarness.repository.assignmentStatesForUser(
          ownerUserId,
        ))[assignmentId];
        expect(finalState?.status, domain.AssignmentStatus.notStarted);
        expect(finalState?.submittedAt, isNull);
        expect(finalState?.version, 2);

        final finalRemote = await peerGateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final assignmentRemote = finalRemote.changes
            .where(
              (change) =>
                  change.entityType == 'assignment' &&
                  change.entityId == assignmentId &&
                  change.operation == ScheduleDeltaOperation.upsert,
            )
            .toList(growable: false);
        expect(assignmentRemote, hasLength(2));
        final latestAssignment = assignmentRemote.last;
        expect(latestAssignment.payload['ownerUserId'], ownerUserId);
        expect(latestAssignment.payload['title'], 'Offline edited');
        expect(latestAssignment.payload['memo'], 'edited memo');
        expect(latestAssignment.payload['priority'], 'urgent');
        expect(latestAssignment.serverVersion, 2);
        final stateRemote = finalRemote.changes
            .where(
              (change) =>
                  change.entityType == 'assignment_user_state' &&
                  change.entityId == assignmentId,
            )
            .toList(growable: false);
        expect(stateRemote, hasLength(2));
        final latestState = stateRemote.last;
        expect(latestState.payload['userId'], ownerUserId);
        expect(latestState.payload['status'], 'notStarted');
        expect(latestState.payload['submittedAt'], isNull);
        expect(latestState.serverVersion, 2);

        await expectLater(
          tenantClient.rpc(
            'apply_schedule_mutation',
            params: {
              'p_idempotency_key': const Uuid().v4(),
              'p_entity_type': 'assignment',
              'p_entity_id': assignmentId,
              'p_operation': 'update',
              'p_base_version': 2,
              'p_payload': {
                'id': assignmentId,
                'ownerUserId': ownerUserId,
                'title': 'Unauthorized B write',
                'dueAt': editedDueAt.toUtc().toIso8601String(),
                'memo': 'must remain unchanged',
                'visibilityLevel': 'PRIVATE',
                'version': 3,
              },
            },
          ),
          throwsA(isA<PostgrestException>()),
        );
        final afterUnauthorizedWrite = await peerGateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final unchangedAssignment = afterUnauthorizedWrite.changes
            .where(
              (change) =>
                  change.entityType == 'assignment' &&
                  change.entityId == assignmentId &&
                  change.operation == ScheduleDeltaOperation.upsert,
            )
            .toList(growable: false)
            .last;
        expect(unchangedAssignment.payload['title'], 'Offline edited');
        expect(unchangedAssignment.serverVersion, 2);
        // Peer A starts from the authoritative baseline. A then advances the
        // server version while peer A submits an intentionally stale update.
        final peerDb = local.AppDatabase(NativeDatabase.memory());
        peerDatabase = peerDb;
        peerHarness = _AssignmentHarness(
          database: peerDb,
          client: peerClient,
          ownerUserId: ownerUserId,
        );
        peerCoordinator = peerHarness.createCoordinator();
        await peerCoordinator.start();
        final conflictId = await replayHarness.repository.createAssignment(
          ownerUserId: ownerUserId,
          input: AssignmentInput(
            title: 'Conflict baseline',
            dueAt: editedDueAt,
          ),
        );
        await replayCoordinator.synchronize(SyncTrigger.localMutation);
        await peerCoordinator.synchronize(SyncTrigger.manual);
        final authoritativeBefore =
            (await replayHarness.repository.assignmentsForUser(
          ownerUserId,
        ))
                .singleWhere((item) => item.id == conflictId);
        final stalePeer = (await peerHarness.repository.assignmentsForUser(
          ownerUserId,
        ))
            .singleWhere((item) => item.id == conflictId);
        expect(authoritativeBefore.version, 1);
        expect(stalePeer.version, authoritativeBefore.version);
        await replayHarness.repository.updateAssignment(
          assignmentId: conflictId,
          ownerUserId: ownerUserId,
          expectedVersion: authoritativeBefore.version,
          input: AssignmentInput(
            title: 'Authoritative owner edit',
            dueAt: editedDueAt,
          ),
        );
        await replayCoordinator.synchronize(SyncTrigger.localMutation);
        await peerHarness.repository.updateAssignment(
          assignmentId: conflictId,
          ownerUserId: ownerUserId,
          expectedVersion: stalePeer.version,
          input: AssignmentInput(
            title: 'Stale peer edit',
            dueAt: editedDueAt,
          ),
        );
        final conflictRun = await peerCoordinator.synchronize(
          SyncTrigger.localMutation,
        );
        expect(conflictRun.push.conflicts, 1);
        final durableConflict = (await peerHarness.queue.all()).singleWhere(
          (mutation) =>
              mutation.entityId == conflictId &&
              mutation.status == SyncMutationStatus.conflict,
        );
        expect(durableConflict.baseVersion, 1);
        expect(durableConflict.serverVersion, 2);
        expect(
            durableConflict.serverPayload['title'], 'Authoritative owner edit');

        final remoteConflict = await peerGateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final conflictChanges = remoteConflict.changes
            .where(
              (change) =>
                  change.entityType == 'assignment' &&
                  change.entityId == conflictId,
            )
            .toList(growable: false);
        expect(conflictChanges, hasLength(2));
        expect(
            conflictChanges.last.payload['title'], 'Authoritative owner edit');
        expect(conflictChanges.last.serverVersion, 2);
      } finally {
        coordinatorA?.dispose();
        coordinatorB?.dispose();
        peerCoordinator?.dispose();
        await peerDatabase?.close();
        await database?.close();
        await tenantClient.dispose();
        await peerClient.dispose();
        await sessionClient.dispose();
        await temporaryDirectory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

class _AssignmentHarness {
  _AssignmentHarness({
    required this.database,
    required SupabaseClient client,
    required this.ownerUserId,
  })  : gateway = SupabaseScheduleGateway(client: client),
        repository = DriftScheduleRepository(database),
        queue = DriftSyncQueue(database, ownerUserId: ownerUserId),
        store = DriftScheduleSyncStore(database, ownerUserId: ownerUserId);

  final local.AppDatabase database;
  final String ownerUserId;
  final SupabaseScheduleGateway gateway;
  final DriftScheduleRepository repository;
  final DriftSyncQueue queue;
  final DriftScheduleSyncStore store;

  SyncCoordinator createCoordinator({
    RemoteScheduleGateway? gateway,
    AfterRemoteMutationAck? afterRemoteAck,
  }) {
    final selectedGateway = gateway ?? this.gateway;
    return SyncCoordinator(
      ownerUserId: ownerUserId,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(selectedGateway),
        store: store,
        afterRemoteAck: afterRemoteAck,
      ),
      gateway: selectedGateway,
      store: store,
    );
  }
}

class _RecordingGateway implements RemoteScheduleGateway {
  _RecordingGateway(this.delegate);

  final RemoteScheduleGateway delegate;
  final List<ScheduleMutationAck> acknowledgements = [];

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    final acknowledgement = await delegate.applyMutation(mutation);
    acknowledgements.add(acknowledgement);
    return acknowledgement;
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) {
    return delegate.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: afterCursor,
      limit: limit,
    );
  }
}

class _DroppedRemoteAck implements Exception {
  const _DroppedRemoteAck();
}

class _LocalSupabaseEnvironment {
  const _LocalSupabaseEnvironment({
    required this.url,
    required this.publishableKey,
  });

  factory _LocalSupabaseEnvironment.fromProcess() {
    if (Platform.environment['UNIVERSITY_SCHEDULE_LOCAL_SYNC_TEST'] != '1') {
      throw StateError(
        'Set UNIVERSITY_SCHEDULE_LOCAL_SYNC_TEST=1 through the safe runner.',
      );
    }
    final rawUrl = Platform.environment['LOCAL_SUPABASE_URL']?.trim() ?? '';
    final publishableKey =
        Platform.environment['LOCAL_SUPABASE_PUBLISHABLE_KEY']?.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    final isLoopback = uri != null &&
        uri.hasAuthority &&
        uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
    if (!isLoopback) {
      throw StateError('The Phase 6 harness only accepts loopback HTTP.');
    }
    if (publishableKey.isEmpty) {
      throw StateError('A local public Supabase client key is required.');
    }
    return _LocalSupabaseEnvironment(
      url: rawUrl.replaceFirst(RegExp(r'/$'), ''),
      publishableKey: publishableKey,
    );
  }

  final String url;
  final String publishableKey;
}

SupabaseClient _newClient(_LocalSupabaseEnvironment environment) {
  return SupabaseClient(
    environment.url,
    environment.publishableKey,
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      authFlowType: AuthFlowType.implicit,
    ),
  );
}
