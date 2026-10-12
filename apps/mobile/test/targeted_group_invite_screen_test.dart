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
import 'package:university_schedule_mobile/features/notification/application/server_notification_providers.dart';
import 'package:university_schedule_mobile/features/notification/domain/server_notification.dart';
import 'package:university_schedule_mobile/features/notification/domain/server_notification_repository.dart';

void main() {
  testWidgets(
      'invite picker hides prior account friend names on account switch',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final notifications = _NotificationRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(_GroupRepository()),
      friendsControllerProvider.overrideWith(
        () => _Friends(relationships: const [
          FriendRelationship(
            id: 'private-relation',
            otherUserId: 'private-friend',
            otherDisplayName: 'Private friend from account A',
            status: FriendshipStatus.accepted,
          ),
        ]),
      ),
      serverNotificationRepositoryProvider.overrideWithValue(notifications),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-targeted-invite')));
    await tester.pumpAndSettle();
    expect(find.text('Private friend from account A'), findsOneWidget);

    container.read(sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('Private friend from account A'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('ログイン状態が変わりました'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: changedDialog, matching: find.text('閉じる')),
    );
    await tester.pumpAndSettle();
    expect(notifications.inviteeUserId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'group invite picker omits blocked users and retains unrelated friends',
      (tester) async {
    final notifications = _NotificationRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentAuthSessionProvider
            .overrideWithValue(const AppAuthSession(userId: 'viewer')),
        groupRepositoryProvider.overrideWithValue(_GroupRepository()),
        friendsControllerProvider.overrideWith(() => _Friends(
              relationships: const [
                FriendRelationship(
                  id: 'blocked-relation',
                  otherUserId: 'blocked-target',
                  otherDisplayName: 'Blocked A',
                  status: FriendshipStatus.accepted,
                ),
                FriendRelationship(
                  id: 'available-relation',
                  otherUserId: 'available-target',
                  otherDisplayName: 'Available B',
                  status: FriendshipStatus.accepted,
                ),
              ],
              blockedUserIds: const {'blocked-target'},
            )),
        serverNotificationRepositoryProvider.overrideWithValue(notifications),
      ],
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-targeted-invite')));
    await tester.pumpAndSettle();
    expect(find.text('Blocked A'), findsNothing);
    expect(find.text('Available B'), findsOneWidget);

    await tester.tap(find.byKey(
      const Key('targeted-invite-friend-available-target'),
    ));
    await tester.pumpAndSettle();
    expect(notifications.inviteeUserId, 'available-target');
    expect(notifications.inviteeUserId, isNot('blocked-target'));
  });

  testWidgets(
      'group admin sends a consent-based invitation to an accepted friend',
      (tester) async {
    final notifications = _NotificationRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentAuthSessionProvider
            .overrideWithValue(const AppAuthSession(userId: 'viewer')),
        groupRepositoryProvider.overrideWithValue(_GroupRepository()),
        friendsControllerProvider.overrideWith(_Friends.new),
        serverNotificationRepositoryProvider.overrideWithValue(notifications),
      ],
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-targeted-invite')));
    await tester.pumpAndSettle();
    expect(find.text('友だちを招待'), findsNWidgets(2));
    expect(find.text('招待を受けた友だちは、承諾してから参加します。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('targeted-invite-friend-friend')));
    await tester.pumpAndSettle();

    expect(notifications.groupId, 'group');
    expect(notifications.inviteeUserId, 'friend');
    expect(notifications.expiresAt!.isAfter(DateTime.now()), isTrue);
    expect(
        notifications.expiresAt!
            .isBefore(DateTime.now().add(const Duration(days: 4))),
        isTrue);
    expect(notifications.inviteeUserId, isNotNull);
  });
}

class _Friends extends FriendsController {
  _Friends({
    this.relationships = const [
      FriendRelationship(
        id: 'relation',
        otherUserId: 'friend',
        otherDisplayName: 'さくら',
        status: FriendshipStatus.accepted,
      ),
    ],
    this.blockedUserIds = const {},
  });

  final List<FriendRelationship> relationships;
  final Set<String> blockedUserIds;

  @override
  Future<FriendState> build() async => FriendState(
        relationships: relationships,
        blockedUserIds: blockedUserIds,
      );

  @override
  Future<void> refreshRelationships() async {}
}

class _GroupRepository extends UnavailableGroupRepository {
  @override
  Future<GroupSummary> getGroup(String groupId) async => const GroupSummary(
        id: 'group',
        name: 'ゼミ',
        ownerUserId: 'viewer',
        type: GroupType.other,
        role: GroupRole.owner,
      );

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => const [
        GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: '本人',
          role: GroupRole.owner,
        ),
      ];

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async =>
      const [];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      const [];
}

class _NotificationRepository implements ServerNotificationRepository {
  String? groupId;
  String? inviteeUserId;
  DateTime? expiresAt;

  @override
  Future<void> inviteFriendToGroup({
    required String groupId,
    required String inviteeUserId,
    required DateTime expiresAt,
  }) async {
    this.groupId = groupId;
    this.inviteeUserId = inviteeUserId;
    this.expiresAt = expiresAt;
  }

  @override
  Future<List<ServerNotification>> list({
    DateTime? before,
    String? beforeId,
    int limit = 30,
  }) async =>
      const [];

  @override
  Future<List<TargetedGroupInvitation>> listInvitations() async => const [];

  @override
  Future<bool> markRead(String inboxId) async => true;

  @override
  Future<void> respondToInvitation(String invitationId,
      {required bool accept}) async {}
}
