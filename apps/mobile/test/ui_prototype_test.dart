import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/ui_prototype/ui_prototype_app.dart';

void main() {
  test(
      'prototype controller keeps a fixed clock, validates explicit deadlines, and resets fixtures',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);

    expect(container.read(prototypeControllerProvider).assignments, isNotEmpty);
    controller.beginAdd();
    controller.updateDraft(title: 'レポート', dueLabel: '2026/10/01 17:30');
    expect(controller.validateDraft(), isTrue);
    final id = controller.saveDraft();
    expect(id, 'created-3');
    expect(
        container.read(prototypeControllerProvider).assignments.last.dueLabel,
        '2026/10/01 17:30');

    controller.setFixture(PrototypeFixture.empty);
    expect(container.read(prototypeControllerProvider).assignments, isEmpty);
    expect(container.read(prototypeControllerProvider).draft.title, isEmpty);
    expect(container.read(prototypeControllerProvider).darkMode, isFalse);
  });

  test('editing and undo preserve the previous assignment state and history',
      () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);

    final before = container
        .read(prototypeControllerProvider)
        .assignments
        .firstWhere((item) => item.id == 'overdue');
    expect(before.status, PrototypeAssignmentStatus.inProgress);
    controller.recordSubmission(before.id);
    expect(
      container
          .read(prototypeControllerProvider)
          .assignments
          .firstWhere((item) => item.id == before.id)
          .status,
      PrototypeAssignmentStatus.submitted,
    );
    controller.undoSubmission(before.id);
    final restored = container
        .read(prototypeControllerProvider)
        .assignments
        .firstWhere((item) => item.id == before.id);
    expect(restored.status, PrototypeAssignmentStatus.inProgress);
    expect(
        restored.history, contains('2026-09-18 08:30 JST に Undo で提出前の状態へ復元'));

    controller.beginEdit(restored);
    controller.updateDraft(title: '編集後の課題');
    expect(controller.saveDraft(), restored.id);
    final edited = container
        .read(prototypeControllerProvider)
        .assignments
        .firstWhere((item) => item.id == restored.id);
    expect(edited.status, PrototypeAssignmentStatus.inProgress);
    expect(edited.history, restored.history);

    final receiptRevision = controller.recordSubmission('due-today');
    controller.reset();
    expect(
      controller.undoSubmissionIfCurrent('due-today', receiptRevision),
      isFalse,
    );
  });

  testWidgets(
      'Today keeps its common surface while variant B exposes timeline keys',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(prototypeControllerProvider.notifier)
      ..setExperiment(PrototypeExperiment.submission)
      ..setVariant(PrototypeVariant.b);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PrototypeTodayScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-next-class')), findsOneWidget);
    expect(find.byKey(const Key('prototype-deadline-band')), findsNothing);

    container
        .read(prototypeControllerProvider.notifier)
        .setExperiment(PrototypeExperiment.today);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-deadline-band')), findsOneWidget);
    expect(find.byKey(const Key('prototype-timeline')), findsOneWidget);
  });

  testWidgets(
      'submission experiment B keeps record and external actions in detail',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);
    controller
      ..setExperiment(PrototypeExperiment.submission)
      ..setVariant(PrototypeVariant.b);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PrototypeAssignmentListScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-assignment-list')), findsOneWidget);
    expect(find.text('提出先を開く'), findsWidgets);
    expect(find.text('提出済みを記録'), findsNothing);
    expect(find.text('詳細'), findsWidgets);
  });

  testWidgets(
      'external action gives immediate feedback without changing status',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container
        .read(prototypeControllerProvider)
        .assignments
        .firstWhere((item) => item.id == 'due-today');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PrototypeAssignmentListScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('提出先を開く').first);
    await tester.pumpAndSettle();
    expect(find.text('https://example.invalid/submit'), findsOneWidget);
    expect(find.text('この試作では外部ページを開きません。送信や提出済みの記録も行いません。'), findsOneWidget);
    expect(
        container
            .read(prototypeControllerProvider)
            .assignments
            .firstWhere((item) => item.id == before.id)
            .status,
        before.status);
    await tester.tap(find.byKey(const Key('prototype-external-close')));
    await tester.pumpAndSettle();
    expect(find.text('この試作では外部ページを開きません。送信や提出済みの記録も行いません。'), findsNothing);
  });

  testWidgets('prototype settings expose selectors without resetting the app',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);
    controller.beginAdd();
    controller.updateDraft(title: '設定を開いても残る課題', dueLabel: '2026/09/18 18:00');
    controller.recordSubmission('due-today');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const UiPrototypeApp(),
    ));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('prototype-intro-acknowledge')), findsOneWidget);
    await tester.tap(find.byKey(const Key('prototype-intro-acknowledge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-settings')), findsOneWidget);
    expect(
        find.byKey(const Key('prototype-experiment-selector')), findsNothing);
    await tester.tap(find.byKey(const Key('prototype-settings')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('prototype-experiment-selector')), findsOneWidget);
    expect(find.byKey(const Key('prototype-variant-selector')), findsOneWidget);
    expect(find.byKey(const Key('prototype-fixture-selector')), findsOneWidget);
    expect(find.byKey(const Key('prototype-fixed-clock')), findsOneWidget);
    expect(find.byKey(const Key('prototype-theme-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('prototype-settings-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-settings')), findsOneWidget);
    expect(
        container.read(prototypeControllerProvider).draft.title, '設定を開いても残る課題');
    expect(
        container
            .read(prototypeControllerProvider)
            .assignments
            .firstWhere((item) => item.id == 'due-today')
            .status,
        PrototypeAssignmentStatus.submitted);
  });

  testWidgets('long fixture entry and add form remain usable at 1.5x text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(411, 914));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);
    controller
      ..setFixture(PrototypeFixture.longText)
      ..setExperiment(PrototypeExperiment.add)
      ..setVariant(PrototypeVariant.b);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: UiPrototypeApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('prototype-intro-acknowledge')), findsOneWidget);
    await tester.tap(find.byKey(const Key('prototype-intro-acknowledge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('prototype-add-from-next-course')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-add-form')), findsOneWidget);
    expect(find.byKey(const Key('prototype-title-field')), findsOneWidget);
    final exception = tester.takeException();
    expect(exception, isNull);
  });

  testWidgets(
      'manual course changes clear inherited provenance and keep full label',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);
    controller.beginAdd(courseId: 'course-a', inheritedCourse: true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PrototypeAddScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('授業起点の科目を引き継いでいます。変更できます。'), findsOneWidget);

    controller.updateDraft(
      title: '手動選択課題',
      courseId: 'course-b',
      dueLabel: '2026/09/18 18:00',
    );
    await tester.pumpAndSettle();
    expect(find.text('授業起点の科目を引き継いでいます。変更できます。'), findsNothing);
    expect(find.byKey(const Key('prototype-selected-course-full')),
        findsOneWidget);
    expect(find.textContaining('地域政策とフィールドワーク'), findsNWidgets(2));

    final id = controller.saveDraft();
    expect(id, isNotNull);
    final saved = container
        .read(prototypeControllerProvider)
        .assignments
        .firstWhere((item) => item.id == id);
    expect(saved.originatedFromCourse, isFalse);
    controller.beginEdit(saved);
    await tester.pumpAndSettle();
    expect(find.text('授業起点の科目を引き継いでいます。変更できます。'), findsNothing);
  });

  testWidgets('Android back from E2 confirmation returns to the retained form',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(prototypeControllerProvider.notifier);
    controller
      ..setExperiment(PrototypeExperiment.add)
      ..setVariant(PrototypeVariant.b)
      ..beginAdd();
    controller.updateDraft(
      title: '戻り確認課題',
      dueLabel: '2026/09/18 18:00',
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const UiPrototypeApp(),
      ),
    );
    await tester.pumpAndSettle();
    if (find
        .byKey(const Key('prototype-intro-acknowledge'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const Key('prototype-intro-acknowledge')));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const Key('prototype-intro-acknowledge')), findsNothing);
    await tester.tap(find.byIcon(Icons.add_task));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-add-form')), findsOneWidget);
    expect(container.read(prototypeControllerProvider).variant,
        PrototypeVariant.b);
    expect(find.text('基本情報'), findsOneWidget);
    final nextButton =
        find.byKey(const Key('prototype-next-confirm'), skipOffstage: false);
    await tester.drag(
        find.byKey(const Key('prototype-add-form')), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(nextButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-add-confirm')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('prototype-add-form')), findsOneWidget);
    expect(find.text('戻り確認課題'), findsOneWidget);
    expect(find.text('2026/09/18 18:00'), findsOneWidget);
  });
}
