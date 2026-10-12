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
  testWidgets('availability form requires self and exposes bounded controls',
      (tester) async {
    final repository = _ScreenAvailabilityRepository(fail: true);
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('group-availability-search')));
    await tester.pumpAndSettle();
    expect(find.text('対象メンバー（本人は必須）'), findsOneWidget);
    expect(find.text('Viewer'), findsAtLeastNWidgets(1));
    expect(find.widgetWithText(TextField, '開始(分)'), findsOneWidget);
    expect(find.widgetWithText(TextField, '終了(分)'), findsOneWidget);
    expect(find.widgetWithText(DropdownButtonFormField<int>, '必要時間'),
        findsOneWidget);
    await tester.tap(find.text('検索'));
    await tester.pumpAndSettle();

    // A denied/failed query must not open the candidate dialog or look like an
    // empty successful result.
    expect(find.text('共通空き時間'), findsNothing);
    expect(repository.requestedMemberIds, ['viewer', 'member-a']);
  });
}

Widget _app(_ScreenAvailabilityRepository repository) => ProviderScope(
      overrides: [
        currentAuthSessionProvider
            .overrideWithValue(const AppAuthSession(userId: 'viewer')),
        groupRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    );

class _ScreenAvailabilityRepository extends UnavailableGroupRepository {
  _ScreenAvailabilityRepository({required this.fail});
  final bool fail;
  List<String>? requestedMemberIds;

  GroupSummary get group => const GroupSummary(
      id: 'group',
      name: 'Group',
      ownerUserId: 'viewer',
      type: GroupType.other,
      role: GroupRole.owner);

  @override
  Future<GroupSummary> getGroup(String groupId) async => group;

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
  Future<Set<String>> listBlockedGroupMembers(String groupId) async => const {};

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
    requestedMemberIds = memberIds;
    if (fail) throw const NetworkError('denied');
    return GroupAvailabilityResult(
        rows: const [],
        memberIds: memberIds,
        queryId: 'query-1',
        generation: 'generation-1');
  }

  @override
  Future<bool> validateGroupAvailability({
    required String groupId,
    required List<String> memberIds,
    required String generation,
  }) async =>
      true;
}
