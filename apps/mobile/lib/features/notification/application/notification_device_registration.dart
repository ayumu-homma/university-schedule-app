import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

class NotificationDeviceReceipt {
  const NotificationDeviceReceipt({
    required this.userId,
    required this.clientGeneration,
    required this.bindingGeneration,
    required this.tokenHash,
    this.revokePending = false,
    this.providerTokenInvalidated = false,
  });

  final String userId;
  final int clientGeneration;
  final int bindingGeneration;
  final String tokenHash;

  /// The last revoke was not confirmed. A same-user re-registration must not
  /// be suppressed by the token-hash dedupe until the server accepts a newer
  /// generation.
  final bool revokePending;

  /// A stale account's provider token deletion completed after an unexpected
  /// auth change. Avoid deleting a later token again while awaiting rebind.
  final bool providerTokenInvalidated;
}

class NotificationInstallationState {
  const NotificationInstallationState({
    required this.installationId,
    required this.clientGeneration,
    this.receipt,
  });

  final String installationId;
  final int clientGeneration;
  final NotificationDeviceReceipt? receipt;
}

abstract interface class NotificationInstallationStore {
  Future<NotificationInstallationState> load();
  Future<NotificationInstallationState> reserveNextGeneration();
  Future<void> saveReceipt(NotificationDeviceReceipt receipt);
  Future<void> markReceiptRevokePending({
    bool providerTokenInvalidated = false,
  });
  Future<void> clearReceipt();
}

abstract interface class NotificationDeviceTokenSource {
  /// Initializes Firebase when platform configuration exists. Returns false
  /// when push is unavailable; that must not prevent ordinary app startup.
  Future<bool> initialize();

  Stream<String> get tokenRefreshes;

  /// Returns a token only when the OS already authorizes notifications. It
  /// must not start a permission prompt during background registration.
  Future<String?> currentTokenIfAuthorized();

  Future<void> deleteToken();
}

abstract interface class NotificationDeviceGateway {
  String? get currentUserId;

  Stream<String?> watchUserIds();

  Future<int?> register({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required String platform,
    required String token,
  });

  Future<bool> revoke({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required int bindingGeneration,
  });
}

/// Serializes token registration and identity changes around the server's
/// generation-checked RPCs. Raw push tokens stay in memory and are sent only
/// to the authenticated registration RPC; local secure state keeps a hash.
class NotificationDeviceRegistrationCoordinator {
  NotificationDeviceRegistrationCoordinator({
    required NotificationDeviceGateway gateway,
    required NotificationDeviceTokenSource tokenSource,
    required NotificationInstallationStore installationStore,
    required String platform,
  })  : _gateway = gateway,
        _tokenSource = tokenSource,
        _installationStore = installationStore,
        _platform = platform;

  final NotificationDeviceGateway _gateway;
  final NotificationDeviceTokenSource _tokenSource;
  final NotificationInstallationStore _installationStore;
  final String _platform;

  StreamSubscription<String?>? _authSubscription;
  StreamSubscription<String>? _tokenSubscription;
  Future<void> _queue = Future<void>.value();
  Future<void>? _startFuture;
  String? _desiredUserId;
  int _intentGeneration = 0;
  bool _closed = false;
  bool _identityReplacementInProgress = false;

  Future<void> start() {
    if (_closed) return Future<void>.value();
    final existing = _startFuture;
    if (existing != null) return existing;
    return _startFuture = _start();
  }

  Future<void> _start() async {
    _authSubscription = _gateway.watchUserIds().listen(
          _acceptIdentity,
          onError: (Object _, StackTrace __) {},
        );

    var sourceReady = false;
    try {
      sourceReady = await _tokenSource.initialize();
    } on Object {
      sourceReady = false;
    }
    if (_closed) return;
    if (sourceReady) {
      _tokenSubscription = _tokenSource.tokenRefreshes.listen(
        _acceptRefreshedToken,
        onError: (Object _, StackTrace __) {},
      );
    }

    final userId = _gateway.currentUserId;
    if (userId != null) _acceptIdentity(userId, force: true);
  }

  /// Rechecks the token after returning from OS notification settings or an
  /// external sign-in flow. It never prompts for permission itself.
  Future<void> onAppResumed() async {
    await start();
    if (_closed) return;
    final userId = _gateway.currentUserId;
    if (userId == null) return;
    if (_desiredUserId != userId || _identityReplacementInProgress) {
      _acceptIdentity(userId, force: true);
      return;
    }
    final intent = _intentGeneration;
    await _enqueue(() => _reconcile(userId, intent));
  }

  /// Revokes the current account binding before an auth flow can replace the
  /// account. A canceled external flow is re-enabled on app resume.
  Future<void> prepareForAccountChange() async =>
      _prepareForIdentityReplacement(deleteProviderToken: false);

  /// Best-effort online revocation and FCM token deletion before local logout.
  Future<void> prepareForSignOut() async =>
      _prepareForIdentityReplacement(deleteProviderToken: true);

  Future<void> resumeAfterAuthFlowFailure() => onAppResumed();

  Future<void> _prepareForIdentityReplacement({
    required bool deleteProviderToken,
  }) async {
    await start();
    if (_closed) return;
    final userId = _gateway.currentUserId;
    _identityReplacementInProgress = true;
    _desiredUserId = null;
    _intentGeneration++;
    await _enqueue(() async {
      await _bestEffortRevoke(userId);
      if (deleteProviderToken) await _bestEffortDeleteToken();
    });
  }

  void _acceptIdentity(String? userId, {bool force = false}) {
    if (_closed) return;
    if (!force && userId == _desiredUserId) return;
    final wasSignedIn = _desiredUserId != null;
    _desiredUserId = userId;
    final intent = ++_intentGeneration;

    if (userId == null) {
      _identityReplacementInProgress = true;
      if (wasSignedIn) {
        // The auth stream reports signedOut after its session is cleared, so
        // an RPC can no longer authenticate as the prior user. Normal local
        // sign-out revokes in prepareForSignOut before that transition.
        unawaited(_enqueue(_bestEffortDeleteToken));
      }
      return;
    }

    _identityReplacementInProgress = false;
    unawaited(_enqueue(() => _reconcile(userId, intent)));
  }

  void _acceptRefreshedToken(String token) {
    final userId = _desiredUserId;
    if (userId == null || _identityReplacementInProgress || _closed) return;
    final intent = _intentGeneration;
    unawaited(_enqueue(() => _registerRefreshedToken(userId, token, intent)));
  }

  Future<void> _registerRefreshedToken(
    String userId,
    String refreshedToken,
    int intent,
  ) async {
    if (!_owns(userId, intent)) return;
    final token = await _tokenSource.currentTokenIfAuthorized();
    if (token == null || token != refreshedToken || !_owns(userId, intent)) {
      return;
    }
    await _registerToken(userId, token, intent);
  }

  Future<void> _reconcile(String userId, int intent) async {
    if (!_owns(userId, intent)) return;

    // Auth events can arrive after an SDK-driven account replacement that did
    // not pass through our pre-change hook. The previous account's authenticated
    // revoke is no longer possible, so invalidate its provider token and retain
    // the generation receipt until a newer registration replaces the binding.
    final stored = await _installationStore.load();
    if (!_owns(userId, intent)) return;
    final priorReceipt = stored.receipt;
    if (priorReceipt != null && priorReceipt.userId != userId) {
      await _installationStore.markReceiptRevokePending();
      if (!priorReceipt.providerTokenInvalidated &&
          await _bestEffortDeleteToken()) {
        await _installationStore.markReceiptRevokePending(
          providerTokenInvalidated: true,
        );
      }
      if (!_owns(userId, intent)) return;
    } else if (priorReceipt?.revokePending == true) {
      await _bestEffortRevoke(userId);
      if (!_owns(userId, intent)) return;
    }

    final token = await _tokenSource.currentTokenIfAuthorized();
    if (token == null || !_owns(userId, intent)) return;
    await _registerToken(userId, token, intent);
  }

  Future<void> _registerToken(String userId, String token, int intent) async {
    if (!_owns(userId, intent) || token.length < 20 || token.length > 8192) {
      return;
    }
    final hash = sha256.convert(utf8.encode(token)).toString();
    final current = await _installationStore.load();
    if (!_owns(userId, intent)) return;
    final receipt = current.receipt;
    if (receipt != null &&
        receipt.userId == userId &&
        receipt.tokenHash == hash &&
        !receipt.revokePending) {
      return;
    }

    final reserved = await _installationStore.reserveNextGeneration();
    if (!_owns(userId, intent)) return;
    final bindingGeneration = await _gateway.register(
      expectedUserId: userId,
      installationId: reserved.installationId,
      clientGeneration: reserved.clientGeneration,
      platform: _platform,
      token: token,
    );
    if (bindingGeneration == null || bindingGeneration < 1) return;

    // Persist a successful response even if a newer identity arrived while
    // the RPC was in flight. Identity operations share this queue, so the
    // newer operation will replace or revoke this receipt next.
    await _installationStore.saveReceipt(
      NotificationDeviceReceipt(
        userId: userId,
        clientGeneration: reserved.clientGeneration,
        bindingGeneration: bindingGeneration,
        tokenHash: hash,
      ),
    );
  }

  bool _owns(String userId, int intent) =>
      !_closed &&
      !_identityReplacementInProgress &&
      _desiredUserId == userId &&
      _intentGeneration == intent &&
      _gateway.currentUserId == userId;

  Future<void> _bestEffortRevoke(String? userId) async {
    if (userId == null || _gateway.currentUserId != userId) return;
    try {
      final state = await _installationStore.load();
      final receipt = state.receipt;
      if (receipt == null || receipt.userId != userId) return;
      if (_gateway.currentUserId != userId) return;
      await _installationStore.markReceiptRevokePending();
      final revoked = await _gateway.revoke(
        expectedUserId: userId,
        installationId: state.installationId,
        clientGeneration: receipt.clientGeneration,
        bindingGeneration: receipt.bindingGeneration,
      );
      if (revoked) await _installationStore.clearReceipt();
    } on Object {
      // Logout and account replacement must remain available offline. A
      // later accepted registration replaces this installation server-side.
    }
  }

  Future<bool> _bestEffortDeleteToken() async {
    try {
      await _tokenSource.deleteToken();
      await _installationStore.markReceiptRevokePending(
        providerTokenInvalidated: true,
      );
      return true;
    } on Object {
      // Provider cleanup is best-effort; never block auth state changes.
      return false;
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) async {
      try {
        await operation();
      } on Object {
        // Keep the serialized queue usable after network/storage failures.
      }
    });
    _queue = next;
    return next;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _intentGeneration++;
    await _authSubscription?.cancel();
    await _tokenSubscription?.cancel();
    await _queue;
  }
}
