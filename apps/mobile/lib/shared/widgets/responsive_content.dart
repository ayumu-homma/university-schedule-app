import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

/// Keeps screen content readable on tablets without narrowing compact phones.
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    required this.child,
    this.maxWidth = AppSizes.contentMaxWidth,
    this.compactPadding = const EdgeInsets.all(AppSpacing.md),
    this.expandedPadding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.xl,
      vertical: AppSpacing.lg,
    ),
    super.key,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry compactPadding;
  final EdgeInsetsGeometry expandedPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final expanded = constraints.maxWidth >= AppBreakpoints.tablet;
        final contentWidth =
            constraints.maxWidth > maxWidth ? maxWidth : constraints.maxWidth;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: contentWidth,
            height: constraints.hasBoundedHeight ? constraints.maxHeight : null,
            child: Padding(
              padding: expanded ? expandedPadding : compactPadding,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
