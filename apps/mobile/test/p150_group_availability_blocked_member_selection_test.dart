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

  testWidgets('blocked group member is not selected or searchable',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final repository = _P150GroupRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(repository),
      friendsControllerProvider.overrideWith(_P150FriendsController.new),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-availability-search')));
    await tester.pumpAndSettle();

    expect(find.text('ブロック中のメンバー'), findsWidgets);
    final blockedTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'ブロック中のメンバー').last,
    );
    expect(blockedTile.value, isFalse);
    expect(blockedTile.onChanged, isNull);
    final viewerTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Viewer').last,
    );
    expect(viewerTile.value, isTrue);

    await tester.tap(find.text('検索'));
    await tester.pumpAndSettle();
    expect(repository.availabilityCalls, 1);
    expect(repository.memberIds, ['viewer']);
    expect(find.text('共通空き時間'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
  });
}

class _P150FriendsController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'viewer',
      );
}

class _P150GroupRepository extends UnavailableGroupRepository {
  static const _group = GroupSummary(
    id: 'group',
    name: 'P150 group',
    ownerUserId: 'viewer',
    type: GroupType.other,
    role: GroupRole.owner,
  );

  int availabilityCalls = 0;
  List<String> memberIds = const [];

  @override
  Future<List<GroupSummary>> listGroups() async => const [_group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => _group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => const [
        GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: 'Viewer',
          role: GroupRole.owner,
        ),
        GroupMemberSummary(
          groupId: 'group',
          userId: 'peer',
          displayName: 'Private blocked peer',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) async => {'peer'};

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async =>
      const [];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      const [];

  @override
  Future<GroupAvailabilityResult> findGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required int minimumDurationMinutes,
  }) async {
    availabilityCalls++;
    this.memberIds = memberIds;
    return GroupAvailabilityResult(
      rows: const [],
      memberIds: memberIds,
      queryId: 'p150-query',
      generation: 'p150-generation',
    );
  }

  @override
  Future<bool> validateGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required String generation,
  }) async =>
      true;
}
