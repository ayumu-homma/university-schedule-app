import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config_provider.dart';
import '../core/config/environment_status_bar.dart';
import '../core/sync/sync_coordinator.dart';
import '../features/document_import/application/document_import_reconciliation_runtime.dart';
import '../features/email_import/application/email_reconciliation_runtime.dart';
import '../features/email_import/application/email_review_providers.dart';
import '../features/friends/application/friend_providers.dart';
import '../features/notification/application/morning_alarm_controller.dart';
import '../features/notification/application/local_notification_runtime.dart';
import '../features/notification/application/notification_device_registration_provider.dart';
import '../features/timetable/application/demo_app_controller.dart';
import '../features/timetable/application/schedule_sync_runtime.dart';
import '../features/timetable/presentation/schedule_sync_status_banner.dart';
import '../features/widget_bridge/application/widget_snapshot_runtime.dart';
import '../shared/widgets/mvp_scaffold.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class UniversityScheduleApp extends ConsumerStatefulWidget {
  const UniversityScheduleApp({super.key});

  @override
  ConsumerState<UniversityScheduleApp> createState() =>
      _UniversityScheduleAppState();
}

class _UniversityScheduleAppState extends ConsumerState<UniversityScheduleApp>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (results) {
        if (results.any((result) => result != ConnectivityResult.none)) {
          unawaited(
            ref
                .read(scheduleSyncRuntimeProvider.notifier)
                .trigger(SyncTrigger.connectivity),
          );
          // A foreground friend view must re-authorize and refetch before it
          // can display again after reconnect.  The controller is a no-op
          // when sharing is not active, so background connectivity changes do
          // not start friend polling.
          unawaited(
            ref.read(friendsControllerProvider.notifier).onConnectionRestored(),
          );
        } else {
          // Shared data is authorization-gated; close its display before any
          // asynchronous cache cleanup when connectivity disappears.
          unawaited(
            ref.read(friendsControllerProvider.notifier).onConnectionLost(),
          );
        }
      },
      onError: (_) {
        // Connectivity is only a wake-up hint. RPC errors and retry state are
        // handled by the durable coordinator itself.
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final notificationRegistration =
          ref.read(notificationDeviceRegistrationCoordinatorProvider);
      if (notificationRegistration != null) {
        unawaited(notificationRegistration.onAppResumed());
      }
      ref.invalidate(demoAppControllerProvider);
      ref.invalidate(localNotificationRuntimeProvider);
      ref.invalidate(emailNetworkAvailableProvider);
      unawaited(
        ref
            .read(scheduleSyncRuntimeProvider.notifier)
            .trigger(SyncTrigger.appResume),
      );
      unawaited(
        ref
            .read(documentImportReconciliationRuntimeProvider.notifier)
            .trigger(DocumentImportReconciliationTrigger.appResume),
      );
      unawaited(
        ref.read(friendsControllerProvider.notifier).onAppResumed(),
      );
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref.read(friendsControllerProvider.notifier).onAppPaused(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    final syncStatus = ref.watch(scheduleSyncRuntimeProvider);
    ref.watch(documentImportReconciliationRuntimeProvider);
    ref.watch(emailReconciliationRuntimeProvider);
    ref.watch(morningAlarmOwnershipRuntimeProvider);
    ref.watch(localNotificationRuntimeProvider);
    ref.watch(notificationDeviceRegistrationRuntimeProvider);
    ref.watch(widgetSnapshotRuntimeProvider);
    final router = ref.watch(routerProvider);
    final banner = ScheduleSyncStatusBanner.isVisibleFor(syncStatus)
        ? ScheduleSyncStatusBanner(
            status: syncStatus,
            onRetry: () async {
              await ref
                  .read(scheduleSyncRuntimeProvider.notifier)
                  .trigger(SyncTrigger.manual);
            },
            onOpenSettings: () => router.go('/settings'),
          )
        : null;
    return MvpScaffoldBannerScope(
      banner: banner,
      child: MaterialApp.router(
        title: 'Uni Schedule',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: router,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => EnvironmentStatusBar(
          config: config,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
