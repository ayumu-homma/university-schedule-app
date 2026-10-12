import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';
import 'package:go_router/go_router.dart';

void main() {
  const labels = ['ホーム', '時間割', '課題・テスト', 'カレンダー', '共有'];
  const paths = ['/', '/timetable', '/assignments', '/calendar', '/shared'];

  for (final size in [const Size(320, 800), const Size(411, 800)]) {
    for (final textScale in [1.0, 1.5]) {
      testWidgets(
        'navigation labels stay within bounds at ${size.width}dp ${textScale}x',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));

          final router = GoRouter(
            initialLocation: '/',
            routes: [
              for (var index = 0; index < labels.length; index++)
                GoRoute(
                  path: paths[index],
                  builder: (_, __) => MvpScaffold(
                    title: '画面',
                    selectedIndex: index,
                    child: const SizedBox.expand(),
                  ),
                ),
            ],
          );
          addTearDown(router.dispose);

          await tester.pumpWidget(
            MaterialApp.router(
              theme: AppTheme.light(),
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: size,
                  textScaler: TextScaler.linear(textScale),
                  viewInsets: const EdgeInsets.only(bottom: 240),
                ),
                child: child!,
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          final navigationBar = tester.getRect(find.byType(NavigationBar));
          expect(navigationBar.height, greaterThanOrEqualTo(48));
          expect(navigationBar.width / labels.length, greaterThanOrEqualTo(48));
          for (var index = 0; index < labels.length; index++) {
            final label = labels[index];
            final labelRect = tester.getRect(find.text(label).last);
            final destinationLeft = navigationBar.left +
                navigationBar.width * index / labels.length;
            final destinationRight = navigationBar.left +
                navigationBar.width * (index + 1) / labels.length;
            expect(labelRect.left, greaterThanOrEqualTo(destinationLeft - 0.5));
            expect(labelRect.right, lessThanOrEqualTo(destinationRight + 0.5));
            expect(
                labelRect.top, greaterThanOrEqualTo(navigationBar.top - 0.5));
            expect(
              labelRect.bottom,
              lessThanOrEqualTo(navigationBar.bottom + 0.5),
            );

            await tester.tap(find.text(label).last);
            await tester.pumpAndSettle();
            expect(router.state.uri.path, paths[index]);
            expect(
              tester
                  .widget<NavigationBar>(find.byType(NavigationBar))
                  .selectedIndex,
              index,
            );
          }
        },
      );
    }
  }
}
