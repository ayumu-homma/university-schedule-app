import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../config/storage_region.dart';

const nativeScopeChannelName = 'jp.universityschedule.app/native_scope';

class NativeScopeState {
  const NativeScopeState({
    required this.regionId,
    required this.ownerHash,
    required this.activationToken,
    required this.generation,
    required this.active,
  });

  const NativeScopeState.inactive()
      : regionId = null,
        ownerHash = null,
        activationToken = null,
        generation = 0,
        active = false;

  final String? regionId;
  final String? ownerHash;
  final String? activationToken;
  final int generation;
  final bool active;

  bool matchesOwner(String ownerUserId) {
    if (!active || ownerHash == null) return false;
    return ownerHash ==
        sha256.convert(utf8.encode(ownerUserId.trim())).toString();
  }

  factory NativeScopeState.fromMap(Map<Object?, Object?> map) {
    final generation = map['generation'];
    if (generation is! int || map['active'] is! bool) {
      throw const FormatException('Invalid native scope state.');
    }
    return NativeScopeState(
      regionId: map['regionId'] as String?,
      ownerHash: map['ownerHash'] as String?,
      activationToken: map['activationToken'] as String?,
      generation: generation,
      active: map['active'] as bool,
    );
  }
}

class NativeScopeBridge {
  const NativeScopeBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(nativeScopeChannelName);

  final MethodChannel _channel;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<NativeScopeState> prepare(StorageRegion region) async {
    if (!isSupported) {
      return const NativeScopeState.inactive();
    }
    return _invoke('prepareRegion', {'regionId': region.id});
  }

  Future<NativeScopeState> activate(
    StorageRegion region,
    String ownerUserId,
  ) async {
    if (!isSupported) return const NativeScopeState.inactive();
    return _invoke('activateOwner', {
      'regionId': region.id,
      'ownerId': ownerUserId,
    });
  }

  Future<NativeScopeState> deactivate() async {
    if (!isSupported) return const NativeScopeState.inactive();
    return _invoke('deactivate');
  }

  Future<NativeScopeState> current() async {
    if (!isSupported) return const NativeScopeState.inactive();
    return _invoke('current');
  }

  Future<NativeScopeState> _invoke(String method, [Object? arguments]) async {
    final result = await _channel.invokeMethod<Object?>(method, arguments);
    if (result is! Map) {
      throw const FormatException('Invalid native scope response.');
    }
    return NativeScopeState.fromMap(Map<Object?, Object?>.from(result));
  }
}

final nativeScopeBridgeProvider = Provider<NativeScopeBridge>((ref) {
  return const NativeScopeBridge();
});
