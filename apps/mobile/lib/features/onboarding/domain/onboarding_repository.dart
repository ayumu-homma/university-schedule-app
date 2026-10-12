import 'onboarding_models.dart';

abstract interface class OnboardingRepository {
  Future<OnboardingProfile> loadProfile(String userId);

  Future<OnboardingCatalog> loadCatalog();

  Future<OnboardingProfile> completeOnboarding({
    required String userId,
    required OnboardingCompletion completion,
  });
}
