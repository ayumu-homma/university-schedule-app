import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/app/theme/app_tokens.dart';
import 'package:university_schedule_mobile/shared/widgets/app_status_badge.dart';
import 'package:university_schedule_mobile/shared/widgets/empty_state.dart';
import 'package:university_schedule_mobile/shared/widgets/privacy_badge.dart';
import 'package:university_schedule_mobile/shared/widgets/responsive_content.dart';
import 'package:university_schedule_mobile/shared/widgets/section_header.dart';

void main() {
  test('semantic foreground and container pairs meet WCAG AA contrast', () {
    for (final colors in const [
      AppSemanticColors.light(),
      AppSemanticColors.dark(),
    ]) {
      final pairs = [
        (colors.course, colors.onCourse),
        (colors.assignment, colors.onAssignment),
        (colors.exam, colors.onExam),
        (colors.event, colors.onEvent),
        (colors.success, colors.onSuccess),
        (colors.warning, colors.onWarning),
        (colors.critical, colors.onCritical),
        (colors.neutral, colors.onNeutral),
      ];
      for (final pair in pairs) {
        expect(
          _contrastRatio(pair.$1, pair.$2),
          greaterThanOrEqualTo(4.5),
          reason: '${pair.$2} on ${pair.$1} must remain readable.',
        );
      }
    }
  });

  test('light and dark themes keep readable typography and touch tokens', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      expect(theme.textTheme.bodyMedium?.fontSize, greaterThanOrEqualTo(16));
      expect(theme.textTheme.bodySmall?.fontSize, greaterThanOrEqualTo(14));
      expect(theme.textTheme.labelMedium?.fontSize, greaterThanOrEqualTo(12));
      expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(theme.extension<AppSemanticColors>(), isNotNull);
      expect(theme.chipTheme.shape, isNotNull);
      expect(theme.dialogTheme.shape, isNotNull);
    }
    expect(AppSizes.minimumTouchTarget, 48);
    expect(AppSpacing.md % 8, 0);
  });

  for (final scenario in const [
    _LayoutScenario(
      name: 'compact light 1.3x',
      size: Size(360, 640),
      brightness: Brightness.light,
      textScale: 1.3,
    ),
    _LayoutScenario(
      name: 'phone dark 1.3x',
      size: Size(412, 915),
      brightness: Brightness.dark,
      textScale: 1.3,
    ),
    _LayoutScenario(
      name: 'tablet light 2.0x',
      size: Size(900, 1000),
      brightness: Brightness.light,
      textScale: 2,
    ),
  ]) {
    testWidgets('${scenario.name} keeps shared components usable',
        (tester) async {
      await tester.binding.setSurfaceSize(scenario.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: scenario.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: MediaQuery(
            data: MediaQueryData(
              size: scenario.size,
              textScaler: TextScaler.linear(scenario.textScale),
            ),
            child: Scaffold(
              body: SafeArea(
                child: ResponsiveContent(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSectionHeader(
                          title: '今週中に確認する長い日本語の予定と提出物',
                          icon: Icons.event_note_outlined,
                          count: 12,
                          actionLabel: 'すべて見る',
                          onAction: () {},
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: AppStatusBadge(
                            label: '期限切れ',
                            icon: Icons.error_outline,
                            tone: AppStatusTone.critical,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: PrivacyBadge(
                            level: VisibilityLevel.private,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        EmptyState(
                          icon: Icons.task_alt,
                          title: '今日締切の課題はありません',
                          message: '次の期限を確認するか、新しい課題を追加できます。',
                          action: FilledButton.icon(
                            key: const Key('empty-action'),
                            onPressed: () {},
                            icon: const Icon(Icons.add),
                            label: const Text('課題を追加'),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            key: const Key('icon-action'),
                            tooltip: '表示設定',
                            onPressed: () {},
                            icon: const Icon(Icons.tune),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('empty-action'))).height,
        greaterThanOrEqualTo(AppSizes.minimumTouchTarget),
      );
      expect(
        tester.getSize(find.byKey(const Key('icon-action'))).height,
        greaterThanOrEqualTo(AppSizes.minimumTouchTarget),
      );
      expect(find.bySemanticsLabel('状態: 期限切れ'), findsOneWidget);
      expect(find.bySemanticsLabel('公開範囲: 自分のみ'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          '今日締切の課題はありません。次の期限を確認するか、新しい課題を追加できます。',
        ),
        findsOneWidget,
      );
      semantics.dispose();
    });
  }
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter =
      firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
  final darker =
      firstLuminance > secondLuminance ? secondLuminance : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

class _LayoutScenario {
  const _LayoutScenario({
    required this.name,
    required this.size,
    required this.brightness,
    required this.textScale,
  });

  final String name;
  final Size size;
  final Brightness brightness;
  final double textScale;
}
