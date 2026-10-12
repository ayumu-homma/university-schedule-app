import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/features/settings/presentation/account_policy_settings_section.dart';

void main() {
  testWidgets('opens validated policy links and starts in-app deletion flow',
      (tester) async {
    final opened = <Uri>[];
    final config = _productionConfig();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                AccountPolicySettingsSection(
                  config: config,
                  accountDeletionEnabled: true,
                  launchExternalUri: (uri) async {
                    opened.add(uri);
                    return true;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('privacy-policy-settings-tile')));
    await tester.pump();
    expect(opened.single.toString(), 'https://policy.example.edu/privacy');

    await tester.tap(find.byKey(const Key('account-deletion-settings-tile')));
    await tester.pump();
    expect(find.text('削除サービスを利用できません。通信設定を確認してください。'), findsOneWidget);
    expect(opened, hasLength(1));
  });

  testWidgets('demo or signed-out state cannot initiate account deletion',
      (tester) async {
    final config = AppConfig.demoForTesting();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AccountPolicySettingsSection(
              config: config,
              accountDeletionEnabled: false,
              launchExternalUri: (_) async => true,
            ),
          ),
        ),
      ),
    );

    final tile = tester.widget<ListTile>(
      find.byKey(const Key('account-deletion-settings-tile')),
    );
    expect(tile.enabled, isFalse);
    expect(tile.onTap, isNull);
  });

  for (final throwsException in [false, true]) {
    testWidgets(
        'link launcher ${throwsException ? 'exception' : 'false'} is handled',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AccountPolicySettingsSection(
                config: _productionConfig(),
                accountDeletionEnabled: true,
                launchExternalUri: (_) async {
                  if (throwsException) {
                    throw StateError('synthetic launch error');
                  }
                  return false;
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('privacy-policy-settings-tile')));
      await tester.pump();
      expect(find.text('ページを開けませんでした。設定を確認してください。'), findsOneWidget);
    });
  }
}

AppConfig _productionConfig() => AppConfig.validated(
      environment: 'production',
      demoMode: false,
      supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
      supabasePublishableKey: 'sb_publishable_mobile_test',
      stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
      productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
      webBaseUrl: 'https://schedule.example.edu',
      privacyPolicyUrl: 'https://policy.example.edu/privacy',
      termsUrl: 'https://policy.example.edu/terms',
      accountDeletionUrl: 'https://policy.example.edu/account-deletion',
      supportUrl: 'https://support.example.edu/help',
      isReleaseMode: true,
    );
