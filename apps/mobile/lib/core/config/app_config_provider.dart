import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'storage_region.dart';

final appConfigProvider = Provider<AppConfig>((ref) {
  throw StateError('AppConfig must be injected by the application bootstrap.');
});

/// The resolved storage/native identity is immutable for the process lifetime.
final storageRegionProvider = Provider<StorageRegion>((ref) {
  return StorageRegion.fromConfig(ref.watch(appConfigProvider));
});

final supabaseClientProvider = Provider<SupabaseClient?>((ref) => null);

final secureAuthLocalStorageProvider = Provider<LocalStorage?>((ref) => null);
