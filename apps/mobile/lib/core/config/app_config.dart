import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' as services;

enum AppEnvironment { local, test, staging, production }

class AppConfigException implements Exception {
  const AppConfigException(this.message);

  final String message;

  @override
  String toString() => 'AppConfigException: $message';
}

class AppConfig {
  const AppConfig._({
    required this.environment,
    required this.demoMode,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.stagingSupabaseProjectRef,
    required this.productionSupabaseProjectRef,
    required this.deepLinkScheme,
    required this.webBaseUrl,
    required this.privacyPolicyUrl,
    required this.termsUrl,
    required this.accountDeletionUrl,
    required this.supportUrl,
    required this.emailImportEnabled,
    required this.emailImportGmailClientId,
    required this.documentImportEnabled,
  });

  factory AppConfig.fromEnvironment({bool isReleaseMode = kReleaseMode}) {
    const publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const legacyAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    return AppConfig.validated(
      environment: const String.fromEnvironment(
        'APP_ENV',
        defaultValue: 'local',
      ),
      demoMode: const bool.fromEnvironment(
        'APP_DEMO_MODE',
        defaultValue: false,
      ),
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: publishableKey,
      legacySupabaseAnonKey: legacyAnonKey,
      stagingSupabaseProjectRef: const String.fromEnvironment(
        'STAGING_SUPABASE_PROJECT_REF',
      ),
      productionSupabaseProjectRef: const String.fromEnvironment(
        'PRODUCTION_SUPABASE_PROJECT_REF',
      ),
      deepLinkScheme: const String.fromEnvironment(
        'APP_DEEP_LINK_SCHEME',
        defaultValue: 'unischedule',
      ),
      webBaseUrl: const String.fromEnvironment(
        'APP_WEB_BASE_URL',
        defaultValue: 'https://example.com',
      ),
      privacyPolicyUrl: const String.fromEnvironment(
        'APP_PRIVACY_POLICY_URL',
      ),
      termsUrl: const String.fromEnvironment('APP_TERMS_URL'),
      accountDeletionUrl: const String.fromEnvironment(
        'APP_ACCOUNT_DELETION_URL',
      ),
      supportUrl: const String.fromEnvironment('APP_SUPPORT_URL'),
      emailImportEnabled: const bool.fromEnvironment(
        'EMAIL_IMPORT_ENABLED',
        defaultValue: false,
      ),
      emailImportGmailClientId: const String.fromEnvironment(
        'EMAIL_IMPORT_GMAIL_CLIENT_ID',
      ),
      documentImportEnabled: const bool.fromEnvironment(
        'DOCUMENT_IMPORT_ENABLED',
        defaultValue: false,
      ),
      isReleaseMode: isReleaseMode,
      nativeAppFlavor: services.appFlavor ?? '',
      requireNativeFlavorBinding:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
    );
  }

  factory AppConfig.validated({
    required String environment,
    required bool demoMode,
    String supabaseUrl = '',
    String supabasePublishableKey = '',
    String legacySupabaseAnonKey = '',
    String stagingSupabaseProjectRef = '',
    String productionSupabaseProjectRef = '',
    String deepLinkScheme = 'unischedule',
    String webBaseUrl = 'https://example.com',
    String privacyPolicyUrl = '',
    String termsUrl = '',
    String accountDeletionUrl = '',
    String supportUrl = '',
    bool emailImportEnabled = false,
    String emailImportGmailClientId = '',
    bool documentImportEnabled = false,
    bool isReleaseMode = false,
    String nativeAppFlavor = '',
    bool requireNativeFlavorBinding = false,
  }) {
    final parsedEnvironment = _parseEnvironment(environment);
    final normalizedPublishableKey = supabasePublishableKey.trim();
    final normalizedLegacyKey = legacySupabaseAnonKey.trim();
    if (normalizedPublishableKey.isNotEmpty &&
        normalizedLegacyKey.isNotEmpty &&
        normalizedPublishableKey != normalizedLegacyKey) {
      throw const AppConfigException(
        'Conflicting Supabase client keys were supplied.',
      );
    }
    final clientKey = normalizedPublishableKey.isNotEmpty
        ? normalizedPublishableKey
        : normalizedLegacyKey;

    if (clientKey.isNotEmpty && _looksLikeSecretKey(clientKey)) {
      throw const AppConfigException(
        'A server-side Supabase key cannot be used by the mobile app.',
      );
    }

    if (demoMode &&
        (isReleaseMode ||
            parsedEnvironment == AppEnvironment.staging ||
            parsedEnvironment == AppEnvironment.production)) {
      throw const AppConfigException(
        'Demo mode is limited to local and test environments.',
      );
    }
    if (isReleaseMode &&
        (parsedEnvironment == AppEnvironment.local ||
            parsedEnvironment == AppEnvironment.test)) {
      throw const AppConfigException(
        'Release builds require APP_ENV=staging or production.',
      );
    }
    if (parsedEnvironment == AppEnvironment.production && !isReleaseMode) {
      throw const AppConfigException(
        'APP_ENV=production requires a release build.',
      );
    }

    final normalizedStagingProjectRef = _validatedProjectRef(
      stagingSupabaseProjectRef,
      variableName: 'STAGING_SUPABASE_PROJECT_REF',
    );
    final normalizedProductionProjectRef = _validatedProjectRef(
      productionSupabaseProjectRef,
      variableName: 'PRODUCTION_SUPABASE_PROJECT_REF',
    );
    final isDeployedEnvironment = parsedEnvironment == AppEnvironment.staging ||
        parsedEnvironment == AppEnvironment.production;
    if (requireNativeFlavorBinding) {
      final expectedFlavor = parsedEnvironment == AppEnvironment.production
          ? 'production'
          : 'staging';
      if (nativeAppFlavor.trim().toLowerCase() != expectedFlavor) {
        throw AppConfigException(
          'Android flavor must be $expectedFlavor for the selected '
          'environment.',
        );
      }
    }
    if (isDeployedEnvironment &&
        clientKey.isNotEmpty &&
        !_isAllowedDeployedClientKey(clientKey)) {
      throw const AppConfigException(
        'Deployed environments require a Supabase publishable key or a '
        'legacy anon-role key.',
      );
    }
    if (normalizedStagingProjectRef.isNotEmpty &&
        normalizedProductionProjectRef.isNotEmpty &&
        normalizedStagingProjectRef == normalizedProductionProjectRef) {
      throw const AppConfigException(
        'Staging and production must use different Supabase projects.',
      );
    }
    final expectedProjectRef = switch (parsedEnvironment) {
      AppEnvironment.staging => normalizedStagingProjectRef,
      AppEnvironment.production => normalizedProductionProjectRef,
      _ => '',
    };
    if (isDeployedEnvironment && expectedProjectRef.isEmpty) {
      final variableName = parsedEnvironment == AppEnvironment.staging
          ? 'STAGING_SUPABASE_PROJECT_REF'
          : 'PRODUCTION_SUPABASE_PROJECT_REF';
      throw AppConfigException(
        '$variableName is required for the selected environment.',
      );
    }

    final normalizedScheme = deepLinkScheme.trim().toLowerCase();
    final allowedSchemes = switch (parsedEnvironment) {
      AppEnvironment.staging => const {'unischedule-staging'},
      AppEnvironment.production => const {'unischedule'},
      AppEnvironment.local || AppEnvironment.test => const {
          'unischedule',
          'unischedule-staging',
        },
    };
    if (!allowedSchemes.contains(normalizedScheme) ||
        !RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(normalizedScheme)) {
      throw const AppConfigException(
        'The mobile deep-link scheme does not match the installed app.',
      );
    }
    if (requireNativeFlavorBinding) {
      final expectedNativeScheme =
          nativeAppFlavor.trim().toLowerCase() == 'production'
              ? 'unischedule'
              : 'unischedule-staging';
      if (normalizedScheme != expectedNativeScheme) {
        throw AppConfigException(
          'Deep-link scheme must be $expectedNativeScheme for the Android '
          'flavor.',
        );
      }
    }

    final webUri = _validatedWebBaseUrl(
      webBaseUrl,
      environment: parsedEnvironment,
      allowLocalHttp: !isReleaseMode,
    );
    final privacyUri = _validatedOptionalPublicUrl(
      privacyPolicyUrl,
      fallback: isDeployedEnvironment
          ? null
          : _policyPageFallback(webUri, '/privacy'),
      environment: parsedEnvironment,
      allowLocalHttp: !isReleaseMode,
      variableName: 'APP_PRIVACY_POLICY_URL',
    );
    final termsUri = _validatedOptionalPublicUrl(
      termsUrl,
      fallback:
          isDeployedEnvironment ? null : _policyPageFallback(webUri, '/terms'),
      environment: parsedEnvironment,
      allowLocalHttp: !isReleaseMode,
      variableName: 'APP_TERMS_URL',
    );
    final deletionUri = _validatedPublicUrl(
      accountDeletionUrl,
      fallback:
          isDeployedEnvironment ? null : webUri.resolve('/account-deletion'),
      environment: parsedEnvironment,
      allowLocalHttp: !isReleaseMode,
      variableName: 'APP_ACCOUNT_DELETION_URL',
    );
    if (deletionUri.path != '/account-deletion') {
      throw const AppConfigException(
        'APP_ACCOUNT_DELETION_URL must point to /account-deletion.',
      );
    }
    final supportUri = _validatedOptionalPublicUrl(
      supportUrl,
      fallback: isDeployedEnvironment
          ? null
          : _policyPageFallback(webUri, '/support'),
      environment: parsedEnvironment,
      allowLocalHttp: !isReleaseMode,
      variableName: 'APP_SUPPORT_URL',
    );
    final normalizedGmailClientId = emailImportGmailClientId.trim();
    if (emailImportEnabled &&
        !_gmailClientIdPattern.hasMatch(normalizedGmailClientId)) {
      throw const AppConfigException(
        'EMAIL_IMPORT_GMAIL_CLIENT_ID is required when email import is enabled.',
      );
    }
    if (normalizedGmailClientId.isNotEmpty &&
        !_gmailClientIdPattern.hasMatch(normalizedGmailClientId)) {
      throw const AppConfigException(
        'EMAIL_IMPORT_GMAIL_CLIENT_ID is invalid.',
      );
    }

    Uri? supabaseUri;
    if (!demoMode) {
      if (supabaseUrl.trim().isEmpty || clientKey.isEmpty) {
        throw const AppConfigException(
          'Supabase client configuration is required outside demo mode.',
        );
      }
      supabaseUri = _validatedSupabaseUrl(
        supabaseUrl,
        environment: parsedEnvironment,
        allowLocalHttp: !isReleaseMode,
        expectedProjectRef: expectedProjectRef,
      );
    } else if (supabaseUrl.trim().isNotEmpty) {
      supabaseUri = _validatedSupabaseUrl(
        supabaseUrl,
        environment: parsedEnvironment,
        allowLocalHttp: !isReleaseMode,
        expectedProjectRef: expectedProjectRef,
      );
    }

    return AppConfig._(
      environment: parsedEnvironment,
      demoMode: demoMode,
      supabaseUrl: supabaseUri,
      supabasePublishableKey: clientKey,
      stagingSupabaseProjectRef: normalizedStagingProjectRef,
      productionSupabaseProjectRef: normalizedProductionProjectRef,
      deepLinkScheme: normalizedScheme,
      webBaseUrl: webUri,
      privacyPolicyUrl: privacyUri,
      termsUrl: termsUri,
      accountDeletionUrl: deletionUri,
      supportUrl: supportUri,
      emailImportEnabled: emailImportEnabled,
      emailImportGmailClientId: normalizedGmailClientId,
      documentImportEnabled: documentImportEnabled,
    );
  }

  factory AppConfig.demoForTesting() {
    return AppConfig.validated(environment: 'test', demoMode: true);
  }

  final AppEnvironment environment;
  final bool demoMode;
  final Uri? supabaseUrl;
  final String supabasePublishableKey;
  final String stagingSupabaseProjectRef;
  final String productionSupabaseProjectRef;
  final String deepLinkScheme;
  final Uri webBaseUrl;
  final Uri? privacyPolicyUrl;
  final Uri? termsUrl;
  final Uri accountDeletionUrl;
  final Uri? supportUrl;
  final bool emailImportEnabled;
  final String emailImportGmailClientId;
  final bool documentImportEnabled;

  bool get platformDeepLinksEnabled => environment != AppEnvironment.test;

  String get environmentLabel => environment.name.toUpperCase();

  String? get selectedSupabaseProjectRef => switch (environment) {
        AppEnvironment.staging => stagingSupabaseProjectRef,
        AppEnvironment.production => productionSupabaseProjectRef,
        _ => null,
      };

  Uri get authRedirectUri =>
      Uri(scheme: deepLinkScheme, host: 'auth-callback', path: '/');

  Uri? get emailImportOAuthRedirectUri => supabaseUrl?.replace(
        path: '/functions/v1/email-import',
        query: null,
        fragment: null,
      );

  static AppEnvironment _parseEnvironment(String raw) {
    final normalized = raw.trim().toLowerCase();
    return AppEnvironment.values.firstWhere(
      (value) => value.name == normalized,
      orElse: () => throw const AppConfigException(
        'APP_ENV must be local, test, staging, or production.',
      ),
    );
  }

  static Uri _validatedSupabaseUrl(
    String raw, {
    required AppEnvironment environment,
    required bool allowLocalHttp,
    required String expectedProjectRef,
  }) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AppConfigException('SUPABASE_URL is invalid.');
    }
    if (_isLocalEnvironment(environment) && !_isLoopbackHost(uri.host)) {
      throw const AppConfigException(
        'APP_ENV=local/test may connect only to a loopback Supabase instance.',
      );
    }
    if ((environment == AppEnvironment.staging ||
            environment == AppEnvironment.production) &&
        (uri.hasPort ||
            expectedProjectRef.isEmpty ||
            uri.host != '$expectedProjectRef.supabase.co')) {
      throw const AppConfigException(
        'SUPABASE_URL does not match the selected environment project ref.',
      );
    }
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' &&
        allowLocalHttp &&
        _isLocalEnvironment(environment) &&
        _isLoopbackHost(uri.host)) {
      return uri;
    }
    throw const AppConfigException(
      'SUPABASE_URL must use HTTPS outside local development.',
    );
  }

  static String _validatedProjectRef(
    String raw, {
    required String variableName,
  }) {
    final normalized = raw.trim().toLowerCase();
    if (normalized.isEmpty) return '';
    if (!_projectRefPattern.hasMatch(normalized)) {
      throw AppConfigException('$variableName is invalid.');
    }
    return normalized;
  }

  static Uri _validatedPublicUrl(
    String raw, {
    required Uri? fallback,
    required AppEnvironment environment,
    required bool allowLocalHttp,
    required String variableName,
  }) {
    final normalized = raw.trim();
    final isDeployed = environment == AppEnvironment.staging ||
        environment == AppEnvironment.production;
    if (normalized.isEmpty && isDeployed) {
      throw AppConfigException(
        '$variableName is required for deployed environments.',
      );
    }
    final candidate = normalized.isEmpty ? fallback : Uri.tryParse(normalized);
    if (candidate == null ||
        !candidate.hasScheme ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty ||
        candidate.hasQuery ||
        candidate.hasFragment ||
        (candidate.scheme != 'https' &&
            !(allowLocalHttp &&
                _isLocalEnvironment(environment) &&
                candidate.scheme == 'http' &&
                _isLoopbackHost(candidate.host)))) {
      throw AppConfigException('$variableName is invalid.');
    }
    if (isDeployed && _isReservedOrLoopbackHost(candidate.host)) {
      throw AppConfigException(
        '$variableName must use a public, non-placeholder host.',
      );
    }
    return candidate;
  }

  static Uri? _validatedOptionalPublicUrl(
    String raw, {
    required Uri? fallback,
    required AppEnvironment environment,
    required bool allowLocalHttp,
    required String variableName,
  }) {
    final isDeployed = environment == AppEnvironment.staging ||
        environment == AppEnvironment.production;
    if (raw.trim().isEmpty && fallback == null && !isDeployed) return null;
    try {
      final candidate = _validatedPublicUrl(
        raw,
        fallback: fallback,
        environment: environment,
        allowLocalHttp: allowLocalHttp,
        variableName: variableName,
      );
      if (!isDeployed &&
          !_isLoopbackHost(candidate.host) &&
          _isReservedOrLoopbackHost(candidate.host)) {
        return null;
      }
      return candidate;
    } on AppConfigException {
      if (isDeployed) rethrow;
      return null;
    }
  }

  static Uri? _policyPageFallback(Uri webBaseUrl, String path) {
    if (_isReservedOrLoopbackHost(webBaseUrl.host) &&
        !_isLoopbackHost(webBaseUrl.host)) {
      return null;
    }
    return webBaseUrl.resolve(path);
  }

  static Uri _validatedWebBaseUrl(
    String raw, {
    required AppEnvironment environment,
    required bool allowLocalHttp,
  }) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(allowLocalHttp &&
                uri.scheme == 'http' &&
                _isLocalEnvironment(environment) &&
                _isLoopbackHost(uri.host)))) {
      throw const AppConfigException('APP_WEB_BASE_URL is invalid.');
    }
    if ((environment == AppEnvironment.staging ||
            environment == AppEnvironment.production) &&
        _isReservedOrLoopbackHost(uri.host)) {
      throw const AppConfigException(
        'APP_WEB_BASE_URL must be configured for deployed environments.',
      );
    }
    return uri;
  }

  static bool _isLocalEnvironment(AppEnvironment environment) {
    return environment == AppEnvironment.local ||
        environment == AppEnvironment.test;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = _normalizedHost(host);
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '::ffff:127.0.0.1' ||
        normalized == '::ffff:7f00:1' ||
        normalized == '0.0.0.0' ||
        normalized == '10.0.2.2';
  }

  static bool _isReservedOrLoopbackHost(String host) {
    final normalized = _normalizedHost(host);
    return normalized.isEmpty ||
        !normalized.contains('.') ||
        normalized.endsWith('.local') ||
        RegExp(r'^[0-9.]+$').hasMatch(normalized) ||
        _isLoopbackHost(normalized) ||
        _isIpLiteral(normalized) ||
        normalized == 'example.com' ||
        normalized == 'example.net' ||
        normalized == 'example.org' ||
        normalized.endsWith('.example.com') ||
        normalized.endsWith('.example.net') ||
        normalized.endsWith('.example.org') ||
        normalized.endsWith('.example') ||
        normalized.endsWith('.invalid') ||
        normalized.endsWith('.localhost') ||
        normalized.endsWith('.test');
  }

  static String _normalizedHost(String host) {
    var normalized = host.trim().toLowerCase();
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((part) {
      final value = int.tryParse(part);
      return value != null && value >= 0 && value <= 255;
    });
  }

  static bool _looksLikeSecretKey(String key) {
    final normalized = key.trim();
    if (normalized.toLowerCase().startsWith('sb_secret_')) return true;
    return _legacyJwtRole(normalized) == 'service_role';
  }

  static bool _isAllowedDeployedClientKey(String key) {
    final normalized = key.trim();
    if (normalized.length <= 4096 &&
        RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(normalized)) {
      return true;
    }
    return _legacyJwtRole(normalized) == 'anon';
  }

  static String? _legacyJwtRole(String key) {
    final normalized = key.trim();
    final segments = normalized.split('.');
    if (segments.length != 3) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(segments[1])),
      );
      final decoded = jsonDecode(payload);
      final role = decoded is Map ? decoded['role'] : null;
      return role is String ? role : null;
    } on Object {
      return null;
    }
  }

  static final _gmailClientIdPattern = RegExp(
    r'^[A-Za-z0-9._-]{1,480}\.apps\.googleusercontent\.com$',
  );
  static final _projectRefPattern = RegExp(r'^[a-z0-9]{20}$');
}
