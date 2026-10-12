import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation_guard.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../../core/links/external_uri_launcher.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../auth/application/auth_action_controller.dart';
import '../../auth/application/auth_providers.dart';
import '../../email_import/application/email_review_providers.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/application/schedule_sync_runtime.dart';
import '../../../core/sync/sync_coordinator.dart';
import 'account_policy_settings_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  var _isSigningOut = false;

  @override
  Widget build(BuildContext context) {
    if (_isSigningOut) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: 'ログアウト中',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      );
    }
    final config = ref.watch(appConfigProvider);
    final session = ref.watch(currentAuthSessionProvider);
    final authAction = ref.watch(authActionControllerProvider);
    final appState = ref.watch(demoAppControllerProvider).valueOrNull;
    final pendingMutations = appState?.pendingMutations ?? const [];
    final queueCounts = appState?.syncQueueCounts;
    final syncStatus = ref.watch(scheduleSyncRuntimeProvider);
    final actionableMutations =
        ref.watch(actionableScheduleMutationsProvider).valueOrNull ?? const [];
    final canProcess = !syncStatus.isRunning &&
        (config.demoMode || syncStatus.ownerUserId == session?.userId);
    final emailImportPresentationEnabled =
        ref.watch(emailImportPresentationEnabledProvider);
    final launchExternalUri = ref.watch(externalUriLauncherProvider);
    return MvpScaffold(
      title: '設定',
      selectedIndex: 0,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('大学・学期・時限'),
            onTap: () => context.go('/university'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('公開範囲'),
            onTap: () => context.go('/visibility'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('通知'),
            onTap: () => context.go('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('通知の受信箱'),
            onTap: () => context.go('/notifications/inbox'),
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('ウィジェット'),
            onTap: () => context.go('/widgets'),
          ),
          ListTile(
            key: const Key('email-import-settings-tile'),
            enabled: emailImportPresentationEnabled,
            leading: const Icon(Icons.mark_email_unread_outlined),
            title: const Text('メール取込'),
            subtitle: Text(
              emailImportPresentationEnabled
                  ? 'Gmail の接続と確認待ち候補'
                  : '現在は利用できません（Gmail への通信は行いません）',
            ),
            onTap: emailImportPresentationEnabled
                ? () => context.go('/settings/email-import')
                : null,
          ),
          ExpansionTile(
            leading: const Icon(Icons.sync_outlined),
            title: const Text('Schedule sync'),
            subtitle: Text(
              'pending ${queueCounts?.pending ?? 0} / '
              'processing ${queueCounts?.processing ?? 0} / '
              'conflict ${queueCounts?.conflict ?? 0} / '
              'failed ${queueCounts?.failed ?? 0} / '
              'synced ${queueCounts?.synced ?? 0} / '
              'cursor ${syncStatus.cursor}',
            ),
            children: [
              ListTile(
                dense: true,
                title: Text('状態: ${syncStatus.phase.name}'),
                subtitle: syncStatus.lastError == null
                    ? null
                    : Text(syncStatus.lastError!),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: !canProcess
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final result = config.demoMode
                                ? await ref
                                    .read(
                                      demoAppControllerProvider.notifier,
                                    )
                                    .processPendingSync()
                                : (await ref
                                        .read(
                                          scheduleSyncRuntimeProvider.notifier,
                                        )
                                        .trigger(SyncTrigger.manual))
                                    ?.push;
                            if (!context.mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  result == null
                                      ? '同期を開始できませんでした。'
                                      : 'Sync processed ${result.processed}: '
                                          '${result.synced} synced, '
                                          '${result.conflicts} conflicts, '
                                          '${result.failed} failed.',
                                ),
                              ),
                            );
                          },
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('Process pending sync'),
                  ),
                ),
              ),
              if ((config.demoMode && pendingMutations.isEmpty) ||
                  (!config.demoMode && actionableMutations.isEmpty))
                const ListTile(title: Text('待機中の変更はありません')),
              if (config.demoMode)
                for (final mutation in pendingMutations.take(10))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${mutation.entityType} ${mutation.operation.name}',
                    ),
                    subtitle: Text(mutation.entityId),
                    trailing: Text(mutation.status.name),
                  ),
              if (!config.demoMode)
                for (final mutation in actionableMutations.take(10))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${mutation.entityType} ${mutation.operation}',
                    ),
                    subtitle: Text(mutation.entityId),
                    trailing: mutation.status == 'conflict'
                        ? TextButton(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (dialogContext) => AlertDialog(
                                      title: const Text('サーバー版を使用しますか？'),
                                      content: const Text(
                                        'この端末の競合中の変更を破棄し、'
                                        'サーバーに保存された版へ戻します。',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(
                                            dialogContext,
                                            false,
                                          ),
                                          child: const Text('キャンセル'),
                                        ),
                                        FilledButton(
                                          onPressed: () => Navigator.pop(
                                            dialogContext,
                                            true,
                                          ),
                                          child: const Text('サーバー版を使用'),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!confirmed || !context.mounted) return;
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await ref
                                    .read(
                                      demoAppControllerProvider.notifier,
                                    )
                                    .resolveSyncConflictServerWins(
                                      mutation.clientMutationId,
                                    );
                                if (!context.mounted) return;
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('サーバー版で競合を解決しました。'),
                                  ),
                                );
                              } on Object {
                                if (!context.mounted) return;
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('競合を解決できませんでした。'),
                                  ),
                                );
                              }
                            },
                            child: const Text('サーバー版'),
                          )
                        : Text(mutation.status),
                  ),
            ],
          ),
          const Divider(),
          AccountPolicySettingsSection(
            config: config,
            launchExternalUri: launchExternalUri,
            accountDeletionEnabled: session != null && !config.demoMode,
          ),
          if (session != null)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('ログアウト'),
              subtitle: Text(session.email ?? '現在のアカウント'),
              trailing: _isSigningOut || authAction.isLoading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _isSigningOut || authAction.isLoading ? null : _signOut,
            ),
          const Divider(),
          if (config.environment != AppEnvironment.production)
            ListTile(
              key: const Key('settings-environment-mode'),
              leading: const Icon(Icons.info_outline),
              title: const Text('実行モード'),
              subtitle: Text(
                '${config.environmentLabel} · '
                '${config.demoMode ? 'Demo mode' : 'Supabase mode'}',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _signOut() async {
    final pendingLinks = ref.read(pendingDeepLinkStoreProvider);
    final authActions = ref.read(authActionControllerProvider.notifier);
    setState(() => _isSigningOut = true);
    pendingLinks.beginExplicitSignOut();
    await authActions.signOut();
    if (!mounted) return;
    final result = ref.read(authActionControllerProvider);
    if (!result.hasError) return;
    pendingLinks.cancelExplicitSignOut();
    setState(() => _isSigningOut = false);
    final error = result.error;
    final message = error is AppError ? error.message : 'ログアウトできませんでした';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
