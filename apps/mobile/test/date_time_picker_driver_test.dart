import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/date_time_picker_driver.dart';

void main() {
  for (final scenario in [
    (use24Hours: false, hour: 23, minute: 59),
    (use24Hours: false, hour: 0, minute: 5),
    (use24Hours: true, hour: 23, minute: 59),
  ]) {
    testWidgets('picker gestures select explicit civil date/time: $scenario',
        (tester) async {
      DateTime? selectedDate;
      TimeOfDay? selectedTime;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: scenario.use24Hours,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(builder: (context) {
            return TextButton(
              onPressed: () async {
                selectedDate = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 12, 28),
                  firstDate: DateTime(2026),
                  lastDate: DateTime(2028),
                );
                if (selectedDate == null || !context.mounted) return;
                selectedTime = await showTimePicker(
                  context: context,
                  initialTime: const TimeOfDay(hour: 12, minute: 30),
                );
              },
              child: const Text('Choose deadline'),
            );
          }),
        ),
      ));
      await tester.tap(find.text('Choose deadline'));
      final target = DateTime(2027, 1, 4, scenario.hour, scenario.minute);
      await chooseOpenDateTimePickers(tester, civilDateTime: target);
      expect(selectedDate, DateTime(2027, 1, 4));
      expect(selectedTime,
          TimeOfDay(hour: scenario.hour, minute: scenario.minute));
    });
  }
}
