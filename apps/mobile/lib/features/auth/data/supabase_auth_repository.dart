import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/error/app_error.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class SupabaseAuthRepository implements AuthRepository {
  const SupabaseAuthRepository({
    required SupabaseClient client,
    required AppConfig config,
    required LocalStorage sessionStorage,
    Future<void> Function()? beforeAccountChange,
    Future<void> Function()? resumeAfterAuthFlowFailure,
    Future<void> Function()? beforeSignOut,
  }) : this._(
          client,
          config,
          sessionStorage,
          beforeAccountChange,
          resumeAfterAuthFlowFailure,
          beforeSignOut,
        );

  const SupabaseAuthRepository._(
    this._client,
    this._config,
    this._sessionStorage,
    this._beforeAccountChange,
    this._resumeAfterAuthFlowFailure,
    this._beforeSignOut,
  );

  final SupabaseClient _client;
  final AppConfig _config;
  final LocalStorage _sessionStorage;
  final Future<void> Function()? _beforeAccountChange;
  final Future<void> Function()? _resumeAfterAuthFlowFailure;
  final Future<void> Function()? _beforeSignOut;

  @override
  AppAuthSession? get currentSession =>
      _sessionFromSupabase(_client.auth.currentSession);

  @override
  Stream<AppAuthState> watchAuthState() {
    return _client.auth.onAuthStateChange.map(
      (state) => AppAuthState(
        event: _eventFromSupabase(state.event),
        session: _sessionFromSupabase(state.session),
      ),
    );
  }

  @override
  Future<void> sendMagicLink(String email) async {
    final normalizedEmail = AuthValidators.normalizeEmail(email);
    final validationError = AuthValidators.validateEmail(normalizedEmail);
    if (validationError != null) throw ValidationError(validationError);
    await _bestEffort(_beforeAccountChange);
    try {
      await _client.auth.signInWithOtp(
        email: normalizedEmail,
        emailRedirectTo: _config.authRedirectUri.toString(),
        shouldCreateUser: true,
      );
    } on Object catch (error) {
      await _bestEffort(_resumeAfterAuthFlowFailure);
      throw _safeAuthError(error);
    }
  }

  @override
  Future<OAuthLaunchResult> signInWithOAuth(AppAuthProvider provider) async {
    await _bestEffort(_beforeAccountChange);
    try {
      final launched = await _client.auth.signInWithOAuth(
        switch (provider) {
          AppAuthProvider.google => OAuthProvider.google,
          AppAuthProvider.apple => OAuthProvider.apple,
        },
        redirectTo: _config.authRedirectUri.toString(),
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!launched) await _bestEffort(_resumeAfterAuthFlowFailure);
      return launched ? OAuthLaunchResult.started : OAuthLaunchResult.cancelled;
    } on Object catch (error) {
      await _bestEffort(_resumeAfterAuthFlowFailure);
      throw _safeAuthError(error);
    }
  }

  @override
  Future<void> signOut() async {
    await _bestEffort(_beforeSignOut);
    AppError? remoteFailure;
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } on Object catch (error) {
      remoteFailure = _safeAuthError(error);
    }

    try {
      // supabase_flutter persists auth events asynchronously and logs storage
      // failures internally. This explicit queued removal makes sign-out wait
      // for every earlier refresh write and exposes a fail-closed result.
      await _sessionStorage.removePersistedSession();
    } on Object {
      throw const AuthError(
        '端末の認証情報を安全に削除できませんでした。もう一度お試しください',
      );
    }

    if (remoteFailure != null) {
      if (_client.auth.currentSession == null) {
        throw const AuthError(
          '端末ではログアウトしましたが、サーバー側のセッション無効化は確認できませんでした。',
        );
      }
      throw remoteFailure;
    }
  }

  AppAuthSession? _sessionFromSupabase(Session? session) {
    if (session == null) return null;
    return AppAuthSession(userId: session.user.id, email: session.user.email);
  }

  AuthEvent _eventFromSupabase(AuthChangeEvent event) {
    return switch (event) {
      AuthChangeEvent.initialSession => AuthEvent.initialSession,
      AuthChangeEvent.signedIn ||
      AuthChangeEvent.passwordRecovery ||
      AuthChangeEvent.mfaChallengeVerified =>
        AuthEvent.signedIn,
      AuthChangeEvent.signedOut => AuthEvent.signedOut,
      AuthChangeEvent.tokenRefreshed => AuthEvent.tokenRefreshed,
      AuthChangeEvent.userUpdated => AuthEvent.userUpdated,
      _ => AuthEvent.signedOut,
    };
  }

  AppError _safeAuthError(Object error) {
    if (error is AuthRetryableFetchException) {
      return const NetworkError('通信できませんでした。接続を確認してもう一度お試しください');
    }
    if (error is AuthException) {
      return switch (error.code) {
        'over_email_send_rate_limit' ||
        'over_request_rate_limit' =>
          const AuthError('しばらく待ってからもう一度お試しください'),
        'provider_disabled' => const AuthError('このログイン方法は現在利用できません'),
        _ => const AuthError('認証に失敗しました。もう一度お試しください'),
      };
    }
    return const AuthError('認証に失敗しました。もう一度お試しください');
  }

  Future<void> _bestEffort(Future<void> Function()? action) async {
    if (action == null) return;
    try {
      await action();
    } on Object {
      // Push cleanup must not prevent login, account replacement, or logout.
    }
  }
}
