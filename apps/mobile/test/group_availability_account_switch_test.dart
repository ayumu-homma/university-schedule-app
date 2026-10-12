import 'dart:async';

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

  testWidgets('availability criteria are discarded after viewer changes',
      (tester) async {
    final harness = await _openAvailabilityDialog(tester);
    expect(find.text('Private peer from account A'), findsWidgets);

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('Private peer from account A'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.byType(TextField),
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

    if (find.text('検索').evaluate().isNotEmpty) {
      await tester.tap(find.text('検索'));
      await tester.pumpAndSettle();
    }
    expect(harness.repository.availabilityCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'availability date picker is dismissed safely after viewer change',
      (tester) async {
    final harness = await _openAvailabilityDialog(tester);
    await tester.tap(find.byIcon(Icons.calendar_today).first);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsNothing);
    final openNotices = find.text('ログイン状態が変わりました');
    expect(openNotices, findsWidgets);
    while (find.text('閉じる').evaluate().isNotEmpty) {
      await tester.tap(find.text('閉じる').last);
      await tester.pumpAndSettle();
    }
    expect(harness.repository.availabilityCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'viewer change while searching skips stale generation validation and result',
      (tester) async {
    final harness = await _openAvailabilityDialog(tester);
    final pendingResult = Completer<GroupAvailabilityResult>();
    harness.repository.pendingAvailabilityResult = pendingResult;

    await tester.tap(find.text('検索'));
    await tester.pumpAndSettle();
    expect(harness.repository.availabilityCalls, 1);
    expect(harness.repository.validationCalls, 0);

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    pendingResult.complete(const GroupAvailabilityResult(
      rows: [],
      memberIds: ['viewer', 'peer'],
      queryId: 'synthetic-query',
      generation: 'synthetic-generation',
    ));
    await tester.pumpAndSettle();

    expect(harness.repository.validationCalls, 0);
    expect(find.text('共通空き時間'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<_AvailabilityHarness> _openAvailabilityDialog(
    WidgetTester tester) async {
  final sessionState = StateProvider<AppAuthSession?>(
    (ref) => const AppAuthSession(userId: 'viewer'),
  );
  final repository = _AvailabilityGroupRepository();
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
  await tester.tap(find.byKey(const Key('group-availability-search')));
  await tester.pumpAndSettle();
  return _AvailabilityHarness(sessionState, repository, container);
}

class _AvailabilityHarness {
  const _AvailabilityHarness(
      this.sessionState, this.repository, this.container);

  final StateProvider<AppAuthSession?> sessionState;
  final _AvailabilityGroupRepository repository;
  final ProviderContainer container;
}

class _KnownEmptyFriendsController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'viewer',
      );
}

class _AvailabilityGroupRepository extends UnavailableGroupRepository {
  static const _group = GroupSummary(
    id: 'group',
    name: 'Group A',
    ownerUserId: 'viewer',
    type: GroupType.other,
    role: GroupRole.owner,
  );

  int availabilityCalls = 0;
  int validationCalls = 0;
  Completer<GroupAvailabilityResult>? pendingAvailabilityResult;

  @override
  Future<List<GroupSummary>> listGroups() async => const [_group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => _group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => const [
        GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: 'Viewer A',
          role: GroupRole.owner,
        ),
        GroupMemberSummary(
          groupId: 'group',
          userId: 'peer',
          displayName: 'Private peer from account A',
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
  Future<GroupAvailabilityResult> findGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required int minimumDurationMinutes,
  }) async {
    availabilityCalls++;
    final pending = pendingAvailabilityResult;
    if (pending != null) return pending.future;
    return GroupAvailabilityResult(
      rows: const [],
      memberIds: memberIds,
      queryId: 'synthetic-query',
      generation: 'synthetic-generation',
    );
  }

  @override
  Future<bool> validateGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required String generation,
  }) async =>
      _recordValidation();

  Future<bool> _recordValidation() async {
    validationCalls++;
    return true;
  }
}
