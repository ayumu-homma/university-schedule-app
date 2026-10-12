import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'old member-removal confirmation cannot remove after viewer switch',
      (tester) async {
    final harness = await _openGroupDetail(tester);
    final memberTile = find.byKey(const Key('group-member-peer'));
    final memberMenu = tester.widget<PopupMenuButton<String>>(find.descendant(
      of: memberTile,
      matching: find.byType(PopupMenuButton<String>),
    ));
    memberMenu.onSelected!('remove');
    await tester.pumpAndSettle();
    expect(find.text('メンバーを削除しますか？'), findsOneWidget);
    final confirmRemoval = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '実行'))
        .onPressed!;

    harness.repository.viewerRole = GroupRole.member;
    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    expect(find.text('メンバーを削除しますか？'), findsNothing);
    expect(find.text('ログイン状態が変わりました'), findsOneWidget);
    confirmRemoval();
    await tester.pumpAndSettle();
    expect(harness.repository.removeMemberCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'old group-deletion confirmation cannot delete after viewer switch',
      (tester) async {
    final harness = await _openGroupDetail(tester);
    final deleteButton = tester.widget<OutlinedButton>(find.widgetWithText(
      OutlinedButton,
      'グループを削除',
      skipOffstage: false,
    ));
    deleteButton.onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('グループを削除しますか？'), findsOneWidget);
    final confirmDeletion = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '削除'))
        .onPressed!;

    harness.repository.viewerRole = GroupRole.member;
    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    expect(find.text('グループを削除しますか？'), findsNothing);
    expect(find.text('ログイン状態が変わりました'), findsOneWidget);
    confirmDeletion();
    await tester.pumpAndSettle();
    expect(harness.repository.deleteGroupCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale owner menu selection cannot change a member role',
      (tester) async {
    final harness = await _openGroupDetail(tester);
    final memberTile = find.byKey(const Key('group-member-peer'));
    final memberMenu = tester.widget<PopupMenuButton<String>>(find.descendant(
      of: memberTile,
      matching: find.byType(PopupMenuButton<String>),
    ));

    harness.repository.viewerRole = GroupRole.member;
    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    memberMenu.onSelected!('admin');
    await tester.pumpAndSettle();
    expect(harness.repository.changeRoleCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

Future<_GroupHarness> _openGroupDetail(WidgetTester tester) async {
  final sessionState = StateProvider<AppAuthSession?>(
    (ref) => const AppAuthSession(userId: 'viewer'),
  );
  final repository = _MembershipRepository();
  final container = ProviderContainer(overrides: [
    currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
    groupRepositoryProvider.overrideWithValue(repository),
    friendsControllerProvider.overrideWith(_KnownEmptyFriendsController.new),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
  ));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('group-member-peer')),
    180,
  );
  await tester.pumpAndSettle();
  return _GroupHarness(sessionState, repository, container);
}

class _GroupHarness {
  const _GroupHarness(this.sessionState, this.repository, this.container);

  final StateProvider<AppAuthSession?> sessionState;
  final _MembershipRepository repository;
  final ProviderContainer container;
}

class _KnownEmptyFriendsController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'viewer',
      );
}

class _MembershipRepository extends UnavailableGroupRepository {
  GroupRole viewerRole = GroupRole.owner;
  int removeMemberCalls = 0;
  int deleteGroupCalls = 0;
  int changeRoleCalls = 0;

  GroupSummary get _group => GroupSummary(
        id: 'group',
        name: 'Group A',
        ownerUserId: 'viewer',
        type: GroupType.other,
        role: viewerRole,
      );

  @override
  Future<List<GroupSummary>> listGroups() async => [_group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => _group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => [
        GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: 'Viewer A',
          role: viewerRole,
        ),
        const GroupMemberSummary(
          groupId: 'group',
          userId: 'peer',
          displayName: 'Peer',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) async => const {};

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async =>
      const [];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      const [];

  @override
  Future<void> removeMember(String groupId, String userId) async {
    removeMemberCalls++;
  }

  @override
  Future<void> changeMemberRole(
      String groupId, String userId, GroupRole role) async {
    changeRoleCalls++;
  }

  @override
  Future<void> deleteGroup(String groupId) async {
    deleteGroupCalls++;
  }
}
