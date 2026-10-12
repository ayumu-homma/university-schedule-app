import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_action_controller.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/data/fake_auth_repository.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';

void main() {
  test('app-composed demo auth starts signed out', () async {
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(authStateProvider.future);

    expect(initial.event, AuthEvent.initialSession);
    expect(initial.session, isNull);
  });

  group('FakeAuthRepository', () {
    test('emits initial and restored sessions', () async {
      final repository = FakeAuthRepository();
      final statesFuture = repository.watchAuthState().take(2).toList();
      await Future<void>.delayed(Duration.zero);

      repository.restoreSession(
        const AppAuthSession(userId: 'user-1', email: 'user@example.test'),
      );
      final states = await statesFuture;

      expect(states.first.event, AuthEvent.initialSession);
      expect(states.first.session, isNull);
      expect(states.last.session?.userId, 'user-1');
      await repository.dispose();
    });

    test('supports deterministic OAuth cancellation without a session',
        () async {
      final repository = FakeAuthRepository();
      repository.setOAuthResult(
        AppAuthProvider.google,
        OAuthLaunchResult.cancelled,
      );

      final result = await repository.signInWithOAuth(AppAuthProvider.google);

      expect(result, OAuthLaunchResult.cancelled);
      expect(repository.currentState.session, isNull);
      await repository.dispose();
    });
  });

  group('AuthActionController', () {
    test('normalizes email and exposes magic-link success', () async {
      final repository = FakeAuthRepository(autoAuthenticateEmail: false);
      final container = _container(repository);
      addTearDown(() async {
        container.dispose();
        await repository.dispose();
      });
      await container.read(authActionControllerProvider.future);

      await container
          .read(authActionControllerProvider.notifier)
          .sendMagicLink('  Student@Example.EDU ');

      expect(
        container.read(authActionControllerProvider).valueOrNull,
        AuthActionResult.magicLinkSent,
      );
      expect(repository.lastMagicLinkEmail, 'student@example.edu');
    });

    test('keeps repository failures safe for presentation', () async {
      final repository = FakeAuthRepository();
      repository.failNext(const AuthError('安全な認証エラー'));
      final container = _container(repository);
      addTearDown(() async {
        container.dispose();
        await repository.dispose();
      });
      await container.read(authActionControllerProvider.future);

      await container
          .read(authActionControllerProvider.notifier)
          .signInWithOAuth(AppAuthProvider.apple);

      final state = container.read(authActionControllerProvider);
      expect(state.hasError, isTrue);
      expect(state.error, isA<AuthError>());
      expect((state.error! as AuthError).message, '安全な認証エラー');
    });
  });
}

ProviderContainer _container(FakeAuthRepository repository) {
  return ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(AppConfig.demoForTesting()),
      authRepositoryProvider.overrideWithValue(repository),
    ],
  );
}
