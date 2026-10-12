import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../core/links/external_uri_launcher.dart';
import '../../../core/native/native_scope_bridge.dart';
import '../../auth/application/auth_action_controller.dart';
import '../../../local_db/app_database_provider.dart';

class AccountPolicySettingsSection extends ConsumerStatefulWidget {
  const AccountPolicySettingsSection({
    required this.config,
    required this.launchExternalUri,
    required this.accountDeletionEnabled,
    super.key,
  });

  final AppConfig config;
  final ExternalUriLauncher launchExternalUri;
  final bool accountDeletionEnabled;

  @override
  ConsumerState<AccountPolicySettingsSection> createState() =>
      _AccountPolicySettingsSectionState();
}

class _AccountPolicySettingsSectionState
    extends ConsumerState<AccountPolicySettingsSection> {
  bool _deletionInProgress = false;
  String? _phase;

  @override
  Widget build(BuildContext context) {
    final hasPendingDeletion = _phase != null && _phase != 'complete';
    final privacyPolicyUrl = widget.config.privacyPolicyUrl;
    final termsUrl = widget.config.termsUrl;
    final supportUrl = widget.config.supportUrl;
    return Column(
      children: [
        ListTile(
          key: const Key('privacy-policy-settings-tile'),
          enabled: privacyPolicyUrl != null,
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('プライバシーポリシー'),
          subtitle: Text(
            privacyPolicyUrl == null ? '公開準備中' : '保存・共有・削除されるデータを確認',
          ),
          trailing:
              privacyPolicyUrl == null ? null : const Icon(Icons.open_in_new),
          onTap: privacyPolicyUrl == null
              ? null
              : () => _open(context, privacyPolicyUrl),
        ),
        ListTile(
          key: const Key('terms-settings-tile'),
          enabled: termsUrl != null,
          leading: const Icon(Icons.description_outlined),
          title: const Text('利用規約'),
          subtitle: termsUrl == null ? const Text('公開準備中') : null,
          trailing: termsUrl == null ? null : const Icon(Icons.open_in_new),
          onTap: termsUrl == null ? null : () => _open(context, termsUrl),
        ),
        ListTile(
          key: const Key('support-settings-tile'),
          enabled: supportUrl != null,
          leading: const Icon(Icons.support_agent_outlined),
          title: const Text('サポート・管理者への連絡'),
          subtitle: supportUrl == null ? const Text('公開準備中') : null,
          trailing: supportUrl == null ? null : const Icon(Icons.open_in_new),
          onTap: supportUrl == null ? null : () => _open(context, supportUrl),
        ),
        ListTile(
          key: const Key('account-deletion-settings-tile'),
          enabled: widget.accountDeletionEnabled && !_deletionInProgress,
          leading: const Icon(Icons.delete_forever_outlined),
          title: const Text('アカウントとデータを削除'),
          subtitle: Text(
            _deletionInProgress
                ? '削除処理を実行しています'
                : hasPendingDeletion
                    ? '削除処理を再開できます（状態: $_phase）'
                    : widget.accountDeletionEnabled
                        ? '対象データと共有グループの扱いを確認して申請'
                        : 'ログイン中の Supabase アカウントで利用できます',
          ),
          trailing: _deletionInProgress
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : hasPendingDeletion
                  ? const Icon(Icons.refresh)
                  : const Icon(Icons.delete_forever_outlined),
          onTap: widget.accountDeletionEnabled && !_deletionInProgress
              ? hasPendingDeletion
                  ? _resumeDeletion
                  : _beginDeletion
              : null,
        ),
      ],
    );
  }

  Future<void> _beginDeletion() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) {
      _showMessage('削除サービスを利用できません。通信設定を確認してください。');
      return;
    }
    setState(() => _deletionInProgress = true);
    try {
      final ownerUserId = client.auth.currentUser?.id;
      if (ownerUserId == null) throw StateError('No authenticated owner');
      final priorRows =
          await client.rpc('get_my_account_deletion_context') as List<dynamic>;
      if (priorRows.isNotEmpty) {
        final prior = Map<String, dynamic>.from(priorRows.first as Map);
        if (prior['phase'] != 'complete') {
          final priorOperationId = prior['operation_id'] as String;
          final actions = _decodeGroupActions(prior['group_actions']);
          if (mounted) setState(() => _phase = prior['phase'] as String?);
          await _purgeLocalAccountData(ownerUserId, actions);
          await _runDeletionWorker(client, priorOperationId);
          return;
        }
      }
      final raw = await client.rpc('get_my_account_deletion_preflight');
      final response = Map<String, dynamic>.from(raw as Map);
      final groups = (response['groups'] as List<dynamic>? ?? const [])
          .map((group) => Map<String, dynamic>.from(group as Map))
          .toList();
      if (!mounted) return;
      final choices = await _confirmDeletion(groups);
      if (choices == null || !mounted) return;
      final operationId = const Uuid().v4();
      await client.rpc(
        'request_account_deletion',
        params: {
          'p_operation_id': operationId,
          'p_group_actions': choices,
        },
      );
      if (mounted) setState(() => _phase = 'requested');
      await _purgeLocalAccountData(ownerUserId, choices);
      await _runDeletionWorker(client, operationId);
    } on Object {
      if (mounted && _phase != null && _phase != 'complete') {
        setState(() => _phase = 'retry_required');
      }
      if (mounted) _showMessage('削除を申請できませんでした。状態を確認して再試行してください。');
    } finally {
      if (mounted) setState(() => _deletionInProgress = false);
    }
  }

  Future<List<Map<String, Object?>>?> _confirmDeletion(
    List<Map<String, dynamic>> groups,
  ) async {
    final selected = <String, String>{};
    final successors = <String, String?>{};
    final phrase = TextEditingController();
    try {
      return await showDialog<List<Map<String, Object?>>>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final choicesReady = groups.every((group) {
              final id = group['group_id'] as String;
              final count = (group['member_count'] as num?)?.toInt() ?? 0;
              final action = selected[id];
              if (count <= 1) return true;
              if (action == 'disband') return true;
              return action == 'transfer' && successors[id] != null;
            });
            final canConfirm = choicesReady && phrase.text == '削除';
            return AlertDialog(
              title: const Text('削除内容を確認'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '個人データ、予定、連携情報を削除し、ログイン情報を消去します。'
                        '共有コメントは匿名化されます。完了後は元に戻せません。',
                      ),
                      if (groups.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text('あなたが管理するグループ'),
                      ],
                      for (final group in groups)
                        _groupChoice(
                          group,
                          selected[group['group_id'] as String],
                          successors[group['group_id'] as String],
                          (action, successor) => setDialogState(() {
                            selected[group['group_id'] as String] = action;
                            successors[group['group_id'] as String] = successor;
                          }),
                        ),
                      const SizedBox(height: 12),
                      const Text('続行するには「削除」と入力してください。'),
                      TextField(
                        key: const Key('account-deletion-confirmation'),
                        controller: phrase,
                        onChanged: (_) => setDialogState(() {}),
                        decoration: const InputDecoration(hintText: '削除'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  key: const Key('confirm-account-deletion'),
                  onPressed: canConfirm
                      ? () => Navigator.pop(
                            dialogContext,
                            groups.map((group) {
                              final id = group['group_id'] as String;
                              final count =
                                  (group['member_count'] as num?)?.toInt() ?? 0;
                              final action =
                                  count <= 1 ? 'delete' : selected[id]!;
                              return <String, Object?>{
                                'group_id': id,
                                'action': action,
                                if (action == 'transfer')
                                  'successor_id': successors[id],
                              };
                            }).toList(),
                          )
                      : null,
                  child: const Text('削除を申請'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      phrase.dispose();
    }
  }

  Widget _groupChoice(
    Map<String, dynamic> group,
    String? action,
    String? successor,
    void Function(String action, String? successor) onChanged,
  ) {
    final id = group['group_id'] as String;
    final name = (group['name'] as String?) ?? 'グループ';
    final count = (group['member_count'] as num?)?.toInt() ?? 0;
    final members = (group['successors'] as List<dynamic>? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    if (count <= 1) {
      return ListTile(
        key: Key('deletion-group-$id'),
        contentPadding: EdgeInsets.zero,
        title: Text(name),
        subtitle: const Text('あなたのみのグループは削除されます'),
        leading: const Icon(Icons.delete_outline),
      );
    }
    final transferUnavailable = members.isEmpty;
    return Card(
      key: Key('deletion-group-$id'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(name),
              subtitle: Text('共有グループ · $count 人'),
            ),
            RadioGroup<String>(
              groupValue: action,
              onChanged: transferUnavailable
                  ? (value) => onChanged(value!, null)
                  : (value) => onChanged(
                        value!,
                        value == 'transfer'
                            ? successor ?? members.first['user_id'] as String
                            : null,
                      ),
              child: Column(
                children: [
                  RadioListTile<String>(
                    value: 'transfer',
                    enabled: !transferUnavailable,
                    title: const Text('メンバーへ管理を移す'),
                  ),
                  if (!transferUnavailable && action == 'transfer')
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            successor ?? members.first['user_id'] as String,
                        decoration: const InputDecoration(labelText: '移管先'),
                        items: members
                            .map((member) => DropdownMenuItem<String>(
                                  value: member['user_id'] as String,
                                  child: Text(
                                      (member['display_name'] as String?) ??
                                          '利用者'),
                                ))
                            .toList(),
                        onChanged: (value) => onChanged('transfer', value),
                      ),
                    ),
                  const RadioListTile<String>(
                    value: 'disband',
                    title: Text('グループと共有データを削除する'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resumeDeletion() async {
    final client = ref.read(supabaseClientProvider);
    if (client == null) return;
    setState(() => _deletionInProgress = true);
    try {
      final rows =
          await client.rpc('get_my_account_deletion_context') as List<dynamic>;
      if (rows.isEmpty) throw StateError('No pending deletion');
      final status = Map<String, dynamic>.from(rows.first as Map);
      final phase = status['phase'] as String?;
      if (phase == 'complete') {
        await _finishAndSignOut();
        return;
      }
      final id = status['operation_id'] as String;
      final ownerUserId = client.auth.currentUser?.id;
      if (ownerUserId == null) throw StateError('No authenticated owner');
      await _purgeLocalAccountData(
        ownerUserId,
        _decodeGroupActions(status['group_actions']),
      );
      await _runDeletionWorker(client, id);
    } on Object {
      if (mounted) _showMessage('削除処理を再開できませんでした。しばらくしてからもう一度お試しください。');
    } finally {
      if (mounted) setState(() => _deletionInProgress = false);
    }
  }

  Future<void> _runDeletionWorker(
      SupabaseClient client, String operationId) async {
    final response = await client.functions.invoke(
      'process-account-deletion',
      body: {'operation_id': operationId},
    );
    if (response.status < 200 ||
        response.status >= 300 ||
        (response.data is Map && response.data['phase'] != 'complete')) {
      if (mounted) {
        setState(() {
          _phase = response.data is Map
              ? response.data['phase'] as String?
              : 'retry_required';
        });
        _showMessage('削除処理を完了できませんでした。設定画面から再開できます。');
      }
      return;
    }
    await _finishAndSignOut();
  }

  Future<void> _purgeLocalAccountData(
    String ownerUserId,
    List<Map<String, Object?>> groupActions,
  ) async {
    await ref.read(appDatabaseProvider).purgeAccountData(
          ownerUserId: ownerUserId,
          groupActions: groupActions,
        );
    await ref.read(nativeScopeBridgeProvider).deactivate();
  }

  List<Map<String, Object?>> _decodeGroupActions(Object? value) {
    if (value is! List) throw const FormatException('Invalid deletion context');
    return value.map((action) {
      if (action is! Map) {
        throw const FormatException('Invalid deletion context');
      }
      return Map<String, Object?>.from(action);
    }).toList();
  }

  Future<void> _finishAndSignOut() async {
    await ref.read(authActionControllerProvider.notifier).signOut();
    if (!mounted) return;
    final signOut = ref.read(authActionControllerProvider);
    setState(() {
      _phase = 'complete';
    });
    _showMessage(signOut.hasError
        ? 'サーバーデータは削除しましたが、端末の認証情報を消去できませんでした。設定からログアウトを再試行してください。'
        : 'アカウントとデータを削除しました。');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    var opened = false;
    try {
      opened = await widget.launchExternalUri(uri);
    } on Object {
      opened = false;
    }
    if (opened || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ページを開けませんでした。設定を確認してください。')),
    );
  }
}
