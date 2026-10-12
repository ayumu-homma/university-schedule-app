import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../auth/application/auth_providers.dart';
import '../application/email_review_providers.dart';
import '../data/email_candidate_update_repository.dart';
import '../domain/email_review_models.dart';
import 'email_review_labels.dart';

class EmailCandidateInboxScreen extends ConsumerStatefulWidget {
  const EmailCandidateInboxScreen({super.key});

  @override
  ConsumerState<EmailCandidateInboxScreen> createState() =>
      _EmailCandidateInboxScreenState();
}

class _EmailCandidateInboxScreenState
    extends ConsumerState<EmailCandidateInboxScreen> {
  final _selectedCandidateIds = <String>{};
  var _selectionMode = false;

  @override
  Widget build(BuildContext context) {
    final presentationEnabled =
        ref.watch(emailImportPresentationEnabledProvider);
    final session = ref.watch(currentAuthSessionProvider);
    if (!presentationEnabled) {
      return _MessageScreen(
        title: 'メール候補',
        icon: Icons.mark_email_unread_outlined,
        message: 'メール取込は現在利用できません',
        actionLabel: '設定を確認',
        onAction: () => context.go('/settings/email-import'),
      );
    }
    if (session == null) {
      return const _MessageScreen(
        title: 'メール候補',
        icon: Icons.lock_outline,
        message: 'メール候補を確認するにはログインが必要です',
      );
    }

    final ownerUserId = session.userId;
    final candidates = ref.watch(emailReviewCandidatesProvider(ownerUserId));
    final updates = ref.watch(emailCandidateUpdatesProvider(ownerUserId));
    final connections = ref.watch(emailConnectionsProvider(ownerUserId));
    final network = ref.watch(emailNetworkAvailableProvider);
    final action = ref.watch(emailReviewActionControllerProvider);
    _listenForFeedback(context);
    final connected = connections.valueOrNull
        ?.where(
          (item) => item.status == EmailConnectionStatus.connected,
        )
        .firstOrNull;
    final isOnline = network.valueOrNull == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            _selectionMode ? '${_selectedCandidateIds.length}件を選択中' : 'メール候補'),
        actions: [
          IconButton(
            key: const Key('email-inbox-select-button'),
            tooltip: _selectionMode ? '選択を終了' : '候補を選択',
            onPressed: action.isBusy ? null : _toggleSelectionMode,
            icon: Icon(_selectionMode ? Icons.close : Icons.checklist),
          ),
          IconButton(
            key: const Key('email-inbox-refresh-button'),
            tooltip: '新着を取得',
            onPressed: !isOnline || action.isBusy
                ? null
                : () {
                    if (connected == null) {
                      context.go('/settings/email-import');
                      return;
                    }
                    ref
                        .read(emailReviewActionControllerProvider.notifier)
                        .refresh(
                          ownerUserId: ownerUserId,
                          connectionId: connected.id,
                        );
                  },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'メール取込設定',
            onPressed: () => context.go('/settings/email-import'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (network.valueOrNull == false) const _InboxOfflineBanner(),
            if (action.isBusy)
              _InboxActionProgress(operation: action.operation),
            if (connections.hasValue)
              for (final connection in connections.value!)
                if (connection.status == EmailConnectionStatus.reauthRequired ||
                    connection.status == EmailConnectionStatus.rateLimited ||
                    connection.status == EmailConnectionStatus.failed)
                  _ConnectionAttentionBanner(connection: connection),
            updates.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const _UpdateProposalLoadError(),
              data: (items) => items.isEmpty
                  ? const SizedBox.shrink()
                  : _PendingUpdateSection(
                      items: items,
                      onOpen: (proposal) => context.go(
                        '/email-import/update/${proposal.id}',
                      ),
                    ),
            ),
            Expanded(
              child: candidates.when(
                loading: () => Center(
                  child: Semantics(
                    liveRegion: true,
                    label: 'メール候補を読み込み中',
                    child: const CircularProgressIndicator(),
                  ),
                ),
                error: (_, __) => _CandidateLoadError(
                  onRetry: () => ref.invalidate(
                    emailReviewCandidatesProvider(ownerUserId),
                  ),
                ),
                data: (items) => _CandidateTabs(
                  items: items,
                  selectionMode: _selectionMode,
                  selectedCandidateIds: _selectedCandidateIds,
                  isOnline: isOnline,
                  busy: action.isBusy,
                  onToggle: _toggleCandidate,
                  onStartSelection: _startSelection,
                  onOpen: (candidate) =>
                      context.go('/email-import/${candidate.id}'),
                  onDismissSelected: () => _dismissSelected(ownerUserId),
                  onRetrySelected: () => _retrySelected(ownerUserId, items),
                  onReviewSelected: () => _openFirstSelected(items),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedCandidateIds.clear();
    });
  }

  void _toggleCandidate(String candidateId) {
    setState(() {
      if (!_selectedCandidateIds.add(candidateId)) {
        _selectedCandidateIds.remove(candidateId);
      }
    });
  }

  void _startSelection(String candidateId) {
    setState(() {
      _selectionMode = true;
      _selectedCandidateIds.add(candidateId);
    });
  }

  Future<void> _dismissSelected(String ownerUserId) async {
    if (_selectedCandidateIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('選択した候補を除外しますか？'),
            content: Text(
              '${_selectedCandidateIds.length}件を確認待ちから除外します。予定は作成されません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                key: const Key('confirm-bulk-dismiss-button'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('除外する'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final success = await ref
        .read(emailReviewActionControllerProvider.notifier)
        .dismissMany(
          ownerUserId: ownerUserId,
          candidateIds: _selectedCandidateIds,
        );
    if (success && mounted) _toggleSelectionMode();
  }

  Future<void> _retrySelected(
    String ownerUserId,
    List<EmailReviewCandidate> items,
  ) async {
    final failedIds = items
        .where(
          (item) => _selectedCandidateIds.contains(item.id) && item.canRetry,
        )
        .map((item) => item.id)
        .toList(growable: false);
    if (failedIds.isEmpty) return;
    await ref.read(emailReviewActionControllerProvider.notifier).retryMany(
          ownerUserId: ownerUserId,
          candidateIds: failedIds,
        );
  }

  void _openFirstSelected(List<EmailReviewCandidate> items) {
    final selected = items.where(
      (item) => item.isActionable && _selectedCandidateIds.contains(item.id),
    );
    if (selected.isEmpty) return;
    context.go('/email-import/${selected.first.id}');
  }

  void _listenForFeedback(BuildContext context) {
    ref.listen<EmailReviewActionState>(emailReviewActionControllerProvider, (
      previous,
      next,
    ) {
      if (!context.mounted || next.isBusy) return;
      final expectedAuthorizationHandoff =
          next.connectionStatus == EmailConnectionStatus.connecting &&
              (next.success == EmailReviewSuccess.authorizationOpened ||
                  next.success == EmailReviewSuccess.authorizationPending);
      final message = next.failureCategory != null ||
              (next.connectionStatus != null &&
                  next.connectionStatus != EmailConnectionStatus.connected &&
                  !expectedAuthorizationHandoff)
          ? emailActionFailureMessage(
              connectionStatus: next.connectionStatus,
              errorCategory: next.failureCategory,
            )
          : switch (next.success) {
              EmailReviewSuccess.refreshed => '新着メールの確認が完了しました',
              EmailReviewSuccess.dismissed => '候補を除外しました',
              EmailReviewSuccess.retryCompleted => '候補の再処理が完了しました',
              EmailReviewSuccess.connected => 'Gmail に接続しました',
              EmailReviewSuccess.authorizationOpened => 'Google の認証画面を開きました',
              EmailReviewSuccess.authorizationPending => 'Gmail の認証はまだ完了していません',
              EmailReviewSuccess.saved => '変更を保存しました',
              EmailReviewSuccess.disconnected => 'Gmail の接続を解除しました',
              EmailReviewSuccess.accountDataDeleted => 'メール取込データを削除しました',
              EmailReviewSuccess.confirmed => '予定に追加しました',
              null => null,
            };
      if (message == null ||
          (previous?.failureCategory == next.failureCategory &&
              previous?.success == next.success &&
              previous?.connectionStatus == next.connectionStatus)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }
}

class _PendingUpdateSection extends StatelessWidget {
  const _PendingUpdateSection({
    required this.items,
    required this.onOpen,
  });

  final List<EmailCandidateUpdateProposal> items;
  final ValueChanged<EmailCandidateUpdateProposal> onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '既存の予定への更新候補 (${items.length})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: items.length == 1 ? 76 : 152,
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final proposal = items[index];
                  return Card(
                    margin: const EdgeInsets.only(top: 4),
                    child: ListTile(
                      key: Key('email-update-card-${proposal.id}'),
                      leading: const Icon(Icons.update_outlined),
                      title: Text(proposal.proposedPayload.title ?? 'タイトル未設定'),
                      subtitle: Text('${proposal.fieldDiff.length}項目の変更を確認'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpen(proposal),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateProposalLoadError extends StatelessWidget {
  const _UpdateProposalLoadError();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: const ListTile(
        leading: Icon(Icons.error_outline),
        title: Text('更新候補を読み込めませんでした'),
      ),
    );
  }
}

class _CandidateTabs extends StatelessWidget {
  const _CandidateTabs({
    required this.items,
    required this.selectionMode,
    required this.selectedCandidateIds,
    required this.isOnline,
    required this.busy,
    required this.onToggle,
    required this.onStartSelection,
    required this.onOpen,
    required this.onDismissSelected,
    required this.onRetrySelected,
    required this.onReviewSelected,
  });

  final List<EmailReviewCandidate> items;
  final bool selectionMode;
  final Set<String> selectedCandidateIds;
  final bool isOnline;
  final bool busy;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onStartSelection;
  final ValueChanged<EmailReviewCandidate> onOpen;
  final VoidCallback onDismissSelected;
  final VoidCallback onRetrySelected;
  final VoidCallback onReviewSelected;

  @override
  Widget build(BuildContext context) {
    final actionable = items.where((item) => item.isActionable).toList();
    final history = items.where((item) => item.isHistory).toList();
    final selectedFailed = actionable.any(
      (item) => selectedCandidateIds.contains(item.id) && item.canRetry,
    );
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            tabs: [
              Tab(text: '確認待ち (${actionable.length})'),
              Tab(text: '履歴 (${history.length})'),
            ],
          ),
          if (selectionMode)
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const Key('bulk-review-button'),
                      onPressed: selectedCandidateIds.isEmpty || busy
                          ? null
                          : onReviewSelected,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('一件ずつ確認'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('bulk-retry-button'),
                      onPressed: !selectedFailed || !isOnline || busy
                          ? null
                          : onRetrySelected,
                      icon: const Icon(Icons.refresh),
                      label: const Text('失敗を再試行'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('bulk-dismiss-button'),
                      onPressed: selectedCandidateIds.isEmpty || busy
                          ? null
                          : onDismissSelected,
                      icon: const Icon(Icons.remove_circle_outline),
                      label: const Text('まとめて除外'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: TabBarView(
              children: [
                _CandidateList(
                  key: const Key('email-actionable-candidate-list'),
                  items: actionable,
                  emptyTitle: '確認待ちの候補はありません',
                  emptySubtitle: 'Gmail を同期すると、課題・テスト・予定の候補がここに表示されます。',
                  selectionMode: selectionMode,
                  selectedCandidateIds: selectedCandidateIds,
                  onToggle: onToggle,
                  onStartSelection: onStartSelection,
                  onOpen: onOpen,
                ),
                _CandidateList(
                  key: const Key('email-candidate-history-list'),
                  items: history,
                  emptyTitle: '履歴はまだありません',
                  emptySubtitle: '追加または除外した候補がここに表示されます。',
                  selectionMode: false,
                  selectedCandidateIds: const {},
                  onToggle: onToggle,
                  onStartSelection: onStartSelection,
                  onOpen: onOpen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({
    required this.items,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.selectionMode,
    required this.selectedCandidateIds,
    required this.onToggle,
    required this.onStartSelection,
    required this.onOpen,
    super.key,
  });

  final List<EmailReviewCandidate> items;
  final String emptyTitle;
  final String emptySubtitle;
  final bool selectionMode;
  final Set<String> selectedCandidateIds;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onStartSelection;
  final ValueChanged<EmailReviewCandidate> onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined, size: 48),
              const SizedBox(height: 12),
              Text(emptyTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(emptySubtitle, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final candidate = items[index];
        final payload = candidate.payload;
        final title = payload?.title ??
            switch (candidate.state) {
              EmailCandidateReviewState.failed => '処理できなかった候補',
              EmailCandidateReviewState.dismissed => '除外した候補',
              _ => 'タイトル未設定',
            };
        final date = switch (payload?.candidateType) {
          EmailCandidateType.assignment => payload?.due.at,
          EmailCandidateType.exam ||
          EmailCandidateType.event =>
            payload?.startAt,
          EmailCandidateType.announcement ||
          EmailCandidateType.unknown ||
          null =>
            null,
        };
        return Card(
          child: Semantics(
            button: true,
            label: '$title、${emailReviewStateLabel(candidate.state)}',
            child: ListTile(
              key: Key('email-candidate-${candidate.id}'),
              onTap: selectionMode
                  ? () => onToggle(candidate.id)
                  : () => onOpen(candidate),
              onLongPress: candidate.isActionable
                  ? () => selectionMode
                      ? onToggle(candidate.id)
                      : onStartSelection(candidate.id)
                  : null,
              leading: selectionMode && candidate.isActionable
                  ? Checkbox(
                      value: selectedCandidateIds.contains(candidate.id),
                      onChanged: (_) => onToggle(candidate.id),
                    )
                  : Icon(emailCandidateTypeIcon(payload?.candidateType)),
              title: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          payload == null
                              ? candidate.state ==
                                      EmailCandidateReviewState.dismissed
                                  ? '内容は削除済み'
                                  : '読み取りエラー'
                              : emailCandidateTypeLabel(
                                  payload.candidateType,
                                ),
                        ),
                      ),
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(emailReviewStateLabel(candidate.state)),
                      ),
                    ],
                  ),
                  if (date != null)
                    Text(
                      formatEmailDateTime(
                        date,
                        timeZone: candidate.timezone,
                      ),
                    ),
                  if (payload?.warnings.isNotEmpty == true)
                    Text(
                      '注意事項 ${payload!.warnings.length}件',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (candidate.errorCategory != null)
                    Text(
                      emailErrorMessage(candidate.errorCategory),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
        );
      },
    );
  }
}

class _ConnectionAttentionBanner extends StatelessWidget {
  const _ConnectionAttentionBanner({required this.connection});

  final EmailConnectionSummary connection;

  @override
  Widget build(BuildContext context) {
    final message = connection.status == EmailConnectionStatus.reauthRequired
        ? 'Gmail の再接続が必要です。保存済み候補は引き続き確認できます。'
        : connection.status == EmailConnectionStatus.rateLimited
            ? '取得回数の上限に達しました。保存済み候補は引き続き確認できます。'
            : emailErrorMessage(connection.errorCategory);
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.info_outline),
        title: Text(message),
        trailing: TextButton(
          onPressed: () => context.go('/settings/email-import'),
          child: const Text('設定'),
        ),
      ),
    );
  }
}

class _InboxOfflineBanner extends StatelessWidget {
  const _InboxOfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const ListTile(
        key: Key('email-offline-banner'),
        dense: true,
        leading: Icon(Icons.cloud_off_outlined),
        title: Text('オフラインです'),
        subtitle: Text('保存済み候補の確認・編集・除外はできます。'),
      ),
    );
  }
}

class _InboxActionProgress extends StatelessWidget {
  const _InboxActionProgress({required this.operation});

  final EmailReviewOperation operation;

  @override
  Widget build(BuildContext context) {
    final label = switch (operation) {
      EmailReviewOperation.refreshing => '新着メールを確認中',
      EmailReviewOperation.checkingAuthorization => 'Gmail の接続状態を確認中',
      EmailReviewOperation.saving => '変更を保存中',
      EmailReviewOperation.dismissing => '候補を除外中',
      EmailReviewOperation.retrying => '候補を再処理中',
      EmailReviewOperation.confirming => '予定を追加中',
      EmailReviewOperation.connecting => 'Gmail に接続中',
      EmailReviewOperation.disconnecting => 'Gmail の接続を解除中',
      EmailReviewOperation.deletingAccountData => 'メール取込データを削除中',
      EmailReviewOperation.idle => '処理中',
    };
    return Semantics(
      liveRegion: true,
      label: label,
      child: const LinearProgressIndicator(),
    );
  }
}

class _CandidateLoadError extends StatelessWidget {
  const _CandidateLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            const Text('メール候補を読み込めませんでした'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込み'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageScreen extends StatelessWidget {
  const _MessageScreen({
    required this.title,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
