import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/secure_auth_storage.dart';
import '../../../core/config/app_config_provider.dart';
import '../data/firebase_notification_device_token_source.dart';
import '../data/secure_notification_installation_store.dart';
import '../data/supabase_notification_device_gateway.dart';
import 'notification_device_registration.dart';

final notificationDeviceRegistrationCoordinatorProvider =
    Provider<NotificationDeviceRegistrationCoordinator?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.demoMode) return null;
  final client = ref.watch(supabaseClientProvider);
  if (client == null) return null;

  final region = ref.watch(storageRegionProvider);
  final platform = switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => 'unsupported',
  };
  final coordinator = NotificationDeviceRegistrationCoordinator(
    gateway: SupabaseNotificationDeviceGateway(client),
    tokenSource: FirebaseNotificationDeviceTokenSource(),
    installationStore: SecureNotificationInstallationStore(
      secureStore: FlutterSecureValueStore(),
      storageScope: region.id,
    ),
    platform: platform,
  );
  ref.onDispose(() => unawaited(coordinator.dispose()));
  return coordinator;
});

final notificationDeviceRegistrationRuntimeProvider = Provider<void>((ref) {
  final coordinator =
      ref.watch(notificationDeviceRegistrationCoordinatorProvider);
  if (coordinator == null) return;
  unawaited(coordinator.start());
});
