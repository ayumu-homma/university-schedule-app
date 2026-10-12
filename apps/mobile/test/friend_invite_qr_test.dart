import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:university_schedule_mobile/app/deep_link_controller.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/friends/presentation/friend_invite_qr.dart';

void main() {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: true,
    webBaseUrl: 'https://schedule.example.edu',
  );

  DeepLinkNormalizer normalizer() => DeepLinkNormalizer(config);

  test('scan gate accepts one exact friend invitation and fences repeats', () {
    final gate = FriendInviteScanGate(normalizer());
    final token = 'a' * 64;
    final link = 'unischedule://invite/friend/$token';

    expect(gate.tryAccept(link), '/invite/friend/$token');
    expect(gate.hasAccepted, isTrue);
    expect(gate.tryAccept(link), isNull);
  });

  test('scan gate accepts the configured web origin with exact token shape',
      () {
    final token = 'B' * 64;
    final gate = FriendInviteScanGate(normalizer());
    expect(
      gate.tryAccept('https://schedule.example.edu/invite/friend/$token'),
      '/invite/friend/$token',
    );
  });

  test('scan gate accepts the exact configured web origin including its port',
      () {
    final localConfig = AppConfig.validated(
      environment: 'test',
      demoMode: true,
      webBaseUrl: 'http://127.0.0.1:3000/base',
    );
    final token = 'C' * 64;
    final gate = FriendInviteScanGate(DeepLinkNormalizer(localConfig));

    expect(
      gate.tryAccept('http://127.0.0.1:3000/base/invite/friend/$token'),
      '/invite/friend/$token',
    );
  });

  test('scan gate rejects foreign, query-bearing, group, and malformed links',
      () {
    final gate = FriendInviteScanGate(normalizer());
    final token = 'a' * 64;
    for (final value in [
      'https://attacker.example/invite/friend/$token',
      'https://schedule.example.edu/invite/friend/$token?next=/settings',
      'unischedule://invite/friend/$token?next=/settings',
      'unischedule://invite/group/$token',
      'unischedule://invite/friend/${'a' * 63}',
      'unischedule://invite/friend/${'g' * 64}',
      'unischedule://user@invite/friend/$token',
      'unischedule://invite:443/friend/$token',
      'unischedule://invite/friend/$token/extra',
      'unischedule://invite/friend/${'a' * 32}%2F${'a' * 31}',
      'mailto:friend@example.edu',
    ]) {
      expect(gate.tryAccept(value), isNull, reason: value);
      expect(gate.hasAccepted, isFalse);
    }
  });

  test('friend invitation links use the configured custom scheme', () {
    final uri = friendInvitationUri(config, 'a' * 64);
    expect(uri.scheme, 'unischedule');
    expect(uri.host, 'invite');
    expect(uri.pathSegments, ['friend', 'a' * 64]);
  });

  test('scanner and QR management routes remain internal-only', () {
    final linkNormalizer = normalizer();
    expect(linkNormalizer.isSafeInternalLocation('/shared/scan'), isTrue);
    expect(
      linkNormalizer.isSafeInternalLocation('/shared/invite/qr'),
      isTrue,
    );
    expect(
      linkNormalizer.isSafeInternalLocation('/shared/invite/qr?next=/sign-in'),
      isFalse,
    );
  });

  testWidgets('scanner does not request the camera before explicit action',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const MaterialApp(home: FriendInviteScannerScreen()),
      ),
    );

    expect(find.text('QRを読み取る'), findsOneWidget);
    expect(find.byKey(const Key('friend-start-scanner')), findsOneWidget);
    expect(find.text('カメラを起動中…'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('QRを読み取る'), findsOneWidget);
  });

  testWidgets('scanner layout remains reachable at large text scale',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(3)),
          child: MaterialApp(home: FriendInviteScannerScreen()),
        ),
      ),
    );

    expect(find.byKey(const Key('friend-start-scanner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scanner recovery layout remains reachable at large text scale',
      (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(3)),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FriendInviteScannerRecoveryView(
                message: 'カメラを起動できませんでした。招待リンクをコピーして受け取ってください。',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('カメラを起動できませんでした'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('scanner session invalidates pending start before leave', () {
    final session = FriendInviteScannerSession();
    final operation = session.beginOperation();
    session.invalidate();
    expect(session.isCurrent(operation), isFalse);
    session.dispose();
    expect(session.beginOperation(), -1);
    expect(session.isDisposed, isTrue);
  });

  test(
      'scanner lifecycle preserves permission-dialog start and resumes a pause',
      () {
    final policy = FriendInviteScannerLifecyclePolicy();
    policy.requestStart();
    expect(
      policy.onLifecycle(AppLifecycleState.inactive),
      FriendInviteScannerLifecycleAction.none,
    );
    expect(
      policy.onLifecycle(AppLifecycleState.resumed),
      FriendInviteScannerLifecycleAction.none,
    );
    policy.startSucceeded();
    expect(
      policy.onLifecycle(AppLifecycleState.paused),
      FriendInviteScannerLifecycleAction.stop,
    );
    expect(
      policy.onLifecycle(AppLifecycleState.resumed),
      FriendInviteScannerLifecycleAction.resume,
    );
    expect(policy.userRequested, isTrue);
  });

  test('camera recovery messages are Japanese and do not expose scanner data',
      () {
    expect(
      friendInviteCameraRecoveryMessage(
          MobileScannerErrorCode.permissionDenied),
      contains('カメラ'),
    );
    expect(
      friendInviteCameraRecoveryMessage(MobileScannerErrorCode.unsupported),
      contains('招待リンク'),
    );
    expect(friendInviteCameraRecoveryMessage(null), isNot(contains('opaque')));
  });
}
