import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'app/bootstrap.dart';
import 'core/native/sqlite_identity_handshake.dart';
import 'debug/phase8_sqlite_proof.dart' as phase8_proof;
import 'features/notification/application/local_notification_projection.dart';
import 'features/notification/data/local_notification_readonly_snapshot.dart';

const notificationBackgroundChannelName =
    'jp.universityschedule.app/notification_background';

class _HeadlessServicesBinding extends BindingBase
    with SchedulerBinding, ServicesBinding {}

/// Retained entrypoint launched by Android JobScheduler without an Activity.
/// It only reads the already committed canonical database and sends the full
/// projection back to the native guarded publisher. No auth, bootstrap,
/// network, Drift migration, seed, or durable Dart write is allowed here.
@pragma('vm:entry-point')
Future<void> phase71HeadlessEntryPoint() async {
  try {
    ServicesBinding.instance;
  } on Object {
    _HeadlessServicesBinding();
  }
  const channel = MethodChannel(notificationBackgroundChannelName);
  try {
    await const SqliteIdentityHandshake().verify(force: true);
  } on Object catch (error) {
    await channel.invokeMethod<void>('result', {'error': error.toString()});
    return;
  }
  channel.setMethodCallHandler((call) async {
    if (call.method != 'refill') {
      return null;
    }
    final raw = call.arguments;
    try {
      if (raw is! Map) {
        throw const FormatException('refill request must be a map');
      }
      final request = Map<Object?, Object?>.from(raw);
      final scope = Map<Object?, Object?>.from(request['scope'] as Map);
      final requestRegionId = scope['regionId'] as String;
      final databasePath = request['databasePath'] as String?;
      if (databasePath == null || databasePath.isEmpty) {
        throw StateError('headless_database_path_missing');
      }
      final nowMs = (request['planningNowMs'] as num?)?.toInt() ??
          DateTime.now().toUtc().millisecondsSinceEpoch;
      final snapshot = await loadReadonlySnapshotInBackground(
        LocalNotificationReadonlySnapshotRequest(
          databasePath: databasePath,
          regionId: requestRegionId,
          ownerUserId: request['ownerUserId'] as String? ?? '',
          ownerHash: scope['ownerHash'] as String,
          nowUtc: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
          expectedPreviousProjectionEpoch:
              (request['expectedProjectionEpoch'] as num?)?.toInt(),
          activationToken: scope['activationToken'] as String?,
          generation: (scope['generation'] as num?)?.toInt(),
          jobRunToken: request['runToken'] as String?,
        ),
      );
      final projection = const LocalNotificationProjectionComputer().compute(
        snapshot,
        nowUtc: DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
      );
      await const SqliteIdentityHandshake().checkHealth(requestRegionId);
      await channel.invokeMethod<void>('result', {
        'request': projection.toPublicationPayload(
          databasePath: databasePath,
          regionId: requestRegionId,
          ownerHash: scope['ownerHash'] as String,
          generation: (scope['generation'] as num).toInt(),
          activationToken: scope['activationToken'] as String,
          jobRunToken: request['runToken'] as String?,
        ),
      });
    } on Object catch (error) {
      // The guarded reader records storage failures before returning them.
      // Configuration, scope and projection failures never mark a DB corrupt.
      await channel.invokeMethod<void>('result', {
        'error': error.toString(),
      });
    }
    return null;
  });
  // Native waits for this acknowledgement before sending the refill request,
  // avoiding a startup race between Dart handler registration and JobService.
  try {
    await channel.invokeMethod<void>('ready', {'schemaVersion': 1});
  } on MissingPluginException {
    // Older native builds send refill immediately; the handler remains
    // registered and still accepts that request.
  }
}

@pragma('vm:entry-point')
Future<void> phase8SqliteProofEntryPoint() =>
    phase8_proof.phase8SqliteProofEntryPoint();

@pragma('vm:entry-point')
Future<void> main() => bootstrap();
