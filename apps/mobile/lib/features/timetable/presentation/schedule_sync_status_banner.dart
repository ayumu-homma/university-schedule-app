import 'package:flutter/material.dart';

import '../application/schedule_sync_runtime.dart';

/// A concise, safe status indicator for durable schedule synchronization.
///
/// It intentionally does not render [ScheduleSyncStatus.lastError], which can
/// contain implementation details. Detailed conflict handling remains in
/// Settings, where the user can make an explicit destructive-choice decision.
class ScheduleSyncStatusBanner extends StatelessWidget {
  const ScheduleSyncStatusBanner({
    required this.status,
    this.onRetry,
    this.onOpenSettings,
    super.key,
  });

  final ScheduleSyncStatus status;
  final Future<void> Function()? onRetry;
  final VoidCallback? onOpenSettings;

  static bool isVisibleFor(ScheduleSyncStatus status) {
    return switch (status.phase) {
      ScheduleSyncPhase.running ||
      ScheduleSyncPhase.waitingToRetry ||
      ScheduleSyncPhase.conflict ||
      ScheduleSyncPhase.blockedByLocalMutation ||
      ScheduleSyncPhase.error =>
        true,
      ScheduleSyncPhase.disabled ||
      ScheduleSyncPhase.idle ||
      ScheduleSyncPhase.synchronized =>
        false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final content = _contentFor(status.phase);
    if (content == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final backgroundColor = switch (content.tone) {
      _BannerTone.progress => scheme.surfaceContainerHighest,
      _BannerTone.notice => scheme.secondaryContainer,
      _BannerTone.warning => scheme.tertiaryContainer,
      _BannerTone.error => scheme.errorContainer,
    };
    final foregroundColor = switch (content.tone) {
      _BannerTone.error => scheme.onErrorContainer,
      _ => scheme.onSurface,
    };

    return Semantics(
      container: true,
      liveRegion: true,
      label: content.message,
      child: Material(
        key: const Key('schedule-sync-status-banner'),
        color: backgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              if (content.showProgress)
                SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    color: foregroundColor,
                    strokeWidth: 2,
                  ),
                )
              else
                Icon(content.icon, color: foregroundColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  content.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: foregroundColor,
                      ),
                ),
              ),
              if (content.action == _BannerAction.retry)
                TextButton(
                  key: const Key('schedule-sync-status-retry'),
                  onPressed: onRetry == null
                      ? null
                      : () {
                          onRetry!();
                        },
                  child: const Text('再試行'),
                ),
              if (content.action == _BannerAction.openSettings)
                TextButton(
                  key: const Key('schedule-sync-status-details'),
                  onPressed: onOpenSettings,
                  child: const Text('確認'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  _BannerContent? _contentFor(ScheduleSyncPhase phase) {
    return switch (phase) {
      ScheduleSyncPhase.running => const _BannerContent(
          message: '予定を同期中です',
          tone: _BannerTone.progress,
          showProgress: true,
        ),
      ScheduleSyncPhase.waitingToRetry => const _BannerContent(
          message: '接続できないため同期を待機中です。変更はこの端末に保存されています。',
          tone: _BannerTone.notice,
          icon: Icons.cloud_off_outlined,
          action: _BannerAction.retry,
        ),
      ScheduleSyncPhase.conflict => const _BannerContent(
          message: '予定の競合があります。設定で確認してください。',
          tone: _BannerTone.warning,
          icon: Icons.warning_amber_outlined,
          action: _BannerAction.openSettings,
        ),
      ScheduleSyncPhase.blockedByLocalMutation => const _BannerContent(
          message: '同期できない変更があります。設定で確認してください。',
          tone: _BannerTone.warning,
          icon: Icons.sync_problem_outlined,
          action: _BannerAction.openSettings,
        ),
      ScheduleSyncPhase.error => const _BannerContent(
          message: '同期で問題が発生しました。変更はこの端末に保存されています。',
          tone: _BannerTone.error,
          icon: Icons.error_outline,
          action: _BannerAction.retry,
        ),
      ScheduleSyncPhase.disabled ||
      ScheduleSyncPhase.idle ||
      ScheduleSyncPhase.synchronized =>
        null,
    };
  }
}

enum _BannerTone { progress, notice, warning, error }

enum _BannerAction { retry, openSettings }

class _BannerContent {
  const _BannerContent({
    required this.message,
    required this.tone,
    this.icon,
    this.showProgress = false,
    this.action,
  });

  final String message;
  final _BannerTone tone;
  final IconData? icon;
  final bool showProgress;
  final _BannerAction? action;
}
