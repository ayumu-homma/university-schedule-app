// ignore_for_file: curly_braces_in_flow_control_structures, use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/auth_models.dart';
import '../../friends/application/friend_providers.dart';
import '../../friends/domain/friend_models.dart';
import '../../notification/application/server_notification_providers.dart';
import '../application/group_providers.dart';
import '../domain/group_models.dart';

bool _blockStatusKnown({
  required GroupState? state,
  required String? groupId,
  required String? viewerId,
}) =>
    viewerId != null &&
    groupId != null &&
    state != null &&
    state.blockedMemberStatusLoaded &&
    state.blockedMemberStatusGroupId == groupId &&
    state.blockedMemberStatusViewerUserId == viewerId;

String _visibilityLabel(String visibility) => switch (visibility) {
      'PRIVATE' => '自分のみ',
      'BUSY_ONLY' => '予定あり',
      'TITLE_ONLY' => 'タイトルのみ',
      'FULL' => '詳細を共有',
      _ => '未設定',
    };

Set<String> _blockedGroupMemberIds(
  GroupState? state,
  FriendState? friendState, {
  required String? viewerId,
}) {
  final blockedUserIds = <String>{...?state?.blockedMemberUserIds};
  if (viewerId != null &&
      friendState?.blockStatusLoaded == true &&
      friendState?.blockStatusViewerUserId == viewerId) {
    blockedUserIds.addAll(friendState!.blockedUserIds);
  }
  return blockedUserIds;
}

String _memberDisplayLabel(
  GroupMemberSummary member, {
  required String? viewerId,
  required bool blockStatusKnown,
  required Set<String> blockedUserIds,
}) {
  final shouldHideIdentity = member.userId != viewerId &&
      (!blockStatusKnown || blockedUserIds.contains(member.userId));
  return shouldHideIdentity ? 'ブロック中のメンバー' : member.displayName;
}

String _commentAuthorLabel({
  required String authorUserId,
  required String? viewerId,
  required bool blockStatusKnown,
  required Set<String> blockedUserIds,
}) {
  if (authorUserId == viewerId) return '自分';
  if (!blockStatusKnown || blockedUserIds.contains(authorUserId)) {
    return 'ブロック中のメンバー';
  }
  return 'メンバー';
}

class GroupListTab extends ConsumerWidget {
  const GroupListTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupsControllerProvider);
    final state = async.valueOrNull ?? const GroupState();
    if (async.isLoading && state.groups.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null && state.groups.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'グループを読み込めません',
        message: state.errorMessage!,
        action: OutlinedButton(
          onPressed: () =>
              ref.read(groupsControllerProvider.notifier).refresh(),
          child: const Text('再試行'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(groupsControllerProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: state.mutating ? null : () => _create(context, ref),
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('グループを作成'),
          ),
          const SizedBox(height: 12),
          if (state.groups.isEmpty)
            const EmptyState(
              icon: Icons.groups_outlined,
              title: 'グループはまだありません',
              message: '授業・ゼミ・サークルなどの共有グループを作成できます。',
            )
          else
            ...state.groups.map(
              (group) => Card(
                child: ListTile(
                  key: Key('group-${group.id}'),
                  leading: const Icon(Icons.groups_outlined),
                  title: Text(group.name),
                  subtitle: Text('${group.type.name} · ${group.role.name}'),
                  onTap: () => context.push('/group/${group.id}'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final draft = await showDialog<_GroupDraft>(
        context: context,
        builder: (_) => _AccountBoundDialog(
            viewerId: viewerId,
            child: const _GroupDraftDialog(title: 'グループを作成')));
    if (draft == null ||
        draft.name.isEmpty ||
        !context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewerId) return;
    await ref.read(groupsControllerProvider.notifier).create(
          name: draft.name,
          type: draft.type,
          description: draft.description,
          eventCreatePolicy: draft.policy,
        );
  }
}

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({this.groupId, this.inviteToken, super.key});
  final String? groupId;
  final String? inviteToken;
  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen>
    with WidgetsBindingObserver {
  String? _requestedGroupOpenViewerId;
  String? _requestedGroupOpenGroupId;
  int _groupOpenAttempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_load);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.groupId != null) {
      _load(force: true);
    }
  }

  @override
  void didUpdateWidget(covariant GroupDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId ||
        oldWidget.inviteToken != widget.inviteToken) {
      _requestedGroupOpenViewerId = null;
      _requestedGroupOpenGroupId = null;
      _load(force: true);
    }
  }

  Future<void> _load({bool force = false}) async {
    final controller = ref.read(groupsControllerProvider.notifier);
    if (widget.inviteToken != null) {
      await controller.preview(widget.inviteToken!);
    } else if (widget.groupId != null) {
      final viewerId = ref.read(currentAuthSessionProvider)?.userId;
      if (viewerId != null) {
        final state = ref.read(groupsControllerProvider).valueOrNull;
        if (!force &&
            state?.selected?.id == widget.groupId &&
            _blockStatusKnown(
              state: state,
              groupId: widget.groupId,
              viewerId: viewerId,
            )) {
          return;
        }
        _requestGroupOpen(viewerId, widget.groupId!, force: force);
      }
    }
  }

  void _requestGroupOpen(String viewerId, String groupId,
      {bool force = false}) {
    if (!force &&
        _requestedGroupOpenViewerId == viewerId &&
        _requestedGroupOpenGroupId == groupId) {
      return;
    }
    _requestedGroupOpenViewerId = viewerId;
    _requestedGroupOpenGroupId = groupId;
    final attempt = ++_groupOpenAttempt;
    Future.microtask(() async {
      if (!mounted ||
          widget.groupId != groupId ||
          ref.read(currentAuthSessionProvider)?.userId != viewerId) {
        if (attempt == _groupOpenAttempt) {
          _requestedGroupOpenViewerId = null;
          _requestedGroupOpenGroupId = null;
        }
        return;
      }
      final opened =
          await ref.read(groupsControllerProvider.notifier).open(groupId);
      if (!opened && attempt == _groupOpenAttempt) {
        _requestedGroupOpenViewerId = null;
        _requestedGroupOpenGroupId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppAuthSession?>(currentAuthSessionProvider, (previous, next) {
      if (widget.inviteToken != null ||
          widget.groupId == null ||
          next == null ||
          previous?.userId == next.userId) {
        return;
      }
      _requestGroupOpen(next.userId, widget.groupId!, force: true);
    });
    ref.listen<AsyncValue<FriendState>>(friendsControllerProvider,
        (previous, next) {
      final before = previous?.valueOrNull;
      final after = next.valueOrNull;
      final viewerId = ref.read(currentAuthSessionProvider)?.userId;
      if (before == null ||
          after == null ||
          viewerId == null ||
          before.blockStatusViewerUserId != viewerId ||
          after.blockStatusViewerUserId != viewerId ||
          (before.blockStatusLoaded == after.blockStatusLoaded &&
              before.blockedUserIds.length == after.blockedUserIds.length &&
              before.blockedUserIds.containsAll(after.blockedUserIds))) {
        return;
      }
      final groupId =
          ref.read(groupsControllerProvider).valueOrNull?.selected?.id;
      if (groupId != null) {
        Future.microtask(() => ref
            .read(groupsControllerProvider.notifier)
            .refreshMemberBlockStatus(groupId));
      }
    });
    final async = ref.watch(groupsControllerProvider);
    final state = async.valueOrNull ?? const GroupState();
    final viewerId = ref.watch(currentAuthSessionProvider)?.userId;
    if (widget.inviteToken == null &&
        widget.groupId != null &&
        viewerId != null &&
        (state.selected?.id != widget.groupId ||
            !state.blockedMemberStatusLoaded ||
            state.blockedMemberStatusViewerUserId != viewerId)) {
      _requestGroupOpen(viewerId, widget.groupId!);
    }
    final friendsAsync = ref.watch(friendsControllerProvider);
    final friendState = friendsAsync.valueOrNull;
    final group = state.selected?.id == widget.groupId ? state.selected : null;
    final blockStatusKnown = _blockStatusKnown(
      state: state,
      groupId: group?.id,
      viewerId: viewerId,
    );
    final blockedUserIds =
        _blockedGroupMemberIds(state, friendState, viewerId: viewerId);
    if (widget.inviteToken != null) return _invite(context, state);
    final child = state.loading && group == null
        ? const Center(child: CircularProgressIndicator())
        : group == null
            ? EmptyState(
                icon: Icons.error_outline,
                title: 'グループを読み込めません',
                message: state.errorMessage ?? '権限または通信を確認してください。',
                action:
                    OutlinedButton(onPressed: _load, child: const Text('再試行')),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                      child: ListTile(
                          leading: const Icon(Icons.groups),
                          title: Text(group.name),
                          subtitle: Text(group.description ?? 'グループ共有'))),
                  Card(
                    child: ListTile(
                      key: const Key('group-default-visibility'),
                      leading: const Icon(Icons.visibility_outlined),
                      title: const Text('共有予定の既定公開範囲'),
                      subtitle: Text(_visibilityLabel(group.defaultVisibility)),
                      trailing: group.role == GroupRole.owner ||
                              group.role == GroupRole.admin
                          ? IconButton(
                              key: const Key('edit-group-default-visibility'),
                              tooltip: '公開範囲を変更',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: state.mutating
                                  ? null
                                  : () => _editGroupDefaultVisibility(
                                      context, group),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('グループ予定',
                            style: Theme.of(context).textTheme.titleMedium),
                        if (_canCreateEvent(group))
                          IconButton(
                              key: const Key('group-event-create'),
                              tooltip: '予定を作成',
                              icon: const Icon(Icons.add),
                              onPressed: () => _createEvent(context, group.id)),
                      ]),
                  OutlinedButton.icon(
                      key: const Key('group-availability-search'),
                      icon: const Icon(Icons.schedule_outlined),
                      label: const Text('メンバーの共通空き時間を検索'),
                      onPressed: state.loading
                          ? null
                          : () => _searchAvailability(context, group, state)),
                  if (state.eventDraft != null)
                    Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: ListTile(
                            title: const Text('予定が更新されています'),
                            subtitle: const Text('最新版を確認してから再編集してください。'),
                            trailing: TextButton(
                                onPressed: () {
                                  final draft = state.eventDraft!;
                                  final matches = state.events
                                      .where((e) => e.eventId == draft.eventId);
                                  final viewerId = ref
                                      .read(currentAuthSessionProvider)
                                      ?.userId;
                                  if (matches.isNotEmpty && viewerId != null) {
                                    _editEvent(context, matches.first, draft,
                                        viewerId: viewerId);
                                  }
                                },
                                child: const Text('再編集')))),
                  if (state.events.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(12), child: Text('予定はまだありません。'))
                  else
                    ...state.events.map((event) => ListTile(
                          key: Key('group-event-${event.eventId}'),
                          title: Text(event.title),
                          subtitle:
                              Text(_eventRange(event.startAt, event.endAt)),
                          onTap: () => _showEvent(context, event, group),
                        )),
                  const SizedBox(height: 16),
                  Text('メンバー', style: Theme.of(context).textTheme.titleMedium),
                  if (group.role == GroupRole.owner ||
                      group.role == GroupRole.admin)
                    OutlinedButton.icon(
                      key: const Key('group-targeted-invite'),
                      icon: const Icon(Icons.person_add_alt_1_outlined),
                      label: const Text('友だちを招待'),
                      onPressed: state.mutating
                          ? null
                          : () => _inviteFriend(context, group.id, state),
                    ),
                  ...state.members.map((m) => _memberTile(context, group, m,
                      viewerId: viewerId,
                      blockStatusKnown: blockStatusKnown,
                      blockedUserIds: blockedUserIds)),
                  if (group.role == GroupRole.owner ||
                      group.role == GroupRole.admin) ...[
                    const SizedBox(height: 12),
                    const Text('招待'),
                    ...state.invites.map((invite) => ListTile(
                          key: Key('invite-${invite.id}'),
                          title: Text(invite.active ? '有効な招待' : '無効な招待'),
                          subtitle: Text(
                              '使用 ${invite.usedCount}/${invite.maxUses ?? '無制限'}'),
                          trailing: invite.active
                              ? IconButton(
                                  tooltip: '招待を取り消す',
                                  icon: const Icon(Icons.link_off),
                                  onPressed: () => ref
                                      .read(groupsControllerProvider.notifier)
                                      .revokeInvite(group.id, invite.id),
                                )
                              : null,
                        )),
                  ],
                  const SizedBox(height: 16),
                  if (group.role.name == 'owner' || group.role.name == 'admin')
                    FilledButton.icon(
                      onPressed: state.mutating
                          ? null
                          : () => _createInvite(context, group.id),
                      icon: const Icon(Icons.link),
                      label: const Text('招待リンクを発行してコピー'),
                    ),
                  if (group.role == GroupRole.owner ||
                      group.role == GroupRole.admin)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.edit),
                      label: const Text('グループを編集'),
                      onPressed: state.mutating
                          ? null
                          : () => _editGroup(context, group),
                    ),
                  if (group.role.name != 'owner') ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                        onPressed: state.mutating
                            ? null
                            : () => _confirmLeave(context, group.id),
                        child: const Text('グループを退出')),
                  ],
                  if (group.role.name == 'owner') ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                        onPressed: state.mutating
                            ? null
                            : () => _confirmDelete(context, group.id),
                        child: const Text('グループを削除')),
                  ],
                ],
              );
    return MvpScaffold(
        title: group?.name ?? 'グループ詳細', selectedIndex: 4, child: child);
  }

  Widget _invite(BuildContext context, GroupState state) {
    final expectedDigest = widget.inviteToken == null
        ? null
        : ref
            .read(groupsControllerProvider.notifier)
            .digestToken(widget.inviteToken!);
    final preview =
        state.previewTokenDigest == expectedDigest ? state.preview : null;
    return Scaffold(
      appBar: AppBar(title: const Text('グループ招待')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: state.loading && preview == null
            ? const Center(child: CircularProgressIndicator())
            : preview == null
                ? EmptyState(
                    icon: Icons.link_off_outlined,
                    title: '招待を確認できません',
                    message: state.errorMessage ?? 'リンクの期限または通信を確認してください。')
                : ListView(children: [
                    const Icon(Icons.group_add_outlined, size: 64),
                    const SizedBox(height: 16),
                    Text(preview.groupName,
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    Text(
                        preview.usable
                            ? '参加するとこのグループのメンバーになります。'
                            : 'この招待リンクは期限切れまたは無効です。',
                        textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    if (preview.usable)
                      FilledButton(
                          key: const Key('group-invite-confirm'),
                          onPressed:
                              state.mutating ? null : () => _join(context),
                          child: const Text('参加する')),
                    OutlinedButton(
                        onPressed: () => context.go('/shared'),
                        child: const Text('戻る'))
                  ]),
      ),
    );
  }

  Future<void> _join(BuildContext context) async {
    final group = await ref
        .read(groupsControllerProvider.notifier)
        .join(widget.inviteToken!);
    if (group != null && context.mounted) context.go('/group/${group.id}');
  }

  Widget _memberTile(
      BuildContext context, GroupSummary group, GroupMemberSummary member,
      {required String? viewerId,
      required bool blockStatusKnown,
      required Set<String> blockedUserIds}) {
    final canAdmin = group.role.name == 'owner' || group.role.name == 'admin';
    final canTransfer =
        group.role.name == 'owner' && member.role.name != 'owner';
    final canEdit = canAdmin && member.role.name != 'owner';
    return ListTile(
      key: Key('group-member-${member.userId}'),
      leading:
          Icon(member.role.name == 'owner' ? Icons.star : Icons.person_outline),
      title: Text(
        _memberDisplayLabel(
          member,
          viewerId: viewerId,
          blockStatusKnown: blockStatusKnown,
          blockedUserIds: blockedUserIds,
        ),
      ),
      subtitle: Text(member.role.name),
      trailing: canEdit || canTransfer
          ? PopupMenuButton<String>(
              onSelected: (value) async {
                if (viewerId == null ||
                    ref.read(currentAuthSessionProvider)?.userId != viewerId) {
                  return;
                }
                final controller = ref.read(groupsControllerProvider.notifier);
                if (value == 'admin')
                  await controller.changeRole(
                      group.id, member.userId, GroupRole.admin);
                if (value == 'member')
                  await controller.changeRole(
                      group.id, member.userId, GroupRole.member);
                if (value == 'remove' &&
                    await _confirmAction(context, 'メンバーを削除しますか？',
                        viewerId: viewerId) &&
                    mounted &&
                    ref.read(currentAuthSessionProvider)?.userId == viewerId)
                  await controller.removeMember(group.id, member.userId);
                if (value == 'transfer' &&
                    await _confirmAction(context, 'Ownerを移譲しますか？',
                        viewerId: viewerId) &&
                    mounted &&
                    ref.read(currentAuthSessionProvider)?.userId == viewerId)
                  await controller.transferOwnership(group.id, member.userId);
              },
              itemBuilder: (_) => [
                if (canEdit && member.role.name != 'admin')
                  const PopupMenuItem(value: 'admin', child: Text('Adminに昇格')),
                if (canEdit && member.role.name == 'admin')
                  const PopupMenuItem(
                      value: 'member', child: Text('Memberに降格')),
                if (canEdit)
                  const PopupMenuItem(value: 'remove', child: Text('メンバーを削除')),
                if (canTransfer)
                  const PopupMenuItem(
                      value: 'transfer', child: Text('Ownerを移譲')),
              ],
            )
          : null,
    );
  }

  Future<bool> _confirmAction(BuildContext context, String title,
      {required String viewerId}) async {
    final result = await showDialog<bool>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: AlertDialog(
                  title: Text(title),
                  content: const Text('この操作は取り消せません。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('キャンセル')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('実行')),
                  ]),
            ));
    return result == true &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId;
  }

  Future<void> _createInvite(BuildContext context, String groupId) async {
    final invite =
        await ref.read(groupsControllerProvider.notifier).createInvite(groupId);
    if (invite != null && context.mounted) {
      await Clipboard.setData(
          ClipboardData(text: 'unischedule://invite/group/${invite.token}'));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('招待リンクをコピーしました。')));
        ref.read(groupsControllerProvider.notifier).clearCreatedInvite();
      }
    }
  }

  Future<void> _inviteFriend(
      BuildContext context, String groupId, GroupState groupState) async {
    final userId = ref.read(currentAuthSessionProvider)?.userId;
    if (userId == null) return;
    try {
      await ref.read(friendsControllerProvider.future);
      await ref.read(friendsControllerProvider.notifier).refreshRelationships();
      if (!mounted || ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      final friendState = ref.read(friendsControllerProvider).valueOrNull ??
          const FriendState();
      final groupMemberIds =
          groupState.members.map((member) => member.userId).toSet();
      final eligible = friendState.relationships
          .where((friend) =>
              friend.isAccepted &&
              !groupMemberIds.contains(friend.otherUserId) &&
              !friendState.blockedUserIds.contains(friend.otherUserId))
          .toList(growable: false);
      if (eligible.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('招待できる友だちがいません。友だち登録を確認してください。'),
        ));
        return;
      }
      final invitee = await showDialog<FriendRelationship>(
        context: context,
        builder: (_) => _AccountBoundDialog(
          viewerId: userId,
          child: _TargetedGroupInviteDialog(friends: eligible),
        ),
      );
      if (invitee == null ||
          !mounted ||
          ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      await ref.read(serverNotificationRepositoryProvider).inviteFriendToGroup(
            groupId: groupId,
            inviteeUserId: invitee.otherUserId,
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
          );
      if (!mounted || ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('招待を送りました。相手が承諾するまでメンバーにはなりません。'),
      ));
    } on Object {
      if (mounted && ref.read(currentAuthSessionProvider)?.userId == userId) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('招待を送れませんでした。権限・友だち状態を確認してください。'),
        ));
      }
    }
  }

  bool _canCreateEvent(GroupSummary group) => switch (group.eventCreatePolicy) {
        'member' => true,
        'admin' =>
          group.role == GroupRole.owner || group.role == GroupRole.admin,
        'owner' => group.role == GroupRole.owner,
        _ => false,
      };

  String _eventRange(DateTime start, DateTime end) {
    final localStart = start.toLocal();
    final localEnd = end.toLocal();
    final startText = localStart.toString().substring(0, 16);
    final sameDay = localStart.year == localEnd.year &&
        localStart.month == localEnd.month &&
        localStart.day == localEnd.day;
    final endText = localEnd.toString().substring(sameDay ? 11 : 0, 16);
    return '$startText - $endText';
  }

  Future<void> _createEvent(BuildContext context, String groupId,
      {DateTime? startAt, DateTime? endAt}) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final draft = await showDialog<_EventDraft>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: _EventFormDialog(
                viewerId: viewerId,
                title: 'グループ予定を作成',
                initialStartAt: startAt,
                initialEndAt: endAt,
              ),
            ));
    if (draft != null &&
        draft.title.isNotEmpty &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId) {
      await ref.read(groupsControllerProvider.notifier).createEvent(
          groupId: groupId,
          title: draft.title,
          startAt: draft.startAt,
          endAt: draft.endAt,
          location: draft.location,
          description: draft.description);
    }
  }

  Future<void> _searchAvailability(
      BuildContext context, GroupSummary group, GroupState state) async {
    final viewer = ref.read(currentAuthSessionProvider)?.userId;
    if (viewer == null || state.members.isEmpty) return;
    final request = await showDialog<_AvailabilityRequest>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewer,
              child: _AvailabilitySearchDialog(
                  members: state.members, groupId: group.id, viewerId: viewer),
            ));
    if (request == null ||
        !context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewer) return;
    final found = await ref
        .read(groupsControllerProvider.notifier)
        .searchGroupAvailability(
            groupId: group.id,
            memberIds: request.memberIds,
            rangeStart: request.rangeStart,
            rangeEnd: request.rangeEnd,
            minimumDurationMinutes: request.minimumDurationMinutes);
    if (!context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewer) return;
    if (!found) return;
    final latest = ref.read(groupsControllerProvider).valueOrNull ?? state;
    await showDialog<void>(
        context: context,
        builder: (_) => _AccountBoundDialog(
            viewerId: viewer,
            child: AlertDialog(
              title: const Text('共通空き時間'),
              content: latest.availabilityWindows.isEmpty
                  ? const Text('共通候補はありません。\n予定を含めて保守的に計算しています。')
                  : SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: latest.availabilityWindows
                              .map((window) => ListTile(
                                    title: Text(_eventRange(
                                        window.startAt, window.endAt)),
                                    subtitle: const Text(
                                        '候補は予定作成フォームへ引き継ぐだけです。保存には確認が必要です。'),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _createEvent(context, group.id,
                                          startAt: window.startAt,
                                          endAt: window.endAt);
                                    },
                                  ))
                              .toList())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('閉じる'))
              ],
            )));
  }

  Future<void> _showEvent(
      BuildContext context, GroupEventSummary event, GroupSummary group) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final controller = ref.read(groupsControllerProvider.notifier);
    if (!await controller.loadEventContent(event.eventId)) return;
    if (!context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewerId) {
      return;
    }
    final eventState = ref.read(groupsControllerProvider).valueOrNull;
    final rsvps = eventState?.eventRsvpEventId == event.eventId
        ? eventState?.eventRsvps ?? const <GroupEventRsvp>[]
        : const <GroupEventRsvp>[];
    final status = await showDialog<String>(
        context: context,
        builder: (_) => _GroupEventDetailDialog(
            event: event, group: group, rsvps: rsvps, viewerId: viewerId));
    if (!context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewerId) {
      return;
    }
    if (status == 'edit') {
      await _editEvent(context, event, null, viewerId: viewerId);
    } else if (status == 'cancel') {
      final confirmed =
          await _confirmAction(context, '予定をキャンセルしますか？', viewerId: viewerId);
      if (confirmed &&
          context.mounted &&
          ref.read(currentAuthSessionProvider)?.userId == viewerId) {
        await ref
            .read(groupsControllerProvider.notifier)
            .cancelEvent(event.eventId, event.version);
      }
    } else if (status != null && context.mounted) {
      if (ref.read(currentAuthSessionProvider)?.userId != viewerId) return;
      await ref
          .read(groupsControllerProvider.notifier)
          .setEventRsvp(event.eventId, status);
    }
  }

  Future<void> _editEvent(BuildContext context, GroupEventSummary event,
      GroupEventDraft? retainedDraft,
      {required String viewerId}) async {
    if (ref.read(currentAuthSessionProvider)?.userId != viewerId) return;
    final draft = await showDialog<_EventDraft>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: _EventFormDialog(
                  viewerId: viewerId,
                  title: '予定を編集',
                  initial: event,
                  draft: retainedDraft),
            ));
    if (draft != null &&
        draft.title.isNotEmpty &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId) {
      await ref.read(groupsControllerProvider.notifier).updateEvent(
          eventId: event.eventId,
          title: draft.title,
          startAt: draft.startAt,
          endAt: draft.endAt,
          location: draft.location,
          description: draft.description,
          expectedVersion: event.version);
    }
  }

  Future<void> _editGroup(BuildContext context, GroupSummary group) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final draft = await showDialog<_GroupDraft>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: _GroupDraftDialog(
                title: 'グループを編集',
                initial: _GroupDraft(
                    name: group.name,
                    type: group.type.name,
                    policy: group.eventCreatePolicy,
                    description: group.description),
              ),
            ));
    if (draft != null &&
        draft.name.isNotEmpty &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId) {
      await ref.read(groupsControllerProvider.notifier).updateGroup(
          groupId: group.id,
          name: draft.name,
          type: draft.type,
          description: draft.description,
          eventCreatePolicy: draft.policy);
    }
  }

  Future<void> _editGroupDefaultVisibility(
      BuildContext context, GroupSummary group) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null ||
        (group.role != GroupRole.owner && group.role != GroupRole.admin)) {
      return;
    }
    final visibility = await showDialog<String>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: _GroupDefaultVisibilityDialog(
                initialValue: group.defaultVisibility,
              ),
            ));
    if (visibility == null ||
        !context.mounted ||
        ref.read(currentAuthSessionProvider)?.userId != viewerId) {
      return;
    }
    await ref
        .read(groupsControllerProvider.notifier)
        .setGroupDefaultVisibility(groupId: group.id, visibility: visibility);
  }

  Future<void> _confirmLeave(BuildContext context, String id) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: AlertDialog(
                  title: const Text('グループを退出しますか？'),
                  content: const Text('退出後は再招待が必要です。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('キャンセル')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('退出'))
                  ]),
            ));
    if (ok == true &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId &&
        await ref.read(groupsControllerProvider.notifier).leave(id))
      context.go('/shared');
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final viewerId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerId == null) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId,
              child: AlertDialog(
                  title: const Text('グループを削除しますか？'),
                  content: const Text('削除したグループは一覧から表示されなくなります。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('キャンセル')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('削除')),
                  ]),
            ));
    if (ok == true &&
        context.mounted &&
        ref.read(currentAuthSessionProvider)?.userId == viewerId &&
        await ref.read(groupsControllerProvider.notifier).delete(id)) {
      if (context.mounted) context.go('/shared');
    }
  }
}

class _TargetedGroupInviteDialog extends StatelessWidget {
  const _TargetedGroupInviteDialog({required this.friends});

  final List<FriendRelationship> friends;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('友だちを招待'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('招待を受けた友だちは、承諾してから参加します。'),
              ),
              ...friends.map((friend) => ListTile(
                    key: Key('targeted-invite-friend-${friend.otherUserId}'),
                    leading: const Icon(Icons.person_outline),
                    title: Text(friend.otherDisplayName),
                    onTap: () => Navigator.pop(context, friend),
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
        ],
      );
}

class _GroupEventDetailDialog extends ConsumerStatefulWidget {
  const _GroupEventDetailDialog({
    required this.event,
    required this.group,
    required this.rsvps,
    required this.viewerId,
  });

  final GroupEventSummary event;
  final GroupSummary group;
  final List<GroupEventRsvp> rsvps;
  final String? viewerId;

  @override
  ConsumerState<_GroupEventDetailDialog> createState() =>
      _GroupEventDetailDialogState();
}

class _GroupEventDetailDialogState
    extends ConsumerState<_GroupEventDetailDialog> {
  late final TextEditingController _commentController;
  final _reactions = const <String, String>{
    'ok': '了解',
    'thanks': 'ありがとう',
    'question': '質問',
    'maybe': '参加できそう',
    'cannot': '厳しい',
  };

  @override
  void initState() {
    super.initState();
    _commentController = TextEditingController();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentViewerId = ref.watch(currentAuthSessionProvider)?.userId;
    if (currentViewerId == null || currentViewerId != widget.viewerId) {
      return AlertDialog(
        content: const Text('ログイン状態が変わりました'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      );
    }

    final state = ref.watch(groupsControllerProvider).valueOrNull;
    final friendState = ref.watch(friendsControllerProvider).valueOrNull;
    final blockStatusKnown = _blockStatusKnown(
      state: state,
      groupId: widget.group.id,
      viewerId: widget.viewerId,
    );
    final blockedUserIds = _blockedGroupMemberIds(
      state,
      friendState,
      viewerId: widget.viewerId,
    );
    final comments = state?.eventCommentsEventId == widget.event.eventId
        ? state?.eventComments ?? const <GroupEventComment>[]
        : const <GroupEventComment>[];
    final reactions = state?.eventReactionsEventId == widget.event.eventId
        ? state?.eventReactions ?? const <GroupEventReaction>[]
        : const <GroupEventReaction>[];
    final commentDraft = state?.eventCommentDraft;
    final canManage = widget.group.role == GroupRole.owner ||
        widget.group.role == GroupRole.admin;
    final canEditEvent = canManage || widget.event.createdBy == widget.viewerId;
    return AlertDialog(
      title: Text(widget.event.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_eventRange(widget.event.startAt, widget.event.endAt)),
              if ((widget.event.location ?? '').isNotEmpty)
                Text('場所: ${widget.event.location}'),
              if ((widget.event.description ?? '').isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(widget.event.description!)),
              const Divider(height: 24),
              Text('参加状況', style: Theme.of(context).textTheme.titleSmall),
              ...widget.rsvps
                  .map((rsvp) => Text('${rsvp.userId}: ${rsvp.status}')),
              const Divider(height: 24),
              Text('リアクション', style: Theme.of(context).textTheme.titleSmall),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _reactions.entries.map((entry) {
                  final value = reactions.where((r) => r.reaction == entry.key);
                  final current = value.isEmpty ? null : value.first;
                  return FilterChip(
                    label:
                        Text('${entry.value} ${current?.reactionCount ?? 0}'),
                    selected: current?.reactedByMe == true,
                    onSelected: (selected) async {
                      if (selected) {
                        await ref
                            .read(groupsControllerProvider.notifier)
                            .setReaction(widget.event.eventId, entry.key);
                      } else {
                        await ref
                            .read(groupsControllerProvider.notifier)
                            .removeReaction(widget.event.eventId, entry.key);
                      }
                    },
                  );
                }).toList(),
              ),
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('コメント (${comments.length})',
                      style: Theme.of(context).textTheme.titleSmall),
                  TextButton.icon(
                    onPressed: () => _report('event', widget.event.eventId),
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('予定を通報'),
                  ),
                ],
              ),
              if (commentDraft != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    title: const Text('コメントが更新されています'),
                    subtitle: const Text('最新版を確認してから再編集してください。'),
                    trailing: TextButton(
                      onPressed: () {
                        final current = comments.where((comment) =>
                            comment.commentId == commentDraft.commentId);
                        if (current.isNotEmpty) {
                          _editComment(current.first,
                              initialBody: commentDraft.body);
                        }
                      },
                      child: const Text('再編集'),
                    ),
                  ),
                ),
              if (comments.isEmpty)
                const Text('コメントはまだありません。')
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: comments.length,
                    itemBuilder: (_, index) => _commentTile(
                      comments[index],
                      canManage,
                      blockStatusKnown: blockStatusKnown,
                      blockedUserIds: blockedUserIds,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _commentController,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                    labelText: 'コメントを入力', border: OutlineInputBorder()),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: state?.mutating == true ? null : _submitComment,
                  icon: const Icon(Icons.send),
                  label: const Text('送信'),
                ),
              ),
              if (state?.errorMessage != null)
                Text(state!.errorMessage!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        if (canEditEvent)
          TextButton(
              onPressed: () => Navigator.pop(context, 'edit'),
              child: const Text('編集')),
        if (canEditEvent)
          TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('取消')),
        ...['attending', 'tentative', 'declined', 'unanswered'].map((status) =>
            TextButton(
                onPressed: () => Navigator.pop(context, status),
                child: Text(_rsvpLabel(status)))),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
      ],
    );
  }

  Widget _commentTile(GroupEventComment comment, bool canManage,
          {required bool blockStatusKnown,
          required Set<String> blockedUserIds}) =>
      Card(
        child: ListTile(
          key: Key('group-comment-${comment.commentId}'),
          title: Text(comment.body),
          subtitle: Text(
            '${_commentAuthorLabel(
              authorUserId: comment.authorUserId,
              viewerId: widget.viewerId,
              blockStatusKnown: blockStatusKnown,
              blockedUserIds: blockedUserIds,
            )} · ${_commentDate(comment.updatedAt)}',
          ),
          trailing: PopupMenuButton<String>(
            tooltip: 'コメント操作',
            onSelected: (value) async {
              if (!_isCurrentViewer(widget.viewerId)) return;
              if (value == 'edit') await _editComment(comment);
              if (value == 'delete') await _deleteComment(comment);
              if (value == 'moderate') {
                await ref
                    .read(groupsControllerProvider.notifier)
                    .moderateDeleteComment(comment.commentId);
              }
              if (value == 'report') {
                await _report('comment', comment.commentId);
              }
            },
            itemBuilder: (_) => [
              if (comment.authorUserId == widget.viewerId)
                const PopupMenuItem(value: 'edit', child: Text('編集')),
              if (comment.authorUserId == widget.viewerId)
                const PopupMenuItem(value: 'delete', child: Text('削除')),
              if (canManage && comment.authorUserId != widget.viewerId)
                const PopupMenuItem(value: 'moderate', child: Text('管理者として削除')),
              const PopupMenuItem(value: 'report', child: Text('通報')),
            ],
          ),
        ),
      );

  Future<void> _submitComment() async {
    final viewerId = widget.viewerId;
    final body = _commentController.text.trim();
    if (body.isEmpty || body.length > 2000 || !_isCurrentViewer(viewerId)) {
      return;
    }
    final ok = await ref
        .read(groupsControllerProvider.notifier)
        .createComment(widget.event.eventId, body);
    if (ok && _isCurrentViewer(viewerId)) _commentController.clear();
  }

  Future<void> _editComment(GroupEventComment comment,
      {String? initialBody}) async {
    final viewerId = widget.viewerId;
    if (!_isCurrentViewer(viewerId)) return;
    final body = await showDialog<String>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId!,
              child: _CommentEditDialog(initial: initialBody ?? comment.body),
            ));
    if (body == null || body.trim().isEmpty || !_isCurrentViewer(viewerId)) {
      return;
    }
    await ref
        .read(groupsControllerProvider.notifier)
        .updateComment(comment, body.trim());
  }

  Future<void> _deleteComment(GroupEventComment comment) async {
    final viewerId = widget.viewerId;
    if (!_isCurrentViewer(viewerId)) return;
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId!,
              child: AlertDialog(
                title: const Text('コメントを削除しますか？'),
                content: const Text('削除後は本文を復元できません。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('キャンセル')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('削除')),
                ],
              ),
            ));
    if (ok == true && _isCurrentViewer(viewerId)) {
      await ref.read(groupsControllerProvider.notifier).deleteComment(comment);
    }
  }

  Future<void> _report(String targetType, String targetId) async {
    final viewerId = widget.viewerId;
    if (!_isCurrentViewer(viewerId)) return;
    final reason = await showDialog<String>(
        context: context,
        builder: (_) => _AccountBoundDialog(
              viewerId: viewerId!,
              child: const _ReportDialog(),
            ));
    if (reason == null ||
        reason.trim().isEmpty ||
        !_isCurrentViewer(viewerId)) {
      return;
    }
    final ok = await ref.read(groupsControllerProvider.notifier).reportContent(
        targetType: targetType, targetId: targetId, reason: reason.trim());
    if (ok && _isCurrentViewer(viewerId)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('通報を受け付けました。')));
    }
  }

  bool _isCurrentViewer(String? viewerId) =>
      viewerId != null &&
      mounted &&
      ref.read(currentAuthSessionProvider)?.userId == viewerId;

  String _rsvpLabel(String status) => switch (status) {
        'attending' => '参加',
        'tentative' => '未定',
        'declined' => '不参加',
        _ => '未回答',
      };

  String _eventRange(DateTime start, DateTime end) {
    final localStart = start.toLocal();
    final localEnd = end.toLocal();
    final startText = localStart.toString().substring(0, 16);
    final sameDay = localStart.year == localEnd.year &&
        localStart.month == localEnd.month &&
        localStart.day == localEnd.day;
    final endText = localEnd.toString().substring(sameDay ? 11 : 0, 16);
    return '$startText - $endText';
  }

  String _commentDate(DateTime value) =>
      '${value.toLocal().month}/${value.toLocal().day} ${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
}

class _AccountBoundDialog extends ConsumerWidget {
  const _AccountBoundDialog({required this.viewerId, required this.child});

  final String viewerId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentViewerId = ref.watch(currentAuthSessionProvider)?.userId;
    if (currentViewerId == viewerId) return child;
    return AlertDialog(
      content: const Text('ログイン状態が変わりました'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}

class _CommentEditDialog extends StatefulWidget {
  const _CommentEditDialog({required this.initial});
  final String initial;
  @override
  State<_CommentEditDialog> createState() => _CommentEditDialogState();
}

class _CommentEditDialogState extends State<_CommentEditDialog> {
  late final TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('コメントを編集'),
        content: TextField(
            controller: _controller,
            minLines: 2,
            maxLines: 6,
            maxLength: 2000,
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _controller.text),
              child: const Text('保存')),
        ],
      );
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog();
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  late final TextEditingController _controller;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('通報理由'),
        content: TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '理由を入力')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _controller.text),
              child: const Text('通報する')),
        ],
      );
}

class _AvailabilityRequest {
  const _AvailabilityRequest(
      {required this.memberIds,
      required this.rangeStart,
      required this.rangeEnd,
      required this.minimumDurationMinutes});
  final List<String> memberIds;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final int minimumDurationMinutes;
}

class _AvailabilitySearchDialog extends ConsumerStatefulWidget {
  const _AvailabilitySearchDialog(
      {required this.members, required this.groupId, required this.viewerId});
  final List<GroupMemberSummary> members;
  final String groupId;
  final String viewerId;
  @override
  ConsumerState<_AvailabilitySearchDialog> createState() =>
      _AvailabilitySearchDialogState();
}

class _AvailabilitySearchDialogState
    extends ConsumerState<_AvailabilitySearchDialog> {
  late final Set<String> _selected;
  late DateTime _date;
  late final TextEditingController _start;
  late final TextEditingController _end;
  int _minimum = 60;
  @override
  void initState() {
    super.initState();
    final groupState = ref.read(groupsControllerProvider).valueOrNull;
    final friendState = ref.read(friendsControllerProvider).valueOrNull;
    final blockStatusKnown = _blockStatusKnown(
      state: groupState,
      groupId: widget.groupId,
      viewerId: widget.viewerId,
    );
    final blockedUserIds = _blockedGroupMemberIds(
      groupState,
      friendState,
      viewerId: widget.viewerId,
    );
    _selected = {
      for (final member in widget.members)
        if (member.userId == widget.viewerId ||
            (blockStatusKnown && !blockedUserIds.contains(member.userId)))
          member.userId,
    };
    final n = DateTime.now();
    _date = DateTime(n.year, n.month, n.day);
    _start = TextEditingController(text: '540');
    _end = TextEditingController(text: '1080');
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final value = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDate: _date,
        builder: (context, child) => _AccountBoundDialog(
            viewerId: widget.viewerId,
            child: child ?? const SizedBox.shrink()));
    if (!mounted ||
        ref.read(currentAuthSessionProvider)?.userId != widget.viewerId) {
      return;
    }
    if (value != null) setState(() => _date = value);
  }

  @override
  Widget build(BuildContext context) {
    final groupState = ref.watch(groupsControllerProvider).valueOrNull;
    final viewerId = ref.watch(currentAuthSessionProvider)?.userId;
    final friendState = ref.watch(friendsControllerProvider).valueOrNull;
    final blockStatusKnown = _blockStatusKnown(
      state: groupState,
      groupId: widget.groupId,
      viewerId: viewerId,
    );
    final blockedUserIds =
        _blockedGroupMemberIds(groupState, friendState, viewerId: viewerId);
    final selectionSafe = blockStatusKnown &&
        viewerId == widget.viewerId &&
        _selected.every((id) => id == viewerId || !blockedUserIds.contains(id));
    return AlertDialog(
        title: const Text('共通空き時間の条件'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text('日付: ${_date.year}/${_date.month}/${_date.day}'),
              trailing: IconButton(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today))),
          const Align(
              alignment: Alignment.centerLeft, child: Text('対象メンバー（本人は必須）')),
          ...widget.members.map((m) => CheckboxListTile(
              value: _selected.contains(m.userId),
              onChanged: m.userId == viewerId ||
                      !blockStatusKnown ||
                      blockedUserIds.contains(m.userId) &&
                          !_selected.contains(m.userId)
                  ? null
                  : (v) {
                      if (blockedUserIds.contains(m.userId)) {
                        if (v == false) {
                          setState(() => _selected.remove(m.userId));
                        }
                        return;
                      }
                      setState(() => v == true
                          ? _selected.add(m.userId)
                          : _selected.remove(m.userId));
                    },
              title: Text(_memberDisplayLabel(
                m,
                viewerId: viewerId,
                blockStatusKnown: blockStatusKnown,
                blockedUserIds: blockedUserIds,
              )),
              subtitle: Text(m.userId == viewerId ? '本人' : 'グループメンバー'))),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: _start,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '開始(分)'))),
            Expanded(
                child: TextField(
                    controller: _end,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '終了(分)')))
          ]),
          DropdownButtonFormField<int>(
              initialValue: _minimum,
              decoration: const InputDecoration(labelText: '必要時間'),
              items: const [
                DropdownMenuItem(value: 30, child: Text('30分')),
                DropdownMenuItem(value: 60, child: Text('60分')),
                DropdownMenuItem(value: 90, child: Text('90分')),
                DropdownMenuItem(value: 120, child: Text('120分'))
              ],
              onChanged: (v) {
                if (v != null) setState(() => _minimum = v);
              })
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: selectionSafe
                  ? () {
                      final s = int.tryParse(_start.text),
                          e = int.tryParse(_end.text);
                      if (s == null ||
                          e == null ||
                          s < 0 ||
                          e > 1440 ||
                          s >= e ||
                          !_selected.contains(widget.viewerId)) return;
                      Navigator.pop(
                          context,
                          _AvailabilityRequest(
                              memberIds: _selected.toList(),
                              rangeStart:
                                  DateTime(_date.year, _date.month, _date.day)
                                      .add(Duration(minutes: s)),
                              rangeEnd:
                                  DateTime(_date.year, _date.month, _date.day)
                                      .add(Duration(minutes: e)),
                              minimumDurationMinutes: _minimum));
                    }
                  : null,
              child: const Text('検索'))
        ]);
  }
}

class _GroupDraft {
  const _GroupDraft(
      {required this.name,
      required this.type,
      required this.policy,
      this.description});
  final String name;
  final String type;
  final String policy;
  final String? description;
}

class _GroupDefaultVisibilityDialog extends StatefulWidget {
  const _GroupDefaultVisibilityDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_GroupDefaultVisibilityDialog> createState() =>
      _GroupDefaultVisibilityDialogState();
}

class _GroupDefaultVisibilityDialogState
    extends State<_GroupDefaultVisibilityDialog> {
  late String _value = widget.initialValue;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('共有予定の既定公開範囲'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('共有時間割と空き時間検索での公開範囲です。グループ詳細の予定閲覧権限は変わりません。'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('group-visibility-choice'),
            initialValue: _value,
            items: const [
              DropdownMenuItem(value: 'PRIVATE', child: Text('自分のみ')),
              DropdownMenuItem(value: 'BUSY_ONLY', child: Text('予定あり')),
              DropdownMenuItem(value: 'TITLE_ONLY', child: Text('タイトルのみ')),
              DropdownMenuItem(value: 'FULL', child: Text('詳細を共有')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _value = value);
            },
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              key: const Key('save-group-default-visibility'),
              onPressed: () => Navigator.pop(context, _value),
              child: const Text('保存')),
        ],
      );
}

class _GroupDraftDialog extends StatefulWidget {
  const _GroupDraftDialog({this.initial, required this.title});
  final _GroupDraft? initial;
  final String title;
  @override
  State<_GroupDraftDialog> createState() => _GroupDraftDialogState();
}

class _GroupDraftDialogState extends State<_GroupDraftDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late String _type;
  late String _policy;
  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _name = TextEditingController(text: d?.name);
    _description = TextEditingController(text: d?.description);
    _type = d?.type ?? 'other';
    _policy = d?.policy ?? 'member';
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'グループ名')),
            TextField(
                controller: _description,
                decoration: const InputDecoration(labelText: '説明（任意）')),
            DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: '種類'),
                items: const [
                  DropdownMenuItem(value: 'friends', child: Text('友だち')),
                  DropdownMenuItem(value: 'course', child: Text('授業')),
                  DropdownMenuItem(value: 'club', child: Text('サークル')),
                  DropdownMenuItem(value: 'seminar', child: Text('ゼミ')),
                  DropdownMenuItem(value: 'lab', child: Text('研究室')),
                  DropdownMenuItem(
                      value: 'part_time_job', child: Text('アルバイト')),
                  DropdownMenuItem(value: 'other', child: Text('その他'))
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _type = v);
                }),
            DropdownButtonFormField<String>(
                initialValue: _policy,
                decoration: const InputDecoration(labelText: '予定作成権限'),
                items: const [
                  DropdownMenuItem(value: 'member', child: Text('メンバー')),
                  DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  DropdownMenuItem(value: 'owner', child: Text('Owner'))
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _policy = v);
                }),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(
                    context,
                    _GroupDraft(
                        name: _name.text.trim(),
                        type: _type,
                        policy: _policy,
                        description: _description.text.trim())),
                child: const Text('保存'))
          ]);
}

class _EventDraft {
  const _EventDraft(
      {required this.title,
      required this.startAt,
      required this.endAt,
      this.location,
      this.description});
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? location;
  final String? description;
}

class _EventFormDialog extends ConsumerStatefulWidget {
  const _EventFormDialog(
      {required this.viewerId,
      this.initial,
      this.draft,
      this.initialStartAt,
      this.initialEndAt,
      required this.title});
  final String viewerId;
  final GroupEventSummary? initial;
  final GroupEventDraft? draft;
  final DateTime? initialStartAt;
  final DateTime? initialEndAt;
  final String title;
  @override
  ConsumerState<_EventFormDialog> createState() => _EventFormDialogState();
}

class _EventFormDialogState extends ConsumerState<_EventFormDialog> {
  late final TextEditingController _title, _location, _description;
  late DateTime _start, _end;
  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    final d = widget.draft;
    final now = DateTime.now();
    _title = TextEditingController(text: d?.title ?? e?.title);
    _location = TextEditingController(text: d?.location ?? e?.location);
    _description =
        TextEditingController(text: d?.description ?? e?.description);
    _start = (d?.startAt ?? e?.startAt ?? widget.initialStartAt)?.toLocal() ??
        now.add(const Duration(hours: 1));
    _end = (d?.endAt ?? e?.endAt ?? widget.initialEndAt)?.toLocal() ??
        now.add(const Duration(hours: 2));
  }

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _date(bool start) async {
    final value = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        initialDate: (start ? _start : _end),
        builder: (context, child) => _AccountBoundDialog(
            viewerId: widget.viewerId,
            child: child ?? const SizedBox.shrink()));
    if (!mounted ||
        ref.read(currentAuthSessionProvider)?.userId != widget.viewerId) {
      return;
    }
    if (value != null)
      setState(() => start
          ? _start = DateTime(
              value.year, value.month, value.day, _start.hour, _start.minute)
          : _end = DateTime(
              value.year, value.month, value.day, _end.hour, _end.minute));
  }

  Future<void> _time(bool start) async {
    final current = start ? _start : _end;
    final value = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(current),
        builder: (context, child) => _AccountBoundDialog(
            viewerId: widget.viewerId,
            child: child ?? const SizedBox.shrink()));
    if (!mounted ||
        ref.read(currentAuthSessionProvider)?.userId != widget.viewerId) {
      return;
    }
    if (value != null)
      setState(() => start
          ? _start = DateTime(current.year, current.month, current.day,
              value.hour, value.minute)
          : _end = DateTime(current.year, current.month, current.day,
              value.hour, value.minute));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'タイトル')),
            Row(children: [
              Expanded(
                  child: Text(
                      '開始: ${_start.year}/${_start.month}/${_start.day} ${_start.hour.toString().padLeft(2, '0')}:${_start.minute.toString().padLeft(2, '0')}')),
              IconButton(
                  onPressed: () => _date(true),
                  icon: const Icon(Icons.calendar_today)),
              IconButton(
                  onPressed: () => _time(true),
                  icon: const Icon(Icons.schedule))
            ]),
            Row(children: [
              Expanded(
                  child: Text(
                      '終了: ${_end.year}/${_end.month}/${_end.day} ${_end.hour.toString().padLeft(2, '0')}:${_end.minute.toString().padLeft(2, '0')}')),
              IconButton(
                  onPressed: () => _date(false),
                  icon: const Icon(Icons.calendar_today)),
              IconButton(
                  onPressed: () => _time(false),
                  icon: const Icon(Icons.schedule))
            ]),
            TextField(
                controller: _location,
                decoration: const InputDecoration(labelText: '場所（任意）')),
            TextField(
                controller: _description,
                decoration: const InputDecoration(labelText: '説明（任意）'))
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル')),
            FilledButton(
                onPressed: () => Navigator.pop(
                    context,
                    _EventDraft(
                        title: _title.text.trim(),
                        startAt: _start.toUtc(),
                        endAt: _end.toUtc(),
                        location: _location.text.trim(),
                        description: _description.text.trim())),
                child: const Text('保存'))
          ]);
}
