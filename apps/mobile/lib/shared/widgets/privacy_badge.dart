import 'package:flutter/material.dart';
import 'package:shared_domain/shared_domain.dart';

import 'app_status_badge.dart';

class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({required this.level, super.key});

  final VisibilityLevel level;

  @override
  Widget build(BuildContext context) {
    final (label, icon, tone) = switch (level) {
      VisibilityLevel.private => (
          '自分のみ',
          Icons.lock_outline,
          AppStatusTone.neutral,
        ),
      VisibilityLevel.busyOnly => (
          '予定ありのみ',
          Icons.event_busy_outlined,
          AppStatusTone.warning,
        ),
      VisibilityLevel.titleOnly => (
          'タイトルのみ',
          Icons.badge_outlined,
          AppStatusTone.info,
        ),
      VisibilityLevel.full => (
          '詳細まで',
          Icons.public_outlined,
          AppStatusTone.success,
        ),
    };
    return Tooltip(
      message: '公開範囲: $label',
      child: Semantics(
        label: '公開範囲: $label',
        excludeSemantics: true,
        child: AppStatusBadge(
          label: label,
          icon: icon,
          tone: tone,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}
