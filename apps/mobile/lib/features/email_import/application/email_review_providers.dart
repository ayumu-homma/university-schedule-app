import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../local_db/app_database_provider.dart';
import '../../auth/application/auth_providers.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../data/drift_email_review_store.dart';
import '../data/email_candidate_confirmation_repository.dart';
import '../data/email_candidate_update_repository.dart';
import '../data/email_import_failure.dart';
import '../data/production_email_review_actions.dart';
import '../domain/email_review_models.dart';

/// Defaults to the production feature flag. Secret-free tests/E2E may
/// explicitly override this together with fake store/network boundaries; the
/// production remote adapter still independently fails closed on AppConfig.
final emailImportPresentationEnabledProvider = Provider<bool>((ref) {
  return ref.watch(appConfigProvider).emailImportEnabled;
});

class EmailOwnedCourseOption {
  const EmailOwnedCourseOption({required this.id, required this.title});

  final String id;
  final String title;
}

/// Active, owner-scoped courses available for an explicit Assignment/Exam
/// link. Candidate hint text is never used to infer a course identifier.
final emailOwnedCoursesProvider = Provider<List<EmailOwnedCourseOption>>((ref) {
  final state = ref.watch(demoAppControllerProvider).valueOrNull;
  return (state?.courses ?? const [])
      .map(
        (course) => EmailOwnedCourseOption(
          id: course.id,
          title: course.title,
        ),
      )
      .toList(growable: false);
});

final emailReviewStoreProvider = Provider<EmailReviewStore>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(
    ownerUserId: session?.userId ?? '',
    database: db,
  );
  if (session == null) lease.revoke();
  ref.onDispose(lease.revoke);
  return DriftEmailReviewStore(
    db: db,
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    lease: lease,
  );
});

final emailReviewRemoteActionsProvider = Provider<EmailReviewRemoteActions>((
  ref,
) {
  final session = ref.watch(currentAuthSessionProvider);
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(
    ownerUserId: session?.userId ?? '',
    database: db,
  );
  if (session == null) lease.revoke();
  ref.onDispose(lease.revoke);
  return ProductionEmailReviewRemoteActions(
    db: db,
    config: ref.watch(appConfigProvider),
    client: ref.watch(supabaseClientProvider),
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    lease: lease,
  );
});

final emailCandidateConfirmationGatewayProvider =
    Provider<EmailCandidateConfirmationGateway>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(
    ownerUserId: session?.userId ?? '',
    database: db,
  );
  if (session == null) lease.revoke();
  ref.onDispose(lease.revoke);
  return DriftEmailCandidateConfirmationGateway(
    db: db,
    clock: DateTime.now,
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    lease: lease,
  );
});

final emailCandidateUpdateRepositoryProvider =
    Provider<EmailCandidateUpdateRepository>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(
    ownerUserId: session?.userId ?? '',
    database: db,
  );
  if (session == null) lease.revoke();
  ref.onDispose(lease.revoke);
  return DriftEmailCandidateUpdateRepository(
    db: db,
    clock: DateTime.now,
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
    lease: lease,
  );
});

final emailConnectionsProvider = StreamProvider.autoDispose
    .family<List<EmailConnectionSummary>, String>((ref, ownerUserId) {
  return ref.watch(emailReviewStoreProvider).watchConnections(ownerUserId);
});

final emailReviewCandidatesProvider = StreamProvider.autoDispose
    .family<List<EmailReviewCandidate>, String>((ref, ownerUserId) {
  return ref.watch(emailReviewStoreProvider).watchCandidates(ownerUserId);
});

final emailCandidateUpdatesProvider = StreamProvider.autoDispose
    .family<List<EmailCandidateUpdateProposal>, String>((ref, ownerUserId) {
  final db = ref.watch(appDatabaseProvider);
  final repository = ref.watch(emailCandidateUpdateRepositoryProvider);
  return db.emailImportDao
      .watchPendingUpdates(ownerUserId)
      .asyncMap((_) => repository.pending(ownerUserId: ownerUserId));
});

abstract interface class EmailConnectivityHintSource {
  Future<List<ConnectivityResult>> checkConnectivity();

  Stream<List<ConnectivityResult>> get onConnectivityChanged;
}

typedef EmailBackendReachabilityProbe = Future<bool> Function();

typedef EmailBackendReachabilityHttpClientFactory = http.Client Function();

typedef EmailBackendReachabilityRetryDelay = Duration Function(int retryIndex);

final emailConnectivityHintSourceProvider =
    Provider<EmailConnectivityHintSource>((ref) {
  return _PluginEmailConnectivityHintSource(Connectivity());
});

final emailBackendReachabilityTimeoutProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 3);
});

final emailBackendReachabilityHttpClientFactoryProvider =
    Provider<EmailBackendReachabilityHttpClientFactory>((ref) {
  return () => http.Client();
});

final emailBackendReachabilityProbeProvider =
    Provider<EmailBackendReachabilityProbe>((ref) {
  final baseUrl = ref.watch(appConfigProvider).supabaseUrl;
  final timeout = ref.watch(emailBackendReachabilityTimeoutProvider);
  final createClient =
      ref.watch(emailBackendReachabilityHttpClientFactoryProvider);
  return () async {
    if (baseUrl == null) return false;
    final client = createClient();
    try {
      final response =
          await client.get(baseUrl.resolve('/auth/v1/health')).timeout(timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close();
    }
  };
});

final emailBackendReachabilityRetryDelayProvider =
    Provider<EmailBackendReachabilityRetryDelay>((ref) {
  return _emailBackendReachabilityRetryDelay;
});

final emailNetworkAvailableProvider = StreamProvider.autoDispose<bool>((ref) {
  final connectivity = ref.watch(emailConnectivityHintSourceProvider);
  final probe = ref.watch(emailBackendReachabilityProbeProvider);
  final probeTimeout = ref.watch(emailBackendReachabilityTimeoutProvider);
  final retryDelay = ref.watch(emailBackendReachabilityRetryDelayProvider);
  late final StreamController<bool> controller;
  StreamSubscription<List<ConnectivityResult>>? subscription;
  Timer? retryTimer;
  var generation = 0;
  var retryIndex = 0;
  var hasPositiveHint = false;
  var disposed = false;

  void cancelRetry({required bool resetBackoff}) {
    retryTimer?.cancel();
    retryTimer = null;
    if (resetBackoff) retryIndex = 0;
  }

  void publish(bool available, int requestGeneration) {
    if (disposed || controller.isClosed || requestGeneration != generation) {
      return;
    }
    controller.add(available);
  }

  late final Future<void> Function(int requestGeneration) probeBackend;

  void scheduleRetry(int requestGeneration) {
    if (disposed || requestGeneration != generation || !hasPositiveHint) {
      return;
    }
    retryTimer?.cancel();
    final timerGeneration = requestGeneration;
    final delay = retryDelay(retryIndex++);
    retryTimer = Timer(delay, () {
      retryTimer = null;
      if (disposed || timerGeneration != generation || !hasPositiveHint) {
        return;
      }
      final retryGeneration = ++generation;
      unawaited(probeBackend(retryGeneration));
    });
  }

  probeBackend = (int requestGeneration) async {
    var reachable = false;
    try {
      reachable = await probe().timeout(probeTimeout);
    } on Object {
      // Connectivity is only a wake-up hint. A timeout or transport failure
      // means the configured backend is not currently usable by Email import.
    }
    if (disposed || requestGeneration != generation) return;
    if (reachable) {
      cancelRetry(resetBackoff: true);
      publish(true, requestGeneration);
      return;
    }
    publish(false, requestGeneration);
    scheduleRetry(requestGeneration);
  };

  void evaluateLatest(List<ConnectivityResult> results) {
    final requestGeneration = ++generation;
    cancelRetry(resetBackoff: true);
    hasPositiveHint = _hasNetworkHint(results);
    if (!hasPositiveHint) {
      publish(false, requestGeneration);
      return;
    }
    unawaited(probeBackend(requestGeneration));
  }

  void publishFailureIfCurrent(int expectedGeneration) {
    if (disposed || generation != expectedGeneration) return;
    final requestGeneration = ++generation;
    cancelRetry(resetBackoff: true);
    hasPositiveHint = false;
    publish(false, requestGeneration);
  }

  controller = StreamController<bool>(
    onListen: () {
      // Subscribe before the initial check so a transition during the async
      // platform call cannot be lost. The generation check below discards a
      // stale initial result when the change stream has already advanced.
      subscription = connectivity.onConnectivityChanged.listen(
        evaluateLatest,
        onError: (Object _, StackTrace __) {
          final requestGeneration = ++generation;
          cancelRetry(resetBackoff: true);
          hasPositiveHint = false;
          publish(false, requestGeneration);
        },
      );
      final generationBeforeInitialCheck = generation;
      unawaited(() async {
        try {
          final initial = await connectivity.checkConnectivity();
          if (disposed || generation != generationBeforeInitialCheck) return;
          evaluateLatest(initial);
        } on Object {
          publishFailureIfCurrent(generationBeforeInitialCheck);
        }
      }());
    },
    onCancel: () async {
      disposed = true;
      generation++;
      hasPositiveHint = false;
      cancelRetry(resetBackoff: true);
      await subscription?.cancel();
      await controller.close();
    },
  );
  return controller.stream.distinct();
});

bool _hasNetworkHint(List<ConnectivityResult> results) {
  return results.any((result) => result != ConnectivityResult.none);
}

Duration _emailBackendReachabilityRetryDelay(int retryIndex) {
  return switch (retryIndex) {
    <= 0 => const Duration(seconds: 2),
    1 => const Duration(seconds: 10),
    2 => const Duration(seconds: 30),
    3 => const Duration(minutes: 2),
    _ => const Duration(minutes: 5),
  };
}

final class _PluginEmailConnectivityHintSource
    implements EmailConnectivityHintSource {
  const _PluginEmailConnectivityHintSource(this._connectivity);

  final Connectivity _connectivity;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    return _connectivity.checkConnectivity();
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged;
  }
}

enum EmailReviewOperation {
  idle,
  connecting,
  checkingAuthorization,
  refreshing,
  saving,
  dismissing,
  retrying,
  disconnecting,
  deletingAccountData,
  confirming,
}

enum EmailReviewSuccess {
  connected,
  authorizationOpened,
  authorizationPending,
  refreshed,
  saved,
  dismissed,
  retryCompleted,
  disconnected,
  accountDataDeleted,
  confirmed,
}

class EmailReviewActionState {
  const EmailReviewActionState({
    this.operation = EmailReviewOperation.idle,
    this.success,
    this.failureCategory,
    this.connectionStatus,
    this.retryAfter,
  });

  final EmailReviewOperation operation;
  final EmailReviewSuccess? success;
  final EmailErrorCategory? failureCategory;
  final EmailConnectionStatus? connectionStatus;
  final Duration? retryAfter;

  bool get isBusy => operation != EmailReviewOperation.idle;
}

final emailReviewActionControllerProvider = StateNotifierProvider.autoDispose<
    EmailReviewActionController, EmailReviewActionState>((ref) {
  return EmailReviewActionController(
    store: ref.watch(emailReviewStoreProvider),
    remoteActions: ref.watch(emailReviewRemoteActionsProvider),
    confirmationGateway: ref.watch(emailCandidateConfirmationGatewayProvider),
    updateRepository: ref.watch(emailCandidateUpdateRepositoryProvider),
  );
});

class EmailReviewActionController
    extends StateNotifier<EmailReviewActionState> {
  EmailReviewActionController({
    required this.store,
    required this.remoteActions,
    required this.confirmationGateway,
    this.updateRepository,
    EmailCandidatePayloadCodec candidateCodec =
        const EmailCandidatePayloadCodec(),
  })  : _candidateCodec = candidateCodec,
        super(const EmailReviewActionState());

  final EmailReviewStore store;
  final EmailReviewRemoteActions remoteActions;
  final EmailCandidateConfirmationGateway confirmationGateway;
  final EmailCandidateUpdateRepository? updateRepository;
  final EmailCandidatePayloadCodec _candidateCodec;

  Future<bool> connect(String ownerUserId) async {
    state = const EmailReviewActionState(
      operation: EmailReviewOperation.connecting,
    );
    try {
      final connection = await remoteActions.connect(
        ownerUserId: ownerUserId,
      );
      if (connection.status == EmailConnectionStatus.connecting &&
          connection.oauthChallenge != null) {
        state = const EmailReviewActionState(
          success: EmailReviewSuccess.authorizationOpened,
          connectionStatus: EmailConnectionStatus.connecting,
        );
        return true;
      }
      if (connection.status != EmailConnectionStatus.connected) {
        state = EmailReviewActionState(
          connectionStatus: connection.status,
          failureCategory: connection.errorCategory,
          retryAfter: connection.retryAfter,
        );
        return false;
      }
      state = const EmailReviewActionState(
        success: EmailReviewSuccess.connected,
        connectionStatus: EmailConnectionStatus.connected,
      );
      return true;
    } on Object catch (error) {
      _setFailure(error);
      return false;
    }
  }

  Future<bool> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
    String? callbackCorrelationId,
  }) async {
    if (state.isBusy) return false;
    state = const EmailReviewActionState(
      operation: EmailReviewOperation.checkingAuthorization,
    );
    try {
      final correlated = remoteActions is CorrelatedEmailAuthorizationActions
          ? remoteActions as CorrelatedEmailAuthorizationActions
          : null;
      final connection = callbackCorrelationId != null && correlated != null
          ? await correlated.checkCorrelatedAuthorization(
              ownerUserId: ownerUserId,
              requestedConnectionId: connectionId,
              callbackCorrelationId: callbackCorrelationId,
            )
          : await remoteActions.checkAuthorization(
              ownerUserId: ownerUserId,
              connectionId: connectionId,
            );
      if (connection.status == EmailConnectionStatus.connected) {
        state = const EmailReviewActionState(
          success: EmailReviewSuccess.connected,
          connectionStatus: EmailConnectionStatus.connected,
        );
        return true;
      }
      if (connection.status == EmailConnectionStatus.connecting) {
        state = const EmailReviewActionState(
          success: EmailReviewSuccess.authorizationPending,
          connectionStatus: EmailConnectionStatus.connecting,
        );
        return false;
      }
      state = EmailReviewActionState(
        connectionStatus: connection.status,
        failureCategory: connection.errorCategory,
        retryAfter: connection.retryAfter,
      );
      return false;
    } on Object catch (error) {
      _setFailure(error);
      return false;
    }
  }

  Future<bool> refresh({
    required String ownerUserId,
    required String connectionId,
  }) {
    return _run(
      EmailReviewOperation.refreshing,
      EmailReviewSuccess.refreshed,
      () => remoteActions.refresh(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      ),
    );
  }

  Future<bool> saveDraft({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
  }) {
    return _run(
      EmailReviewOperation.saving,
      EmailReviewSuccess.saved,
      () => store.saveDraft(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        payload: payload,
      ),
    );
  }

  Future<bool> dismissMany({
    required String ownerUserId,
    required Iterable<String> candidateIds,
  }) {
    return _run(
      EmailReviewOperation.dismissing,
      EmailReviewSuccess.dismissed,
      () async {
        for (final candidateId in candidateIds.toSet()) {
          await store.dismiss(
            ownerUserId: ownerUserId,
            candidateId: candidateId,
          );
        }
      },
    );
  }

  Future<bool> retryMany({
    required String ownerUserId,
    required Iterable<String> candidateIds,
  }) {
    return _run(
      EmailReviewOperation.retrying,
      EmailReviewSuccess.retryCompleted,
      () async {
        for (final candidateId in candidateIds.toSet()) {
          await remoteActions.retryCandidate(
            ownerUserId: ownerUserId,
            candidateId: candidateId,
          );
        }
      },
    );
  }

  Future<bool> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) {
    return _run(
      EmailReviewOperation.disconnecting,
      EmailReviewSuccess.disconnected,
      () => remoteActions.disconnect(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
        deleteDerivedData: deleteDerivedData,
      ),
    );
  }

  Future<bool> deleteAccountData({required String ownerUserId}) {
    return _run(
      EmailReviewOperation.deletingAccountData,
      EmailReviewSuccess.accountDataDeleted,
      () => remoteActions.deleteAccountData(ownerUserId: ownerUserId),
    );
  }

  Future<bool> acceptUpdate({
    required String ownerUserId,
    required String updateId,
  }) {
    return _run(
      EmailReviewOperation.saving,
      EmailReviewSuccess.saved,
      () async {
        final repository = updateRepository;
        if (repository == null) {
          throw const EmailReviewActionException(
            EmailErrorCategory.configurationMissing,
          );
        }
        await repository.accept(
          ownerUserId: ownerUserId,
          updateId: updateId,
        );
      },
    );
  }

  Future<bool> rejectUpdate({
    required String ownerUserId,
    required String updateId,
  }) {
    return _run(
      EmailReviewOperation.saving,
      EmailReviewSuccess.saved,
      () async {
        final repository = updateRepository;
        if (repository == null) {
          throw const EmailReviewActionException(
            EmailErrorCategory.configurationMissing,
          );
        }
        await repository.reject(
          ownerUserId: ownerUserId,
          updateId: updateId,
        );
      },
    );
  }

  /// Saves first, then reloads and revalidates the committed proposal before
  /// invoking Phase 5E. A save failure can never reach confirmation.
  Future<bool> saveAndConfirm({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
    required bool warningsAcknowledged,
    String? courseId,
  }) async {
    if (!_isConfirmable(payload) || !warningsAcknowledged) {
      state = const EmailReviewActionState(
        failureCategory: EmailErrorCategory.validationFailed,
      );
      return false;
    }
    state = const EmailReviewActionState(
      operation: EmailReviewOperation.saving,
    );
    try {
      final expectedCanonical = _candidateCodec.encode(payload);
      await store.saveDraft(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        payload: payload,
      );
      final persisted = await store.loadCandidate(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      final persistedPayload = persisted?.payload;
      if (persisted == null ||
          persistedPayload == null ||
          persisted.isHistory ||
          persisted.state == EmailCandidateReviewState.updateAvailable ||
          !_isConfirmable(persistedPayload) ||
          _candidateCodec.encode(persistedPayload) != expectedCanonical) {
        throw const EmailReviewActionException(
          EmailErrorCategory.validationFailed,
        );
      }
      state = const EmailReviewActionState(
        operation: EmailReviewOperation.confirming,
      );
      await confirmationGateway.confirm(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
        courseId: switch (payload.candidateType) {
          EmailCandidateType.assignment || EmailCandidateType.exam => courseId,
          EmailCandidateType.event ||
          EmailCandidateType.announcement ||
          EmailCandidateType.unknown =>
            null,
        },
      );
      state = const EmailReviewActionState(
        success: EmailReviewSuccess.confirmed,
      );
      return true;
    } on Object catch (error) {
      _setFailure(error);
      return false;
    }
  }

  void clearFeedback() {
    if (!state.isBusy) state = const EmailReviewActionState();
  }

  bool _isConfirmable(EmailCandidatePayload payload) {
    if (!payload.requiresUserConfirmation ||
        payload.title == null ||
        payload.title!.trim().isEmpty) {
      return false;
    }
    return switch (payload.candidateType) {
      EmailCandidateType.assignment => payload.due.at != null,
      EmailCandidateType.exam => payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.event => payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.announcement || EmailCandidateType.unknown => false,
    };
  }

  Future<bool> _run(
    EmailReviewOperation operation,
    EmailReviewSuccess success,
    Future<void> Function() action,
  ) async {
    if (state.isBusy) return false;
    state = EmailReviewActionState(operation: operation);
    try {
      await action();
      state = EmailReviewActionState(success: success);
      return true;
    } on Object catch (error) {
      _setFailure(error);
      return false;
    }
  }

  void _setFailure(Object error) {
    if (error is EmailReviewActionException) {
      state = EmailReviewActionState(failureCategory: error.category);
      return;
    }
    if (error is EmailImportFailure) {
      state = EmailReviewActionState(
        failureCategory: error.errorCategory,
        connectionStatus: error.connectionStatus,
        retryAfter: error.retryAfter,
      );
      return;
    }
    state = const EmailReviewActionState(
      failureCategory: EmailErrorCategory.internalError,
    );
  }
}
