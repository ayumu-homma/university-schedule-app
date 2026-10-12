import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_config.dart';

/// Immutable identity of the local storage and native derived-data scope.
///
/// The identity deliberately excludes credentials, user IDs, app versions and
/// hashCode values. A demo build has one fixed sentinel origin so it can never
/// alias a live Supabase origin.
class StorageRegion {
  const StorageRegion._({
    required this.environment,
    required this.mode,
    required this.canonicalOrigin,
    required this.id,
  });

  factory StorageRegion.fromConfig(AppConfig config) {
    final mode = config.demoMode ? 'demo' : 'live';
    final origin = config.demoMode
        ? _demoSentinelOrigin
        : _canonicalOrigin(config.supabaseUrl!);
    final identity = jsonEncode([
      _identityVersion,
      config.environment.name,
      mode,
      origin,
    ]);
    return StorageRegion._(
      environment: config.environment,
      mode: mode,
      canonicalOrigin: origin,
      id: sha256.convert(utf8.encode(identity)).toString(),
    );
  }

  static const _identityVersion = 'storage-space-v1';
  static const _demoSentinelOrigin = 'demo://university-schedule';

  final AppEnvironment environment;
  final String mode;
  final String canonicalOrigin;
  final String id;

  String get directoryName => id;

  @override
  String toString() => 'StorageRegion($id)';
}

String _canonicalOrigin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final hostPart = host.contains(':') ? '[$host]' : host;
  // Uri.port already returns the scheme's effective default (for example,
  // 443 for https), so an omitted default port cannot alias a non-default
  // explicit port while equivalent origins remain stable.
  final effectivePort = uri.port;
  return '$scheme://$hostPart:$effectivePort';
}
