import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Waits for this popup's transition and overlay removal, without dismissing
/// any route or waiting on unrelated modal routes elsewhere in the navigator.
Future<void> waitForPopupRouteDismissal(
  WidgetTester tester,
  PopupRoute<dynamic> route, {
  required String label,
}) async {
  final overlayEntries = List<OverlayEntry>.of(route.overlayEntries);
  var completed = false;
  route.completed.then((_) => completed = true);
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (completed) {
      // Overlay removal schedules a rebuild; completion can precede the frame
      // that unmounts its widgets. Flush that frame before checking the entries.
      await tester.pump();
      if (overlayEntries.every((entry) => !entry.mounted)) return;
    }
  }
  fail('Timed out waiting for $label '
      '(route=${route.runtimeType} current=${route.isCurrent} '
      'active=${route.isActive}).');
}
