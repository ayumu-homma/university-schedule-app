import 'package:flutter/material.dart';

import '../application/assignment_undo.dart';

/// Gives a delayed SnackBar action a live feedback channel without consulting
/// the originating widget State after navigation or disposal.
Future<void> runAssignmentUndoWithFeedback(
  AssignmentUndoOperation operation,
  ScaffoldMessengerState messenger,
) async {
  try {
    await operation.undo();
  } on Object {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('元に戻せませんでした。課題一覧で状態を確認してください。'),
        ),
      );
  }
}
