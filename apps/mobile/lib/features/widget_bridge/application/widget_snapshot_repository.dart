import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/native/native_scope_bridge.dart';

const androidWidgetChannelName = 'jp.universityschedule.app/widget_bridge';

abstract interface class WidgetSnapshotRepository {
  Future<void> saveSnapshot(WidgetSnapshot snapshot, {NativeScopeState? scope});

  Future<WidgetSnapshot?> readLatestSnapshot();
}

final widgetSnapshotRepositoryProvider =
    Provider<WidgetSnapshotRepository>((ref) {
  return widgetSnapshotRepositoryFor(defaultTargetPlatform);
});

WidgetSnapshotRepository widgetSnapshotRepositoryFor(
  TargetPlatform platform, {
  bool allowDesktopTestFallback = kDebugMode,
}) {
  if (platform == TargetPlatform.android) {
    return const MethodChannelWidgetSnapshotRepository();
  }
  if (platform != TargetPlatform.iOS && allowDesktopTestFallback) {
    return InMemoryWidgetSnapshotRepository();
  }
  return const UnsupportedWidgetSnapshotRepository();
}

class UnsupportedWidgetSnapshotRepository implements WidgetSnapshotRepository {
  const UnsupportedWidgetSnapshotRepository();

  static UnsupportedError _unavailable() => UnsupportedError(
        'Native widget snapshot persistence is unavailable on this platform.',
      );

  @override
  Future<WidgetSnapshot?> readLatestSnapshot() => Future.error(_unavailable());

  @override
  Future<void> saveSnapshot(WidgetSnapshot snapshot,
          {NativeScopeState? scope}) =>
      Future.error(_unavailable());
}

class MethodChannelWidgetSnapshotRepository
    implements WidgetSnapshotRepository {
  const MethodChannelWidgetSnapshotRepository({
    MethodChannel channel = const MethodChannel(androidWidgetChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<WidgetSnapshot?> readLatestSnapshot() async {
    final payload = await _channel.invokeMethod<String>('readSnapshot');
    if (payload == null) return null;
    return _decode(payload);
  }

  @override
  Future<void> saveSnapshot(WidgetSnapshot snapshot,
      {NativeScopeState? scope}) async {
    final payload = jsonEncode(snapshot.toJson());
    // Decode through the strict public contract before crossing the native
    // boundary. Android validates independently and fails closed as well.
    _decode(payload);
    final arguments = <String, Object?>{'payload': payload};
    if (scope != null) {
      if (!scope.active ||
          scope.regionId == null ||
          scope.ownerHash == null ||
          scope.activationToken == null) {
        throw StateError('Widget snapshot scope is unavailable.');
      }
      arguments.addAll({
        'regionId': scope.regionId,
        'ownerHash': scope.ownerHash,
        'generation': scope.generation,
        'activationToken': scope.activationToken,
      });
    }
    await _channel.invokeMethod<void>('saveSnapshot', arguments);
  }

  WidgetSnapshot _decode(String payload) {
    if (payload.length > 64 * 1024) {
      throw const FormatException('Widget snapshot exceeds the size limit.');
    }
    final decoded = jsonDecode(payload);
    if (decoded is! Map) {
      throw const FormatException('Widget snapshot must be a JSON object.');
    }
    return WidgetSnapshot.fromJson(Map<String, Object?>.from(decoded));
  }
}

class InMemoryWidgetSnapshotRepository implements WidgetSnapshotRepository {
  WidgetSnapshot? _snapshot;

  @override
  Future<WidgetSnapshot?> readLatestSnapshot() async => _snapshot;

  @override
  Future<void> saveSnapshot(WidgetSnapshot snapshot,
      {NativeScopeState? scope}) async {
    _snapshot = snapshot;
  }
}
