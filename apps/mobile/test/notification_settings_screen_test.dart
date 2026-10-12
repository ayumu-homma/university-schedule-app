import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/app/theme/app_tokens.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_platform.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';
import 'package:university_schedule_mobile/features/notification/presentation/notification_settings_screen.dart';

void main() {
  testWidgets('morning alarm starts OFF and persists a real enabled schedule',
      (tester) async {
    final now = JapanTime.at(
      year: 2026,
      month: 8,
      day: 10,
      hour: 6,
    );
    final platform = InMemoryMorningAlarmPlatform(now: () => now);
    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(const Key('morning-alarm-enabled-switch'));
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
    expect(find.text('OFF（端末のアラームは登録されていません）'), findsOneWidget);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    expect(find.textContaining('次回 8/10（月） 07:30'), findsOneWidget);
    expect((await platform.refresh('owner-a')).settings!.enabled, isTrue);
  });

  testWidgets('permission request follows an in-app value explanation',
      (tester) async {
    final platform = InMemoryMorningAlarmPlatform(
      capabilities: const MorningAlarmCapabilities(
        notificationPermission: AlarmPermissionStatus.denied,
        schedulePrecision: AlarmSchedulePrecision.inexact,
        fullScreenAllowed: false,
        debugTestAllowed: false,
      ),
    );
    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('morning-alarm-enabled-switch')));
    await tester.pumpAndSettle();

    expect(find.text('朝の予定を知らせるために'), findsOneWidget);
    expect((await platform.refresh('owner-a')).settings!.enabled, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, '続ける'));
    await tester.pumpAndSettle();

    expect((await platform.refresh('owner-a')).settings!.enabled, isTrue);
  });

  testWidgets('weekday selection cannot become empty', (tester) async {
    final platform = InMemoryMorningAlarmPlatform();
    var settings = MorningAlarmSettings(
      ownerUserId: 'owner-a',
      weekdays: const {DateTime.monday},
    );
    await platform.synchronizeOwner('owner-a');
    await platform.save(settings);
    await tester.pumpWidget(_app(platform));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('morning-alarm-weekday-1')));
    await tester.pumpAndSettle();

    expect(find.text('曜日を1つ以上選んでください'), findsOneWidget);
    settings = (await platform.refresh('owner-a')).settings!;
    expect(settings.weekdays, {DateTime.monday});
  });

  testWidgets('loading state has a live accessible name', (tester) async {
    final semantics = tester.ensureSemantics();
    final platform = _DelayedMorningAlarmPlatform();

    await tester.pumpWidget(_app(platform));
    await tester.pump();

    final loadingSemantics = find.bySemanticsLabel(
      '朝の確認アラーム設定を読み込み中',
    );
    expect(loadingSemantics, findsOneWidget);
    expect(
      tester.getSemantics(loadingSemantics),
      isSemantics(
        label: '朝の確認アラーム設定を読み込み中',
        isLiveRegion: true,
      ),
    );

    platform.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('朝の確認'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'dark large-text portrait and landscape keep alarm controls accessible',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(() => tester.binding.setSurfaceSize(null));

      for (final scenario in <({Size size, double textScale})>[
        (size: const Size(360, 640), textScale: 2),
        (size: const Size(640, 360), textScale: 1.3),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.binding.setSurfaceSize(scenario.size);
        await tester.pumpWidget(
          _app(
            InMemoryMorningAlarmPlatform(),
            themeMode: ThemeMode.dark,
            textScale: scenario.textScale,
            accessibleNavigation: true,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final headingSemantics = find.bySemanticsLabel('朝の確認');
        expect(headingSemantics, findsOneWidget);
        expect(
          tester.getSemantics(headingSemantics),
          isSemantics(label: '朝の確認', isHeader: true),
        );
        expect(
          tester
              .getSize(
                find.byKey(const Key('morning-alarm-enabled-switch')),
              )
              .height,
          greaterThanOrEqualTo(AppSizes.minimumTouchTarget),
        );

        final settingsScrollable = find.descendant(
          of: find.byKey(const Key('morning-alarm-settings-list')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.text('端末の許可状態'),
          180,
          scrollable: settingsScrollable,
        );
        await tester.pumpAndSettle();
        expect(find.text('端末の許可状態'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('morning-alarm-notification-capability')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(
            find.byKey(const Key('morning-alarm-notification-capability')),
          ),
          isSemantics(label: '通知: 許可済み'),
        );
        await tester.ensureVisible(
          find.byKey(const Key('morning-alarm-precision-capability')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(
            find.byKey(const Key('morning-alarm-precision-capability')),
          ),
          isSemantics(label: '時刻精度: 正確なアラーム'),
        );
        await tester.ensureVisible(
          find.byKey(const Key('morning-alarm-full-screen-capability')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(
            find.byKey(const Key('morning-alarm-full-screen-capability')),
          ),
          isSemantics(label: '全画面表示: 利用可能'),
        );
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );
}

Widget _app(
  MorningAlarmPlatform platform, {
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
  bool accessibleNavigation = false,
}) {
  return ProviderScope(
    overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'owner-a'),
      ),
      morningAlarmPlatformProvider.overrideWithValue(platform),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          accessibleNavigation: accessibleNavigation,
          disableAnimations: accessibleNavigation,
        ),
        child: child!,
      ),
      home: const NotificationSettingsScreen(),
    ),
  );
}

class _DelayedMorningAlarmPlatform extends InMemoryMorningAlarmPlatform {
  final Completer<void> release = Completer<void>();

  @override
  Future<MorningAlarmPlatformState> synchronizeOwner(
    String? ownerUserId, {
    NativeScopeState? expectedScope,
  }) async {
    await release.future;
    return super.synchronizeOwner(ownerUserId, expectedScope: expectedScope);
  }
}
