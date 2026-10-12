import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comment report failure shows generic message without values',
      (tester) async {
    const reporterId = 'reporter-private-id';
    const commentId = 'comment-private-id';
    const reason = 'report-reason-private-sentinel';
    final repository = _FailingReportRepository(
      errorDetails: '$reporterId | $commentId | $reason',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: reporterId),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('コメント操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通報'));
    await tester.pumpAndSettle();
    final reasonField = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextField),
    );
    await tester.enterText(reasonField, reason);
    await tester.tap(find.text('通報する'));
    await tester.pumpAndSettle();

    expect(repository.reportCalls, hasLength(1));
    expect(repository.reportCalls.single.targetType, 'comment');
    expect(repository.reportCalls.single.targetId, commentId);
    expect(repository.reportCalls.single.reason, reason);
    expect(
      find.text('グループ操作に失敗しました。通信と権限を確認してください。'),
      findsOneWidget,
    );
    expect(find.text('通報を受け付けました。'), findsNothing);
    for (final privateValue in [
      reporterId,
      commentId,
      reason,
      repository.errorDetails
    ]) {
      expect(find.textContaining(privateValue), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}

class _FailingReportRepository extends UnavailableGroupRepository {
  _FailingReportRepository({required this.errorDetails});

  final String errorDetails;
  final List<({String targetType, String targetId, String reason})>
      reportCalls = [];

  final GroupSummary _group = const GroupSummary(
    id: 'group',
    name: 'テストグループ',
    ownerUserId: 'owner-id',
    type: GroupType.other,
    role: GroupRole.member,
  );

  final GroupEventSummary _event = GroupEventSummary(
    eventId: 'event',
    groupId: 'group',
    title: 'テスト予定',
    startAt: DateTime.utc(2026, 10, 1, 14),
    endAt: DateTime.utc(2026, 10, 1, 16),
    createdBy: 'other-member',
    version: 1,
  );

  @override
  Future<List<GroupSummary>> listGroups() async => [_group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => _group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => [
        const GroupMemberSummary(
          groupId: 'group',
          userId: 'reporter-private-id',
          displayName: '閲覧者',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      [_event];

  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) async =>
      GroupEventContent(
        eventId: 'event',
        groupId: 'group',
        generation: 'generation-1',
        rsvps: const [
          GroupEventRsvp(
            userId: 'other-attendee',
            status: 'unanswered',
            updatedAt: null,
          ),
        ],
        comments: [
          GroupEventComment(
            commentId: 'comment-private-id',
            eventId: 'event',
            authorUserId: 'other-member',
            body: '既存コメント',
            createdAt: DateTime.utc(2026, 10, 1),
            updatedAt: DateTime.utc(2026, 10, 1),
            version: 1,
          ),
        ],
        reactions: [],
      );

  @override
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  }) async =>
      true;

  @override
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) async {
    reportCalls.add((
      targetType: targetType,
      targetId: targetId,
      reason: reason,
    ));
    throw StateError(errorDetails);
  }
}
