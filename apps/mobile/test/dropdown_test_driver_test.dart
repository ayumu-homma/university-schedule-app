import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dropdown_test_driver.dart';

void main() {
  testWidgets(
    '初回 tap で popup が生成された場合は再試行しない',
    (tester) async {
      await tester.pumpWidget(
        const _ConsumedFirstTapDropdown(consumeNextTap: false),
      );
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('retry-dropdown-field'));
      final tapCount = await openVerifiedDropdownWithSingleRetry(
        tester,
        field: field,
        optionKey: const Key('retry-dropdown-course'),
        expectedOptionValue: 'course',
        expectedFieldValue: 'all',
        label: 'the first-attempt regression course option',
      );

      expect(tapCount, 1);
      await _selectOpenCourseOption(tester);
      expect(find.text('選択: course'), findsOneWidget);
    },
  );

  testWidgets(
    'popup が生成されない初回 tap だけを再試行して実 gesture で選択する',
    (tester) async {
      await tester.pumpWidget(const _ConsumedFirstTapDropdown());
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('retry-dropdown-field'));
      final tapCount = await openVerifiedDropdownWithSingleRetry(
        tester,
        field: field,
        optionKey: const Key('retry-dropdown-course'),
        expectedOptionValue: 'course',
        expectedFieldValue: 'all',
        label: 'the retry regression course option',
      );

      expect(tapCount, 2);
      await _selectOpenCourseOption(tester);

      expect(
        tester.state<FormFieldState<String>>(field).value,
        'course',
      );
      expect(find.text('選択: course'), findsOneWidget);
    },
  );
}

Future<void> _selectOpenCourseOption(WidgetTester tester) async {
  final openOption = find.byKey(const Key('retry-dropdown-course'));
  final popupOptionElements = openOption.evaluate().where((element) {
    final route = ModalRoute.of(element);
    return route is PopupRoute<dynamic> && route.isCurrent;
  }).toList(growable: false);
  expect(popupOptionElements, hasLength(1));
  final popupOption = find.byElementPredicate(
    (element) => identical(element, popupOptionElements.single),
    description: 'the open retry regression course option',
  );

  await tester.tapAt(tester.getCenter(popupOption));
  await tester.pumpAndSettle();
}

class _ConsumedFirstTapDropdown extends StatefulWidget {
  const _ConsumedFirstTapDropdown({this.consumeNextTap = true});

  final bool consumeNextTap;

  @override
  State<_ConsumedFirstTapDropdown> createState() =>
      _ConsumedFirstTapDropdownState();
}

class _ConsumedFirstTapDropdownState extends State<_ConsumedFirstTapDropdown> {
  late bool _consumeNextTap;
  var _selected = 'all';

  @override
  void initState() {
    super.initState();
    _consumeNextTap = widget.consumeNextTap;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('retry-dropdown-field'),
                  initialValue: _selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '授業別',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      key: const Key('retry-dropdown-all'),
                      value: 'all',
                      child: _consumeNextTap
                          ? GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                setState(() => _consumeNextTap = false);
                              },
                              child: const SizedBox(
                                width: 280,
                                height: 48,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('すべての授業'),
                                ),
                              ),
                            )
                          : const Text('すべての授業'),
                    ),
                    const DropdownMenuItem(
                      key: Key('retry-dropdown-course'),
                      value: 'course',
                      child: Text('再試行対象の授業'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _selected = value);
                  },
                ),
                Text('選択: $_selected'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
