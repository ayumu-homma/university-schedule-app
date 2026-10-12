import 'package:app_links/app_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:university_schedule_mobile/app/deep_link_controller.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';

void main() {
  final normalizer = DeepLinkNormalizer(
    AppConfig.validated(
      environment: 'test',
      demoMode: true,
      webBaseUrl: 'https://schedule.example.edu',
    ),
  );

  test('normalizes supported custom-scheme hosts into GoRouter paths', () {
    expect(
      normalizer.normalize(Uri.parse('unischedule://home'))?.location,
      '/',
    );
    expect(
      normalizer.normalize(Uri.parse('unischedule://timetable'))?.location,
      '/timetable',
    );
    expect(
      normalizer.normalize(Uri.parse('unischedule://today'))?.location,
      '/today',
    );
    expect(
      normalizer
          .normalize(
            Uri.parse('unischedule://today?source=morning-alarm'),
          )
          ?.location,
      '/today?source=morning-alarm',
    );
    expect(
      normalizer
          .normalize(Uri.parse('unischedule://course/course-1'))
          ?.location,
      '/course/course-1',
    );
    expect(
      normalizer.normalize(Uri.parse('unischedule://course-new/2/4'))?.location,
      '/courses/manual?weekday=2&period=4',
    );
    expect(
      normalizer
          .normalize(Uri.parse('unischedule://assignment/assignment-1'))
          ?.location,
      '/assignment/assignment-1/edit',
    );
    expect(
      normalizer
          .normalize(Uri.parse('unischedule://invite/group/token_123'))
          ?.location,
      '/invite/group/token_123',
    );
    expect(
      normalizer
          .normalize(Uri.parse('unischedule://settings/visibility'))
          ?.location,
      '/visibility',
    );
  });

  test('ordinary notification taps strip validated markers and route details',
      () {
    final plan = 'local-${'a' * 64}';
    final identity =
        'v1|r=demo|o=owner|id=$plan|k=assignment|e=assignment-1|t=1|rule=due';
    final uri = Uri(
      scheme: 'unischedule',
      host: 'assignment',
      pathSegments: const ['assignment-1'],
      queryParameters: {
        'notification': identity,
        'plan': plan,
        'fingerprint': 'b' * 64,
      },
    );
    expect(normalizer.normalize(uri)?.location, '/assignment/assignment-1');
    expect(
      normalizer.normalize(uri.replace(
        queryParameters: {...uri.queryParameters, 'unexpected': 'x'},
      )),
      isNull,
    );
  });

  test('recognizes but never navigates an auth callback with secret params',
      () {
    final callback = normalizer.normalize(
      Uri.parse('unischedule://auth-callback/?code=sensitive-code'),
    );

    expect(callback, isNotNull);
    expect(callback!.isAuthCallback, isTrue);
    expect(callback.location, isNull);
  });

  test('email OAuth callback carries only exact attempt UUIDs into settings',
      () {
    final callback = normalizer.normalize(
      Uri.parse(
        'unischedule://email-import-callback'
        '?email_import=connected'
        '&correlation_id=11111111-1111-4111-8111-111111111111'
        '&connection_id=22222222-2222-4222-8222-222222222222',
      ),
    );

    expect(
      callback?.location,
      '/settings/email-import?oauth_connection_id='
      '22222222-2222-4222-8222-222222222222&oauth_correlation_id='
      '11111111-1111-4111-8111-111111111111',
    );
    expect(callback?.isAuthCallback, isFalse);
  });

  test('email OAuth callback rejects secrets and malformed outcome metadata',
      () {
    for (final uri in [
      'unischedule://email-import-callback?code=secret'
          '&email_import=connected'
          '&correlation_id=11111111-1111-4111-8111-111111111111'
          '&connection_id=22222222-2222-4222-8222-222222222222',
      'unischedule://email-import-callback?email_import=failed'
          '&category=provider_private_error'
          '&correlation_id=11111111-1111-4111-8111-111111111111'
          '&connection_id=22222222-2222-4222-8222-222222222222',
      'unischedule://email-import-callback?email_import=connected'
          '&correlation_id=not-a-uuid'
          '&connection_id=22222222-2222-4222-8222-222222222222',
      'unischedule://email-import-callback/path?email_import=connected'
          '&correlation_id=11111111-1111-4111-8111-111111111111'
          '&connection_id=22222222-2222-4222-8222-222222222222',
      'unischedule://email-import-callback?email_import=connected'
          '&correlation_id=11111111-1111-4111-8111-111111111111',
      'unischedule://email-import-callback?email_import=connected'
          '&correlation_id=11111111-1111-4111-8111-111111111111'
          '&connection_id=not-a-uuid',
    ]) {
      expect(normalizer.normalize(Uri.parse(uri)), isNull, reason: uri);
    }
  });

  test('email OAuth callback accepts only allow-listed safe failure categories',
      () {
    final callback = normalizer.normalize(
      Uri.parse(
        'unischedule://email-import-callback'
        '?email_import=failed'
        '&category=authorization_revoked'
        '&correlation_id=11111111-1111-4111-8111-111111111111'
        '&connection_id=22222222-2222-4222-8222-222222222222',
      ),
    );

    expect(callback?.location, contains('oauth_correlation_id='));
  });

  test('cold-start email callback opens settings without forwarding its query',
      () async {
    final router = _MockGoRouter();
    final appLinks = _MockAppLinks();
    when(() => appLinks.uriLinkStream).thenAnswer((_) => const Stream.empty());
    when(appLinks.getInitialLink).thenAnswer(
      (_) async => Uri.parse(
        'unischedule://email-import-callback'
        '?email_import=connected'
        '&correlation_id=11111111-1111-4111-8111-111111111111'
        '&connection_id=22222222-2222-4222-8222-222222222222',
      ),
    );
    final controller = DeepLinkController(
      router: router,
      normalizer: normalizer,
      appLinks: appLinks,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpEventQueue();

    verify(
      () => router.go(
        '/settings/email-import?oauth_connection_id='
        '22222222-2222-4222-8222-222222222222&oauth_correlation_id='
        '11111111-1111-4111-8111-111111111111',
      ),
    ).called(1);
    verifyNever(() => router.go(any(that: contains('email_import'))));
  });

  test('cold-start morning alarm opens the single Today destination', () async {
    final router = _MockGoRouter();
    final appLinks = _MockAppLinks();
    when(() => appLinks.uriLinkStream).thenAnswer((_) => const Stream.empty());
    when(appLinks.getInitialLink).thenAnswer(
      (_) async => Uri.parse(
        'unischedule://today?source=morning-alarm',
      ),
    );
    final controller = DeepLinkController(
      router: router,
      normalizer: normalizer,
      appLinks: appLinks,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpEventQueue();

    verify(() => router.go('/today?source=morning-alarm')).called(1);
  });

  test('accepts only configured-origin public invitation links', () {
    expect(
      normalizer
          .normalize(
            Uri.parse('https://schedule.example.edu/invite/friend/token-1'),
          )
          ?.location,
      '/invite/friend/token-1',
    );
    expect(
      normalizer.normalize(
        Uri.parse('https://attacker.example/invite/friend/token-1'),
      ),
      isNull,
    );
  });

  test('rejects queries, traversal, foreign schemes, and unsupported hosts',
      () {
    expect(
      normalizer.normalize(
        Uri.parse(
            'unischedule://course/course-1?next=https://attacker.example'),
      ),
      isNull,
    );
    for (final value in [
      'unischedule://today?source=notification',
      'unischedule://today?source=morning-alarm&next=/settings',
      'unischedule://today?source=morning-alarm&source=notification',
      'unischedule://today?source=morning-alarm&',
      'unischedule://today#',
      'unischedule://today/',
      'unischedule://today/extra?source=morning-alarm',
    ]) {
      expect(normalizer.normalize(Uri.parse(value)), isNull, reason: value);
    }
    expect(
      normalizer.normalize(Uri.parse('unischedule://course/..')),
      isNull,
    );
    expect(
      normalizer.normalize(Uri.parse('other-app://course/course-1')),
      isNull,
    );
    expect(
      normalizer.normalize(Uri.parse('unischedule://unknown/value')),
      isNull,
    );
    expect(
      normalizer.normalize(Uri.parse('unischedule://course-new/0/6')),
      isNull,
    );
  });

  test('validates pending locations as internal allow-listed paths', () {
    expect(normalizer.isSafeInternalLocation('/course/course-1/edit'), isTrue);
    expect(normalizer.isSafeInternalLocation('/today'), isTrue);
    expect(normalizer.isSafeInternalLocation('/today/'), isFalse);
    expect(
      normalizer.isSafeInternalLocation('/today?source=morning-alarm'),
      isTrue,
    );
    expect(
      normalizer.isSafeInternalLocation('/today?source=notification'),
      isFalse,
    );
    expect(
      normalizer.isSafeInternalLocation('/today?source=morning-alarm&'),
      isFalse,
    );
    expect(normalizer.isSafeInternalLocation('/today#'), isFalse);
    expect(
      normalizer.isSafeInternalLocation(
        '/today?source=morning-alarm&next=/settings',
      ),
      isFalse,
    );
    expect(
        normalizer.isSafeInternalLocation('/course/course-1/extra'), isFalse);
    expect(
      normalizer.isSafeInternalLocation('/assignment/assignment-1/edit'),
      isTrue,
    );
    expect(
      normalizer.isSafeInternalLocation('/assignment/assignment-1'),
      isTrue,
    );
    expect(normalizer.isSafeInternalLocation('/assignments/new'), isTrue);
    expect(normalizer.isSafeInternalLocation('/courses/arbitrary'), isFalse);
    expect(normalizer.isSafeInternalLocation('/events/new'), isTrue);
    expect(
      normalizer.isSafeInternalLocation('/settings/email-import'),
      isTrue,
    );
    expect(
      normalizer.isSafeInternalLocation(
        '/settings/email-import?oauth_connection_id='
        '22222222-2222-4222-8222-222222222222&oauth_correlation_id='
        '11111111-1111-4111-8111-111111111111',
      ),
      isTrue,
    );
    expect(
      normalizer.isSafeInternalLocation(
        '/settings/email-import?oauth_correlation_id='
        '11111111-1111-4111-8111-111111111111',
      ),
      isFalse,
    );
    expect(normalizer.isSafeInternalLocation('/events/new/extra'), isFalse);
    expect(
      normalizer.isSafeInternalLocation(
        '/courses/search?weekday=1&period=9',
      ),
      isTrue,
    );
    expect(
      normalizer
          .isSafeInternalLocation('/courses/search?next=https://evil.test'),
      isFalse,
    );
    expect(
        normalizer.isSafeInternalLocation('https://attacker.example'), isFalse);
    expect(
        normalizer.isSafeInternalLocation('//attacker.example/path'), isFalse);
    expect(
      normalizer.isSafeInternalLocation('//attacker.example/course/course-1'),
      isFalse,
    );
    expect(normalizer.isSafeInternalLocation('/sign-in'), isFalse);
  });
}

class _MockGoRouter extends Mock implements GoRouter {}

class _MockAppLinks extends Mock implements AppLinks {}
