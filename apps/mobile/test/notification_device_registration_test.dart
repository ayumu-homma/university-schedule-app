import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/core/auth/secure_auth_storage.dart';
import 'package:university_schedule_mobile/features/notification/application/notification_device_registration.dart';
import 'package:university_schedule_mobile/features/notification/data/firebase_notification_device_token_source.dart';
import 'package:university_schedule_mobile/features/notification/data/secure_notification_installation_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notification device lifecycle', () {
    late _DeviceGateway gateway;
    late _TokenSource tokens;
    late _InstallationStore store;
    late List<String> lifecycleEvents;
    late NotificationDeviceRegistrationCoordinator coordinator;

    setUp(() {
      lifecycleEvents = [];
      gateway = _DeviceGateway(lifecycleEvents)
        ..setUser('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      tokens = _TokenSource(lifecycleEvents)..token = _token('a');
      store = _InstallationStore();
      coordinator = _coordinator(gateway, tokens, store);
    });

    tearDown(() async {
      await coordinator.dispose();
      await gateway.dispose();
      await tokens.dispose();
    });

    test('registers once for an authorized session and suppresses duplicates',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(1));
      expect(gateway.binding?.userId, gateway.currentUserId);
      expect(gateway.binding?.token, _token('a'));

      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(1));
      expect(store.state.clientGeneration, 1);
    });

    test(
        'token refresh replaces the binding and repeated refresh is idempotent',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();

      tokens.refresh(_token('b'));
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(2));
      expect(gateway.binding?.token, _token('b'));
      expect(gateway.binding?.clientGeneration, 2);

      tokens.refresh(_token('b'));
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(2));
      expect(store.state.clientGeneration, 2);
    });

    test('serialized A to B to A changes leave only the latest account bound',
        () async {
      final gate = gateway.blockNextRegistration();
      await coordinator.start();
      await gateway.registerStarted;

      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      gateway.setUser('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      gate.complete();
      await coordinator.onAppResumed();

      expect(gateway.registerCalls, hasLength(1));
      expect(gateway.binding?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(gateway.binding?.clientGeneration, 1);
      expect(
          store.state.receipt?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    });

    test('A to B to A fences both stale registration completions', () async {
      final firstGate = gateway.blockNextRegistration();
      await coordinator.start();
      await gateway.registerStarted;

      final secondGate = gateway.blockSecondRegistration();
      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      firstGate.complete();
      await gateway.secondRegisterStarted;

      gateway.setUser('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      secondGate.complete();
      await coordinator.onAppResumed();

      expect(gateway.registerCalls, hasLength(3));
      expect(gateway.binding?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(gateway.binding?.clientGeneration, 3);
      expect(
          store.state.receipt?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(store.state.clientGeneration, 3);
    });

    test('account switch replaces stale in-flight registration in order',
        () async {
      final gate = gateway.blockNextRegistration();
      await coordinator.start();
      await gateway.registerStarted;

      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      gate.complete();
      await coordinator.onAppResumed();

      expect(gateway.registerCalls, hasLength(2));
      expect(gateway.binding?.userId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      expect(gateway.binding?.clientGeneration, 2);
      expect(
          store.state.receipt?.userId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    });

    test(
        'unexpected account switch invalidates old token if new token is absent',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      expect(gateway.binding?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

      tokens
        ..authorized = false
        ..token = null;
      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await coordinator.onAppResumed();

      expect(tokens.deleteCalls, 1);
      expect(gateway.registerCalls, hasLength(1));
      expect(gateway.binding?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(
          store.state.receipt?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      expect(store.state.receipt?.revokePending, isTrue);
      expect(store.state.receipt?.providerTokenInvalidated, isTrue);
    });

    test('direct account switch deletes provider token before rebinding',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();

      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await coordinator.onAppResumed();

      expect(
        lifecycleEvents,
        [
          'register:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'delete-token',
          'register:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ],
      );
      expect(gateway.binding?.userId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    });

    test('pre-auth account replacement revokes old account before sign-in',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      expect(gateway.binding?.userId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

      await coordinator.prepareForAccountChange();
      expect(gateway.binding, isNull);
      expect(tokens.deleteCalls, 0);

      gateway.setUser('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await coordinator.onAppResumed();
      expect(gateway.binding?.userId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      expect(gateway.binding?.clientGeneration, 2);
    });

    test('refresh is ignored while notification permission is unavailable',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      tokens.authorized = false;
      tokens.refresh(_token('b'));
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(1));
      expect(gateway.binding?.token, _token('a'));
    });

    test(
        'logout waits for in-flight registration then revokes and deletes token',
        () async {
      final gate = gateway.blockNextRegistration();
      await coordinator.start();
      await gateway.registerStarted;

      final signOut = coordinator.prepareForSignOut();
      gate.complete();
      await signOut;

      expect(gateway.binding, isNull);
      expect(gateway.revokeCalls, 1);
      expect(tokens.deleteCalls, 1);
      expect(store.state.receipt, isNull);
      gateway.setUser(null);
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, hasLength(1));
    });

    test('offline logout cleanup does not block and retains retry receipt',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      gateway.failRevoke = true;

      await expectLater(coordinator.prepareForSignOut(), completes);
      expect(tokens.deleteCalls, 1);
      expect(store.state.receipt, isNotNull);
      expect(store.state.receipt?.revokePending, isTrue);
    });

    test(
        'false revoke retains receipt and same-token rebind advances generation',
        () async {
      await coordinator.start();
      await coordinator.onAppResumed();
      gateway.returnFalseOnRevoke = true;

      await coordinator.prepareForSignOut();
      expect(store.state.receipt?.revokePending, isTrue);

      gateway.returnFalseOnRevoke = false;
      gateway.setUser('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      await coordinator.onAppResumed();

      expect(gateway.registerCalls, hasLength(2));
      expect(gateway.binding?.clientGeneration, 2);
      expect(store.state.receipt?.revokePending, isFalse);
    });

    test('unconfigured token source creates no server registration', () async {
      tokens.available = false;
      await coordinator.start();
      await coordinator.onAppResumed();
      expect(gateway.registerCalls, isEmpty);
    });
  });

  test('missing Firebase build options fail closed without a config file',
      () async {
    final source = FirebaseNotificationDeviceTokenSource(
      platform: TargetPlatform.android,
      isWeb: false,
    );
    expect(await source.initialize(), isFalse);
    expect(await source.currentTokenIfAuthorized(), isNull);
    await source.deleteToken();
  });

  test('secure installation metadata stores generations and token hashes only',
      () async {
    final secure = _SecureValues();
    final store = SecureNotificationInstallationStore(
      secureStore: secure,
      storageScope: 'local-test',
    );
    final initial = await store.load();
    expect(initial.clientGeneration, 0);
    expect(
        initial.installationId,
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));

    final reserved = await store.reserveNextGeneration();
    const receipt = NotificationDeviceReceipt(
      userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      clientGeneration: 1,
      bindingGeneration: 3,
      tokenHash:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
    await store.saveReceipt(receipt);
    await store.markReceiptRevokePending();
    await store.markReceiptRevokePending(providerTokenInvalidated: true);

    final persisted = secure.values.values.single;
    expect(persisted, isNot(contains(_token('a'))));
    final reopened = SecureNotificationInstallationStore(
      secureStore: secure,
      storageScope: 'local-test',
    );
    final loaded = await reopened.load();
    expect(reserved.installationId, loaded.installationId);
    expect(loaded.clientGeneration, 1);
    expect(loaded.receipt?.bindingGeneration, 3);
    expect(loaded.receipt?.revokePending, isTrue);
    expect(loaded.receipt?.providerTokenInvalidated, isTrue);
  });
}

NotificationDeviceRegistrationCoordinator _coordinator(
  _DeviceGateway gateway,
  _TokenSource tokens,
  _InstallationStore store,
) =>
    NotificationDeviceRegistrationCoordinator(
      gateway: gateway,
      tokenSource: tokens,
      installationStore: store,
      platform: 'android',
    );

String _token(String suffix) => 'test-fcm-registration-token-$suffix-123456';

class _TokenSource implements NotificationDeviceTokenSource {
  _TokenSource([List<String>? lifecycleEvents])
      : lifecycleEvents = lifecycleEvents ?? <String>[];

  final List<String> lifecycleEvents;
  final StreamController<String> _refreshes =
      StreamController<String>.broadcast(sync: true);
  String? token;
  bool available = true;
  bool authorized = true;
  int deleteCalls = 0;

  @override
  Future<bool> initialize() async => available;

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Future<String?> currentTokenIfAuthorized() async =>
      available && authorized ? token : null;

  void refresh(String nextToken) {
    token = nextToken;
    _refreshes.add(nextToken);
  }

  @override
  Future<void> deleteToken() async {
    deleteCalls++;
    lifecycleEvents.add('delete-token');
  }

  Future<void> dispose() => _refreshes.close();
}

class _DeviceGateway implements NotificationDeviceGateway {
  _DeviceGateway([List<String>? lifecycleEvents])
      : lifecycleEvents = lifecycleEvents ?? <String>[];

  final List<String> lifecycleEvents;
  final StreamController<String?> _users =
      StreamController<String?>.broadcast(sync: true);
  String? _userId;
  _ServerBinding? binding;
  final List<_ServerBinding> registerCalls = [];
  int revokeCalls = 0;
  bool failRevoke = false;
  bool returnFalseOnRevoke = false;
  Completer<void>? _nextRegisterGate;
  Completer<void>? registrationStarted;
  Completer<void>? _secondRegisterGate;
  Completer<void>? secondRegistrationStarted;

  Future<void> get registerStarted {
    final started = registrationStarted;
    if (started == null) throw StateError('no registration gate was set');
    return started.future;
  }

  Future<void> get secondRegisterStarted {
    final started = secondRegistrationStarted;
    if (started == null) {
      throw StateError('no second registration gate was set');
    }
    return started.future;
  }

  void setUser(String? userId) {
    _userId = userId;
    _users.add(userId);
  }

  Completer<void> blockNextRegistration() {
    registrationStarted = Completer<void>();
    return _nextRegisterGate = Completer<void>();
  }

  Completer<void> blockSecondRegistration() {
    secondRegistrationStarted = Completer<void>();
    return _secondRegisterGate = Completer<void>();
  }

  @override
  String? get currentUserId => _userId;

  @override
  Stream<String?> watchUserIds() => _users.stream;

  @override
  Future<int?> register({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required String platform,
    required String token,
  }) async {
    if (currentUserId != expectedUserId) return null;
    lifecycleEvents.add('register:$expectedUserId');
    final call = _ServerBinding(
      userId: expectedUserId,
      installationId: installationId,
      clientGeneration: clientGeneration,
      bindingGeneration: (binding?.bindingGeneration ?? 0) + 1,
      token: token,
    );
    registerCalls.add(call);
    final gate = _nextRegisterGate ??
        (registerCalls.length == 2 ? _secondRegisterGate : null);
    if (gate != null) {
      if (registerCalls.length == 1) {
        _nextRegisterGate = null;
        registrationStarted?.complete();
      } else {
        _secondRegisterGate = null;
        secondRegistrationStarted?.complete();
      }
      await gate.future;
    }
    if (binding != null && clientGeneration <= binding!.clientGeneration) {
      return null;
    }
    binding = call;
    return call.bindingGeneration;
  }

  @override
  Future<bool> revoke({
    required String expectedUserId,
    required String installationId,
    required int clientGeneration,
    required int bindingGeneration,
  }) async {
    revokeCalls++;
    if (failRevoke) throw StateError('offline');
    if (returnFalseOnRevoke) return false;
    final current = binding;
    if (current == null ||
        current.userId != expectedUserId ||
        current.installationId != installationId ||
        current.clientGeneration != clientGeneration ||
        current.bindingGeneration != bindingGeneration ||
        currentUserId != expectedUserId) {
      return false;
    }
    binding = null;
    return true;
  }

  Future<void> dispose() => _users.close();
}

class _ServerBinding {
  const _ServerBinding({
    required this.userId,
    required this.installationId,
    required this.clientGeneration,
    required this.bindingGeneration,
    required this.token,
  });

  final String userId;
  final String installationId;
  final int clientGeneration;
  final int bindingGeneration;
  final String token;
}

class _InstallationStore implements NotificationInstallationStore {
  NotificationInstallationState state = const NotificationInstallationState(
    installationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    clientGeneration: 0,
  );

  @override
  Future<NotificationInstallationState> load() async => state;

  @override
  Future<NotificationInstallationState> reserveNextGeneration() async {
    state = NotificationInstallationState(
      installationId: state.installationId,
      clientGeneration: state.clientGeneration + 1,
      receipt: state.receipt,
    );
    return state;
  }

  @override
  Future<void> saveReceipt(NotificationDeviceReceipt receipt) async {
    state = NotificationInstallationState(
      installationId: state.installationId,
      clientGeneration: state.clientGeneration,
      receipt: receipt,
    );
  }

  @override
  Future<void> markReceiptRevokePending({
    bool providerTokenInvalidated = false,
  }) async {
    final receipt = state.receipt;
    if (receipt == null ||
        (receipt.revokePending &&
            (!providerTokenInvalidated || receipt.providerTokenInvalidated))) {
      return;
    }
    state = NotificationInstallationState(
      installationId: state.installationId,
      clientGeneration: state.clientGeneration,
      receipt: NotificationDeviceReceipt(
        userId: receipt.userId,
        clientGeneration: receipt.clientGeneration,
        bindingGeneration: receipt.bindingGeneration,
        tokenHash: receipt.tokenHash,
        revokePending: true,
        providerTokenInvalidated:
            receipt.providerTokenInvalidated || providerTokenInvalidated,
      ),
    );
  }

  @override
  Future<void> clearReceipt() async {
    state = NotificationInstallationState(
      installationId: state.installationId,
      clientGeneration: state.clientGeneration,
    );
  }
}

class _SecureValues implements SecureValueStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
