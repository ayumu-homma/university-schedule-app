import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../auth/application/auth_providers.dart';
import '../data/supabase_university_settings_repository.dart';
import '../domain/university_settings_models.dart';
import '../domain/university_settings_repository.dart';

final universitySettingsRepositoryProvider =
    Provider<UniversitySettingsRepository>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final client = ref.watch(supabaseClientProvider);
  if (session == null || client == null) {
    throw const PermissionError('大学設定の取得にはログインが必要です');
  }
  return SupabaseUniversitySettingsRepository(
    client: client,
    userId: session.userId,
  );
});

final universityRequestsProvider =
    FutureProvider.autoDispose<List<UniversityRequestRecord>>((ref) {
  return ref.watch(universitySettingsRepositoryProvider).loadRequests();
});
