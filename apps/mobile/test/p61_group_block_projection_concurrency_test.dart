import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';

void main() {
  test('stale projection cannot replace newer success or newer unknown state',
      () async {
    final repository = _ConcurrentProjectionRepository();
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

    final staleEmpty = Completer<Set<String>>();
    final latestBlocked = Completer<Set<String>>();
    repository.replies.addAll([staleEmpty.future, latestBlocked.future]);
    final staleRequest = controller.refreshMemberBlockStatus('group');
    final latestRequest = controller.refreshMemberBlockStatus('group');
    latestBlocked.complete({'blocked-peer'});
    await latestRequest;
    staleEmpty.complete(<String>{});
    await staleRequest;

    var state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusLoaded, isTrue);
    expect(state.blockedMemberUserIds, {'blocked-peer'});

    final staleEmptyAfterFailure = Completer<Set<String>>();
    final latestFailure = Completer<Set<String>>();
    repository.replies
      ..add(staleEmptyAfterFailure.future)
      ..add(latestFailure.future);
    final staleAfterFailure = controller.refreshMemberBlockStatus('group');
    final failedLatest = controller.refreshMemberBlockStatus('group');
    latestFailure.completeError(StateError('synthetic projection failure'));
    await failedLatest;
    staleEmptyAfterFailure.complete(<String>{});
    await staleAfterFailure;

    state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusLoaded, isFalse);
    expect(state.blockedMemberUserIds, isEmpty);
  });
}

class _ConcurrentProjectionRepository extends UnavailableGroupRepository {
  final List<Future<Set<String>>> replies = [];
  bool _opened = false;

  @override
  Future<List<GroupSummary>> listGroups() async => const [];

  @override
  Future<GroupSummary> getGroup(String groupId) async => const GroupSummary(
        id: 'group',
        name: 'Synthetic group',
        ownerUserId: 'viewer',
        type: GroupType.other,
        role: GroupRole.member,
      );

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => const [
        GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: 'Viewer',
          role: GroupRole.member,
        ),
        GroupMemberSummary(
          groupId: 'group',
          userId: 'blocked-peer',
          displayName: 'Peer',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) {
    if (!_opened) {
      _opened = true;
      return Future.value(<String>{});
    }
    return replies.removeAt(0);
  }

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      const [];
}
