import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/document_import/application/document_import_controller.dart';
import 'package:university_schedule_mobile/features/document_import/application/document_import_reconciliation_runtime.dart';
import 'package:university_schedule_mobile/features/document_import/data/drift_document_import_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  test('disabled release flag reads no auth network or gateway provider',
      () async {
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config(
          enabled: false,
          release: true,
        )),
        currentAuthSessionProvider.overrideWith(
          (ref) => throw StateError('disabled runtime read auth'),
        ),
        documentImportOwnerIdProvider.overrideWith(
          (ref) => throw StateError('disabled runtime read owner'),
        ),
        documentImportNetworkAvailableProvider.overrideWith(
          (ref) => throw StateError('disabled runtime read connectivity'),
        ),
        documentImportPendingReviewReconcilerProvider.overrideWith(
          (ref) => throw StateError('disabled runtime read gateway'),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(documentImportReconciliationRuntimeProvider).phase,
      DocumentImportReconciliationPhase.disabled,
    );
    await container
        .read(documentImportReconciliationRuntimeProvider.notifier)
        .trigger(DocumentImportReconciliationTrigger.appResume);
  });

  test('reconnect and app resume drain the authenticated owner', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final network = StreamController<bool>();
    final reconciler = _RecordingReconciler();
    final container = _container(
      db: db,
      reconciler: reconciler,
      network: network.stream,
    );
    final subscription = container.listen(
      documentImportReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await network.close();
      await db.close();
    });

    network.add(false);
    await _waitUntil(
      () =>
          container.read(documentImportReconciliationRuntimeProvider).phase ==
          DocumentImportReconciliationPhase.offline,
    );
    expect(reconciler.calls, isEmpty);

    network.add(true);
    await _waitUntil(() => reconciler.calls.length == 1);
    await _waitUntil(
      () =>
          container.read(documentImportReconciliationRuntimeProvider).phase ==
          DocumentImportReconciliationPhase.synchronized,
    );

    network.add(false);
    await _waitUntil(
      () =>
          container.read(documentImportReconciliationRuntimeProvider).phase ==
          DocumentImportReconciliationPhase.offline,
    );
    network.add(true);
    await _waitUntil(() => reconciler.calls.length == 2);

    await container
        .read(documentImportReconciliationRuntimeProvider.notifier)
        .trigger(DocumentImportReconciliationTrigger.appResume);
    expect(reconciler.calls,
        orderedEquals(const ['owner-a', 'owner-a', 'owner-a']));
    final state = container.read(documentImportReconciliationRuntimeProvider);
    expect(state.phase, DocumentImportReconciliationPhase.synchronized);
    expect(state.lastTrigger, DocumentImportReconciliationTrigger.appResume);
  });

  test('concurrent lifecycle wakes are single-flight with one bounded rerun',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final reconciler = _RecordingReconciler()
      ..blockers['owner-a'] = Completer<void>();
    final container = _container(
      db: db,
      reconciler: reconciler,
      network: Stream.value(true),
    );
    final subscription = container.listen(
      documentImportReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await db.close();
    });

    await _waitUntil(() => reconciler.calls.length == 1);
    final first = container
        .read(documentImportReconciliationRuntimeProvider.notifier)
        .trigger(DocumentImportReconciliationTrigger.appResume);
    final second = container
        .read(documentImportReconciliationRuntimeProvider.notifier)
        .trigger(DocumentImportReconciliationTrigger.appResume);
    reconciler.blockers['owner-a']!.complete();
    await Future.wait([first, second]);

    expect(reconciler.calls, hasLength(2));
    expect(reconciler.maxActive, 1);
  });

  test('wake on the completion boundary is drained instead of stranded',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final reconciler = _RecordingReconciler();
    final container = _container(
      db: db,
      reconciler: reconciler,
      network: Stream.value(true),
    );
    var boundaryWakeSent = false;
    final subscription = container.listen(
      documentImportReconciliationRuntimeProvider,
      (_, next) {
        if (!boundaryWakeSent &&
            next.phase == DocumentImportReconciliationPhase.synchronized) {
          boundaryWakeSent = true;
          unawaited(
            container
                .read(documentImportReconciliationRuntimeProvider.notifier)
                .trigger(DocumentImportReconciliationTrigger.appResume),
          );
        }
      },
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await db.close();
    });

    await _waitUntil(() => reconciler.calls.length == 2);
    await _waitUntil(
      () =>
          container.read(documentImportReconciliationRuntimeProvider).phase ==
          DocumentImportReconciliationPhase.synchronized,
    );

    expect(boundaryWakeSent, isTrue);
    expect(reconciler.calls, orderedEquals(const ['owner-a', 'owner-a']));
    expect(reconciler.maxActive, 1);
  });

  test('durable pending rows keep the runtime in retryable state', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    await _seedPendingReview(db);
    final reconciler = _RecordingReconciler();
    final container = _container(
      db: db,
      reconciler: reconciler,
      network: Stream.value(true),
    );
    final subscription = container.listen(
      documentImportReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await db.close();
    });

    await _waitUntil(
      () =>
          container.read(documentImportReconciliationRuntimeProvider).phase ==
          DocumentImportReconciliationPhase.waitingToRetry,
    );
    expect(reconciler.calls, isNotEmpty);
    expect(
      (await db.select(db.documentCandidatesCache).get())
          .single
          .remoteSyncState,
      'pending_select',
    );
  });

  test('owner switch starts a new generation and ignores the late old owner',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    final reconciler = _RecordingReconciler()
      ..blockers['owner-a'] = Completer<void>();
    final container = _container(
      db: db,
      reconciler: reconciler,
      network: Stream.value(true),
    );
    final subscription = container.listen(
      documentImportReconciliationRuntimeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await db.close();
    });

    await _waitUntil(() => reconciler.calls.contains('owner-a'));
    container.read(_testOwnerProvider.notifier).setOwner('owner-b');
    await _waitUntil(() => reconciler.calls.contains('owner-b'));
    await _waitUntil(() {
      final state = container.read(documentImportReconciliationRuntimeProvider);
      return state.ownerUserId == 'owner-b' &&
          state.phase == DocumentImportReconciliationPhase.synchronized;
    });

    reconciler.blockers['owner-a']!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final state = container.read(documentImportReconciliationRuntimeProvider);
    expect(state.ownerUserId, 'owner-b');
    expect(state.phase, DocumentImportReconciliationPhase.synchronized);
  });
}

ProviderContainer _container({
  required local.AppDatabase db,
  required _RecordingReconciler reconciler,
  required Stream<bool> network,
}) {
  return ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(_config(enabled: true)),
      appDatabaseProvider.overrideWithValue(db),
      currentAuthSessionProvider.overrideWith((ref) {
        final owner = ref.watch(_testOwnerProvider);
        return owner == null ? null : AppAuthSession(userId: owner);
      }),
      documentImportOwnerIdProvider.overrideWith(
        (ref) => ref.watch(_testOwnerProvider),
      ),
      documentImportNetworkAvailableProvider.overrideWith(
        (ref) => network,
      ),
      documentImportPendingReviewReconcilerProvider.overrideWithValue(
        reconciler,
      ),
    ],
  );
}

AppConfig _config({required bool enabled, bool release = false}) {
  if (release) {
    return AppConfig.validated(
      environment: 'production',
      demoMode: false,
      supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
      supabasePublishableKey: 'sb_publishable_mobile_test',
      productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
      webBaseUrl: 'https://schedule.example.edu',
      privacyPolicyUrl: 'https://schedule.example.edu/privacy',
      termsUrl: 'https://schedule.example.edu/terms',
      accountDeletionUrl: 'https://schedule.example.edu/account-deletion',
      supportUrl: 'https://schedule.example.edu/support',
      documentImportEnabled: enabled,
      isReleaseMode: true,
    );
  }
  return AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: 'http://127.0.0.1:54321',
    supabasePublishableKey: 'test-publishable-key',
    webBaseUrl: 'https://schedule.example.edu',
    documentImportEnabled: enabled,
  );
}

Future<void> _seedPendingReview(local.AppDatabase db) async {
  await db.into(db.documentSourcesCache).insert(
        local.DocumentSourcesCacheCompanion.insert(
          id: 'source-a',
          ownerUserId: 'owner-a',
          mediaType: 'text/plain',
          byteSize: 1,
          contentHash: 'a' * 64,
        ),
      );
  await db.into(db.documentCandidatesCache).insert(
        local.DocumentCandidatesCacheCompanion.insert(
          id: 'candidate-a',
          ownerUserId: 'owner-a',
          sourceId: 'source-a',
          candidateKey: 'source-a:assignment:1',
          remoteCandidateId: const Value('remote-a'),
          schemaVersion: '1.0',
          candidateType: 'assignment',
          normalizedPayloadJson: '{}',
          remoteVersion: const Value(1),
          remoteSyncState: const Value('pending_select'),
        ),
      );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for document reconciliation runtime.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final _testOwnerProvider =
    NotifierProvider<_TestOwnerController, String?>(_TestOwnerController.new);

class _TestOwnerController extends Notifier<String?> {
  @override
  String? build() => 'owner-a';

  void setOwner(String? ownerUserId) => state = ownerUserId;
}

class _RecordingReconciler implements DocumentImportPendingReviewReconciler {
  final calls = <String>[];
  final blockers = <String, Completer<void>>{};
  int active = 0;
  int maxActive = 0;

  @override
  Future<void> reconcilePending(String ownerUserId) async {
    calls.add(ownerUserId);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await blockers[ownerUserId]?.future;
    } finally {
      active--;
    }
  }
}
