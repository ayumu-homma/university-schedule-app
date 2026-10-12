import 'dart:async';

import '../../../core/error/app_error.dart';
import '../domain/auth_models.dart';
import '../domain/auth_repository.dart';

class FakeAuthRepository implements AuthRepository, DisposableAuthRepository {
  FakeAuthRepository({
    AppAuthSession? initialSession,
    this.autoAuthenticateEmail = true,
    this.autoAuthenticateOAuth = true,
    this.authenticatedUserId = 'demo-user',
  }) : _state = AppAuthState(
          event: AuthEvent.initialSession,
          session: initialSession,
        );

  final bool autoAuthenticateEmail;
  final bool autoAuthenticateOAuth;
  final String authenticatedUserId;
  final _controller = StreamController<AppAuthState>.broadcast(sync: true);
  AppAuthState _state;
  Object? _nextFailure;
  final Map<AppAuthProvider, OAuthLaunchResult> _oauthResults = {};

  AppAuthState get currentState => _state;
  @override
  AppAuthSession? get currentSession => _state.session;
  String? lastMagicLinkEmail;
  AppAuthProvider? lastOAuthProvider;

  void failNext([Object error = const AuthError('認証に失敗しました')]) {
    _nextFailure = error;
  }

  void setOAuthResult(AppAuthProvider provider, OAuthLaunchResult result) {
    _oauthResults[provider] = result;
  }

  void restoreSession(AppAuthSession? session) {
    _emit(
      AppAuthState(
        event: session == null ? AuthEvent.signedOut : AuthEvent.signedIn,
        session: session,
      ),
    );
  }

  @override
  Stream<AppAuthState> watchAuthState() async* {
    yield _state;
    yield* _controller.stream;
  }

  @override
  Future<void> sendMagicLink(String email) async {
    _throwQueuedFailure();
    final normalizedEmail = AuthValidators.normalizeEmail(email);
    final validationError = AuthValidators.validateEmail(normalizedEmail);
    if (validationError != null) throw ValidationError(validationError);
    lastMagicLinkEmail = normalizedEmail;
    if (autoAuthenticateEmail) {
      _emit(
        AppAuthState(
          event: AuthEvent.signedIn,
          session: AppAuthSession(
            userId: authenticatedUserId,
            email: normalizedEmail,
          ),
        ),
      );
    }
  }

  @override
  Future<OAuthLaunchResult> signInWithOAuth(AppAuthProvider provider) async {
    _throwQueuedFailure();
    lastOAuthProvider = provider;
    final result = _oauthResults[provider] ?? OAuthLaunchResult.started;
    if (result == OAuthLaunchResult.started && autoAuthenticateOAuth) {
      _emit(
        AppAuthState(
          event: AuthEvent.signedIn,
          session: AppAuthSession(
            userId: authenticatedUserId,
            email: 'fake-${provider.name}@example.test',
          ),
        ),
      );
    }
    return result;
  }

  @override
  Future<void> signOut() async {
    _throwQueuedFailure();
    _emit(const AppAuthState(event: AuthEvent.signedOut, session: null));
  }

  void _throwQueuedFailure() {
    final failure = _nextFailure;
    _nextFailure = null;
    if (failure != null) throw failure;
  }

  void _emit(AppAuthState value) {
    _state = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  @override
  Future<void> dispose() => _controller.close();
}
