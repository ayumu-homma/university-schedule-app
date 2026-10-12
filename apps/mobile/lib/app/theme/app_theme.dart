import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF175CD3),
      brightness: Brightness.light,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ).copyWith(
      surface: const Color(0xFFFFFFFF),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFF8F9FB),
      surfaceContainer: const Color(0xFFF0F3F7),
      surfaceContainerHigh: const Color(0xFFE8EDF3),
      surfaceContainerHighest: const Color(0xFFDDE5EE),
      outlineVariant: const Color(0xFFD7DFEA),
    );
    return _base(scheme, const AppSemanticColors.light());
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFAAC7FF),
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    ).copyWith(
      surface: const Color(0xFF11161D),
      surfaceContainerLowest: const Color(0xFF0C1117),
      surfaceContainerLow: const Color(0xFF191F27),
      surfaceContainer: const Color(0xFF202731),
      surfaceContainerHigh: const Color(0xFF29313C),
      surfaceContainerHighest: const Color(0xFF333D49),
      outlineVariant: const Color(0xFF414D5D),
    );
    return _base(scheme, const AppSemanticColors.dark());
  }

  static ThemeData _base(
    ColorScheme scheme,
    AppSemanticColors semanticColors,
  ) {
    final typography = Typography.material2021(
      platform: defaultTargetPlatform,
    );
    final baseTextTheme = scheme.brightness == Brightness.dark
        ? typography.white
        : typography.black;
    final textTheme = baseTextTheme
        .copyWith(
          displayLarge: baseTextTheme.displayLarge?.copyWith(
            fontSize: 56,
            height: 1.12,
            fontWeight: FontWeight.w700,
          ),
          headlineLarge: baseTextTheme.headlineLarge?.copyWith(
            fontSize: 32,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
          headlineMedium: baseTextTheme.headlineMedium?.copyWith(
            fontSize: 28,
            height: 1.25,
            fontWeight: FontWeight.w700,
          ),
          titleLarge: baseTextTheme.titleLarge?.copyWith(
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: baseTextTheme.titleMedium?.copyWith(
            fontSize: 18,
            height: 1.35,
            fontWeight: FontWeight.w700,
          ),
          titleSmall: baseTextTheme.titleSmall?.copyWith(
            fontSize: 16,
            height: 1.4,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: baseTextTheme.bodyLarge?.copyWith(
            fontSize: 16,
            height: 1.55,
          ),
          bodyMedium: baseTextTheme.bodyMedium?.copyWith(
            fontSize: 16,
            height: 1.5,
          ),
          bodySmall: baseTextTheme.bodySmall?.copyWith(
            fontSize: 14,
            height: 1.45,
          ),
          labelLarge: baseTextTheme.labelLarge?.copyWith(
            fontSize: 14,
            height: 1.25,
            fontWeight: FontWeight.w700,
          ),
          labelMedium: baseTextTheme.labelMedium?.copyWith(
            fontSize: 12,
            height: 1.25,
            fontWeight: FontWeight.w700,
          ),
          labelSmall: baseTextTheme.labelSmall?.copyWith(
            fontSize: 12,
            height: 1.25,
          ),
        )
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );
    const minimumSize = WidgetStatePropertyAll(
      Size(AppSizes.minimumTouchTarget, AppSizes.minimumTouchTarget),
    );
    const buttonShape = WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadii.medium)),
      ),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      textTheme: textTheme,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AccessiblePageTransitionsBuilder(),
          TargetPlatform.iOS: AccessiblePageTransitionsBuilder(),
          TargetPlatform.macOS: AccessiblePageTransitionsBuilder(),
          TargetPlatform.windows: AccessiblePageTransitionsBuilder(),
          TargetPlatform.linux: AccessiblePageTransitionsBuilder(),
          TargetPlatform.fuchsia: AccessiblePageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: scheme.surface,
      focusColor: scheme.primary.withValues(alpha: 0.16),
      extensions: <ThemeExtension<dynamic>>[semanticColors],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: AppElevations.flat,
        scrolledUnderElevation: AppElevations.raised,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: AppElevations.flat,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(
            Radius.circular(AppRadii.medium),
          ),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        helperMaxLines: 3,
        errorMaxLines: 3,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(AppRadii.medium),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(
            Radius.circular(AppRadii.medium),
          ),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(
            Radius.circular(AppRadii.medium),
          ),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        style: ButtonStyle(minimumSize: minimumSize),
      ),
      filledButtonTheme: const FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          shape: buttonShape,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: const OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          shape: buttonShape,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
          ),
        ),
      ),
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: minimumSize,
          shape: buttonShape,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.md),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: AppElevations.raised,
        focusElevation: AppElevations.overlay,
        hoverElevation: AppElevations.overlay,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.large)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
        disabledColor: scheme.surfaceContainerLowest,
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.pill)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        height: 72,
        indicatorColor: scheme.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurface,
        ),
        unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
        minTileHeight: AppSizes.minimumTouchTarget,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.medium)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.large),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: AppElevations.overlay,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadii.large)),
        ),
      ),
    );
  }
}

/// Keep native-style transitions unless the OS requests reduced motion.
class AccessiblePageTransitionsBuilder extends PageTransitionsBuilder {
  const AccessiblePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final platform = Theme.of(context).platform;
    final delegate =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
            ? const CupertinoPageTransitionsBuilder()
            : const ZoomPageTransitionsBuilder();
    return delegate.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
