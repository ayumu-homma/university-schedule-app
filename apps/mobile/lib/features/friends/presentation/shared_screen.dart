import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../auth/application/auth_providers.dart';
import '../application/friend_providers.dart';
import '../domain/friend_models.dart';
import 'friend_invite_qr.dart';
import '../../groups/presentation/group_detail_screen.dart';

class SharedScreen extends ConsumerWidget {
  const SharedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(friendsControllerProvider);
    return MvpScaffold(
      title: '共有',
      selectedIndex: 4,
      showQuickAdd: false,
      child: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.person_outline), text: '友だち'),
                Tab(icon: Icon(Icons.groups_outlined), text: 'グループ'),
                Tab(icon: Icon(Icons.search), text: '空きコマ'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _FriendsTab(asyncState: asyncState),
                  const GroupListTab(),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () => context.go('/availability'),
                      icon: const Icon(Icons.search),
                      label: const Text('空きコマ検索を開く'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendsTab extends ConsumerStatefulWidget {
  const _FriendsTab({required this.asyncState});

  final AsyncValue<FriendState> asyncState;

  @override
  ConsumerState<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends ConsumerState<_FriendsTab> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (mounted) {
        ref.read(friendsControllerProvider.notifier).refreshRelationships();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.asyncState.valueOrNull ?? const FriendState();
    return RefreshIndicator(
      onRefresh: () =>
          ref.read(friendsControllerProvider.notifier).refreshRelationships(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            key: const Key('friend-create-invite'),
            onPressed:
                state.isMutating ? null : () => _createAndCopy(context, ref),
            icon: const Icon(Icons.link),
            label: const Text('招待リンクを発行してコピー'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('friend-show-invite-qr'),
            onPressed: state.isMutating ? null : () => _openQr(context, ref),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('QRで招待'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('friend-scan-invite'),
            onPressed: () => context.push('/shared/scan'),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('QRを読み取る'),
          ),
          const SizedBox(height: 12),
          _FriendUsernameDiscovery(),
          const SizedBox(height: 12),
          const Text(
            'リンクを受け取った相手が確認して申請し、あなたが承認すると友だちになります。リンクを開いただけでは共有されません。',
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          Text('友だち・申請', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (state.relationships.isEmpty)
            const EmptyState(
              icon: Icons.people_outline,
              title: '友だちはまだいません',
              message: '招待リンクを発行して、共有する相手を選びます。',
            )
          else
            for (final relationship in state.relationships)
              _RelationshipTile(
                relationship: relationship,
                defaultLevel: state.visibilityRules[relationship.otherUserId]
                    ?.where(
                      (rule) => rule.targetKind == 'default' && !rule.inherited,
                    )
                    .firstOrNull
                    ?.level,
              ),
          if (state.issuedInvitations.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('発行済みリンク', style: Theme.of(context).textTheme.titleSmall),
            for (final invitation in state.issuedInvitations)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  invitation.revoked ? Icons.link_off : Icons.link,
                ),
                title: Text(
                  invitation.revoked
                      ? '失効済み'
                      : invitation.claimed
                          ? '申請済み'
                          : !invitation.isActive
                              ? '期限切れ'
                              : '有効な招待リンク',
                ),
                subtitle: Text(
                  '期限 ${MaterialLocalizations.of(context).formatShortDate(invitation.expiresAt.toLocal())}',
                ),
                trailing: invitation.isActive
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (state.pendingInvitation?.id == invitation.id)
                            IconButton(
                              tooltip: 'QRを表示',
                              icon: const Icon(Icons.qr_code_2),
                              onPressed: () =>
                                  context.push('/shared/invite/qr'),
                            ),
                          TextButton(
                            onPressed: () => ref
                                .read(friendsControllerProvider.notifier)
                                .revokeInvitation(invitation.id),
                            child: const Text('失効'),
                          ),
                        ],
                      )
                    : null,
              ),
          ],
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => context.go('/shared/blocked'),
            icon: const Icon(Icons.block_outlined),
            label: Text('ブロック一覧（${state.blockedUserIds.length}）'),
          ),
          if (state.isOffline)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('通信できないため、共有状態を更新できません。'),
            ),
        ],
      ),
    );
  }

  Future<void> _createAndCopy(BuildContext context, WidgetRef ref) async {
    final invitation =
        await ref.read(friendsControllerProvider.notifier).createInvitation();
    if (invitation == null || !context.mounted) return;
    final config = ref.read(appConfigProvider);
    // Keep the opaque token in the clipboard payload only.  The configured
    // custom scheme is accepted by the same allow-listed deep-link parser and
    // is the reliable form for local/staging handoff.
    final uri = friendInvitationUri(config, invitation.token);
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('招待リンクをコピーしました。期限と失効はこの画面で管理できます。')),
    );
  }

  Future<void> _openQr(BuildContext context, WidgetRef ref) async {
    final invitation =
        await ref.read(friendsControllerProvider.notifier).createInvitation();
    if (invitation == null || !context.mounted) return;
    await context.push('/shared/invite/qr');
  }
}

class _FriendUsernameDiscovery extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FriendUsernameDiscovery> createState() =>
      _FriendUsernameDiscoveryState();
}

class _FriendUsernameDiscoveryState
    extends ConsumerState<_FriendUsernameDiscovery> {
  late final TextEditingController _usernameController;
  late final TextEditingController _searchController;
  bool _searchable = false;
  bool _edited = false;
  int _viewerIdentityEpoch = 0;
  Object? _usernameConfirmationId;
  BuildContext? _usernameConfirmationContext;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentAuthSessionProvider, (previous, next) {
      if (previous?.userId == next?.userId) return;
      _viewerIdentityEpoch++;
      _usernameConfirmationId = null;
      final dialogContext = _usernameConfirmationContext;
      _usernameConfirmationContext = null;
      if (dialogContext?.mounted ?? false) {
        Navigator.of(dialogContext!).pop(false);
      }
    });
    final state =
        ref.watch(friendsControllerProvider).valueOrNull ?? const FriendState();
    if (state.usernameQuery.isEmpty && _searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    final profile = state.friendUsername;
    if (!_edited && profile != null) {
      if (_usernameController.text != (profile.username ?? '')) {
        _usernameController.text = profile.username ?? '';
      }
      _searchable = profile.searchable;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ユーザー名で見つけてもらう',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('設定は任意です。オンにするまで、検索結果には表示されません。'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('friend-username-field'),
              controller: _usernameController,
              enabled: !state.isMutating,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: 'ユーザー名',
                helperText: '半角英数字と _ の3〜32文字',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _edited = true,
            ),
            SwitchListTile(
              key: const Key('friend-username-opt-in'),
              contentPadding: EdgeInsets.zero,
              title: const Text('ユーザー名で検索可能にする'),
              value: _searchable,
              onChanged: state.isMutating
                  ? null
                  : (value) => setState(() {
                        _edited = true;
                        _searchable = value;
                      }),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: const Key('friend-username-save'),
                onPressed: state.isMutating
                    ? null
                    : () async {
                        final saved = await ref
                            .read(friendsControllerProvider.notifier)
                            .saveMyFriendUsername(
                              username: _usernameController.text,
                              searchable: _searchable,
                            );
                        if (saved && context.mounted) {
                          setState(() => _edited = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('ユーザー名を保存しました')),
                          );
                        }
                      },
                child: state.isMutating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
            if (state.usernameError != null) ...[
              const SizedBox(height: 8),
              Text(state.usernameError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const Divider(height: 28),
            TextField(
              key: const Key('friend-username-search'),
              controller: _searchController,
              enabled: !state.isMutating,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                labelText: '友だちのユーザー名を検索',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => ref
                  .read(friendsControllerProvider.notifier)
                  .onUsernameQueryChanged(value),
            ),
            if (state.isSearchingUsername)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.usernameMatches.isNotEmpty)
              for (final match in state.usernameMatches)
                ListTile(
                  key: const Key('friend-username-result'),
                  contentPadding: EdgeInsets.zero,
                  leading:
                      const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text(match.displayName),
                  subtitle: Text('@${match.username}'),
                  trailing: const Icon(Icons.person_add_alt_1),
                  onTap:
                      state.isMutating ? null : () => _confirm(context, match),
                )
            else if (state.usernameError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(state.usernameError!),
              )
            else if (FriendUsernamePolicy.isValid(state.usernameQuery))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('ユーザーが見つかりませんでした'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(
    BuildContext context,
    FriendUsernameMatch match,
  ) async {
    final viewerUserId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerUserId == null) return;
    final viewerIdentityEpoch = _viewerIdentityEpoch;
    final confirmationId = Object();
    _usernameConfirmationId = confirmationId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (builtContext) {
        final isCurrentViewer = mounted &&
            identical(_usernameConfirmationId, confirmationId) &&
            _viewerIdentityEpoch == viewerIdentityEpoch &&
            ref.read(currentAuthSessionProvider)?.userId == viewerUserId;
        if (!isCurrentViewer) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (builtContext.mounted) Navigator.of(builtContext).pop(false);
          });
          return const AlertDialog(
            title: Text('アカウントが変更されました'),
            content: Text('確認を閉じています。もう一度検索してください。'),
          );
        }
        _usernameConfirmationContext = builtContext;
        return AlertDialog(
          title: const Text('友だち申請を送りますか？'),
          content: Text(
            '${match.displayName} さん (@${match.username}) に申請します。相手が承認するまで予定は共有されません。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(builtContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              key: const Key('friend-username-confirm'),
              onPressed: () => Navigator.of(builtContext).pop(true),
              child: const Text('申請する'),
            ),
          ],
        );
      },
    );
    if (identical(_usernameConfirmationId, confirmationId)) {
      _usernameConfirmationId = null;
      _usernameConfirmationContext = null;
    }
    if (confirmed != true ||
        !context.mounted ||
        _viewerIdentityEpoch != viewerIdentityEpoch ||
        ref.read(currentAuthSessionProvider)?.userId != viewerUserId) {
      return;
    }
    final sent = await ref
        .read(friendsControllerProvider.notifier)
        .confirmUsernameFriendRequest(match);
    if (!context.mounted) return;
    if (sent) {
      _searchController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('友だち申請を送信しました')),
      );
    }
  }
}

class _RelationshipTile extends StatelessWidget {
  const _RelationshipTile({required this.relationship, this.defaultLevel});

  final FriendRelationship relationship;
  final VisibilityLevel? defaultLevel;

  @override
  Widget build(BuildContext context) {
    final isIncoming = relationship.isPending && !relationship.isRequester;
    final status = relationship.isAccepted
        ? '友だち'
        : isIncoming
            ? '承認待ち'
            : '申請中';
    return Card(
      child: ListTile(
        leading: Icon(
          relationship.isAccepted
              ? Icons.person
              : Icons.hourglass_empty_outlined,
        ),
        title: Text(relationship.otherDisplayName),
        subtitle: Text(
          defaultLevel == null
              ? status
              : '$status · 初期値: ${_visibilityTitle(defaultLevel!)}',
        ),
        trailing: relationship.isAccepted
            ? const Icon(Icons.chevron_right)
            : _PendingActions(relationship: relationship),
        onTap: relationship.isAccepted
            ? () => context.go('/shared/friend/${relationship.otherUserId}')
            : null,
      ),
    );
  }
}

String _visibilityTitle(VisibilityLevel level) => switch (level) {
      VisibilityLevel.private => '自分のみ',
      VisibilityLevel.busyOnly => '予定ありのみ',
      VisibilityLevel.titleOnly => 'タイトルのみ',
      VisibilityLevel.full => '詳細まで',
    };

class _PendingActions extends StatelessWidget {
  const _PendingActions({required this.relationship});

  final FriendRelationship relationship;

  @override
  Widget build(BuildContext context) {
    final isIncoming = !relationship.isRequester;
    return PopupMenuButton<String>(
      tooltip: '申請操作',
      onSelected: (value) {
        final container = ProviderScope.containerOf(context, listen: false);
        final controller = container.read(friendsControllerProvider.notifier);
        if (value == 'accept') {
          unawaited(controller.respondToRequest(relationship, accept: true));
        } else if (value == 'reject') {
          unawaited(controller.respondToRequest(relationship, accept: false));
        } else {
          unawaited(controller.cancelRequest(relationship));
        }
      },
      itemBuilder: (_) => [
        if (isIncoming) const PopupMenuItem(value: 'accept', child: Text('承認')),
        if (isIncoming) const PopupMenuItem(value: 'reject', child: Text('拒否')),
        if (!isIncoming)
          const PopupMenuItem(value: 'cancel', child: Text('申請を取り消す')),
      ],
    );
  }
}

class FriendInvitationScreen extends ConsumerStatefulWidget {
  const FriendInvitationScreen({required this.token, super.key});

  final String token;

  @override
  ConsumerState<FriendInvitationScreen> createState() =>
      _FriendInvitationScreenState();
}

class _FriendInvitationScreenState
    extends ConsumerState<FriendInvitationScreen> {
  Future<void> _load() async {
    final token = widget.token;
    await ref.read(friendsControllerProvider.future);
    if (!mounted || widget.token != token) return;
    await ref.read(friendsControllerProvider.notifier).previewInvitation(token);
  }

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  @override
  void didUpdateWidget(covariant FriendInvitationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) {
      Future<void>.microtask(_load);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(friendsControllerProvider);
    final state = asyncState.valueOrNull ?? const FriendState();
    final preview = state.preview;
    return Scaffold(
      appBar: AppBar(title: const Text('友だち招待')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: (asyncState.isLoading || state.isLoading) && preview == null
              ? const Center(child: CircularProgressIndicator())
              : preview == null
                  ? _InvitationError(message: state.errorMessage)
                  : _InvitationConfirmation(preview: preview),
        ),
      ),
    );
  }
}

class _InvitationConfirmation extends ConsumerWidget {
  const _InvitationConfirmation({required this.preview});

  final FriendInvitationPreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(friendsControllerProvider).valueOrNull ?? const FriendState();
    final usable = preview.isUsable;
    return ListView(
      children: [
        const Icon(Icons.person_add_alt_1_outlined, size: 56),
        const SizedBox(height: 16),
        Text(
          '${preview.issuerDisplayName ?? '利用者'}さんからの招待です',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          usable
              ? '確認して申請すると、相手の承認待ちになります。承認されるまで予定は共有されません。'
              : 'この招待リンクは期限切れまたは無効です。',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (usable)
          FilledButton(
            key: const Key('friend-invite-confirm'),
            onPressed: state.isLoading || state.isMutating
                ? null
                : () async {
                    final ok = await ref
                        .read(friendsControllerProvider.notifier)
                        .requestInvitation();
                    if (ok && context.mounted) context.go('/shared');
                  },
            child: state.isMutating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('この人に友だち申請を送る'),
          ),
        if (state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(state.errorMessage!),
          ),
        OutlinedButton(
          onPressed: () => context.go('/shared'),
          child: const Text('戻る'),
        ),
      ],
    );
  }
}

class _InvitationError extends StatelessWidget {
  const _InvitationError({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.link_off_outlined,
      title: '招待を確認できません',
      message: message ?? 'リンクの期限、状態、通信を確認してください。',
      action: OutlinedButton(
        onPressed: () => context.go('/shared'),
        child: const Text('共有へ戻る'),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
