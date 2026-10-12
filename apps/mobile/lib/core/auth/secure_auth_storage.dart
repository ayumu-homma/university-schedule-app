import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/storage_region.dart';

abstract interface class SecureValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

Future<void> _writeSecureValueVerified({
  required SecureValueStore store,
  required String key,
  required String value,
  required String verificationFailureMessage,
}) async {
  final previousValue = await store.read(key);
  Object? writeError;
  StackTrace? writeStackTrace;
  try {
    await store.write(key, value);
  } catch (error, stackTrace) {
    writeError = error;
    writeStackTrace = stackTrace;
  }

  final storedValue = await store.read(key);
  if (writeError == null && storedValue == value) return;

  if (storedValue != previousValue) {
    var restored = false;
    if (previousValue != null) {
      try {
        await store.write(key, previousValue);
        restored = await store.read(key) == previousValue;
      } catch (_) {
        restored = false;
      }
    }
    if (!restored) {
      await store.delete(key);
      if (await store.read(key) != null) {
        throw StateError(
          '$verificationFailureMessage Secure storage recovery failed.',
        );
      }
    }
  }

  if (writeError != null) {
    Error.throwWithStackTrace(writeError, writeStackTrace!);
  }
  throw StateError(verificationFailureMessage);
}

class FlutterSecureValueStore implements SecureValueStore {
  FlutterSecureValueStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accountName: 'jp.universityschedule.app.auth',
                accessibility: KeychainAccessibility.unlocked_this_device,
                synchronizable: false,
              ),
              aOptions: AndroidOptions(
                storageNamespace: 'jp_universityschedule_app_auth',
                migrateWithBackup: false,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SecureAuthStorageBundle {
  SecureAuthStorageBundle._({
    required this.sessionStorage,
    required this.pkceStorage,
  });

  factory SecureAuthStorageBundle.forSupabaseUrl(
    Uri supabaseUrl, {
    SecureValueStore? secureStore,
    LocalStorage? legacySessionStorage,
    GotrueAsyncStorage? legacyPkceStorage,
    StorageRegion? region,
  }) {
    final legacyProjectNamespace = supabaseUrl.host.split('.').first;
    final secureProjectNamespace =
        region?.id ?? _secureProjectNamespace(supabaseUrl);
    if (legacyProjectNamespace.isEmpty ||
        legacyProjectNamespace.length > 255 ||
        legacyProjectNamespace.contains(RegExp(r'[\r\n\x00]'))) {
      throw StateError('Supabase auth storage namespace is invalid.');
    }
    final legacySessionKey = 'sb-$legacyProjectNamespace-auth-token';
    final store = secureStore ?? FlutterSecureValueStore();
    return SecureAuthStorageBundle._(
      sessionStorage: SecureAuthLocalStorage(
        secureStore: store,
        secureKey: 'unischedule:$secureProjectNamespace:auth-token',
        legacyStorage: region == null
            ? (legacySessionStorage ??
                SharedPreferencesLocalStorage(
                  persistSessionKey: legacySessionKey,
                ))
            : SharedPreferencesLocalStorage(
                persistSessionKey: 'unischedule:${region.id}:legacy-auth',
              ),
      ),
      pkceStorage: SecurePkceAsyncStorage(
        secureStore: store,
        keyPrefix: 'unischedule:$secureProjectNamespace:pkce:',
        legacyStorage: region == null
            ? (legacyPkceStorage ?? SharedPreferencesGotrueAsyncStorage())
            : _NamespacedPkceStorage(
                legacyPkceStorage ?? SharedPreferencesGotrueAsyncStorage(),
                region.id,
              ),
      ),
    );
  }

  final SecureAuthLocalStorage sessionStorage;
  final SecurePkceAsyncStorage pkceStorage;

  static String _secureProjectNamespace(Uri supabaseUrl) {
    final host = supabaseUrl.host.toLowerCase();
    if (host.isEmpty) {
      throw StateError('Supabase auth storage namespace is invalid.');
    }
    final hostedMatch =
        RegExp(r'^([a-z0-9]{20})\.supabase\.co$').firstMatch(host);
    if (hostedMatch != null) return hostedMatch.group(1)!;
    final origin = '${supabaseUrl.scheme.toLowerCase()}://$host:'
        '${supabaseUrl.hasPort ? supabaseUrl.port : 0}';
    return 'local_${sha256.convert(utf8.encode(origin)).toString().substring(0, 32)}';
  }
}

/// Persists the Supabase session in platform secure storage.
///
/// The previous Supabase Flutter default used SharedPreferences. Migration is
/// ordered so the legacy value is removed only after a secure read-back proves
/// that the complete session was stored.
class SecureAuthLocalStorage extends LocalStorage {
  SecureAuthLocalStorage({
    required SecureValueStore secureStore,
    required String secureKey,
    required LocalStorage legacyStorage,
  })  : _secureStore = secureStore,
        _secureKey = secureKey,
        _legacyStorage = legacyStorage;

  static const maximumSessionBytes = 256 * 1024;

  final SecureValueStore _secureStore;
  final String _secureKey;
  final LocalStorage _legacyStorage;
  bool _initialized = false;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<void> initialize() {
    return _serialize(() async {
      if (_initialized) return;
      await _legacyStorage.initialize();
      final secureSession = await _secureStore.read(_secureKey);
      if (secureSession == null) {
        final legacySession = await _legacyStorage.accessToken();
        if (legacySession != null) {
          _validateSession(legacySession);
          await _writeSecureValueVerified(
            store: _secureStore,
            key: _secureKey,
            value: legacySession,
            verificationFailureMessage:
                'Secure session migration verification failed.',
          );
          await _removeLegacySessionVerified();
        }
      } else {
        _validateSession(secureSession);
        if (await _legacyStorage.hasAccessToken()) {
          await _removeLegacySessionVerified();
        }
      }
      _initialized = true;
    });
  }

  @override
  Future<bool> hasAccessToken() {
    return _serialize(() async {
      _ensureInitialized();
      return await _secureStore.read(_secureKey) != null;
    });
  }

  @override
  Future<String?> accessToken() {
    return _serialize(() async {
      _ensureInitialized();
      return _secureStore.read(_secureKey);
    });
  }

  @override
  Future<void> persistSession(String persistSessionString) {
    return _serialize(() async {
      _ensureInitialized();
      _validateSession(persistSessionString);
      await _writeSecureValueVerified(
        store: _secureStore,
        key: _secureKey,
        value: persistSessionString,
        verificationFailureMessage:
            'Secure session persistence verification failed.',
      );
    });
  }

  @override
  Future<void> removePersistedSession() {
    return _serialize(() async {
      _ensureInitialized();
      await _removeLegacySessionVerified();
      await _secureStore.delete(_secureKey);
      if (await _secureStore.read(_secureKey) != null) {
        throw StateError('Secure session removal verification failed.');
      }
    });
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _removeLegacySessionVerified() async {
    await _legacyStorage.removePersistedSession();
    if (await _legacyStorage.hasAccessToken() ||
        await _legacyStorage.accessToken() != null) {
      throw StateError('Legacy session removal verification failed.');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Secure auth storage is not initialized.');
    }
  }

  static void _validateSession(String value) {
    if (value.isEmpty || utf8.encode(value).length > maximumSessionBytes) {
      throw StateError('Persisted auth session is invalid.');
    }
  }
}

/// Stores PKCE verifiers in the same platform-secure boundary as the session.
/// Existing verifier values migrate lazily by key to avoid breaking an OAuth
/// callback that was started immediately before an app update.
class SecurePkceAsyncStorage extends GotrueAsyncStorage {
  SecurePkceAsyncStorage({
    required SecureValueStore secureStore,
    required String keyPrefix,
    required GotrueAsyncStorage legacyStorage,
  })  : _secureStore = secureStore,
        _keyPrefix = keyPrefix,
        _legacyStorage = legacyStorage;

  static const maximumVerifierBytes = 16 * 1024;

  final SecureValueStore _secureStore;
  final String _keyPrefix;
  final GotrueAsyncStorage _legacyStorage;

  @override
  Future<String?> getItem({required String key}) async {
    final secureKey = _validatedKey(key);
    final secureValue = await _secureStore.read(secureKey);
    if (secureValue != null) {
      _validateValue(secureValue);
      if (await _legacyStorage.getItem(key: key) != null) {
        await _removeLegacyValueVerified(key);
      }
      return secureValue;
    }
    final legacyValue = await _legacyStorage.getItem(key: key);
    if (legacyValue == null) return null;
    _validateValue(legacyValue);
    await _writeSecureValueVerified(
      store: _secureStore,
      key: secureKey,
      value: legacyValue,
      verificationFailureMessage: 'Secure PKCE migration verification failed.',
    );
    await _removeLegacyValueVerified(key);
    return legacyValue;
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    final secureKey = _validatedKey(key);
    _validateValue(value);
    await _writeSecureValueVerified(
      store: _secureStore,
      key: secureKey,
      value: value,
      verificationFailureMessage:
          'Secure PKCE persistence verification failed.',
    );
    await _removeLegacyValueVerified(key);
  }

  @override
  Future<void> removeItem({required String key}) async {
    final secureKey = _validatedKey(key);
    await _removeLegacyValueVerified(key);
    await _secureStore.delete(secureKey);
    if (await _secureStore.read(secureKey) != null) {
      throw StateError('Secure PKCE removal verification failed.');
    }
  }

  Future<void> _removeLegacyValueVerified(String key) async {
    await _legacyStorage.removeItem(key: key);
    if (await _legacyStorage.getItem(key: key) != null) {
      throw StateError('Legacy PKCE removal verification failed.');
    }
  }

  String _validatedKey(String key) {
    if (key.isEmpty ||
        key.length > 512 ||
        key.contains(RegExp(r'[\r\n\x00]'))) {
      throw StateError('PKCE storage key is invalid.');
    }
    return '$_keyPrefix$key';
  }

  static void _validateValue(String value) {
    if (value.isEmpty || utf8.encode(value).length > maximumVerifierBytes) {
      throw StateError('PKCE storage value is invalid.');
    }
  }
}

/// Keeps the legacy PKCE migration source inside the resolved storage region.
/// A region-scoped auth bundle must never inspect the historical global key
/// names, because those keys do not identify an environment or account.
class _NamespacedPkceStorage extends GotrueAsyncStorage {
  _NamespacedPkceStorage(this._delegate, String regionId)
      : _prefix = 'unischedule:$regionId:legacy-pkce:';

  final GotrueAsyncStorage _delegate;
  final String _prefix;

  String _key(String key) => '$_prefix$key';

  @override
  Future<String?> getItem({required String key}) =>
      _delegate.getItem(key: _key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _delegate.setItem(key: _key(key), value: value);

  @override
  Future<void> removeItem({required String key}) =>
      _delegate.removeItem(key: _key(key));
}
