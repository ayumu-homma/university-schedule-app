import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database_provider.dart';
import '../../auth/application/auth_providers.dart';
import '../data/drift_onboarding_local_store.dart';
import '../data/supabase_onboarding_repository.dart';
import '../domain/onboarding_models.dart';
import '../domain/onboarding_repository.dart';

final onboardingRepositoryProvider = Provider<OnboardingRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    throw StateError('SupabaseClient is unavailable for onboarding.');
  }
  return SupabaseOnboardingRepository(
    client,
    localStore: DriftOnboardingLocalStore(
      ref.watch(appDatabaseProvider),
      clock: ref.watch(appClockProvider).now,
    ),
  );
});

final onboardingControllerProvider =
    AsyncNotifierProvider<OnboardingController, OnboardingProfile?>(
  OnboardingController.new,
);

final onboardingCatalogProvider = FutureProvider<OnboardingCatalog>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  if (session == null) {
    throw const PermissionError('カタログの取得にはログインが必要です');
  }
  return ref.watch(onboardingRepositoryProvider).loadCatalog();
});

class OnboardingController extends AsyncNotifier<OnboardingProfile?> {
  @override
  Future<OnboardingProfile?> build() async {
    final session = ref.watch(currentAuthSessionProvider);
    if (session == null) return null;
    return ref.watch(onboardingRepositoryProvider).loadProfile(session.userId);
  }

  Future<void> completeOnboarding(OnboardingCompletion completion) async {
    if (state.isLoading) return;
    final authRepository = ref.read(authRepositoryProvider);
    final session = authRepository.currentSession;
    if (session == null) {
      state = AsyncError(
        const PermissionError('ログインセッションが切れました'),
        StackTrace.current,
      );
      return;
    }

    final previous = state;
    state = const AsyncLoading<OnboardingProfile?>().copyWithPrevious(
      previous,
    );
    try {
      final profile = await ref
          .read(onboardingRepositoryProvider)
          .completeOnboarding(userId: session.userId, completion: completion);
      final currentSession = authRepository.currentSession;
      if (currentSession?.userId != session.userId) return;
      if (profile.userId != session.userId || !profile.hasActiveSchedule) {
        throw const UnknownAppError('認証中のユーザー設定を復元できませんでした');
      }
      state = AsyncData(profile);
    } on Object catch (error, stackTrace) {
      if (authRepository.currentSession?.userId != session.userId) {
        return;
      }
      final safeError = error is AppError
          ? error
          : const UnknownAppError('オンボーディングの完了に失敗しました');
      state = AsyncError<OnboardingProfile?>(
        safeError,
        stackTrace,
      ).copyWithPrevious(previous);
    }
  }

  Future<void> retryProfileRestore() async {
    final authRepository = ref.read(authRepositoryProvider);
    final session = authRepository.currentSession;
    if (session == null) return;
    final previous = state;
    state = const AsyncLoading<OnboardingProfile?>().copyWithPrevious(
      previous,
    );
    final AsyncValue<OnboardingProfile?> restored =
        await AsyncValue.guard<OnboardingProfile?>(
      () => ref.read(onboardingRepositoryProvider).loadProfile(session.userId),
    );
    if (authRepository.currentSession?.userId != session.userId) return;
    state = restored.copyWithPrevious(previous);
  }
}
