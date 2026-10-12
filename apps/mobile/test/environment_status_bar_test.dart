import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/environment_status_bar.dart';

void main() {
  testWidgets('staging is clearly identified without exposing project details',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final config = AppConfig.validated(
      environment: 'staging',
      deepLinkScheme: 'unischedule-staging',
      demoMode: false,
      supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
      supabasePublishableKey: 'sb_publishable_mobile_test',
      stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
      productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
      webBaseUrl: 'https://staging.schedule.example.edu',
      privacyPolicyUrl: 'https://policy.example.edu/privacy',
      termsUrl: 'https://policy.example.edu/terms',
      accountDeletionUrl: 'https://policy.example.edu/account-deletion',
      supportUrl: 'https://support.example.edu/help',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EnvironmentStatusBar(
          config: config,
          child: const Placeholder(),
        ),
      ),
    );

    expect(find.byKey(const Key('environment-status-bar')), findsOneWidget);
    expect(find.text('STAGING'), findsOneWidget);
    expect(find.bySemanticsLabel('実行環境: STAGING'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^STAGING$')), findsNothing);
    expect(find.textContaining('abcdefghijklmnopqrst'), findsNothing);
    semantics.dispose();
  });

  testWidgets('production never renders a debug environment ribbon',
      (tester) async {
    final config = AppConfig.validated(
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

    await tester.pumpWidget(
      MaterialApp(
        home: EnvironmentStatusBar(
          config: config,
          child: const Placeholder(key: Key('production-content')),
        ),
      ),
    );

    expect(find.byKey(const Key('environment-status-bar')), findsNothing);
    expect(find.byKey(const Key('production-content')), findsOneWidget);
  });
}
