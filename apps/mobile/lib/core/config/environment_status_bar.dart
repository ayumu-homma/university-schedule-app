import 'package:flutter/material.dart';

import 'app_config.dart';

/// A compact, non-production environment indicator.
///
/// Production intentionally has no debug ribbon. Local/test identity remains
/// available from Settings while staging is always visible to prevent evidence
/// or screenshots from being mistaken for production.
class EnvironmentStatusBar extends StatelessWidget {
  const EnvironmentStatusBar({
    required this.config,
    required this.child,
    super.key,
  });

  final AppConfig config;
  final Widget child;

  static bool isVisibleFor(AppConfig config) {
    return config.environment == AppEnvironment.staging;
  }

  @override
  Widget build(BuildContext context) {
    if (!isVisibleFor(config)) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          excludeSemantics: true,
          label: '実行環境: ${config.environmentLabel}',
          child: ColoredBox(
            key: const Key('environment-status-bar'),
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: const SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'STAGING',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
