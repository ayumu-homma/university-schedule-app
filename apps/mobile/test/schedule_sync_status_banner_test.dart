import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/timetable/application/schedule_sync_runtime.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/schedule_sync_status_banner.dart';
import 'package:university_schedule_mobile/shared/widgets/mvp_scaffold.dart';

void main() {
  testWidgets('hides durable no-op sync phases', (tester) async {
    for (final phase in [
      ScheduleSyncPhase.disabled,
      ScheduleSyncPhase.idle,
      ScheduleSyncPhase.synchronized,
    ]) {
      await tester.pumpWidget(
        _bannerApp(ScheduleSyncStatus(phase: phase)),
      );

      expect(
        find.byKey(const Key('schedule-sync-status-banner')),
        findsNothing,
      );
    }
  });

  testWidgets('renders sync progress as a live status', (tester) async {
    await tester.pumpWidget(
      _bannerApp(
        const ScheduleSyncStatus(phase: ScheduleSyncPhase.running),
      ),
    );

    expect(find.text('予定を同期中です'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '予定を同期中です' &&
            widget.properties.liveRegion == true,
      ),
      findsOneWidget,
    );
  });

  testWidgets('waiting status protects local edits and retries safely',
      (tester) async {
    var retryCalls = 0;
    await tester.pumpWidget(
      _bannerApp(
        const ScheduleSyncStatus(
          phase: ScheduleSyncPhase.waitingToRetry,
          lastError: 'internal-token-must-not-render',
        ),
        onRetry: () async {
          retryCalls++;
        },
      ),
    );

    expect(
      find.text('接続できないため同期を待機中です。変更はこの端末に保存されています。'),
      findsOneWidget,
    );
    expect(find.textContaining('internal-token'), findsNothing);

    await tester.tap(find.byKey(const Key('schedule-sync-status-retry')));
    await tester.pump();

    expect(retryCalls, 1);
  });

  testWidgets('conflict and blocked statuses route users to settings',
      (tester) async {
    var settingsCalls = 0;

    await tester.pumpWidget(
      _bannerApp(
        const ScheduleSyncStatus(phase: ScheduleSyncPhase.conflict),
        onOpenSettings: () {
          settingsCalls++;
        },
      ),
    );
    expect(find.text('予定の競合があります。設定で確認してください。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-sync-status-details')));
    await tester.pump();

    await tester.pumpWidget(
      _bannerApp(
        const ScheduleSyncStatus(
          phase: ScheduleSyncPhase.blockedByLocalMutation,
        ),
        onOpenSettings: () {
          settingsCalls++;
        },
      ),
    );
    expect(find.text('同期できない変更があります。設定で確認してください。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-sync-status-details')));
    await tester.pump();

    expect(settingsCalls, 2);
  });

  testWidgets('error status omits raw failure details and offers retry',
      (tester) async {
    var retryCalls = 0;
    await tester.pumpWidget(
      _bannerApp(
        const ScheduleSyncStatus(
          phase: ScheduleSyncPhase.error,
          lastError: 'authorization-header-secret',
        ),
        onRetry: () async {
          retryCalls++;
        },
      ),
    );

    expect(
      find.text('同期で問題が発生しました。変更はこの端末に保存されています。'),
      findsOneWidget,
    );
    expect(find.textContaining('authorization-header-secret'), findsNothing);
    await tester.tap(find.byKey(const Key('schedule-sync-status-retry')));
    await tester.pump();

    expect(retryCalls, 1);
  });

  testWidgets('MvpScaffold keeps its body bounded below a scoped banner',
      (tester) async {
    await tester.pumpWidget(
      MvpScaffoldBannerScope(
        banner: const SizedBox(
          key: Key('scoped-sync-banner'),
          height: 40,
        ),
        child: MaterialApp(
          home: MvpScaffold(
            title: 'テスト',
            selectedIndex: 0,
            child: ListView(
              key: const Key('scoped-scroll-body'),
              children: const [SizedBox(height: 800)],
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('scoped-sync-banner')), findsOneWidget);
    final bodySize =
        tester.getSize(find.byKey(const Key('scoped-scroll-body')));
    expect(bodySize.height, greaterThan(0));

    await tester.drag(
      find.byKey(const Key('scoped-scroll-body')),
      const Offset(0, -200),
    );
    await tester.pump();
  });
}

Widget _bannerApp(
  ScheduleSyncStatus status, {
  Future<void> Function()? onRetry,
  VoidCallback? onOpenSettings,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ScheduleSyncStatusBanner(
        status: status,
        onRetry: onRetry,
        onOpenSettings: onOpenSettings,
      ),
    ),
  );
}
