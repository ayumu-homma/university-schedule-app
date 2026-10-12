import 'package:flutter/material.dart';

Future<bool> confirmDiscardUnsavedChanges(
  BuildContext context, {
  required bool hasUnsavedChanges,
  required bool isSaving,
}) async {
  if (!hasUnsavedChanges) return true;
  if (isSaving) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('保存が完了するまでお待ちください')),
    );
    return false;
  }

  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('変更を破棄しますか？'),
          content: const Text('保存していない入力内容は失われます。'),
          actions: [
            TextButton(
              key: const Key('keep-editing'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('編集を続ける'),
            ),
            FilledButton(
              key: const Key('discard-changes'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('破棄して戻る'),
            ),
          ],
        ),
      ) ??
      false;
}

/// Prevents accidental navigation while a form contains unsaved changes.
///
/// The caller owns dirty-state detection and must clear [hasUnsavedChanges]
/// before navigating after a successful save or delete.
class UnsavedChangesGuard extends StatefulWidget {
  const UnsavedChangesGuard({
    required this.hasUnsavedChanges,
    required this.isSaving,
    required this.child,
    this.onDiscard,
    super.key,
  });

  final bool hasUnsavedChanges;
  final bool isSaving;
  final Widget child;
  final Future<void> Function()? onDiscard;

  @override
  State<UnsavedChangesGuard> createState() => _UnsavedChangesGuardState();
}

class _UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  bool _allowNextPop = false;
  bool _dialogOpen = false;

  @override
  void didUpdateWidget(covariant UnsavedChangesGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hasUnsavedChanges) {
      _allowNextPop = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _allowNextPop || !widget.hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _allowNextPop || _dialogOpen) return;
        _dialogOpen = true;
        final discard = await confirmDiscardUnsavedChanges(
          context,
          hasUnsavedChanges: widget.hasUnsavedChanges,
          isSaving: widget.isSaving,
        );
        _dialogOpen = false;
        if (!discard || !mounted) return;

        setState(() => _allowNextPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          if (widget.onDiscard != null) {
            await widget.onDiscard!();
            return;
          }
          final popped = await Navigator.of(context).maybePop(result);
          if (!popped && mounted) {
            setState(() => _allowNextPop = false);
          }
        });
      },
      child: widget.child,
    );
  }
}
