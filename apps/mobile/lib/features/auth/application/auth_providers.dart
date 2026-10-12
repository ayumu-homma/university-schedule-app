import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../data/fake_auth_repository.dart';
import '../data/supabase_auth_repository.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';
import '../../notification/application/notification_device_registration_provider.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.demoMode) {
    final repository = FakeAuthRepository();
    ref.onDispose(repository.dispose);
    return repository;
  }

  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    throw StateError('SupabaseClient is unavailable outside demo mode.');
  }
  final sessionStorage = ref.watch(secureAuthLocalStorageProvider);
  if (sessionStorage == null) {
    throw StateError('Secure auth storage is unavailable outside demo mode.');
  }
  final notificationRegistration =
      ref.watch(notificationDeviceRegistrationCoordinatorProvider);
  return SupabaseAuthRepository(
    client: client,
    config: config,
    sessionStorage: sessionStorage,
    beforeAccountChange: notificationRegistration?.prepareForAccountChange,
    resumeAfterAuthFlowFailure:
        notificationRegistration?.resumeAfterAuthFlowFailure,
    beforeSignOut: notificationRegistration?.prepareForSignOut,
  );
});

final authStateProvider = StreamProvider<AppAuthState>((ref) {
  return ref.watch(authRepositoryProvider).watchAuthState();
});

final currentAuthSessionProvider = Provider<AppAuthSession?>((ref) {
  return ref.watch(authStateProvider).valueOrNull?.session;
});
