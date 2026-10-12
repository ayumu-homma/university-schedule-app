import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';

void main() {
  test('availability result is published only after generation validation',
      () async {
    final repository = _AvailabilityRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);

    final controller = container.read(groupsControllerProvider.notifier);
    expect(
        await controller.searchGroupAvailability(
            groupId: 'group',
            memberIds: const ['viewer', 'member-a'],
            rangeStart: DateTime.utc(2026, 10, 1, 9),
            rangeEnd: DateTime.utc(2026, 10, 1, 18),
            minimumDurationMinutes: 60),
        isTrue);
    final result = container.read(groupsControllerProvider).requireValue;
    expect(result.availabilityResult?.queryId, 'query-1');
    expect(result.availabilityResult?.memberIds, ['viewer', 'member-a']);
    expect(result.availabilityWindows, isNotEmpty);
    expect(repository.validatedGeneration, 'generation-1');
  });

  test('generation or membership failure never becomes empty-success',
      () async {
    final repository = _AvailabilityRepository()..validationResult = false;
    final container = _container(repository);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);

    final controller = container.read(groupsControllerProvider.notifier);
    expect(
        await controller.searchGroupAvailability(
            groupId: 'group',
            memberIds: const ['viewer', 'member-a'],
            rangeStart: DateTime.utc(2026, 10, 1, 9),
            rangeEnd: DateTime.utc(2026, 10, 1, 18),
            minimumDurationMinutes: 60),
        isFalse);
    final state = container.read(groupsControllerProvider).requireValue;
    expect(state.availabilityResult, isNull);
    expect(state.availabilityWindows, isEmpty);
    expect(state.errorMessage, isNotNull);
  });

  test('opening a group clears the bounded availability lease', () async {
    final repository = _AvailabilityRepository();
    final container = _container(repository);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);
    final controller = container.read(groupsControllerProvider.notifier);
    await controller.searchGroupAvailability(
        groupId: 'group',
        memberIds: const ['viewer', 'member-a'],
        rangeStart: DateTime.utc(2026, 10, 1, 9),
        rangeEnd: DateTime.utc(2026, 10, 1, 18),
        minimumDurationMinutes: 60);
    expect(
        container
            .read(groupsControllerProvider)
            .requireValue
            .availabilityResult,
        isNotNull);

    await controller.open('group');
    expect(
        container
            .read(groupsControllerProvider)
            .requireValue
            .availabilityResult,
        isNull);
    expect(
        container
            .read(groupsControllerProvider)
            .requireValue
            .availabilityWindows,
        isEmpty);
  });
}

ProviderContainer _container(_AvailabilityRepository repository) =>
    ProviderContainer(overrides: [
      currentAuthSessionProvider
          .overrideWithValue(const AppAuthSession(userId: 'viewer')),
      groupRepositoryProvider.overrideWithValue(repository),
    ]);

class _AvailabilityRepository extends UnavailableGroupRepository {
  bool validationResult = true;
  String? validatedGeneration;

  @override
  Future<List<GroupSummary>> listGroups() async => const [];

  @override
  Future<GroupSummary> getGroup(String groupId) async => const GroupSummary(
      id: 'group',
      name: 'Group',
      ownerUserId: 'viewer',
      type: GroupType.other,
      role: GroupRole.owner);

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => const [
        GroupMemberSummary(
            groupId: 'group',
            userId: 'viewer',
            displayName: 'Viewer',
            role: GroupRole.owner),
        GroupMemberSummary(
            groupId: 'group',
            userId: 'member-a',
            displayName: 'Member A',
            role: GroupRole.member),
      ];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      const [];

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async =>
      const [];

  @override
  Future<GroupAvailabilityResult> findGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required int minimumDurationMinutes,
  }) async {
    return GroupAvailabilityResult(rows: [
      GroupAvailabilityRow(
          memberId: 'group',
          startAt: DateTime.utc(2026, 10, 1, 12),
          endAt: DateTime.utc(2026, 10, 1, 13),
          visibility: 'BUSY_ONLY')
    ], memberIds: memberIds, queryId: 'query-1', generation: 'generation-1');
  }

  @override
  Future<bool> validateGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required String generation,
  }) async {
    validatedGeneration = generation;
    return validationResult;
  }
}
