import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('owner-only policy hides create from admin but creator can edit',
      (tester) async {
    final repository = _GroupScreenRepository(role: GroupRole.admin);
    await tester.pumpWidget(
        _app(repository, const GroupDetailScreen(groupId: 'group')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('group-event-create')), findsNothing);
    expect(find.textContaining('2026-10-01 23:00 - 2026-10-02 01:00'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();
    expect(find.text('編集'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.textContaining('viewer: unanswered'), findsOneWidget);
    expect(find.text('未回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner opens state-owned event form without controller errors',
      (tester) async {
    final repository = _GroupScreenRepository(role: GroupRole.owner);
    await tester.pumpWidget(
        _app(repository, const GroupDetailScreen(groupId: 'group')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-event-create')));
    await tester.pumpAndSettle();
    expect(find.text('グループ予定を作成'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'タイトル'), findsOneWidget);
    expect(find.textContaining('開始:'), findsOneWidget);
    expect(find.textContaining('終了:'), findsOneWidget);
    expect(find.widgetWithText(TextField, '場所（任意）'), findsOneWidget);
    expect(find.widgetWithText(TextField, '説明（任意）'), findsOneWidget);

    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('group create dialog owns controllers through route disposal',
      (tester) async {
    final repository = _GroupScreenRepository(role: GroupRole.owner);
    await tester
        .pumpWidget(_app(repository, const Scaffold(body: GroupListTab())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('グループを作成'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'グループ名'), 'Lifecycle group');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(repository.createdNames, contains('Lifecycle group'));
  });

  testWidgets('version conflict keeps the draft for explicit re-edit',
      (tester) async {
    final repository =
        _GroupScreenRepository(role: GroupRole.owner, conflictOnUpdate: true);
    await tester.pumpWidget(
        _app(repository, const GroupDetailScreen(groupId: 'group')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('編集'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'タイトル'), '保持される下書き');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('予定が更新されています'), findsOneWidget);
    await tester.tap(find.text('再編集'));
    await tester.pumpAndSettle();
    expect(find.text('保持される下書き'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('event detail renders comments and fixed reactions',
      (tester) async {
    final repository =
        _GroupScreenRepository(role: GroupRole.member, withUgc: true);
    await tester.pumpWidget(
        _app(repository, const GroupDetailScreen(groupId: 'group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();
    expect(find.text('既存コメント'), findsOneWidget);
    expect(find.text('了解 1'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'コメントを入力'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'コメントを入力'), '追加コメント');
    await tester.ensureVisible(find.text('送信'));
    await tester.tap(find.text('送信'));
    await tester.pumpAndSettle();
    expect(repository.commentBodies, contains('追加コメント'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'comment report cancellation sends nothing and submit reports once',
      (tester) async {
    final repository =
        _GroupScreenRepository(role: GroupRole.member, withUgc: true);
    await tester.pumpWidget(
        _app(repository, const GroupDetailScreen(groupId: 'group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('コメント操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通報'));
    await tester.pumpAndSettle();
    expect(find.text('通報理由'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(repository.reportCalls, isEmpty);

    await tester.tap(find.byTooltip('コメント操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通報'));
    await tester.pumpAndSettle();
    final reasonField = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextField),
    );
    await tester.enterText(reasonField, '  嫌がらせの内容  ');
    await tester.tap(find.text('通報する'));
    await tester.pumpAndSettle();

    expect(repository.reportCalls, hasLength(1));
    expect(repository.reportCalls.single.targetType, 'comment');
    expect(repository.reportCalls.single.targetId, 'comment');
    expect(repository.reportCalls.single.reason, '嫌がらせの内容');
    expect(find.text('通報を受け付けました。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('comment conflict retains draft in controller state', () async {
    final repository = _GroupScreenRepository(
        role: GroupRole.member, withUgc: true, commentConflictOnUpdate: true);
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'viewer'),
      ),
      groupRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);
    final controller = container.read(groupsControllerProvider.notifier);
    expect(await controller.open('group'), isTrue);
    expect(await controller.loadEventContent('event'), isTrue);
    final comment =
        container.read(groupsControllerProvider).value!.eventComments.single;
    expect(await controller.updateComment(comment, '保持するコメント下書き'), isFalse);
    expect(
        container.read(groupsControllerProvider).value!.eventCommentDraft?.body,
        '保持するコメント下書き');
  });

  test('event content is not published when generation validation fails',
      () async {
    final repository = _GroupScreenRepository(
        role: GroupRole.member, withUgc: true, contentGenerationValid: false);
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'viewer'),
      ),
      groupRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);
    final controller = container.read(groupsControllerProvider.notifier);
    expect(await controller.open('group'), isTrue);
    expect(await controller.loadEventContent('event'), isFalse);
    final state = container.read(groupsControllerProvider).value!;
    expect(state.eventComments, isEmpty);
    expect(state.eventContentGeneration, isNull);
  });
}

Widget _app(_GroupScreenRepository repository, Widget home) => ProviderScope(
      overrides: [
        currentAuthSessionProvider.overrideWithValue(
          const AppAuthSession(userId: 'viewer'),
        ),
        groupRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(home: home),
    );

class _GroupScreenRepository extends UnavailableGroupRepository {
  _GroupScreenRepository(
      {required this.role,
      this.conflictOnUpdate = false,
      this.withUgc = false,
      this.commentConflictOnUpdate = false,
      this.contentGenerationValid = true});
  final GroupRole role;
  final bool conflictOnUpdate;
  final bool withUgc;
  final bool commentConflictOnUpdate;
  final bool contentGenerationValid;
  final List<String> createdNames = [];
  final List<String> commentBodies = [];
  final List<({String targetType, String targetId, String reason})>
      reportCalls = [];

  GroupSummary get group => GroupSummary(
        id: 'group',
        name: 'テストグループ',
        ownerUserId: role == GroupRole.owner ? 'viewer' : 'owner',
        type: GroupType.other,
        eventCreatePolicy: 'owner',
        role: role,
      );

  GroupEventSummary get event => GroupEventSummary(
        eventId: 'event',
        groupId: 'group',
        title: '日またぎ予定',
        // The UI presents local time; keep the overnight fixture local on CI too.
        startAt: DateTime(2026, 10, 1, 23).toUtc(),
        endAt: DateTime(2026, 10, 2, 1).toUtc(),
        createdBy: 'viewer',
        version: 1,
      );

  @override
  Future<List<GroupSummary>> listGroups() async => [group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => [
        GroupMemberSummary(
          groupId: groupId,
          userId: 'viewer',
          displayName: '閲覧者',
          role: role,
        ),
      ];

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async => [];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      [event];

  @override
  Future<List<GroupEventRsvp>> listGroupEventRsvps(String eventId) async =>
      const [
        GroupEventRsvp(userId: 'viewer', status: 'unanswered', updatedAt: null),
      ];

  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) async =>
      GroupEventContent(
        eventId: eventId,
        groupId: 'group',
        generation: 'generation-1',
        rsvps: const [
          GroupEventRsvp(
              userId: 'viewer', status: 'unanswered', updatedAt: null)
        ],
        comments: withUgc
            ? [
                GroupEventComment(
                    commentId: 'comment',
                    eventId: eventId,
                    authorUserId: 'viewer',
                    body: '既存コメント',
                    createdAt: DateTime.utc(2026, 10, 1),
                    updatedAt: DateTime.utc(2026, 10, 1),
                    version: 1)
              ]
            : const [],
        reactions: withUgc
            ? const [
                GroupEventReaction(
                    reaction: 'ok', reactionCount: 1, reactedByMe: false)
              ]
            : const [],
      );

  @override
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  }) async =>
      contentGenerationValid;

  @override
  Future<List<GroupEventComment>> listGroupEventComments(
          String eventId) async =>
      withUgc
          ? [
              GroupEventComment(
                  commentId: 'comment',
                  eventId: eventId,
                  authorUserId: 'viewer',
                  body: '既存コメント',
                  createdAt: DateTime.utc(2026, 10, 1),
                  updatedAt: DateTime.utc(2026, 10, 1),
                  version: 1)
            ]
          : [];

  @override
  Future<List<GroupEventReaction>> listGroupEventReactions(
          String eventId) async =>
      withUgc
          ? [
              const GroupEventReaction(
                  reaction: 'ok', reactionCount: 1, reactedByMe: false)
            ]
          : [];

  @override
  Future<GroupEventComment> createGroupEventComment(
      {required String eventId, required String body}) async {
    commentBodies.add(body);
    return GroupEventComment(
        commentId: 'created',
        eventId: eventId,
        authorUserId: 'viewer',
        body: body,
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        version: 1);
  }

  @override
  Future<GroupEventComment> updateGroupEventComment({
    required String commentId,
    required String body,
    required int expectedVersion,
  }) async {
    if (commentConflictOnUpdate) {
      throw const ConflictError('コメントが更新されています。最新版を確認して再編集してください。');
    }
    return GroupEventComment(
        commentId: commentId,
        eventId: 'event',
        authorUserId: 'viewer',
        body: body,
        createdAt: DateTime.utc(2026, 10, 1),
        updatedAt: DateTime.utc(2026, 10, 1),
        version: expectedVersion + 1);
  }

  @override
  Future<void> setGroupEventReaction(
      {required String eventId, required String reaction}) async {}

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
  }

  @override
  Future<GroupSummary> createGroup({
    required String name,
    required String type,
    String? description,
    required String eventCreatePolicy,
  }) async {
    createdNames.add(name);
    return group;
  }

  @override
  Future<GroupEventSummary> updateGroupEvent({
    required String eventId,
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? location,
    String? description,
    required int expectedVersion,
  }) async {
    if (conflictOnUpdate) {
      throw const ConflictError('予定が更新されています。最新版を確認して再編集してください。');
    }
    return GroupEventSummary(
      eventId: eventId,
      groupId: 'group',
      title: title,
      startAt: startAt,
      endAt: endAt,
      location: location,
      description: description,
      createdBy: 'viewer',
      version: expectedVersion + 1,
    );
  }
}
