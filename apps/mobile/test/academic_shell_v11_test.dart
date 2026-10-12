import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/app/theme/app_tokens.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';

void main() {
  for (final size in const [
    Size(360, 800),
    Size(412, 915),
    Size(1024, 900),
    Size(844, 390)
  ]) {
    testWidgets(
        'academic shell supports 2x text, keyboard and reduced motion at $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = GoRouter(routes: [
        for (final path in const [
          '/',
          '/timetable',
          '/assignments',
          '/calendar',
          '/shared',
          '/settings'
        ])
          GoRoute(
              path: path,
              builder: (_, __) => MvpScaffold(
                    title: '予定',
                    selectedIndex: const [
                      '/',
                      '/timetable',
                      '/assignments',
                      '/calendar',
                      '/shared'
                    ].indexOf(path).clamp(0, 4),
                    child: ListView(children: const [
                      Text('長い日本語の予定も確認できる学習スケジュール'),
                      TextField()
                    ]),
                  )),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(
        theme: AppTheme.dark(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: size,
            textScaler: const TextScaler.linear(2),
            disableAnimations: true,
            viewInsets: const EdgeInsets.only(bottom: 120),
          ),
          child: child!,
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final isTablet = size.width >= 840 && size.height >= 480;
      expect(find.byType(NavigationRail),
          isTablet ? findsOneWidget : findsNothing);
      expect(
          find.byType(NavigationBar), isTablet ? findsNothing : findsOneWidget);
      await tester.tap(find.text('カレンダー').last);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/calendar');
      final settings = find.byTooltip('設定');
      expect(tester.getSize(settings).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tablet navigation keeps the unsaved-change guard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var guardCalls = 0;
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (_, __) => MvpScaffold(
                title: '編集',
                selectedIndex: 0,
                onBeforeNavigate: () async {
                  guardCalls++;
                  return false;
                },
                child: const Text('編集中'),
              )),
      GoRoute(path: '/timetable', builder: (_, __) => const Text('時間割へ移動')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      theme: AppTheme.light(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: const Size(1024, 900)),
        child: child!,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.text('時間割'));
    await tester.pumpAndSettle();
    expect(guardCalls, 1);
    expect(router.state.uri.path, '/');
  });

  testWidgets(
      'OS reduced motion renders route content without a scale transition',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
                  body: TextButton(
                onPressed: () => context.go('/next'),
                child: const Text('次へ'),
              ))),
      GoRoute(
          path: '/next',
          builder: (_, __) =>
              const Scaffold(body: Text('授業の詳細', key: Key('next-content')))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      theme: AppTheme.light(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('次へ'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const Key('next-content')), findsOneWidget);
    expect(
        find.ancestor(
            of: find.byKey(const Key('next-content')),
            matching: find.byType(ScaleTransition)),
        findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  test('neutral light surface and foreground remain readable', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      for (final color in [
        theme.colorScheme.surface,
        theme.colorScheme.surfaceContainerLow
      ]) {
        final a = color.computeLuminance();
        final b = theme.colorScheme.onSurface.computeLuminance();
        final contrast =
            (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    }
    expect(AppTheme.light().colorScheme.surface, Colors.white);
    expect(AppSizes.minimumTouchTarget, 48);
  });
}
