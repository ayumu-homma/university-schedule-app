import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('local account deletion URL falls back to the implemented web route',
        () {
      final config = AppConfig.validated(
        environment: 'local',
        demoMode: true,
        webBaseUrl: 'http://127.0.0.1:3000',
      );

      expect(
        config.accountDeletionUrl.toString(),
        'http://127.0.0.1:3000/account-deletion',
      );
    });

    test('allows an explicitly selected local demo without Supabase values',
        () {
      final config = AppConfig.validated(
        environment: 'local',
        demoMode: true,
      );

      expect(config.demoMode, isTrue);
      expect(config.emailImportEnabled, isFalse);
      expect(config.supabaseUrl, isNull);
      expect(config.authRedirectUri.toString(), 'unischedule://auth-callback/');
    });

    test('fails closed when non-demo Supabase values are missing', () {
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(
          environment: 'production',
          supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co:444',
          isReleaseMode: true,
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('SUPABASE_URL does not match'),
          ),
        ),
      );
    });

    test('rejects demo mode for release and deployed environments', () {
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: true,
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'staging',
          deepLinkScheme: 'unischedule-staging',
          demoMode: false,
          supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
          stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
          productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
          webBaseUrl: 'https://staging.schedule.example.edu',
          supportUrl: 'https://support.example.com/help',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'staging',
          deepLinkScheme: 'unischedule-staging',
          demoMode: true,
          webBaseUrl: 'https://staging.example.edu',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('accepts HTTPS deployment client configuration', () {
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

      expect(config.demoMode, isFalse);
      expect(
        config.supabaseUrl!.host,
        'uvwxyz0123456789abcd.supabase.co',
      );
      expect(config.supabasePublishableKey, 'sb_publishable_mobile_test');
      expect(config.selectedSupabaseProjectRef, 'uvwxyz0123456789abcd');
      expect(config.environmentLabel, 'PRODUCTION');
      expect(
        config.accountDeletionUrl.toString(),
        'https://policy.example.edu/account-deletion',
      );
      expect(config.emailImportEnabled, isFalse);
    });

    test('rejects production configuration outside release mode', () {
      expect(
        () => _deployedConfig(environment: 'production'),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('requires a release build'),
          ),
        ),
      );
    });

    test('fails closed when a release build has no deployed APP_ENV', () {
      expect(
        () => AppConfig.fromEnvironment(isReleaseMode: true),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('Release builds require APP_ENV=staging or production'),
          ),
        ),
      );
    });

    test('binds staging and production to distinct expected project refs', () {
      expect(
        () => _deployedConfig(
          environment: 'staging',
          supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('SUPABASE_URL does not match'),
          ),
        ),
      );
      expect(
        () => AppConfig.validated(
          environment: 'production',
          demoMode: false,
          supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
          stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
          productionSupabaseProjectRef: 'abcdefghijklmnopqrst',
          webBaseUrl: 'https://schedule.example.edu',
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'production',
          demoMode: false,
          supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
          webBaseUrl: 'https://schedule.example.edu',
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('requires only the selected environment project ref', () {
      expect(
        _deployedConfig(
          environment: 'staging',
          productionSupabaseProjectRef: '',
        ).selectedSupabaseProjectRef,
        'abcdefghijklmnopqrst',
      );
      expect(
        _deployedConfig(
          environment: 'production',
          stagingSupabaseProjectRef: '',
          supabaseUrl: 'https://uvwxyz0123456789abcd.supabase.co',
          isReleaseMode: true,
        ).selectedSupabaseProjectRef,
        'uvwxyz0123456789abcd',
      );
      expect(
        () => _deployedConfig(
          environment: 'staging',
          stagingSupabaseProjectRef: '',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(
          environment: 'production',
          productionSupabaseProjectRef: '',
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('binds deployed Android configuration to the native app flavor', () {
      expect(
        () => _deployedConfig(
          environment: 'staging',
          nativeAppFlavor: 'production',
          requireNativeFlavorBinding: true,
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('Android flavor must be staging'),
          ),
        ),
      );
      expect(
        () => _deployedConfig(
          environment: 'production',
          nativeAppFlavor: 'staging',
          requireNativeFlavorBinding: true,
          isReleaseMode: true,
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('Android flavor must be production'),
          ),
        ),
      );
      final testConfig = AppConfig.validated(
        environment: 'test',
        demoMode: true,
        deepLinkScheme: 'unischedule-staging',
        nativeAppFlavor: 'staging',
        requireNativeFlavorBinding: true,
      );
      expect(testConfig.environment, AppEnvironment.test);
      expect(
        testConfig.authRedirectUri.toString(),
        'unischedule-staging://auth-callback/',
      );
      expect(
        () => AppConfig.validated(
          environment: 'test',
          demoMode: true,
          deepLinkScheme: 'unischedule',
          nativeAppFlavor: 'staging',
          requireNativeFlavorBinding: true,
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('Deep-link scheme must be unischedule-staging'),
          ),
        ),
      );
    });

    test('rejects hosted projects in local and local/test release builds', () {
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'test',
          demoMode: false,
          supabaseUrl: 'https://example.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('validates explicit policy, deletion, and support URLs', () {
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

      expect(config.privacyPolicyUrl!.path, '/privacy');
      expect(config.termsUrl!.path, '/terms');
      expect(config.accountDeletionUrl.path, '/account-deletion');
      expect(config.supportUrl!.host, 'support.example.edu');
      expect(
        () => AppConfig.validated(
          environment: 'staging',
          deepLinkScheme: 'unischedule-staging',
          demoMode: false,
          supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
          stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
          productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
          webBaseUrl: 'https://staging.schedule.example.edu',
          privacyPolicyUrl: 'http://policy.example.edu/privacy',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(environment: 'staging', accountDeletionUrl: ''),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(
          environment: 'staging',
          accountDeletionUrl:
              'http://staging.schedule.example.edu/account-deletion',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(
          environment: 'staging',
          accountDeletionUrl:
              'https://staging.schedule.example.edu/account/delete',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('requires public policy URLs explicitly in deployed environments', () {
      expect(
        () => AppConfig.validated(
          environment: 'staging',
          deepLinkScheme: 'unischedule-staging',
          demoMode: false,
          supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
          supabasePublishableKey: 'sb_publishable_mobile_test',
          stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
          productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
          webBaseUrl: 'https://staging.schedule.example.edu',
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('APP_PRIVACY_POLICY_URL is required'),
          ),
        ),
      );

      for (final url in [
        'https://localhost/privacy',
        'https://localhost./privacy',
        'https://127.0.0.1./privacy',
        'https://127.1/privacy',
        'https://2130706433/privacy',
        'https://[::ffff:127.0.0.1]/privacy',
        'https://intranet/privacy',
        'https://printer.local/privacy',
        'https://example.com./privacy',
        'https://policy.example.invalid/privacy',
        'https://policy.example.test/privacy',
        'https://policy.example.test./privacy',
      ]) {
        expect(
          () => AppConfig.validated(
            environment: 'staging',
            deepLinkScheme: 'unischedule-staging',
            demoMode: false,
            supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
            supabasePublishableKey: 'sb_publishable_mobile_test',
            stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
            productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
            webBaseUrl: 'https://staging.schedule.example.edu',
            privacyPolicyUrl: url,
            termsUrl: 'https://policy.example.edu/terms',
            accountDeletionUrl: 'https://policy.example.edu/account-deletion',
            supportUrl: 'https://support.example.edu/help',
          ),
          throwsA(isA<AppConfigException>()),
        );
      }
    });

    test('email import remains disabled unless explicitly enabled', () {
      final disabled = AppConfig.validated(
        environment: 'test',
        demoMode: true,
      );
      final explicitlyEnabled = AppConfig.validated(
        environment: 'test',
        demoMode: true,
        emailImportEnabled: true,
        emailImportGmailClientId: 'mobile-public.apps.googleusercontent.com',
      );

      expect(disabled.emailImportEnabled, isFalse);
      expect(explicitlyEnabled.emailImportEnabled, isTrue);
      expect(
        explicitlyEnabled.emailImportGmailClientId,
        'mobile-public.apps.googleusercontent.com',
      );
    });

    test('enabled email import requires an exact public Gmail client id', () {
      for (final clientId in [
        '',
        'contains whitespace.apps.googleusercontent.com',
        'client.example.invalid',
      ]) {
        expect(
          () => AppConfig.validated(
            environment: 'test',
            demoMode: true,
            emailImportEnabled: true,
            emailImportGmailClientId: clientId,
          ),
          throwsA(isA<AppConfigException>()),
        );
      }
    });

    test('allows local emulator HTTP only for local development', () {
      final local = AppConfig.validated(
        environment: 'local',
        demoMode: false,
        supabaseUrl: 'http://10.0.2.2:54321',
        legacySupabaseAnonKey: 'local-anon-client-key',
        webBaseUrl: 'http://10.0.2.2:3000',
      );

      expect(local.supabaseUrl!.host, '10.0.2.2');
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: 'http://10.0.2.2:54321',
          legacySupabaseAnonKey: 'local-anon-client-key',
          webBaseUrl: 'https://schedule.example.edu',
          isReleaseMode: true,
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => _deployedConfig(
          environment: 'production',
          supabaseUrl: 'http://uvwxyz0123456789abcd.supabase.co',
          isReleaseMode: true,
        ),
        throwsA(
          isA<AppConfigException>().having(
            (error) => error.message,
            'message',
            contains('SUPABASE_URL must use HTTPS'),
          ),
        ),
      );
    });

    test('rejects server-side keys and conflicting client keys', () {
      expect(
        () => AppConfig.validated(
          environment: 'test',
          demoMode: true,
          supabasePublishableKey: 'sb_secret_embedded_but_unused',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: 'http://127.0.0.1:54321',
          legacySupabaseAnonKey: _jwtForRole('service_role'),
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: 'http://127.0.0.1:54321',
          supabasePublishableKey: 'sb_secret_do_not_embed',
        ),
        throwsA(isA<AppConfigException>()),
      );
      expect(
        () => AppConfig.validated(
          environment: 'local',
          demoMode: false,
          supabaseUrl: 'http://127.0.0.1:54321',
          supabasePublishableKey: 'publishable-a',
          legacySupabaseAnonKey: 'anon-b',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });

    test('accepts only publishable or anon-role keys when deployed', () {
      AppConfig buildWithKey(String key) => AppConfig.validated(
            environment: 'staging',
            deepLinkScheme: 'unischedule-staging',
            demoMode: false,
            supabaseUrl: 'https://abcdefghijklmnopqrst.supabase.co',
            supabasePublishableKey: key,
            stagingSupabaseProjectRef: 'abcdefghijklmnopqrst',
            productionSupabaseProjectRef: 'uvwxyz0123456789abcd',
            webBaseUrl: 'https://staging.schedule.example.edu',
            privacyPolicyUrl: 'https://policy.example.edu/privacy',
            termsUrl: 'https://policy.example.edu/terms',
            accountDeletionUrl: 'https://policy.example.edu/account-deletion',
            supportUrl: 'https://support.example.edu/help',
          );

      expect(buildWithKey('sb_publishable_mobile_test').environment,
          AppEnvironment.staging);
      expect(buildWithKey(_jwtForRole('anon')).environment,
          AppEnvironment.staging);
      for (final key in [
        'opaque-client-looking-value',
        _jwtForRole('authenticated'),
        _jwtForRole('service_role'),
      ]) {
        expect(() => buildWithKey(key), throwsA(isA<AppConfigException>()));
      }
    });

    test('rejects a scheme that does not match the Android manifest', () {
      expect(
        () => AppConfig.validated(
          environment: 'test',
          demoMode: true,
          deepLinkScheme: 'different-app',
        ),
        throwsA(isA<AppConfigException>()),
      );
    });
  });
}

String _jwtForRole(String role) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none'})}.${encode({'role': role})}.signature';
}

AppConfig _deployedConfig({
  required String environment,
  String? supabaseUrl,
  String accountDeletionUrl = 'https://policy.example.edu/account-deletion',
  String stagingSupabaseProjectRef = 'abcdefghijklmnopqrst',
  String productionSupabaseProjectRef = 'uvwxyz0123456789abcd',
  String nativeAppFlavor = '',
  bool requireNativeFlavorBinding = false,
  bool isReleaseMode = false,
}) {
  final production = environment == 'production';
  return AppConfig.validated(
    environment: environment,
    demoMode: false,
    supabaseUrl: supabaseUrl ??
        (production
            ? 'https://uvwxyz0123456789abcd.supabase.co'
            : 'https://abcdefghijklmnopqrst.supabase.co'),
    supabasePublishableKey: 'sb_publishable_mobile_test',
    deepLinkScheme: production ? 'unischedule' : 'unischedule-staging',
    stagingSupabaseProjectRef: stagingSupabaseProjectRef,
    productionSupabaseProjectRef: productionSupabaseProjectRef,
    webBaseUrl: production
        ? 'https://schedule.example.edu'
        : 'https://staging.schedule.example.edu',
    privacyPolicyUrl: 'https://policy.example.edu/privacy',
    termsUrl: 'https://policy.example.edu/terms',
    accountDeletionUrl: accountDeletionUrl,
    supportUrl: 'https://support.example.edu/help',
    nativeAppFlavor: nativeAppFlavor,
    requireNativeFlavorBinding: requireNativeFlavorBinding,
    isReleaseMode: isReleaseMode,
  );
}
