import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Measures the visible scaffold chrome without requiring quick-add on forms.
({double top, double bottom}) measureMvpActionTapBounds(WidgetTester tester) {
  final appBar = find.byType(AppBar);
  final navigationBar = find.byType(NavigationBar);
  final floatingActionButton = find.byType(FloatingActionButton);
  expect(appBar, findsOneWidget);
  expect(navigationBar, findsOneWidget);
  final fabCount = floatingActionButton.evaluate().length;
  expect(fabCount, lessThanOrEqualTo(1));

  final top = tester.getBottomLeft(appBar).dy + 16;
  var bottom = tester.getTopLeft(navigationBar).dy - 16;
  if (fabCount == 1) {
    final fabTop = tester.getTopLeft(floatingActionButton).dy - 16;
    if (fabTop < bottom) bottom = fabTop;
  }
  expect(bottom, greaterThan(top));
  return (top: top, bottom: bottom);
}
