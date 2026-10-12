import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_controller.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';
import 'package:university_schedule_mobile/features/notification/presentation/ordinary_notification_permission_prompt.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('prompt markers survive reopening the local database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'notification-prompt-order-',
    );
    final file = File('${directory.path}/notifications.sqlite');
    AppDatabase? persistentDatabase;
    final warnAboutMultipleDatabases =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    try {
      persistentDatabase = AppDatabase(NativeDatabase(file));
      final firstStore = LocalNotificationStore(persistentDatabase);
      await firstStore.markPermissionPromptSeen(
        'owner-a',
        promptKey: LocalNotificationStore.firstCourseEducationPromptKey,
      );
      await firstStore.markPermissionPromptSeen(
        'owner-b',
        promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
      );
      await persistentDatabase.close();

      persistentDatabase = AppDatabase(NativeDatabase(file));
      final reopenedStore = LocalNotificationStore(persistentDatabase);
      expect(
        await reopenedStore.permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.firstCourseEducationPromptKey,
        ),
        isTrue,
      );
      expect(
        await reopenedStore.permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
        ),
        isFalse,
      );
      expect(
        await reopenedStore.permissionPromptSeen(
          'owner-b',
          promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
        ),
        isTrue,
      );
    } finally {
      await persistentDatabase?.close();
      driftRuntimeOptions.dontWarnAboutMultipleDatabases =
          warnAboutMultipleDatabases;
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'first-course education preserves Later and never requests OS permission',
    (tester) => _withAndroidPlatform(() async {
      final recorder = _PermissionRequestRecorder();
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerFirstCourseNotificationEducation,
      );

      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      expect(find.text('予定通知について'), findsOneWidget);
      await tester.tap(find.text('後で'));
      await tester.pumpAndSettle();

      final store = LocalNotificationStore(database);
      expect(
        await store.permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.firstCourseEducationPromptKey,
        ),
        isTrue,
      );
      expect(
        await store.permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
        ),
        isFalse,
      );
      expect(recorder.permissionRequests, 0);

      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        ownerUserId: 'owner-b',
        action: offerFirstCourseNotificationEducation,
      );
      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('わかった'));
      await tester.pumpAndSettle();
      expect(recorder.permissionRequests, 0);
      expect(
        await store.permissionPromptSeen(
          'owner-b',
          promptKey: LocalNotificationStore.firstCourseEducationPromptKey,
        ),
        isTrue,
      );
    }),
  );

  testWidgets(
    'first-course Later and legacy marker do not suppress post-registration explanation',
    (tester) => _withAndroidPlatform(() async {
      final recorder = _PermissionRequestRecorder();
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerFirstCourseNotificationEducation,
      );
      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('後で'));
      await tester.pumpAndSettle();

      await _insertCourse(database, 'owner-a');
      final store = LocalNotificationStore(database);
      await store.markPermissionPromptSeen(
        'owner-a',
        promptKey: LocalNotificationStore.legacyOrdinaryPermissionPromptKey,
      );
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerPostRegistrationNotificationPermissionPrompt,
      );
      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();

      expect(find.text('予定通知を有効にしますか？'), findsOneWidget);
      await tester.tap(find.text('後で'));
      await tester.pumpAndSettle();
      expect(recorder.permissionRequests, 0);
      expect(
        await store.permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
        ),
        isTrue,
      );
    }),
  );

  testWidgets(
    'post-registration OS request follows the explanation and explicit Allow action',
    (tester) => _withAndroidPlatform(() async {
      final recorder = _PermissionRequestRecorder();
      await _insertCourse(database, 'owner-a');
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerPostRegistrationNotificationPermissionPrompt,
      );

      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      expect(recorder.permissionRequests, 0);
      await tester.tap(find.text('通知を許可'));
      await tester.pumpAndSettle();

      expect(recorder.permissionRequests, 1);
      expect(
        await LocalNotificationStore(database).permissionPromptSeen(
          'owner-a',
          promptKey: LocalNotificationStore.postRegistrationPermissionPromptKey,
        ),
        isTrue,
      );
    }),
  );

  testWidgets(
      'permission prompt markers stay scoped to the active owner',
      (
        tester,
      ) =>
          _withAndroidPlatform(() async {
            final recorder = _PermissionRequestRecorder();
            await _insertCourse(database, 'owner-b');
            await LocalNotificationStore(database).markPermissionPromptSeen(
              'owner-a',
              promptKey:
                  LocalNotificationStore.postRegistrationPermissionPromptKey,
            );
            await _pumpPrompt(
              tester,
              database: database,
              recorder: recorder,
              ownerUserId: 'owner-b',
              action: offerPostRegistrationNotificationPermissionPrompt,
            );

            await tester.tap(find.text('表示する説明'));
            await tester.pumpAndSettle();
            expect(find.text('予定通知を有効にしますか？'), findsOneWidget);
            await tester.tap(find.text('後で'));
            await tester.pumpAndSettle();
            expect(recorder.permissionRequests, 0);
            expect(
              await LocalNotificationStore(database).permissionPromptSeen(
                'owner-b',
                promptKey:
                    LocalNotificationStore.postRegistrationPermissionPromptKey,
              ),
              isTrue,
            );
          }));

  testWidgets(
      'task/event registration before a course does not prompt',
      (
        tester,
      ) =>
          _withAndroidPlatform(() async {
            final recorder = _PermissionRequestRecorder();
            await _pumpPrompt(
              tester,
              database: database,
              recorder: recorder,
              action: offerPostRegistrationNotificationPermissionPrompt,
            );

            await tester.tap(find.text('表示する説明'));
            await tester.pumpAndSettle();
            expect(find.text('予定通知を有効にしますか？'), findsNothing);
            expect(recorder.permissionRequests, 0);
            expect(
              await LocalNotificationStore(database).permissionPromptSeen(
                'owner-a',
                promptKey:
                    LocalNotificationStore.postRegistrationPermissionPromptKey,
              ),
              isFalse,
            );
          }));

  testWidgets(
    'OS request failure is visible and does not repeat automatically',
    (tester) => _withAndroidPlatform(() async {
      final recorder = _PermissionRequestRecorder()
        ..failPermissionRequest = true;
      await _insertCourse(database, 'owner-a');
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerPostRegistrationNotificationPermissionPrompt,
      );
      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通知を許可'));
      await tester.pumpAndSettle();

      expect(recorder.permissionRequests, 1);
      expect(
        find.text('通知を有効にできませんでした。設定画面から再試行できます。'),
        findsOneWidget,
      );
      await _pumpPrompt(
        tester,
        database: database,
        recorder: recorder,
        action: offerPostRegistrationNotificationPermissionPrompt,
      );
      await tester.tap(find.text('表示する説明'));
      await tester.pumpAndSettle();
      expect(find.text('予定通知を有効にしますか？'), findsNothing);
      expect(recorder.permissionRequests, 1);
    }),
  );
}

Future<void> _withAndroidPlatform(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _pumpPrompt(
  WidgetTester tester, {
  required AppDatabase database,
  required _PermissionRequestRecorder recorder,
  required Future<void> Function(BuildContext, WidgetRef) action,
  String ownerUserId = 'owner-a',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        activeScheduleContextProvider.overrideWithValue(
          ActiveScheduleContext(
            ownerUserId: ownerUserId,
            universityId: 'university-a',
            termId: 'term-a',
            academicYear: 2026,
            primaryCalendarId: 'calendar-a',
          ),
        ),
        morningAlarmControllerProvider.overrideWith(
          () => _RecordingMorningAlarmController(recorder),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => action(context, ref),
              child: const Text('表示する説明'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PermissionRequestRecorder {
  var permissionRequests = 0;
  var failPermissionRequest = false;
}

class _RecordingMorningAlarmController extends MorningAlarmController {
  _RecordingMorningAlarmController(this.recorder);

  final _PermissionRequestRecorder recorder;

  @override
  Future<MorningAlarmPlatformState> build() async => MorningAlarmPlatformState(
        ownerUserId: 'owner-a',
        settings: MorningAlarmSettings(ownerUserId: 'owner-a'),
        capabilities: const MorningAlarmCapabilities.unavailable(),
        nextOccurrence: null,
      );

  @override
  Future<void> requestNotificationPermission() async {
    recorder.permissionRequests += 1;
    if (recorder.failPermissionRequest) {
      throw StateError('synthetic permission request failure');
    }
  }
}

Future<void> _insertCourse(AppDatabase database, String ownerUserId) async {
  await database.into(database.userCourses).insert(
        UserCoursesCompanion.insert(
          id: 'course-$ownerUserId',
          ownerUserId: ownerUserId,
          termId: 'term-a',
          title: '登録済み授業',
          normalizedTitle: '登録済み授業',
        ),
      );
}
