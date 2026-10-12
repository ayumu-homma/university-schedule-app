import 'package:flutter/material.dart';

/// Portfolio v0.5 design tokens shared by production screens.
///
/// Layout values follow an 8 dp grid with 4 dp available for compact details.
/// Interactive controls should use [AppSizes.minimumTouchTarget] or a Material
/// component whose theme applies the same minimum.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
  static const double xxxl = 64;
}

abstract final class AppRadii {
  static const double small = 8;
  static const double medium = 12;
  static const double large = 20;
  static const double pill = 999;
}

abstract final class AppElevations {
  static const double flat = 0;
  static const double raised = 1;
  static const double overlay = 6;
}

abstract final class AppSizes {
  static const double minimumTouchTarget = 48;
  static const double iconSmall = 16;
  static const double iconMedium = 24;
  static const double iconLarge = 40;
  static const double compactStatusHeight = 28;
  static const double contentMaxWidth = 840;
  static const double formMaxWidth = 680;
}

abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double tablet = 840;
  static const double wide = 1200;
}

abstract final class AppMotion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration emphasized = Duration(milliseconds: 320);
}

@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.course,
    required this.onCourse,
    required this.assignment,
    required this.onAssignment,
    required this.exam,
    required this.onExam,
    required this.event,
    required this.onEvent,
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.onWarning,
    required this.critical,
    required this.onCritical,
    required this.neutral,
    required this.onNeutral,
  });

  const AppSemanticColors.light()
      : course = const Color(0xFFE8F2FF),
        onCourse = const Color(0xFF004A98),
        assignment = const Color(0xFFFFE9DE),
        onAssignment = const Color(0xFF7C2D00),
        exam = const Color(0xFFF3E8FF),
        onExam = const Color(0xFF55238A),
        event = const Color(0xFFDCF7EE),
        onEvent = const Color(0xFF005844),
        success = const Color(0xFFD8F5E5),
        onSuccess = const Color(0xFF0B5937),
        warning = const Color(0xFFFFEFC5),
        onWarning = const Color(0xFF654500),
        critical = const Color(0xFFF9DEDC),
        onCritical = const Color(0xFF8C1D18),
        neutral = const Color(0xFFE8EAF0),
        onNeutral = const Color(0xFF383C44);

  const AppSemanticColors.dark()
      : course = const Color(0xFF00315F),
        onCourse = const Color(0xFFB3CEFF),
        assignment = const Color(0xFF572100),
        onAssignment = const Color(0xFFFFB694),
        exam = const Color(0xFF3C1B63),
        onExam = const Color(0xFFD9B9FF),
        event = const Color(0xFF004D3B),
        onEvent = const Color(0xFF8BD9C2),
        success = const Color(0xFF0B4F32),
        onSuccess = const Color(0xFF91D9B4),
        warning = const Color(0xFF493200),
        onWarning = const Color(0xFFF7CB63),
        critical = const Color(0xFF690005),
        onCritical = const Color(0xFFFFB4AB),
        neutral = const Color(0xFF2D3036),
        onNeutral = const Color(0xFFC7CAD2);

  final Color course;
  final Color onCourse;
  final Color assignment;
  final Color onAssignment;
  final Color exam;
  final Color onExam;
  final Color event;
  final Color onEvent;
  final Color success;
  final Color onSuccess;
  final Color warning;
  final Color onWarning;
  final Color critical;
  final Color onCritical;
  final Color neutral;
  final Color onNeutral;

  static AppSemanticColors of(BuildContext context) =>
      Theme.of(context).extension<AppSemanticColors>() ??
      (Theme.of(context).brightness == Brightness.dark
          ? const AppSemanticColors.dark()
          : const AppSemanticColors.light());

  @override
  AppSemanticColors copyWith({
    Color? course,
    Color? onCourse,
    Color? assignment,
    Color? onAssignment,
    Color? exam,
    Color? onExam,
    Color? event,
    Color? onEvent,
    Color? success,
    Color? onSuccess,
    Color? warning,
    Color? onWarning,
    Color? critical,
    Color? onCritical,
    Color? neutral,
    Color? onNeutral,
  }) {
    return AppSemanticColors(
      course: course ?? this.course,
      onCourse: onCourse ?? this.onCourse,
      assignment: assignment ?? this.assignment,
      onAssignment: onAssignment ?? this.onAssignment,
      exam: exam ?? this.exam,
      onExam: onExam ?? this.onExam,
      event: event ?? this.event,
      onEvent: onEvent ?? this.onEvent,
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      critical: critical ?? this.critical,
      onCritical: onCritical ?? this.onCritical,
      neutral: neutral ?? this.neutral,
      onNeutral: onNeutral ?? this.onNeutral,
    );
  }

  @override
  AppSemanticColors lerp(
    covariant ThemeExtension<AppSemanticColors>? other,
    double t,
  ) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      course: Color.lerp(course, other.course, t)!,
      onCourse: Color.lerp(onCourse, other.onCourse, t)!,
      assignment: Color.lerp(assignment, other.assignment, t)!,
      onAssignment: Color.lerp(onAssignment, other.onAssignment, t)!,
      exam: Color.lerp(exam, other.exam, t)!,
      onExam: Color.lerp(onExam, other.onExam, t)!,
      event: Color.lerp(event, other.event, t)!,
      onEvent: Color.lerp(onEvent, other.onEvent, t)!,
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      onCritical: Color.lerp(onCritical, other.onCritical, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      onNeutral: Color.lerp(onNeutral, other.onNeutral, t)!,
    );
  }
}
