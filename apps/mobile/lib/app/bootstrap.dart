import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/config/app_config.dart';
import '../core/config/app_config_provider.dart';
import '../core/auth/secure_auth_storage.dart';
import '../core/config/storage_region.dart';
import '../core/native/native_scope_bridge.dart';
import '../core/native/sqlite_identity_handshake.dart';
import '../core/storage/storage_database.dart';
import '../core/storage/storage_preparation.dart';
import '../core/sync/schedule_sync_deadline_http_client.dart';
import '../features/timetable/data/local_schedule_repository.dart';
import '../local_db/app_database.dart';
import '../local_db/app_database_provider.dart';
import 'app.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on Object {
    try {
      await const NativeScopeBridge().deactivate();
    } on Object {
      // Continue to the fail-closed startup surface even if the native bridge
      // itself is unavailable while configuration is invalid.
    }
    runApp(const _BootstrapFailureApp(reason: 'config_invalid'));
    return;
  }

  final region = StorageRegion.fromConfig(config);
  try {
    await const SqliteIdentityHandshake().verify(force: true);
  } on SqliteIdentityException {
    runApp(const _BootstrapFailureApp(reason: 'sqlite_identity_unavailable'));
    return;
  } on Object {
    runApp(const _BootstrapFailureApp(reason: 'sqlite_identity_unavailable'));
    return;
  }
  try {
    await const NativeScopeBridge().prepare(region);
  } on Object {
    runApp(const _BootstrapFailureApp(reason: 'native_scope_unavailable'));
    return;
  }
  final PreparedStorage preparedStorage;
  try {
    final documents = await getApplicationDocumentsDirectory();
    preparedStorage = await const StoragePreparation().prepare(
      documents,
      region,
    );
  } on StoragePreparationException catch (error) {
    runApp(_BootstrapFailureApp(reason: error.reason));
    return;
  } on Object {
    runApp(const _BootstrapFailureApp(reason: 'storage_preparation_failed'));
    return;
  }
  // The opener performs identity and durable-health checks inside the Drift
  // worker immediately before its NativeDatabase opens the canonical file.
  SqliteIdentityHandshake.requireVerified();
  AppDatabase? database;
  try {
    final openedDatabase = await openStorageDatabaseInBackground(
      file: File(preparedStorage.databasePath),
      region: region,
    );
    database = openedDatabase;
    // Opening a trivial query forces Drift migrations and the region file
    // readiness check to complete before auth or any runtime is constructed.
    await openedDatabase.customSelect('SELECT 1').get();
  } on Object {
    await database?.close();
    runApp(const _BootstrapFailureApp(reason: 'database_unavailable'));
    return;
  }

  SupabaseClient? client;
  SecureAuthLocalStorage? secureAuthLocalStorage;
  if (!config.demoMode) {
    try {
      final secureAuthStorage = SecureAuthStorageBundle.forSupabaseUrl(
        config.supabaseUrl!,
        region: region,
      );
      secureAuthLocalStorage = secureAuthStorage.sessionStorage;
      final initialized = await Supabase.initialize(
        url: config.supabaseUrl!.toString(),
        publishableKey: config.supabasePublishableKey,
        httpClient: ScheduleSyncDeadlineHttpClient(),
        authOptions: FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          detectSessionInUri: true,
          localStorage: secureAuthStorage.sessionStorage,
          pkceAsyncStorage: secureAuthStorage.pkceStorage,
        ),
      );
      client = initialized.client;
    } on Object {
      await database.close();
      runApp(const _BootstrapFailureApp(reason: 'auth_unavailable'));
      return;
    }
  }

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        storageRegionProvider.overrideWithValue(region),
        appDatabaseProvider.overrideWithValue(database),
        appDatabasePathProvider.overrideWithValue(preparedStorage.databasePath),
        supabaseClientProvider.overrideWithValue(client),
        secureAuthLocalStorageProvider.overrideWithValue(
          secureAuthLocalStorage,
        ),
        if (config.demoMode) ...[
          activeScheduleContextProvider.overrideWithValue(
            demoScheduleContext,
          ),
          demoScheduleDataEnabledProvider.overrideWithValue(true),
        ],
      ],
      child: const UniversityScheduleApp(),
    ),
  );
}

class _BootstrapFailureApp extends StatelessWidget {
  const _BootstrapFailureApp({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'アプリを起動できませんでした',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _BootstrapFailureApp.messageFor(reason),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(reason, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String messageFor(String reason) {
    switch (reason) {
      case 'legacy_explicit_migration_required':
      case 'orphaned_legacy_sidecars':
      case 'legacy_receipt_scope_mismatch':
      case 'legacy_receipt_file_set':
      case 'legacy_receipt_path_mismatch':
      case 'legacy_source_presence_mismatch':
      case 'legacy_source_hash_mismatch':
      case 'interrupted_receipt_mismatch':
      case 'interrupted_target_mismatch':
        return '以前のデータを保護するため起動を停止しました。保存元を確認した明示的な移行が必要です。';
      default:
        return '安全な接続設定を確認してから、もう一度起動してください。';
    }
  }
}
