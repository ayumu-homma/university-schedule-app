import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';
import 'package:university_schedule_mobile/shared/widgets/unsaved_changes_guard.dart';

void main() {
  testWidgets('back keeps a dirty form until discard is confirmed',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              key: const Key('open-editor'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const UnsavedChangesGuard(
                    hasUnsavedChanges: true,
                    isSaving: false,
                    child: Scaffold(body: Text('編集中の画面')),
                  ),
                ),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-editor')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('変更を破棄しますか？'), findsOneWidget);
    expect(find.text('編集中の画面'), findsOneWidget);

    await tester.tap(find.byKey(const Key('keep-editing')));
    await tester.pumpAndSettle();
    expect(find.text('編集中の画面'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open-editor')), findsOneWidget);
    expect(find.text('編集中の画面'), findsNothing);
  });

  testWidgets('shared scaffold asks before imperative navigation',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MvpScaffold(
          title: '編集',
          selectedIndex: 0,
          onBeforeNavigate: () async {
            attempts += 1;
            return false;
          },
          child: const Text('入力内容'),
        ),
      ),
    );

    await tester.tap(find.byTooltip('設定'));
    await tester.pump();

    expect(attempts, 1);
    expect(find.text('入力内容'), findsOneWidget);
  });
}
