import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../auth/application/auth_providers.dart';
import '../data/supabase_term_period_repository.dart';
import '../domain/term_period_models.dart';
import '../domain/term_period_repository.dart';

final termPeriodRepositoryProvider = Provider<TermPeriodRepository>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final client = ref.watch(supabaseClientProvider);
  if (session == null || client == null) {
    throw const PermissionError('学期設定の取得にはログインが必要です');
  }
  return SupabaseTermPeriodRepository(
    client: client,
    userId: session.userId,
  );
});

final personalTermPeriodSnapshotProvider =
    FutureProvider.autoDispose<PersonalTermPeriodSnapshot>((ref) {
  return ref.watch(termPeriodRepositoryProvider).load();
});

final personalPeriodSettingsProvider = FutureProvider.autoDispose
    .family<List<PersonalPeriodSetting>, String>((ref, termId) {
  return ref.watch(termPeriodRepositoryProvider).loadPeriods(termId);
});
