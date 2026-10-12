// ignore_for_file: non_constant_identifier_names

@ffi.DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as sqlite_bindings;

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)>()
external ffi.Pointer<ffi.Void> sqlite3_vfs_find(ffi.Pointer<ffi.Char> name);

const sqliteIdentityChannelName = 'jp.universityschedule.app/sqlite_identity';

class SqliteIdentityException implements Exception {
  const SqliteIdentityException(this.reason);
  final String reason;

  @override
  String toString() => 'SqliteIdentityException($reason)';
}

/// Certifies that Dart's package:sqlite3 bindings resolve to the same
/// application asset that the synchronous JNI coordinator uses. The process
/// local certificate is required before any canonical storage open.
class SqliteIdentityHandshake {
  const SqliteIdentityHandshake({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(sqliteIdentityChannelName);

  final MethodChannel _channel;

  static Future<void>? _inFlight;
  static bool _verified = false;

  Future<void> verify({bool force = false}) {
    if (!Platform.isAndroid) {
      _verified = true;
      return Future<void>.value();
    }
    if (_verified && !force) {
      return Future<void>.value();
    }
    return _inFlight ??= _verifyOnce().whenComplete(() {
      _inFlight = null;
    });
  }

  Future<void> _verifyOnce() async {
    final pointers = <int>[
      sqlite_bindings.addresses.sqlite3_open_v2.address,
      sqlite_bindings.addresses.sqlite3_prepare_v2.address,
      sqlite_bindings.addresses.sqlite3_step.address,
      sqlite_bindings.addresses.sqlite3_finalize.address,
      sqlite_bindings.addresses.sqlite3_close_v2.address,
      sqlite3_vfs_find(ffi.nullptr).address,
    ];
    final raw = await _channel.invokeMethod<Object?>('verify', {
      'dartAddresses': pointers,
      'binding': 'package:sqlite3-3.3.4',
    });
    if (raw is! Map) {
      throw const SqliteIdentityException('invalid_native_identity');
    }
    final response = Map<Object?, Object?>.from(raw);
    final ok = response['ok'] == true || response['ok'] == 'true';
    final pointersMatch = response['pointersMatch'] == true ||
        response['pointersMatch'] == 'true';
    if (!ok || !pointersMatch || response['reason'] != 'ok') {
      throw SqliteIdentityException(
        response['reason']?.toString() ?? 'sqlite_identity_mismatch',
      );
    }
    final vfsMatch = response['vfsMatch'];
    if (vfsMatch != true && vfsMatch != 'true') {
      throw const SqliteIdentityException('sqlite_vfs_mismatch');
    }
    _verified = true;
  }

  static void requireVerified() {
    if (Platform.isAndroid && !_verified) {
      throw const SqliteIdentityException('sqlite_identity_not_verified');
    }
  }

  Future<void> recordCorruption(String region,
      {String reason = 'dart_sqlite_corruption'}) async {
    if (!Platform.isAndroid) return;
    _validateRegion(region);
    await _channel.invokeMethod<void>('recordCorruption', {
      'region': region,
      'reason': reason,
    });
  }

  /// Reads the durable native health marker before any canonical SQLite open.
  /// The native side also keeps an in-memory latch, so this check remains
  /// effective after a marker was observed earlier in the process.
  Future<void> checkHealth(String region) async {
    if (!Platform.isAndroid) return;
    _validateRegion(region);
    await _channel.invokeMethod<void>('checkHealth', {'region': region});
  }

  static void _validateRegion(String region) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(region)) {
      throw ArgumentError.value(region, 'region', 'must be a SHA-256 id');
    }
  }

  static void resetForTests() {
    _inFlight = null;
    _verified = false;
  }
}
