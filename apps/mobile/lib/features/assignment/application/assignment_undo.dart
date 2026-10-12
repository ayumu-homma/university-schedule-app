import '../../timetable/data/local_schedule_repository.dart';

/// A screen-independent submission operation.
///
/// The callback intentionally owns only the immutable receipt and repository
/// operation. It can therefore outlive the screen that displayed its
/// SnackBar, while the repository performs the final owner/version guard.
class AssignmentUndoOperation {
  AssignmentUndoOperation({
    required this.receipt,
    required Future<void> Function(AssignmentUndoReceipt receipt) undo,
  }) : _undo = undo;

  final AssignmentUndoReceipt receipt;
  final Future<void> Function(AssignmentUndoReceipt receipt) _undo;
  Future<void>? _inFlight;

  String get assignmentId => receipt.assignmentId;
  String get ownerUserId => receipt.ownerUserId;
  int get resultingVersion => receipt.resultingVersion;

  /// Runs once at a time. A failed attempt is cleared so the user can retry.
  Future<void> undo() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final operation = _runUndo();
    _inFlight = operation;
    return operation;
  }

  Future<void> _runUndo() async {
    try {
      await _undo(receipt);
    } finally {
      _inFlight = null;
    }
  }
}
