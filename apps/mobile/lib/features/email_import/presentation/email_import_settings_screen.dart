import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../auth/application/auth_providers.dart';
import '../application/email_review_providers.dart';
import '../domain/email_review_models.dart';
import 'email_review_labels.dart';

class EmailImportSettingsScreen extends ConsumerWidget {
  const EmailImportSettingsScreen({
    super.key,
    this.callbackRequestedConnectionId,
    this.callbackCorrelationId,
  });

  final String? callbackRequestedConnectionId;
  final String? callbackCorrelationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentationEnabled =
        ref.watch(emailImportPresentationEnabledProvider);
    final session = ref.watch(currentAuthSessionProvider);
    if (!presentationEnabled) {
      return const _EmailFeatureDisabledScreen();
    }
    if (session == null) {
      return const _EmailSignedOutScreen();
    }

    final ownerUserId = session.userId;
    final connections = ref.watch(emailConnectionsProvider(ownerUserId));
    final network = ref.watch(emailNetworkAvailableProvider);
    final action = ref.watch(emailReviewActionControllerProvider);
    _listenForFeedback(context, ref);
    final isOnline = network.valueOrNull == true;

    return Scaffold(
      appBar: AppBar(title: const Text('メール取込')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (network.valueOrNull == false) const _OfflineBanner(),
            if (network.isLoading)
              const LinearProgressIndicator(
                key: Key('email-network-loading'),
              ),
            if (action.isBusy) _ActionProgress(operation: action.operation),
            Expanded(
              child: connections.when(
                loading: () => Center(
                  child: Semantics(
                    liveRegion: true,
                    label: 'メール接続情報を読み込み中',
                    child: const CircularProgressIndicator(),
                  ),
                ),
                error: (_, __) => _ConnectionLoadError(
                  onRetry: () =>
                      ref.invalidate(emailConnectionsProvider(ownerUserId)),
                ),
                data: (items) => _ConnectionSettingsContent(
                  connections: items,
                  action: action,
                  isOnline: isOnline,
                  onConnect: () => ref
                      .read(emailReviewActionControllerProvider.notifier)
                      .connect(ownerUserId),
                  onRefresh: (connectionId) => ref
                      .read(emailReviewActionControllerProvider.notifier)
                      .refresh(
                        ownerUserId: ownerUserId,
                        connectionId: connectionId,
                      ),
                  callbackRequestedConnectionId: callbackRequestedConnectionId,
                  onCheckAuthorization: (connectionId) => _checkAuthorization(
                    context,
                    ref,
                    ownerUserId: ownerUserId,
                    connectionId: connectionId,
                  ),
                  onDisconnect: (connection) => _confirmDisconnect(
                    context,
                    ref,
                    ownerUserId: ownerUserId,
                    connection: connection,
                  ),
                  onDeleteAccountData: () => _confirmAccountDataDeletion(
                    context,
                    ref,
                    ownerUserId: ownerUserId,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _checkAuthorization(
    BuildContext context,
    WidgetRef ref, {
    required String ownerUserId,
    required String connectionId,
  }) async {
    final isCallbackConnection = callbackRequestedConnectionId == connectionId;
    try {
      return await ref
          .read(emailReviewActionControllerProvider.notifier)
          .checkAuthorization(
            ownerUserId: ownerUserId,
            connectionId: connectionId,
            callbackCorrelationId:
                isCallbackConnection ? callbackCorrelationId : null,
          );
    } finally {
      if (context.mounted &&
          isCallbackConnection &&
          callbackCorrelationId != null) {
        context.replace('/settings/email-import');
      }
    }
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    WidgetRef ref, {
    required String ownerUserId,
    required EmailConnectionSummary connection,
  }) async {
    var deleteDerivedData = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Gmail の接続を解除しますか？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '接続解除にはネットワークが必要です。追加済みの課題・テスト・予定は削除されません。',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const Key('delete-email-derived-data-checkbox'),
                contentPadding: EdgeInsets.zero,
                value: deleteDerivedData,
                onChanged: (value) => setDialogState(
                  () => deleteDerivedData = value ?? false,
                ),
                title: const Text('未確定のメール候補も削除する'),
                subtitle: const Text('追加済みの予定は残ります'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              key: const Key('confirm-email-disconnect-button'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('接続を解除'),
            ),
          ],
        ),
      ),
    );
    if (result != true || !context.mounted) return;
    await ref.read(emailReviewActionControllerProvider.notifier).disconnect(
          ownerUserId: ownerUserId,
          connectionId: connection.id,
          deleteDerivedData: deleteDerivedData,
        );
  }

  Future<void> _confirmAccountDataDeletion(
    BuildContext context,
    WidgetRef ref, {
    required String ownerUserId,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('メール取込データを削除しますか？'),
        content: const Text(
          'ネットワークを使って、このアカウントの Gmail 接続、未確定候補、メール由来のメタデータをサーバーと端末から削除します。追加済みの課題・テスト・予定は削除されません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            key: const Key('confirm-email-account-data-delete-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('メール取込データを削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref
        .read(emailReviewActionControllerProvider.notifier)
        .deleteAccountData(ownerUserId: ownerUserId);
  }
}

class _ConnectionSettingsContent extends StatelessWidget {
  const _ConnectionSettingsContent({
    required this.connections,
    required this.action,
    required this.isOnline,
    required this.onConnect,
    required this.onRefresh,
    required this.onCheckAuthorization,
    required this.callbackRequestedConnectionId,
    required this.onDisconnect,
    required this.onDeleteAccountData,
  });

  final List<EmailConnectionSummary> connections;
  final EmailReviewActionState action;
  final bool isOnline;
  final Future<bool> Function() onConnect;
  final Future<bool> Function(String connectionId) onRefresh;
  final Future<bool> Function(String connectionId) onCheckAuthorization;
  final String? callbackRequestedConnectionId;
  final Future<void> Function(EmailConnectionSummary connection) onDisconnect;
  final Future<void> Function() onDeleteAccountData;

  @override
  Widget build(BuildContext context) {
    final busy = action.isBusy;
    return ListView(
      key: const Key('email-import-settings-list'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'Gmail から予定候補を確認',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'メールは候補として保存されます。内容を確認して「追加」を押すまで、課題・テスト・予定は作成されません。',
        ),
        const SizedBox(height: 16),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '取込候補は自分だけに表示されます。メール本文、認証情報、メールアドレスはこの画面や診断情報に表示しません。',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (connections.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.mail_outline),
                    title: Text('Gmail は未接続です'),
                    subtitle: Text('接続と新しいメールの取得にはネットワークが必要です'),
                  ),
                  FilledButton.icon(
                    key: const Key('email-connect-button'),
                    onPressed: !isOnline || busy ? null : onConnect,
                    icon: const Icon(Icons.link),
                    label: const Text('Gmail を接続'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          for (final connection in connections)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ConnectionCard(
                connection: connection,
                busy: busy,
                isOnline: isOnline,
                authorizationCheckEnabled:
                    callbackRequestedConnectionId == null ||
                        callbackRequestedConnectionId == connection.id,
                onRefresh: () => onRefresh(connection.id),
                onCheckAuthorization: () => onCheckAuthorization(connection.id),
                onDisconnect: () => onDisconnect(connection),
                onReconnect: onConnect,
              ),
            ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('open-email-inbox-button'),
          onPressed: () => context.go('/email-import'),
          icon: const Icon(Icons.inbox_outlined),
          label: const Text('確認待ちの候補を開く'),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'アカウントのメール取込データ',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        const Text(
          '接続解除とは別に、このアカウントの Gmail 接続とメール由来データをまとめて削除できます。追加済みの予定は残ります。',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('email-account-data-delete-button'),
          onPressed: !isOnline || busy ? null : onDeleteAccountData,
          icon: const Icon(Icons.delete_outline),
          label: const Text('メール取込データを削除'),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.connection,
    required this.busy,
    required this.isOnline,
    required this.authorizationCheckEnabled,
    required this.onRefresh,
    required this.onCheckAuthorization,
    required this.onDisconnect,
    required this.onReconnect,
  });

  final EmailConnectionSummary connection;
  final bool busy;
  final bool isOnline;
  final bool authorizationCheckEnabled;
  final VoidCallback onRefresh;
  final VoidCallback onCheckAuthorization;
  final VoidCallback onDisconnect;
  final Future<bool> Function() onReconnect;

  @override
  Widget build(BuildContext context) {
    final canRefresh = connection.status == EmailConnectionStatus.connected ||
        connection.status == EmailConnectionStatus.rateLimited ||
        connection.status == EmailConnectionStatus.failed;
    final retryWindowOpen = connection.retryAfter == null ||
        !connection.retryAfter!.isAfter(DateTime.now().toUtc());
    final needsReconnect =
        connection.status == EmailConnectionStatus.reauthRequired ||
            connection.status == EmailConnectionStatus.disconnected;
    final needsAuthorizationCheck =
        connection.status == EmailConnectionStatus.connecting;
    final canDisconnect =
        connection.status != EmailConnectionStatus.disconnected &&
            connection.status != EmailConnectionStatus.disconnecting;
    return Card(
      key: const Key('email-connection-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.mail_outline),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Gmail',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                    label: Text(emailConnectionStatusLabel(connection.status))),
              ],
            ),
            if (connection.lastSyncedAt != null) ...[
              const SizedBox(height: 8),
              Text('最終取得: ${formatEmailDateTime(connection.lastSyncedAt)}'),
            ],
            if (needsAuthorizationCheck) ...[
              const SizedBox(height: 8),
              const Text(
                'Google の認証画面で許可した後、この画面に戻って接続状態を確認してください。認証情報は端末に保存しません。',
                key: Key('email-authorization-handoff-message'),
              ),
            ],
            if (connection.status == EmailConnectionStatus.rateLimited &&
                connection.retryAfter != null) ...[
              const SizedBox(height: 8),
              Text('再試行可能: ${formatEmailDateTime(connection.retryAfter)}'),
            ],
            if (connection.errorCategory != null) ...[
              const SizedBox(height: 8),
              Text(
                emailErrorMessage(connection.errorCategory),
                key: const Key('email-connection-safe-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ] else if (connection.status ==
                    EmailConnectionStatus.reauthRequired ||
                connection.status == EmailConnectionStatus.rateLimited) ...[
              const SizedBox(height: 8),
              Text(
                emailActionFailureMessage(
                  connectionStatus: connection.status,
                  errorCategory: null,
                ),
                key: const Key('email-connection-safe-status-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (needsAuthorizationCheck)
                  FilledButton.icon(
                    key: const Key('email-authorization-check-button'),
                    onPressed: !isOnline || busy || !authorizationCheckEnabled
                        ? null
                        : onCheckAuthorization,
                    icon: const Icon(Icons.verified_user_outlined),
                    label: const Text('接続状態を確認'),
                  ),
                if (canRefresh)
                  FilledButton.icon(
                    key: const Key('email-manual-refresh-button'),
                    onPressed: !isOnline || busy || !retryWindowOpen
                        ? null
                        : onRefresh,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      connection.status == EmailConnectionStatus.connected
                          ? '新着を取得'
                          : '再試行',
                    ),
                  ),
                if (needsReconnect)
                  FilledButton.icon(
                    key: const Key('email-reauth-button'),
                    onPressed: !isOnline || busy ? null : onReconnect,
                    icon: const Icon(Icons.login),
                    label: Text(
                      connection.status == EmailConnectionStatus.reauthRequired
                          ? '再接続'
                          : '接続し直す',
                    ),
                  ),
                if (canDisconnect)
                  OutlinedButton.icon(
                    key: const Key('email-disconnect-button'),
                    onPressed: !isOnline || busy ? null : onDisconnect,
                    icon: const Icon(Icons.link_off),
                    label: const Text('接続を解除'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionProgress extends StatelessWidget {
  const _ActionProgress({required this.operation});

  final EmailReviewOperation operation;

  @override
  Widget build(BuildContext context) {
    final label = switch (operation) {
      EmailReviewOperation.connecting => 'Google の認証画面を準備中',
      EmailReviewOperation.checkingAuthorization => 'Gmail の接続状態を確認中',
      EmailReviewOperation.refreshing => '新着メールを確認中',
      EmailReviewOperation.saving => '変更を保存中',
      EmailReviewOperation.dismissing => '候補を除外中',
      EmailReviewOperation.retrying => '候補を再処理中',
      EmailReviewOperation.disconnecting => 'Gmail の接続を解除中',
      EmailReviewOperation.deletingAccountData => 'メール取込データを削除中',
      EmailReviewOperation.confirming => '予定を追加中',
      EmailReviewOperation.idle => '処理中',
    };
    return Semantics(
      liveRegion: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(label),
          ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const ListTile(
        key: Key('email-offline-banner'),
        leading: Icon(Icons.cloud_off_outlined),
        title: Text('オフラインです'),
        subtitle: Text('保存済み候補の確認・編集・除外はできます。新着取得、接続、データ削除はできません。'),
      ),
    );
  }
}

class _ConnectionLoadError extends StatelessWidget {
  const _ConnectionLoadError({required this.onRetry});

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
            const Text('メール接続情報を読み込めませんでした'),
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

class _EmailFeatureDisabledScreen extends StatelessWidget {
  const _EmailFeatureDisabledScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('メール取込')),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mark_email_unread_outlined, size: 48),
                SizedBox(height: 16),
                Text('メール取込は現在利用できません'),
                SizedBox(height: 8),
                Text('利用可能になるまで、Gmail への接続や通信は行いません。'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmailSignedOutScreen extends StatelessWidget {
  const _EmailSignedOutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('メール取込')),
      body: const Center(child: Text('メール取込を使うにはログインが必要です')),
    );
  }
}

void _listenForFeedback(BuildContext context, WidgetRef ref) {
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
            EmailReviewSuccess.connected => 'Gmail に接続しました',
            EmailReviewSuccess.authorizationOpened =>
              'Google の認証画面を開きました。許可後、この画面で接続状態を確認してください',
            EmailReviewSuccess.authorizationPending =>
              '認証はまだ完了していません。Google の画面で許可してから再確認してください',
            EmailReviewSuccess.refreshed => '新着メールの確認が完了しました',
            EmailReviewSuccess.saved => '変更を保存しました',
            EmailReviewSuccess.dismissed => '候補を除外しました',
            EmailReviewSuccess.retryCompleted => '候補の再処理が完了しました',
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  });
}
