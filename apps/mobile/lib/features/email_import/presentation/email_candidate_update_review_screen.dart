import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/application/auth_providers.dart';
import '../application/email_review_providers.dart';
import '../data/email_candidate_update_repository.dart';
import 'email_review_labels.dart';

class EmailCandidateUpdateReviewScreen extends ConsumerWidget {
  const EmailCandidateUpdateReviewScreen({
    required this.updateId,
    super.key,
  });

  final String updateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(emailImportPresentationEnabledProvider);
    final session = ref.watch(currentAuthSessionProvider);
    if (!enabled) {
      return const _UpdateMessageScreen(message: 'メール取込は現在利用できません');
    }
    if (session == null) {
      return const _UpdateMessageScreen(message: '更新候補を確認するにはログインが必要です');
    }
    final updates = ref.watch(emailCandidateUpdatesProvider(session.userId));
    return updates.when(
      loading: () => const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      ),
      error: (_, __) => _UpdateMessageScreen(
        message: '更新候補を読み込めませんでした',
        onRetry: () =>
            ref.invalidate(emailCandidateUpdatesProvider(session.userId)),
      ),
      data: (items) {
        final proposal = items.where((item) => item.id == updateId).firstOrNull;
        if (proposal == null) {
          return const _UpdateMessageScreen(message: '更新候補はすでに処理されています');
        }
        return _UpdateReviewBody(
          ownerUserId: session.userId,
          proposal: proposal,
        );
      },
    );
  }
}

class _UpdateReviewBody extends ConsumerWidget {
  const _UpdateReviewBody({
    required this.ownerUserId,
    required this.proposal,
  });

  final String ownerUserId;
  final EmailCandidateUpdateProposal proposal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(emailNetworkAvailableProvider).valueOrNull;
    final action = ref.watch(emailReviewActionControllerProvider);
    final fields = proposal.fieldDiff.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return Scaffold(
      appBar: AppBar(title: const Text('更新候補を確認')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (network == false)
              Material(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.cloud_off_outlined),
                  title: Text('オフラインです'),
                  subtitle: Text('選択は端末に保存され、接続後に自動で同期されます。'),
                ),
              ),
            if (action.isBusy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                key: const Key('email-update-review-list'),
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    proposal.proposedPayload.title ?? 'タイトル未設定',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '現在の予定は、反映を選ぶまで変更されません。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  Text('変更内容', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final field in fields)
                    _UpdateDiffCard(
                      field: field.key,
                      rawDiff: field.value,
                      timezone: proposal.timezone,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('reject-email-update-button'),
                      onPressed: action.isBusy
                          ? null
                          : () => _resolve(context, ref, accepted: false),
                      child: const Text('更新を見送る'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('accept-email-update-button'),
                      onPressed: action.isBusy
                          ? null
                          : () => _resolve(context, ref, accepted: true),
                      child: const Text('更新を反映'),
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

  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref, {
    required bool accepted,
  }) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(accepted ? '変更を反映しますか？' : '更新候補を見送りますか？'),
            content: Text(
              accepted ? '表示された変更内容を既存の予定へ反映します。' : '元の予定は変更されません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                key: Key(
                  accepted
                      ? 'confirm-accept-email-update-button'
                      : 'confirm-reject-email-update-button',
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(accepted ? '反映する' : '見送る'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    final controller = ref.read(emailReviewActionControllerProvider.notifier);
    final succeeded = accepted
        ? await controller.acceptUpdate(
            ownerUserId: ownerUserId,
            updateId: proposal.id,
          )
        : await controller.rejectUpdate(
            ownerUserId: ownerUserId,
            updateId: proposal.id,
          );
    if (!context.mounted) return;
    if (succeeded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(accepted ? '変更を反映しました' : '更新候補を見送りました')),
      );
      context.go('/email-import');
      return;
    }
    final state = ref.read(emailReviewActionControllerProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          emailActionFailureMessage(
            connectionStatus: state.connectionStatus,
            errorCategory: state.failureCategory,
          ),
        ),
      ),
    );
  }
}

class _UpdateDiffCard extends StatelessWidget {
  const _UpdateDiffCard({
    required this.field,
    required this.rawDiff,
    required this.timezone,
  });

  final String field;
  final Object? rawDiff;
  final String timezone;

  @override
  Widget build(BuildContext context) {
    final diff = rawDiff is Map ? rawDiff! as Map : const <Object?, Object?>{};
    return Card(
      key: Key('email-update-diff-$field'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_fieldLabel(field),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Text(
              '現在: ${_valueLabel(field, diff['before'], timezone)}',
            ),
            const SizedBox(height: 6),
            Text(
              '変更後: ${_valueLabel(field, diff['after'], timezone)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

String _fieldLabel(String field) => switch (field) {
      'title' => 'タイトル',
      'due_at' => '締切',
      'due_all_day' => '終日',
      'due_timezone' => 'タイムゾーン',
      'start_at' => '開始日時',
      'end_at' => '終了日時',
      'location' => '場所',
      'submission_url' => '提出先 URL',
      'summary' => '概要',
      'suggested_reminders_minutes' => 'リマインダー',
      _ => '予定情報',
    };

String _valueLabel(String field, Object? value, String timezone) {
  if (value == null || value == '') return 'なし';
  if (value is bool) return value ? 'はい' : 'いいえ';
  if (field == 'suggested_reminders_minutes' && value is List) {
    return value.isEmpty ? 'なし' : value.map((item) => '$item分前').join('、');
  }
  if (field == 'due_at' || field == 'start_at' || field == 'end_at') {
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed != null) {
      return formatEmailDateTime(parsed, timeZone: timezone);
    }
  }
  return value.toString();
}

class _UpdateMessageScreen extends StatelessWidget {
  const _UpdateMessageScreen({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更新候補')),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                FilledButton(onPressed: onRetry, child: const Text('再読み込み')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
