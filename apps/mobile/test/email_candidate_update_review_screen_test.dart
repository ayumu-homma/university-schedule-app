import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_candidate_update_repository.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_candidate_update_review_screen.dart';

void main() {
  testWidgets(
      'shows explicit diffs and accepts while offline without an add UI',
      (tester) async {
    final updates = _FakeUpdateRepository();
    final controller = _controller(updates);
    await _pump(tester, controller: controller);

    expect(find.byKey(const Key('email-update-diff-title')), findsOneWidget);
    expect(find.text('現在: 旧タイトル'), findsOneWidget);
    expect(find.text('変更後: 新タイトル'), findsOneWidget);
    expect(find.text('現在: 2030/04/10 10:59'), findsOneWidget);
    expect(find.text('変更後: 2030/04/11 10:59'), findsOneWidget);
    expect(find.text('オフラインです'), findsOneWidget);
    expect(find.byKey(const Key('accept-email-update-button')), findsOneWidget);
    expect(find.byKey(const Key('reject-email-update-button')), findsOneWidget);
    expect(find.textContaining('追加'), findsNothing);
    expect(updates.accepted, isEmpty);

    await tester.tap(find.byKey(const Key('accept-email-update-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('confirm-accept-email-update-button')),
    );
    await tester.pumpAndSettle();

    expect(updates.accepted, ['update-1']);
    expect(find.text('inbox'), findsOneWidget);
  });

  testWidgets('reject is explicit, offline-capable, and does not call accept',
      (tester) async {
    final updates = _FakeUpdateRepository();
    final controller = _controller(updates);
    await _pump(tester, controller: controller);

    await tester.tap(find.byKey(const Key('reject-email-update-button')));
    await tester.pumpAndSettle();
    expect(find.text('元の予定は変更されません。'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('confirm-reject-email-update-button')),
    );
    await tester.pumpAndSettle();

    expect(updates.rejected, ['update-1']);
    expect(updates.accepted, isEmpty);
    expect(find.text('inbox'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required EmailReviewActionController controller,
}) async {
  final router = GoRouter(
    initialLocation: '/email-import/update/update-1',
    routes: [
      GoRoute(
        path: '/email-import/update/:id',
        builder: (context, state) => EmailCandidateUpdateReviewScreen(
          updateId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/email-import',
        builder: (context, state) => const Scaffold(body: Text('inbox')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        emailImportPresentationEnabledProvider.overrideWithValue(true),
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'owner-a'),
        ),
        emailNetworkAvailableProvider.overrideWith(
          (ref) => Stream.value(false),
        ),
        emailCandidateUpdatesProvider('owner-a').overrideWith(
          (ref) => Stream.value([_proposal()]),
        ),
        emailReviewActionControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

EmailReviewActionController _controller(
  EmailCandidateUpdateRepository updates,
) {
  return EmailReviewActionController(
    store: _UnusedStore(),
    remoteActions: _UnusedRemoteActions(),
    confirmationGateway: _UnusedConfirmationGateway(),
    updateRepository: updates,
  );
}

EmailCandidateUpdateProposal _proposal() {
  return EmailCandidateUpdateProposal(
    id: 'update-1',
    candidateId: 'candidate-1',
    entityType: EmailCandidateType.assignment,
    entityId: '33333333-3333-4333-8333-333333333333',
    fieldDiff: const {
      'title': {'before': '旧タイトル', 'after': '新タイトル'},
      'due_at': {
        'before': '2030-04-10T14:59:00.000Z',
        'after': '2030-04-11T14:59:00.000Z',
      },
    },
    proposedPayload: EmailCandidatePayload(
      schemaVersion: '1.0',
      candidateType: EmailCandidateType.assignment,
      title: '新タイトル',
      courseHint: const EmailCourseHint(),
      due: EmailDueCandidate(
        at: DateTime.utc(2030, 4, 11, 14, 59),
        allDay: false,
        timezone: 'America/New_York',
      ),
      confidence: const EmailCandidateConfidence(
        overall: 1,
        title: 1,
        course: 1,
        dateTime: 1,
      ),
      requiresUserConfirmation: true,
    ),
    baseEntityVersion: 1,
    createdAt: DateTime.utc(2026, 7, 22),
    timezone: 'America/New_York',
  );
}

class _FakeUpdateRepository implements EmailCandidateUpdateRepository {
  final accepted = <String>[];
  final rejected = <String>[];

  @override
  Future<EmailCandidateUpdateResolutionResult> accept({
    required String ownerUserId,
    required String updateId,
  }) async {
    accepted.add(updateId);
    return EmailCandidateUpdateResolutionResult(
      updateId: updateId,
      entityType: EmailCandidateType.assignment,
      entityId: '33333333-3333-4333-8333-333333333333',
      accepted: true,
      replayed: false,
    );
  }

  @override
  Future<List<EmailCandidateUpdateProposal>> pending({
    required String ownerUserId,
  }) async =>
      [_proposal()];

  @override
  Future<EmailCandidateUpdateResolutionResult> reject({
    required String ownerUserId,
    required String updateId,
  }) async {
    rejected.add(updateId);
    return EmailCandidateUpdateResolutionResult(
      updateId: updateId,
      entityType: EmailCandidateType.assignment,
      entityId: '33333333-3333-4333-8333-333333333333',
      accepted: false,
      replayed: false,
    );
  }
}

class _UnusedStore implements EmailReviewStore {
  @override
  Future<void> dismiss(
          {required String ownerUserId, required String candidateId}) =>
      throw UnimplementedError();

  @override
  Future<EmailReviewCandidate?> loadCandidate({
    required String ownerUserId,
    required String candidateId,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> saveDraft({
    required String ownerUserId,
    required String candidateId,
    required EmailCandidatePayload payload,
  }) =>
      throw UnimplementedError();

  @override
  Stream<List<EmailReviewCandidate>> watchCandidates(String ownerUserId) =>
      const Stream.empty();

  @override
  Stream<List<EmailConnectionSummary>> watchConnections(String ownerUserId) =>
      const Stream.empty();
}

class _UnusedRemoteActions implements EmailReviewRemoteActions {
  @override
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  }) =>
      throw UnimplementedError();

  @override
  Future<EmailConnectionState> connect({required String ownerUserId}) =>
      throw UnimplementedError();

  @override
  Future<void> deleteAccountData({required String ownerUserId}) =>
      throw UnimplementedError();

  @override
  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  }) =>
      throw UnimplementedError();
}

class _UnusedConfirmationGateway implements EmailCandidateConfirmationGateway {
  @override
  Future<EmailCandidateConfirmationResult> confirm({
    required String ownerUserId,
    required String candidateId,
    String? courseId,
  }) =>
      throw UnimplementedError();
}
