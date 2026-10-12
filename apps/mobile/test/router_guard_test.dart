import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/app/deep_link_controller.dart';
import 'package:university_schedule_mobile/app/navigation_guard.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';

void main() {
  late DeepLinkNormalizer normalizer;
  late PendingDeepLinkStore pending;

  setUp(() {
    normalizer = DeepLinkNormalizer(AppConfig.demoForTesting());
    pending = PendingDeepLinkStore();
  });

  test('holds navigation on the loading route while session restores', () {
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.loading,
        onboardingStatus: OnboardingGateStatus.loading,
        currentLocation: '/course/course-1',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/auth-loading',
    );
    expect(pending.location, '/course/course-1');
  });

  test('restores a widget course prefill received during cold start', () {
    const location = '/courses/manual?weekday=2&period=2';
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.loading,
        onboardingStatus: OnboardingGateStatus.loading,
        currentLocation: '/',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/auth-loading',
    );
    expect(pending.location, isNull);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.loading,
        onboardingStatus: OnboardingGateStatus.loading,
        currentLocation: location,
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/auth-loading',
    );
    expect(pending.location, location);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/auth-loading',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      location,
    );
    expect(pending.location, isNull);
  });

  test('restores one pending protected link after auth and onboarding', () {
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: '/course/course-1',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
    expect(pending.location, '/course/course-1');

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: '/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/onboarding',
    );
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/onboarding',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/course/course-1',
    );
    expect(pending.location, isNull);
  });

  test('restores the exact morning-alarm Today link after auth and onboarding',
      () {
    const location = '/today?source=morning-alarm';
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: location,
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
    expect(pending.location, location);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: '/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/onboarding',
    );
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/onboarding',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      location,
    );
  });

  test(
      'does not retain a destination during repeated explicit sign-out redirects',
      () {
    pending.beginExplicitSignOut();

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/settings',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
    expect(pending.location, isNull);

    // A second refresh can occur before GoRouter replaces /settings with
    // /sign-in. It must remain suppressed rather than restoring /settings
    // after the next successful login.
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/settings',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
    expect(pending.location, isNull);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: '/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/onboarding',
    );
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/onboarding',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/',
    );
    expect(pending.location, isNull);
  });

  test(
      'a fresh trusted invite after explicit sign-out replaces stale route suppression',
      () {
    final staleLocation = '/invite/friend/${List.filled(64, 'a').join()}';
    final freshLocation = '/invite/friend/${List.filled(64, 'b').join()}';
    pending.beginExplicitSignOut();
    pending.capture(staleLocation, normalizer);
    expect(pending.location, isNull);

    pending.captureIncoming(freshLocation, normalizer);
    expect(pending.isExplicitSignOut, isFalse);
    expect(pending.location, freshLocation);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: freshLocation,
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      freshLocation,
    );
  });

  test('preserves validated timetable prefill query parameters', () {
    const location = '/courses/search?weekday=2&period=7';
    resolveAppRedirect(
      authStatus: AuthGateStatus.signedOut,
      onboardingStatus: OnboardingGateStatus.required,
      currentLocation: location,
      pendingLinks: pending,
      normalizer: normalizer,
    );

    expect(pending.location, location);
    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedIn,
        onboardingStatus: OnboardingGateStatus.completed,
        currentLocation: '/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      location,
    );
  });

  test('restores a signed-out group invite after onboarding', () {
    final location = '/invite/group/${List.filled(64, 'g').join()}';
    expect(normalizer.isSafeInternalLocation(location), isTrue);
    expect(
        resolveAppRedirect(
          authStatus: AuthGateStatus.signedOut,
          onboardingStatus: OnboardingGateStatus.required,
          currentLocation: location,
          pendingLinks: pending,
          normalizer: normalizer,
        ),
        '/sign-in');
    expect(
        resolveAppRedirect(
          authStatus: AuthGateStatus.signedIn,
          onboardingStatus: OnboardingGateStatus.completed,
          currentLocation: '/sign-in',
          pendingLinks: pending,
          normalizer: normalizer,
        ),
        location);
  });

  test('never stores external or auth-entry locations as pending', () {
    resolveAppRedirect(
      authStatus: AuthGateStatus.signedOut,
      onboardingStatus: OnboardingGateStatus.required,
      currentLocation: '//attacker.example/path',
      pendingLinks: pending,
      normalizer: normalizer,
    );
    expect(pending.location, isNull);

    expect(
      resolveAppRedirect(
        authStatus: AuthGateStatus.signedOut,
        onboardingStatus: OnboardingGateStatus.required,
        currentLocation: 'https://attacker.example/sign-in',
        pendingLinks: pending,
        normalizer: normalizer,
      ),
      '/sign-in',
    );
  });
}
