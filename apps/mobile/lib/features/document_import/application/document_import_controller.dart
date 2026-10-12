import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/lifecycle/scoped_context_lease.dart';
import '../../../core/time/app_clock.dart';
import '../../auth/application/auth_providers.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../data/document_file_picker.dart';
import '../data/document_import_gateway.dart';
import '../data/drift_document_import_repository.dart';
import '../domain/document_import_models.dart';

enum DocumentImportUiPhase {
  idle,
  picking,
  uploading,
  analyzing,
  ready,
  confirming,
  retrying,
  completed,
  failed,
}

class DocumentImportViewState {
  const DocumentImportViewState({
    required this.phase,
    this.batch,
    this.errorCategory,
    this.confirmedCount = 0,
    this.failedCount = 0,
  });

  const DocumentImportViewState.idle()
      : this(phase: DocumentImportUiPhase.idle);

  final DocumentImportUiPhase phase;
  final DocumentReviewBatch? batch;
  final DocumentImportErrorCategory? errorCategory;
  final int confirmedCount;
  final int failedCount;

  bool get isBusy => switch (phase) {
        DocumentImportUiPhase.picking ||
        DocumentImportUiPhase.uploading ||
        DocumentImportUiPhase.analyzing ||
        DocumentImportUiPhase.confirming ||
        DocumentImportUiPhase.retrying =>
          true,
        _ => false,
      };

  DocumentImportViewState copyWith({
    DocumentImportUiPhase? phase,
    DocumentReviewBatch? batch,
    bool clearBatch = false,
    DocumentImportErrorCategory? errorCategory,
    bool clearError = false,
    int? confirmedCount,
    int? failedCount,
  }) {
    return DocumentImportViewState(
      phase: phase ?? this.phase,
      batch: clearBatch ? null : (batch ?? this.batch),
      errorCategory: clearError ? null : (errorCategory ?? this.errorCategory),
      confirmedCount: confirmedCount ?? this.confirmedCount,
      failedCount: failedCount ?? this.failedCount,
    );
  }
}

final documentImportOwnerIdProvider = Provider<String?>((ref) {
  return ref.watch(activeScheduleContextProvider)?.ownerUserId;
});

final documentImportAvailableProvider = Provider<bool>((ref) {
  final config = ref.watch(appConfigProvider);
  return config.demoMode || config.documentImportEnabled;
});

final documentFilePickerProvider = Provider<DocumentFilePicker>((ref) {
  return const PlatformDocumentFilePicker();
});

final documentImportCourseOptionsProvider =
    FutureProvider<List<DocumentCourseOption>>((ref) async {
  final ownerUserId = ref.watch(documentImportOwnerIdProvider);
  if (ownerUserId == null) return const [];
  final db = ref.watch(appDatabaseProvider);
  final rows = await (db.select(db.userCourses)
        ..where(
          (row) => row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull(),
        )
        ..orderBy([(row) => OrderingTerm.asc(row.title)]))
      .get();
  return [
    for (final row in rows) DocumentCourseOption(id: row.id, title: row.title),
  ];
});

final documentImportGatewayProvider = Provider<DocumentImportGateway>((ref) {
  final config = ref.watch(appConfigProvider);
  final ownerUserId = ref.watch(documentImportOwnerIdProvider);
  if (config.demoMode) {
    return FakeDocumentImportGateway(
      ownerUserId: ownerUserId ?? 'signed-out-demo',
    );
  }
  if (!config.documentImportEnabled) {
    return const _DisabledDocumentImportGateway();
  }
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return const _DisabledDocumentImportGateway();
  }
  return SupabaseDocumentImportGateway(
    client: client,
    authenticatedUserId: () => ref.read(currentAuthSessionProvider)?.userId,
  );
});

final documentImportRepositoryProvider =
    Provider<DriftDocumentImportRepository>((ref) {
  // The schedule context can remain stable across demo/logout transitions;
  // observe auth separately so its lease is revoked on either boundary.
  ref.watch(currentAuthSessionProvider);
  final ownerUserId = ref.watch(documentImportOwnerIdProvider);
  if (ownerUserId == null) {
    throw StateError('Document import requires an authenticated owner.');
  }
  final db = ref.watch(appDatabaseProvider);
  final lease = ScopedContextLease(ownerUserId: ownerUserId, database: db);
  ref.onDispose(lease.revoke);
  return DriftDocumentImportRepository(
    db: db,
    gateway: ref.watch(documentImportGatewayProvider),
    clock: () => ref.read(appClockProvider).now(),
    authenticatedUserId: () => ref.read(documentImportOwnerIdProvider),
    lease: lease,
  );
});

final documentImportControllerProvider =
    AsyncNotifierProvider<DocumentImportController, DocumentImportViewState>(
  DocumentImportController.new,
);

class DocumentImportController extends AsyncNotifier<DocumentImportViewState> {
  int _operationGeneration = 0;
  DocumentImportCancellation? _activeCancellation;

  @override
  Future<DocumentImportViewState> build() async {
    _activeCancellation?.cancel();
    _activeCancellation = null;
    _operationGeneration++;
    final ownerUserId = ref.watch(documentImportOwnerIdProvider);
    if (ownerUserId == null) return const DocumentImportViewState.idle();
    final batch = await ref
        .watch(documentImportRepositoryProvider)
        .loadLatest(ownerUserId);
    if (batch == null) return const DocumentImportViewState.idle();
    return DocumentImportViewState(
      phase: DocumentImportUiPhase.ready,
      batch: batch,
    );
  }

  Future<void> pickAndAnalyze() async {
    if (!_available || _current.isBusy) return;
    final previous = _current;
    state = AsyncData(previous.copyWith(
      phase: DocumentImportUiPhase.picking,
      clearError: true,
    ));
    try {
      final selected = await ref.read(documentFilePickerProvider).pick();
      if (selected == null) {
        state = AsyncData(previous);
        return;
      }
      state = AsyncData(previous);
      await analyzeFile(selected);
    } on DocumentImportFailure catch (error) {
      _setFailure(error.category);
    } on Object {
      _setFailure(DocumentImportErrorCategory.internalError);
    }
  }

  Future<void> analyzeSyntheticDemo() async {
    final config = ref.read(appConfigProvider);
    if (!config.demoMode || _current.isBusy) return;
    final bytes = Uint8List.fromList(
      utf8.encode(
        '合成授業資料。課題2件と試験1件を含むポートフォリオ用fixture。',
      ),
    );
    await analyzeFile(
      DocumentSelectedFile.validate(
        extension: 'txt',
        declaredSize: bytes.length,
        bytes: bytes,
      ),
    );
  }

  Future<void> analyzeFile(DocumentSelectedFile file) async {
    if (!_available || _current.isBusy) return;
    final current = _current;
    final generation = ++_operationGeneration;
    final cancellation = DocumentImportCancellation();
    _activeCancellation = cancellation;
    state = AsyncData(current.copyWith(
      phase: DocumentImportUiPhase.uploading,
      clearError: true,
      confirmedCount: 0,
      failedCount: 0,
    ));
    try {
      final batch = await ref.read(documentImportRepositoryProvider).analyze(
        file,
        cancellation: cancellation,
        onState: (gatewayState) {
          if (!_isCurrentOperation(generation, cancellation)) return;
          final phase = switch (gatewayState) {
            DocumentImportState.uploading => DocumentImportUiPhase.uploading,
            DocumentImportState.analyzing => DocumentImportUiPhase.analyzing,
            _ => null,
          };
          if (phase != null) {
            state = AsyncData(_current.copyWith(phase: phase));
          }
        },
      );
      if (!_isCurrentOperation(generation, cancellation)) return;
      state = AsyncData(DocumentImportViewState(
        phase: DocumentImportUiPhase.ready,
        batch: batch,
      ));
    } on DocumentImportFailure catch (error) {
      if (!_isCurrentOperation(generation, cancellation)) return;
      _setFailure(error.category);
    } on Object {
      if (!_isCurrentOperation(generation, cancellation)) return;
      _setFailure(DocumentImportErrorCategory.internalError);
    } finally {
      if (_isCurrentOperation(generation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }

  void cancelAnalysis() {
    final cancellation = _activeCancellation;
    if (cancellation == null ||
        (_current.phase != DocumentImportUiPhase.uploading &&
            _current.phase != DocumentImportUiPhase.analyzing)) {
      return;
    }
    cancellation.cancel();
    _operationGeneration++;
    _activeCancellation = null;
    final current = _current;
    state = AsyncData(DocumentImportViewState(
      phase: current.batch == null
          ? DocumentImportUiPhase.idle
          : DocumentImportUiPhase.ready,
      batch: current.batch,
    ));
  }

  Future<void> setSelected(String candidateLocalId, bool selected) async {
    final review = _candidate(candidateLocalId);
    if (review == null || _current.isBusy) return;
    await _update(
      review,
      DocumentCandidateEdit(
        candidate: review.candidate,
        courseId: review.courseId,
      ),
      selected ? 'select' : 'deselect',
    );
  }

  Future<void> setAllSelected(bool selected) async {
    final batch = _current.batch;
    if (batch == null || _current.isBusy) return;
    for (final review in batch.candidates.where(
      (candidate) =>
          candidate.reviewState == DocumentCandidateReviewState.needsReview,
    )) {
      await _update(
        review,
        DocumentCandidateEdit(
          candidate: review.candidate,
          courseId: review.courseId,
        ),
        selected ? 'select' : 'deselect',
        refresh: false,
      );
    }
    await _refresh(batch.sourceId);
  }

  Future<void> exclude(String candidateLocalId) async {
    final review = _candidate(candidateLocalId);
    if (review == null || _current.isBusy) return;
    await _update(
      review,
      DocumentCandidateEdit(
        candidate: review.candidate,
        courseId: review.courseId,
      ),
      'exclude',
    );
  }

  Future<void> restore(String candidateLocalId) async {
    final review = _candidate(candidateLocalId);
    if (review == null || _current.isBusy) return;
    await _update(
      review,
      DocumentCandidateEdit(
        candidate: review.candidate,
        courseId: review.courseId,
      ),
      'restore',
    );
  }

  Future<void> edit(
    String candidateLocalId,
    DocumentCandidateEdit edit,
  ) async {
    final review = _candidate(candidateLocalId);
    if (review == null || _current.isBusy) return;
    await _update(review, edit, 'edit');
  }

  Future<void> _update(
    DocumentCandidateReview review,
    DocumentCandidateEdit edit,
    String action, {
    bool refresh = true,
  }) async {
    final ownerUserId = _owner;
    try {
      await ref.read(documentImportRepositoryProvider).updateCandidate(
            ownerUserId: ownerUserId,
            candidateLocalId: review.localId,
            edit: edit,
            action: action,
          );
      if (refresh) await _refresh(review.sourceId);
    } on DocumentImportFailure catch (error) {
      _setFailure(error.category);
    }
  }

  Future<void> confirmSelected() async {
    final current = _current;
    final batch = current.batch;
    if (batch == null || current.isBusy) return;
    final selected = batch.candidates
        .where((candidate) => candidate.canConfirm)
        .toList(growable: false);
    if (selected.isEmpty) return;
    state = AsyncData(current.copyWith(
      phase: DocumentImportUiPhase.confirming,
      clearError: true,
    ));
    try {
      final repository = ref.read(documentImportRepositoryProvider);
      final result = await repository.confirmEach(
        ownerUserId: _owner,
        items: _confirmationItems(selected),
      );
      final refreshed = await repository.loadSource(
        ownerUserId: _owner,
        sourceId: batch.sourceId,
      );
      state = AsyncData(DocumentImportViewState(
        phase: DocumentImportUiPhase.completed,
        batch: refreshed,
        confirmedCount: _confirmedCandidateCount(refreshed),
        failedCount: result.failed.length,
        errorCategory:
            result.failed.isEmpty ? null : result.failed.first.errorCategory,
      ));
    } on DocumentImportFailure catch (error) {
      _setConfirmationFailure(error.category, selected.length);
    } on Object {
      _setConfirmationFailure(
        DocumentImportErrorCategory.internalError,
        selected.length,
      );
    }
  }

  Future<void> retryPendingReviewSync() async {
    final current = _current;
    final batch = current.batch;
    if (batch == null || current.isBusy) return;
    state = AsyncData(current.copyWith(
      phase: DocumentImportUiPhase.retrying,
      clearError: true,
    ));
    try {
      final repository = ref.read(documentImportRepositoryProvider);
      final ownerUserId = _owner;
      await repository.reconcilePending(ownerUserId);
      var refreshed = await repository.loadSource(
        ownerUserId: ownerUserId,
        sourceId: batch.sourceId,
      );
      final retryCandidates = current.failedCount == 0
          ? const <DocumentCandidateReview>[]
          : refreshed.candidates
              .where((candidate) => candidate.canConfirm)
              .toList(growable: false);
      if (retryCandidates.isNotEmpty) {
        final result = await repository.confirmEach(
          ownerUserId: ownerUserId,
          items: _confirmationItems(retryCandidates),
        );
        refreshed = await repository.loadSource(
          ownerUserId: ownerUserId,
          sourceId: batch.sourceId,
        );
        state = AsyncData(DocumentImportViewState(
          phase: DocumentImportUiPhase.completed,
          batch: refreshed,
          confirmedCount: _confirmedCandidateCount(refreshed),
          failedCount: result.failed.length,
          errorCategory:
              result.failed.isEmpty ? null : result.failed.first.errorCategory,
        ));
        return;
      }
      final stillPending = refreshed.candidates.any(
        (candidate) => candidate.remoteSyncPending,
      );
      final confirmedCount = _confirmedCandidateCount(refreshed);
      state = AsyncData(DocumentImportViewState(
        phase: confirmedCount > 0 ||
                current.phase == DocumentImportUiPhase.completed
            ? DocumentImportUiPhase.completed
            : DocumentImportUiPhase.ready,
        batch: refreshed,
        confirmedCount: confirmedCount,
        failedCount: 0,
        errorCategory: stillPending
            ? DocumentImportErrorCategory.networkUnavailable
            : null,
      ));
    } on DocumentImportFailure catch (error) {
      _setFailure(error.category);
    } on Object {
      _setFailure(DocumentImportErrorCategory.internalError);
    }
  }

  Future<void> deleteCurrentSource() async {
    final current = _current;
    final batch = current.batch;
    if (batch == null || current.isBusy) return;
    await ref.read(documentImportRepositoryProvider).deleteSource(
          ownerUserId: _owner,
          sourceId: batch.sourceId,
        );
    state = const AsyncData(DocumentImportViewState.idle());
  }

  Future<void> _refresh(String sourceId) async {
    final batch = await ref
        .read(documentImportRepositoryProvider)
        .loadSource(ownerUserId: _owner, sourceId: sourceId);
    state = AsyncData(DocumentImportViewState(
      phase: DocumentImportUiPhase.ready,
      batch: batch,
    ));
  }

  DocumentCandidateReview? _candidate(String localId) {
    for (final candidate in _current.batch?.candidates ?? const []) {
      if (candidate.localId == localId) return candidate;
    }
    return null;
  }

  DocumentImportViewState get _current =>
      state.valueOrNull ?? const DocumentImportViewState.idle();

  String get _owner {
    final owner = ref.read(documentImportOwnerIdProvider);
    if (owner == null) {
      throw const DocumentImportFailure(
        DocumentImportErrorCategory.configurationMissing,
      );
    }
    return owner;
  }

  bool get _available => ref.read(documentImportAvailableProvider);

  bool _isCurrentOperation(
    int generation,
    DocumentImportCancellation cancellation,
  ) {
    return generation == _operationGeneration &&
        identical(_activeCancellation, cancellation) &&
        !cancellation.isCancelled;
  }

  void _setFailure(DocumentImportErrorCategory category) {
    state = AsyncData(_current.copyWith(
      phase: DocumentImportUiPhase.failed,
      errorCategory: category,
    ));
  }

  Iterable<DocumentConfirmationItem> _confirmationItems(
    Iterable<DocumentCandidateReview> candidates,
  ) sync* {
    for (final candidate in candidates) {
      yield DocumentConfirmationItem(
        candidateId: candidate.localId,
        courseId: candidate.courseId,
      );
    }
  }

  int _confirmedCandidateCount(DocumentReviewBatch batch) {
    return batch.candidates
        .where(
          (candidate) =>
              candidate.reviewState == DocumentCandidateReviewState.confirmed,
        )
        .length;
  }

  void _setConfirmationFailure(
    DocumentImportErrorCategory category,
    int failedCount,
  ) {
    state = AsyncData(_current.copyWith(
      phase: DocumentImportUiPhase.failed,
      errorCategory: category,
      confirmedCount: 0,
      failedCount: failedCount,
    ));
  }
}

class _DisabledDocumentImportGateway implements DocumentImportGateway {
  const _DisabledDocumentImportGateway();

  @override
  bool get confirmsOnServer => true;

  Never _disabled() => throw const DocumentImportFailure(
        DocumentImportErrorCategory.configurationMissing,
      );

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async =>
      _disabled();

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) async =>
      _disabled();

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async =>
      _disabled();

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) async =>
      _disabled();
}
