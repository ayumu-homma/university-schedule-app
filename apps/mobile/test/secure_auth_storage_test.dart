import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:university_schedule_mobile/core/auth/secure_auth_storage.dart';

void main() {
  group('SecureAuthLocalStorage', () {
    test('migrates only after secure read-back and removes legacy value',
        () async {
      final secure = _MemorySecureStore();
      final legacy = _MemoryLocalStorage('legacy-session');
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );

      await storage.initialize();

      expect(await storage.accessToken(), 'legacy-session');
      expect(secure.values['secure-session'], 'legacy-session');
      expect(legacy.value, isNull);
    });

    test('keeps legacy session when secure write fails', () async {
      final secure = _MemorySecureStore(failWrites: true);
      final legacy = _MemoryLocalStorage('legacy-session');
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );

      await expectLater(storage.initialize(), throwsStateError);

      expect(legacy.value, 'legacy-session');
      expect(secure.values, isEmpty);
    });

    test('keeps legacy session when secure write read-back is different',
        () async {
      final secure = _MemorySecureStore(corruptWrites: true);
      final legacy = _MemoryLocalStorage('legacy-session');
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );

      await expectLater(storage.initialize(), throwsStateError);

      expect(legacy.value, 'legacy-session');
      expect(secure.values, isEmpty);

      secure.corruptWrites = false;
      final retryStorage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );
      await retryStorage.initialize();

      expect(await retryStorage.accessToken(), 'legacy-session');
      expect(secure.values['secure-session'], 'legacy-session');
      expect(legacy.value, isNull);
    });

    test('rejects an oversized persisted session before secure storage',
        () async {
      final secure = _MemorySecureStore();
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: _MemoryLocalStorage(),
      );
      await storage.initialize();

      await expectLater(
        storage.persistSession(
          'x' * (SecureAuthLocalStorage.maximumSessionBytes + 1),
        ),
        throwsStateError,
      );
      expect(secure.values, isEmpty);
    });

    test('restores the prior session after a corrupt refresh write', () async {
      final secure = _MemorySecureStore()
        ..values['secure-session'] = 'previous-session';
      final legacy = _MemoryLocalStorage();
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );
      await storage.initialize();
      secure.corruptWriteCount = 1;

      await expectLater(
        storage.persistSession('refreshed-session'),
        throwsStateError,
      );

      expect(secure.values['secure-session'], 'previous-session');
      final nextLaunch = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );
      await nextLaunch.initialize();
      expect(await nextLaunch.accessToken(), 'previous-session');
    });

    test('serializes a delayed refresh write before sign-out removal',
        () async {
      final secure = _DelayedWriteSecureStore();
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: _MemoryLocalStorage(),
      );
      await storage.initialize();

      final persist = storage.persistSession('refresh-session');
      await secure.writeStarted.future;
      final remove = storage.removePersistedSession();
      secure.releaseWrite.complete();

      await persist;
      await remove;
      expect(secure.values, isEmpty);
      expect(secure.operations, ['write-start', 'write-end', 'delete']);
    });

    test('serializes concurrent refresh writes in invocation order', () async {
      final secure = _DelayedWriteSecureStore();
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: _MemoryLocalStorage(),
      );
      await storage.initialize();

      final first = storage.persistSession('first-refresh');
      await secure.writeStarted.future;
      final second = storage.persistSession('second-refresh');
      secure.releaseWrite.complete();

      await Future.wait([first, second]);
      expect(await storage.accessToken(), 'second-refresh');
      expect(
        secure.operations,
        ['write-start', 'write-end', 'write-start', 'write-end'],
      );
    });

    test('clears both secure and legacy session locations on sign-out',
        () async {
      final secure = _MemorySecureStore()
        ..values['secure-session'] = 'secure-session-value';
      final legacy = _MemoryLocalStorage('stale-legacy-session');
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );

      await storage.initialize();
      await storage.removePersistedSession();

      expect(await storage.hasAccessToken(), isFalse);
      expect(legacy.value, isNull);
    });

    test(
        'legacy removal failure cannot silently resurrect a signed-out session',
        () async {
      final secure = _MemorySecureStore();
      final legacy = _MemoryLocalStorage();
      final storage = SecureAuthLocalStorage(
        secureStore: secure,
        secureKey: 'secure-session',
        legacyStorage: legacy,
      );
      await storage.initialize();
      await storage.persistSession('secure-session-value');
      legacy
        ..value = 'stale-legacy-session'
        ..failRemovals = true;

      await expectLater(storage.removePersistedSession(), throwsStateError);

      expect(secure.values['secure-session'], 'secure-session-value');
      expect(legacy.value, 'stale-legacy-session');
    });
  });

  group('SecurePkceAsyncStorage', () {
    test('lazily migrates an in-flight verifier without exposing its key',
        () async {
      final secure = _MemorySecureStore();
      final legacy = _MemoryAsyncStorage()..values['flow-key'] = 'verifier';
      final storage = SecurePkceAsyncStorage(
        secureStore: secure,
        keyPrefix: 'project:pkce:',
        legacyStorage: legacy,
      );

      expect(await storage.getItem(key: 'flow-key'), 'verifier');
      expect(secure.values['project:pkce:flow-key'], 'verifier');
      expect(legacy.values, isEmpty);
    });

    test('clears a corrupt migration write so the legacy verifier can retry',
        () async {
      final secure = _MemorySecureStore(corruptWrites: true);
      final legacy = _MemoryAsyncStorage()..values['flow-key'] = 'verifier';
      final storage = SecurePkceAsyncStorage(
        secureStore: secure,
        keyPrefix: 'project:pkce:',
        legacyStorage: legacy,
      );

      await expectLater(storage.getItem(key: 'flow-key'), throwsStateError);
      expect(secure.values, isEmpty);
      expect(legacy.values['flow-key'], 'verifier');

      secure.corruptWrites = false;
      final retryStorage = SecurePkceAsyncStorage(
        secureStore: secure,
        keyPrefix: 'project:pkce:',
        legacyStorage: legacy,
      );
      expect(await retryStorage.getItem(key: 'flow-key'), 'verifier');
      expect(secure.values['project:pkce:flow-key'], 'verifier');
      expect(legacy.values, isEmpty);
    });

    test('does not retain a corrupt verifier persistence write', () async {
      final secure = _MemorySecureStore(corruptWrites: true);
      final storage = SecurePkceAsyncStorage(
        secureStore: secure,
        keyPrefix: 'project:pkce:',
        legacyStorage: _MemoryAsyncStorage(),
      );

      await expectLater(
        storage.setItem(key: 'flow-key', value: 'verifier'),
        throwsStateError,
      );
      expect(secure.values, isEmpty);
    });

    test('rejects control characters and oversized verifier values', () async {
      final storage = SecurePkceAsyncStorage(
        secureStore: _MemorySecureStore(),
        keyPrefix: 'project:pkce:',
        legacyStorage: _MemoryAsyncStorage(),
      );

      await expectLater(
        storage.setItem(key: 'bad\nkey', value: 'verifier'),
        throwsStateError,
      );
      await expectLater(
        storage.setItem(
          key: 'flow-key',
          value: 'x' * (SecurePkceAsyncStorage.maximumVerifierBytes + 1),
        ),
        throwsStateError,
      );
    });

    test('legacy verifier removal is read back before secure deletion',
        () async {
      final secure = _MemorySecureStore()..values['project:pkce:flow'] = 'v';
      final legacy = _MemoryAsyncStorage()
        ..values['flow'] = 'legacy-v'
        ..failRemovals = true;
      final storage = SecurePkceAsyncStorage(
        secureStore: secure,
        keyPrefix: 'project:pkce:',
        legacyStorage: legacy,
      );

      await expectLater(storage.removeItem(key: 'flow'), throwsStateError);

      expect(secure.values['project:pkce:flow'], 'v');
      expect(legacy.values['flow'], 'legacy-v');
    });
  });

  test('bundle isolates auth keys by Supabase project hostname', () async {
    final secure = _MemorySecureStore();
    final first = SecureAuthStorageBundle.forSupabaseUrl(
      Uri.parse('https://abcdefghijklmnopqrst.supabase.co'),
      secureStore: secure,
      legacySessionStorage: _MemoryLocalStorage(),
      legacyPkceStorage: _MemoryAsyncStorage(),
    );
    final second = SecureAuthStorageBundle.forSupabaseUrl(
      Uri.parse('https://uvwxyz0123456789abcd.supabase.co'),
      secureStore: secure,
      legacySessionStorage: _MemoryLocalStorage(),
      legacyPkceStorage: _MemoryAsyncStorage(),
    );
    await first.sessionStorage.initialize();
    await second.sessionStorage.initialize();

    await first.sessionStorage.persistSession('first-session');
    await second.sessionStorage.persistSession('second-session');

    expect(await first.sessionStorage.accessToken(), 'first-session');
    expect(await second.sessionStorage.accessToken(), 'second-session');
    expect(secure.values, hasLength(2));
  });

  test('bundle isolates loopback instances by full origin and port', () async {
    final secure = _MemorySecureStore();
    final first = SecureAuthStorageBundle.forSupabaseUrl(
      Uri.parse('http://127.0.0.1:54321'),
      secureStore: secure,
      legacySessionStorage: _MemoryLocalStorage(),
      legacyPkceStorage: _MemoryAsyncStorage(),
    );
    final second = SecureAuthStorageBundle.forSupabaseUrl(
      Uri.parse('http://127.0.0.1:54322'),
      secureStore: secure,
      legacySessionStorage: _MemoryLocalStorage(),
      legacyPkceStorage: _MemoryAsyncStorage(),
    );
    await first.sessionStorage.initialize();
    await second.sessionStorage.initialize();

    await first.sessionStorage.persistSession('first-local-session');
    await second.sessionStorage.persistSession('second-local-session');

    expect(await first.sessionStorage.accessToken(), 'first-local-session');
    expect(await second.sessionStorage.accessToken(), 'second-local-session');
    expect(secure.values, hasLength(2));
  });
}

class _MemorySecureStore implements SecureValueStore {
  _MemorySecureStore({this.failWrites = false, this.corruptWrites = false});

  final bool failWrites;
  bool corruptWrites;
  int corruptWriteCount = 0;
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('synthetic secure write failure');
    final corruptThisWrite = corruptWrites || corruptWriteCount > 0;
    if (corruptWriteCount > 0) corruptWriteCount -= 1;
    values[key] = corruptThisWrite ? '$value-corrupted' : value;
  }
}

class _DelayedWriteSecureStore implements SecureValueStore {
  final values = <String, String>{};
  final operations = <String>[];
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool _delayNextWrite = true;

  @override
  Future<void> delete(String key) async {
    operations.add('delete');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    operations.add('write-start');
    if (_delayNextWrite) {
      _delayNextWrite = false;
      writeStarted.complete();
      await releaseWrite.future;
    }
    values[key] = value;
    operations.add('write-end');
  }
}

class _MemoryLocalStorage extends LocalStorage {
  _MemoryLocalStorage([this.value]);

  String? value;
  bool failRemovals = false;

  @override
  Future<String?> accessToken() async => value;

  @override
  Future<bool> hasAccessToken() async => value != null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> persistSession(String persistSessionString) async {
    value = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    if (failRemovals) return;
    value = null;
  }
}

class _MemoryAsyncStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  bool failRemovals = false;

  @override
  Future<String?> getItem({required String key}) async => values[key];

  @override
  Future<void> removeItem({required String key}) async {
    if (failRemovals) return;
    values.remove(key);
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }
}
