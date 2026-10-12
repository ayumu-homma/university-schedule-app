enum AppAuthProvider { google, apple }

enum AuthEvent {
  initialSession,
  signedIn,
  signedOut,
  tokenRefreshed,
  userUpdated,
}

enum OAuthLaunchResult { started, cancelled }

enum AuthActionResult { magicLinkSent, oauthStarted, oauthCancelled, signedOut }

class AppAuthSession {
  const AppAuthSession({required this.userId, this.email});

  final String userId;
  final String? email;

  @override
  bool operator ==(Object other) {
    return other is AppAuthSession &&
        other.userId == userId &&
        other.email == email;
  }

  @override
  int get hashCode => Object.hash(userId, email);
}

class AppAuthState {
  const AppAuthState({required this.event, required this.session});

  final AuthEvent event;
  final AppAuthSession? session;

  bool get isSignedIn => session != null;
}

class AuthValidators {
  const AuthValidators._();

  static String normalizeEmail(String value) => value.trim().toLowerCase();

  static String? validateEmail(String? value) {
    final normalized = normalizeEmail(value ?? '');
    if (normalized.isEmpty) return 'メールアドレスを入力してください';
    if (normalized.length > 254 ||
        !RegExp(
          r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
          caseSensitive: false,
        ).hasMatch(normalized)) {
      return '有効なメールアドレスを入力してください';
    }
    return null;
  }
}
