import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../timetable/data/local_schedule_repository.dart';
import '../application/morning_alarm_controller.dart';
import '../application/local_notification_runtime.dart';
import '../data/local_notification_store.dart';

/// Keeps the accepted onboarding explanation after a first-course save.
/// This is informational only: neither action can open the OS permission UI.
Future<void> offerFirstCourseNotificationEducation(
  BuildContext context,
  WidgetRef ref,
) =>
    _offerNotificationPrompt(
      context,
      ref,
      promptKey: LocalNotificationStore.firstCourseEducationPromptKey,
      title: '予定通知について',
      positiveLabel: 'わかった',
      requestOsPermission: false,
    );

/// Offers the OS permission request only after a new assignment or event was
/// successfully registered and the user accepts this in-app explanation.
Future<void> offerPostRegistrationNotificationPermissionPrompt(
  BuildContext context,
  WidgetRef ref,
) =>
    _offerNotificationPrompt(
      context,
      ref,
      promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
      title: '予定通知を有効にしますか？',
      positiveLabel: '通知を許可',
      requestOsPermission: true,
    );

Future<void> _offerNotificationPrompt(
  BuildContext context,
  WidgetRef ref, {
  required String promptKey,
  required String title,
  required String positiveLabel,
  required bool requestOsPermission,
}) async {
  try {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final active = ref.read(activeScheduleContextProvider);
    if (active == null) return;
    final store = LocalNotificationStore(ref.read(appDatabaseProvider));
    if (requestOsPermission &&
        !await store.hasRegisteredCourse(
          active.ownerUserId,
          active.termId,
        )) {
      return;
    }
    if (await store.permissionPromptSeen(
      active.ownerUserId,
      promptKey: promptKey,
    )) {
      return;
    }
    if (!context.mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: const Text(
          '授業・課題・試験・予定の開始前に、この端末で通知します。'
          '端末の通知設定と正確なアラーム設定が必要です。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('後で'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(positiveLabel),
          ),
        ],
      ),
    );
    // Persist the response before a possible OS call. A denial or dismissal
    // must not cause the automatic prompt to reappear after every save.
    await store.markPermissionPromptSeen(
      active.ownerUserId,
      promptKey: promptKey,
    );
    if (!requestOsPermission || accepted != true || !context.mounted) return;
    try {
      await ref
          .read(morningAlarmControllerProvider.notifier)
          .requestNotificationPermission();
      ref.invalidate(localNotificationRuntimeProvider);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('通知を有効にできませんでした。設定画面から再試行できます。'),
          ),
        );
      }
    }
  } on Object {
    // Permission UX must never turn a successful registration into a failure.
  }
}
