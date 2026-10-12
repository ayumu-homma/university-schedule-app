import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/sync/drift_schedule_sync_store.dart';
import 'package:university_schedule_mobile/core/sync/drift_sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/sync_coordinator.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/sync/sync_worker.dart';
import 'package:university_schedule_mobile/features/onboarding/data/drift_onboarding_local_store.dart';
import 'package:university_schedule_mobile/features/onboarding/data/supabase_onboarding_repository.dart';
import 'package:university_schedule_mobile/features/onboarding/domain/onboarding_models.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:uuid/uuid.dart';

const _kitUniversityId = '26a72fcd-6e61-5d0f-9c77-350762f2562f';
const _kitCampusId = '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74';
const _kitSpringTermTemplateId = '657f0bb3-7c10-510d-a8d2-133f0114a2f9';
const _kitPeriodTemplateSetId = '253ef732-d142-5abc-bb3a-17a12ff3820b';

void main() {
  test(
    'local Supabase converges two clients and survives idempotent restart',
    () async {
      final previousMultipleDatabaseWarning =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      // This acceptance test intentionally models independent devices with
      // separate executors. No QueryExecutor is shared between these DBs.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases =
            previousMultipleDatabaseWarning;
      });
      final environment = _LocalSupabaseEnvironment.fromProcess();
      final clientA = _newClient(environment);
      final clientB = _newClient(environment);
      final tenantClient = _newClient(environment);
      final databaseA = local.AppDatabase(NativeDatabase.memory());
      final databaseB = local.AppDatabase(NativeDatabase.memory());
      final temporaryDirectory =
          await Directory.systemTemp.createTemp('schedule-sync-supabase-');
      local.AppDatabase? restartDatabase;
      SyncCoordinator? coordinatorA;
      SyncCoordinator? coordinatorB;
      SyncCoordinator? restartCoordinator;

      try {
        final identity = const Uuid().v4();
        final email = 'schedule-sync-$identity@example.test';
        final password = 'Local-${const Uuid().v4()}-Aa1!';
        final signUp = await clientA.auth.signUp(
          email: email,
          password: password,
        );
        final ownerUserId = signUp.user?.id;
        if (ownerUserId == null || signUp.session == null) {
          throw StateError(
            'Local Supabase must allow immediate email/password sessions.',
          );
        }
        final secondSession = await clientB.auth.signInWithPassword(
          email: email,
          password: password,
        );
        if (secondSession.user?.id != ownerUserId ||
            secondSession.session == null) {
          throw StateError('The second local client did not restore the user.');
        }
        final tenantIdentity = const Uuid().v4();
        final tenantEmail = 'schedule-sync-$tenantIdentity@example.test';
        final tenantPassword = 'Local-${const Uuid().v4()}-Aa1!';
        final tenantSignUp = await tenantClient.auth.signUp(
          email: tenantEmail,
          password: tenantPassword,
        );
        final tenantUserId = tenantSignUp.user?.id;
        if (tenantUserId == null || tenantSignUp.session == null) {
          throw StateError('The tenant-isolation session was not created.');
        }

        final profileA = await SupabaseOnboardingRepository(
          clientA,
          localStore: DriftOnboardingLocalStore(databaseA),
        ).completeOnboarding(
          userId: ownerUserId,
          completion: OnboardingCompletion(
            idempotencyKey: const Uuid().v4(),
            userType: OnboardingUserType.undergraduate,
            universityId: _kitUniversityId,
            campusId: _kitCampusId,
            entryAcademicYear: 2026,
            termTemplateId: _kitSpringTermTemplateId,
            periodTemplateSetId: _kitPeriodTemplateSetId,
          ),
        );
        final profileB = await SupabaseOnboardingRepository(
          clientB,
          localStore: DriftOnboardingLocalStore(databaseB),
        ).loadProfile(ownerUserId);
        final termId = profileA.activeTerm?.id;
        if (termId == null || profileB.activeTerm?.id != termId) {
          throw StateError('The local clients did not hydrate the same term.');
        }

        final harnessA = _SyncHarness(
          database: databaseA,
          client: clientA,
          ownerUserId: ownerUserId,
        );
        final harnessB = _SyncHarness(
          database: databaseB,
          client: clientB,
          ownerUserId: ownerUserId,
        );
        coordinatorA = harnessA.coordinator;
        coordinatorB = harnessB.coordinator;

        // Connectivity, foreground, and realtime wake-ups share one in-flight
        // operation even against the real transport.
        final connectivityRun = coordinatorA.synchronize(
          SyncTrigger.connectivity,
        );
        final realtimeRun = coordinatorA.synchronize(SyncTrigger.realtime);
        expect(identical(connectivityRun, realtimeRun), isTrue);
        await connectivityRun;

        // Duplicate delivery must replay the original acknowledgement without
        // creating a second row or advancing the remote change cursor.
        final duplicateCourseId = await harnessA.repository.createUserCourse(
          ownerUserId: ownerUserId,
          termId: termId,
          input: const UserCourseInput(
            title: 'Idempotent Systems',
            dayOfWeek: 1,
            periodNo: 1,
            room: 'A-101',
          ),
        );
        final duplicateMutation = (await harnessA.queue.pending()).singleWhere(
          (mutation) => mutation.entityId == duplicateCourseId,
        );
        final firstAck = await harnessA.gateway.applyMutation(
          duplicateMutation,
        );
        final replayAck = await harnessA.gateway.applyMutation(
          duplicateMutation,
        );
        expect(firstAck.replayed, isFalse);
        expect(replayAck.replayed, isTrue);
        expect(replayAck.serverVersion, firstAck.serverVersion);
        expect(replayAck.changeCursor, firstAck.changeCursor);
        expect(replayAck.change.payload, firstAck.change.payload);

        // The worker delivers the still-pending mutation once more; it must
        // consume the replay acknowledgement and converge the second client.
        final duplicateRun = await coordinatorA.synchronize(
          SyncTrigger.localMutation,
        );
        expect(duplicateRun.push.synced, 1);
        await coordinatorB.synchronize(SyncTrigger.manual);
        expect(
          (await harnessB.repository.coursesForTerm(
            ownerUserId: ownerUserId,
            termId: termId,
          ))
              .singleWhere((course) => course.id == duplicateCourseId)
              .title,
          'Idempotent Systems',
        );

        // Client B updates the shared row; client A must pull the same version
        // and canonical payload.
        final onClientB = (await harnessB.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        ))
            .singleWhere((course) => course.id == duplicateCourseId);
        await harnessB.repository.updateUserCourse(
          courseId: duplicateCourseId,
          ownerUserId: ownerUserId,
          expectedVersion: onClientB.version,
          input: const UserCourseInput(
            title: 'Distributed Systems',
            dayOfWeek: 2,
            periodNo: 2,
            room: 'B-202',
          ),
        );
        expect(
          (await coordinatorB.synchronize(SyncTrigger.localMutation))
              .push
              .synced,
          1,
        );
        await coordinatorA.synchronize(SyncTrigger.manual);
        final convergedA = (await harnessA.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        ))
            .singleWhere((course) => course.id == duplicateCourseId);
        final convergedB = (await harnessB.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        ))
            .singleWhere((course) => course.id == duplicateCourseId);
        expect(convergedA.title, 'Distributed Systems');
        expect(convergedB.title, convergedA.title);
        expect(convergedB.version, convergedA.version);

        final firstCursorPage = await harnessA.gateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 1,
        );
        expect(firstCursorPage.changes, hasLength(1));
        expect(firstCursorPage.hasMore, isTrue);
        final secondCursorPage = await harnessA.gateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: firstCursorPage.nextCursor,
          limit: 1,
        );
        expect(secondCursorPage.changes, hasLength(1));
        expect(
          secondCursorPage.nextCursor,
          greaterThan(firstCursorPage.nextCursor),
        );

        // A delete is a versioned tombstone, not a client-side hard delete.
        await harnessA.repository.deleteUserCourse(
          courseId: duplicateCourseId,
          ownerUserId: ownerUserId,
          expectedVersion: convergedA.version,
        );
        expect(
          (await coordinatorA.synchronize(SyncTrigger.localMutation))
              .push
              .synced,
          1,
        );
        await coordinatorB.synchronize(SyncTrigger.manual);
        final visibleAfterDelete = await harnessB.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        );
        expect(
          visibleAfterDelete.where(
            (course) => course.id == duplicateCourseId,
          ),
          isEmpty,
        );
        final localTombstone = await (databaseB.select(databaseB.userCourses)
              ..where((row) => row.id.equals(duplicateCourseId)))
            .getSingle();
        expect(localTombstone.deletedAt, isNotNull);
        final deleteDelta = await harnessA.gateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final remoteTombstone = deleteDelta.changes
            .where((change) => change.entityId == duplicateCourseId)
            .last;
        expect(remoteTombstone.operation, ScheduleDeltaOperation.delete);
        expect(remoteTombstone.deletedAt, isNotNull);
        expect(remoteTombstone.serverVersion, localTombstone.version);

        // Both clients edit version 1. A wins version 2; B's stale base version
        // must become a durable conflict and must not overwrite the server.
        final conflictCourseId = await harnessA.repository.createUserCourse(
          ownerUserId: ownerUserId,
          termId: termId,
          input: const UserCourseInput(
            title: 'Conflict Baseline',
            dayOfWeek: 3,
            periodNo: 3,
          ),
        );
        await coordinatorA.synchronize(SyncTrigger.localMutation);
        await coordinatorB.synchronize(SyncTrigger.manual);
        final staleClientB = (await harnessB.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        ))
            .singleWhere((course) => course.id == conflictCourseId);
        final currentClientA = (await harnessA.repository.coursesForTerm(
          ownerUserId: ownerUserId,
          termId: termId,
        ))
            .singleWhere((course) => course.id == conflictCourseId);
        expect(staleClientB.version, currentClientA.version);

        await harnessA.repository.updateUserCourse(
          courseId: conflictCourseId,
          ownerUserId: ownerUserId,
          expectedVersion: currentClientA.version,
          input: const UserCourseInput(
            title: 'Authoritative A',
            dayOfWeek: 3,
            periodNo: 3,
          ),
        );
        await coordinatorA.synchronize(SyncTrigger.localMutation);
        final beforeStaleConflict = await harnessA.gateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final beforeStaleConflictChanges = beforeStaleConflict.changes
            .where((change) => change.entityId == conflictCourseId)
            .toList();
        final authoritativeCursor =
            beforeStaleConflictChanges.last.changeCursor;
        await harnessB.repository.updateUserCourse(
          courseId: conflictCourseId,
          ownerUserId: ownerUserId,
          expectedVersion: staleClientB.version,
          input: const UserCourseInput(
            title: 'Stale B',
            dayOfWeek: 4,
            periodNo: 4,
          ),
        );
        final conflictRun = await coordinatorB.synchronize(
          SyncTrigger.localMutation,
        );
        expect(conflictRun.push.conflicts, 1);
        final durableConflict = (await harnessB.queue.all()).singleWhere(
          (mutation) =>
              mutation.entityId == conflictCourseId &&
              mutation.status == SyncMutationStatus.conflict,
        );
        expect(durableConflict.baseVersion, staleClientB.version);
        expect(durableConflict.serverVersion, currentClientA.version + 1);
        expect(durableConflict.serverPayload['title'], 'Authoritative A');
        expect(durableConflict.conflictCursor, authoritativeCursor);
        final conflictDelta = await harnessA.gateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final authoritativeRemote = conflictDelta.changes
            .where((change) => change.entityId == conflictCourseId)
            .last;
        expect(
          conflictDelta.changes
              .where((change) => change.entityId == conflictCourseId),
          hasLength(beforeStaleConflictChanges.length),
        );
        expect(authoritativeRemote.changeCursor, authoritativeCursor);
        expect(authoritativeRemote.payload['title'], 'Authoritative A');
        expect(
          authoritativeRemote.serverVersion,
          durableConflict.serverVersion,
        );

        // Simulate a process death after the server commit and before the local
        // acknowledgement. Reopening the same Drift file must recover the
        // processing lease and receive a replayed acknowledgement exactly once.
        final restartFile = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}restart.sqlite',
        );
        restartDatabase = local.AppDatabase(NativeDatabase(restartFile));
        await SupabaseOnboardingRepository(
          clientA,
          localStore: DriftOnboardingLocalStore(restartDatabase),
        ).loadProfile(ownerUserId);
        final restartRepository = DriftScheduleRepository(restartDatabase);
        final restartCourseId = await restartRepository.createUserCourse(
          ownerUserId: ownerUserId,
          termId: termId,
          input: const UserCourseInput(
            title: 'Crash Safe Sync',
            dayOfWeek: 5,
            periodNo: 5,
          ),
        );
        final firstRecordingGateway = _RecordingGateway(
          SupabaseScheduleGateway(client: clientA),
        );
        final firstRestartQueue = DriftSyncQueue(
          restartDatabase,
          ownerUserId: ownerUserId,
        );
        final firstRestartWorker = SyncWorker(
          queue: firstRestartQueue,
          dispatcher: SyncMutationDispatcher(firstRecordingGateway),
          store: DriftScheduleSyncStore(
            restartDatabase,
            ownerUserId: ownerUserId,
          ),
          afterRemoteAck: (_, __) async => throw const _DroppedRemoteAck(),
        );
        await expectLater(
          firstRestartWorker.processPending(),
          throwsA(isA<_DroppedRemoteAck>()),
        );
        expect(firstRecordingGateway.mutationAcks, hasLength(1));
        expect(firstRecordingGateway.mutationAcks.single.replayed, isFalse);
        expect(
          (await firstRestartQueue.all())
              .singleWhere((row) => row.entityId == restartCourseId)
              .status,
          SyncMutationStatus.processing,
        );
        await restartDatabase.close();
        restartDatabase = null;

        restartDatabase = local.AppDatabase(NativeDatabase(restartFile));
        final replayRecordingGateway = _RecordingGateway(
          SupabaseScheduleGateway(client: clientA),
        );
        final replayQueue = DriftSyncQueue(
          restartDatabase,
          ownerUserId: ownerUserId,
        );
        final replayStore = DriftScheduleSyncStore(
          restartDatabase,
          ownerUserId: ownerUserId,
        );
        final replayWorker = SyncWorker(
          queue: replayQueue,
          dispatcher: SyncMutationDispatcher(replayRecordingGateway),
          store: replayStore,
        );
        restartCoordinator = SyncCoordinator(
          ownerUserId: ownerUserId,
          worker: replayWorker,
          gateway: replayRecordingGateway,
          store: replayStore,
        );
        final restartRun = await restartCoordinator.start();
        expect(restartRun.push.recovered, 0);
        expect(restartRun.push.synced, 1);
        expect(replayRecordingGateway.mutationAcks, hasLength(1));
        expect(replayRecordingGateway.mutationAcks.single.replayed, isTrue);
        final recoveredMutation = (await replayQueue.all()).singleWhere(
          (row) => row.entityId == restartCourseId,
        );
        expect(recoveredMutation.status, SyncMutationStatus.synced);
        expect(recoveredMutation.attemptCount, 2);

        final completeDelta = await replayRecordingGateway.pullDelta(
          ownerUserId: ownerUserId,
          afterCursor: 0,
          limit: 500,
        );
        final remoteRestartChanges = completeDelta.changes
            .where((change) => change.entityId == restartCourseId)
            .toList(growable: false);
        expect(remoteRestartChanges, hasLength(1));
        expect(
          remoteRestartChanges.single.serverVersion,
          replayRecordingGateway.mutationAcks.single.serverVersion,
        );

        // A different authenticated tenant sees none of the owner's deltas,
        // and switching the original client to that session invalidates the
        // owner-bound gateway before another request can leave the device.
        final tenantGateway = SupabaseScheduleGateway(client: tenantClient);
        final tenantDelta = await tenantGateway.pullDelta(
          ownerUserId: tenantUserId,
          afterCursor: 0,
          limit: 500,
        );
        expect(
          tenantDelta.changes.any(
            (change) =>
                change.entityId == duplicateCourseId ||
                change.entityId == conflictCourseId ||
                change.entityId == restartCourseId,
          ),
          isFalse,
        );
        await clientA.auth.signOut();
        final switched = await clientA.auth.signInWithPassword(
          email: tenantEmail,
          password: tenantPassword,
        );
        expect(switched.user?.id, tenantUserId);
        await expectLater(
          harnessA.gateway.pullDelta(
            ownerUserId: ownerUserId,
            afterCursor: 0,
          ),
          throwsA(isA<RemoteScheduleAuthenticationException>()),
        );
      } finally {
        restartCoordinator?.dispose();
        coordinatorB?.dispose();
        coordinatorA?.dispose();
        await restartDatabase?.close();
        await databaseB.close();
        await databaseA.close();
        await tenantClient.dispose();
        await clientB.dispose();
        await clientA.dispose();
        await temporaryDirectory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _SyncHarness {
  _SyncHarness({
    required this.database,
    required SupabaseClient client,
    required this.ownerUserId,
  })  : repository = DriftScheduleRepository(database),
        queue = DriftSyncQueue(database, ownerUserId: ownerUserId),
        gateway = SupabaseScheduleGateway(client: client),
        store = DriftScheduleSyncStore(
          database,
          ownerUserId: ownerUserId,
        ) {
    coordinator = SyncCoordinator(
      ownerUserId: ownerUserId,
      worker: SyncWorker(
        queue: queue,
        dispatcher: SyncMutationDispatcher(gateway),
        store: store,
      ),
      gateway: gateway,
      store: store,
    );
  }

  final local.AppDatabase database;
  final String ownerUserId;
  final DriftScheduleRepository repository;
  final DriftSyncQueue queue;
  final SupabaseScheduleGateway gateway;
  final DriftScheduleSyncStore store;
  late final SyncCoordinator coordinator;
}

class _RecordingGateway implements RemoteScheduleGateway {
  _RecordingGateway(this._delegate);

  final RemoteScheduleGateway _delegate;
  final List<ScheduleMutationAck> mutationAcks = [];

  @override
  Future<ScheduleMutationAck> applyMutation(PendingMutation mutation) async {
    final acknowledgement = await _delegate.applyMutation(mutation);
    mutationAcks.add(acknowledgement);
    return acknowledgement;
  }

  @override
  Future<ScheduleDeltaPage> pullDelta({
    required String ownerUserId,
    required int afterCursor,
    int limit = 200,
  }) {
    return _delegate.pullDelta(
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
      throw StateError('The schedule sync harness only accepts loopback HTTP.');
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
