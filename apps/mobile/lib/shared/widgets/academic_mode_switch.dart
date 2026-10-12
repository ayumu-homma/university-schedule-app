import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';

enum AcademicMode { assignments, exams }

/// A compact, two-way switch between the existing workload routes.
///
/// Counts include every record in the current local snapshot, regardless of
/// assignment status or exam date.
class AcademicModeSwitch extends StatelessWidget {
  const AcademicModeSwitch({
    required this.selected,
    required this.assignmentCount,
    required this.examCount,
    required this.onSelected,
    super.key,
  });

  final AcademicMode selected;
  final int assignmentCount;
  final int examCount;
  final ValueChanged<AcademicMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '課題とテストの表示切り替え。'
          '課題数は提出済みを含む全件、テスト数は全日程の件数です。',
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              mode: AcademicMode.assignments,
              selected: selected == AcademicMode.assignments,
              count: assignmentCount,
              label: '課題',
              icon: Icons.assignment_outlined,
              onPressed: () => onSelected(AcademicMode.assignments),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: _ModeButton(
              mode: AcademicMode.exams,
              selected: selected == AcademicMode.exams,
              count: examCount,
              label: 'テスト',
              icon: Icons.quiz_outlined,
              onPressed: () => onSelected(AcademicMode.exams),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.mode,
    required this.selected,
    required this.count,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final AcademicMode mode;
  final bool selected;
  final int count;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final text = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: AppSizes.iconSmall),
        const SizedBox(width: AppSpacing.xs),
        Flexible(child: Text('$label $count件', textAlign: TextAlign.center)),
      ],
    );
    return Semantics(
      button: true,
      enabled: true,
      selected: selected,
      label: '$label、$count件。'
          '${mode == AcademicMode.assignments ? '提出済みを含む全課題数' : '全日程のテスト数'}',
      onTap: onPressed,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(minHeight: AppSizes.minimumTouchTarget),
        child: selected
            ? FilledButton(
                key: ValueKey('academic-mode-${mode.name}'),
                onPressed: onPressed,
                child: text,
              )
            : OutlinedButton(
                key: ValueKey('academic-mode-${mode.name}'),
                onPressed: onPressed,
                child: text,
              ),
      ),
    );
  }
}
