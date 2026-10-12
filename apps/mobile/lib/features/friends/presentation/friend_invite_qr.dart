import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/deep_link_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../features/friends/application/friend_providers.dart';
import '../../../features/friends/domain/friend_models.dart';

/// Builds the same custom-scheme invite URI used by the existing copy action.
/// The token remains in memory and in the QR renderer only; callers must not
/// persist or log the returned value.
Uri friendInvitationUri(AppConfig config, String token) {
  return Uri(
    scheme: config.deepLinkScheme,
    host: 'invite',
    pathSegments: ['friend', token],
  );
}

/// A small, stateful fence around the existing deep-link allowlist. It keeps
/// malformed/foreign values in the scanner and accepts one valid route only.
class FriendInviteScanGate {
  FriendInviteScanGate(this.normalizer);

  final DeepLinkNormalizer normalizer;
  bool _accepted = false;

  bool get hasAccepted => _accepted;

  String? tryAccept(String rawValue) {
    if (_accepted) return null;
    final value = rawValue.trim();
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (!_isExactInviteUri(uri)) return null;
    final target = normalizer.normalize(uri)?.location;
    if (target == null || !target.startsWith('/invite/friend/')) return null;
    _accepted = true;
    return target;
  }

  bool _isExactInviteUri(Uri uri) {
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return false;
    }
    // Encoded separators must not be normalized into a different path shape.
    final rawPath = uri.toString().split('?').first.split('#').first;
    if (RegExp(r'%(?:2f|5c|2e|00)', caseSensitive: false).hasMatch(rawPath)) {
      return false;
    }
    final config = normalizer.config;
    final isCustomScheme =
        uri.scheme.toLowerCase() == config.deepLinkScheme.toLowerCase() &&
            !uri.hasPort &&
            uri.host.toLowerCase() == 'invite' &&
            uri.pathSegments.length == 2 &&
            uri.pathSegments[0] == 'friend' &&
            _tokenPattern.hasMatch(uri.pathSegments[1]);
    final baseSegments =
        config.webBaseUrl.pathSegments.where((value) => value.isNotEmpty);
    final incoming = uri.pathSegments;
    final prefix = baseSegments.toList(growable: false);
    final prefixMatches = incoming.length >= prefix.length &&
        List<int>.generate(prefix.length, (index) => index)
            .every((index) => incoming[index] == prefix[index]);
    final isConfiguredWebOrigin =
        (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.toLowerCase() == config.webBaseUrl.host.toLowerCase() &&
            uri.port == config.webBaseUrl.port &&
            incoming.length == prefix.length + 3 &&
            prefixMatches &&
            incoming[prefix.length] == 'invite' &&
            incoming[prefix.length + 1] == 'friend' &&
            _tokenPattern.hasMatch(incoming[prefix.length + 2]);
    return isCustomScheme || isConfiguredWebOrigin;
  }

  static final _tokenPattern = RegExp(r'^[0-9a-fA-F]{64}$');
}

/// Invalidates queued camera work synchronously when leaving the route.
class FriendInviteScannerSession {
  bool _disposed = false;
  int _epoch = 0;

  bool get isDisposed => _disposed;

  int beginOperation() => _disposed ? -1 : ++_epoch;

  bool isCurrent(int operation) => !_disposed && operation == _epoch;

  void invalidate() {
    if (!_disposed) ++_epoch;
  }

  void dispose() {
    _disposed = true;
    ++_epoch;
  }
}

enum FriendInviteScannerLifecycleAction { none, stop, resume }

/// Keeps camera lifecycle handling explicit and testable. An inactive callback
/// while start is in flight is commonly the platform permission dialog; it
/// must not stop that start. Once running, backgrounding pauses the camera and
/// resumes it only when the user had explicitly requested scanning.
class FriendInviteScannerLifecyclePolicy {
  bool userRequested = false;
  bool startInFlight = false;
  bool cameraRunning = false;
  bool pausedForLifecycle = false;

  void requestStart() {
    userRequested = true;
    startInFlight = true;
  }

  void startSucceeded() {
    startInFlight = false;
    cameraRunning = true;
  }

  void startFailed() {
    startInFlight = false;
    cameraRunning = false;
  }

  void stopped({bool preserveUserRequest = true}) {
    cameraRunning = false;
    startInFlight = false;
    if (!preserveUserRequest) {
      userRequested = false;
      pausedForLifecycle = false;
    }
  }

  FriendInviteScannerLifecycleAction onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      final shouldStop = cameraRunning || startInFlight;
      pausedForLifecycle = false;
      return shouldStop
          ? FriendInviteScannerLifecycleAction.stop
          : FriendInviteScannerLifecycleAction.none;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Permission prompts transiently make the app inactive while start is
      // pending. Let the plugin finish permission negotiation in that case.
      if (startInFlight) return FriendInviteScannerLifecycleAction.none;
      if (cameraRunning) {
        cameraRunning = false;
        pausedForLifecycle = true;
        return FriendInviteScannerLifecycleAction.stop;
      }
      return FriendInviteScannerLifecycleAction.none;
    }
    if (state == AppLifecycleState.resumed &&
        userRequested &&
        pausedForLifecycle &&
        !startInFlight &&
        !cameraRunning) {
      pausedForLifecycle = false;
      return FriendInviteScannerLifecycleAction.resume;
    }
    return FriendInviteScannerLifecycleAction.none;
  }
}

String friendInviteCameraRecoveryMessage(MobileScannerErrorCode? code) {
  return switch (code) {
    MobileScannerErrorCode.permissionDenied =>
      'カメラの使用が許可されませんでした。招待リンクをコピーして受け取る方法を使えます。',
    MobileScannerErrorCode.unsupported =>
      'この端末ではカメラを利用できません。招待リンクをコピーして受け取る方法を使えます。',
    _ => 'カメラを起動できませんでした。権限を確認するか、招待リンクをコピーして受け取ってください。',
  };
}

class FriendInviteQrScreen extends ConsumerStatefulWidget {
  const FriendInviteQrScreen({super.key});

  @override
  ConsumerState<FriendInviteQrScreen> createState() =>
      _FriendInviteQrScreenState();
}

class _FriendInviteQrScreenState extends ConsumerState<FriendInviteQrScreen>
    with WidgetsBindingObserver {
  Timer? _expiryTimer;
  Timer? _refreshTimer;
  String? _scheduledInvitationId;
  DateTime? _scheduledInvitationExpiry;
  bool _refreshing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleExpiry(ref.watch(friendsControllerProvider).valueOrNull);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(_refreshInvitations);
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_refreshInvitations());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshInvitations());
    }
  }

  Future<void> _refreshInvitations() async {
    if (!mounted || _refreshing) return;
    _refreshing = true;
    try {
      await ref.read(friendsControllerProvider.notifier).refreshRelationships();
      if (mounted) {
        ref
            .read(friendsControllerProvider.notifier)
            .clearExpiredPendingInvitation();
        setState(() => _scheduleExpiry(
              ref.read(friendsControllerProvider).valueOrNull,
            ));
      }
    } finally {
      _refreshing = false;
    }
  }

  void _scheduleExpiry(FriendState? state) {
    final invitation = state?.pendingInvitation;
    if (invitation == null) {
      _expiryTimer?.cancel();
      _expiryTimer = null;
      _scheduledInvitationId = null;
      _scheduledInvitationExpiry = null;
      return;
    }
    if (_scheduledInvitationId == invitation.id &&
        _scheduledInvitationExpiry == invitation.expiresAt) {
      return;
    }
    _expiryTimer?.cancel();
    _scheduledInvitationId = invitation.id;
    _scheduledInvitationExpiry = invitation.expiresAt;
    final delay = invitation.expiresAt.difference(DateTime.now());
    _expiryTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        ref
            .read(friendsControllerProvider.notifier)
            .clearExpiredPendingInvitation();
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiryTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(friendsControllerProvider).valueOrNull;
    _scheduleExpiry(ref.read(friendsControllerProvider).valueOrNull);
    final invitation = state?.pendingInvitation;
    final active = invitation?.isActive ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('QRで招待')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: invitation == null || !active
              ? _ExpiredInvite(onBack: () => context.go('/shared'))
              : _InviteQrContent(invitation: invitation),
        ),
      ),
    );
  }
}

class _InviteQrContent extends ConsumerWidget {
  const _InviteQrContent({required this.invitation});

  final FriendInvitation invitation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);
    final link = friendInvitationUri(config, invitation.token).toString();
    final expiry = MaterialLocalizations.of(context).formatFullDate(
      invitation.expiresAt.toLocal(),
    );
    final expiryTime = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(invitation.expiresAt.toLocal()),
    );
    return ListView(
      children: [
        const Text(
          'あなたが発行した友だち招待',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text('有効期限: $expiry $expiryTime', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        Center(
          child: Semantics(
            label: '友だち招待QRコード',
            child: QrImageView(
              data: link,
              size: 260,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '相手がアプリの「QRを読み取る」から読み取ると、招待の確認画面に進みます。読み取っただけでは申請されません。',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('friend-copy-invite-link'),
          onPressed: () async {
            // Clipboard is the existing explicit link handoff. Do not put the
            // opaque link in diagnostics or persistent state.
            await Clipboard.setData(ClipboardData(text: link));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('招待リンクをコピーしました。')),
            );
          },
          icon: const Icon(Icons.copy),
          label: const Text('招待リンクをコピー'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => context.go('/shared'),
          child: const Text('共有へ戻る'),
        ),
      ],
    );
  }
}

class _ExpiredInvite extends StatelessWidget {
  const _ExpiredInvite({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.link_off_outlined, size: 56),
          const SizedBox(height: 12),
          const Text('QR招待は期限切れまたは失効済みです'),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onBack, child: const Text('共有へ戻る')),
        ],
      ),
    );
  }
}

class FriendInviteScannerScreen extends ConsumerStatefulWidget {
  const FriendInviteScannerScreen({super.key});

  @override
  ConsumerState<FriendInviteScannerScreen> createState() =>
      _FriendInviteScannerScreenState();
}

class _FriendInviteScannerScreenState
    extends ConsumerState<FriendInviteScannerScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  late final FriendInviteScanGate _scanGate;
  late final FriendInviteScannerSession _session;
  late final FriendInviteScannerLifecyclePolicy _lifecyclePolicy;
  bool _requested = false;
  bool _starting = false;
  bool _handlingDetection = false;
  String? _message;
  Future<void> _cameraOperationTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
    _scanGate = FriendInviteScanGate(
      DeepLinkNormalizer(ref.read(appConfigProvider)),
    );
    _lifecyclePolicy = FriendInviteScannerLifecyclePolicy();
    _session = FriendInviteScannerSession();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final action = _lifecyclePolicy.onLifecycle(state);
    if (action == FriendInviteScannerLifecycleAction.stop) {
      unawaited(_stopCamera());
    } else if (action == FriendInviteScannerLifecycleAction.resume) {
      unawaited(_startCamera());
    }
  }

  Future<void> _startCamera() async {
    if (!mounted ||
        _session.isDisposed ||
        _starting ||
        _controller.value.isRunning) {
      return;
    }
    final operation = _session.beginOperation();
    _lifecyclePolicy.requestStart();
    setState(() {
      _requested = true;
      _starting = true;
      _message = null;
    });
    await _serializeCameraOperation(() async {
      if (!_session.isCurrent(operation)) return;
      try {
        await _controller.start();
        if (!_session.isCurrent(operation)) {
          await _controller.stop();
          return;
        }
        _lifecyclePolicy.startSucceeded();
        if (mounted) setState(() => _starting = false);
      } on MobileScannerException catch (error) {
        _lifecyclePolicy.startFailed();
        if (mounted) {
          setState(() {
            _starting = false;
            _message = _cameraErrorMessage(error.errorCode);
          });
        }
      } on Object {
        _lifecyclePolicy.startFailed();
        if (mounted) {
          setState(() {
            _starting = false;
            _message = _cameraErrorMessage(null);
          });
        }
      }
    });
  }

  Future<void> _stopCamera({bool preserveUserRequest = true}) async {
    if (_session.isDisposed) return;
    _session.invalidate();
    _lifecyclePolicy.stopped(preserveUserRequest: preserveUserRequest);
    await _serializeCameraOperation(() async {
      try {
        await _controller.stop();
      } on Object {
        // Stopping after a denied/unavailable start is already a recovery path.
      }
      if (mounted && _starting) setState(() => _starting = false);
    });
  }

  Future<void> _serializeCameraOperation(
    Future<void> Function() operation,
  ) {
    final next = _cameraOperationTail.then<void>(
      (_) => operation(),
      onError: (_, __) => operation(),
    );
    _cameraOperationTail = next.catchError((_) {});
    return next;
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_handlingDetection || _scanGate.hasAccepted) return;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue == null) continue;
      final location = _scanGate.tryAccept(rawValue);
      if (location == null) continue;
      _handlingDetection = true;
      await _stopCamera(preserveUserRequest: false);
      if (mounted) context.go(location);
      return;
    }
    if (mounted) {
      setState(() {
        _message = 'このQRは友だち招待リンクではありません。アプリ内の招待QRを読み取ってください。';
      });
    }
  }

  String _cameraErrorMessage(MobileScannerErrorCode? code) {
    return friendInviteCameraRecoveryMessage(code);
  }

  @override
  Widget build(BuildContext context) {
    final showCamera = _requested;
    return Scaffold(
      appBar: AppBar(title: const Text('QRを読み取る')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              const Text(
                '友だち招待QRを枠内に合わせてください。読み取った後は確認画面で申請します。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: showCamera ? 300 : 220,
                child: showCamera
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MobileScanner(
                              controller: _controller,
                              onDetect: (capture) =>
                                  unawaited(_handleDetection(capture)),
                              errorBuilder: (context, error) => Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text(
                                    _cameraErrorMessage(error.errorCode),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                            Center(
                              child: Container(
                                width: 240,
                                height: 240,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.qr_code_scanner, size: 96),
                      ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                FriendInviteScannerRecoveryView(
                  message: _message!,
                ),
              ],
              const SizedBox(height: 12),
              if (!showCamera || !_controller.value.isRunning)
                FilledButton.icon(
                  key: const Key('friend-start-scanner'),
                  onPressed: _starting ? null : _startCamera,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: Text(_starting ? 'カメラを起動中…' : 'カメラを起動'),
                ),
              OutlinedButton(
                onPressed: () async {
                  await _stopCamera(preserveUserRequest: false);
                  if (context.mounted) context.go('/shared');
                },
                child: const Text('戻る'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _session.dispose();
    _lifecyclePolicy.stopped(preserveUserRequest: false);
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_serializeCameraOperation(_disposeScanner));
    super.dispose();
  }

  Future<void> _disposeScanner() async {
    try {
      await _controller.stop();
    } finally {
      _lifecyclePolicy.stopped(preserveUserRequest: false);
      await _controller.dispose();
    }
  }
}

class FriendInviteScannerRecoveryView extends StatelessWidget {
  const FriendInviteScannerRecoveryView({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
  }
}
