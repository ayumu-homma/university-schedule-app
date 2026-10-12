import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'deep_link_controller.dart';

enum AuthGateStatus { loading, signedOut, signedIn }

enum OnboardingGateStatus { loading, required, completed }

class PendingDeepLinkStore {
  String? _location;
  bool _explicitSignOut = false;

  String? get location => _location;

  void capture(String location, DeepLinkNormalizer normalizer) {
    if (!_explicitSignOut &&
        _location == null &&
        normalizer.isSafeInternalLocation(location)) {
      _location = location;
    }
  }

  /// A newly delivered platform link is a user action. It is allowed to
  /// supersede the stale route suppression used while an explicit logout is
  /// still settling. The normal router refresh path must continue using
  /// [capture] so an old protected route cannot be restored after logout.
  void captureIncoming(String location, DeepLinkNormalizer normalizer) {
    if (!normalizer.isSafeInternalLocation(location)) return;
    _explicitSignOut = false;
    _location = location;
  }

  String? take() {
    final value = _location;
    _location = null;
    return value;
  }

  void clear() => _location = null;

  void beginExplicitSignOut() {
    _explicitSignOut = true;
    clear();
  }

  void cancelExplicitSignOut() => _explicitSignOut = false;

  bool get isExplicitSignOut => _explicitSignOut;
}

final pendingDeepLinkStoreProvider = Provider<PendingDeepLinkStore>((ref) {
  return PendingDeepLinkStore();
});

String? resolveAppRedirect({
  required AuthGateStatus authStatus,
  required OnboardingGateStatus onboardingStatus,
  required String currentLocation,
  required PendingDeepLinkStore pendingLinks,
  required DeepLinkNormalizer normalizer,
}) {
  const loadingLocation = '/auth-loading';
  const signInLocation = '/sign-in';
  const onboardingLocation = '/onboarding';
  const callbackLocation = '/auth/callback';
  final currentUri = Uri.tryParse(currentLocation);
  final currentPath =
      currentUri == null || currentUri.isAbsolute || currentUri.hasAuthority
          ? ''
          : currentUri.path;
  bool canCaptureProtectedLocation() =>
      !pendingLinks.isExplicitSignOut &&
      currentPath.isNotEmpty &&
      currentPath != '/' &&
      currentPath != loadingLocation &&
      currentPath != signInLocation &&
      currentPath != onboardingLocation &&
      currentPath != callbackLocation;

  if (authStatus == AuthGateStatus.loading) {
    if (canCaptureProtectedLocation()) {
      pendingLinks.capture(currentLocation, normalizer);
    }
    return currentPath == loadingLocation ? null : loadingLocation;
  }

  if (authStatus == AuthGateStatus.signedOut) {
    if (!pendingLinks.isExplicitSignOut &&
        currentPath != signInLocation &&
        currentPath != loadingLocation &&
        currentPath != onboardingLocation &&
        currentPath != callbackLocation) {
      pendingLinks.capture(currentLocation, normalizer);
    }
    return currentPath == signInLocation ? null : signInLocation;
  }

  // GoRouter can ask for multiple redirects before it commits the sign-in
  // location. Keep explicit logout suppression through all signed-out
  // refreshes, then clear it only after authentication has actually resumed.
  pendingLinks.cancelExplicitSignOut();

  if (onboardingStatus == OnboardingGateStatus.loading) {
    if (canCaptureProtectedLocation()) {
      pendingLinks.capture(currentLocation, normalizer);
    }
    return currentPath == loadingLocation ? null : loadingLocation;
  }

  if (onboardingStatus == OnboardingGateStatus.required) {
    if (currentPath != onboardingLocation &&
        currentPath != loadingLocation &&
        currentPath != signInLocation &&
        currentPath != callbackLocation) {
      pendingLinks.capture(currentLocation, normalizer);
    }
    return currentPath == onboardingLocation ? null : onboardingLocation;
  }

  if (currentPath == signInLocation ||
      currentPath == onboardingLocation ||
      currentPath == loadingLocation ||
      currentPath == callbackLocation) {
    return pendingLinks.take() ?? '/';
  }
  return null;
}
