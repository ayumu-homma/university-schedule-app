import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/document_import/application/document_import_controller.dart';
import 'package:university_schedule_mobile/features/document_import/data/document_import_gateway.dart';
import 'package:university_schedule_mobile/features/document_import/data/drift_document_import_repository.dart';
import 'package:university_schedule_mobile/features/document_import/domain/document_import_models.dart';
import 'package:university_schedule_mobile/features/document_import/presentation/document_import_chat_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';
import 'package:university_schedule_mobile/local_db/app_database_provider.dart';

void main() {
  testWidgets(
    'fake document chat keeps proposals inert then excludes edits and confirms exactly two',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportGatewayProvider.overrideWithValue(
              FakeDocumentImportGateway(ownerUserId: 'owner-a'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('document-import-demo-button')),
        findsOneWidget,
      );
      final supportedTypes = find.text(
        '対応: PDF / PNG / JPEG / TXT（最大10 MB）',
      );
      final supportedTypesContext = tester.element(supportedTypes);
      expect(
        DefaultTextStyle.of(supportedTypesContext).style.color,
        Theme.of(supportedTypesContext).colorScheme.onPrimaryContainer,
      );
      await tester.tap(find.byKey(const Key('document-import-demo-button')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('document-import-screen'))),
      );
      final importedState =
          container.read(documentImportControllerProvider).valueOrNull;
      expect(importedState?.errorCategory, isNull);
      expect(importedState?.batch, isNotNull);
      final reviewList = find.byKey(
        ValueKey(
          'document-import-list-${importedState!.batch!.sourceId}',
        ),
      );
      expect(reviewList, findsOneWidget);
      expect(
        tester.getRect(reviewList).height,
        greaterThan(500),
        reason: tester.getRect(reviewList).toString(),
      );
      await tester.dragFrom(const Offset(200, 600), const Offset(0, -320));
      await tester.pumpAndSettle();
      final userMessage = find.text('この資料から課題と試験を探して');
      expect(userMessage, findsOneWidget);
      final userMessageContext = tester.element(userMessage);
      expect(
        DefaultTextStyle.of(userMessageContext).style.color,
        Theme.of(userMessageContext).colorScheme.onPrimaryContainer,
      );
      expect(importedState.batch!.candidates, hasLength(3));
      expect(await database.select(database.assignments).get(), isEmpty);
      expect(await database.select(database.exams).get(), isEmpty);
      expect(
        await database.select(database.notificationScheduleRequests).get(),
        isEmpty,
      );
      expect(await database.select(database.syncQueueEntries).get(), isEmpty);

      final exclude = find.byKey(const Key('candidate-exclude-1'));
      await tester.drag(find.byType(ListView), const Offset(0, -360));
      await tester.pumpAndSettle();
      await tester.tap(exclude);
      await tester.pumpAndSettle();
      expect(find.text('選択した2件を登録'), findsOneWidget);

      final edit = find.byKey(const Key('candidate-edit-0'));
      await _scrollUpUntilBuilt(tester, edit);
      final editSemantics = find.bySemanticsLabel(
        '「第8回アルゴリズムレポート」を編集',
      );
      expect(
        editSemantics,
        findsOneWidget,
      );
      expect(
        tester.getSemantics(editSemantics),
        isSemantics(
          label: '「第8回アルゴリズムレポート」を編集',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'The compact candidate editor must not overflow.',
      );
      final titleEditor = find.byKey(const Key('candidate-title-editor'));
      await tester.enterText(titleEditor, '');
      await tester.tap(find.byKey(const Key('candidate-editor-save')));
      await tester.pumpAndSettle();
      final validationError = find.byKey(
        const Key('candidate-editor-error'),
      );
      expect(validationError, findsOneWidget);
      expect(find.bySemanticsLabel('必須項目を確認してください。'), findsOneWidget);
      expect(
        tester.getSemantics(validationError),
        isSemantics(
          label: '必須項目を確認してください。',
          isLiveRegion: true,
        ),
      );

      await tester.enterText(titleEditor, '編集済みレポート');
      await tester.tap(find.byKey(const Key('candidate-editor-save')));
      await tester.pumpAndSettle();
      expect(find.text('編集済みレポート'), findsOneWidget);

      final confirm = find.byKey(const Key('document-confirm-button'));
      await tester.tap(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      final successMessage = find.text('2件を登録しました');
      await _scrollUpUntilBuilt(tester, successMessage);
      expect(successMessage, findsOneWidget);
      expect(await database.select(database.assignments).get(), hasLength(1));
      expect(await database.select(database.exams).get(), hasLength(1));
      expect(
        await database.select(database.notificationScheduleRequests).get(),
        hasLength(2),
      );
      expect(
        await database.select(database.syncQueueEntries).get(),
        hasLength(2),
      );
      expect(
        await database.select(database.documentScheduleEntityLinks).get(),
        hasLength(2),
      );
      semantics.dispose();
    },
  );

  testWidgets(
    'partial failure exposes guarded retry and creates only the failed candidate',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      final gateway = _FlakyWidgetDocumentImportGateway();
      addTearDown(database.close);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportGatewayProvider.overrideWithValue(gateway),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-import-demo-button')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('document-import-screen'))),
      );
      final imported =
          container.read(documentImportControllerProvider).valueOrNull!;
      await container
          .read(documentImportControllerProvider.notifier)
          .setSelected(imported.batch!.candidates[2].localId, false);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('document-confirm-button')));
      await tester.pumpAndSettle();
      final partialMessage = find.text('1件を登録しました／1件失敗');
      await _scrollUpUntilBuilt(tester, partialMessage);
      expect(partialMessage, findsOneWidget);
      expect(gateway.confirmationCalls, 2);
      expect(
        (await database.select(database.assignments).get()).length +
            (await database.select(database.exams).get()).length,
        1,
      );

      final retry = find.byKey(const Key('document-import-retry-button'));
      await _scrollUpUntilBuilt(tester, retry);
      await tester.tap(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      final completedMessage = find.text('2件を登録しました');
      await _scrollUpUntilBuilt(tester, completedMessage);
      expect(completedMessage, findsOneWidget);
      expect(gateway.confirmationCalls, 3);
      expect(
        (await database.select(database.assignments).get()).length +
            (await database.select(database.exams).get()).length,
        2,
      );
      expect(
        await database.select(database.notificationScheduleRequests).get(),
        hasLength(2),
      );
      expect(
        await database.select(database.syncQueueEntries).get(),
        hasLength(2),
      );
      expect(
        await database.select(database.documentScheduleEntityLinks).get(),
        hasLength(2),
      );
      expect(retry, findsNothing);
    },
  );

  testWidgets(
    'editing an exam into an assignment explicitly clears its location',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportGatewayProvider.overrideWithValue(
              FakeDocumentImportGateway(ownerUserId: 'owner-a'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-import-demo-button')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('document-import-screen'))),
      );
      final before = container
          .read(documentImportControllerProvider)
          .requireValue
          .batch!
          .candidates
          .singleWhere(
            (review) => review.candidate.type == DocumentCandidateType.exam,
          );
      expect(before.candidate.location, 'B203');

      final edit = find.byKey(const Key('candidate-edit-2'));
      for (var attempt = 0; attempt < 8 && edit.evaluate().isEmpty; attempt++) {
        await tester.drag(
          find.byType(ListView).last,
          const Offset(0, -320),
        );
        await tester.pumpAndSettle();
      }
      expect(edit, findsOneWidget);
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();

      final typeEditor = find.byKey(const Key('candidate-type-editor'));
      await tester.tap(
        find.descendant(of: typeEditor, matching: find.text('課題')),
      );
      await tester.pumpAndSettle();
      expect(find.text('教室（任意）'), findsNothing);
      await tester.tap(find.byKey(const Key('candidate-editor-save')));
      await tester.pumpAndSettle();

      final after = container
          .read(documentImportControllerProvider)
          .requireValue
          .batch!
          .candidates
          .singleWhere((review) => review.localId == before.localId)
          .candidate;
      expect(after.type, DocumentCandidateType.assignment);
      expect(after.location, isNull);
      expect(after.dueAt, isNotNull);
      expect(after.startAt, isNull);
      expect(after.endAt, isNull);
    },
  );

  testWidgets(
    'unexpected confirmation exception leaves a recoverable failed state',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      final repository = _ThrowingConfirmRepository(database);
      addTearDown(database.close);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-import-demo-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-confirm-button')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('document-import-screen'))),
      );
      final failed =
          container.read(documentImportControllerProvider).valueOrNull!;
      expect(failed.phase, DocumentImportUiPhase.failed);
      expect(
        failed.errorCategory,
        DocumentImportErrorCategory.internalError,
      );
      expect(failed.isBusy, isFalse);
      expect(
        find.byKey(const Key('document-import-retry-button')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'cancelled upload ignores a late response without deleting shared source state',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      final gateway = _DelayedDocumentImportGateway();
      addTearDown(database.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportGatewayProvider.overrideWithValue(gateway),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('document-import-demo-button')));
      await tester.pump();
      await gateway.started;
      await tester.pump();

      final cancel = find.byKey(const Key('document-import-cancel-button'));
      expect(cancel, findsOneWidget);
      await tester.tap(cancel);
      await tester.pump();
      expect(
        find.byKey(const Key('document-import-demo-button')),
        findsOneWidget,
      );

      gateway.release();
      await tester.pumpAndSettle();
      expect(gateway.deletedSources, isEmpty);
      expect(
          await database.select(database.documentSourcesCache).get(), isEmpty);
      expect(
        await database.select(database.documentCandidatesCache).get(),
        isEmpty,
      );
      expect(await database.select(database.assignments).get(), isEmpty);
      expect(await database.select(database.exams).get(), isEmpty);
      expect(
        await database.select(database.notificationScheduleRequests).get(),
        isEmpty,
      );
      expect(await database.select(database.syncQueueEntries).get(), isEmpty);
      expect(find.textContaining('候補が見つかりました'), findsNothing);
    },
  );

  testWidgets(
    'compact 360 by 640 at two times text keeps upload and confirm reachable',
    (tester) async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
            appDatabaseProvider.overrideWithValue(database),
            documentImportOwnerIdProvider.overrideWithValue('owner-a'),
            documentImportGatewayProvider.overrideWithValue(
              FakeDocumentImportGateway(ownerUserId: 'owner-a'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            home: const DocumentImportChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final upload = find.byKey(const Key('document-import-demo-button'));
      expect(upload, findsOneWidget);
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      expect(tester.getRect(upload).bottom, lessThanOrEqualTo(640));
      await tester.tap(upload);
      await tester.pumpAndSettle();

      final edit = find.byKey(const Key('candidate-edit-0'));
      for (var attempt = 0; attempt < 8 && edit.evaluate().isEmpty; attempt++) {
        await tester.drag(
          find.byType(ListView).last,
          const Offset(0, -320),
        );
        await tester.pumpAndSettle();
      }
      expect(edit, findsOneWidget);
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      expect(tester.getRect(edit).bottom, lessThanOrEqualTo(640));
      expect(
        tester.takeException(),
        isNull,
        reason: 'The 360dp, 2x-text review list must not overflow.',
      );
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'The 360dp, 2x-text candidate editor must not overflow.',
      );
      await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
      await tester.pumpAndSettle();

      final confirm = find.byKey(const Key('document-confirm-button'));
      expect(confirm, findsOneWidget);
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(640));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(await database.select(database.assignments).get(), hasLength(2));
      expect(await database.select(database.exams).get(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _scrollUpUntilBuilt(WidgetTester tester, Finder finder) async {
  final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
  for (var attempt = 0; attempt < 8 && finder.evaluate().isEmpty; attempt++) {
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

class _FlakyWidgetDocumentImportGateway implements DocumentImportGateway {
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

class _ThrowingConfirmRepository extends DriftDocumentImportRepository {
  _ThrowingConfirmRepository(AppDatabase database)
      : super(
          db: database,
          gateway: FakeDocumentImportGateway(ownerUserId: 'owner-a'),
          clock: () => DateTime.utc(2026, 8, 10, 1),
          authenticatedUserId: () => 'owner-a',
        );

  @override
  Future<DocumentBulkConfirmationResult> confirmEach({
    required String ownerUserId,
    required Iterable<DocumentConfirmationItem> items,
  }) async {
    throw StateError('synthetic confirmation crash');
  }
}

class _DelayedDocumentImportGateway implements DocumentImportGateway {
  final Completer<void> _started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  final List<String> deletedSources = [];

  Future<void> get started => _started.future;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  bool get confirmsOnServer => false;

  @override
  Future<DocumentAnalysisResult> analyze(
    DocumentSelectedFile file, {
    void Function(DocumentImportState state)? onState,
    DocumentImportCancellation? cancellation,
  }) async {
    onState?.call(DocumentImportState.uploading);
    if (!_started.isCompleted) _started.complete();
    await _release.future;
    final reserved =
        await FakeDocumentImportGateway(ownerUserId: 'owner-a').analyze(file);
    return DocumentAnalysisResult(
      batch: reserved.batch,
      storagePath: reserved.storagePath,
      remoteCandidates: reserved.remoteCandidates,
      remoteSourceVersion: reserved.remoteSourceVersion,
    );
  }

  @override
  Future<DocumentRemoteConfirmation> confirmCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String entityId,
    required String idempotencyKey,
    required String? courseId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSource({
    required String sourceId,
    required String? storagePath,
  }) async {
    deletedSources.add(sourceId);
  }

  @override
  Future<int?> updateCandidate({
    required RemoteDocumentCandidateIdentity identity,
    required DocumentScheduleCandidate candidate,
    required String action,
  }) {
    throw UnimplementedError();
  }
}
