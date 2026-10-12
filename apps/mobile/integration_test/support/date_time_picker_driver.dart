import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Selects civil date/time through the two real Material picker dialogs.
/// The caller opens the date picker; no state or callback is set directly.
Future<void> chooseOpenDateTimePickers(
  WidgetTester tester, {
  required DateTime civilDateTime,
}) async {
  await tester.pumpAndSettle();
  final dateDialog = find.byType(DatePickerDialog);
  expect(dateDialog, findsOneWidget);
  final dateLabels = MaterialLocalizations.of(tester.element(dateDialog));
  await tester.tap(find.descendant(
    of: dateDialog,
    matching: find.byTooltip(dateLabels.inputDateModeButtonLabel),
  ));
  await tester.pumpAndSettle();
  final dateInput = find.descendant(
    of: dateDialog,
    matching: find.byType(TextFormField),
  );
  expect(dateInput, findsOneWidget);
  await tester.enterText(
    dateInput,
    dateLabels.formatCompactDate(civilDateTime),
  );
  await tester.tap(find.descendant(
    of: dateDialog,
    matching: find.widgetWithText(TextButton, dateLabels.okButtonLabel),
  ));
  await tester.pumpAndSettle();
  expect(dateDialog, findsNothing);

  final timeDialog = find.byType(TimePickerDialog);
  expect(timeDialog, findsOneWidget);
  final context = tester.element(timeDialog);
  final timeLabels = MaterialLocalizations.of(context);
  final use24Hours = MediaQuery.alwaysUse24HourFormatOf(context);
  final time = TimeOfDay.fromDateTime(civilDateTime);
  await tester.tap(find.descendant(
    of: timeDialog,
    matching: find.byTooltip(timeLabels.inputTimeModeButtonLabel),
  ));
  await tester.pumpAndSettle();
  final timeInputs = find.descendant(
    of: timeDialog,
    matching: find.byType(TextFormField),
  );
  expect(timeInputs, findsNWidgets(2));
  await tester.enterText(
    timeInputs.at(0),
    timeLabels.formatHour(time, alwaysUse24HourFormat: use24Hours),
  );
  await tester.enterText(timeInputs.at(1), timeLabels.formatMinute(time));
  final period = find.descendant(
    of: timeDialog,
    matching: find.text(time.period == DayPeriod.am
        ? timeLabels.anteMeridiemAbbreviation
        : timeLabels.postMeridiemAbbreviation),
  );
  if (period.evaluate().isNotEmpty) {
    expect(period, findsOneWidget);
    await tester.tap(period);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.descendant(
    of: timeDialog,
    matching: find.widgetWithText(TextButton, timeLabels.okButtonLabel),
  ));
  await tester.pumpAndSettle();
  expect(timeDialog, findsNothing);
}
