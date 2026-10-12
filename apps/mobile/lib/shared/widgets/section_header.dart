import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    required this.title,
    this.icon,
    this.count,
    this.actionLabel,
    this.onAction,
    super.key,
  }) : assert(
          (actionLabel == null) == (onAction == null),
          'actionLabel and onAction must be supplied together.',
        );

  final String title;
  final IconData? icon;
  final int? count;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: AppSizes.iconMedium, color: colorScheme.primary),
          const SizedBox(width: AppSpacing.xs),
        ],
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              count == null ? title : '$title（$count件）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        if (onAction != null)
          TextButton(
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}
