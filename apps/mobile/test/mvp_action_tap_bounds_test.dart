import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';

import '../integration_test/support/mvp_action_tap_bounds.dart';

void main() {
  for (final showQuickAdd in [false, true]) {
    testWidgets('tap bounds respect quick-add visibility: $showQuickAdd',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 914));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: MvpScaffold(
          title: 'Synthetic form',
          selectedIndex: 1,
          showQuickAdd: showQuickAdd,
          child: Center(
            child: FilledButton(
              key: const Key('synthetic-save'),
              onPressed: () => taps++,
              child: const Text('Save'),
            ),
          ),
        ),
      ));

      final bounds = measureMvpActionTapBounds(tester);
      expect(bounds.top, tester.getBottomLeft(find.byType(AppBar)).dy + 16);
      final navTop = tester.getTopLeft(find.byType(NavigationBar)).dy - 16;
      if (showQuickAdd) {
        final fabTop =
            tester.getTopLeft(find.byType(FloatingActionButton)).dy - 16;
        expect(bounds.bottom, fabTop);
        expect(bounds.bottom, lessThan(navTop));
      } else {
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(bounds.bottom, navTop);
      }
      final action = find.byKey(const Key('synthetic-save'));
      final rect = tester.getRect(action);
      expect(rect.top, greaterThanOrEqualTo(bounds.top));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      await tester.tap(action.hitTestable());
      expect(taps, 1);
    });
  }

  testWidgets('ambiguous floating controls still fail the bounds check',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(),
        bottomNavigationBar: NavigationBar(destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ]),
        body: Row(children: [
          FloatingActionButton(heroTag: 'one', onPressed: () {}),
          FloatingActionButton(heroTag: 'two', onPressed: () {}),
        ]),
      ),
    ));
    expect(
      () => measureMvpActionTapBounds(tester),
      throwsA(isA<TestFailure>()),
    );
  });
}
