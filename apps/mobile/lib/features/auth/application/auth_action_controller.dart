import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_error.dart';
import '../domain/auth_models.dart';
import 'auth_providers.dart';

final authActionControllerProvider =
    AsyncNotifierProvider<AuthActionController, AuthActionResult?>(
  AuthActionController.new,
);

class AuthActionController extends AsyncNotifier<AuthActionResult?> {
  @override
  AuthActionResult? build() => null;

  Future<void> sendMagicLink(String email) async {
    await _run(() async {
      await ref.read(authRepositoryProvider).sendMagicLink(email);
      return AuthActionResult.magicLinkSent;
    });
  }

  Future<void> signInWithOAuth(AppAuthProvider provider) async {
    await _run(() async {
      final result =
          await ref.read(authRepositoryProvider).signInWithOAuth(provider);
      return switch (result) {
        OAuthLaunchResult.started => AuthActionResult.oauthStarted,
        OAuthLaunchResult.cancelled => AuthActionResult.oauthCancelled,
      };
    });
  }

  Future<void> signOut() async {
    await _run(() async {
      await ref.read(authRepositoryProvider).signOut();
      return AuthActionResult.signedOut;
    });
  }

  void clearFeedback() {
    if (!state.isLoading) state = const AsyncData(null);
  }

  Future<void> _run(Future<AuthActionResult> Function() action) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    try {
      state = AsyncData(await action());
    } on AppError catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      state = AsyncError(const AuthError('認証に失敗しました。もう一度お試しください'), stackTrace);
    }
  }
}
