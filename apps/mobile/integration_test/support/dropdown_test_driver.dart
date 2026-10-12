import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens a decorated [DropdownButton] through its real pointer surface.
///
/// A real-device integration frame can occasionally consume an otherwise
/// hit-testable tap without creating the popup route. The single retry is
/// allowed only after the first bounded route probe still observes no current
/// [PopupRoute]. Before each gesture this driver resolves the live field again
/// and proves that its selected value and keyed option snapshot are unchanged.
Future<int> openVerifiedDropdownWithSingleRetry(
  WidgetTester tester, {
  required Finder field,
  required Key optionKey,
  required Object? expectedOptionValue,
  required Object? expectedFieldValue,
  required String label,
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final target = _resolveVerifiedDropdownTarget(
      tester,
      field: field,
      optionKey: optionKey,
      label: label,
    );
    expect(
      target.optionValue,
      expectedOptionValue,
      reason: 'The keyed option value changed before opening $label.',
    );
    expect(
      target.fieldValue,
      expectedFieldValue,
      reason: 'The selected field value changed before opening $label.',
    );
    expect(
      _currentPopupRouteScrollableElements(),
      isEmpty,
      reason: 'No PopupRoute may already be open before selecting $label.',
    );

    await tester.tap(target.surface);
    if (await _waitForCurrentPopupRoute(tester, label: label)) {
      return attempt + 1;
    }
  }

  // Preserve the existing route-scoped lazy-menu diagnostic as the authority
  // when both bounded real gestures fail to materialize a popup.
  return 2;
}

({Finder surface, Object? optionValue, Object? fieldValue})
    _resolveVerifiedDropdownTarget(
  WidgetTester tester, {
  required Finder field,
  required Key optionKey,
  required String label,
}) {
  final fieldElements = field.evaluate().toList(growable: false);
  expect(fieldElements, hasLength(1));
  final liveFieldElement = fieldElements.single;
  final liveField = find.byElementPredicate(
    (element) => identical(element, liveFieldElement),
    description: 'the live DropdownButton field for $label',
  );
  final dropdownButton = find.descendant(
    of: liveField,
    matching: find.byWidgetPredicate(
      (widget) => widget is DropdownButton,
      description: 'the live inner DropdownButton for $label',
    ),
  );
  expect(dropdownButton, findsOneWidget);

  final dropdown = tester.widget<DropdownButton<dynamic>>(dropdownButton);
  final sourceItems = (dropdown.items ?? const <DropdownMenuItem<dynamic>>[])
      .where((item) => item.key == optionKey)
      .toList(growable: false);
  expect(
    sourceItems,
    hasLength(1),
    reason: 'The live DropdownButton must contain exactly one keyed $label.',
  );

  // DropdownButtonFormField supplies an InputDecoration, so Flutter opens the
  // menu from the GestureDetector whose direct child is InputDecorator. Tap
  // that actual onTap surface instead of the broader FormField render subtree.
  final surface = find
      .descendant(
        of: dropdownButton,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector &&
              widget.onTap != null &&
              widget.child is InputDecorator,
          description:
              'the decorated DropdownButton gesture surface for $label',
        ),
      )
      .hitTestable();
  expect(
    surface,
    findsOneWidget,
    reason:
        'The live decorated DropdownButton must expose one real tap surface.',
  );

  return (
    surface: surface,
    optionValue: sourceItems.single.value,
    fieldValue: tester.state<FormFieldState<dynamic>>(liveField).value,
  );
}

Future<bool> _waitForCurrentPopupRoute(
  WidgetTester tester, {
  required String label,
}) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final popupScrollables = _currentPopupRouteScrollableElements();
    if (popupScrollables.length > 1) {
      fail('Found more than one current PopupRoute after opening $label.');
    }
    if (popupScrollables.length == 1) return true;
  }
  return false;
}

List<Element> _currentPopupRouteScrollableElements() {
  return find.byType(Scrollable).evaluate().where((element) {
    final route = ModalRoute.of(element);
    return route is PopupRoute<dynamic> && route.isCurrent;
  }).toList(growable: false);
}
