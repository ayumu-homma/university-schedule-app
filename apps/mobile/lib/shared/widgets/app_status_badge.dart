import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

enum AppStatusTone {
  neutral,
  info,
  course,
  assignment,
  exam,
  event,
  success,
  warning,
  critical,
}

/// A non-interactive status label that never relies on color alone.
class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({
    required this.label,
    required this.icon,
    this.tone = AppStatusTone.neutral,
    this.excludeFromSemantics = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final AppStatusTone tone;
  final bool excludeFromSemantics;

  @override
  Widget build(BuildContext context) {
    final colors = _colorsFor(context, tone);
    final badge = Container(
      constraints: const BoxConstraints(
        minHeight: AppSizes.compactStatusHeight,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: colors.foreground.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: AppSizes.iconSmall,
            color: colors.foreground,
          ),
          const SizedBox(width: AppSpacing.xxs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.foreground,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );

    if (excludeFromSemantics) return ExcludeSemantics(child: badge);
    return Semantics(
      label: '状態: $label',
      excludeSemantics: true,
      child: badge,
    );
  }
}

({Color background, Color foreground}) _colorsFor(
  BuildContext context,
  AppStatusTone tone,
) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = AppSemanticColors.of(context);
  return switch (tone) {
    AppStatusTone.neutral => (
        background: semantic.neutral,
        foreground: semantic.onNeutral,
      ),
    AppStatusTone.info => (
        background: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
      ),
    AppStatusTone.course => (
        background: semantic.course,
        foreground: semantic.onCourse,
      ),
    AppStatusTone.assignment => (
        background: semantic.assignment,
        foreground: semantic.onAssignment,
      ),
    AppStatusTone.exam => (
        background: semantic.exam,
        foreground: semantic.onExam,
      ),
    AppStatusTone.event => (
        background: semantic.event,
        foreground: semantic.onEvent,
      ),
    AppStatusTone.success => (
        background: semantic.success,
        foreground: semantic.onSuccess,
      ),
    AppStatusTone.warning => (
        background: semantic.warning,
        foreground: semantic.onWarning,
      ),
    AppStatusTone.critical => (
        background: semantic.critical,
        foreground: semantic.onCritical,
      ),
  };
}
