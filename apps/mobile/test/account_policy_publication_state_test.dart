import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/features/settings/presentation/account_policy_settings_section.dart';

void main() {
  test('local placeholder base does not publish policy URLs', () {
    final config = AppConfig.demoForTesting();

    expect(config.privacyPolicyUrl, isNull);
    expect(config.termsUrl, isNull);
    expect(config.supportUrl, isNull);
  });

  test('local web base resolves to the public policy route paths', () {
    final config = AppConfig.validated(
      environment: 'local',
      demoMode: true,
      webBaseUrl: 'http://127.0.0.1:3000',
    );

    expect(
      config.privacyPolicyUrl,
      Uri.parse('http://127.0.0.1:3000/privacy'),
    );
    expect(
      config.termsUrl,
      Uri.parse('http://127.0.0.1:3000/terms'),
    );
    expect(
      config.supportUrl,
      Uri.parse('http://127.0.0.1:3000/support'),
    );
  });

  test('invalid local policy URLs are treated as unpublished', () {
    final config = AppConfig.validated(
      environment: 'local',
      demoMode: true,
      privacyPolicyUrl: 'https://example.com/privacy',
      termsUrl: 'http://policy.example.edu/terms',
      supportUrl: 'not a URL',
    );

    expect(config.privacyPolicyUrl, isNull);
    expect(config.termsUrl, isNull);
    expect(config.supportUrl, isNull);
  });

  testWidgets('unpublished policy links are disabled and never launched', (
    tester,
  ) async {
    final config = AppConfig.demoForTesting();
    final opened = <Uri>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AccountPolicySettingsSection(
              config: config,
              launchExternalUri: (uri) async {
                opened.add(uri);
                return true;
              },
              accountDeletionEnabled: false,
            ),
          ),
        ),
      ),
    );

    for (final key in const [
      Key('privacy-policy-settings-tile'),
      Key('terms-settings-tile'),
      Key('support-settings-tile'),
    ]) {
      final tile = tester.widget<ListTile>(find.byKey(key));
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
    }
    expect(find.text('公開準備中'), findsNWidgets(3));

    await tester.tap(find.byKey(const Key('privacy-policy-settings-tile')));
    await tester.pump();
    expect(opened, isEmpty);
  });

  testWidgets('configured HTTPS policy URLs reach the launcher unchanged', (
    tester,
  ) async {
    const privacyUrl = 'https://policy.example.edu/privacy';
    const termsUrl = 'https://policy.example.edu/terms';
    const supportUrl = 'https://support.example.edu/help';
    final config = AppConfig.validated(
      environment: 'local',
      demoMode: true,
      privacyPolicyUrl: privacyUrl,
      termsUrl: termsUrl,
      supportUrl: supportUrl,
    );
    final opened = <Uri>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: AccountPolicySettingsSection(
              config: config,
              launchExternalUri: (uri) async {
                opened.add(uri);
                return true;
              },
              accountDeletionEnabled: false,
            ),
          ),
        ),
      ),
    );

    for (final key in const [
      Key('privacy-policy-settings-tile'),
      Key('terms-settings-tile'),
      Key('support-settings-tile'),
    ]) {
      await tester.tap(find.byKey(key));
      await tester.pump();
    }

    expect(opened,
        [Uri.parse(privacyUrl), Uri.parse(termsUrl), Uri.parse(supportUrl)]);
  });
}
