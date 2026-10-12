import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/auth/secure_auth_storage.dart';
import '../application/notification_device_registration.dart';

class SecureNotificationInstallationStore
    implements NotificationInstallationStore {
  SecureNotificationInstallationStore({
    required SecureValueStore secureStore,
    required String storageScope,
    Uuid uuid = const Uuid(),
  })  : _secureStore = secureStore,
        _key = 'unischedule:$storageScope:notification-installation:v1',
        _uuid = uuid;

  final SecureValueStore _secureStore;
  final String _key;
  final Uuid _uuid;

  @override
  Future<NotificationInstallationState> load() async {
    final raw = await _secureStore.read(_key);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final installationId = decoded['installationId'];
          final generation = decoded['clientGeneration'];
          final receiptJson = decoded['receipt'];
          if (installationId is String &&
              _isUuid(installationId) &&
              generation is int &&
              generation >= 0) {
            final receipt = _readReceipt(receiptJson);
            final state = NotificationInstallationState(
              installationId: installationId,
              clientGeneration: generation,
              receipt: receipt,
            );
            if (receiptJson == null || receipt != null) return state;
          }
        }
      } on Object {
        // Invalid persisted metadata is replaced with a new installation id.
      }
    }
    final state = NotificationInstallationState(
      installationId: _uuid.v4(),
      clientGeneration: 0,
    );
    await _write(state);
    return state;
  }

  @override
  Future<NotificationInstallationState> reserveNextGeneration() async {
    final current = await load();
    if (current.clientGeneration >= 0x7fffffffffffffff) {
      throw StateError('Notification client generation is exhausted.');
    }
    final next = NotificationInstallationState(
      installationId: current.installationId,
      clientGeneration: current.clientGeneration + 1,
      receipt: current.receipt,
    );
    await _write(next);
    return next;
  }

  @override
  Future<void> saveReceipt(NotificationDeviceReceipt receipt) async {
    final current = await load();
    if (receipt.clientGeneration < current.clientGeneration) return;
    if (receipt.clientGeneration != current.clientGeneration) {
      throw StateError('Notification receipt generation is not reserved.');
    }
    await _write(NotificationInstallationState(
      installationId: current.installationId,
      clientGeneration: current.clientGeneration,
      receipt: receipt,
    ));
  }

  @override
  Future<void> markReceiptRevokePending({
    bool providerTokenInvalidated = false,
  }) async {
    final current = await load();
    final receipt = current.receipt;
    if (receipt == null ||
        (receipt.revokePending &&
            (!providerTokenInvalidated || receipt.providerTokenInvalidated))) {
      return;
    }
    await _write(NotificationInstallationState(
      installationId: current.installationId,
      clientGeneration: current.clientGeneration,
      receipt: NotificationDeviceReceipt(
        userId: receipt.userId,
        clientGeneration: receipt.clientGeneration,
        bindingGeneration: receipt.bindingGeneration,
        tokenHash: receipt.tokenHash,
        revokePending: true,
        providerTokenInvalidated:
            receipt.providerTokenInvalidated || providerTokenInvalidated,
      ),
    ));
  }

  @override
  Future<void> clearReceipt() async {
    final current = await load();
    await _write(NotificationInstallationState(
      installationId: current.installationId,
      clientGeneration: current.clientGeneration,
    ));
  }

  Future<void> _write(NotificationInstallationState state) async {
    final json = jsonEncode({
      'installationId': state.installationId,
      'clientGeneration': state.clientGeneration,
      if (state.receipt case final receipt?)
        'receipt': {
          'userId': receipt.userId,
          'clientGeneration': receipt.clientGeneration,
          'bindingGeneration': receipt.bindingGeneration,
          'tokenHash': receipt.tokenHash,
          'revokePending': receipt.revokePending,
          'providerTokenInvalidated': receipt.providerTokenInvalidated,
        },
    });
    await _secureStore.write(_key, json);
    if (await _secureStore.read(_key) != json) {
      throw StateError('Notification installation metadata was not persisted.');
    }
  }

  NotificationDeviceReceipt? _readReceipt(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) return null;
    final userId = raw['userId'];
    final clientGeneration = raw['clientGeneration'];
    final bindingGeneration = raw['bindingGeneration'];
    final tokenHash = raw['tokenHash'];
    final revokePending = raw['revokePending'];
    final providerTokenInvalidated = raw['providerTokenInvalidated'];
    if (userId is! String ||
        !_isUuid(userId) ||
        clientGeneration is! int ||
        clientGeneration < 1 ||
        bindingGeneration is! int ||
        bindingGeneration < 1 ||
        tokenHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenHash) ||
        (revokePending != null && revokePending is! bool) ||
        (providerTokenInvalidated != null &&
            providerTokenInvalidated is! bool)) {
      return null;
    }
    return NotificationDeviceReceipt(
      userId: userId,
      clientGeneration: clientGeneration,
      bindingGeneration: bindingGeneration,
      tokenHash: tokenHash,
      revokePending: revokePending as bool? ?? false,
      providerTokenInvalidated: providerTokenInvalidated as bool? ?? false,
    );
  }

  bool _isUuid(String value) => RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);
}
