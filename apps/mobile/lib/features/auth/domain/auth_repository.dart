import 'auth_models.dart';

abstract interface class AuthRepository {
  AppAuthSession? get currentSession;

  Stream<AppAuthState> watchAuthState();

  Future<void> sendMagicLink(String email);

  Future<OAuthLaunchResult> signInWithOAuth(AppAuthProvider provider);

  Future<void> signOut();
}

abstract interface class DisposableAuthRepository {
  Future<void> dispose();
}
