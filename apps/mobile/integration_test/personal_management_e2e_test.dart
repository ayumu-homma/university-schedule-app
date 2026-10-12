import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support/popup_route_dismissal.dart';

import 'package:drift/drift.dart' hide View, isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_domain/email_import_trusted.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/app.dart';
import 'package:university_schedule_mobile/app/navigation_guard.dart';
import 'package:university_schedule_mobile/core/auth/secure_auth_storage.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/core/native/sqlite_identity_handshake.dart';
import 'package:university_schedule_mobile/core/storage/storage_database.dart';
import 'package:university_schedule_mobile/core/storage/storage_preparation.dart';
import 'package:university_schedule_mobile/app/router.dart';
import 'package:university_schedule_mobile/core/sync/remote_schedule_gateway.dart';
import 'package:university_schedule_mobile/core/sync/schedule_sync_deadline_http_client.dart';
import 'package:university_schedule_mobile/core/sync/sync_coordinator.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_action_controller.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_reconciliation_runtime.dart';
import 'package:university_schedule_mobile/features/email_import/application/email_review_providers.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_connector_binding.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_failure.dart';
import 'package:university_schedule_mobile/features/email_import/data/email_import_sync_service.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_reconciliation.dart';
import 'package:university_schedule_mobile/features/email_import/domain/email_review_models.dart';
import 'package:university_schedule_mobile/features/email_import/presentation/email_review_labels.dart';
import 'package:university_schedule_mobile/features/onboarding/application/onboarding_providers.dart';
import 'package:university_schedule_mobile/features/term_period/application/term_period_providers.dart';
import 'package:university_schedule_mobile/features/timetable/application/schedule_sync_runtime.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart'
    hide WidgetSnapshot;
import 'package:university_schedule_mobile/local_db/app_database_provider.dart'
    show appDatabasePathProvider;
import 'package:university_schedule_mobile/local_db/email_import_identity.dart';

import 'support/dropdown_test_driver.dart';
import 'support/date_time_picker_driver.dart';
import 'support/mvp_action_tap_bounds.dart';

enum _AndroidE2ePhase {
  bootstrap,
  bootstrapExams,
  personalManagement,
  emailOnline,
  emailRestart,
  routineOffline,
  restart,
  convergence;

  String get runnerToken => switch (this) {
        _AndroidE2ePhase.bootstrap => 'bootstrap',
        _AndroidE2ePhase.bootstrapExams => 'bootstrap-exams',
        _AndroidE2ePhase.personalManagement => 'personal-management',
        _AndroidE2ePhase.emailOnline => 'email-online',
        _AndroidE2ePhase.emailRestart => 'email-restart',
        _AndroidE2ePhase.routineOffline => 'routine-offline',
        _AndroidE2ePhase.restart => 'restart',
        _AndroidE2ePhase.convergence => 'convergence',
      };
}

enum _EmailOnlineSlice {
  inbox,
  review,
  assignmentConfirmation,
  timezoneAndOffline,
}

enum _BootstrapExamSlice { restore, create, project }

class _BootstrapExamHandoff {
  const _BootstrapExamHandoff({
    required this.ownerUserId,
    required this.manualCourseId,
    this.courseLinkedExamId,
    this.standaloneExamId,
  });

  final String ownerUserId;
  final String manualCourseId;
  final String? courseLinkedExamId;
  final String? standaloneExamId;

  _BootstrapExamHandoff withExamIds({
    required String courseLinkedId,
    required String standaloneId,
  }) {
    return _BootstrapExamHandoff(
      ownerUserId: ownerUserId,
      manualCourseId: manualCourseId,
      courseLinkedExamId: courseLinkedId,
      standaloneExamId: standaloneId,
    );
  }
}

class _EmailOnlineCandidateHandoff {
  const _EmailOnlineCandidateHandoff({
    required this.ownerUserId,
    required this.assignmentCandidateId,
    required this.examCandidateId,
    required this.dismissedEventCandidateId,
    required this.timezoneEventCandidateId,
    this.correctedCourseId,
  });

  final String ownerUserId;
  final String assignmentCandidateId;
  final String examCandidateId;
  final String dismissedEventCandidateId;
  final String timezoneEventCandidateId;
  final String? correctedCourseId;

  _EmailOnlineCandidateHandoff withCorrectedCourseId(String courseId) {
    return _EmailOnlineCandidateHandoff(
      ownerUserId: ownerUserId,
      assignmentCandidateId: assignmentCandidateId,
      examCandidateId: examCandidateId,
      dismissedEventCandidateId: dismissedEventCandidateId,
      timezoneEventCandidateId: timezoneEventCandidateId,
      correctedCourseId: courseId,
    );
  }
}

const _offlineReadyMarker = 'ANDROID_E2E_OFFLINE_READY';
const _offlineNetworkDisabledMarker = 'ANDROID_E2E_OFFLINE_NETWORK_DISABLED';
const _offlineEventUpdatedMarker = 'ANDROID_E2E_OFFLINE_EVENT_UPDATED';
const _offlineQueueDurableMarker = 'ANDROID_E2E_OFFLINE_QUEUE_DURABLE';
const _offlineSettingsRenderedMarker = 'ANDROID_E2E_OFFLINE_SETTINGS_RENDERED';
const _offlineMutationQueuedMarker = 'ANDROID_E2E_OFFLINE_MUTATION_QUEUED';
const _routineOfflineReadyMarker = 'ANDROID_E2E_ROUTINE_OFFLINE_READY';
const _routineOfflineFirstMutationQueuedMarker =
    'ANDROID_E2E_ROUTINE_OFFLINE_FIRST_MUTATION_QUEUED';
const _routineOfflineMutationQueuedMarker =
    'ANDROID_E2E_ROUTINE_OFFLINE_MUTATION_QUEUED';
const _routineRestartQueueVerifiedMarker =
    'ANDROID_E2E_ROUTINE_RESTART_QUEUE_VERIFIED';
const _emailOfflineReadyMarker = 'ANDROID_E2E_EMAIL_OFFLINE_READY';
const _emailOfflineQueuedMarker = 'ANDROID_E2E_EMAIL_OFFLINE_QUEUED';
const _emailConnectionVerifiedMarker = 'ANDROID_E2E_EMAIL_CONNECTION_VERIFIED';
const _emailInboxVerifiedMarker = 'ANDROID_E2E_EMAIL_INBOX_VERIFIED';
const _emailReviewVerifiedMarker = 'ANDROID_E2E_EMAIL_REVIEW_VERIFIED';
const _emailOnlineConfirmationVerifiedMarker =
    'ANDROID_E2E_EMAIL_ONLINE_CONFIRMATION_VERIFIED';
const _emailRestartVerifiedMarker = 'ANDROID_E2E_EMAIL_RESTART_VERIFIED';
const _emailConvergedMarker = 'ANDROID_E2E_EMAIL_CONVERGED';
const _emailUpdateVerifiedMarker = 'ANDROID_E2E_EMAIL_UPDATE_VERIFIED';
const _emailAccountIsolatedMarker = 'ANDROID_E2E_EMAIL_ACCOUNT_ISOLATED';
const _emailCleanupVerifiedMarker = 'ANDROID_E2E_EMAIL_CLEANUP_VERIFIED';
const _androidE2ePlatform = MethodChannel(
  'jp.universityschedule.app/android_e2e',
);
const _widgetBridgePlatform = MethodChannel(
  'jp.universityschedule.app/widget_bridge',
);
const _bootstrapOnboardingCompleteMarker =
    'ANDROID_E2E_BOOTSTRAP_ONBOARDING_COMPLETE';
const _bootstrapTemplateCopiedMarker = 'ANDROID_E2E_BOOTSTRAP_TEMPLATE_COPIED';
const _bootstrapManualCourseCreatedMarker =
    'ANDROID_E2E_BOOTSTRAP_MANUAL_COURSE_CREATED';
const _bootstrapCourseLinkedExamCreatedMarker =
    'ANDROID_E2E_BOOTSTRAP_COURSE_LINKED_EXAM_CREATED';
const _bootstrapStandaloneExamCreatedMarker =
    'ANDROID_E2E_BOOTSTRAP_STANDALONE_EXAM_CREATED';
const _bootstrapExamsProjectedMarker = 'ANDROID_E2E_BOOTSTRAP_EXAMS_PROJECTED';
const _bootstrapAssignmentCreatedMarker =
    'ANDROID_E2E_BOOTSTRAP_ASSIGNMENT_CREATED';
const _bootstrapAssignmentFilteredMarker =
    'ANDROID_E2E_BOOTSTRAP_ASSIGNMENT_FILTERED';
const _bootstrapAssignmentLifecycleMarker =
    'ANDROID_E2E_BOOTSTRAP_ASSIGNMENT_LIFECYCLE';
const _bootstrapInitialSyncVerifiedMarker =
    'ANDROID_E2E_BOOTSTRAP_INITIAL_SYNC_VERIFIED';
const _bootstrapCourseTombstoneVerifiedMarker =
    'ANDROID_E2E_BOOTSTRAP_COURSE_TOMBSTONE_VERIFIED';
const _orphanedCourseLinkNotice =
    '元の授業は削除されています。授業を「なし」または別の授業に変更してから保存してください。';
const _orphanedCourseLinkSentinel = '削除済みの授業（選び直してください）';
const _unsupportedCampusId = '72264f8f-a659-524a-94ea-506634a5bdd7';
const _unsupportedCampusName = '虎ノ門';
const _unsupportedCampusTermName = 'Android E2E 手入力学期';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final environment = _AndroidE2eEnvironment.fromCompileTime();
  if (environment.phase == _AndroidE2ePhase.convergence) {
    _registerConvergenceTests(environment);
    return;
  }
  if (environment.phase == _AndroidE2ePhase.bootstrap) {
    _registerBootstrapTests(environment);
    return;
  }
  if (environment.phase == _AndroidE2ePhase.bootstrapExams) {
    _registerBootstrapExamTests(environment);
    return;
  }
  if (environment.phase == _AndroidE2ePhase.personalManagement) {
    _registerPersonalManagementTests(environment);
    return;
  }
  if (environment.phase == _AndroidE2ePhase.emailOnline) {
    _registerEmailOnlineTests(environment);
    return;
  }

  testWidgets(
    'production composition persists personal schedule management through local Supabase',
    (tester) async {
      final config = AppConfig.validated(
        environment: 'test',
        demoMode: false,
        supabaseUrl: environment.supabaseUrl.toString(),
        supabasePublishableKey: environment.publishableKey,
        deepLinkScheme: environment.deepLinkScheme,
      );
      final appTransport = ScheduleSyncDeadlineHttpClient(
        // ADB reverse is removed during the runner-controlled outage. Avoid a
        // pooled loopback socket bypassing that boundary; the production
        // transport default remains persistent outside this acceptance path.
        allowPersistentConnections: !environment.usesAdbReverseTransport,
      );
      final initializedSupabase = await _initializeSupabaseForAndroidE2e(
        config: config,
        httpClient: appTransport,
      );
      final appClient = initializedSupabase.client;
      final sessionStorage = initializedSupabase.sessionStorage;
      switch (environment.phase) {
        case _AndroidE2ePhase.bootstrap:
          throw StateError(
            'The bootstrap phase must use its separately bounded tests.',
          );
        case _AndroidE2ePhase.bootstrapExams:
          throw StateError(
            'The bootstrap exam phase must use its separately bounded tests.',
          );
        case _AndroidE2ePhase.personalManagement:
          throw StateError(
            'The personal-management phase must use its separately bounded tests.',
          );
        case _AndroidE2ePhase.emailOnline:
          throw StateError(
            'The online email-import phase must use its separately bounded tests.',
          );
        case _AndroidE2ePhase.emailRestart:
          await _runEmailRestartPhase(
            tester,
            environment: environment,
            config: config,
            appClient: appClient,
            sessionStorage: sessionStorage,
            appTransport: appTransport,
          );
        case _AndroidE2ePhase.routineOffline:
          await _runRoutineOfflinePhase(
            tester,
            environment: environment,
            config: config,
            appClient: appClient,
            sessionStorage: sessionStorage,
          );
        case _AndroidE2ePhase.restart:
          await _runRestartOfflinePhase(
            tester,
            environment: environment,
            config: config,
            appClient: appClient,
            sessionStorage: sessionStorage,
          );
        case _AndroidE2ePhase.convergence:
          throw StateError(
            'The convergence phase must use its separately bounded tests.',
          );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _registerBootstrapTests(_AndroidE2eEnvironment environment) {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: environment.supabaseUrl.toString(),
    supabasePublishableKey: environment.publishableKey,
    deepLinkScheme: environment.deepLinkScheme,
  );
  final appTransport = ScheduleSyncDeadlineHttpClient(
    allowPersistentConnections: !environment.usesAdbReverseTransport,
  );
  late SupabaseClient appClient;
  late SecureAuthLocalStorage sessionStorage;
  var onboardingCompleted = false;

  setUpAll(() async {
    final initializedSupabase = await _initializeSupabaseForAndroidE2e(
      config: config,
      httpClient: appTransport,
    );
    appClient = initializedSupabase.client;
    sessionStorage = initializedSupabase.sessionStorage;
    // The runner clears app data only before bootstrap. Avoid inheriting an
    // interrupted local session when this phase is invoked manually.
    await appClient.auth.signOut(scope: SignOutScope.local);
  });

  tearDownAll(appTransport.close);

  group('production bootstrap through local Supabase', () {
    testWidgets(
      'authenticates and completes production onboarding',
      (tester) async {
        await _runBootstrapOnboardingPhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
        );
        onboardingCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'copies a catalog course and creates a manual course',
      (tester) async {
        expect(
          onboardingCompleted,
          isTrue,
          reason:
              'Course bootstrap requires the authenticated onboarding slice to complete first.',
        );
        await _runBootstrapCoursePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

void _registerBootstrapExamTests(_AndroidE2eEnvironment environment) {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: environment.supabaseUrl.toString(),
    supabasePublishableKey: environment.publishableKey,
    deepLinkScheme: environment.deepLinkScheme,
  );
  final appTransport = ScheduleSyncDeadlineHttpClient(
    allowPersistentConnections: !environment.usesAdbReverseTransport,
  );
  late SupabaseClient appClient;
  late SecureAuthLocalStorage sessionStorage;
  _BootstrapExamHandoff? examHandoff;
  var restoreCompleted = false;
  var creationCompleted = false;

  setUpAll(() async {
    final initializedSupabase = await _initializeSupabaseForAndroidE2e(
      config: config,
      httpClient: appTransport,
    );
    appClient = initializedSupabase.client;
    sessionStorage = initializedSupabase.sessionStorage;
  });

  tearDownAll(appTransport.close);

  group('production exam bootstrap through local Supabase', () {
    testWidgets(
      'restores the authenticated manual-course boundary',
      (tester) async {
        examHandoff = await _runBootstrapExamsOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _BootstrapExamSlice.restore,
        );
        restoreCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'creates linked and standalone exams through the production UI',
      (tester) async {
        expect(
          restoreCompleted,
          isTrue,
          reason: 'Exam creation requires the restored course boundary first.',
        );
        final handoff = examHandoff;
        expect(handoff, isNotNull);
        examHandoff = await _runBootstrapExamsOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _BootstrapExamSlice.create,
          handoff: handoff!,
        );
        creationCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'projects both exams through detail and calendar UI',
      (tester) async {
        expect(
          creationCompleted,
          isTrue,
          reason: 'Exam projection requires durable exam creation first.',
        );
        final handoff = examHandoff;
        expect(handoff, isNotNull);
        await _runBootstrapExamsOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _BootstrapExamSlice.project,
          handoff: handoff!,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

void _registerPersonalManagementTests(_AndroidE2eEnvironment environment) {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: environment.supabaseUrl.toString(),
    supabasePublishableKey: environment.publishableKey,
    deepLinkScheme: environment.deepLinkScheme,
  );
  final appTransport = ScheduleSyncDeadlineHttpClient(
    allowPersistentConnections: !environment.usesAdbReverseTransport,
  );
  late SupabaseClient appClient;
  late SecureAuthLocalStorage sessionStorage;
  var authenticatedRestoreCompleted = false;
  String? restoredOwnerUserId;
  var courseRestoreCompleted = false;
  String? restoredManualCourseId;
  var assignmentCreationCompleted = false;
  String? restoredAssignmentId;
  var assignmentLifecycleCompleted = false;

  setUpAll(() async {
    final initializedSupabase = await _initializeSupabaseForAndroidE2e(
      config: config,
      httpClient: appTransport,
    );
    appClient = initializedSupabase.client;
    sessionStorage = initializedSupabase.sessionStorage;
  });

  tearDownAll(appTransport.close);

  group('production personal management through local Supabase', () {
    testWidgets(
      'restores the authenticated production app boundary',
      (tester) async {
        restoredOwnerUserId =
            await _runPersonalManagementAuthenticationRestorePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
        );
        authenticatedRestoreCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'restores the manual course and native widget snapshot',
      (tester) async {
        expect(
          authenticatedRestoreCompleted,
          isTrue,
          reason:
              'The course restore slice requires the authenticated restore slice to complete first.',
        );
        final ownerUserId = restoredOwnerUserId;
        expect(ownerUserId, isNotNull);
        restoredManualCourseId = await _runPersonalManagementCourseRestorePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          expectedOwnerUserId: ownerUserId!,
        );
        courseRestoreCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'creates and filters a linked assignment through the production UI',
      (tester) async {
        expect(
          courseRestoreCompleted,
          isTrue,
          reason:
              'Assignment creation requires the restored course/widget slice to complete first.',
        );
        final manualCourseId = restoredManualCourseId;
        final ownerUserId = restoredOwnerUserId;
        expect(manualCourseId, isNotNull);
        expect(ownerUserId, isNotNull);
        restoredAssignmentId =
            await _runPersonalManagementAssignmentCreationPhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          expectedOwnerUserId: ownerUserId!,
          expectedManualCourseId: manualCourseId!,
        );
        assignmentCreationCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'submits the linked assignment through the production UI',
      (tester) async {
        expect(
          assignmentCreationCompleted,
          isTrue,
          reason:
              'The assignment lifecycle slice requires assignment creation to complete first.',
        );
        final manualCourseId = restoredManualCourseId;
        final assignmentId = restoredAssignmentId;
        final ownerUserId = restoredOwnerUserId;
        expect(manualCourseId, isNotNull);
        expect(assignmentId, isNotNull);
        expect(ownerUserId, isNotNull);
        await _runPersonalManagementAssignmentLifecyclePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          expectedOwnerUserId: ownerUserId!,
          expectedManualCourseId: manualCourseId!,
          expectedAssignmentId: assignmentId!,
        );
        assignmentLifecycleCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'syncs an edited course and event before tombstoning the course',
      (tester) async {
        expect(
          assignmentLifecycleCompleted,
          isTrue,
          reason:
              'The sync/tombstone slice requires the assignment lifecycle slice to complete first.',
        );
        final ownerUserId = restoredOwnerUserId;
        final manualCourseId = restoredManualCourseId;
        final assignmentId = restoredAssignmentId;
        expect(ownerUserId, isNotNull);
        expect(manualCourseId, isNotNull);
        expect(assignmentId, isNotNull);
        await _runPersonalManagementSyncPhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          expectedOwnerUserId: ownerUserId!,
          expectedManualCourseId: manualCourseId!,
          expectedAssignmentId: assignmentId!,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

void _registerEmailOnlineTests(_AndroidE2eEnvironment environment) {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: environment.supabaseUrl.toString(),
    supabasePublishableKey: environment.publishableKey,
    deepLinkScheme: environment.deepLinkScheme,
  );
  final appTransport = ScheduleSyncDeadlineHttpClient(
    // ADB reverse is removed after the final online slice. Avoid a pooled
    // loopback socket bypassing that runner-controlled outage boundary.
    allowPersistentConnections: !environment.usesAdbReverseTransport,
  );
  late SupabaseClient appClient;
  late SecureAuthLocalStorage sessionStorage;
  _EmailOnlineCandidateHandoff? candidateHandoff;
  var inboxCompleted = false;
  var reviewCompleted = false;
  var onlineConfirmationCompleted = false;

  setUpAll(() async {
    final initializedSupabase = await _initializeSupabaseForAndroidE2e(
      config: config,
      httpClient: appTransport,
    );
    appClient = initializedSupabase.client;
    sessionStorage = initializedSupabase.sessionStorage;
  });

  tearDownAll(appTransport.close);

  group('production email import through local Supabase', () {
    testWidgets(
      'connects, imports, and safely retries the private inbox',
      (tester) async {
        candidateHandoff = await _runEmailOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _EmailOnlineSlice.inbox,
        );
        inboxCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'edits an assignment candidate and dismisses an event candidate',
      (tester) async {
        expect(
          inboxCompleted,
          isTrue,
          reason: 'Email review requires the verified inbox slice first.',
        );
        final handoff = candidateHandoff;
        expect(handoff, isNotNull);
        candidateHandoff = await _runEmailOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _EmailOnlineSlice.review,
          handoff: handoff!,
        );
        reviewCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'confirms the corrected assignment while online',
      (tester) async {
        expect(
          reviewCompleted,
          isTrue,
          reason:
              'Online email confirmation requires the persisted review slice first.',
        );
        final handoff = candidateHandoff;
        expect(handoff, isNotNull);
        expect(handoff!.correctedCourseId, isNotNull);
        candidateHandoff = await _runEmailOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _EmailOnlineSlice.assignmentConfirmation,
          handoff: handoff,
        );
        onlineConfirmationCompleted = true;
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'confirms timezone and offline exam candidates durably',
      (tester) async {
        expect(
          onlineConfirmationCompleted,
          isTrue,
          reason:
              'The outage slice requires the online confirmation slice first.',
        );
        final handoff = candidateHandoff;
        expect(handoff, isNotNull);
        await _runEmailOnlinePhase(
          tester,
          environment: environment,
          config: config,
          appClient: appClient,
          sessionStorage: sessionStorage,
          appTransport: appTransport,
          slice: _EmailOnlineSlice.timezoneAndOffline,
          handoff: handoff!,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

void _registerConvergenceTests(_AndroidE2eEnvironment environment) {
  final config = AppConfig.validated(
    environment: 'test',
    demoMode: false,
    supabaseUrl: environment.supabaseUrl.toString(),
    supabasePublishableKey: environment.publishableKey,
    deepLinkScheme: environment.deepLinkScheme,
  );
  final appTransport = ScheduleSyncDeadlineHttpClient(
    // ADB reverse is removed during the runner-controlled outage. Avoid a
    // pooled loopback socket bypassing that boundary; the production
    // transport default remains persistent outside this acceptance path.
    allowPersistentConnections: !environment.usesAdbReverseTransport,
  );
  late SupabaseClient appClient;
  late SecureAuthLocalStorage sessionStorage;

  setUpAll(() async {
    final initializedSupabase = await _initializeSupabaseForAndroidE2e(
      config: config,
      httpClient: appTransport,
    );
    appClient = initializedSupabase.client;
    sessionStorage = initializedSupabase.sessionStorage;
  });

  tearDownAll(appTransport.close);

  group('production convergence through local Supabase', () {
    testWidgets(
      'syncs the queued event, tombstone, and magic-link reauthentication',
      (tester) => _runEventConvergencePhase(
        tester,
        environment: environment,
        config: config,
        appClient: appClient,
        sessionStorage: sessionStorage,
        appTransport: appTransport,
      ),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'syncs assignment and exam edit-delete lifecycles',
      (tester) => _runAssignmentExamConvergencePhase(
        tester,
        environment: environment,
        config: config,
        appClient: appClient,
        sessionStorage: sessionStorage,
        appTransport: appTransport,
      ),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'persists the university request and custom term-period settings',
      (tester) => _runUniversityTermConvergencePhase(
        tester,
        environment: environment,
        config: config,
        appClient: appClient,
        sessionStorage: sessionStorage,
        appTransport: appTransport,
      ),
      timeout: const Timeout(Duration(minutes: 3)),
    );

    testWidgets(
      'isolates the completed first-user state from the second user',
      (tester) => _runSecondUserConvergencePhase(
        tester,
        environment: environment,
        config: config,
        appClient: appClient,
        sessionStorage: sessionStorage,
        appTransport: appTransport,
      ),
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}

Future<void> _runBootstrapOnboardingPhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  // Keep the harmless Auth health probe on the same public transport that
  // performs the single real sign-up. A fresh Android socket can otherwise
  // abort between a successful raw HttpClient health check and its first POST.
  final provisioningTransport = ScheduleSyncDeadlineHttpClient();
  final provisioningClient = _newPublicClient(
    environment,
    httpClient: provisioningTransport,
  );
  final inbox = _LocalMailpitInbox(environment.mailpitUrl);
  _RunningApp? runningApp;

  try {
    // The runner has restored the emulator network, but TCP acceptance alone
    // does not prove that Android can complete an Auth HTTP exchange yet.
    // Verify the exact local Auth route before the first real sign-up request.
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      requiredConsecutiveSuccesses: 2,
      probeClient: provisioningTransport,
      label: 'the online bootstrap Auth route',
    );
    await _provisionSyntheticUser(
      provisioningClient,
      email: environment.firstEmail,
      password: environment.password,
    );
    await _provisionSyntheticUser(
      provisioningClient,
      email: environment.secondEmail,
      password: environment.password,
    );

    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _waitFor(
      tester,
      find.byKey(const Key('sign-in-email')),
      label: 'the production sign-in screen',
    );

    await _signInWithMagicLink(
      tester,
      client: appClient,
      container: runningApp.container,
      inbox: inbox,
      email: environment.firstEmail,
    );
    final firstUserId = appClient.auth.currentUser?.id;
    expect(firstUserId, isNotNull);
    final ownerUserId = firstUserId!;
    await _requestUniversityDuringOnboarding(
      tester,
      container: runningApp.container,
      client: appClient,
      ownerUserId: ownerUserId,
      environment: environment,
      appTransport: appTransport,
    );
    await _completeSeededOnboarding(tester);
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'Home after onboarding',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
    await tester.pumpAndSettle();
    await _signalRunnerMarker(environment, _bootstrapOnboardingCompleteMarker);

    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext, isNotNull);
    final context = activeContext!;
    expect(context.ownerUserId, ownerUserId);
    await appClient.removeAllChannels();
    expect(appClient.getChannels(), isEmpty);
    await _synchronize(
      runningApp.container,
      clock: runningApp.clock,
    );
  } finally {
    await runningApp?.dispose(tester);
    inbox.close();
    await provisioningClient.dispose();
    provisioningTransport.close();
  }
}

Future<void> _runBootstrapCoursePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  final peerClient = _newPublicClient(environment);
  _RunningApp? runningApp;

  try {
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the bootstrap course boundary',
    );
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'bootstrap course creation',
    );
    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext, isNotNull);
    final context = activeContext!;
    expect(context.ownerUserId, ownerUserId);

    final templateFixture = await _findAuthenticatedTemplateFixture(
      appClient,
      environment: environment,
      context: context,
    );
    await _searchAndCopyCourseTemplate(
      tester,
      title: environment.templateTitle,
      instructor: environment.templateInstructor,
      duplicateTitle: environment.duplicateTemplateTitle,
      templateFixture: templateFixture,
    );
    // Observe the committed snapshot through an independent public client.
    // The running application owns startup/realtime sync on appClient, so this
    // avoids coupling the server assertion to an in-flight app transport.
    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    await _assertCopiedTemplateSnapshot(
      peerClient,
      templateFixture: templateFixture,
      ownerUserId: ownerUserId,
      environment: environment,
      context: context,
    );
    await _signalRunnerMarker(environment, _bootstrapTemplateCopiedMarker);

    await _createCourse(tester, title: environment.manualCourseTitle);
    await _waitFor(
      tester,
      find.text(environment.manualCourseTitle),
      label: 'the newly created manual course',
    );
    await _waitForGone(
      tester,
      find.byType(BottomSheet),
      label: 'Quick Add to dismiss its course sheet before navigation',
    );
    await _waitForGone(
      tester,
      find.text('授業を追加'),
      label: 'the Quick Add course action to close before navigation',
    );
    await _waitForNativeWidgetCourse(
      tester,
      title: environment.manualCourseTitle,
      room: 'E2E-101',
      weekday: DateTime.tuesday,
      periodNo: 2,
    );
    await _assertNativeWidgetRejectsInvalidSnapshots(
      ownerUserId: ownerUserId,
      region: StorageRegion.fromConfig(config),
    );
    await _signalRunnerMarker(
      environment,
      _bootstrapManualCourseCreatedMarker,
    );
  } finally {
    await runningApp?.dispose(tester);
    await peerClient.dispose();
  }
}

Future<_BootstrapExamHandoff> _runBootstrapExamsOnlinePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required _BootstrapExamSlice slice,
  _BootstrapExamHandoff? handoff,
}) async {
  _RunningApp? runningApp;

  try {
    final restoredSession = appClient.auth.currentSession;
    expect(
      restoredSession?.user.id,
      isNotNull,
      reason: 'The exam phase must retain the bootstrap auth session.',
    );
    final ownerUserId = restoredSession!.user.id;
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      requiredConsecutiveSuccesses: 2,
      probeClient: appTransport,
      label: 'the restored app transport before bootstrap exam verification',
    );
    final authenticatedProfile = await appClient
        .from('profiles')
        .select('user_id')
        .eq('user_id', ownerUserId)
        .maybeSingle();
    expect(authenticatedProfile, isNotNull);
    expect(
      Map<String, Object?>.from(authenticatedProfile! as Map)['user_id'],
      ownerUserId,
    );
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.isSignedIn ==
          true,
      label:
          'the restored authenticated session before bootstrap exam verification',
    );
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label: 'the restored onboarding state before bootstrap exam verification',
    );
    final onboarding = runningApp.container.read(onboardingControllerProvider);
    expect(
      onboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason: 'The exam phase requires a completed cached bootstrap.',
    );
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'the authenticated Home before bootstrap exam verification',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
    expect(appClient.auth.currentUser?.id, ownerUserId);
    expect(
      appClient.auth.currentUser?.email?.toLowerCase(),
      environment.firstEmail,
    );
    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext?.ownerUserId, ownerUserId);
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      probeClient: appTransport,
      label: 'the restored online bootstrap exam state',
    );

    if (slice != _BootstrapExamSlice.restore) {
      expect(handoff, isNotNull);
      expect(handoff!.ownerUserId, ownerUserId);
    }

    if (slice == _BootstrapExamSlice.restore) {
      // Prove the manual course survived the explicit process boundary before
      // using it as the production exam relationship.
      await _openTimetableWeekView(tester);
      await _waitFor(
        tester,
        find.text(environment.manualCourseTitle),
        label: 'the manual course restored before exam creation',
      );
      await _waitForCondition(
        tester,
        () {
          final state =
              runningApp!.container.read(demoAppControllerProvider).valueOrNull;
          return state?.courses
                  .where(
                    (course) => course.title == environment.manualCourseTitle,
                  )
                  .length ==
              1;
        },
        label: 'the manual course state before exam creation',
      );

      final restoredState =
          runningApp.container.read(demoAppControllerProvider).valueOrNull;
      expect(restoredState, isNotNull);
      final manualCourseId = restoredState!.courses
          .singleWhere(
            (course) => course.title == environment.manualCourseTitle,
          )
          .id;
      await _quiesceBootstrapExamApp(appClient, runningApp);
      return _BootstrapExamHandoff(
        ownerUserId: ownerUserId,
        manualCourseId: manualCourseId,
      );
    }

    if (slice == _BootstrapExamSlice.create) {
      await _waitForCondition(
        tester,
        () {
          final state =
              runningApp!.container.read(demoAppControllerProvider).valueOrNull;
          if (state == null) return false;
          return state.courses
                      .where(
                        (course) =>
                            course.title == environment.manualCourseTitle,
                      )
                      .length ==
                  1 &&
              state.exams.every((exam) =>
                  exam.title != environment.courseLinkedExamTitle &&
                  exam.title != environment.standaloneExamTitle);
        },
        label: 'the durable manual course before exam creation',
      );
      final stateBeforeCreation =
          runningApp.container.read(demoAppControllerProvider).valueOrNull;
      expect(stateBeforeCreation, isNotNull);
      final restoredManualCourse = stateBeforeCreation!.courses.singleWhere(
        (course) => course.title == environment.manualCourseTitle,
      );
      expect(restoredManualCourse.id, handoff!.manualCourseId);
      expect(
        stateBeforeCreation.exams.where((exam) =>
            exam.title == environment.courseLinkedExamTitle ||
            exam.title == environment.standaloneExamTitle),
        isEmpty,
      );

      await _createExam(
        tester,
        title: environment.courseLinkedExamTitle,
        courseTitle: environment.manualCourseTitle,
      );
      await _signalRunnerMarker(
        environment,
        _bootstrapCourseLinkedExamCreatedMarker,
      );
      await _createExam(
        tester,
        title: environment.standaloneExamTitle,
      );
      await _signalRunnerMarker(
        environment,
        _bootstrapStandaloneExamCreatedMarker,
      );
      await _waitForCondition(
        tester,
        () {
          final state =
              runningApp!.container.read(demoAppControllerProvider).valueOrNull;
          if (state == null) return false;
          return state.exams
                      .where((exam) =>
                          exam.title == environment.courseLinkedExamTitle)
                      .length ==
                  1 &&
              state.exams
                      .where((exam) =>
                          exam.title == environment.standaloneExamTitle)
                      .length ==
                  1;
        },
        label: 'both durable exams after production creation',
      );
      final createdState =
          runningApp.container.read(demoAppControllerProvider).valueOrNull;
      expect(createdState, isNotNull);
      final courseLinkedExam = createdState!.exams.singleWhere(
        (exam) => exam.title == environment.courseLinkedExamTitle,
      );
      final standaloneExam = createdState.exams.singleWhere(
        (exam) => exam.title == environment.standaloneExamTitle,
      );
      expect(courseLinkedExam.ownerUserId, ownerUserId);
      expect(courseLinkedExam.courseId, handoff.manualCourseId);
      expect(standaloneExam.ownerUserId, ownerUserId);
      expect(standaloneExam.courseId, isNull);
      await _quiesceBootstrapExamApp(appClient, runningApp);
      return handoff.withExamIds(
        courseLinkedId: courseLinkedExam.id,
        standaloneId: standaloneExam.id,
      );
    }

    if (slice == _BootstrapExamSlice.project) {
      await _waitForCondition(
        tester,
        () {
          final state =
              runningApp!.container.read(demoAppControllerProvider).valueOrNull;
          if (state == null) return false;
          return state.courses
                      .where(
                        (course) =>
                            course.title == environment.manualCourseTitle,
                      )
                      .length ==
                  1 &&
              state.exams
                      .where((exam) =>
                          exam.title == environment.courseLinkedExamTitle)
                      .length ==
                  1 &&
              state.exams
                      .where((exam) =>
                          exam.title == environment.standaloneExamTitle)
                      .length ==
                  1;
        },
        label: 'the restored course and exams before projection checks',
      );
      final restoredState =
          runningApp.container.read(demoAppControllerProvider).valueOrNull;
      expect(restoredState, isNotNull);
      final restoredCourse = restoredState!.courses.singleWhere(
        (course) => course.title == environment.manualCourseTitle,
      );
      final courseLinkedExam = restoredState.exams.singleWhere(
        (exam) => exam.title == environment.courseLinkedExamTitle,
      );
      final standaloneExam = restoredState.exams.singleWhere(
        (exam) => exam.title == environment.standaloneExamTitle,
      );
      expect(restoredCourse.ownerUserId, ownerUserId);
      expect(restoredCourse.id, handoff!.manualCourseId);
      expect(courseLinkedExam.ownerUserId, ownerUserId);
      expect(courseLinkedExam.id, handoff.courseLinkedExamId);
      expect(courseLinkedExam.courseId, restoredCourse.id);
      expect(standaloneExam.ownerUserId, ownerUserId);
      expect(standaloneExam.id, handoff.standaloneExamId);
      expect(standaloneExam.courseId, isNull);
      await _openNavigationDestination(tester, '課題・テスト');
      await _tap(tester, find.byTooltip('テスト一覧'));
      await _waitFor(
        tester,
        _appBarTitle('テスト'),
        label: 'the restored production exam list',
      );
      await _waitFor(
        tester,
        find.text(environment.courseLinkedExamTitle),
        label: 'the course-linked exam in the production exam list',
      );
      await _waitFor(
        tester,
        find.text(environment.standaloneExamTitle),
        label: 'the no-course exam in the production exam list',
      );
      await _waitForCondition(
        tester,
        () {
          final state =
              runningApp!.container.read(demoAppControllerProvider).valueOrNull;
          if (state == null) return false;
          final courseLinkedProjection = state.calendarItems.where(
            (item) =>
                item.kind == EventKind.exam &&
                item.sourceId == courseLinkedExam.id,
          );
          final standaloneProjection = state.calendarItems.where(
            (item) =>
                item.kind == EventKind.exam &&
                item.sourceId == standaloneExam.id,
          );
          return courseLinkedProjection.length == 1 &&
              standaloneProjection.length == 1;
        },
        label: 'the exact restored exam calendar projections',
      );
      await _assertCourseLinkedExamInCourseDetail(
        tester,
        courseTitle: environment.manualCourseTitle,
        linkedExamTitle: environment.courseLinkedExamTitle,
        standaloneExamTitle: environment.standaloneExamTitle,
      );
      await _openNavigationDestination(tester, 'カレンダー');
      await _ensureCalendarFilterSelected(tester, 'テスト');
      await _waitFor(
        tester,
        find.text(environment.courseLinkedExamTitle),
        label: 'the course-linked exam calendar projection',
      );
      await _waitFor(
        tester,
        find.text(environment.standaloneExamTitle),
        label: 'the no-course exam calendar projection',
      );
      await _signalRunnerMarker(environment, _bootstrapExamsProjectedMarker);
      await _quiesceBootstrapExamApp(appClient, runningApp);
      return handoff;
    }
    throw StateError('Unsupported bootstrap exam slice: $slice');
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<void> _quiesceBootstrapExamApp(
  SupabaseClient appClient,
  _RunningApp runningApp,
) async {
  await appClient.removeAllChannels();
  expect(appClient.getChannels(), isEmpty);
  await _synchronize(
    runningApp.container,
    clock: runningApp.clock,
  );
}

Future<String> _runPersonalManagementAuthenticationRestorePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  _RunningApp? runningApp;
  late String ownerUserId;

  Future<void> progress(String stage) =>
      _signalRunnerMarker(environment, 'ANDROID_E2E_PM_AUTH_$stage');

  try {
    final restoredSession = appClient.auth.currentSession;
    expect(
      restoredSession?.user.id,
      isNotNull,
      reason:
          'The personal-management phase must retain the bootstrap auth session.',
    );
    ownerUserId = restoredSession!.user.id;
    await progress('SESSION_READY');
    // ScheduleSyncRuntime starts recovery during the first app pump. Warm the
    // exact Android transport first, then prove the restored session can read
    // only its own profile before that startup work dispatches mutations.
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      requiredConsecutiveSuccesses: 2,
      probeClient: appTransport,
      label: 'the restored app transport before personal-management startup',
    );
    await progress('REACHABILITY_READY');
    final authenticatedProfile = await appClient
        .from('profiles')
        .select('user_id')
        .eq('user_id', ownerUserId)
        .maybeSingle();
    expect(authenticatedProfile, isNotNull);
    expect(
      Map<String, Object?>.from(authenticatedProfile! as Map)['user_id'],
      ownerUserId,
    );
    await progress('PROFILE_READY');
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
      onStage: progress,
    );
    await progress('APP_STARTED');
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.isSignedIn ==
          true,
      label:
          'the restored authenticated session before personal-management edits',
    );
    await progress('STATE_READY');
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label: 'the restored onboarding state before personal-management edits',
    );
    final onboarding = runningApp.container.read(onboardingControllerProvider);
    expect(
      onboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason:
          'The personal-management phase requires a completed locally cached bootstrap.',
    );
    await progress('ONBOARDING_READY');
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'the authenticated Home before personal-management edits',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
    expect(appClient.auth.currentUser?.id, ownerUserId);
    expect(appClient.auth.currentUser?.email?.toLowerCase(),
        environment.firstEmail);
    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext?.ownerUserId, ownerUserId);
    await progress('HOME_READY');
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      probeClient: appTransport,
      label: 'the restored online personal-management state',
    );
    await progress('ONLINE_READY');
    await appClient.removeAllChannels();
    expect(appClient.getChannels(), isEmpty);
    await progress('CHANNELS_CLEARED');
    await _synchronize(
      runningApp.container,
      clock: runningApp.clock,
    );
    await progress('SYNC_COMPLETE');
  } finally {
    await runningApp?.dispose(tester, onStage: progress);
  }
  await progress('RESTORE_COMPLETE');
  return ownerUserId;
}

Future<String> _runPersonalManagementCourseRestorePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required String expectedOwnerUserId,
}) async {
  _RunningApp? runningApp;
  late String manualCourseId;

  try {
    final restored = await _startRestoredPersonalManagementApp(
      tester,
      environment: environment,
      config: config,
      appClient: appClient,
      sessionStorage: sessionStorage,
      appTransport: appTransport,
      label: 'the personal-management course restore boundary',
    );
    runningApp = restored.runningApp;
    expect(restored.ownerUserId, expectedOwnerUserId);

    // This proves the process-boundary handoff retained the exact local
    // bootstrap data before a later slice creates personal-management data.
    await _openTimetableWeekView(tester);
    await _waitFor(
      tester,
      find.text(environment.manualCourseTitle),
      label: 'the manual course restored across the bootstrap process boundary',
    );
    await _waitForCondition(
      tester,
      () {
        final state =
            runningApp!.container.read(demoAppControllerProvider).valueOrNull;
        return state?.courses
                .where(
                  (course) => course.title == environment.manualCourseTitle,
                )
                .length ==
            1;
      },
      label: 'the restored manual course state',
    );
    final restoredState =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(restoredState, isNotNull);
    manualCourseId = restoredState!.courses
        .singleWhere((course) => course.title == environment.manualCourseTitle)
        .id;
    await _waitForNativeWidgetCourse(
      tester,
      title: environment.manualCourseTitle,
      room: 'E2E-101',
      weekday: DateTime.tuesday,
      periodNo: 2,
      courseId: manualCourseId,
    );
    await _quiescePersonalManagementApp(appClient, runningApp);
  } finally {
    await runningApp?.dispose(tester);
  }
  return manualCourseId;
}

Future<String> _runPersonalManagementAssignmentCreationPhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required String expectedOwnerUserId,
  required String expectedManualCourseId,
}) async {
  _RunningApp? runningApp;
  late String assignmentId;

  try {
    final restored = await _startRestoredPersonalManagementApp(
      tester,
      environment: environment,
      config: config,
      appClient: appClient,
      sessionStorage: sessionStorage,
      appTransport: appTransport,
      label: 'the personal-management assignment creation boundary',
    );
    runningApp = restored.runningApp;
    expect(restored.ownerUserId, expectedOwnerUserId);
    await _waitForCondition(
      tester,
      () {
        final state =
            runningApp!.container.read(demoAppControllerProvider).valueOrNull;
        return state?.courses
                .where(
                  (course) => course.title == environment.manualCourseTitle,
                )
                .length ==
            1;
      },
      label: 'the manual course state before assignment creation',
    );
    final restoredState =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(restoredState, isNotNull);
    final manualCourseId = restoredState!.courses
        .singleWhere((course) => course.title == environment.manualCourseTitle)
        .id;
    expect(manualCourseId, expectedManualCourseId);
    expect(
      restoredState.assignments.where(
        (assignment) => assignment.title == environment.assignmentTitle,
      ),
      isEmpty,
    );

    await _createAssignment(
      tester,
      title: environment.assignmentTitle,
      courseTitle: environment.manualCourseTitle,
      dueAt: _defaultAssignmentDueAt(environment),
    );
    await _waitFor(
      tester,
      find.text(environment.assignmentTitle),
      label: 'the newly created assignment',
    );
    await _signalRunnerMarker(environment, _bootstrapAssignmentCreatedMarker);
    await _filterAssignmentsForCourse(
      tester,
      container: runningApp.container,
      title: environment.assignmentTitle,
      courseTitle: environment.manualCourseTitle,
      expectedCourseId: manualCourseId,
    );
    await _signalRunnerMarker(environment, _bootstrapAssignmentFilteredMarker);
    final createdState =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(createdState, isNotNull);
    final createdAssignment = createdState!.assignments.singleWhere(
      (assignment) => assignment.title == environment.assignmentTitle,
    );
    expect(createdAssignment.courseId, expectedManualCourseId);
    expect(
        createdAssignment.dueAt.toUtc(), _defaultAssignmentDueAt(environment));
    expect(createdAssignment.submissionUrl, isNull);
    assignmentId = createdAssignment.id;
    await _quiescePersonalManagementApp(appClient, runningApp);
  } finally {
    await runningApp?.dispose(tester);
  }
  return assignmentId;
}

Future<void> _runPersonalManagementAssignmentLifecyclePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required String expectedOwnerUserId,
  required String expectedManualCourseId,
  required String expectedAssignmentId,
}) async {
  _RunningApp? runningApp;

  try {
    final restored = await _startRestoredPersonalManagementApp(
      tester,
      environment: environment,
      config: config,
      appClient: appClient,
      sessionStorage: sessionStorage,
      appTransport: appTransport,
      label: 'the personal-management assignment lifecycle boundary',
    );
    runningApp = restored.runningApp;
    expect(restored.ownerUserId, expectedOwnerUserId);
    await _waitForCondition(
      tester,
      () {
        final state =
            runningApp!.container.read(demoAppControllerProvider).valueOrNull;
        return state?.courses
                    .where(
                      (course) => course.title == environment.manualCourseTitle,
                    )
                    .length ==
                1 &&
            state?.assignments
                    .where(
                      (assignment) =>
                          assignment.title == environment.assignmentTitle,
                    )
                    .length ==
                1;
      },
      label: 'the restored linked assignment before its lifecycle changes',
    );
    final restoredState =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(restoredState, isNotNull);
    final manualCourseId = restoredState!.courses
        .singleWhere((course) => course.title == environment.manualCourseTitle)
        .id;
    final assignment = restoredState.assignments.singleWhere(
      (item) => item.title == environment.assignmentTitle,
    );
    expect(manualCourseId, expectedManualCourseId);
    expect(assignment.id, expectedAssignmentId);
    expect(assignment.courseId, expectedManualCourseId);
    expect(
      restoredState.assignmentStates[assignment.id]?.status ??
          AssignmentStatus.notStarted,
      AssignmentStatus.notStarted,
    );

    await _openNavigationDestination(tester, '課題・テスト');
    await _waitFor(
      tester,
      find.text(environment.assignmentTitle),
      label: 'the restored assignment before progress',
    );
    await _markAssignmentInProgress(
      tester,
      runningApp.container,
      title: environment.assignmentTitle,
    );

    await _openNavigationDestination(tester, 'カレンダー');
    await _ensureCalendarFilterSelected(tester, '課題');
    await _waitForAssignmentCalendarProjection(
      tester,
      runningApp.container,
      title: environment.assignmentTitle,
    );
    await _waitForAssignmentCalendarDisplay(
      tester,
      title: environment.assignmentTitle,
    );

    await _openNavigationDestination(tester, '課題・テスト');
    final assignmentCard = find.ancestor(
      of: find.text(environment.assignmentTitle),
      matching: find.byType(Card),
    );
    await _tap(
      tester,
      find.descendant(
        of: assignmentCard,
        matching: find.widgetWithText(OutlinedButton, '提出済みを記録'),
      ),
    );
    await _waitFor(
      tester,
      find.text('「${environment.assignmentTitle}」を提出済みにしました。'),
      label: 'the assignment submission acknowledgement',
    );
    await _selectSubmittedAssignmentFilter(
      tester,
      label: 'the submitted assignment filter after submission',
    );
    await _waitFor(
      tester,
      find.textContaining('提出済み · 履歴に保存'),
      label: 'the durable submitted assignment history',
    );
    expect(find.text(environment.assignmentTitle), findsOneWidget);

    await _openNavigationDestination(tester, 'カレンダー');
    await _waitFor(
      tester,
      find.text('今後90日間の予定'),
      label: 'the refreshed calendar list',
    );
    await _assertSubmittedAssignmentIsRemovedFromCalendar(
      tester,
      runningApp.container,
      title: environment.assignmentTitle,
    );
    await _signalRunnerMarker(
      environment,
      _bootstrapAssignmentLifecycleMarker,
    );
    final lifecycleSnackBar = find.byType(SnackBar).hitTestable();
    await _waitFor(
      tester,
      lifecycleSnackBar,
      label: 'the submitted assignment lifecycle feedback',
    );
    expect(
      find.descendant(
        of: lifecycleSnackBar,
        matching: find.text(
          '「${environment.assignmentTitle}」を提出済みにしました。',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: lifecycleSnackBar,
        matching: find.text('元に戻す'),
      ),
      findsOneWidget,
    );
    await tester.drag(lifecycleSnackBar, const Offset(0, 200));
    await tester.pumpAndSettle();
    await _waitForGone(
      tester,
      find.byType(SnackBar).hitTestable(),
      label: 'the assignment lifecycle feedback before course editing',
    );
    await _quiescePersonalManagementApp(appClient, runningApp);
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<({String ownerUserId, _RunningApp runningApp})>
    _startRestoredPersonalManagementApp(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required String label,
}) async {
  final ownerUserId = await _verifyRestoredFirstUserBoundary(
    environment: environment,
    appClient: appClient,
    appTransport: appTransport,
    label: label,
  );
  final runningApp = await _RunningApp.start(
    tester,
    config: config,
    client: appClient,
    sessionStorage: sessionStorage,
    now: environment.now,
  );
  try {
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: label,
    );
  } catch (_) {
    await runningApp.dispose(tester);
    rethrow;
  }
  return (ownerUserId: ownerUserId, runningApp: runningApp);
}

Future<void> _quiescePersonalManagementApp(
  SupabaseClient appClient,
  _RunningApp runningApp,
) async {
  await appClient.removeAllChannels();
  expect(appClient.getChannels(), isEmpty);
  await _synchronize(
    runningApp.container,
    clock: runningApp.clock,
  );
}

Future<void> _runPersonalManagementSyncPhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required String expectedOwnerUserId,
  required String expectedManualCourseId,
  required String expectedAssignmentId,
}) async {
  final peerClient = _newPublicClient(environment);
  _RunningApp? runningApp;

  try {
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the personal-management sync boundary',
    );
    expect(ownerUserId, expectedOwnerUserId);
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'personal-management sync',
    );
    await _waitForCondition(
      tester,
      () {
        final state =
            runningApp!.container.read(demoAppControllerProvider).valueOrNull;
        return state?.courses
                    .where(
                      (course) => course.title == environment.manualCourseTitle,
                    )
                    .length ==
                1 &&
            state?.assignments
                    .where(
                      (assignment) =>
                          assignment.title == environment.assignmentTitle,
                    )
                    .length ==
                1;
      },
      label: 'the persisted personal-management state before sync edits',
    );
    final restoredState =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(restoredState, isNotNull);
    final manualCourseId = restoredState!.courses
        .singleWhere(
          (course) => course.title == environment.manualCourseTitle,
        )
        .id;
    final restoredAssignment = restoredState.assignments.singleWhere(
      (assignment) => assignment.title == environment.assignmentTitle,
    );
    expect(manualCourseId, expectedManualCourseId);
    expect(restoredAssignment.id, expectedAssignmentId);
    expect(restoredAssignment.courseId, manualCourseId);
    expect(
      restoredState.assignmentStates[restoredAssignment.id]?.status,
      AssignmentStatus.submitted,
    );

    await _editManualCourse(
      tester,
      currentTitle: environment.manualCourseTitle,
      updatedTitle: environment.updatedManualCourseTitle,
      updatedRoom: 'E2E-102',
    );
    await _waitForNativeWidgetCourse(
      tester,
      title: environment.updatedManualCourseTitle,
      room: 'E2E-102',
      weekday: DateTime.tuesday,
      periodNo: 2,
      courseId: manualCourseId,
    );
    await _openNavigationDestination(tester, 'カレンダー');

    await _createPersonalEvent(
      tester,
      title: environment.syncedPersonalEventTitle,
      location: 'E2E 同期済み',
    );
    await _waitFor(
      tester,
      find.text(environment.syncedPersonalEventTitle),
      label: 'the normal personal event before its initial sync',
    );
    final stateBeforeInitialSync =
        runningApp.container.read(demoAppControllerProvider).valueOrNull;
    expect(stateBeforeInitialSync, isNotNull);
    final syncedPersonalEventId = stateBeforeInitialSync!.events
        .singleWhere(
          (event) =>
              event.kind == EventKind.normal &&
              event.title == environment.syncedPersonalEventTitle,
        )
        .id;
    await _synchronize(runningApp.container, clock: runningApp.clock);
    await _assertDrainedSyncQueueWithSyncedEvent(
      runningApp.database,
      ownerUserId: ownerUserId,
      eventId: syncedPersonalEventId,
    );
    // The running app owns startup/realtime work on appClient. Observe the
    // committed remote state through an independent authenticated public
    // client, while the app-side sync result above still asserts its own push.
    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    await _assertInitialPersonalManagementUtcRemote(
      peerClient,
      ownerUserId: ownerUserId,
      environment: environment,
    );

    final peerGateway = SupabaseScheduleGateway(client: peerClient);
    final peerDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: 0,
      limit: 200,
    );
    final peerEntityTypes =
        peerDelta.changes.map((change) => change.entityType).toSet();
    expect(peerEntityTypes, contains('user_course'));
    expect(peerEntityTypes, contains('assignment'));
    expect(peerEntityTypes, contains('assignment_user_state'));
    expect(peerEntityTypes, contains('exam'));
    expect(peerEntityTypes, contains('event'));
    final linkedExam = peerDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'exam' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.courseLinkedExamTitle,
    );
    expect(linkedExam.payload['courseId'], isNotNull);
    final standaloneExam = peerDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'exam' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.standaloneExamTitle,
    );
    expect(standaloneExam.payload['courseId'], isNull);
    final syncedPersonalEvent = peerDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.syncedPersonalEventTitle,
    );
    expect(syncedPersonalEvent.payload['location'], 'E2E 同期済み');
    expect(syncedPersonalEvent.deletedAt, isNull);
    _expectUtcPayloadInstant(
      syncedPersonalEvent.payload['startAt'],
      _defaultFormStart(environment),
    );
    final syncedManualCourse = peerDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'user_course' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.updatedManualCourseTitle,
    );
    expect(syncedManualCourse.payload['room'], 'E2E-102');
    await _signalRunnerMarker(environment, _bootstrapInitialSyncVerifiedMarker);

    await _deleteManualCourse(
      tester,
      title: environment.updatedManualCourseTitle,
    );
    await _waitForNativeWidgetCourseRemoval(
      tester,
      courseId: manualCourseId,
    );
    await _synchronize(runningApp.container, clock: runningApp.clock);
    final deletedCourseDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: peerDelta.nextCursor,
      limit: 200,
    );
    expect(deletedCourseDelta.hasMore, isFalse);
    final deletedManualCourse = deletedCourseDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'user_course' &&
          change.entityId == syncedManualCourse.entityId &&
          change.operation == ScheduleDeltaOperation.delete,
    );
    expect(deletedManualCourse.deletedAt, isNotNull);
    expect(deletedManualCourse.payload['deletedAt'], isNotNull);
    expect(
      deletedManualCourse.serverVersion,
      greaterThan(syncedManualCourse.serverVersion),
    );
    await _signalRunnerMarker(
      environment,
      _bootstrapCourseTombstoneVerifiedMarker,
    );
    await _quiescePersonalManagementApp(appClient, runningApp);
  } finally {
    await runningApp?.dispose(tester);
    await peerClient.dispose();
  }
}

Future<_EmailOnlineCandidateHandoff> _runEmailOnlinePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
  required _EmailOnlineSlice slice,
  _EmailOnlineCandidateHandoff? handoff,
}) async {
  _RunningApp? runningApp;
  try {
    expect(
      config.emailImportEnabled,
      isFalse,
      reason: 'The production email feature flag must remain disabled.',
    );
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the online email-import boundary',
    );
    final reconciliationGateway = _AndroidEmailReconciliationGateway();
    const extractor = RuleBasedEmailTaskExtractor();
    late final _AndroidEmailRemoteActions emailRemoteActions;
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
      extraOverrides: (database) {
        emailRemoteActions = _AndroidEmailRemoteActions(
          database: database,
          environment: environment,
          extractor: extractor,
          clock: () => environment.now,
          authenticatedUserId: () => appClient.auth.currentUser?.id,
        );
        return [
          emailImportPresentationEnabledProvider.overrideWithValue(true),
          emailReconciliationGatewayProvider.overrideWithValue(
            reconciliationGateway,
          ),
          emailReviewRemoteActionsProvider.overrideWithValue(
            emailRemoteActions,
          ),
        ];
      },
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'online email import',
    );
    expect(
      runningApp.container.read(emailReconciliationRuntimeProvider).phase,
      EmailReconciliationRuntimePhase.disabled,
      reason: 'Production email runtime must stay disabled throughout E2E.',
    );

    if (slice != _EmailOnlineSlice.inbox) {
      expect(handoff, isNotNull);
      expect(handoff!.ownerUserId, ownerUserId);
    }

    if (slice == _EmailOnlineSlice.inbox) {
      runningApp.container.read(routerProvider).go('/settings/email-import');
      await _waitFor(
        tester,
        find.byKey(const Key('email-import-settings-list')),
        label: 'the explicitly enabled test-only Gmail settings UI',
      );
      final connectAction = find.byKey(const Key('email-connect-button'));
      await _waitForCondition(
        tester,
        () =>
            connectAction.evaluate().length == 1 &&
            tester.widget<FilledButton>(connectAction).onPressed != null,
        label: 'the online Gmail connect action to become enabled',
      );
      expect(
        tester.widget<FilledButton>(connectAction).onPressed,
        isNotNull,
        reason: 'The Gmail connect action must be enabled before the E2E tap.',
      );
      await _tap(tester, connectAction);
      await _waitFor(
        tester,
        find.byKey(const Key('email-connection-card')),
        label: 'the private test Gmail connection',
      );
      final connection =
          await runningApp.database.emailImportDao.connectionById(
        ownerUserId: ownerUserId,
        connectionId: _androidEmailConnectionId,
      );
      expect(connection?.ownerUserId, ownerUserId);
      expect(connection?.providerAccountHash, _androidEmailProviderAccountHash);

      bool emailConnectionProviderReady() {
        return runningApp!.container
                .read(emailConnectionsProvider(ownerUserId))
                .valueOrNull
                ?.any(
                  (item) =>
                      item.id == _androidEmailConnectionId &&
                      item.status == EmailConnectionStatus.connected,
                ) ==
            true;
      }

      await _waitForCondition(
        tester,
        emailConnectionProviderReady,
        label: 'the connected Gmail provider state to hydrate',
      );
      expect(
        emailConnectionProviderReady(),
        isTrue,
        reason:
            'The inbox must observe the connected Gmail provider before navigation.',
      );
      await _signalRunnerMarker(
        environment,
        _emailConnectionVerifiedMarker,
      );

      await _tap(tester, find.byKey(const Key('open-email-inbox-button')));
      await _waitFor(
        tester,
        find.byKey(const Key('email-inbox-refresh-button')),
        label: 'the private email candidate inbox',
      );
      final inboxRefreshAction =
          find.byKey(const Key('email-inbox-refresh-button'));
      await _waitForCondition(
        tester,
        () =>
            inboxRefreshAction.evaluate().length == 1 &&
            emailConnectionProviderReady() &&
            tester.widget<IconButton>(inboxRefreshAction).onPressed != null,
        label: 'the online email inbox refresh action to become enabled',
      );
      expect(
        emailConnectionProviderReady(),
        isTrue,
        reason:
            'The inbox refresh requires the hydrated connected Gmail provider.',
      );
      expect(
        tester.widget<IconButton>(inboxRefreshAction).onPressed,
        isNotNull,
        reason:
            'The email inbox refresh action must be enabled before the E2E tap.',
      );
      await _tap(tester, inboxRefreshAction);
      await _waitForEmailCandidateCount(
        tester,
        runningApp.database,
        ownerUserId: ownerUserId,
        expected: 5,
        label: 'four validated Japanese candidates and one safe failed row',
      );
      expect(
        emailRemoteActions.fixtureState.extractionCalls,
        4,
        reason: 'Every successful fixture must use the injected extractor.',
      );
      final failedCandidate = (await (runningApp.database
                  .select(runningApp.database.emailCandidates)
                ..where((row) =>
                    row.ownerUserId.equals(ownerUserId) &
                    row.reviewState.equals('failed')))
              .get())
          .single;
      expect(
          failedCandidate.errorCategory, EmailErrorCategory.timeout.wireName);
      final failedSource = await runningApp.database.emailImportDao.sourceById(
        ownerUserId: ownerUserId,
        sourceId: failedCandidate.sourceId,
      );
      expect(failedSource?.processingState, 'failed');
      expect(failedSource?.evidenceExcerptsJson, '[]');
      await _waitFor(
        tester,
        find.byKey(Key('email-candidate-${failedCandidate.id}')),
        label: 'the visible safe failed email candidate',
      );
      expect(find.text('処理できなかった候補'), findsOneWidget);
      expect(
        find.text(emailErrorMessage(EmailErrorCategory.timeout)),
        findsOneWidget,
      );
      await _tap(
        tester,
        find.byKey(Key('email-candidate-${failedCandidate.id}')),
      );
      final retryMalformedCandidate =
          find.byKey(const Key('retry-malformed-email-candidate-button'));
      await _waitFor(
        tester,
        retryMalformedCandidate,
        label: 'the owner-scoped malformed candidate retry action',
      );
      await _waitForCondition(
        tester,
        () =>
            retryMalformedCandidate.evaluate().length == 1 &&
            tester.widget<FilledButton>(retryMalformedCandidate).onPressed !=
                null,
        label: 'the online targeted retry action to become enabled',
      );
      expect(
        tester.widget<FilledButton>(retryMalformedCandidate).onPressed,
        isNotNull,
        reason: 'The online targeted retry must be enabled.',
      );
      expect(
        find.text(emailErrorMessage(EmailErrorCategory.timeout)),
        findsOneWidget,
      );
      await _tap(
        tester,
        retryMalformedCandidate,
      );
      var retryActionSucceeded = false;
      await _waitForCondition(
        tester,
        () async {
          final action = runningApp!.container.read(
            emailReviewActionControllerProvider,
          );
          retryActionSucceeded = !action.isBusy &&
              action.success == EmailReviewSuccess.retryCompleted;
          return retryActionSucceeded ||
              (!action.isBusy && action.failureCategory != null);
        },
        label: 'targeted retry terminal feedback',
        diagnostic: () {
          final action = runningApp!.container.read(
            emailReviewActionControllerProvider,
          );
          return 'operation=${action.operation.name} '
              'success=${action.success?.name ?? 'none'} '
              'failure=${action.failureCategory?.wireName ?? 'none'} '
              'retry_calls=${emailRemoteActions.fixtureState.targetedRetryCalls} '
              'extraction_calls=${emailRemoteActions.fixtureState.extractionCalls}';
        },
      );
      if (!retryActionSucceeded) {
        final category = runningApp.container
            .read(emailReviewActionControllerProvider)
            .failureCategory;
        fail(
          'Targeted retry failed safely with '
          '${category?.wireName ?? 'an unknown category'}.',
        );
      }
      await _waitForCondition(
        tester,
        () async {
          final retried =
              await runningApp!.database.emailImportDao.candidateById(
            ownerUserId: ownerUserId,
            candidateId: failedCandidate.id,
          );
          return retried?.reviewState ==
                  EmailCandidateReviewState.needsReview.wireName &&
              retried?.sourceId == failedCandidate.sourceId &&
              retried?.errorCategory == null;
        },
        label: 'the same failed row to become reviewable after targeted retry',
      );
      final retriedCandidate =
          await runningApp.database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: failedCandidate.id,
      );
      final retriedSource = await runningApp.database.emailImportDao.sourceById(
        ownerUserId: ownerUserId,
        sourceId: failedCandidate.sourceId,
      );
      expect(retriedCandidate?.id, failedCandidate.id);
      expect(retriedCandidate?.sourceId, failedCandidate.sourceId);
      expect(retriedCandidate?.candidateType, 'announcement');
      expect(retriedSource?.id, failedSource?.id);
      expect(retriedSource?.processingState, 'processed');
      expect(emailRemoteActions.fixtureState.targetedRetryCalls, 1);
      expect(emailRemoteActions.fixtureState.extractionCalls, 5);
      final connectionAfterRetry =
          await runningApp.database.emailImportDao.connectionById(
        ownerUserId: ownerUserId,
        connectionId: _androidEmailConnectionId,
      );
      expect(
        connectionAfterRetry?.cursor,
        'android-email-initial',
        reason: 'A targeted retry must not move the normal sync cursor.',
      );
      expect(
        await (runningApp.database.select(runningApp.database.emailCandidates)
              ..where((row) => row.ownerUserId.equals(ownerUserId)))
            .get(),
        hasLength(5),
        reason: 'A targeted retry must upgrade, not duplicate, the failed row.',
      );
      await _signalRunnerMarker(environment, _emailInboxVerifiedMarker);
      final durableCandidates =
          await (runningApp.database.select(runningApp.database.emailCandidates)
                ..where((row) => row.ownerUserId.equals(ownerUserId)))
              .get();
      final durableAssignment = _emailCandidateWithTitle(
        durableCandidates,
        environment.emailAmbiguousAssignmentTitle,
      );
      final durableExam = _emailCandidateWithTitle(
        durableCandidates,
        environment.emailExamTitle,
      );
      final durableDismissedEvent = _emailCandidateWithTitle(
        durableCandidates,
        environment.emailDismissedEventTitle,
      );
      final durableTimezoneEvent = _emailCandidateWithTitle(
        durableCandidates,
        environment.emailTimezoneEventTitle,
      );
      await _quiesceEmailOnlineApp(appClient, runningApp);
      return _EmailOnlineCandidateHandoff(
        ownerUserId: ownerUserId,
        assignmentCandidateId: durableAssignment.id,
        examCandidateId: durableExam.id,
        dismissedEventCandidateId: durableDismissedEvent.id,
        timezoneEventCandidateId: durableTimezoneEvent.id,
      );
    }

    if (slice == _EmailOnlineSlice.review) {
      runningApp.container.read(routerProvider).go('/email-import');
      await _waitFor(
        tester,
        find.byKey(const Key('email-inbox-refresh-button')),
        label: 'the inbox after targeted retry',
      );

      final initialCandidates =
          await (runningApp.database.select(runningApp.database.emailCandidates)
                ..where((row) => row.ownerUserId.equals(ownerUserId)))
              .get();
      expect(
        initialCandidates.map((candidate) => candidate.candidateType),
        containsAll(const ['assignment', 'exam', 'event', 'announcement']),
      );
      for (final candidate in initialCandidates) {
        expect(candidate.ownerUserId, ownerUserId);
        expect(candidate.requiresUserConfirmation, isTrue);
        expect(candidate.linkedEntityId, isNull);
      }
      final assignmentCandidate = _emailCandidateWithTitle(
        initialCandidates,
        environment.emailAmbiguousAssignmentTitle,
      );
      final examCandidate = _emailCandidateWithTitle(
        initialCandidates,
        environment.emailExamTitle,
      );
      final eventCandidate = _emailCandidateWithTitle(
        initialCandidates,
        environment.emailDismissedEventTitle,
      );
      final timezoneEventCandidate = _emailCandidateWithTitle(
        initialCandidates,
        environment.emailTimezoneEventTitle,
      );
      expect(assignmentCandidate.id, handoff!.assignmentCandidateId);
      expect(examCandidate.id, handoff.examCandidateId);
      expect(eventCandidate.id, handoff.dismissedEventCandidateId);
      expect(timezoneEventCandidate.id, handoff.timezoneEventCandidateId);
      await _assertNoEmailCanonicalEntities(
        runningApp.database,
        ownerUserId: ownerUserId,
        environment: environment,
      );
      final correctedCourse =
          await (runningApp.database.select(runningApp.database.userCourses)
                ..where((row) =>
                    row.ownerUserId.equals(ownerUserId) &
                    row.title.equals(environment.emailCorrectedCourseName) &
                    row.deletedAt.isNull()))
              .getSingle();

      await _openEmailCandidate(
        tester,
        runningApp.container,
        assignmentCandidate.id,
      );
      await _scrollEmailReviewTo(
        tester,
        find.byKey(const Key('email-candidate-title-field')),
        label: 'the ambiguous assignment title field',
      );
      await tester.enterText(
        find.byKey(const Key('email-candidate-title-field')),
        environment.emailAssignmentTitle,
      );
      await tester.pump();
      await _scrollEmailReviewTo(
        tester,
        find.byKey(const Key('email-candidate-course-field')),
        label: 'the ambiguous assignment course field',
      );
      await tester.enterText(
        find.byKey(const Key('email-candidate-course-field')),
        environment.emailCorrectedCourseName,
      );
      await tester.pump();
      await _scrollEmailReviewTo(
        tester,
        find.byKey(const Key('email-candidate-course-code-field')),
        label: 'the ambiguous assignment course-code field',
      );
      await tester.enterText(
        find.byKey(const Key('email-candidate-course-code-field')),
        environment.emailCorrectedCourseCode,
      );
      await tester.pump();
      tester.binding.focusedEditable = null;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await _androidE2ePlatform.invokeMethod<void>('hideImeAndRefreshInsets');
      await tester.pump(const Duration(milliseconds: 200));
      await _acknowledgeEmailCandidate(tester);
      await _waitForCondition(
        tester,
        () =>
            tester
                .widget<TextButton>(
                  find.byKey(const Key('save-email-candidate-button')),
                )
                .onPressed !=
            null,
        label: 'saving the reviewed assignment draft',
      );
      await _tap(tester, find.byKey(const Key('save-email-candidate-button')));
      await _waitForCondition(
        tester,
        () async {
          final row = await runningApp!.database.emailImportDao.candidateById(
            ownerUserId: ownerUserId,
            candidateId: assignmentCandidate.id,
          );
          if (row == null) return false;
          final payload = const EmailCandidatePayloadCodec()
              .decode(row.normalizedPayloadJson);
          return payload.title == environment.emailAssignmentTitle &&
              payload.courseHint.name == environment.emailCorrectedCourseName &&
              payload.courseHint.code == environment.emailCorrectedCourseCode;
        },
        label: 'the persisted edited assignment title and course hint',
      );

      await _openEmailCandidate(
        tester,
        runningApp.container,
        eventCandidate.id,
      );
      await _tapEmailReviewAction(
        tester,
        find.byKey(const Key('dismiss-email-candidate-button')),
        label: 'the event candidate dismissal action',
      );
      await _waitFor(
        tester,
        find.byKey(const Key('confirm-email-dismiss-button')),
        label: 'the immutable dismissal confirmation',
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-email-dismiss-button')),
      );
      await _waitForCondition(
        tester,
        () async =>
            await runningApp!.database.emailImportDao.candidateById(
              ownerUserId: ownerUserId,
              candidateId: eventCandidate.id,
            ) ==
            null,
        label: 'the pruned dismissed event source and candidate',
      );
      final tombstone = await runningApp.database.emailImportDao.dismissalById(
        ownerUserId: ownerUserId,
        tombstoneId: eventCandidate.id,
      );
      expect(tombstone, isNotNull);
      expect(tombstone!.providerMessageIdHash, hasLength(64));
      expect(tombstone.providerMessageIdHash, isNot(contains('message-event')));
      await _signalRunnerMarker(environment, _emailReviewVerifiedMarker);
      await _quiesceEmailOnlineApp(appClient, runningApp);
      return handoff.withCorrectedCourseId(correctedCourse.id);
    }

    if (slice == _EmailOnlineSlice.assignmentConfirmation) {
      final persistedAssignmentCandidate =
          await runningApp.database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: handoff!.assignmentCandidateId,
      );
      expect(persistedAssignmentCandidate, isNotNull);
      final assignmentCandidate = persistedAssignmentCandidate!;
      final correctedCourseId = handoff.correctedCourseId;
      expect(correctedCourseId, isNotNull);
      final correctedCourse =
          await (runningApp.database.select(runningApp.database.userCourses)
                ..where((row) =>
                    row.id.equals(correctedCourseId!) &
                    row.ownerUserId.equals(ownerUserId) &
                    row.deletedAt.isNull()))
              .getSingle();
      expect(
        await runningApp.database.emailImportDao.candidateById(
          ownerUserId: ownerUserId,
          candidateId: handoff.dismissedEventCandidateId,
        ),
        isNull,
      );
      final durableTombstone =
          await runningApp.database.emailImportDao.dismissalById(
        ownerUserId: ownerUserId,
        tombstoneId: handoff.dismissedEventCandidateId,
      );
      expect(durableTombstone, isNotNull);

      await _openEmailCandidate(
        tester,
        runningApp.container,
        assignmentCandidate.id,
      );
      final persistedCourseField =
          find.byKey(const Key('email-candidate-course-field'));
      await _scrollEmailReviewTo(
        tester,
        persistedCourseField,
        label: 'the persisted corrected assignment course field',
      );
      expect(
        tester.widget<TextFormField>(persistedCourseField).controller?.text,
        environment.emailCorrectedCourseName,
      );
      final persistedCourseCodeField =
          find.byKey(const Key('email-candidate-course-code-field'));
      await _scrollEmailReviewTo(
        tester,
        persistedCourseCodeField,
        label: 'the persisted corrected assignment course-code field',
      );
      expect(
        tester.widget<TextFormField>(persistedCourseCodeField).controller?.text,
        environment.emailCorrectedCourseCode,
      );
      final confirmationCourseField =
          find.byKey(const Key('email-candidate-owned-course-field'));
      await _scrollEmailReviewTo(
        tester,
        confirmationCourseField,
        label: 'the confirmed owned-course relationship',
      );
      await _selectDropdownMenuOption(
        tester,
        field: confirmationCourseField,
        optionText: find.text(environment.emailCorrectedCourseName),
        label: 'the confirmed email assignment course option',
      );
      expect(
        tester.state<FormFieldState<dynamic>>(confirmationCourseField).value,
        correctedCourse.id,
        reason: 'The explicit course selection must use the active owned row.',
      );
      await _acknowledgeEmailCandidate(tester);
      await _tapEmailReviewAction(
        tester,
        find.byKey(const Key('confirm-email-candidate-button')),
        label: 'the online assignment confirmation action',
      );
      await _waitFor(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
        label: 'the private-only assignment confirmation',
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
      );
      final confirmedAssignment = await _waitForConfirmedEmailEntity(
        tester,
        runningApp.database,
        container: runningApp.container,
        ownerUserId: ownerUserId,
        candidateId: assignmentCandidate.id,
        entityType: EmailCandidateType.assignment,
      );
      expect(
        confirmedAssignment.visibilityLevel,
        VisibilityLevel.private.wireName,
      );
      final canonicalAssignment =
          await (runningApp.database.select(runningApp.database.assignments)
                ..where((row) =>
                    row.id.equals(confirmedAssignment.id) &
                    row.ownerUserId.equals(ownerUserId)))
              .getSingle();
      expect(canonicalAssignment.courseId, correctedCourse.id);
      expect(canonicalAssignment.title, environment.emailAssignmentTitle);
      final assignmentMutation = await _waitForEmailMutationState(
        tester,
        runningApp.database,
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: confirmedAssignment.id,
        operation: 'create',
        allowedStatuses: const {'synced', 'pending', 'failed'},
        label: 'the online assignment confirmation queue state',
      );
      _expectOfflineEmailCreateMutation(
        assignmentMutation,
        allowedStatuses: const {'synced', 'pending', 'failed'},
        label: 'the online assignment confirmation before the outage',
      );
      await _signalRunnerMarker(
        environment,
        _emailOnlineConfirmationVerifiedMarker,
      );

      await _quiesceEmailOnlineApp(appClient, runningApp);
      return handoff;
    }

    if (slice == _EmailOnlineSlice.timezoneAndOffline) {
      final persistedTimezoneEventCandidate =
          await runningApp.database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: handoff!.timezoneEventCandidateId,
      );
      final persistedExamCandidate =
          await runningApp.database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: handoff.examCandidateId,
      );
      expect(persistedTimezoneEventCandidate, isNotNull);
      expect(persistedExamCandidate, isNotNull);
      final timezoneEventCandidate = persistedTimezoneEventCandidate!;
      final examCandidate = persistedExamCandidate!;
      expect(
        await runningApp.database.emailImportDao.candidateById(
          ownerUserId: ownerUserId,
          candidateId: handoff.dismissedEventCandidateId,
        ),
        isNull,
      );
      expect(
        await runningApp.database.emailImportDao.dismissalById(
          ownerUserId: ownerUserId,
          tombstoneId: handoff.dismissedEventCandidateId,
        ),
        isNotNull,
      );
      final confirmedAssignmentCandidate =
          await runningApp.database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: handoff.assignmentCandidateId,
      );
      expect(confirmedAssignmentCandidate?.linkedEntityId, isNotNull);
      final durableConfirmedAssignment = await (runningApp.database
              .select(runningApp.database.assignments)
            ..where((row) =>
                row.id.equals(confirmedAssignmentCandidate!.linkedEntityId!) &
                row.ownerUserId.equals(ownerUserId)))
          .getSingle();
      expect(
          durableConfirmedAssignment.title, environment.emailAssignmentTitle);
      expect(
        durableConfirmedAssignment.courseId,
        handoff.correctedCourseId,
      );

      final timezoneEventPayload = const EmailCandidatePayloadCodec()
          .decode(timezoneEventCandidate.normalizedPayloadJson);
      expect(timezoneEventPayload.due.timezone, 'America/New_York');
      final examPayload = const EmailCandidatePayloadCodec()
          .decode(examCandidate.normalizedPayloadJson);
      expect(examPayload.candidateType, EmailCandidateType.exam);
      expect(examPayload.startAt, environment.emailExamStartAt);
      expect(
        examPayload.endAt,
        environment.emailExamStartAt.add(const Duration(hours: 1)),
      );
      expect(examPayload.endAt!.isAfter(examPayload.startAt!), isTrue);
      expect(examPayload.submissionUrl, isNull);
      await _openEmailCandidate(
        tester,
        runningApp.container,
        timezoneEventCandidate.id,
      );
      await _acknowledgeEmailCandidate(tester);
      await _tapEmailReviewAction(
        tester,
        find.byKey(const Key('confirm-email-candidate-button')),
        label: 'the non-Tokyo Event confirmation action',
      );
      await _waitFor(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
        label: 'the private-only non-Tokyo Event confirmation',
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
      );
      final confirmedTimezoneEvent = await _waitForConfirmedEmailEntity(
        tester,
        runningApp.database,
        container: runningApp.container,
        ownerUserId: ownerUserId,
        candidateId: timezoneEventCandidate.id,
        entityType: EmailCandidateType.event,
      );
      expect(
        confirmedTimezoneEvent.visibilityLevel,
        VisibilityLevel.private.wireName,
      );
      final canonicalTimezoneEvent =
          await (runningApp.database.select(runningApp.database.events)
                ..where((row) =>
                    row.id.equals(confirmedTimezoneEvent.id) &
                    row.ownerUserId.equals(ownerUserId)))
              .getSingle();
      expect(canonicalTimezoneEvent.startAt.toUtc(),
          environment.emailTimezoneEventStartAt);
      expect(canonicalTimezoneEvent.timezone, JapanTime.timeZone);
      final timezoneEventNotification = await (runningApp.database
              .select(runningApp.database.notificationScheduleRequests)
            ..where((row) => row.entityId.equals(confirmedTimezoneEvent.id)))
          .getSingle();
      expect(timezoneEventNotification.timezone, 'America/New_York');
      final timezoneEventMutation = await _waitForEmailMutationState(
        tester,
        runningApp.database,
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: confirmedTimezoneEvent.id,
        operation: 'create',
        allowedStatuses: const {'synced', 'pending', 'failed'},
        label: 'the non-Tokyo Event canonical create queue state',
      );
      _expectOfflineEmailCreateMutation(
        timezoneEventMutation,
        allowedStatuses: const {'synced', 'pending', 'failed'},
        label: 'the non-Tokyo Event canonical create',
      );
      if (timezoneEventMutation.payloadJson != '{}') {
        expect(
          (jsonDecode(timezoneEventMutation.payloadJson)
              as Map<String, dynamic>)['timezone'],
          JapanTime.timeZone,
        );
      }

      await _quiesceEmailOnlineApp(appClient, runningApp);
      await _signalRunnerMarker(environment, _emailOfflineReadyMarker);
      await _waitForLocalSupabaseReachability(
        environment,
        reachable: false,
        probeClient: appTransport,
        label: 'the runner-controlled outage before offline email confirmation',
      );
      runningApp.container.invalidate(emailNetworkAvailableProvider);
      await _openEmailCandidate(
        tester,
        runningApp.container,
        examCandidate.id,
      );
      await _waitFor(
        tester,
        find.byKey(const Key('email-offline-banner')),
        label: 'the app-observed offline email state',
      );
      await _acknowledgeEmailCandidate(tester);
      await _tapEmailReviewAction(
        tester,
        find.byKey(const Key('confirm-email-candidate-button')),
        label: 'the offline exam confirmation action',
      );
      await _waitFor(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
        label: 'the private-only offline exam confirmation',
      );
      await _tap(
        tester,
        find.byKey(const Key('confirm-private-email-add-button')),
      );
      final confirmedExam = await _waitForConfirmedEmailEntity(
        tester,
        runningApp.database,
        container: runningApp.container,
        ownerUserId: ownerUserId,
        candidateId: examCandidate.id,
        entityType: EmailCandidateType.exam,
      );
      expect(confirmedExam.visibilityLevel, VisibilityLevel.private.wireName);
      final examMutation = await _waitForEmailMutationState(
        tester,
        runningApp.database,
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: confirmedExam.id,
        operation: 'create',
        allowedStatuses: const {'pending', 'failed'},
        label: 'the offline exam confirmation queue state',
      );
      _expectOfflineEmailCreateMutation(
        examMutation,
        allowedStatuses: const {'pending', 'failed'},
        label: 'the offline exam confirmation',
      );
      await _signalRunnerMarker(environment, _emailOfflineQueuedMarker);
      return handoff;
    }
    throw StateError('Unsupported online email-import slice: $slice');
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<void> _quiesceEmailOnlineApp(
  SupabaseClient appClient,
  _RunningApp runningApp,
) async {
  await appClient.removeAllChannels();
  expect(appClient.getChannels(), isEmpty);
  // Only the schedule queue is drained here. Email reconciliation receipts
  // intentionally remain durable for the real process-restart phase.
  await _synchronize(
    runningApp.container,
    clock: runningApp.clock,
  );
}

Future<Map<EmailCandidateType, EmailCandidate>> _emailCandidatesByType(
  AppDatabase database, {
  required String ownerUserId,
}) async {
  final rows = await (database.select(database.emailCandidates)
        ..where((row) => row.ownerUserId.equals(ownerUserId)))
      .get();
  return {
    for (final row in rows) EmailCandidateType.fromWire(row.candidateType): row,
  };
}

EmailCandidate _emailCandidateWithTitle(
  Iterable<EmailCandidate> candidates,
  String title,
) {
  return candidates.singleWhere((candidate) {
    try {
      return const EmailCandidatePayloadCodec()
              .decode(candidate.normalizedPayloadJson)
              .title ==
          title;
    } on Object {
      return false;
    }
  });
}

Future<void> _waitForEmailCandidateCount(
  WidgetTester tester,
  AppDatabase database, {
  required String ownerUserId,
  required int expected,
  required String label,
}) {
  return _waitForCondition(
    tester,
    () async =>
        (await (database.select(database.emailCandidates)
                  ..where((row) => row.ownerUserId.equals(ownerUserId)))
                .get())
            .length ==
        expected,
    label: label,
  );
}

Future<void> _assertNoEmailCanonicalEntities(
  AppDatabase database, {
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
}) async {
  final assignments = await (database.select(database.assignments)
        ..where((row) =>
            row.ownerUserId.equals(ownerUserId) &
            row.title.isIn([
              environment.emailAmbiguousAssignmentTitle,
              environment.emailAssignmentTitle,
            ])))
      .get();
  final exams = await (database.select(database.exams)
        ..where((row) =>
            row.ownerUserId.equals(ownerUserId) &
            row.title.equals(environment.emailExamTitle)))
      .get();
  final events = await (database.select(database.events)
        ..where((row) =>
            row.ownerUserId.equals(ownerUserId) &
            row.title.isIn([
              environment.emailDismissedEventTitle,
              environment.emailTimezoneEventTitle,
            ])))
      .get();
  expect(assignments, isEmpty);
  expect(exams, isEmpty);
  expect(events, isEmpty);
}

Future<void> _openEmailCandidate(
  WidgetTester tester,
  ProviderContainer container,
  String candidateId,
) async {
  container.read(routerProvider).go('/email-import/$candidateId');
  await tester.pump();
  await _waitFor(
    tester,
    find.byKey(ValueKey('email-candidate-review-$candidateId')),
    label: 'the exact owner-scoped email candidate review',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('email-candidate-review-list')),
    label: 'the owner-scoped email candidate review',
  );
}

Future<void> _scrollEmailReviewTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
}) {
  return _scrollCurrentVerticalListTo(
    tester,
    finder,
    listKey: 'email-candidate-review-list',
    label: label,
  );
}

Future<void> _scrollCurrentVerticalListTo(
  WidgetTester tester,
  Finder finder, {
  required String listKey,
  required String label,
}) async {
  final list = find.byKey(Key(listKey));
  var resetToStart = false;
  var lastListCount = 0;
  var lastTargetCount = 0;
  var lastScrollableCount = 0;
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final listElements = list.evaluate().where((element) {
      final route = ModalRoute.of(element);
      return route == null || route.isCurrent;
    }).toList(growable: false);
    lastListCount = listElements.length;
    if (listElements.length != 1) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      continue;
    }
    final currentList = find.byElementPredicate(
      (element) => identical(element, listElements.single),
      description: 'the current email candidate review list for $label',
    );
    final targetElements = find
        .descendant(of: currentList, matching: finder)
        .evaluate()
        .toList(growable: false);
    lastTargetCount = targetElements.length;
    if (targetElements.length == 1) {
      final target = find.byElementPredicate(
        (element) => identical(element, targetElements.single),
        description: 'the current email review target for $label',
      );
      await Scrollable.ensureVisible(
        targetElements.single,
        duration: Duration.zero,
        alignment: 0.5,
      );
      await tester.pump();
      if (target.hitTestable().evaluate().length == 1) return;
    }

    final scrollableElements = find
        .descendant(of: currentList, matching: find.byType(Scrollable))
        .evaluate()
        .where((element) {
      final scrollable = element.widget as Scrollable;
      return scrollable.axisDirection == AxisDirection.down ||
          scrollable.axisDirection == AxisDirection.up;
    }).toList(growable: false);
    lastScrollableCount = scrollableElements.length;
    if (scrollableElements.length == 1) {
      final scrollable = find.byElementPredicate(
        (element) => identical(element, scrollableElements.single),
        description: 'the current review scrollable for $label',
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      if (position.hasContentDimensions) {
        final targetOffset =
            !resetToStart && position.pixels > position.minScrollExtent + 0.5
                ? position.minScrollExtent
                : (position.pixels + 220)
                    .clamp(position.minScrollExtent, position.maxScrollExtent)
                    .toDouble();
        resetToStart = true;
        if ((position.pixels - targetOffset).abs() > 0.5) {
          position.jumpTo(targetOffset);
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    'Timed out making $label safely tappable '
    '(currentLists=$lastListCount; currentTargets=$lastTargetCount; '
    'currentScrollables=$lastScrollableCount).',
  );
}

Future<void> _acknowledgeEmailCandidate(WidgetTester tester) async {
  final acknowledgement = find.byKey(const Key('email-review-acknowledgement'));
  await _scrollEmailReviewTo(
    tester,
    acknowledgement,
    label: 'the explicit candidate acknowledgement',
  );
  await _waitForCondition(
    tester,
    () {
      if (acknowledgement.evaluate().length != 1) return false;
      return tester.widget<CheckboxListTile>(acknowledgement).onChanged != null;
    },
    label: 'the explicit candidate acknowledgement to be enabled',
  );
  final tile = tester.widget<CheckboxListTile>(acknowledgement);
  if (tile.value != true) {
    final hitTarget = acknowledgement.hitTestable();
    expect(hitTarget, findsOneWidget);
    await tester.tap(hitTarget);
    await tester.pump();
    await _waitForCondition(
      tester,
      () =>
          acknowledgement.evaluate().length == 1 &&
          tester.widget<CheckboxListTile>(acknowledgement).value == true,
      label: 'the explicit candidate acknowledgement to be selected',
    );
  }
  expect(tester.widget<CheckboxListTile>(acknowledgement).value, isTrue);
}

Future<void> _tapEmailReviewAction(
  WidgetTester tester,
  Finder action, {
  required String label,
}) async {
  await _scrollEmailReviewTo(tester, action, label: label);
  await _waitForCondition(
    tester,
    () => tester.widget<ButtonStyleButton>(action).onPressed != null,
    label: '$label to be enabled',
  );
  await _scrollEmailReviewTo(
    tester,
    action,
    label: 'the enabled $label',
  );
  expect(tester.widget<ButtonStyleButton>(action).onPressed, isNotNull);
  final hitTarget = find
      .descendant(
        of: action,
        matching: find.byType(InkWell),
      )
      .hitTestable();
  expect(hitTarget, findsOneWidget);
  await tester.tap(hitTarget);
  await tester.pump();
}

Future<({String id, String? visibilityLevel})> _waitForConfirmedEmailEntity(
  WidgetTester tester,
  AppDatabase database, {
  required ProviderContainer container,
  required String ownerUserId,
  required String candidateId,
  required EmailCandidateType entityType,
}) async {
  var confirmed = false;
  await _waitForCondition(
    tester,
    () async {
      final candidate = await database.emailImportDao.candidateById(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      confirmed = candidate?.reviewState == 'confirmed' &&
          candidate?.linkedEntityType == entityType.wireName &&
          candidate?.linkedEntityId != null;
      final action = container.read(emailReviewActionControllerProvider);
      if (action.isBusy) return false;
      return confirmed || action.failureCategory != null;
    },
    label: 'the atomic private ${entityType.wireName} confirmation',
    diagnostic: () {
      final action = container.read(emailReviewActionControllerProvider);
      return 'confirmed=$confirmed operation=${action.operation.name} '
          'failure=${action.failureCategory?.wireName ?? 'none'}';
    },
  );
  if (!confirmed) {
    final category =
        container.read(emailReviewActionControllerProvider).failureCategory;
    fail(
      'The atomic private ${entityType.wireName} confirmation failed safely '
      'with ${category?.wireName ?? 'an unknown category'}.',
    );
  }
  await _waitFor(
    tester,
    _appBarTitle('メール候補'),
    label: 'the email inbox after ${entityType.wireName} confirmation',
  );
  final candidate = (await database.emailImportDao.candidateById(
    ownerUserId: ownerUserId,
    candidateId: candidateId,
  ))!;
  if (entityType == EmailCandidateType.assignment) {
    final row = await (database.select(database.assignments)
          ..where((row) =>
              row.id.equals(candidate.linkedEntityId!) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingle();
    return (id: row.id, visibilityLevel: row.visibilityLevel);
  }
  if (entityType == EmailCandidateType.exam) {
    final row = await (database.select(database.exams)
          ..where((row) =>
              row.id.equals(candidate.linkedEntityId!) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingle();
    return (id: row.id, visibilityLevel: row.visibilityLevel);
  }
  if (entityType == EmailCandidateType.event) {
    final row = await (database.select(database.events)
          ..where((row) =>
              row.id.equals(candidate.linkedEntityId!) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingle();
    return (id: row.id, visibilityLevel: row.visibilityLevel);
  }
  throw StateError('Unsupported email confirmation type.');
}

void _expectOfflineEmailCreateMutation(
  SyncQueueEntry mutation, {
  required Set<String> allowedStatuses,
  required String label,
}) {
  expect(mutation.operation, 'create', reason: '$label must be a create.');
  expect(
    allowedStatuses,
    contains(mutation.status),
    reason: '$label must remain in an explicitly allowed durable state.',
  );
  expect(
    mutation.status,
    isNot(isIn(const {'processing', 'conflict', 'quarantined'})),
    reason: '$label must not be left claimed, conflicted, or quarantined.',
  );
  if (mutation.status == 'synced') {
    expect(mutation.syncedAt, isNotNull, reason: '$label needs its sync ack.');
    expect(
      mutation.serverVersion,
      greaterThan(0),
      reason: '$label needs its acknowledged server version.',
    );
    expect(
      mutation.completionProvenance,
      scheduleSyncCompletionRemoteApplied,
      reason: '$label must carry a real remote-applied acknowledgement.',
    );
  } else {
    expect(mutation.syncedAt, isNull, reason: '$label is not acknowledged.');
    expect(
      mutation.serverVersion,
      isNull,
      reason: '$label must not claim an unreceived server version.',
    );
    expect(
      mutation.completionProvenance,
      isNull,
      reason: '$label must not claim terminal completion provenance.',
    );
  }
}

void _expectSyncedEmailMutation(
  SyncQueueEntry mutation, {
  required String operation,
  required String label,
}) {
  expect(mutation.operation, operation, reason: '$label operation mismatch.');
  expect(mutation.status, 'synced', reason: '$label must be fully drained.');
  expect(mutation.syncedAt, isNotNull, reason: '$label needs its sync ack.');
  expect(
    mutation.serverVersion,
    greaterThan(0),
    reason: '$label needs its acknowledged server version.',
  );
  expect(
    mutation.completionProvenance,
    scheduleSyncCompletionRemoteApplied,
    reason: '$label must be acknowledged as remotely applied.',
  );
}

Future<SyncQueueEntry> _waitForEmailMutationState(
  WidgetTester tester,
  AppDatabase database, {
  required String ownerUserId,
  required String entityType,
  required String entityId,
  required String operation,
  required Set<String> allowedStatuses,
  required String label,
}) async {
  SyncQueueEntry? observed;
  await _waitForCondition(
    tester,
    () async {
      final matches = (await database.syncQueueDao.allMutations(ownerUserId))
          .where((row) =>
              row.entityType == entityType &&
              row.entityId == entityId &&
              row.operation == operation)
          .toList(growable: false);
      if (matches.length != 1 ||
          !allowedStatuses.contains(matches.single.status)) {
        return false;
      }
      observed = matches.single;
      return true;
    },
    label: label,
  );
  return observed!;
}

Future<void> _runEmailRestartPhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  final peerClient = _newPublicClient(environment);
  _RunningApp? runningApp;
  try {
    expect(config.emailImportEnabled, isFalse);
    final restoredSession = appClient.auth.currentSession;
    expect(
      restoredSession?.user.id,
      isNotNull,
      reason: 'The email restart must retain the first authenticated owner.',
    );
    final ownerUserId = restoredSession!.user.id;
    expect(restoredSession.user.email?.toLowerCase(), environment.firstEmail);
    final reconciliationGateway = _AndroidEmailReconciliationGateway(
      loseFirstConfirmationResponse: true,
    );
    const extractor = RuleBasedEmailTaskExtractor();
    late final _AndroidEmailRemoteActions emailRemoteActions;
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now.add(const Duration(minutes: 10)),
      extraOverrides: (database) {
        emailRemoteActions = _AndroidEmailRemoteActions(
          database: database,
          environment: environment,
          extractor: extractor,
          clock: () => environment.now.add(const Duration(minutes: 10)),
          authenticatedUserId: () => appClient.auth.currentUser?.id,
        );
        return [
          onboardingGateProvider.overrideWithValue(
            const AsyncData(OnboardingGateStatus.completed),
          ),
          emailImportPresentationEnabledProvider.overrideWithValue(true),
          emailReconciliationGatewayProvider.overrideWithValue(
            reconciliationGateway,
          ),
          emailReviewRemoteActionsProvider.overrideWithValue(
            emailRemoteActions,
          ),
        ];
      },
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'offline email process restart',
    );
    expect(
      runningApp.container.read(emailReconciliationRuntimeProvider).phase,
      EmailReconciliationRuntimePhase.disabled,
      reason: 'Production email runtime must stay disabled throughout E2E.',
    );
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: false,
      probeClient: appTransport,
      label: 'the retained email restart outage',
    );

    final restoredCandidates = await _emailCandidatesByType(
      runningApp.database,
      ownerUserId: ownerUserId,
    );
    final assignmentCandidate =
        restoredCandidates[EmailCandidateType.assignment];
    final examCandidate = restoredCandidates[EmailCandidateType.exam];
    final timezoneEventCandidate = restoredCandidates[EmailCandidateType.event];
    final retriedAnnouncementCandidate =
        restoredCandidates[EmailCandidateType.announcement];
    expect(assignmentCandidate?.reviewState, 'confirmed');
    expect(examCandidate?.reviewState, 'confirmed');
    expect(timezoneEventCandidate?.reviewState, 'confirmed');
    expect(
      retriedAnnouncementCandidate?.reviewState,
      EmailCandidateReviewState.needsReview.wireName,
    );
    expect(
      const EmailCandidatePayloadCodec()
          .decode(retriedAnnouncementCandidate!.normalizedPayloadJson)
          .title,
      environment.emailRetriedAnnouncementTitle,
    );
    final restoredAssignmentPayload = const EmailCandidatePayloadCodec()
        .decode(assignmentCandidate!.normalizedPayloadJson);
    expect(restoredAssignmentPayload.title, environment.emailAssignmentTitle);
    expect(
      restoredAssignmentPayload.courseHint.name,
      environment.emailCorrectedCourseName,
    );
    expect(
      restoredAssignmentPayload.courseHint.code,
      environment.emailCorrectedCourseCode,
    );
    final assignmentId = assignmentCandidate.linkedEntityId!;
    final examId = examCandidate!.linkedEntityId!;
    final timezoneEventId = timezoneEventCandidate!.linkedEntityId!;
    final restoredAssignment =
        await (runningApp.database.select(runningApp.database.assignments)
              ..where((row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    final restoredExam =
        await (runningApp.database.select(runningApp.database.exams)
              ..where((row) =>
                  row.id.equals(examId) & row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    final restoredTimezoneEvent =
        await (runningApp.database.select(runningApp.database.events)
              ..where((row) =>
                  row.id.equals(timezoneEventId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    expect(
        restoredAssignment.visibilityLevel, VisibilityLevel.private.wireName);
    expect(restoredExam.visibilityLevel, VisibilityLevel.private.wireName);
    expect(
      restoredTimezoneEvent.visibilityLevel,
      VisibilityLevel.private.wireName,
    );
    expect(restoredTimezoneEvent.timezone, JapanTime.timeZone);
    expect(
      restoredTimezoneEvent.startAt.toUtc(),
      environment.emailTimezoneEventStartAt,
    );
    expect(
      const EmailCandidatePayloadCodec()
          .decode(timezoneEventCandidate.normalizedPayloadJson)
          .due
          .timezone,
      'America/New_York',
    );
    final restoredTimezoneEventNotification = await (runningApp.database
            .select(runningApp.database.notificationScheduleRequests)
          ..where((row) => row.entityId.equals(timezoneEventId)))
        .getSingle();
    expect(restoredTimezoneEventNotification.timezone, 'America/New_York');
    final correctedCourse =
        await (runningApp.database.select(runningApp.database.userCourses)
              ..where((row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.title.equals(environment.emailCorrectedCourseName) &
                  row.deletedAt.isNull()))
            .getSingle();
    expect(restoredAssignment.courseId, correctedCourse.id);
    final confirmationReceipt = await (runningApp.database
            .select(runningApp.database.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.action.equals('confirmation') &
              row.localReferenceId.equals(assignmentCandidate.id)))
        .getSingle();
    final reconciledAssignmentPayload = const EmailCandidatePayloadCodec()
        .decode(confirmationReceipt.reviewedPayloadJson!);
    expect(
      reconciledAssignmentPayload.courseHint.name,
      environment.emailCorrectedCourseName,
    );
    expect(
      reconciledAssignmentPayload.courseHint.code,
      environment.emailCorrectedCourseCode,
    );
    final durableAssignmentCreate = await _waitForEmailMutationState(
      tester,
      runningApp.database,
      ownerUserId: ownerUserId,
      entityType: 'assignment',
      entityId: assignmentId,
      operation: 'create',
      allowedStatuses: const {'synced', 'pending', 'failed'},
      label: 'the restarted assignment create queue state',
    );
    final durableExamCreate = await _waitForEmailMutationState(
      tester,
      runningApp.database,
      ownerUserId: ownerUserId,
      entityType: 'exam',
      entityId: examId,
      operation: 'create',
      allowedStatuses: const {'pending', 'failed'},
      label: 'the restarted offline exam create queue state',
    );
    final durableTimezoneEventCreate = await _waitForEmailMutationState(
      tester,
      runningApp.database,
      ownerUserId: ownerUserId,
      entityType: 'event',
      entityId: timezoneEventId,
      operation: 'create',
      allowedStatuses: const {'synced', 'pending', 'failed'},
      label: 'the restarted canonical Event create queue state',
    );
    _expectOfflineEmailCreateMutation(
      durableAssignmentCreate,
      allowedStatuses: const {'synced', 'pending', 'failed'},
      label: 'the restarted assignment create',
    );
    _expectOfflineEmailCreateMutation(
      durableExamCreate,
      allowedStatuses: const {'pending', 'failed'},
      label: 'the restarted offline exam create',
    );
    _expectOfflineEmailCreateMutation(
      durableTimezoneEventCreate,
      allowedStatuses: const {'synced', 'pending', 'failed'},
      label: 'the restarted canonical Event create',
    );
    runningApp.container.read(routerProvider).go('/email-import');
    await _waitFor(
      tester,
      find.byKey(const Key('email-offline-banner')),
      label: 'the safe Japanese offline email state after restart',
    );
    await _signalRunnerMarker(environment, _emailRestartVerifiedMarker);

    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      requiredConsecutiveSuccesses: 2,
      probeClient: appTransport,
      label: 'the runner-restored email sync network',
    );
    await _synchronize(runningApp.container, clock: runningApp.clock);
    final convergedCreateMutations =
        await runningApp.database.syncQueueDao.allMutations(ownerUserId);
    final convergedAssignmentCreates = convergedCreateMutations
        .where((row) =>
            row.entityType == 'assignment' &&
            row.entityId == assignmentId &&
            row.operation == 'create')
        .toList(growable: false);
    final convergedExamCreates = convergedCreateMutations
        .where((row) =>
            row.entityType == 'exam' &&
            row.entityId == examId &&
            row.operation == 'create')
        .toList(growable: false);
    final convergedTimezoneEventCreates = convergedCreateMutations
        .where((row) =>
            row.entityType == 'event' &&
            row.entityId == timezoneEventId &&
            row.operation == 'create')
        .toList(growable: false);
    expect(convergedAssignmentCreates, hasLength(1));
    expect(convergedExamCreates, hasLength(1));
    expect(convergedTimezoneEventCreates, hasLength(1));
    _expectSyncedEmailMutation(
      convergedAssignmentCreates.single,
      operation: 'create',
      label: 'the converged assignment create',
    );
    _expectSyncedEmailMutation(
      convergedExamCreates.single,
      operation: 'create',
      label: 'the converged exam create',
    );
    _expectSyncedEmailMutation(
      convergedTimezoneEventCreates.single,
      operation: 'create',
      label: 'the converged canonical Event create',
    );
    expect(
      convergedCreateMutations.where(
        (row) =>
            {assignmentId, examId, timezoneEventId}.contains(row.entityId) &&
            const {
              'pending',
              'failed',
              'processing',
              'conflict',
              'quarantined',
            }.contains(row.status),
      ),
      isEmpty,
      reason: 'The reconnected email creates must have no bad queue rows.',
    );
    await _drainEmailReconciliation(
      tester,
      runningApp,
      ownerUserId: ownerUserId,
      expectedActions: const {
        'confirmation': 3,
        'dismissal': 1,
      },
      gateway: reconciliationGateway,
    );
    expect(
      reconciliationGateway.requests
          .where((request) =>
              request.action == EmailReconciliationAction.confirmation)
          .map((request) => request.idempotencyKey)
          .toSet(),
      hasLength(3),
    );
    expect(reconciliationGateway.lostResponseCount, 1);
    expect(reconciliationGateway.replayedResponseCount, 1);
    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    await _assertRemoteEmailEntities(
      peerClient,
      ownerUserId: ownerUserId,
      environment: environment,
      expectedAssignmentId: assignmentId,
      expectedExamId: examId,
      expectedEventId: timezoneEventId,
      expectedAssignmentCourseId: correctedCourse.id,
      expectedAssignmentDueAt: environment.emailInitialAssignmentDueAt,
      expectedEventStartAt: environment.emailTimezoneEventStartAt,
    );
    await _signalRunnerMarker(environment, _emailConvergedMarker);

    runningApp.container.read(routerProvider).go('/settings/email-import');
    await _waitFor(
      tester,
      find.byKey(const Key('email-manual-refresh-button')),
      label: 'the restored Gmail refresh action',
    );
    await _waitForCondition(
      tester,
      () {
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('email-manual-refresh-button')),
        );
        return button.onPressed != null;
      },
      label: 'the online Gmail refresh action to become enabled',
    );
    await _tap(
      tester,
      find.byKey(const Key('email-manual-refresh-button')),
    );
    final activeRunningApp = runningApp;
    await _waitForCondition(
      tester,
      () async {
        final assignmentUpdates =
            await activeRunningApp.database.emailImportDao.pendingUpdates(
          ownerUserId: ownerUserId,
          candidateId: assignmentCandidate.id,
        );
        final eventUpdates =
            await activeRunningApp.database.emailImportDao.pendingUpdates(
          ownerUserId: ownerUserId,
          candidateId: timezoneEventCandidate.id,
        );
        return assignmentUpdates.length == 1 && eventUpdates.length == 1;
      },
      label: 'the same-thread deadline and timezone-only update proposals',
    );
    expect(emailRemoteActions.fixtureState.extractionCalls, 3);
    final proposal = (await runningApp.database.emailImportDao.pendingUpdates(
      ownerUserId: ownerUserId,
      candidateId: assignmentCandidate.id,
    ))
        .single;
    expect(jsonDecode(proposal.fieldDiffJson), contains('due_at'));
    final timezoneProposal =
        (await runningApp.database.emailImportDao.pendingUpdates(
      ownerUserId: ownerUserId,
      candidateId: timezoneEventCandidate.id,
    ))
            .single;
    expect(
      jsonDecode(timezoneProposal.fieldDiffJson),
      {
        'due_timezone': {
          'before': 'America/New_York',
          'after': 'America/Chicago',
        },
      },
    );
    final unchangedAssignment =
        await (runningApp.database.select(runningApp.database.assignments)
              ..where((row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    expect(
      unchangedAssignment.dueAt.toUtc(),
      environment.emailInitialAssignmentDueAt,
      reason: 'An update proposal must not mutate the canonical assignment.',
    );
    final unchangedTimezoneEvent =
        await (runningApp.database.select(runningApp.database.events)
              ..where((row) =>
                  row.id.equals(timezoneEventId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    expect(
      unchangedTimezoneEvent.startAt.toUtc(),
      environment.emailTimezoneEventStartAt,
    );
    expect(unchangedTimezoneEvent.timezone, JapanTime.timeZone);
    final sourcesAfterReplay =
        await (runningApp.database.select(runningApp.database.emailSources)
              ..where((row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.providerMessageId.equals('android-message-event-1')))
            .get();
    expect(sourcesAfterReplay, isEmpty);

    runningApp.container
        .read(routerProvider)
        .go('/email-import/update/${proposal.id}');
    await _waitFor(
      tester,
      find.byKey(const Key('email-update-review-list')),
      label: 'the explicit email update review screen',
    );
    await _waitFor(
      tester,
      find.byKey(const Key('email-update-diff-due_at')),
      label: 'the assignment deadline before/after diff',
    );
    await _tapEmailUpdateAction(
      tester,
      find.byKey(const Key('accept-email-update-button')),
      label: 'the explicit update acceptance action',
    );
    await _waitFor(
      tester,
      find.byKey(const Key('confirm-accept-email-update-button')),
      label: 'the update acceptance confirmation',
    );
    await _tap(
      tester,
      find.byKey(const Key('confirm-accept-email-update-button')),
    );
    await _waitForCondition(
      tester,
      () async {
        final row =
            await runningApp!.database.emailImportDao.candidateUpdateById(
          ownerUserId: ownerUserId,
          updateId: proposal.id,
        );
        return row?.state == 'accepted';
      },
      label: 'the atomically accepted update proposal',
    );
    final updatedAssignment =
        await (runningApp.database.select(runningApp.database.assignments)
              ..where((row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    expect(
      updatedAssignment.dueAt.toUtc(),
      environment.emailUpdatedAssignmentDueAt,
    );
    expect(updatedAssignment.courseId, correctedCourse.id);
    final acceptedAssignmentCandidate =
        await runningApp.database.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: assignmentCandidate.id,
    );
    final acceptedAssignmentPayload = const EmailCandidatePayloadCodec()
        .decode(acceptedAssignmentCandidate!.normalizedPayloadJson);
    expect(
      acceptedAssignmentPayload.courseHint.name,
      environment.emailCorrectedCourseName,
    );
    expect(
      acceptedAssignmentPayload.courseHint.code,
      environment.emailCorrectedCourseCode,
    );
    runningApp.container
        .read(routerProvider)
        .go('/email-import/update/${timezoneProposal.id}');
    await _waitFor(
      tester,
      find.byKey(const Key('email-update-review-list')),
      label: 'the timezone-only Event update review screen',
    );
    await _waitFor(
      tester,
      find.byKey(const Key('email-update-diff-due_timezone')),
      label: 'the explicit Event notification timezone diff',
    );
    await _tapEmailUpdateAction(
      tester,
      find.byKey(const Key('accept-email-update-button')),
      label: 'the explicit timezone-only Event update action',
    );
    await _waitFor(
      tester,
      find.byKey(const Key('confirm-accept-email-update-button')),
      label: 'the timezone-only Event update confirmation',
    );
    await _tap(
      tester,
      find.byKey(const Key('confirm-accept-email-update-button')),
    );
    await _waitForCondition(
      tester,
      () async =>
          (await runningApp!.database.emailImportDao.candidateUpdateById(
            ownerUserId: ownerUserId,
            updateId: timezoneProposal.id,
          ))
              ?.state ==
          'accepted',
      label: 'the atomically accepted timezone-only Event proposal',
    );
    final updatedTimezoneEvent =
        await (runningApp.database.select(runningApp.database.events)
              ..where((row) =>
                  row.id.equals(timezoneEventId) &
                  row.ownerUserId.equals(ownerUserId)))
            .getSingle();
    expect(
      updatedTimezoneEvent.startAt.toUtc(),
      environment.emailTimezoneEventStartAt,
    );
    expect(updatedTimezoneEvent.timezone, JapanTime.timeZone);
    final acceptedTimezoneEventCandidate =
        await runningApp.database.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: timezoneEventCandidate.id,
    );
    expect(
      const EmailCandidatePayloadCodec()
          .decode(acceptedTimezoneEventCandidate!.normalizedPayloadJson)
          .due
          .timezone,
      'America/Chicago',
    );
    final updatedTimezoneNotification = await (runningApp.database
            .select(runningApp.database.notificationScheduleRequests)
          ..where((row) => row.entityId.equals(timezoneEventId)))
        .getSingle();
    expect(updatedTimezoneNotification.timezone, 'America/Chicago');
    final updateMutations =
        (await runningApp.database.syncQueueDao.allMutations(ownerUserId))
            .where((row) =>
                row.entityType == 'assignment' &&
                row.entityId == assignmentId &&
                row.operation == 'update')
            .toList(growable: false);
    expect(updateMutations, hasLength(1));
    final timezoneUpdateMutations =
        (await runningApp.database.syncQueueDao.allMutations(ownerUserId))
            .where((row) =>
                row.entityType == 'event' &&
                row.entityId == timezoneEventId &&
                row.operation == 'update')
            .toList(growable: false);
    expect(timezoneUpdateMutations, hasLength(1));
    if (timezoneUpdateMutations.single.payloadJson != '{}') {
      expect(
        (jsonDecode(timezoneUpdateMutations.single.payloadJson)
            as Map<String, dynamic>)['timezone'],
        JapanTime.timeZone,
      );
    }
    await _synchronize(runningApp.container, clock: runningApp.clock);
    final syncedEmailMutations =
        await runningApp.database.syncQueueDao.allMutations(ownerUserId);
    final syncedUpdateMutations = syncedEmailMutations
        .where((row) =>
            row.entityType == 'assignment' &&
            row.entityId == assignmentId &&
            row.operation == 'update')
        .toList(growable: false);
    final syncedTimezoneUpdateMutations = syncedEmailMutations
        .where((row) =>
            row.entityType == 'event' &&
            row.entityId == timezoneEventId &&
            row.operation == 'update')
        .toList(growable: false);
    expect(syncedUpdateMutations, hasLength(1));
    expect(syncedTimezoneUpdateMutations, hasLength(1));
    _expectSyncedEmailMutation(
      syncedUpdateMutations.single,
      operation: 'update',
      label: 'the accepted assignment deadline update',
    );
    _expectSyncedEmailMutation(
      syncedTimezoneUpdateMutations.single,
      operation: 'update',
      label: 'the accepted Event notification timezone update',
    );
    expect(
      syncedEmailMutations.where(
        (row) =>
            {assignmentId, examId, timezoneEventId}.contains(row.entityId) &&
            const {
              'pending',
              'failed',
              'processing',
              'conflict',
              'quarantined',
            }.contains(row.status),
      ),
      isEmpty,
      reason: 'The accepted email update must leave no bad queue rows.',
    );
    await _drainEmailReconciliation(
      tester,
      runningApp,
      ownerUserId: ownerUserId,
      expectedActions: const {
        'confirmation': 3,
        'dismissal': 1,
        'update': 2,
      },
      gateway: reconciliationGateway,
    );
    await _assertRemoteEmailEntities(
      peerClient,
      ownerUserId: ownerUserId,
      environment: environment,
      expectedAssignmentId: assignmentId,
      expectedExamId: examId,
      expectedEventId: timezoneEventId,
      expectedAssignmentCourseId: correctedCourse.id,
      expectedAssignmentDueAt: environment.emailUpdatedAssignmentDueAt,
      expectedEventStartAt: environment.emailTimezoneEventStartAt,
    );
    await _signalRunnerMarker(environment, _emailUpdateVerifiedMarker);

    runningApp.container.read(routerProvider).go('/');
    await _waitFor(tester, find.text('2026 年度'),
        label: 'Home before owner switch');
    await _signOutThroughSettings(tester, container: runningApp.container);
    final secondSession = await appClient.auth.signInWithPassword(
      email: environment.secondEmail,
      password: environment.password,
    );
    final secondUserId = secondSession.user?.id;
    expect(secondUserId, isNotNull);
    expect(secondUserId, isNot(ownerUserId));
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.session
              ?.userId ==
          secondUserId,
      label: 'the active second-owner session for email isolation',
    );
    runningApp.container.read(routerProvider).go('/email-import');
    await _waitFor(
      tester,
      find.byKey(const Key('email-inbox-select-button')),
      label: 'the second-owner email candidate inbox',
    );
    await _waitFor(
      tester,
      find.text('確認待ち (0)'),
      label: 'the empty second-owner actionable email tab',
    );
    expect(find.text('履歴 (0)'), findsOneWidget);
    expect(find.text(environment.emailAssignmentTitle), findsNothing);
    expect(find.text(environment.emailExamTitle), findsNothing);
    expect(find.text(environment.emailTimezoneEventTitle), findsNothing);
    expect(find.text(environment.emailRetriedAnnouncementTitle), findsNothing);
    expect(
      find.byKey(Key('email-candidate-${assignmentCandidate.id}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('email-candidate-${examCandidate.id}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('email-candidate-${timezoneEventCandidate.id}')),
      findsNothing,
    );
    expect(
      find.byKey(Key('email-candidate-${retriedAnnouncementCandidate.id}')),
      findsNothing,
    );
    expect(find.byKey(Key('email-update-card-${proposal.id}')), findsNothing);
    expect(
      find.byKey(Key('email-update-card-${timezoneProposal.id}')),
      findsNothing,
    );
    await _tap(tester, find.text('履歴 (0)'));
    await _waitFor(
      tester,
      find.text('履歴はまだありません'),
      label: 'the empty second-owner email history',
    );
    expect(find.text(environment.emailAssignmentTitle), findsNothing);
    expect(find.text(environment.emailExamTitle), findsNothing);
    expect(find.text(environment.emailTimezoneEventTitle), findsNothing);
    await _assertOwnerHasNoEmailImportData(
      runningApp.database,
      ownerUserId: secondUserId!,
    );
    final secondOwnerReviewStore =
        runningApp.container.read(emailReviewStoreProvider);
    expect(
      await secondOwnerReviewStore.watchCandidates(secondUserId).first,
      isEmpty,
    );
    expect(
      await secondOwnerReviewStore.watchConnections(secondUserId).first,
      isEmpty,
    );

    final secondOwnerGateway = SupabaseScheduleGateway(client: appClient);
    final secondOwnerDelta = await secondOwnerGateway.pullDelta(
      ownerUserId: secondUserId,
      afterCursor: 0,
      limit: 200,
    );
    expect(
      secondOwnerDelta.changes.any(
        (change) =>
            {assignmentId, examId, timezoneEventId}.contains(change.entityId) ||
            {
              environment.emailAssignmentTitle,
              environment.emailExamTitle,
              environment.emailTimezoneEventTitle,
            }.contains(change.payload['title']),
      ),
      isFalse,
    );
    await expectLater(
      secondOwnerGateway.pullDelta(
        ownerUserId: ownerUserId,
        afterCursor: 0,
        limit: 200,
      ),
      throwsA(isA<RemoteScheduleAuthenticationException>()),
    );
    await _signalRunnerMarker(environment, _emailAccountIsolatedMarker);

    runningApp.container
        .read(pendingDeepLinkStoreProvider)
        .beginExplicitSignOut();
    await appClient.auth.signOut(scope: SignOutScope.local);
    final firstSession = await appClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(firstSession.user?.id, ownerUserId);
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.session
              ?.userId ==
          ownerUserId,
      label: 'the first owner session after isolation proof',
    );
    runningApp.container.read(routerProvider).go('/');
    await tester.pump();
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'email cleanup after the owner-isolation proof',
    );
    runningApp.container.read(routerProvider).go('/settings/email-import');
    await _waitFor(
      tester,
      find.byKey(const Key('email-connection-card')),
      label: 'the first owner Gmail connection before cleanup',
    );
    await _tap(tester, find.byKey(const Key('email-disconnect-button')));
    await _waitFor(
      tester,
      find.byKey(const Key('delete-email-derived-data-checkbox')),
      label: 'the derived-data-only disconnect choice',
    );
    await _tap(
      tester,
      find.byKey(const Key('delete-email-derived-data-checkbox')),
    );
    await _tap(
      tester,
      find.byKey(const Key('confirm-email-disconnect-button')),
    );
    await _waitForCondition(
      tester,
      () async =>
          await runningApp!.database.emailImportDao.connectionById(
            ownerUserId: ownerUserId,
            connectionId: _androidEmailConnectionId,
          ) ==
          null,
      label: 'the deleted first-owner derived email cache',
    );
    expect(
      await (runningApp.database.select(runningApp.database.emailConnections)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    expect(
      await (runningApp.database.select(runningApp.database.emailSources)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    expect(
      await (runningApp.database.select(runningApp.database.emailCandidates)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    expect(
      await (runningApp.database
              .select(runningApp.database.emailCandidateUpdates)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    expect(
      await (runningApp.database
              .select(runningApp.database.emailScheduleEntityLinks)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    expect(
      await (runningApp.database
              .select(runningApp.database.emailReconciliationReceipts)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get(),
      isEmpty,
    );
    final retainedTombstones = await (runningApp.database
            .select(runningApp.database.emailDismissalTombstones)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get();
    expect(retainedTombstones, hasLength(1));
    final retainedTombstone = retainedTombstones.single;
    final retainedHashes = <String>[
      retainedTombstone.providerAccountHash,
      retainedTombstone.providerMessageIdHash,
      retainedTombstone.providerThreadIdHash,
      retainedTombstone.sanitizedContentHash,
      retainedTombstone.semanticFingerprint,
    ];
    for (final hash in retainedHashes) {
      expect(hash, matches(RegExp(r'^[a-f0-9]{64}$')));
    }
    final minimalDismissalMemory = retainedHashes.join('|');
    for (final forbiddenRawValue in <String>[
      'android-message-event-1',
      'android-thread-event',
      environment.emailDismissedEventTitle,
      environment.emailAssignmentTitle,
      environment.emailCorrectedCourseName,
      environment.emailTimezoneEventTitle,
      environment.emailRetriedAnnouncementTitle,
      '説明会を開催します',
    ]) {
      expect(minimalDismissalMemory, isNot(contains(forbiddenRawValue)));
    }
    final canonicalAssignment =
        await (runningApp.database.select(runningApp.database.assignments)
              ..where((row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull()))
            .getSingleOrNull();
    final canonicalExam =
        await (runningApp.database.select(runningApp.database.exams)
              ..where((row) =>
                  row.id.equals(examId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull()))
            .getSingleOrNull();
    final canonicalTimezoneEvent =
        await (runningApp.database.select(runningApp.database.events)
              ..where((row) =>
                  row.id.equals(timezoneEventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull()))
            .getSingleOrNull();
    expect(canonicalAssignment?.title, environment.emailAssignmentTitle);
    expect(canonicalAssignment?.courseId, correctedCourse.id);
    expect(canonicalExam?.title, environment.emailExamTitle);
    expect(canonicalTimezoneEvent?.title, environment.emailTimezoneEventTitle);
    expect(canonicalTimezoneEvent?.timezone, JapanTime.timeZone);
    await _assertRemoteEmailEntities(
      peerClient,
      ownerUserId: ownerUserId,
      environment: environment,
      expectedAssignmentId: assignmentId,
      expectedExamId: examId,
      expectedEventId: timezoneEventId,
      expectedAssignmentCourseId: correctedCourse.id,
      expectedAssignmentDueAt: environment.emailUpdatedAssignmentDueAt,
      expectedEventStartAt: environment.emailTimezoneEventStartAt,
    );
    await _signalRunnerMarker(environment, _emailCleanupVerifiedMarker);
  } finally {
    await runningApp?.dispose(tester);
    await peerClient.dispose();
  }
}

Future<void> _tapEmailUpdateAction(
  WidgetTester tester,
  Finder action, {
  required String label,
}) async {
  await _waitFor(tester, action, label: label);
  await _waitFor(
    tester,
    action.hitTestable(),
    label: 'the hit-testable $label footer',
  );
  final hitTarget = action.hitTestable();
  expect(hitTarget, findsOneWidget);
  await tester.tap(hitTarget);
  await tester.pump();
}

Future<void> _drainEmailReconciliation(
  WidgetTester tester,
  _RunningApp runningApp, {
  required String ownerUserId,
  required Map<String, int> expectedActions,
  required _AndroidEmailReconciliationGateway gateway,
}) async {
  expect(
    runningApp.container.read(emailReconciliationRuntimeProvider).phase,
    EmailReconciliationRuntimePhase.disabled,
    reason: 'The production runtime must stay inert under the false flag.',
  );
  // Invoke the fake gateway through its service explicitly. This exercises
  // reconciliation without enabling production composition or its flag.
  var result = await runningApp.container
      .read(emailReconciliationServiceProvider)
      .synchronize(ownerUserId: ownerUserId, networkAvailable: true);
  if (gateway.hasPendingLostResponse) {
    expect(result.failed, 1);
    final lostKey = gateway.lostResponseIdempotencyKey!;
    final pendingReplay = await (runningApp.database
            .select(runningApp.database.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.idempotencyKey.equals(lostKey)))
        .getSingle();
    expect(pendingReplay.state, 'pending');
    expect(pendingReplay.attemptCount, 1);
    expect(pendingReplay.errorCategory, EmailErrorCategory.timeout.wireName);
    final retryAt = pendingReplay.nextRetryAt!;
    final retryDelay = retryAt.difference(runningApp.clock.now().toUtc());
    if (retryDelay > Duration.zero) runningApp.clock.advance(retryDelay);
    result = await runningApp.container
        .read(emailReconciliationServiceProvider)
        .synchronize(ownerUserId: ownerUserId, networkAvailable: true);
    expect(result.failed, 0);
    final replayedReceipt = await (runningApp.database
            .select(runningApp.database.emailReconciliationReceipts)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.idempotencyKey.equals(lostKey)))
        .getSingle();
    expect(replayedReceipt.state, 'succeeded');
    expect(replayedReceipt.attemptCount, 2);
    expect(replayedReceipt.replayed, isTrue);
    expect(replayedReceipt.errorCategory, isNull);
    expect(gateway.replayedResponseCount, 1);
  } else {
    expect(result.failed, 0);
  }
  await _waitForCondition(
    tester,
    () async {
      final rows = await (runningApp.database
              .select(runningApp.database.emailReconciliationReceipts)
            ..where((row) => row.ownerUserId.equals(ownerUserId)))
          .get();
      for (final entry in expectedActions.entries) {
        final matching = rows
            .where((row) => row.action == entry.key)
            .toList(growable: false);
        if (matching.length != entry.value ||
            matching.any((row) => row.state != 'succeeded')) {
          return false;
        }
      }
      return true;
    },
    label: 'the durable email reconciliation receipts to be acknowledged',
  );
}

Future<void> _assertOwnerHasNoEmailImportData(
  AppDatabase database, {
  required String ownerUserId,
}) async {
  expect(
    await (database.select(database.emailConnections)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailSources)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailCandidates)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailCandidateUpdates)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailDismissalTombstones)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailScheduleEntityLinks)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
  expect(
    await (database.select(database.emailReconciliationReceipts)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get(),
    isEmpty,
  );
}

Future<void> _assertRemoteEmailEntities(
  SupabaseClient peerClient, {
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
  required String expectedAssignmentId,
  required String expectedExamId,
  required String expectedEventId,
  required String expectedAssignmentCourseId,
  required DateTime expectedAssignmentDueAt,
  required DateTime expectedEventStartAt,
}) async {
  final changes = await _loadAllScheduleDelta(
    peerClient,
    ownerUserId: ownerUserId,
  );
  final assignments = changes
      .where((change) =>
          change.entityType == 'assignment' &&
          change.entityId == expectedAssignmentId &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.deletedAt == null)
      .toList(growable: false);
  final exams = changes
      .where((change) =>
          change.entityType == 'exam' &&
          change.entityId == expectedExamId &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.deletedAt == null)
      .toList(growable: false);
  final events = changes
      .where((change) =>
          change.entityType == 'event' &&
          change.entityId == expectedEventId &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.deletedAt == null)
      .toList(growable: false);
  expect(assignments, isNotEmpty);
  expect(exams, hasLength(1));
  expect(events, isNotEmpty);
  final assignment = assignments.last;
  final exam = exams.single;
  final event = events.last;
  expect(assignment.payload['id'], expectedAssignmentId);
  expect(assignment.payload['ownerUserId'], ownerUserId);
  expect(assignment.payload['title'], environment.emailAssignmentTitle);
  expect(assignment.payload['courseId'], expectedAssignmentCourseId);
  expect(
    assignment.payload['visibilityLevel'],
    VisibilityLevel.private.wireName,
  );
  _expectUtcPayloadInstant(
    assignment.payload['dueAt'],
    expectedAssignmentDueAt,
  );
  expect(exam.payload['id'], expectedExamId);
  expect(exam.payload['ownerUserId'], ownerUserId);
  expect(exam.payload['title'], environment.emailExamTitle);
  expect(exam.payload['visibilityLevel'], VisibilityLevel.private.wireName);
  expect(event.payload['id'], expectedEventId);
  expect(event.payload['ownerUserId'], ownerUserId);
  expect(event.payload['title'], environment.emailTimezoneEventTitle);
  expect(event.payload['visibilityLevel'], VisibilityLevel.private.wireName);
  expect(event.payload['timezone'], JapanTime.timeZone);
  _expectUtcPayloadInstant(event.payload['startAt'], expectedEventStartAt);
}

Future<void> _runRoutineOfflinePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
}) async {
  _RunningApp? runningApp;

  try {
    expect(
      appClient.auth.currentSession?.user.id,
      isNotNull,
      reason:
          'The offline routine phase must retain the authenticated local session.',
    );
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.isSignedIn ==
          true,
      label: 'the restored authenticated session before offline routine edits',
    );
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label: 'the restored onboarding state before offline routine edits',
    );
    final onboarding = runningApp.container.read(onboardingControllerProvider);
    expect(
      onboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason:
          'The offline routine phase requires a completed locally cached bootstrap.',
    );
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'the authenticated Home before offline routine edits',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
    final ownerUserId = appClient.auth.currentUser?.id;
    expect(ownerUserId, isNotNull);
    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext?.ownerUserId, ownerUserId);
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      label: 'the online routine-edit bootstrap state',
    );

    // The runner takes the selected emulator offline only after this fixed,
    // non-secret marker. The routine and its child exception must therefore
    // survive the subsequent Android process restart as actionable rows.
    await _signalRunnerMarker(environment, _routineOfflineReadyMarker);
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: false,
      label: 'the runner-controlled offline routine queue state',
    );
    await _createRoutineWithCancelledException(
      tester,
      runningApp.container,
      title: environment.routineTitle,
    );
    await _assertQueuedRoutineException(
      runningApp.database,
      ownerUserId: ownerUserId!,
      routineTitle: environment.routineTitle,
      expectedMode: EventExceptionMode.cancelled,
    );
    // The runner keeps the selected emulator offline until this asserted
    // parent/child queue milestone and the monthly counterpart both finish.
    // Signal this durable midpoint so each real UI slice has its own existing
    // liveness window without changing the Android E2E timeout.
    await _signalRunnerMarker(
      environment,
      _routineOfflineFirstMutationQueuedMarker,
    );
    await _createMonthlyRoutineWithModifiedException(
      tester,
      runningApp.container,
      title: environment.monthlyRoutineTitle,
      overrideLocation: environment.monthlyRoutineOverrideLocation,
    );
    await _assertQueuedRoutineException(
      runningApp.database,
      ownerUserId: ownerUserId,
      routineTitle: environment.monthlyRoutineTitle,
      expectedMode: EventExceptionMode.modified,
      expectedOverrideLocation: environment.monthlyRoutineOverrideLocation,
    );
    await _signalRunnerMarker(environment, _routineOfflineMutationQueuedMarker);
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<void> _runRestartOfflinePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
}) async {
  final peerTransport = ScheduleSyncDeadlineHttpClient();
  final peerClient = _newPublicClient(
    environment,
    httpClient: peerTransport,
  );
  _RunningApp? runningApp;

  try {
    expect(
      appClient.auth.currentSession?.user.id,
      isNotNull,
      reason:
          'The Android process restart must retain the authenticated local session.',
    );
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.isSignedIn ==
          true,
      label:
          'the restored authenticated session after the Android process restart',
    );
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label:
          'the restored onboarding bootstrap after the Android process restart',
    );
    final restoredOnboarding = runningApp.container.read(
      onboardingControllerProvider,
    );
    expect(
      restoredOnboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason:
          'The offline restart must use only a valid locally cached completed bootstrap.',
    );
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'the authenticated Home after the Android process restart',
    );
    final firstUserId = appClient.auth.currentUser?.id;
    expect(firstUserId, isNotNull);
    final ownerUserId = firstUserId!;
    expect(appClient.auth.currentUser?.email?.toLowerCase(),
        environment.firstEmail);

    await _assertRestoredFirstUserData(tester, environment: environment);
    final cursorBeforeRoutineReconnect =
        await runningApp.database.syncQueueDao.readCursor(ownerUserId);
    expect(cursorBeforeRoutineReconnect, greaterThan(0));
    await _assertQueuedRoutineException(
      runningApp.database,
      ownerUserId: ownerUserId,
      routineTitle: environment.routineTitle,
      expectedMode: EventExceptionMode.cancelled,
    );
    await _assertQueuedRoutineException(
      runningApp.database,
      ownerUserId: ownerUserId,
      routineTitle: environment.monthlyRoutineTitle,
      expectedMode: EventExceptionMode.modified,
      expectedOverrideLocation: environment.monthlyRoutineOverrideLocation,
    );

    // This phase starts with the selected emulator still offline. The runner
    // restores it only after the durable parent/child queue order above has
    // been observed from the restarted process.
    await _signalRunnerMarker(environment, _routineRestartQueueVerifiedMarker);
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      label: 'the runner-restored routine queue network',
    );
    // The offline parent can have a retry deadline from the prior process.
    // Advance the injected clock before asking the restarted runtime to drain.
    runningApp.clock.advance(const Duration(minutes: 1));
    await _synchronize(runningApp.container, clock: runningApp.clock);

    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    final peerGateway = SupabaseScheduleGateway(client: peerClient);
    final routineDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: cursorBeforeRoutineReconnect,
      limit: 500,
    );
    expect(routineDelta.hasMore, isFalse);
    final syncedRoutine = routineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.routineTitle,
    );
    final syncedRoutineException = routineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event_exception' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['eventId'] == syncedRoutine.entityId,
    );
    expect(
      syncedRoutine.changeCursor,
      lessThan(syncedRoutineException.changeCursor),
    );
    _expectUtcPayloadInstant(
      syncedRoutine.payload['startAt'],
      _defaultFormStart(environment),
    );
    _expectUtcPayloadInstant(
      syncedRoutineException.payload['recurrenceId'],
      _defaultFormStart(environment),
    );
    final syncedMonthlyRoutine = routineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.monthlyRoutineTitle,
    );
    final syncedMonthlyRoutineException = routineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event_exception' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['eventId'] == syncedMonthlyRoutine.entityId,
    );
    expect(
      syncedMonthlyRoutine.changeCursor,
      lessThan(syncedMonthlyRoutineException.changeCursor),
    );
    _expectUtcPayloadInstant(
      syncedMonthlyRoutine.payload['startAt'],
      _defaultFormStart(environment),
    );
    _expectUtcPayloadInstant(
      syncedMonthlyRoutineException.payload['recurrenceId'],
      _defaultFormStart(environment),
    );
    await _assertRoutineAndExceptionRemote(
      appClient,
      ownerUserId: ownerUserId,
      title: environment.routineTitle,
      environment: environment,
    );
    await _assertMonthlyRoutineAndModifiedExceptionRemote(
      appClient,
      ownerUserId: ownerUserId,
      title: environment.monthlyRoutineTitle,
      overrideLocation: environment.monthlyRoutineOverrideLocation,
      environment: environment,
    );

    // The runner observes only these fixed, non-secret markers. It then
    // disables and restores networking on the explicitly selected emulator.
    await _signalRunnerMarker(environment, _offlineReadyMarker);
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: false,
      label: 'the runner-controlled offline emulator state',
    );
    await _signalRunnerMarker(environment, _offlineNetworkDisabledMarker);

    await _updatePersonalEvent(
      tester,
      currentTitle: environment.syncedPersonalEventTitle,
      updatedTitle: environment.updatedOfflineEventTitle,
    );
    await _signalRunnerMarker(environment, _offlineEventUpdatedMarker);
    await runningApp.container
        .read(scheduleSyncRuntimeProvider.notifier)
        .trigger(SyncTrigger.manual);
    await _waitForSyncPhase(
      tester,
      runningApp.container,
      ScheduleSyncPhase.waitingToRetry,
      label: 'a transient offline sync state',
    );
    final offlineSyncStatus = runningApp.container.read(
      scheduleSyncRuntimeProvider,
    );
    expect(offlineSyncStatus.nextRetryAt, isNotNull);
    await _waitFor(
      tester,
      find.byKey(const Key('schedule-sync-status-banner')),
      label: 'the common offline sync status banner',
    );
    expect(
      find.text('接続できないため同期を待機中です。変更はこの端末に保存されています。'),
      findsOneWidget,
    );
    await _assertQueuedOfflineEventUpdate(
      runningApp.database,
      ownerUserId: ownerUserId,
      title: environment.updatedOfflineEventTitle,
    );
    await _signalRunnerMarker(environment, _offlineQueueDurableMarker);
    await _openSettingsScheduleSync(tester);
    await _waitFor(
      tester,
      find.text('状態: waitingToRetry'),
      label: 'the offline sync state in Settings',
    );
    await _waitFor(
      tester,
      find.text('event update'),
      label: 'the queued offline event update in Settings',
    );
    await _signalRunnerMarker(environment, _offlineSettingsRenderedMarker);

    await _signalRunnerMarker(environment, _offlineMutationQueuedMarker);
  } finally {
    await runningApp?.dispose(tester);
    await peerClient.dispose();
    peerTransport.close();
  }
}

Future<void> _runEventConvergencePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  final peerTransport = ScheduleSyncDeadlineHttpClient();
  final peerClient = _newPublicClient(
    environment,
    httpClient: peerTransport,
  );
  final inbox = _LocalMailpitInbox(environment.mailpitUrl);
  _RunningApp? runningApp;

  try {
    final restoredSession = appClient.auth.currentSession;
    expect(
      restoredSession?.user.id,
      isNotNull,
      reason:
          'The convergence phase must retain the authenticated local session.',
    );
    final ownerUserId = restoredSession!.user.id;
    expect(
      restoredSession.user.email?.toLowerCase(),
      environment.firstEmail,
    );

    // Keep the old runtime offline until it has exited, then capture the
    // server baseline before the new app pump can launch startup recovery.
    await _waitForLocalSupabaseReachability(
      environment,
      reachable: true,
      requiredConsecutiveSuccesses: 2,
      probeClient: appTransport,
      label: 'the restored app transport before convergence startup',
    );
    final authenticatedProfile = await appClient
        .from('profiles')
        .select('user_id')
        .eq('user_id', ownerUserId)
        .maybeSingle();
    expect(authenticatedProfile, isNotNull);
    expect(
      Map<String, Object?>.from(authenticatedProfile! as Map)['user_id'],
      ownerUserId,
    );

    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    final peerGateway = SupabaseScheduleGateway(client: peerClient);
    final baselineDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: 0,
      limit: 500,
    );
    expect(baselineDelta.hasMore, isFalse);
    final baselineCursor = baselineDelta.nextCursor;
    final syncedPersonalEvent = baselineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.syncedPersonalEventTitle,
    );
    expect(syncedPersonalEvent.payload['location'], 'E2E 同期済み');
    expect(syncedPersonalEvent.deletedAt, isNull);
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now,
    );
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.isSignedIn ==
          true,
      label: 'the restored authenticated session before convergence',
    );
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label: 'the restored onboarding state before convergence',
    );
    final restoredOnboarding = runningApp.container.read(
      onboardingControllerProvider,
    );
    expect(
      restoredOnboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason:
          'The convergence phase requires a completed locally cached bootstrap.',
    );
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'the authenticated Home before convergence',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
    final activeContext =
        runningApp.container.read(activeScheduleContextProvider);
    expect(activeContext?.ownerUserId, ownerUserId);
    await _assertQueuedOfflineEventUpdate(
      runningApp.database,
      ownerUserId: ownerUserId,
      title: environment.updatedOfflineEventTitle,
    );

    // The durable retry is scheduled against the injected test clock. Move it
    // beyond the failed attempt before manually exercising reconnect sync.
    runningApp.clock.advance(const Duration(minutes: 1));
    await _synchronize(runningApp.container, clock: runningApp.clock);

    final updateDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: baselineCursor,
      limit: 500,
    );
    expect(updateDelta.hasMore, isFalse);
    final updatedOfflineEvent = updateDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.entityId == syncedPersonalEvent.entityId &&
          change.operation == ScheduleDeltaOperation.upsert,
    );
    expect(
      updatedOfflineEvent.payload['title'],
      environment.updatedOfflineEventTitle,
    );
    expect(updatedOfflineEvent.payload['location'], 'E2E 更新済み');
    expect(updatedOfflineEvent.deletedAt, isNull);
    expect(
      updatedOfflineEvent.serverVersion,
      greaterThan(syncedPersonalEvent.serverVersion),
    );

    await _openNavigationDestination(tester, 'カレンダー');
    await _deletePersonalEvent(
      tester,
      title: environment.updatedOfflineEventTitle,
    );
    await _synchronize(runningApp.container, clock: runningApp.clock);
    final deleteDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: updateDelta.nextCursor,
      limit: 500,
    );
    expect(deleteDelta.hasMore, isFalse);
    final deletedOfflineEvent = deleteDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.entityId == syncedPersonalEvent.entityId &&
          change.operation == ScheduleDeltaOperation.delete,
    );
    expect(deletedOfflineEvent.deletedAt, isNotNull);
    expect(deletedOfflineEvent.payload['deletedAt'], isNotNull);
    expect(
      deletedOfflineEvent.payload['title'],
      environment.updatedOfflineEventTitle,
    );
    expect(
      deletedOfflineEvent.serverVersion,
      greaterThan(updatedOfflineEvent.serverVersion),
    );

    await _signOutThroughSettings(tester, container: runningApp.container);
    await _signInWithMagicLink(
      tester,
      client: appClient,
      container: runningApp.container,
      inbox: inbox,
      email: environment.firstEmail,
    );
    await _waitForCondition(
      tester,
      () =>
          runningApp!.container
              .read(authStateProvider)
              .valueOrNull
              ?.session
              ?.userId ==
          ownerUserId,
      label: 'the first-user auth state after magic-link login',
    );
    await _waitForCondition(
      tester,
      () {
        final onboarding =
            runningApp!.container.read(onboardingControllerProvider);
        return onboarding.valueOrNull?.hasActiveSchedule == true ||
            onboarding.hasError;
      },
      label: 'the first-user onboarding restore after magic-link login',
    );
    final reauthenticatedOnboarding = runningApp.container.read(
      onboardingControllerProvider,
    );
    expect(
      reauthenticatedOnboarding.valueOrNull?.hasActiveSchedule,
      isTrue,
      reason:
          'The reauthenticated first user must restore a completed onboarding profile (error type: ${reauthenticatedOnboarding.hasError ? reauthenticatedOnboarding.error.runtimeType : 'none'}).',
    );
    await _waitFor(
      tester,
      find.text('2026 年度'),
      label: 'Home after logout and magic-link login',
      diagnostic: () => _safeReauthenticationDiagnostic(runningApp!.container),
    );
  } finally {
    await runningApp?.dispose(tester);
    inbox.close();
    await peerClient.dispose();
    peerTransport.close();
  }
}

Future<void> _runAssignmentExamConvergencePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  final peerTransport = ScheduleSyncDeadlineHttpClient();
  final peerClient = _newPublicClient(
    environment,
    httpClient: peerTransport,
  );
  _RunningApp? runningApp;

  try {
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the assignment and exam convergence boundary',
    );
    final peerSession = await peerClient.auth.signInWithPassword(
      email: environment.firstEmail,
      password: environment.password,
    );
    expect(peerSession.user?.id, ownerUserId);
    final peerGateway = SupabaseScheduleGateway(client: peerClient);
    final baselineDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: 0,
      limit: 500,
    );
    expect(baselineDelta.hasMore, isFalse);
    final deletedPersonalEvent = baselineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'event' &&
          change.operation == ScheduleDeltaOperation.delete &&
          change.payload['title'] == environment.updatedOfflineEventTitle,
    );
    expect(deletedPersonalEvent.deletedAt, isNotNull);
    expect(deletedPersonalEvent.payload['deletedAt'], isNotNull);
    final assignmentForEdit = baselineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'assignment' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.assignmentTitle,
    );
    final courseLinkedExamForEdit = baselineDelta.changes.singleWhere(
      (change) =>
          change.entityType == 'exam' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == environment.courseLinkedExamTitle,
    );

    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now.add(const Duration(minutes: 1)),
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'assignment and exam convergence',
    );
    await _openNavigationDestination(tester, '課題・テスト');
    await _selectSubmittedAssignmentFilter(
      tester,
      label: 'the submitted assignment filter after the process boundary',
    );
    await _waitFor(
      tester,
      find.textContaining('提出済み · 履歴に保存'),
      label: 'the first user submitted assignment history after restart',
    );
    expect(find.text(environment.assignmentTitle), findsOneWidget);

    await _editAndDeleteSubmittedAssignment(
      tester,
      currentTitle: environment.assignmentTitle,
      updatedTitle: environment.updatedAssignmentTitle,
    );
    await _editAndDeleteCourseLinkedExam(
      tester,
      currentTitle: environment.courseLinkedExamTitle,
      updatedTitle: environment.updatedCourseLinkedExamTitle,
    );
    await _synchronize(runningApp.container, clock: runningApp.clock);
    final editedAndDeletedDelta = await peerGateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: baselineDelta.nextCursor,
      limit: 200,
    );
    expect(editedAndDeletedDelta.hasMore, isFalse);
    _assertRemoteEntityUpdatedThenDeleted(
      editedAndDeletedDelta.changes,
      entityType: 'assignment',
      entityId: assignmentForEdit.entityId,
      updatedTitle: environment.updatedAssignmentTitle,
      expectClearedCourseLink: true,
    );
    _assertRemoteEntityUpdatedThenDeleted(
      editedAndDeletedDelta.changes,
      entityType: 'exam',
      entityId: courseLinkedExamForEdit.entityId,
      updatedTitle: environment.updatedCourseLinkedExamTitle,
      expectClearedCourseLink: true,
    );
  } finally {
    await runningApp?.dispose(tester);
    await peerClient.dispose();
    peerTransport.close();
  }
}

Future<void> _runUniversityTermConvergencePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  _RunningApp? runningApp;

  try {
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the university and term convergence boundary',
    );
    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now.add(const Duration(minutes: 1)),
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'university and term convergence',
    );

    await _createAndVerifyUniversityRequest(
      tester,
      client: appClient,
      ownerUserId: ownerUserId,
      environment: environment,
    );
    await _createAndVerifyCustomTermPeriod(
      tester,
      container: runningApp.container,
      client: appClient,
      ownerUserId: ownerUserId,
      environment: environment,
    );
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<void> _runSecondUserConvergencePhase(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
  required AppConfig config,
  required SupabaseClient appClient,
  required SecureAuthLocalStorage sessionStorage,
  required http.Client appTransport,
}) async {
  _RunningApp? runningApp;

  try {
    final ownerUserId = await _verifyRestoredFirstUserBoundary(
      environment: environment,
      appClient: appClient,
      appTransport: appTransport,
      label: 'the second-user isolation boundary',
    );
    final requestRow = await appClient
        .from('university_requests')
        .select('id,requested_by,name,status')
        .eq('requested_by', ownerUserId)
        .eq('name', environment.universityRequestTitle)
        .eq('status', 'pending')
        .maybeSingle();
    expect(requestRow, isNotNull);
    final universityRequest = Map<String, Object?>.from(requestRow! as Map);
    final universityRequestId = universityRequest['id'];
    expect(universityRequestId, isA<String>());
    expect(universityRequest['requested_by'], ownerUserId);
    expect(universityRequest['name'], environment.universityRequestTitle);
    expect(universityRequest['status'], 'pending');

    final profileRow = await appClient
        .from('profiles')
        .select('user_id,active_term_id')
        .eq('user_id', ownerUserId)
        .single();
    final profile = Map<String, Object?>.from(profileRow);
    expect(profile['user_id'], ownerUserId);
    final rawPersonalTermId = profile['active_term_id'];
    expect(rawPersonalTermId, isA<String>());
    final personalTermId = rawPersonalTermId as String;
    final termRow = await appClient
        .from('terms')
        .select('id,owner_user_id,name,status,deleted_at')
        .eq('id', personalTermId)
        .single();
    final personalTerm = Map<String, Object?>.from(termRow);
    expect(personalTerm['id'], personalTermId);
    expect(personalTerm['owner_user_id'], ownerUserId);
    expect(personalTerm['name'], environment.customTermTitle);
    expect(personalTerm['status'], 'active');
    expect(personalTerm['deleted_at'], isNull);

    runningApp = await _RunningApp.start(
      tester,
      config: config,
      client: appClient,
      sessionStorage: sessionStorage,
      now: environment.now.add(const Duration(minutes: 1)),
    );
    await _verifyRestoredFirstUserApp(
      tester,
      runningApp: runningApp,
      ownerUserId: ownerUserId,
      label: 'second-user isolation',
    );
    expect(
      runningApp.container.read(activeScheduleContextProvider)?.termId,
      personalTermId,
    );

    await _signOutThroughSettings(tester, container: runningApp.container);
    final secondSession = await appClient.auth.signInWithPassword(
      email: environment.secondEmail,
      password: environment.password,
    );
    final secondUserId = secondSession.user?.id;
    expect(secondUserId, isNotNull);
    expect(secondUserId, isNot(ownerUserId));
    await _waitFor(
      tester,
      find.text('初期設定'),
      label: 'onboarding for the second user',
    );
    expect(find.text(environment.manualCourseTitle), findsNothing);
    expect(find.text(environment.assignmentTitle), findsNothing);
    expect(find.text(environment.courseLinkedExamTitle), findsNothing);
    expect(find.text(environment.standaloneExamTitle), findsNothing);
    expect(find.text(environment.syncedPersonalEventTitle), findsNothing);
    expect(find.text(environment.updatedOfflineEventTitle), findsNothing);
    await _completeUnsupportedCampusCustomOnboarding(
      tester,
      container: runningApp.container,
      database: runningApp.database,
      client: appClient,
      ownerUserId: secondUserId!,
    );
    await _waitFor(
      tester,
      find.text('授業 0'),
      label: 'an empty second-user Home',
    );
    expect(find.text(environment.manualCourseTitle), findsNothing);
    expect(find.text(environment.assignmentTitle), findsNothing);
    expect(find.text(environment.courseLinkedExamTitle), findsNothing);
    expect(find.text(environment.standaloneExamTitle), findsNothing);
    expect(find.text(environment.syncedPersonalEventTitle), findsNothing);
    expect(find.text(environment.updatedOfflineEventTitle), findsNothing);
    await _assertSecondUserCannotReadFirstUserUniversityRequest(
      appClient,
      requestId: universityRequestId as String,
    );
    await _assertSecondUserCannotReadFirstUserTerm(
      appClient,
      termId: personalTermId,
    );

    final firstUserTitles = <String>{
      environment.templateTitle,
      environment.manualCourseTitle,
      environment.assignmentTitle,
      environment.courseLinkedExamTitle,
      environment.standaloneExamTitle,
      environment.routineTitle,
      environment.monthlyRoutineTitle,
      environment.syncedPersonalEventTitle,
      environment.updatedOfflineEventTitle,
    };
    final secondUserDelta = await SupabaseScheduleGateway(
      client: appClient,
    ).pullDelta(
      ownerUserId: secondUserId,
      afterCursor: 0,
      limit: 200,
    );
    expect(
      secondUserDelta.changes.any(
        (change) => firstUserTitles.contains(change.payload['title']),
      ),
      isFalse,
    );
  } finally {
    await runningApp?.dispose(tester);
  }
}

Future<String> _verifyRestoredFirstUserBoundary({
  required _AndroidE2eEnvironment environment,
  required SupabaseClient appClient,
  required http.Client appTransport,
  required String label,
}) async {
  final restoredSession = appClient.auth.currentSession;
  expect(
    restoredSession?.user.id,
    isNotNull,
    reason: '$label must retain the authenticated local session.',
  );
  final ownerUserId = restoredSession!.user.id;
  expect(restoredSession.user.email?.toLowerCase(), environment.firstEmail);
  await _waitForLocalSupabaseReachability(
    environment,
    reachable: true,
    requiredConsecutiveSuccesses: 2,
    probeClient: appTransport,
    label: label,
  );
  final authenticatedProfile = await appClient
      .from('profiles')
      .select('user_id')
      .eq('user_id', ownerUserId)
      .maybeSingle();
  expect(authenticatedProfile, isNotNull);
  expect(
    Map<String, Object?>.from(authenticatedProfile! as Map)['user_id'],
    ownerUserId,
  );
  return ownerUserId;
}

Future<void> _verifyRestoredFirstUserApp(
  WidgetTester tester, {
  required _RunningApp runningApp,
  required String ownerUserId,
  required String label,
}) async {
  await _waitForCondition(
    tester,
    () =>
        runningApp.container.read(authStateProvider).valueOrNull?.isSignedIn ==
        true,
    label: 'the restored authenticated session for $label',
  );
  await _waitForCondition(
    tester,
    () {
      final onboarding = runningApp.container.read(
        onboardingControllerProvider,
      );
      return onboarding.valueOrNull?.hasActiveSchedule == true ||
          onboarding.hasError;
    },
    label: 'the restored onboarding state for $label',
  );
  final restoredOnboarding = runningApp.container.read(
    onboardingControllerProvider,
  );
  expect(
    restoredOnboarding.valueOrNull?.hasActiveSchedule,
    isTrue,
    reason:
        '$label requires a completed locally cached bootstrap (error type: ${restoredOnboarding.hasError ? restoredOnboarding.error.runtimeType : 'none'}).',
  );
  await _waitFor(
    tester,
    find.text('2026 年度'),
    label: 'the authenticated Home for $label',
    diagnostic: () => _safeReauthenticationDiagnostic(runningApp.container),
  );
  expect(
    runningApp.container.read(activeScheduleContextProvider)?.ownerUserId,
    ownerUserId,
  );
}

class _AndroidE2eEnvironment {
  const _AndroidE2eEnvironment({
    required this.supabaseUrl,
    required this.mailpitUrl,
    required this.publishableKey,
    required this.deepLinkScheme,
    required this.now,
    required this.phase,
    required this.runId,
  });

  factory _AndroidE2eEnvironment.fromCompileTime() {
    const enabled = bool.fromEnvironment('ANDROID_PERSONAL_E2E');
    const rawSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
    const rawMailpitUrl = String.fromEnvironment('LOCAL_MAILPIT_URL');
    const publishableKey = String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    );
    const deepLinkScheme = String.fromEnvironment('APP_DEEP_LINK_SCHEME');
    const rawNow = String.fromEnvironment('ANDROID_E2E_NOW');
    const rawPhase = String.fromEnvironment('ANDROID_E2E_PHASE');
    const runId = String.fromEnvironment('ANDROID_E2E_RUN_ID');
    if (!enabled) {
      throw StateError(
        'Run this test through run_android_personal_management_e2e.sh.',
      );
    }
    final supabaseUrl = Uri.tryParse(rawSupabaseUrl);
    final mailpitUrl = Uri.tryParse(rawMailpitUrl);
    if (!_isEmulatorLocalHttp(supabaseUrl) ||
        !_isEmulatorLocalHttp(mailpitUrl)) {
      throw StateError(
        'Android E2E accepts only local emulator transports over HTTP.',
      );
    }
    if (publishableKey.trim().isEmpty) {
      throw StateError('A local public Supabase client key is required.');
    }
    if (deepLinkScheme != 'unischedule-staging') {
      throw StateError(
        'Android E2E requires the isolated staging deep-link scheme.',
      );
    }
    final now = DateTime.tryParse(rawNow)?.toLocal();
    if (now == null) {
      throw StateError('The runner must inject its current test clock.');
    }
    final phase = switch (rawPhase) {
      'bootstrap' => _AndroidE2ePhase.bootstrap,
      'bootstrap-exams' => _AndroidE2ePhase.bootstrapExams,
      'personal-management' => _AndroidE2ePhase.personalManagement,
      'email-online' => _AndroidE2ePhase.emailOnline,
      'email-restart' => _AndroidE2ePhase.emailRestart,
      'routine-offline' => _AndroidE2ePhase.routineOffline,
      'restart' => _AndroidE2ePhase.restart,
      'convergence' => _AndroidE2ePhase.convergence,
      _ => throw StateError('The runner must select an Android E2E phase.'),
    };
    if (!RegExp(r'^[A-Za-z0-9-]{8,96}$').hasMatch(runId)) {
      throw StateError('The runner must inject a safe non-secret run ID.');
    }
    return _AndroidE2eEnvironment(
      supabaseUrl: supabaseUrl!,
      mailpitUrl: mailpitUrl!,
      publishableKey: publishableKey,
      deepLinkScheme: deepLinkScheme,
      now: now,
      phase: phase,
      runId: runId,
    );
  }

  final Uri supabaseUrl;
  final Uri mailpitUrl;
  final String publishableKey;
  final String deepLinkScheme;
  final DateTime now;
  final _AndroidE2ePhase phase;
  final String runId;

  String runnerMarkerFileName(String marker) =>
      'android-e2e-$runId-${phase.runnerToken}-$marker';

  String get firstEmail => 'android-e2e-${runId.toLowerCase()}-a@example.test';

  String get secondEmail => 'android-e2e-${runId.toLowerCase()}-b@example.test';

  String get password => 'Android-E2e-$runId-Aa1!';

  String get templateTitle => 'Android E2E Catalog-$runId';

  String get duplicateTemplateTitle => 'Android E2E Catalog ($runId)';

  String get templateExternalCode => 'android-e2e-catalog-$runId';

  String get duplicateTemplateExternalCode =>
      'android-e2e-catalog-duplicate-$runId';

  String get templateInstructor => 'E2E Instructor';

  String get templateRoom => 'E2E-201';

  String get manualCourseTitle => 'Android E2E 分散システム-$runId';

  String get updatedManualCourseTitle => 'Android E2E 分散システム更新-$runId';

  String get assignmentTitle => 'Android E2E レポート-$runId';

  String get updatedAssignmentTitle => 'Android E2E レポート更新-$runId';

  String get courseLinkedExamTitle => 'Android E2E 授業紐付けテスト-$runId';

  String get standaloneExamTitle => 'Android E2E 授業なしテスト-$runId';

  String get updatedCourseLinkedExamTitle => 'Android E2E 授業紐付けテスト更新-$runId';

  String get universityRequestTitle => '大学申請$runId';

  String get universityRequestNormalizedTitle =>
      '大学申請${runId.toLowerCase().replaceAll('-', '')}';

  String get onboardingUniversityRequestTitle => '大学申請前$runId';

  String get onboardingUniversityRequestNormalizedTitle =>
      '大学申請前${runId.toLowerCase().replaceAll('-', '')}';

  String get customTermTitle => 'Android E2E 集中学期-$runId';

  String get routineTitle => 'Android E2E ルーティン-$runId';

  String get monthlyRoutineTitle => 'Android E2E 月次ルーティン-$runId';

  String get monthlyRoutineOverrideLocation => 'E2E 月次変更場所';

  String get syncedPersonalEventTitle => 'Android E2E 同期済み予定-$runId';

  String get updatedOfflineEventTitle => 'Android E2E オフライン編集予定-$runId';

  String get emailAmbiguousAssignmentTitle => 'メール候補 要確認課題-$runId';

  String get emailAssignmentTitle => 'メール取込 課題-$runId';

  // The personal-management phase deliberately tombstones the manual course.
  // Reuse the still-active copied catalog course so email confirmation proves
  // a real owned-course relationship after that retained process boundary.
  String get emailCorrectedCourseName => templateTitle;

  String get emailCorrectedCourseCode => 'E2E-CORRECTED-$runId';

  String get emailExamTitle => 'メール取込 試験-$runId';

  String get emailDismissedEventTitle => 'メール取込 除外予定-$runId';

  String get emailTimezoneEventTitle => 'メール取込 タイムゾーン予定-$runId';

  String get emailRetriedAnnouncementTitle => 'メール取込 再試行済み-$runId';

  DateTime get emailInitialAssignmentDueAt =>
      _emailInputMinute(now.toUtc().add(const Duration(days: 7)));

  DateTime get emailUpdatedAssignmentDueAt =>
      _emailInputMinute(now.toUtc().add(const Duration(days: 14)));

  DateTime _emailInputMinute(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
  }

  DateTime get emailExamStartAt =>
      JapanTime.startOfDay(now.toUtc().add(const Duration(days: 9)))
          .add(const Duration(hours: 10));

  DateTime get emailEventStartAt =>
      JapanTime.startOfDay(now.toUtc().add(const Duration(days: 5)))
          .add(const Duration(hours: 13));

  DateTime get emailTimezoneEventStartAt => DateTime.utc(2031, 3, 9, 14);

  bool get usesAdbReverseTransport => supabaseUrl.host == '127.0.0.1';

  static bool _isEmulatorLocalHttp(Uri? uri) {
    const localHosts = {'10.0.2.2', '127.0.0.1'};
    return uri != null &&
        uri.scheme == 'http' &&
        localHosts.contains(uri.host) &&
        uri.port > 0 &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }
}

Future<void> _signalRunnerMarker(
  _AndroidE2eEnvironment environment,
  String marker,
) async {
  if (!RegExp(r'^ANDROID_E2E_[A-Z_]+$').hasMatch(marker)) {
    throw StateError('The Android E2E runner marker is invalid.');
  }
  final markerDirectory = await getApplicationSupportDirectory();
  final markerFile = File(
    '${markerDirectory.path}/${environment.runnerMarkerFileName(marker)}',
  );
  await markerFile.writeAsString('$marker\n', flush: true);
  // Keep the same fixed, non-secret breadcrumb in the test output for
  // sanitized failure diagnostics. The runner synchronizes through the file
  // because Flutter test output may be delivered after a transition. The app
  // support directory is retained across the package updates between phases;
  // Android may clear cache and code_cache at those boundaries.
  // ignore: avoid_print
  print(marker);
}

class _PersonalTermE2eResult {
  const _PersonalTermE2eResult({required this.id});

  final String id;
}

class _UniversityRequestE2eResult {
  const _UniversityRequestE2eResult({required this.id});

  final String id;
}

const _androidEmailConnectionId = 'e5000000-0000-4000-8000-000000000001';
const _androidEmailProviderAccountHash =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

/// Deliberately test-only provider boundary. Production remains fail-closed
/// because the acceptance AppConfig keeps EMAIL_IMPORT_ENABLED=false and this
/// fake is installed only through [_RunningApp.start.extraOverrides].
class _AndroidEmailRemoteActions implements EmailReviewRemoteActions {
  _AndroidEmailRemoteActions({
    required this.database,
    required this.environment,
    required this.extractor,
    required this.clock,
    required this.authenticatedUserId,
  });

  final AppDatabase database;
  final _AndroidE2eEnvironment environment;
  final EmailTaskExtractor extractor;
  final DateTime Function() clock;
  final String? Function() authenticatedUserId;
  final fixtureState = _AndroidEmailFixtureState();

  @override
  Future<EmailConnectionState> connect({required String ownerUserId}) async {
    _requireOwner(ownerUserId);
    final now = clock().toUtc();
    await database.emailImportDao.upsertConnection(
      ownerUserId: ownerUserId,
      connection: EmailConnectionsCompanion.insert(
        id: _androidEmailConnectionId,
        ownerUserId: ownerUserId,
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: _androidEmailProviderAccountHash,
        scopesJson: const Value('["gmail.readonly"]'),
        state: const Value('connected'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    return EmailConnectionState(
      provider: EmailProvider.gmail,
      status: EmailConnectionStatus.connected,
      connectedAt: now,
    );
  }

  @override
  Future<EmailConnectionState> checkAuthorization({
    required String ownerUserId,
    required String connectionId,
  }) async {
    _requireConnection(ownerUserId, connectionId);
    return EmailConnectionState(
      provider: EmailProvider.gmail,
      status: EmailConnectionStatus.connected,
      connectedAt: clock().toUtc(),
    );
  }

  @override
  Future<void> refresh({
    required String ownerUserId,
    required String connectionId,
  }) async {
    _requireConnection(ownerUserId, connectionId);
    await EmailImportSyncService(
      db: database,
      connector: _connector(),
      clock: clock,
      authenticatedUserId: authenticatedUserId,
    ).synchronize(
      ownerUserId: ownerUserId,
      connectionId: connectionId,
    );
  }

  @override
  Future<void> retryCandidate({
    required String ownerUserId,
    required String candidateId,
  }) async {
    _requireOwner(ownerUserId);
    final candidate = await database.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: candidateId,
    );
    if (candidate == null ||
        candidate.reviewState != EmailCandidateReviewState.failed.wireName ||
        candidate.errorCategory == null ||
        !EmailErrorCategory.fromWire(candidate.errorCategory!)
            .isCandidateRetryable) {
      throw StateError('Test candidate is unavailable for targeted retry.');
    }
    final source = await database.emailImportDao.sourceById(
      ownerUserId: ownerUserId,
      sourceId: candidate.sourceId,
    );
    if (source == null) throw StateError('Test source is unavailable.');
    final connection = await database.emailImportDao.connectionById(
      ownerUserId: ownerUserId,
      connectionId: source.connectionId,
    );
    if (connection == null) throw StateError('Test connection is unavailable.');
    final connector = _connector();
    if (connector is! TargetedEmailRetryConnector) {
      throw StateError('Test connector lacks targeted retry.');
    }
    final retryIdempotencyKey = emailProviderIdentifierHash(
      kind: 'candidate-retry-idempotency',
      provider: connection.provider,
      providerAccountHash: connection.providerAccountHash,
      rawIdentifier: [
        connection.id,
        source.id,
        source.providerMessageId,
        source.sanitizedContentHash,
        candidate.id,
        candidate.updatedAt.toUtc().toIso8601String(),
      ].join('\u0000'),
    );
    final result =
        await (connector as TargetedEmailRetryConnector).retryCandidate(
      providerMessageId: source.providerMessageId,
      expectedProviderMessageIdHash: emailProviderIdentifierHash(
        kind: 'message',
        provider: connection.provider,
        providerAccountHash: connection.providerAccountHash,
        rawIdentifier: source.providerMessageId,
      ),
      expectedSanitizedContentHash: source.sanitizedContentHash,
      retryIdempotencyKey: retryIdempotencyKey,
    );
    _requireConnection(ownerUserId, source.connectionId);
    expect(result.outcome, TargetedEmailRetryOutcome.persisted);
    await EmailImportSyncService(
      db: database,
      connector: connector,
      clock: () {
        final now = clock().toUtc();
        final minimum = candidate.updatedAt.toUtc().add(
              const Duration(seconds: 1),
            );
        return now.isBefore(minimum) ? minimum : now;
      },
      authenticatedUserId: authenticatedUserId,
    ).persistTargetedRetryItem(
      ownerUserId: ownerUserId,
      connectionId: source.connectionId,
      item: result.item!,
    );
  }

  @override
  Future<void> disconnect({
    required String ownerUserId,
    required String connectionId,
    required bool deleteDerivedData,
  }) async {
    _requireConnection(ownerUserId, connectionId);
    if (deleteDerivedData) {
      await database.transaction(() async {
        await (database.delete(database.emailReconciliationReceipts)
              ..where((row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.connectionId.equals(connectionId)))
            .go();
        final deleted =
            await database.emailImportDao.deleteDerivedDataForConnection(
          ownerUserId: ownerUserId,
          connectionId: connectionId,
        );
        expect(deleted, 1);
      });
      return;
    }
    final now = clock().toUtc();
    final changed = await (database.update(database.emailConnections)
          ..where((row) =>
              row.id.equals(connectionId) &
              row.ownerUserId.equals(ownerUserId)))
        .write(
      EmailConnectionsCompanion(
        state: const Value('disconnected'),
        disconnectedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    expect(changed, 1);
  }

  @override
  Future<void> deleteAccountData({required String ownerUserId}) async {
    _requireOwner(ownerUserId);
    final rows = await (database.select(database.emailConnections)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .get();
    for (final row in rows) {
      await database.emailImportDao.deleteDerivedDataForConnection(
        ownerUserId: ownerUserId,
        connectionId: row.id,
      );
    }
  }

  void _requireConnection(String ownerUserId, String connectionId) {
    _requireOwner(ownerUserId);
    if (connectionId != _androidEmailConnectionId) {
      throw StateError('The Android email fixture connection is mismatched.');
    }
  }

  void _requireOwner(String ownerUserId) {
    if (ownerUserId.isEmpty || authenticatedUserId() != ownerUserId) {
      throw StateError('The Android email fixture owner is inactive.');
    }
  }

  EmailConnector _connector() => _AndroidEmailConnector(
        environment: environment,
        extractor: extractor,
        fixtureState: fixtureState,
      );
}

class _AndroidEmailFixtureState {
  int extractionCalls = 0;
  int targetedRetryCalls = 0;
}

class _AndroidEmailConnector
    implements EmailConnector, TargetedEmailRetryConnector {
  const _AndroidEmailConnector({
    required this.environment,
    required this.extractor,
    required this.fixtureState,
  });

  final _AndroidE2eEnvironment environment;
  final EmailTaskExtractor extractor;
  final _AndroidEmailFixtureState fixtureState;

  @override
  EmailProvider get provider => EmailProvider.gmail;

  @override
  Future<EmailConnectionState> connect() async => EmailConnectionState(
        provider: provider,
        status: EmailConnectionStatus.connected,
        connectedAt: environment.now.toUtc(),
      );

  @override
  Future<void> disconnect({required bool deleteDerivedData}) async {}

  @override
  Future<EmailFetchPage> fetchDelta({String? cursor}) async {
    if (cursor == null) {
      return EmailFetchPage(
        items: await _initialItems(),
        nextCursor: 'android-email-initial',
        hasMore: false,
      );
    }
    if (cursor == 'android-email-initial') {
      return EmailFetchPage(
        items: await _updateItems(),
        nextCursor: 'android-email-update',
        hasMore: false,
      );
    }
    return const EmailFetchPage(items: [], nextCursor: null, hasMore: false);
  }

  @override
  Future<TargetedEmailRetryResult> retryCandidate({
    required String providerMessageId,
    required String expectedProviderMessageIdHash,
    required String expectedSanitizedContentHash,
    required String retryIdempotencyKey,
  }) async {
    expect(providerMessageId, 'android-message-retry-1');
    expect(expectedSanitizedContentHash, 'e' * 64);
    expect(retryIdempotencyKey, hasLength(64));
    expect(
      expectedProviderMessageIdHash,
      emailProviderIdentifierHash(
        kind: 'message',
        provider: EmailProvider.gmail.wireName,
        providerAccountHash: _androidEmailProviderAccountHash,
        rawIdentifier: providerMessageId,
      ),
    );
    fixtureState.targetedRetryCalls++;
    return TargetedEmailRetryResult.persisted(
      await _extractedItem(
        providerMessageId: providerMessageId,
        providerThreadId: 'android-thread-retry',
        receivedAt: environment.now.toUtc().add(const Duration(minutes: 4)),
        hashCharacter: 'e',
        subject: environment.emailRetriedAnnouncementTitle,
        content: 'お知らせ: 安全な対象メッセージの再処理が完了しました',
      ),
    );
  }

  Future<List<EmailFetchItem>> _initialItems() async => [
        await _extractedItem(
          providerMessageId: 'android-message-assignment-1',
          providerThreadId: 'android-thread-assignment',
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 1)),
          hashCharacter: 'a',
          subject: environment.emailAmbiguousAssignmentTitle,
          content: '科目名: 候補の授業 / 別の授業\n'
              '課題名: ${environment.emailAmbiguousAssignmentTitle}\n'
              '提出期限: ${_japanCivilMinute(environment.emailInitialAssignmentDueAt)}\n'
              '提出先: https://classroom.example.invalid/submit',
        ),
        await _extractedItem(
          providerMessageId: 'android-message-exam-1',
          providerThreadId: 'android-thread-exam',
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 2)),
          hashCharacter: 'b',
          subject: environment.emailExamTitle,
          content: '科目名: 試験科目\n'
              '科目コード: E2E201\n'
              '試験名: ${environment.emailExamTitle}\n'
              '試験日時: ${_japanCivilRange(environment.emailExamStartAt, environment.emailExamStartAt.add(const Duration(hours: 1)))}\n'
              '教室: A101',
        ),
        await _dismissedEventItem(
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 3)),
        ),
        await _extractedItem(
          providerMessageId: 'android-message-timezone-event-1',
          providerThreadId: 'android-thread-timezone-event',
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 3)),
          hashCharacter: 'f',
          timezone: 'America/New_York',
          subject: environment.emailTimezoneEventTitle,
          content: 'イベント名: ${environment.emailTimezoneEventTitle}\n'
              '開催日時: 2031年3月9日 10:00〜11:00\n'
              '場所: 国際会議室',
        ),
        EmailFetchItem(
          providerMessageId: 'android-message-retry-1',
          providerThreadId: null,
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 4)),
          sanitizedContentHash: 'e' * 64,
          evidenceExcerpts: const [],
          candidate: null,
          errorCategory: EmailErrorCategory.timeout,
        ),
      ];

  Future<List<EmailFetchItem>> _updateItems() async => [
        await _extractedItem(
          providerMessageId: 'android-message-assignment-2',
          providerThreadId: 'android-thread-assignment',
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 6)),
          hashCharacter: 'd',
          subject: environment.emailAssignmentTitle,
          content: '科目名: ${environment.emailCorrectedCourseName}\n'
              '科目コード: ${environment.emailCorrectedCourseCode}\n'
              '課題名: ${environment.emailAssignmentTitle}\n'
              '提出期限: ${_japanCivilMinute(environment.emailUpdatedAssignmentDueAt)}\n'
              '提出先: https://classroom.example.invalid/submit',
        ),
        await _extractedItem(
          providerMessageId: 'android-message-timezone-event-2',
          providerThreadId: 'android-thread-timezone-event',
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 7)),
          hashCharacter: '1',
          timezone: 'America/Chicago',
          subject: environment.emailTimezoneEventTitle,
          content: 'イベント名: ${environment.emailTimezoneEventTitle}\n'
              '開催日時: 2031年3月9日 09:00〜10:00\n'
              '場所: 国際会議室',
        ),
        // Replay the dismissed provider identity. Its immutable hash tombstone
        // must suppress it before any raw source is re-created.
        await _dismissedEventItem(
          receivedAt: environment.now.toUtc().add(const Duration(minutes: 8)),
        ),
      ];

  Future<EmailFetchItem> _dismissedEventItem({
    required DateTime receivedAt,
  }) {
    return _extractedItem(
      providerMessageId: 'android-message-event-1',
      providerThreadId: 'android-thread-event',
      receivedAt: receivedAt,
      hashCharacter: 'c',
      subject: environment.emailDismissedEventTitle,
      content: 'イベント名: ${environment.emailDismissedEventTitle}\n'
          '開催日時: ${_japanCivilRange(environment.emailEventStartAt, environment.emailEventStartAt.add(const Duration(hours: 1)))}\n'
          '場所: オンライン',
    );
  }

  Future<EmailFetchItem> _extractedItem({
    required String providerMessageId,
    required String providerThreadId,
    required DateTime receivedAt,
    required String hashCharacter,
    required String subject,
    required String content,
    String timezone = JapanTime.timeZone,
  }) async {
    fixtureState.extractionCalls++;
    final candidate = await extractor.extract(
      SanitizedEmailInput(
        receivedAt: receivedAt,
        timezone: timezone,
        sanitizedSubject: subject,
        sanitizedContent: content,
        sanitizedSenderLabel: '合成大学',
      ),
    );
    return EmailFetchItem(
      providerMessageId: providerMessageId,
      providerThreadId: providerThreadId,
      receivedAt: receivedAt,
      sanitizedContentHash: hashCharacter * 64,
      evidenceExcerpts:
          candidate.evidence.map((item) => item.text).toList(growable: false),
      candidate: candidate,
    );
  }

  String _japanCivilMinute(DateTime instant) {
    final civil = JapanTime.civil(instant);
    return '${civil.year}年${civil.month}月${civil.day}日 '
        '${civil.hour.toString().padLeft(2, '0')}:'
        '${civil.minute.toString().padLeft(2, '0')}';
  }

  String _japanCivilRange(DateTime start, DateTime end) {
    final startCivil = JapanTime.civil(start);
    final endCivil = JapanTime.civil(end);
    return '${startCivil.year}年${startCivil.month}月${startCivil.day}日 '
        '${startCivil.hour.toString().padLeft(2, '0')}:'
        '${startCivil.minute.toString().padLeft(2, '0')}〜'
        '${endCivil.hour.toString().padLeft(2, '0')}:'
        '${endCivil.minute.toString().padLeft(2, '0')}';
  }
}

class _AndroidEmailReconciliationGateway implements EmailReconciliationGateway {
  _AndroidEmailReconciliationGateway({
    this.loseFirstConfirmationResponse = false,
  });

  final bool loseFirstConfirmationResponse;
  final List<EmailReconciliationRequest> requests = [];
  final _committedResults = <String, EmailReconciliationResult>{};
  final _committedRequestFingerprints = <String, String>{};
  String? lostResponseIdempotencyKey;
  int lostResponseCount = 0;
  int replayedResponseCount = 0;

  bool get hasPendingLostResponse =>
      lostResponseIdempotencyKey != null && replayedResponseCount == 0;

  @override
  Future<EmailReconciliationResult> reconcile(
    EmailReconciliationRequest request,
  ) async {
    expect(request.connectionId, _androidEmailConnectionId);
    expect(request.provider, EmailProvider.gmail.wireName);
    expect(request.providerAccountHash, _androidEmailProviderAccountHash);
    expect(request.providerMessageIdHash, hasLength(64));
    expect(request.providerThreadIdHash, hasLength(64));
    expect(request.sanitizedContentHash, hasLength(64));
    expect(request.providerMessageIdHash, isNot(contains('android-message')));
    expect(request.providerThreadIdHash, isNot(contains('android-thread')));
    requests.add(request);
    final fingerprint = _requestFingerprint(request);
    final committed = _committedResults[request.idempotencyKey];
    if (committed != null) {
      expect(
        fingerprint,
        _committedRequestFingerprints[request.idempotencyKey],
        reason: 'A lost-response replay must repeat the exact request.',
      );
      replayedResponseCount++;
      return EmailReconciliationResult(
        connectionId: committed.connectionId,
        idempotencyKey: committed.idempotencyKey,
        action: committed.action,
        outcome: committed.outcome,
        entityType: committed.entityType,
        entityId: committed.entityId,
        replayed: true,
      );
    }
    final outcome = switch (request.action) {
      EmailReconciliationAction.confirmation =>
        EmailReconciliationOutcome.confirmed,
      EmailReconciliationAction.dismissal =>
        EmailReconciliationOutcome.dismissed,
      EmailReconciliationAction.update =>
        request.resolution == EmailReconciliationResolution.accepted
            ? EmailReconciliationOutcome.accepted
            : EmailReconciliationOutcome.rejected,
    };
    final result = EmailReconciliationResult(
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: request.action,
      outcome: outcome,
      entityType: request.entityType,
      entityId: request.entityId,
      replayed: false,
    );
    _committedResults[request.idempotencyKey] = result;
    _committedRequestFingerprints[request.idempotencyKey] = fingerprint;
    if (loseFirstConfirmationResponse &&
        request.action == EmailReconciliationAction.confirmation &&
        lostResponseIdempotencyKey == null) {
      lostResponseIdempotencyKey = request.idempotencyKey;
      lostResponseCount++;
      throw EmailImportFailure.timeout();
    }
    return result;
  }

  String _requestFingerprint(EmailReconciliationRequest request) => jsonEncode({
        'action': request.action.wireName,
        'connectionId': request.connectionId,
        'provider': request.provider,
        'providerAccountHash': request.providerAccountHash,
        'providerMessageIdHash': request.providerMessageIdHash,
        'providerThreadIdHash': request.providerThreadIdHash,
        'sanitizedContentHash': request.sanitizedContentHash,
        'idempotencyKey': request.idempotencyKey,
        'reviewedPayload': request.reviewedPayload,
        'resolution': request.resolution?.wireName,
        'entityType': request.entityType,
        'entityId': request.entityId,
      });
}

class _InitializedSupabaseForAndroidE2e {
  const _InitializedSupabaseForAndroidE2e({
    required this.client,
    required this.sessionStorage,
  });

  final SupabaseClient client;
  final SecureAuthLocalStorage sessionStorage;
}

Future<_InitializedSupabaseForAndroidE2e> _initializeSupabaseForAndroidE2e({
  required AppConfig config,
  required http.Client httpClient,
}) async {
  final secureAuthStorage = SecureAuthStorageBundle.forSupabaseUrl(
    config.supabaseUrl!,
    region: StorageRegion.fromConfig(config),
  );
  final initialized = await Supabase.initialize(
    url: config.supabaseUrl!.toString(),
    publishableKey: config.supabasePublishableKey,
    httpClient: httpClient,
    authOptions: FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      detectSessionInUri: true,
      localStorage: secureAuthStorage.sessionStorage,
      pkceAsyncStorage: secureAuthStorage.pkceStorage,
    ),
  );
  return _InitializedSupabaseForAndroidE2e(
    client: initialized.client,
    sessionStorage: secureAuthStorage.sessionStorage,
  );
}

class _RunningApp {
  _RunningApp({
    required this.container,
    required this.database,
    required this.clock,
  });

  final ProviderContainer container;
  final AppDatabase database;
  final _InjectedAppClock clock;
  bool _disposed = false;

  static Future<_RunningApp> start(
    WidgetTester tester, {
    required AppConfig config,
    required SupabaseClient client,
    required SecureAuthLocalStorage sessionStorage,
    required DateTime now,
    Iterable<Override> Function(AppDatabase database)? extraOverrides,
    Future<void> Function(String stage)? onStage,
  }) async {
    final region = StorageRegion.fromConfig(config);
    // Match production bootstrap's native and canonical-storage gates. Do not
    // activate an owner here: the production alarm runtime owns that transition.
    await const SqliteIdentityHandshake().verify(force: true);
    if (onStage != null) await onStage('SQLITE_READY');
    await const NativeScopeBridge().prepare(region);
    if (onStage != null) await onStage('NATIVE_SCOPE_READY');
    final documents = await getApplicationDocumentsDirectory();
    if (onStage != null) await onStage('DOCUMENTS_READY');
    final prepared =
        await const StoragePreparation().prepare(documents, region);
    if (onStage != null) await onStage('STORAGE_READY');
    final database = await openStorageDatabaseInBackground(
      file: File(prepared.databasePath),
      region: region,
    );
    if (onStage != null) await onStage('DATABASE_OPEN_READY');
    try {
      await database.customSelect('SELECT 1').get();
      if (onStage != null) await onStage('DATABASE_PROBE_READY');
    } on Object {
      await database.close();
      rethrow;
    }
    final clock = _InjectedAppClock(now);
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        storageRegionProvider.overrideWithValue(region),
        supabaseClientProvider.overrideWithValue(client),
        secureAuthLocalStorageProvider.overrideWithValue(sessionStorage),
        appDatabaseProvider.overrideWithValue(database),
        appDatabasePathProvider.overrideWithValue(prepared.databasePath),
        appClockProvider.overrideWithValue(clock),
        ...?extraOverrides?.call(database),
      ],
    );
    if (onStage != null) await onStage('CONTAINER_READY');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const UniversityScheduleApp(),
      ),
    );
    if (onStage != null) await onStage('APP_PUMPED');
    await tester.pump();
    if (onStage != null) await onStage('FIRST_FRAME_READY');
    return _RunningApp(container: container, database: database, clock: clock);
  }

  Future<void> dispose(
    WidgetTester tester, {
    Future<void> Function(String stage)? onStage,
  }) async {
    if (_disposed) return;
    _disposed = true;
    // Let route and semantics updates finish while their render objects are
    // still attached. Replacing the root during an in-flight semantics update
    // can leave Flutter's cached semantics fragment without geometry.
    await tester.pumpAndSettle();
    if (onStage != null) await onStage('DISPOSE_SETTLED');
    await tester.pumpWidget(const SizedBox.shrink());
    if (onStage != null) await onStage('DISPOSE_UNMOUNTED');
    await tester.pumpAndSettle();
    if (onStage != null) await onStage('DISPOSE_FINAL_FRAME_READY');
    container.dispose();
    if (onStage != null) await onStage('CONTAINER_DISPOSED');
    await Future<void>.delayed(Duration.zero);
    await database.close();
    if (onStage != null) await onStage('DATABASE_CLOSED');
    // Provider teardown can schedule a frame after the root was unmounted.
    // Finish that frame after asynchronous database cleanup and before the
    // live test binding starts its own post-test frame.
    await tester.pump();
    if (onStage != null) await onStage('DISPOSE_COMPLETION_FRAME_READY');
  }
}

class _InjectedAppClock implements AppClock {
  _InjectedAppClock(this._value);

  DateTime _value;

  @override
  DateTime now() => _value;

  void advance(Duration duration) {
    _value = _value.add(duration);
  }
}

class _LocalMailpitInbox {
  _LocalMailpitInbox(this.baseUrl) : _client = HttpClient();

  final Uri baseUrl;
  final HttpClient _client;
  final Set<String> _consumedMessageIds = <String>{};

  Future<void> ignoreExistingMessagesFor(String email) async {
    final messages = await _getJson('/api/v1/messages');
    if (messages is! Map) return;
    final rows = messages['messages'];
    if (rows is! List) return;
    for (final row in rows) {
      if (row is! Map || !_isForRecipient(row, email)) continue;
      final id = row['ID'];
      if (id is String) _consumedMessageIds.add(id);
    }
  }

  Future<String> takeMagicLinkTokenHash(String email) async {
    for (var attempt = 0; attempt < 50; attempt++) {
      final messages = await _getJson('/api/v1/messages');
      if (messages is Map) {
        final rows = messages['messages'];
        if (rows is List) {
          for (final row in rows) {
            if (row is! Map || !_isForRecipient(row, email)) continue;
            final id = row['ID'];
            if (id is! String || _consumedMessageIds.contains(id)) continue;
            final detail = await _getJson('/api/v1/message/$id');
            final tokenHash = _extractMagicLinkTokenHash(detail);
            if (tokenHash != null) {
              _consumedMessageIds.add(id);
              return tokenHash;
            }
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('Local Mailpit did not receive the expected message.');
  }

  Future<Object?> _getJson(String path) async {
    final request = await _client.getUrl(baseUrl.resolve(path));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) return null;
    return jsonDecode(body);
  }

  bool _isForRecipient(Map<dynamic, dynamic> message, String email) {
    final recipients = message['To'];
    if (recipients is! List) return false;
    return recipients.any(
      (recipient) =>
          recipient is Map &&
          recipient['Address'] is String &&
          (recipient['Address'] as String).toLowerCase() == email.toLowerCase(),
    );
  }

  String? _extractMagicLinkTokenHash(Object? rawDetail) {
    if (rawDetail is! Map) return null;
    final text = rawDetail['Text'] is String ? rawDetail['Text'] as String : '';
    final html = rawDetail['HTML'] is String ? rawDetail['HTML'] as String : '';
    final match = RegExp(
      r'''https?://[^\s"'<>]+/auth/v1/verify\?[^\s"'<>]+''',
    ).firstMatch('$text $html');
    if (match == null) return null;
    final encodedUrl = match.group(0)!.replaceAll('&amp;', '&');
    final uri = Uri.tryParse(encodedUrl);
    if (uri == null || uri.queryParameters['type'] != 'magiclink') return null;
    final tokenHash = uri.queryParameters['token']?.trim();
    return tokenHash == null || tokenHash.isEmpty ? null : tokenHash;
  }

  void close() => _client.close(force: true);
}

SupabaseClient _newPublicClient(
  _AndroidE2eEnvironment environment, {
  http.Client? httpClient,
}) {
  return SupabaseClient(
    environment.supabaseUrl.toString(),
    environment.publishableKey,
    httpClient: httpClient ?? ScheduleSyncDeadlineHttpClient(),
    authOptions: const AuthClientOptions(
      autoRefreshToken: false,
      // These are headless, public test clients used only for synthetic
      // password provisioning and peer convergence checks. PKCE storage is
      // provided by Supabase.initialize for the app client above; a bare
      // SupabaseClient has no async storage to persist a PKCE verifier.
      authFlowType: AuthFlowType.implicit,
    ),
  );
}

Future<void> _provisionSyntheticUser(
  SupabaseClient client, {
  required String email,
  required String password,
}) async {
  final response = await client.auth.signUp(email: email, password: password);
  expect(response.user, isNotNull);
  expect(response.session, isNotNull);
  await client.auth.signOut(scope: SignOutScope.local);
}

Future<void> _signInWithMagicLink(
  WidgetTester tester, {
  required SupabaseClient client,
  required ProviderContainer container,
  required _LocalMailpitInbox inbox,
  required String email,
}) async {
  await _waitFor(
    tester,
    find.byKey(const Key('sign-in-email')),
    label: 'the email sign-in form',
  );
  await _waitForCondition(
    tester,
    () => !container.read(authActionControllerProvider).isLoading,
    label: 'the enabled email sign-in form',
    diagnostic: () => _safeMagicLinkActionDiagnostic(container),
  );
  final emailButton = find.byKey(const Key('sign-in-email-button'));
  expect(emailButton, findsOneWidget);
  expect(
    tester.widget<FilledButton>(emailButton).onPressed,
    isNotNull,
    reason: 'The email sign-in action must be enabled before the E2E tap.',
  );
  // A later Android test phase shares local Mailpit state with bootstrap.
  // Ignore prior messages for this synthetic address before issuing this
  // request so only the newly generated magic link can be consumed.
  await inbox.ignoreExistingMessagesFor(email);
  await tester.enterText(find.byKey(const Key('sign-in-email')), email);
  await _tap(tester, find.byKey(const Key('sign-in-email-button')));
  await _waitForCondition(
    tester,
    () {
      final action = container.read(authActionControllerProvider);
      return action.valueOrNull?.name == 'magicLinkSent' || action.hasError;
    },
    label: 'magic-link request completion',
    diagnostic: () => _safeMagicLinkActionDiagnostic(container),
  );
  expect(
    container.read(authActionControllerProvider).valueOrNull?.name,
    'magicLinkSent',
    reason: _safeMagicLinkActionDiagnostic(container),
  );
  await _waitFor(
    tester,
    find.text('確認リンクを送信しました。メールを確認してください。'),
    label: 'magic-link delivery confirmation',
    diagnostic: () => _safeMagicLinkActionDiagnostic(container),
  );
  final tokenHash = await inbox.takeMagicLinkTokenHash(email);
  final response = await client.auth.verifyOTP(
    tokenHash: tokenHash,
    type: OtpType.magiclink,
  );
  expect(response.user?.email, email);
  expect(response.session, isNotNull);
}

Future<void> _requestUniversityDuringOnboarding(
  WidgetTester tester, {
  required ProviderContainer container,
  required SupabaseClient client,
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
  required http.Client appTransport,
}) async {
  await _waitFor(
    tester,
    find.text('初期設定'),
    label: 'the incomplete onboarding form before the university request',
  );
  // The app starts profile/catalog/sync work immediately after verifyOTP.
  // Before the single UI mutation, prove this exact app transport has a stable
  // local Auth route and that the authenticated REST client can read its own
  // profile. Neither preflight changes data or retries the request RPC.
  await _waitForLocalSupabaseReachability(
    environment,
    reachable: true,
    requiredConsecutiveSuccesses: 2,
    probeClient: appTransport,
    label: 'the authenticated app transport before the university request',
  );
  final authenticatedProfile = await client
      .from('profiles')
      .select('user_id')
      .eq('user_id', ownerUserId)
      .maybeSingle();
  expect(authenticatedProfile, isNotNull);
  expect(
    Map<String, Object?>.from(authenticatedProfile! as Map)['user_id'],
    ownerUserId,
  );
  final requestAction = find.byKey(
    const Key('onboarding-request-university-button'),
  );
  await _scrollOnboardingFormTo(
    tester,
    requestAction,
    label: 'the onboarding university request action',
  );
  await _tap(tester, requestAction);
  await _waitFor(
    tester,
    find.text('未登録大学を申請'),
    label: 'the onboarding university request dialog',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-name')),
    environment.onboardingUniversityRequestTitle,
    label: 'the onboarding university request name',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-prefecture')),
    '石川県',
    label: 'the onboarding university request prefecture',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-url')),
    'https://onboarding-university.example.test',
    label: 'the onboarding university request official URL',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tap(
    tester,
    find.byKey(const Key('submit-university-request-button')),
  );
  await _waitFor(
    tester,
    find.text('大学追加申請を受け付けました。審査後に大学を選択できます。'),
    label: 'the incomplete-onboarding university request acknowledgement',
    diagnostic: () => _safeUniversityRequestDialogDiagnostic(tester),
  );
  await _waitForCondition(
    tester,
    () {
      final onboarding = container.read(onboardingControllerProvider);
      final route = container
          .read(routerProvider)
          .routerDelegate
          .currentConfiguration
          .uri
          .path;
      return route == '/onboarding' &&
          !onboarding.isLoading &&
          !onboarding.hasError &&
          onboarding.valueOrNull?.hasActiveSchedule == false &&
          container.read(activeScheduleContextProvider) == null;
    },
    label: 'the incomplete onboarding state after the university request',
    diagnostic: () => _safeReauthenticationDiagnostic(container),
  );

  final profileRow = await client
      .from('profiles')
      .select(
        'user_id,onboarding_status,onboarding_step,onboarding_completed_at,'
        'active_term_id,primary_calendar_id',
      )
      .eq('user_id', ownerUserId)
      .maybeSingle();
  expect(profileRow, isNotNull);
  final profile = Map<String, Object?>.from(profileRow! as Map);
  expect(profile['user_id'], ownerUserId);
  expect(profile['onboarding_status'], 'not_started');
  expect(profile['onboarding_step'], 'profile');
  expect(profile['onboarding_completed_at'], isNull);
  expect(profile['active_term_id'], isNull);
  expect(profile['primary_calendar_id'], isNull);
  expect(container.read(activeScheduleContextProvider), isNull);

  final requestRow = await client
      .from('university_requests')
      .select(
        'id,requested_by,name,normalized_name,prefecture,official_url,status',
      )
      .eq('name', environment.onboardingUniversityRequestTitle)
      .maybeSingle();
  expect(requestRow, isNotNull);
  final request = Map<String, Object?>.from(requestRow! as Map);
  expect(request['id'], isA<String>());
  expect(request['requested_by'], ownerUserId);
  expect(request['name'], environment.onboardingUniversityRequestTitle);
  expect(
    request['normalized_name'],
    environment.onboardingUniversityRequestNormalizedTitle,
  );
  expect(request['prefecture'], '石川県');
  expect(
    request['official_url'],
    'https://onboarding-university.example.test',
  );
  expect(request['status'], 'pending');
}

Future<void> _completeSeededOnboarding(WidgetTester tester) async {
  await _waitFor(
    tester,
    find.text('初期設定'),
    label: 'the onboarding form',
  );
  final term = _onboardingDropdown('onboarding-term-');
  await _waitFor(
    tester,
    term,
    label: 'the seeded semester selector',
  );
  await _scrollOnboardingFormTo(
    tester,
    term,
    label: 'the seeded semester selector',
  );
  await _selectDropdownMenuOption(
    tester,
    field: term,
    optionText: find.text('2026年度 前学期'),
    label: 'the seeded semester option',
  );
  await tester.pumpAndSettle();
  await _assertOnboardingSelectedLabel(
    tester,
    keyPrefix: 'onboarding-university-',
    selectedLabel: '金沢工業大学',
    label: 'the local seeded university selection',
  );
  await _assertOnboardingSelectedLabel(
    tester,
    keyPrefix: 'onboarding-campus-',
    selectedLabel: '扇が丘',
    label: 'the local seeded campus selection',
  );
  await _assertOnboardingSelectedLabel(
    tester,
    keyPrefix: 'onboarding-term-',
    selectedLabel: '2026年度 前学期',
    label: 'the local seeded semester selection',
  );
  await _assertOnboardingSelectedLabel(
    tester,
    keyPrefix: 'onboarding-period-set-',
    selectedLabel: '2026年度 主時間割（標準）',
    label: 'the selected local seeded period template',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-entry-year')),
    '2026',
    label: 'the seeded onboarding entry year',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  final completeAction = find.byKey(const Key('complete-onboarding-button'));
  await _scrollOnboardingFormTo(
    tester,
    completeAction,
    label: 'the seeded onboarding completion action',
  );
  final completionButton = tester.widget<FilledButton>(completeAction);
  expect(completionButton.onPressed, isNotNull);
  await _tap(tester, completeAction);
}

Future<void> _completeUnsupportedCampusCustomOnboarding(
  WidgetTester tester, {
  required ProviderContainer container,
  required AppDatabase database,
  required SupabaseClient client,
  required String ownerUserId,
}) async {
  await _waitFor(
    tester,
    find.text('初期設定'),
    label: 'the unsupported-campus onboarding form',
  );
  final campus = _onboardingDropdown('onboarding-campus-');
  await _waitFor(
    tester,
    campus,
    label: 'the full campus selector including unsupported campuses',
  );
  await _selectDropdownMenuOption(
    tester,
    field: campus,
    optionText: find.text(_unsupportedCampusName),
    label: 'the known campus without a period template',
  );
  await tester.pumpAndSettle();

  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-entry-year')),
    '2026',
    label: 'the fallback onboarding entry year',
  );
  await _scrollOnboardingFormTo(
    tester,
    find.text('学期を手入力'),
    label: 'the custom term source',
  );
  await _tap(tester, find.text('学期を手入力'));
  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-custom-term-name')),
    _unsupportedCampusTermName,
    label: 'the fallback custom term name',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-custom-term-year')),
    '2026',
    label: 'the fallback custom term academic year',
  );
  await _scrollOnboardingFormTo(
    tester,
    find.byKey(const Key('onboarding-custom-term-type')),
    label: 'the fallback custom term type',
  );
  await _selectDropdownMenuOption(
    tester,
    field: find.byKey(const Key('onboarding-custom-term-type')),
    optionText: find.text('集中講義'),
    label: 'the intensive fallback term type option',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-custom-term-start-date')),
    '2026-08-01',
    label: 'the fallback custom term start date',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const Key('onboarding-custom-term-end-date')),
    '2026-08-31',
    label: 'the fallback custom term end date',
  );

  await _scrollOnboardingFormTo(
    tester,
    find.byKey(const Key('onboarding-add-custom-period-button')),
    label: 'the automatic manual-period fallback action',
  );
  expect(
    find.byKey(const Key('onboarding-period-set-null')),
    findsNothing,
    reason: 'The unavailable campus must not expose another campus template.',
  );
  await _tap(
    tester,
    find.byKey(const Key('onboarding-add-custom-period-button')),
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const ValueKey('onboarding-period-draft-day-0')),
    '1',
    label: 'the fallback manual period weekday',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const ValueKey('onboarding-period-draft-number-0')),
    '1',
    label: 'the fallback manual period number',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const ValueKey('onboarding-period-draft-start-0')),
    '09:00',
    label: 'the fallback manual period start time',
  );
  await _enterOnboardingText(
    tester,
    find.byKey(const ValueKey('onboarding-period-draft-end-0')),
    '10:20',
    label: 'the fallback manual period end time',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _scrollOnboardingFormTo(
    tester,
    find.byKey(const Key('complete-onboarding-button')),
    label: 'the fallback onboarding completion action',
  );
  await _tap(tester, find.byKey(const Key('complete-onboarding-button')));

  await _waitForCondition(
    tester,
    () =>
        container.read(activeScheduleContextProvider)?.ownerUserId ==
        ownerUserId,
    label: 'the custom unsupported-campus active schedule context',
  );
  final context = container.read(activeScheduleContextProvider);
  expect(context, isNotNull);
  final termId = context!.termId;
  expect(context.universityId, '26a72fcd-6e61-5d0f-9c77-350762f2562f');
  expect(context.academicYear, 2026);

  final profileRow = await client
      .from('profiles')
      .select('user_id,campus_id,active_term_id,primary_calendar_id')
      .eq('user_id', ownerUserId)
      .maybeSingle();
  expect(profileRow, isNotNull);
  final profile = Map<String, Object?>.from(profileRow! as Map);
  expect(profile['user_id'], ownerUserId);
  expect(profile['campus_id'], _unsupportedCampusId);
  expect(profile['active_term_id'], termId);
  expect(profile['primary_calendar_id'], isA<String>());

  final termRow = await client
      .from('terms')
      .select(
        'id,owner_user_id,university_id,name,academic_year,start_date,'
        'end_date,term_type,source_template_id,is_template,status,deleted_at',
      )
      .eq('id', termId)
      .maybeSingle();
  expect(termRow, isNotNull);
  final term = Map<String, Object?>.from(termRow! as Map);
  expect(term['id'], termId);
  expect(term['owner_user_id'], ownerUserId);
  expect(term['name'], _unsupportedCampusTermName);
  expect(term['academic_year'], 2026);
  expect(term['start_date'], '2026-08-01');
  expect(term['end_date'], '2026-08-31');
  expect(term['term_type'], 'intensive');
  expect(term['source_template_id'], isNull);
  expect(term['is_template'], isFalse);
  expect(term['status'], 'active');
  expect(term['deleted_at'], isNull);

  final periodRows = await client
      .from('period_settings')
      .select(
        'owner_user_id,term_id,source_template_set_id,day_of_week,period_no,'
        'start_time,end_time,deleted_at',
      )
      .eq('owner_user_id', ownerUserId)
      .eq('term_id', termId)
      .isFilter('deleted_at', null);
  expect(periodRows, isA<List>());
  final periods = [
    for (final row in periodRows as List) Map<String, Object?>.from(row as Map),
  ];
  expect(periods, hasLength(1));
  final period = periods.single;
  expect(period['owner_user_id'], ownerUserId);
  expect(period['term_id'], termId);
  expect(period['source_template_set_id'], isNull);
  expect(period['day_of_week'], 1);
  expect(period['period_no'], 1);
  expect(period['start_time'].toString(), startsWith('09:00'));
  expect(period['end_time'].toString(), startsWith('10:20'));

  final localTerm = (await database.select(database.terms).get()).singleWhere(
    (row) => row.id == termId && row.ownerUserId == ownerUserId,
  );
  final localPeriods = (await database.select(database.periodSettings).get())
      .where(
        (row) =>
            row.ownerUserId == ownerUserId &&
            row.termId == termId &&
            row.deletedAt == null,
      )
      .toList(growable: false);
  expect(localTerm.sourceTemplateId, isNull);
  expect(localTerm.name, _unsupportedCampusTermName);
  expect(localPeriods, hasLength(1));
  expect(localPeriods.single.sourceTemplateSetId, isNull);
  expect(localPeriods.single.dayOfWeek, 1);
  expect(localPeriods.single.periodNo, 1);
  expect(localPeriods.single.startTimeMinutes, 9 * 60);
  expect(localPeriods.single.endTimeMinutes, 10 * 60 + 20);

  final periodProvider = personalPeriodSettingsProvider(termId);
  final subscription = container.listen(
    periodProvider,
    (_, __) {},
    fireImmediately: true,
  );
  try {
    final cached = await container.read(periodProvider.future);
    expect(cached, hasLength(1));
    final cachedPeriod = cached.single;
    expect(cachedPeriod.sourceTemplateSetId, isNull);
    expect(cachedPeriod.dayOfWeek, 1);
    expect(cachedPeriod.periodNo, 1);
    expect(cachedPeriod.startTimeMinutes, 9 * 60);
    expect(cachedPeriod.endTimeMinutes, 10 * 60 + 20);
  } finally {
    subscription.close();
  }
}

Future<void> _enterOnboardingText(
  WidgetTester tester,
  Finder finder,
  String value, {
  required String label,
}) async {
  await _scrollOnboardingFormTo(tester, finder, label: label);
  await _tap(tester, finder);
  await tester.enterText(finder.first, value);
  await tester.pump();
}

Future<void> _scrollOnboardingFormTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
}) async {
  final formScrollables = find.descendant(
    of: find.byKey(const Key('onboarding-form-list')),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    formScrollables,
    label: 'the onboarding form scrollable for $label',
  );
  // Android can deliver the final IME view-inset frame after focus is cleared.
  // That relayout can evict a just-materialized bottom child from this lazy
  // ListView. Return only after the target survives the recentering pump.
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: formScrollables.first,
    );
    // `scrollUntilVisible` permits a partial intersection at either viewport
    // edge. Re-center the target before `_tap` so a newly added onboarding
    // callout cannot leave an action underneath the system gesture area.
    await Scrollable.ensureVisible(
      tester.element(finder.first),
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail(
    'The onboarding field for $label did not remain materialized after '
    'scrolling (viewInsetsBottom=${tester.view.viewInsets.bottom}).',
  );
}

Finder _onboardingDropdown(String keyPrefix) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField<String> &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(keyPrefix),
    description: 'Onboarding selector with key prefix $keyPrefix',
  );
}

Future<void> _assertOnboardingSelectedLabel(
  WidgetTester tester, {
  required String keyPrefix,
  required String selectedLabel,
  required String label,
}) async {
  final dropdown = _onboardingDropdown(keyPrefix);
  await _waitFor(tester, dropdown, label: label);
  final selectedText = find.descendant(
    of: dropdown,
    matching: find.text(selectedLabel),
  );
  await _waitFor(tester, selectedText, label: label);
  expect(selectedText, findsAtLeastNWidgets(1));
}

Future<_CourseTemplateFixture> _findAuthenticatedTemplateFixture(
  SupabaseClient client, {
  required _AndroidE2eEnvironment environment,
  required ActiveScheduleContext context,
}) async {
  final response = await client.rpc(
    'search_course_templates',
    params: {
      'query_text': environment.templateTitle,
      'target_university_id': context.universityId,
      'target_academic_year': context.academicYear,
      'target_term_id': context.termId,
      'target_day_of_week': DateTime.monday,
      'target_period_no': 1,
      'target_instructor_name': environment.templateInstructor,
      'limit_count': 50,
    },
  );
  expect(response, isA<List>());
  final rows = (response as List)
      .map((value) => Map<String, Object?>.from(value as Map))
      .where(
        (value) =>
            value['external_course_code'] == environment.templateExternalCode ||
            value['external_course_code'] ==
                environment.duplicateTemplateExternalCode,
      )
      .toList(growable: false);
  expect(rows, hasLength(2));
  final primary = rows.singleWhere(
    (value) =>
        value['title'] == environment.templateTitle &&
        value['external_course_code'] == environment.templateExternalCode,
  );
  final duplicate = rows.singleWhere(
    (value) =>
        value['title'] == environment.duplicateTemplateTitle &&
        value['external_course_code'] ==
            environment.duplicateTemplateExternalCode,
  );
  final id = primary['id'];
  final copyCount = primary['copy_count_total'];
  final copyCountTerm = primary['copy_count_term'];
  final duplicateCopyCount = duplicate['copy_count_total'];
  final duplicateCopyCountTerm = duplicate['copy_count_term'];
  final primaryRank = primary['rank_score'];
  final duplicateRank = duplicate['rank_score'];
  expect(id, isA<String>());
  expect(copyCount, isA<num>());
  expect(copyCountTerm, isA<num>());
  expect(duplicateCopyCount, isA<num>());
  expect(duplicateCopyCountTerm, isA<num>());
  expect(primaryRank, isA<num>());
  expect(duplicateRank, isA<num>());
  expect(primary['duplicate_key'], isNotNull);
  expect(primary['duplicate_key'], duplicate['duplicate_key']);
  expect(primaryRank! as num, greaterThan(duplicateRank! as num));
  expect(primary, isNot(contains('created_by')));
  expect(primary, isNot(contains('author_name')));
  expect(primary, isNot(contains('report_count')));
  expect(duplicate, isNot(contains('created_by')));
  expect(duplicate, isNot(contains('author_name')));
  expect(duplicate, isNot(contains('report_count')));
  return _CourseTemplateFixture(
    id: id! as String,
    copyCountTotal: (copyCount! as num).toInt(),
    copyCountTerm: (copyCountTerm! as num).toInt(),
    duplicateCopyCountTotal: (duplicateCopyCount! as num).toInt(),
    duplicateCopyCountTerm: (duplicateCopyCountTerm! as num).toInt(),
  );
}

class _CourseTemplateFixture {
  const _CourseTemplateFixture({
    required this.id,
    required this.copyCountTotal,
    required this.copyCountTerm,
    required this.duplicateCopyCountTotal,
    required this.duplicateCopyCountTerm,
  });

  final String id;
  final int copyCountTotal;
  final int copyCountTerm;
  final int duplicateCopyCountTotal;
  final int duplicateCopyCountTerm;
}

Future<void> _searchAndCopyCourseTemplate(
  WidgetTester tester, {
  required String title,
  required String instructor,
  required String duplicateTitle,
  required _CourseTemplateFixture templateFixture,
}) async {
  await _openTimetableWeekView(tester);
  final emptySlot = find.byKey(
    const ValueKey('empty-course-cell-1-1'),
  );
  await _tap(tester, emptySlot);
  await _waitFor(
    tester,
    _appBarTitle('授業検索'),
    label: 'the authenticated course-template search screen',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: find.byKey(const Key('course-template-weekday')),
      matching: find.text('月曜'),
    ),
    label: 'the timetable weekday filter',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: find.byKey(const Key('course-template-period')),
      matching: find.text('1限'),
    ),
    label: 'the timetable period filter',
  );
  await tester.enterText(find.byKey(const Key('course-template-query')), title);
  await tester.enterText(
    find.byKey(const Key('course-template-instructor')),
    instructor,
  );
  await _tap(
    tester,
    find.byKey(const Key('course-template-search-submit')),
  );
  await _waitFor(
    tester,
    find.text('同大学内の検索結果 2件（関連度・コピー数順）'),
    label: 'the ranked authenticated RPC search summary',
  );
  await _scrollCourseTemplateSearchTo(
    tester,
    find.text('検索順位 1'),
    label: 'the highest-ranked duplicate course template',
  );
  await _waitFor(
    tester,
    find.text('検索順位 1'),
    label: 'the highest-ranked duplicate course template',
  );
  var primaryResultCard = find.ancestor(
    of: find.text('検索順位 1'),
    matching: find.byType(Card),
  );
  await _waitFor(
    tester,
    primaryResultCard,
    label: 'the highest-ranked authenticated RPC search-result card',
  );
  final primaryResultTitle = find.descendant(
    of: primaryResultCard,
    matching: find.text(title),
  );
  await _waitFor(
    tester,
    primaryResultTitle,
    label: 'the highest-ranked authenticated RPC search-result title',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: primaryResultCard,
      matching: find.text('学期内コピー ${templateFixture.copyCountTerm}'),
    ),
    label: 'the highest-ranked term copy count',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: primaryResultCard,
      matching: find.text('総コピー ${templateFixture.copyCountTotal}'),
    ),
    label: 'the highest-ranked total copy count',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: primaryResultCard,
      matching: find.text('検索結果内の重複候補 2件'),
    ),
    label: 'the highest-ranked duplicate-candidate disclosure',
  );
  final duplicateResultCard = find.ancestor(
    of: find.text('検索順位 2'),
    matching: find.byType(Card),
  );
  await _scrollCourseTemplateSearchTo(
    tester,
    duplicateResultCard,
    label: 'the lower-ranked duplicate course-template card',
  );
  await _waitFor(
    tester,
    duplicateResultCard,
    label: 'the lower-ranked authenticated RPC search-result card',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: duplicateResultCard,
      matching: find.text(duplicateTitle),
    ),
    label: 'the lower-ranked authenticated RPC search-result title',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: duplicateResultCard,
      matching: find.text(
        '学期内コピー ${templateFixture.duplicateCopyCountTerm}',
      ),
    ),
    label: 'the lower-ranked term copy count',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: duplicateResultCard,
      matching: find.text(
        '総コピー ${templateFixture.duplicateCopyCountTotal}',
      ),
    ),
    label: 'the lower-ranked total copy count',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: duplicateResultCard,
      matching: find.text('検索結果内の重複候補 2件'),
    ),
    label: 'the lower-ranked duplicate-candidate disclosure',
  );
  expect(find.textContaining('作成者'), findsNothing);
  await _scrollCourseTemplateSearchTo(
    tester,
    find.text('検索順位 1'),
    label: 'the highest-ranked template before copy',
    scrollDelta: -180,
  );
  primaryResultCard = find.ancestor(
    of: find.text('検索順位 1'),
    matching: find.byType(Card),
  );
  final primaryCopyAction = find.descendant(
    of: primaryResultCard,
    matching: find.widgetWithText(FilledButton, 'コピー'),
  );
  await _waitFor(
    tester,
    primaryCopyAction,
    label: 'the copy action for the highest-ranked authenticated template',
  );
  expect(primaryCopyAction, findsOneWidget);
  await _scrollCourseTemplateSearchActionIntoSafeTapArea(
    tester,
    primaryCopyAction,
    label: 'the copy action for the highest-ranked authenticated template',
  );
  final primaryCopyButton = tester.widget<FilledButton>(primaryCopyAction);
  expect(primaryCopyButton.onPressed, isNotNull);
  final tappableCopySurface = find
      .descendant(
        of: primaryCopyAction,
        matching: find.byType(InkWell),
      )
      .hitTestable();
  expect(tappableCopySurface, findsOneWidget);
  await tester.tap(tappableCopySurface);
  await tester.pump();
  final copiedCourseDetail = _appBarTitle('授業詳細');
  await _waitForCondition(
    tester,
    () =>
        copiedCourseDetail.evaluate().isNotEmpty ||
        _courseTemplateCopyFailureFeedback() != null,
    label: 'the copied course detail screen or controlled copy failure',
  );
  final copyFailure = _courseTemplateCopyFailureFeedback();
  if (copyFailure != null) {
    fail(
      'Authenticated course-template copy surfaced controlled failure '
      '${copyFailure.code}.',
    );
  }
  await _waitFor(
    tester,
    copiedCourseDetail,
    label: 'the copied course detail screen',
  );
  await _waitFor(
    tester,
    find.text('授業テンプレからコピー済み'),
    label: 'the copied template source marker',
  );
  expect(
    find.text('コピー後は個人時間割として独立しています'),
    findsOneWidget,
  );
}

Future<void> _scrollCourseTemplateSearchTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
  double scrollDelta = 180,
}) async {
  final pageScrollables = find.descendant(
    of: find.byKey(const Key('course-template-search-list')),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    pageScrollables,
    label: 'the course-template search list scrollable for $label',
  );
  await tester.scrollUntilVisible(
    finder,
    scrollDelta,
    scrollable: pageScrollables.first,
  );
  await tester.pump();
}

Future<void> _scrollCourseTemplateSearchActionIntoSafeTapArea(
  WidgetTester tester,
  Finder action, {
  required String label,
}) async {
  final pageScrollables = find.descendant(
    of: find.byKey(const Key('course-template-search-list')),
    matching: find.byType(Scrollable),
  );
  await _scrollMvpActionIntoSafeTapArea(
    tester,
    action: action,
    scrollable: pageScrollables,
    label: label,
  );
}

class _CourseTemplateCopyFailureFeedback {
  const _CourseTemplateCopyFailureFeedback(this.code, this.finder);

  final String code;
  final Finder finder;
}

_CourseTemplateCopyFailureFeedback? _courseTemplateCopyFailureFeedback() {
  const messages = <(String, String)>[
    ('auth', 'ログイン状態を確認して、もう一度お試しください。'),
    (
      'permission',
      'この授業を表示またはコピーする権限がありません。',
    ),
    (
      'remote-data',
      '授業データを取得できませんでした。しばらくしてからお試しください。',
    ),
    ('network', 'ネットワーク接続を確認してください。'),
    ('timeout', '通信が完了しませんでした。もう一度お試しください。'),
    ('malformed-data', '授業データの形式を確認できませんでした。'),
    ('generic', '授業テンプレートをコピーできませんでした'),
  ];
  for (final (code, message) in messages) {
    final feedback = find.descendant(
      of: find.byType(SnackBar),
      matching: find.text(message),
    );
    if (feedback.evaluate().isNotEmpty) {
      return _CourseTemplateCopyFailureFeedback(code, feedback);
    }
  }
  final snackbar = find.byType(SnackBar);
  if (snackbar.evaluate().isNotEmpty) {
    return _CourseTemplateCopyFailureFeedback('unknown', snackbar);
  }
  return null;
}

Future<void> _assertCopiedTemplateSnapshot(
  SupabaseClient client, {
  required _CourseTemplateFixture templateFixture,
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
  required ActiveScheduleContext context,
}) async {
  final copied = (await _loadAllScheduleDelta(
    client,
    ownerUserId: ownerUserId,
  ))
      .singleWhere(
    (change) =>
        change.entityType == 'user_course' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['sourceTemplateId'] == templateFixture.id,
  );
  expect(copied.entityId, copied.payload['id']);
  expect(copied.payload['ownerUserId'], ownerUserId);
  expect(copied.payload['termId'], context.termId);
  expect(copied.payload['sourceTemplateId'], templateFixture.id);
  expect(copied.payload['title'], environment.templateTitle);
  expect(copied.payload['instructorName'], environment.templateInstructor);
  expect(copied.payload['dayOfWeek'], DateTime.monday);
  expect(copied.payload['periodNo'], 1);
  expect(copied.payload['room'], environment.templateRoom);
  expect(copied.deletedAt, isNull);
  expect(copied.payload['deletedAt'], isNull);
  expect(copied.changeCursor, greaterThan(0));
  expect(copied.payload['version'], copied.serverVersion);

  final response = await client.rpc(
    'search_course_templates',
    params: {
      'query_text': environment.templateTitle,
      'target_university_id': context.universityId,
      'target_academic_year': context.academicYear,
      'target_term_id': context.termId,
      'target_day_of_week': DateTime.monday,
      'target_period_no': 1,
      'target_instructor_name': environment.templateInstructor,
      'limit_count': 50,
    },
  );
  expect(response, isA<List>());
  final template = (response as List)
      .map((value) => Map<String, Object?>.from(value as Map))
      .singleWhere((value) => value['id'] == templateFixture.id);
  expect(
    (template['copy_count_total'] as num).toInt(),
    templateFixture.copyCountTotal + 1,
  );
}

Future<void> _createRoutineWithCancelledException(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
}) {
  return _createRoutineWithException(
    tester,
    container,
    title: title,
    frequencyLabel: '毎週',
    exceptionMode: EventExceptionMode.cancelled,
    expectedOccurrenceCount: 1,
  );
}

Future<void> _createMonthlyRoutineWithModifiedException(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
  required String overrideLocation,
}) {
  return _createRoutineWithException(
    tester,
    container,
    title: title,
    frequencyLabel: '毎月',
    exceptionMode: EventExceptionMode.modified,
    expectedOccurrenceCount: 2,
    overrideLocation: overrideLocation,
  );
}

Future<void> _createRoutineWithException(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
  required String frequencyLabel,
  required EventExceptionMode exceptionMode,
  required int expectedOccurrenceCount,
  String? overrideLocation,
}) async {
  assert(
    (exceptionMode == EventExceptionMode.modified) ==
        (overrideLocation != null),
  );
  await _tap(tester, find.byTooltip('追加'));
  await _waitFor(
    tester,
    find.text('ルーティンを追加'),
    label: 'the Quick Add routine action',
  );
  await _tap(tester, find.text('ルーティンを追加'));
  await _waitFor(
    tester,
    _appBarTitle('ルーティンを作成'),
    label: 'the routine form',
  );
  await _waitForGone(
    tester,
    find.byType(BottomSheet),
    label: 'Quick Add to dismiss its routine sheet before navigation',
  );
  await _waitForGone(
    tester,
    find.text('ルーティンを追加'),
    label: 'the Quick Add routine action to close before navigation',
  );
  await tester.enterText(_textFormField('ルーティン名'), title);
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('繰り返し'),
    optionText: find.text(frequencyLabel),
    label: 'the $frequencyLabel rule option',
  );
  await _tap(tester, find.text('回数'));
  await _waitFor(
    tester,
    _textFormField('回数'),
    label: 'the routine count field',
  );
  await tester.enterText(_textFormField('回数'), '2');
  final blockingSnackBar = find.byType(SnackBar).hitTestable();
  if (blockingSnackBar.evaluate().isNotEmpty) {
    expect(blockingSnackBar, findsOneWidget);
    await tester.drag(blockingSnackBar, const Offset(0, 200));
    await tester.pump();
    await _waitForGone(
      tester,
      find.byType(SnackBar).hitTestable(),
      label: 'the offline feedback before saving the routine',
    );
  }
  await _saveMvpForm(
    tester,
    formListKey: 'routine-form-list',
    saveActionKey: 'routine-save',
    label: 'the routine save action',
  );
  await _waitFor(
    tester,
    _appBarTitle('カレンダー'),
    label: 'the calendar after saving the routine',
  );
  await _showOnlyPersonalCalendarItems(tester);
  await _assertRoutineOccurrenceCount(
    tester,
    container,
    title: title,
    expectedCount: 2,
    label: 'two $frequencyLabel routine occurrences before the exception',
  );
  await _tap(tester, find.text(title));
  await _waitFor(
    tester,
    _appBarTitle('ルーティンを編集'),
    label: 'the routine edit screen',
  );
  final addException = find.widgetWithText(OutlinedButton, '例外を追加');
  await _tapMvpFormAction(
    tester,
    formListKey: 'routine-form-list',
    action: addException,
    label: 'the routine add-exception action',
  );
  final exceptionSheet = find.byType(BottomSheet);
  await _waitFor(
    tester,
    find.descendant(of: exceptionSheet, matching: find.text('例外を追加')),
    label: 'the routine exception editor',
  );
  if (exceptionMode == EventExceptionMode.modified) {
    await _selectDropdownMenuOption(
      tester,
      field: _dropdownFormField('この回の扱い'),
      optionText: find.text('この回を変更'),
      label: 'the modified routine exception option',
    );
    final exceptionLocation = find.descendant(
      of: exceptionSheet,
      matching: find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == '場所',
        description: 'the routine exception location field',
      ),
    );
    await _waitFor(
      tester,
      exceptionLocation,
      label: 'the modified routine exception location field',
    );
    await tester.enterText(exceptionLocation, overrideLocation!);
  }
  await _tap(
    tester,
    find.descendant(
      of: exceptionSheet,
      matching: find.widgetWithText(FilledButton, '例外設定を保存'),
    ),
  );
  if (exceptionMode == EventExceptionMode.cancelled) {
    final cancellationDialog = find.byType(AlertDialog);
    await _waitFor(
      tester,
      find.descendant(
        of: cancellationDialog,
        matching: find.text('この回を削除しますか？'),
      ),
      label: 'the destructive routine cancellation confirmation',
    );
    await _tap(
      tester,
      find.descendant(
        of: cancellationDialog,
        matching: find.widgetWithText(FilledButton, '削除'),
      ),
    );
  }
  await _waitForGone(
    tester,
    exceptionSheet,
    label: 'the saved routine exception sheet',
  );
  await _waitFor(
    tester,
    find.text('例外設定を保存しました'),
    label: 'the saved routine exception message',
  );
  await _waitFor(
    tester,
    find.text(
      exceptionMode == EventExceptionMode.cancelled ? 'この回を削除' : '変更: $title',
    ),
    label: 'the saved routine exception summary',
  );
  await _openNavigationDestination(tester, 'カレンダー');
  await _assertRoutineOccurrenceCount(
    tester,
    container,
    title: title,
    expectedCount: expectedOccurrenceCount,
    label:
        '$expectedOccurrenceCount $frequencyLabel routine occurrences after the exception',
  );
  if (overrideLocation != null) {
    await _assertModifiedRoutineLocalProjection(
      tester,
      container,
      title: title,
      overrideLocation: overrideLocation,
    );
  }
}

Future<void> _showOnlyPersonalCalendarItems(WidgetTester tester) async {
  for (final label in const ['授業', '課題', 'テスト']) {
    final filter = find.widgetWithText(FilterChip, label);
    await _waitFor(tester, filter, label: 'the $label calendar filter');
    await _waitForCondition(
      tester,
      () => tester.widget<FilterChip>(filter).onSelected != null,
      label: 'the enabled $label calendar filter',
    );
    final chip = tester.widget<FilterChip>(filter);
    if (chip.selected) {
      await _tap(tester, filter);
      await _waitForCondition(
        tester,
        () => !tester.widget<FilterChip>(filter).selected,
        label: 'the hidden $label calendar filter',
      );
    }
  }
  await _ensureCalendarFilterSelected(tester, '個人予定');
}

Future<void> _ensureCalendarFilterSelected(
  WidgetTester tester,
  String label,
) async {
  final filter = find.widgetWithText(FilterChip, label);
  await _waitFor(tester, filter, label: 'the $label calendar filter');
  await _waitForCondition(
    tester,
    () => tester.widget<FilterChip>(filter).onSelected != null,
    label: 'the enabled $label calendar filter',
  );
  if (!tester.widget<FilterChip>(filter).selected) {
    await _tap(tester, filter);
    await _waitForCondition(
      tester,
      () => tester.widget<FilterChip>(filter).selected,
      label: 'the selected $label calendar filter',
    );
  }
  expect(tester.widget<FilterChip>(filter).selected, isTrue);
}

Future<void> _waitForAssignmentCalendarProjection(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final state = container.read(demoAppControllerProvider).valueOrNull;
    final hasAssignment = state?.assignments.any(
          (assignment) => assignment.title == title,
        ) ??
        false;
    final hasProjection = state?.calendarItems.any(
          (item) =>
              item.kind == EventKind.assignmentDeadline && item.title == title,
        ) ??
        false;
    if (hasAssignment && hasProjection) return;
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final state = container.read(demoAppControllerProvider).valueOrNull;
  final hasAssignment = state?.assignments.any(
        (assignment) => assignment.title == title,
      ) ??
      false;
  final hasProjection = state?.calendarItems.any(
        (item) =>
            item.kind == EventKind.assignmentDeadline && item.title == title,
      ) ??
      false;
  fail(
    'E2E_FAILURE: assignment calendar projection was not locally available '
    '(assignment=$hasAssignment, projection=$hasProjection).',
  );
}

Future<void> _waitForAssignmentCalendarDisplay(
  WidgetTester tester, {
  required String title,
}) async {
  final assignmentTitle = find.text(title);
  final calendarList = find.byKey(const Key('calendar-scroll-list'));
  await _waitFor(
    tester,
    calendarList,
    label: 'the calendar projection list',
  );
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (assignmentTitle.evaluate().isNotEmpty) return;
    await tester.drag(calendarList, const Offset(0, -280));
    await tester.pump(const Duration(milliseconds: 50));
  }
  final assignmentFilter = find.widgetWithText(FilterChip, '課題');
  final assignmentFilterSelected = assignmentFilter.evaluate().isNotEmpty &&
      tester.widget<FilterChip>(assignmentFilter).selected;
  final calendarCards = find.byType(Card).evaluate().length;
  fail(
    'E2E_FAILURE: assignment deadline calendar projection was not rendered '
    'E2E_FAILURE: assignmentFilterSelected=$assignmentFilterSelected '
    'E2E_FAILURE: calendarCards=$calendarCards.',
  );
}

Future<void> _assertSubmittedAssignmentIsRemovedFromCalendar(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
}) async {
  await _waitForCondition(
    tester,
    () {
      final state = container.read(demoAppControllerProvider).valueOrNull;
      final assignment = state?.assignments.where(
        (item) => item.title == title,
      );
      if (assignment == null || assignment.length != 1) return false;
      final assignmentId = assignment.single.id;
      return state!.assignmentStates[assignmentId]?.status ==
              AssignmentStatus.submitted &&
          !state.calendarItems.any(
            (item) =>
                item.kind == EventKind.assignmentDeadline &&
                item.title == title,
          );
    },
    label: 'the submitted assignment to leave the local calendar projection',
  );

  final assignmentTitle = find.text(title);
  final calendarList = find.byKey(const Key('calendar-scroll-list'));
  await _waitFor(tester, calendarList, label: 'the refreshed calendar list');
  for (var attempt = 0; attempt < 50; attempt++) {
    expect(assignmentTitle, findsNothing);
    await tester.drag(calendarList, const Offset(0, -280));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _assertRoutineOccurrenceCount(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
  required int expectedCount,
  required String label,
}) async {
  // Normal events and routines intentionally share the personal-events
  // filter. Assert this routine's exact local projection by its source event,
  // rather than treating the Calendar's category-wide total as a
  // recurrence-specific count.
  await _waitForCondition(
    tester,
    () {
      final state = container.read(demoAppControllerProvider).valueOrNull;
      if (state == null) return false;
      final routines = state.events
          .where(
            (event) => event.kind == EventKind.routine && event.title == title,
          )
          .toList();
      if (routines.length != 1) return false;
      final routineOccurrences = state.calendarItems
          .where(
            (item) =>
                item.kind == EventKind.routine &&
                item.sourceId == routines.single.id,
          )
          .length;
      return routineOccurrences == expectedCount;
    },
    label: '$label in the local calendar projection',
  );
  final state = container.read(demoAppControllerProvider).valueOrNull;
  expect(state, isNotNull);
  final routines = state!.events
      .where(
        (event) => event.kind == EventKind.routine && event.title == title,
      )
      .toList();
  expect(routines, hasLength(1));
  final routineOccurrences = state.calendarItems
      .where(
        (item) =>
            item.kind == EventKind.routine &&
            item.sourceId == routines.single.id,
      )
      .length;
  expect(routineOccurrences, expectedCount);
  await _waitForRoutineCalendarDisplay(tester, title: title, label: label);
}

Future<void> _assertModifiedRoutineLocalProjection(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
  required String overrideLocation,
}) async {
  await _waitForCondition(
    tester,
    () {
      final state = container.read(demoAppControllerProvider).valueOrNull;
      if (state == null) return false;
      final routine = state.events.singleWhere(
        (event) => event.kind == EventKind.routine && event.title == title,
      );
      return state.calendarItems.any(
        (item) =>
            item.sourceId == routine.id && item.location == overrideLocation,
      );
    },
    label: 'the modified monthly routine in the local calendar projection',
  );
  final state = container.read(demoAppControllerProvider).valueOrNull;
  expect(state, isNotNull);
  final routine = state!.events.singleWhere(
    (event) => event.kind == EventKind.routine && event.title == title,
  );
  final occurrences = state.calendarItems
      .where(
        (item) => item.kind == EventKind.routine && item.sourceId == routine.id,
      )
      .toList();
  expect(occurrences, hasLength(2));
  final modified = occurrences.singleWhere(
    (item) => item.location == overrideLocation,
  );
  expect(modified.title, title);
}

Future<void> _waitForRoutineCalendarDisplay(
  WidgetTester tester, {
  required String title,
  required String label,
}) async {
  final routineTitle = find.text(title);
  final calendarList = find.byKey(const Key('calendar-scroll-list'));
  await _waitFor(tester, calendarList, label: 'the calendar projection list');
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (routineTitle.evaluate().isNotEmpty) return;
    await tester.drag(calendarList, const Offset(0, -280));
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail(
    'E2E_FAILURE: $label was locally projected but its routine card was not '
    'rendered in the Calendar list.',
  );
}

Future<void> _assertRoutineAndExceptionRemote(
  SupabaseClient client, {
  required String ownerUserId,
  required String title,
  required _AndroidE2eEnvironment environment,
}) async {
  final changes = await _loadAllScheduleDelta(client, ownerUserId: ownerUserId);
  final routine = changes.singleWhere(
    (change) =>
        change.entityType == 'event' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['title'] == title,
  );
  expect(routine.entityId, routine.payload['id']);
  expect(routine.payload['ownerUserId'], ownerUserId);
  expect(routine.payload['kind'], 'routine');
  expect(routine.payload['timezone'], japanTimeZone);
  _expectUtcPayloadInstant(
    routine.payload['startAt'],
    _defaultFormStart(environment),
  );
  _expectUtcPayloadInstant(
    routine.payload['endAt'],
    _defaultFormStart(environment).add(const Duration(hours: 1)),
  );
  final rrule = routine.payload['rrule'];
  expect(rrule, isA<String>());
  final encodedRule = rrule! as String;
  expect(encodedRule, contains('FREQ=WEEKLY'));
  expect(encodedRule, isNot(contains('INTERVAL=2')));
  expect(encodedRule, contains('BYDAY='));
  expect(encodedRule, contains('COUNT=2'));

  final exception = changes.singleWhere(
    (change) =>
        change.entityType == 'event_exception' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['eventId'] == routine.entityId &&
        change.payload['mode'] == 'cancelled',
  );
  expect(exception.entityId, exception.payload['id']);
  expect(exception.payload['ownerUserId'], ownerUserId);
  expect(exception.payload['eventId'], routine.entityId);
  expect(exception.payload['mode'], 'cancelled');
  _expectUtcPayloadInstant(
    exception.payload['recurrenceId'],
    _defaultFormStart(environment),
  );
}

Future<void> _assertMonthlyRoutineAndModifiedExceptionRemote(
  SupabaseClient client, {
  required String ownerUserId,
  required String title,
  required String overrideLocation,
  required _AndroidE2eEnvironment environment,
}) async {
  final expectedStart = _defaultFormStart(environment);
  final changes = await _loadAllScheduleDelta(client, ownerUserId: ownerUserId);
  final routine = changes.singleWhere(
    (change) =>
        change.entityType == 'event' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['title'] == title,
  );
  expect(routine.entityId, routine.payload['id']);
  expect(routine.payload['ownerUserId'], ownerUserId);
  expect(routine.payload['kind'], 'routine');
  expect(routine.payload['timezone'], japanTimeZone);
  _expectUtcPayloadInstant(routine.payload['startAt'], expectedStart);
  _expectUtcPayloadInstant(
    routine.payload['endAt'],
    expectedStart.add(const Duration(hours: 1)),
  );
  final rrule = routine.payload['rrule'];
  expect(rrule, isA<String>());
  final encodedRule = rrule! as String;
  expect(encodedRule, contains('FREQ=MONTHLY'));
  expect(encodedRule, contains('COUNT=2'));
  expect(
    encodedRule,
    contains('MONTHDAY=${JapanTime.civil(expectedStart).day}'),
  );
  expect(encodedRule, isNot(contains('BYDAY=')));

  final exception = changes.singleWhere(
    (change) =>
        change.entityType == 'event_exception' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['eventId'] == routine.entityId &&
        change.payload['mode'] == 'modified',
  );
  expect(exception.entityId, exception.payload['id']);
  expect(exception.payload['ownerUserId'], ownerUserId);
  expect(exception.payload['eventId'], routine.entityId);
  expect(exception.payload['mode'], 'modified');
  expect(exception.payload['overrideTitle'], title);
  expect(exception.payload['overrideLocation'], overrideLocation);
  _expectUtcPayloadInstant(exception.payload['recurrenceId'], expectedStart);
  _expectUtcPayloadInstant(exception.payload['overrideStartAt'], expectedStart);
  _expectUtcPayloadInstant(
    exception.payload['overrideEndAt'],
    expectedStart.add(const Duration(hours: 1)),
  );
}

Future<void> _assertInitialPersonalManagementUtcRemote(
  SupabaseClient client, {
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
}) async {
  final expectedStart = _defaultFormStart(environment);
  final changes = await _loadAllScheduleDelta(client, ownerUserId: ownerUserId);
  final personalEvent = changes.singleWhere(
    (change) =>
        change.entityType == 'event' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['title'] == environment.syncedPersonalEventTitle,
  );
  expect(personalEvent.entityId, personalEvent.payload['id']);
  expect(personalEvent.payload['ownerUserId'], ownerUserId);
  expect(personalEvent.payload['timezone'], japanTimeZone);
  _expectUtcPayloadInstant(personalEvent.payload['startAt'], expectedStart);
  _expectUtcPayloadInstant(
    personalEvent.payload['endAt'],
    expectedStart.add(const Duration(hours: 1)),
  );

  final assignment = changes.singleWhere(
    (change) =>
        change.entityType == 'assignment' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['title'] == environment.assignmentTitle,
  );
  expect(assignment.entityId, assignment.payload['id']);
  expect(assignment.payload['ownerUserId'], ownerUserId);
  _expectUtcPayloadInstant(
    assignment.payload['dueAt'],
    _defaultAssignmentDueAt(environment),
  );
  final assignmentStates = changes
      .where(
        (change) =>
            change.entityType == 'assignment_user_state' &&
            change.entityId == assignment.entityId &&
            change.operation == ScheduleDeltaOperation.upsert,
      )
      .toList();
  expect(
    assignmentStates.any(
      (change) =>
          change.payload['status'] == 'inProgress' &&
          change.payload['submittedAt'] == null,
    ),
    isTrue,
    reason: 'The initial progress state must sync without a submitted time.',
  );
  expect(
    assignmentStates.any(
      (change) =>
          change.payload['status'] == 'submitted' &&
          change.payload['submittedAt'] != null,
    ),
    isTrue,
    reason: 'The explicit submit action must preserve its submitted time.',
  );

  for (final title in [
    environment.courseLinkedExamTitle,
    environment.standaloneExamTitle,
  ]) {
    final exam = changes.singleWhere(
      (change) =>
          change.entityType == 'exam' &&
          change.operation == ScheduleDeltaOperation.upsert &&
          change.payload['title'] == title,
    );
    expect(exam.entityId, exam.payload['id']);
    expect(exam.payload['ownerUserId'], ownerUserId);
    _expectUtcPayloadInstant(exam.payload['startAt'], expectedStart);
    _expectUtcPayloadInstant(
      exam.payload['endAt'],
      expectedStart.add(const Duration(minutes: 90)),
    );
  }

  final updatedManualCourse = changes.singleWhere(
    (change) =>
        change.entityType == 'user_course' &&
        change.operation == ScheduleDeltaOperation.upsert &&
        change.payload['title'] == environment.updatedManualCourseTitle,
  );
  expect(updatedManualCourse.entityId, updatedManualCourse.payload['id']);
  expect(updatedManualCourse.payload['ownerUserId'], ownerUserId);
  expect(updatedManualCourse.payload['room'], 'E2E-102');
  expect(updatedManualCourse.deletedAt, isNull);
}

Future<List<ScheduleDeltaChange>> _loadAllScheduleDelta(
  SupabaseClient client, {
  required String ownerUserId,
}) async {
  final gateway = SupabaseScheduleGateway(client: client);
  final changes = <ScheduleDeltaChange>[];
  var afterCursor = 0;
  while (true) {
    final page = await gateway.pullDelta(
      ownerUserId: ownerUserId,
      afterCursor: afterCursor,
      limit: 500,
    );
    changes.addAll(page.changes);
    if (!page.hasMore) return changes;
    expect(
      page.nextCursor,
      greaterThan(afterCursor),
      reason: 'Schedule-delta pagination must move forward.',
    );
    afterCursor = page.nextCursor;
  }
}

Future<void> _assertQueuedRoutineException(
  AppDatabase database, {
  required String ownerUserId,
  required String routineTitle,
  required EventExceptionMode expectedMode,
  String? expectedOverrideLocation,
}) async {
  final rows = await database.syncQueueDao.allMutations(ownerUserId);
  final routine = rows.singleWhere((row) {
    final payload = _queuePayload(row.payloadJson);
    return row.entityType == 'event' && payload['title'] == routineTitle;
  });
  final exception = rows.singleWhere((row) {
    final payload = _queuePayload(row.payloadJson);
    return row.entityType == 'event_exception' &&
        payload['eventId'] == routine.entityId;
  });
  expect(routine.enqueueSequence, greaterThan(0));
  expect(exception.enqueueSequence, greaterThan(routine.enqueueSequence));
  expect(routine.status, isNot('synced'));
  expect(exception.status, isNot('synced'));
  final payload = _queuePayload(exception.payloadJson);
  expect(payload['mode'], expectedMode.name);
  expect(payload['overrideLocation'], expectedOverrideLocation);
}

Future<void> _assertQueuedOfflineEventUpdate(
  AppDatabase database, {
  required String ownerUserId,
  required String title,
}) async {
  final rows = await database.syncQueueDao.allMutations(ownerUserId);
  final update = rows.singleWhere((row) {
    final payload = _queuePayload(row.payloadJson);
    return row.entityType == 'event' &&
        row.operation == 'update' &&
        payload['title'] == title;
  });
  expect(update.status, 'failed');
  expect(update.nextRetryAt, isNotNull);
  expect(update.syncedAt, isNull);
}

Future<void> _assertDrainedSyncQueueWithSyncedEvent(
  AppDatabase database, {
  required String ownerUserId,
  required String eventId,
}) async {
  final rows = await database.syncQueueDao.allMutations(ownerUserId);
  final pendingCount = rows.where((row) => row.status == 'pending').length;
  final processingCount =
      rows.where((row) => row.status == 'processing').length;
  final failedCount = rows.where((row) => row.status == 'failed').length;
  final conflictCount = rows.where((row) => row.status == 'conflict').length;
  final quarantinedCount =
      rows.where((row) => row.status == 'quarantined').length;
  expect(
    pendingCount,
    0,
    reason:
        'Initial remote verification must not leave pending sync mutations.',
  );
  expect(
    processingCount,
    0,
    reason:
        'Initial remote verification must not leave processing sync mutations.',
  );
  expect(
    failedCount,
    0,
    reason: 'Initial remote verification must not leave failed sync mutations.',
  );
  expect(
    conflictCount,
    0,
    reason:
        'Initial remote verification must not leave conflicted sync mutations.',
  );
  expect(
    quarantinedCount,
    0,
    reason:
        'Initial remote verification must not leave quarantined sync mutations.',
  );

  // Synced queue rows deliberately redact their payloads. The local event ID
  // therefore remains the durable, non-content-bearing link to the exact
  // mutation whose acknowledgement this phase must prove.
  final matchingEvents = rows
      .where(
        (row) =>
            row.entityType == 'event' &&
            row.operation == 'create' &&
            row.entityId == eventId,
      )
      .toList(growable: false);
  expect(
    matchingEvents.length,
    1,
    reason:
        'The initial personal event must have exactly one durable mutation.',
  );
  final eventMutation = matchingEvents.single;
  expect(eventMutation.status, 'synced');
  expect(eventMutation.nextRetryAt, isNull);
  expect(eventMutation.syncedAt, isNotNull);
  expect(eventMutation.serverVersion, isNotNull);
}

Map<String, Object?> _queuePayload(String raw) {
  final decoded = jsonDecode(raw);
  expect(decoded, isA<Map>());
  return (decoded as Map).map(
    (key, value) => MapEntry(key.toString(), value),
  );
}

DateTime _defaultFormStart(_AndroidE2eEnvironment environment) {
  final now = JapanTime.civil(environment.now);
  return JapanTime.at(
    year: now.year,
    month: now.month,
    day: now.day,
    hour: now.hour + 1,
  );
}

DateTime _defaultAssignmentDueAt(_AndroidE2eEnvironment environment) {
  final now = JapanTime.civil(environment.now);
  return JapanTime.at(
    year: now.year,
    month: now.month,
    day: now.day + 7,
    hour: 23,
    minute: 59,
  );
}

void _expectUtcPayloadInstant(Object? value, DateTime expected) {
  final parsed = switch (value) {
    DateTime() => value,
    String() => DateTime.tryParse(value),
    _ => null,
  };
  expect(parsed, isNotNull);
  expect(parsed!.isUtc, isTrue);
  expect(parsed.toUtc(), expected.toUtc());
}

Future<void> _assertRestoredFirstUserData(
  WidgetTester tester, {
  required _AndroidE2eEnvironment environment,
}) async {
  await _openTimetableWeekView(tester);
  await _waitFor(
    tester,
    find.text(environment.templateTitle),
    label: 'the copied course after the Android process restart',
  );
  final copiedCourseCell = find.ancestor(
    of: find.text(environment.templateTitle),
    matching: find.byType(InkWell),
  );
  await _tap(tester, copiedCourseCell);
  await _waitFor(
    tester,
    find.text('授業テンプレからコピー済み'),
    label: 'the restored copied course source snapshot',
  );
  await _openNavigationDestination(tester, '課題・テスト');
  await _selectSubmittedAssignmentFilter(
    tester,
    label: 'the submitted assignment filter after process restart',
  );
  await _waitFor(
    tester,
    find.textContaining('提出済み · 履歴に保存'),
    label: 'submitted history after the Android process restart',
  );
  expect(find.text(environment.assignmentTitle), findsOneWidget);
}

Future<void> _assertCourseLinkedExamInCourseDetail(
  WidgetTester tester, {
  required String courseTitle,
  required String linkedExamTitle,
  required String standaloneExamTitle,
}) async {
  await _openTimetableWeekView(tester);
  await _waitFor(
    tester,
    find.text(courseTitle),
    label: 'the course carrying the linked exam',
  );
  final courseCell = find.ancestor(
    of: find.text(courseTitle),
    matching: find.byType(InkWell),
  );
  await _tap(tester, courseCell);
  await _waitFor(
    tester,
    _appBarTitle('授業詳細'),
    label: 'the linked course detail screen',
  );
  await _waitFor(
    tester,
    find.text(linkedExamTitle),
    label: 'the linked exam in its course detail',
  );
  expect(find.text(standaloneExamTitle), findsNothing);
}

Future<void> _createPersonalEvent(
  WidgetTester tester, {
  required String title,
  required String location,
}) async {
  await _tap(tester, find.byTooltip('追加'));
  await _waitFor(
    tester,
    find.text('予定を追加'),
    label: 'the Quick Add personal-event action',
  );
  await _tap(tester, find.text('予定を追加'));
  await _waitFor(
    tester,
    _appBarTitle('予定を作成'),
    label: 'the personal-event form',
  );
  await _waitForGone(
    tester,
    find.byType(BottomSheet),
    label: 'Quick Add to dismiss its personal-event sheet before navigation',
  );
  await _waitForGone(
    tester,
    find.text('予定を追加'),
    label: 'the Quick Add personal-event action to close before navigation',
  );
  await tester.enterText(_textFormField('予定名'), title);
  await tester.enterText(_textFormField('場所'), location);
  await _saveMvpForm(
    tester,
    formListKey: 'event-form-list',
    saveActionKey: 'event-save',
    label: 'the personal-event save action',
  );
  await _waitFor(
    tester,
    _appBarTitle('カレンダー'),
    label: 'the calendar after saving the personal event',
  );
}

Future<void> _updatePersonalEvent(
  WidgetTester tester, {
  required String currentTitle,
  required String updatedTitle,
}) async {
  await _openNavigationDestination(tester, 'カレンダー');
  await _waitFor(
    tester,
    find.text(currentTitle),
    label: 'the synced personal event before offline editing',
  );
  await _tap(tester, find.text(currentTitle));
  await _waitFor(
    tester,
    _appBarTitle('予定を編集'),
    label: 'the personal-event edit form',
  );
  await tester.enterText(_textFormField('予定名'), updatedTitle);
  await tester.enterText(_textFormField('場所'), 'E2E 更新済み');
  await _saveMvpForm(
    tester,
    formListKey: 'event-form-list',
    saveActionKey: 'event-save',
    label: 'the personal-event update action',
  );
  await _waitFor(
    tester,
    _appBarTitle('カレンダー'),
    label: 'the calendar after updating the personal event',
  );
  await _waitFor(
    tester,
    find.text(updatedTitle),
    label: 'the updated personal event in the calendar',
  );
  expect(find.text(currentTitle), findsNothing);
}

Future<void> _deletePersonalEvent(
  WidgetTester tester, {
  required String title,
}) async {
  await _waitFor(
    tester,
    find.text(title),
    label: 'the updated personal event before deletion',
  );
  await _tap(tester, find.text(title));
  await _waitFor(
    tester,
    _appBarTitle('予定を編集'),
    label: 'the personal-event delete form',
  );
  await _tapMvpFormAction(
    tester,
    formListKey: 'event-form-list',
    action: find.widgetWithText(OutlinedButton, 'この予定を削除'),
    label: 'the personal-event delete action',
  );
  final confirmation = find.byType(AlertDialog);
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('予定を削除しますか？'),
    ),
    label: 'the personal-event deletion confirmation',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('端末ではすぐ非表示になり、削除は同期キューに保存されます。'),
    ),
    label: 'the queued deletion explanation',
  );
  await _tap(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.widgetWithText(FilledButton, '削除'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('カレンダー'),
    label: 'the calendar after deleting the personal event',
  );
  await _waitForGone(
    tester,
    find.text(title),
    label: 'the deleted personal event to disappear from the calendar',
  );
  expect(find.text(title), findsNothing);
}

Future<void> _openSettingsScheduleSync(WidgetTester tester) async {
  await _tap(tester, find.byTooltip('設定'));
  await _waitFor(
    tester,
    _appBarTitle('設定'),
    label: 'the production Settings screen',
  );
  await _tap(tester, find.text('Schedule sync'));
}

Future<void> _waitForSyncPhase(
  WidgetTester tester,
  ProviderContainer container,
  ScheduleSyncPhase phase, {
  required String label,
}) {
  return _waitForCondition(
    tester,
    () => container.read(scheduleSyncRuntimeProvider).phase == phase,
    label: label,
  );
}

Future<void> _waitForLocalSupabaseReachability(
  _AndroidE2eEnvironment environment, {
  required bool reachable,
  int requiredConsecutiveSuccesses = 1,
  http.Client? probeClient,
  required String label,
}) async {
  if (requiredConsecutiveSuccesses < 1) {
    throw ArgumentError.value(
      requiredConsecutiveSuccesses,
      'requiredConsecutiveSuccesses',
      'Must be at least one.',
    );
  }
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var consecutiveSuccesses = 0;
  while (true) {
    if (await _isLocalSupabaseReachable(
          environment,
          probeClient: probeClient,
        ) ==
        reachable) {
      consecutiveSuccesses++;
      if (consecutiveSuccesses >= requiredConsecutiveSuccesses) return;
    } else {
      consecutiveSuccesses = 0;
    }
    if (!DateTime.now().isBefore(deadline)) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $label.');
}

Future<bool> _isLocalSupabaseReachable(
  _AndroidE2eEnvironment environment, {
  http.Client? probeClient,
}) async {
  if (probeClient != null) {
    try {
      final response = await probeClient
          .get(environment.supabaseUrl.resolve('/auth/v1/health'))
          .timeout(const Duration(seconds: 1));
      return response.statusCode == HttpStatus.ok;
    } on Object {
      return false;
    }
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final request = await client
        .getUrl(environment.supabaseUrl.resolve('/auth/v1/health'))
        .timeout(const Duration(seconds: 1));
    final response = await request.close().timeout(const Duration(seconds: 1));
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<void> _assertNativeWidgetRejectsInvalidSnapshots({
  required String ownerUserId,
  required StorageRegion region,
}) async {
  final scope = await const NativeScopeBridge().current();
  expect(
    scope.matchesOwner(ownerUserId) &&
        scope.regionId == region.id &&
        scope.activationToken != null,
    isTrue,
    reason: 'The production runtime must establish the current owner scope.',
  );
  final storedBefore =
      await _widgetBridgePlatform.invokeMethod<String>('readSnapshot');
  expect(
    storedBefore,
    isNotNull,
    reason:
        'The production widget runtime must publish before rejection tests.',
  );
  final unsupported = Map<String, Object?>.from(
    jsonDecode(storedBefore!) as Map,
  )..['schemaVersion'] = 2;
  final invalidPayloads = <String>[
    '{',
    jsonEncode(unsupported),
  ];

  // Native authorization precedes payload parsing. A valid payload without
  // its active scope must still be rejected, before testing invalid payloads
  // under the real runtime-established scope below.
  await expectLater(
    _widgetBridgePlatform.invokeMethod<void>(
      'saveSnapshot',
      <String, Object?>{'payload': storedBefore},
    ),
    throwsA(
      isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'stale_widget_snapshot',
      ),
    ),
  );

  for (final payload in invalidPayloads) {
    await expectLater(
      _widgetBridgePlatform.invokeMethod<void>(
        'saveSnapshot',
        <String, Object?>{
          'payload': payload,
          'regionId': scope.regionId,
          'ownerHash': scope.ownerHash,
          'activationToken': scope.activationToken,
          'generation': scope.generation,
        },
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalid_widget_snapshot',
        ),
      ),
    );
  }

  expect(
    await _widgetBridgePlatform.invokeMethod<String>('readSnapshot'),
    storedBefore,
    reason: 'Rejected native payloads must not replace the last good snapshot.',
  );
}

Future<void> _waitForNativeWidgetCourse(
  WidgetTester tester, {
  required String title,
  required String room,
  required int weekday,
  required int periodNo,
  String? courseId,
}) async {
  Object? lastError;
  WidgetSnapshot? latest;
  for (var attempt = 0; attempt < 80; attempt++) {
    try {
      final payload =
          await _widgetBridgePlatform.invokeMethod<String>('readSnapshot');
      if (payload != null) {
        latest = WidgetSnapshot.fromJson(
          Map<String, Object?>.from(jsonDecode(payload) as Map),
        );
        final matches = latest.cells.where(
          (cell) =>
              cell.title == title &&
              cell.room == room &&
              cell.weekday == weekday &&
              cell.periodNo == periodNo &&
              (courseId == null || cell.courseId == courseId) &&
              cell.deepLink == 'unischedule://course/${cell.courseId}',
        );
        if (matches.length == 1) return;
      }
    } on Object catch (error) {
      lastError = error;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(
    'Native widget snapshot did not contain "$title" at '
    '$weekday/$periodNo. Latest snapshot: ${latest?.toJson()}; '
    'last error: $lastError',
  );
}

Future<void> _waitForNativeWidgetCourseRemoval(
  WidgetTester tester, {
  required String courseId,
}) async {
  Object? lastError;
  WidgetSnapshot? latest;
  for (var attempt = 0; attempt < 80; attempt++) {
    try {
      final payload =
          await _widgetBridgePlatform.invokeMethod<String>('readSnapshot');
      if (payload != null) {
        latest = WidgetSnapshot.fromJson(
          Map<String, Object?>.from(jsonDecode(payload) as Map),
        );
        if (!latest.cells.any((cell) => cell.courseId == courseId)) return;
      }
    } on Object catch (error) {
      lastError = error;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(
    'Native widget snapshot retained deleted course "$courseId". '
    'Latest snapshot: ${latest?.toJson()}; last error: $lastError',
  );
}

Future<void> _createCourse(
  WidgetTester tester, {
  required String title,
}) async {
  await _tap(tester, find.byTooltip('追加'));
  await _waitFor(
    tester,
    find.text('授業を追加'),
    label: 'the quick-add course action',
  );
  final quickAddRoute = ModalRoute.of(tester.element(find.text('授業を追加')));
  expect(quickAddRoute, isA<ModalBottomSheetRoute<dynamic>>());
  await _tap(tester, find.text('授業を追加'));
  await _waitFor(
    tester,
    find.text('授業を作成'),
    label: 'the course form',
  );
  await _waitForGone(
    tester,
    find.byType(BottomSheet),
    label: 'Quick Add to dismiss its course sheet before navigation',
  );
  await _waitForGone(
    tester,
    find.text('授業を追加'),
    label: 'the Quick Add course action to close before navigation',
  );
  await waitForPopupRouteDismissal(
    tester,
    quickAddRoute! as PopupRoute<dynamic>,
    label: 'the Quick Add course route and its overlay to finish dismissing',
  );
  await _waitForGone(
    tester,
    find.byType(ModalBarrier).hitTestable(),
    label: 'the blocking Quick Add barrier before course form interaction',
  );
  await tester.enterText(_textFormField('授業名'), title);
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('曜日'),
    optionText: find.text('火'),
    label: 'the Tuesday course option',
  );
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('時限'),
    optionText: find.text('2限'),
    label: 'the second-period option',
  );
  await tester.enterText(_textFormField('教室'), 'E2E-101');
  await tester.enterText(_textFormField('教員名'), 'E2E 教員');
  await _saveMvpForm(
    tester,
    formListKey: 'course-form-list',
    saveActionKey: 'course-save',
    label: 'the manual-course save action',
  );
  await _waitFor(
    tester,
    _appBarTitle('授業詳細'),
    label: 'the saved course detail screen',
  );
}

Future<void> _editManualCourse(
  WidgetTester tester, {
  required String currentTitle,
  required String updatedTitle,
  required String updatedRoom,
}) async {
  await _openTimetableWeekView(tester);
  await _waitFor(
    tester,
    find.text(currentTitle),
    label: 'the manual course before editing',
  );
  final courseCell = find.ancestor(
    of: find.text(currentTitle),
    matching: find.byType(InkWell),
  );
  await _tap(tester, courseCell);
  await _waitFor(
    tester,
    _appBarTitle('授業詳細'),
    label: 'the manual course detail before editing',
  );
  await _tap(tester, find.byTooltip('授業を編集'));
  await _waitFor(
    tester,
    _appBarTitle('授業を編集'),
    label: 'the manual course edit form',
  );
  await tester.enterText(_textFormField('授業名'), updatedTitle);
  await tester.enterText(_textFormField('教室'), updatedRoom);
  await tester.enterText(_textFormField('教員名'), 'E2E 更新教員');
  await _saveMvpForm(
    tester,
    formListKey: 'course-form-list',
    saveActionKey: 'course-save',
    label: 'the manual-course update action',
  );
  await _waitFor(
    tester,
    _appBarTitle('授業詳細'),
    label: 'the updated manual course detail',
  );
  await _waitFor(
    tester,
    find.text(updatedTitle),
    label: 'the updated manual course title',
  );
  expect(find.text(currentTitle), findsNothing);
  expect(find.text(updatedRoom), findsOneWidget);
}

Future<void> _deleteManualCourse(
  WidgetTester tester, {
  required String title,
}) async {
  await _openTimetableWeekView(tester);
  await _waitFor(
    tester,
    find.text(title),
    label: 'the updated manual course before deletion',
  );
  final courseCell = find.ancestor(
    of: find.text(title),
    matching: find.byType(InkWell),
  );
  await _tap(tester, courseCell);
  await _waitFor(
    tester,
    _appBarTitle('授業詳細'),
    label: 'the manual course deletion detail',
  );
  await _tap(tester, find.byTooltip('授業を削除'));
  final confirmation = find.byType(AlertDialog);
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('授業を削除しますか？'),
    ),
    label: 'the manual course deletion confirmation',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('紐づく課題・テストの履歴は残り、授業だけが非表示になります。'),
    ),
    label: 'the retained linked-history deletion explanation',
  );
  await _tap(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.widgetWithText(FilledButton, '削除'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('時間割'),
    label: 'the timetable after deleting the manual course',
  );
  await _openTimetableWeekView(tester);
  await _waitForGone(
    tester,
    find.text(title),
    label: 'the deleted manual course to disappear from the timetable',
  );
  expect(find.text(title), findsNothing);
}

Future<void> _editAndDeleteSubmittedAssignment(
  WidgetTester tester, {
  required String currentTitle,
  required String updatedTitle,
}) async {
  final originalCard = find.ancestor(
    of: find.text(currentTitle),
    matching: find.byType(Card),
  );
  await _waitFor(
    tester,
    originalCard,
    label: 'the submitted assignment before editing',
  );
  await _tap(
    tester,
    find.descendant(
      of: originalCard,
      matching: find.byTooltip('「$currentTitle」を編集'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('課題を編集'),
    label: 'the submitted assignment edit form',
  );
  await _waitFor(
    tester,
    _textFormField('課題名'),
    label: 'the loaded submitted assignment edit form',
  );
  await _selectNoCourseForOrphanedLink(tester, entityLabel: 'assignment');
  await _enterMvpFormText(
    tester,
    formListKey: 'assignment-form-list',
    fieldLabel: '課題名',
    value: updatedTitle,
    scrollDelta: -180,
    label: 'the submitted assignment title after clearing its deleted course',
  );
  await _enterMvpFormText(
    tester,
    formListKey: 'assignment-form-list',
    fieldLabel: 'メモ',
    value: '更新後も非公開の E2E メモ',
    scrollDelta: 180,
    label: 'the submitted assignment memo after clearing its deleted course',
  );
  await _saveMvpForm(
    tester,
    formListKey: 'assignment-form-list',
    saveActionKey: 'assignment-save',
    label: 'the assignment update action',
  );
  await _waitFor(
    tester,
    _appBarTitle('課題・テスト'),
    label: 'the assignment list after editing',
  );
  await _selectSubmittedAssignmentFilter(
    tester,
    label: 'the submitted assignment filter after editing',
  );
  await _waitFor(
    tester,
    find.text(updatedTitle),
    label: 'the updated submitted assignment',
  );
  expect(find.text(currentTitle), findsNothing);
  await _waitFor(
    tester,
    find.textContaining('提出済み · 履歴に保存'),
    label: 'the submitted history after assignment editing',
  );

  final updatedCard = find.ancestor(
    of: find.text(updatedTitle),
    matching: find.byType(Card),
  );
  await _tap(
    tester,
    find.descendant(
      of: updatedCard,
      matching: find.byTooltip('「$updatedTitle」を編集'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('課題を編集'),
    label: 'the updated assignment deletion form',
  );
  await _waitFor(
    tester,
    _textFormField('課題名'),
    label: 'the loaded updated assignment deletion form',
  );
  final deleteButton = find.widgetWithText(OutlinedButton, 'この課題を削除');
  await _tapMvpFormAction(
    tester,
    formListKey: 'assignment-form-list',
    action: deleteButton,
    label: 'the assignment delete action',
  );
  final confirmation = find.byType(AlertDialog);
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('課題を削除しますか？'),
    ),
    label: 'the assignment deletion confirmation',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('端末ではすぐ非表示になり、削除は同期キューに保存されます。'),
    ),
    label: 'the assignment queued-deletion explanation',
  );
  await _tap(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.widgetWithText(FilledButton, '削除'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('課題・テスト'),
    label: 'the assignment list after deletion',
  );
  await _selectSubmittedAssignmentFilter(
    tester,
    label: 'the submitted assignment filter after deletion',
  );
  await _waitForGone(
    tester,
    find.text(updatedTitle),
    label: 'the deleted submitted assignment to disappear from history',
  );
  expect(find.text(updatedTitle), findsNothing);
}

Future<void> _editAndDeleteCourseLinkedExam(
  WidgetTester tester, {
  required String currentTitle,
  required String updatedTitle,
}) async {
  await _tap(tester, find.byTooltip('テスト一覧'));
  await _waitFor(
    tester,
    _appBarTitle('テスト'),
    label: 'the production exam list before editing',
  );
  await _waitFor(
    tester,
    find.text(currentTitle),
    label: 'the course-linked exam before editing',
  );
  await _tap(tester, find.text(currentTitle));
  await _waitFor(
    tester,
    _appBarTitle('テストを編集'),
    label: 'the course-linked exam edit form',
  );
  await _waitFor(
    tester,
    _textFormField('テスト名'),
    label: 'the loaded course-linked exam edit form',
  );
  await _selectNoCourseForOrphanedLink(tester, entityLabel: 'exam');
  await _enterMvpFormText(
    tester,
    formListKey: 'exam-form-list',
    fieldLabel: 'テスト名',
    value: updatedTitle,
    scrollDelta: -180,
    label: 'the course-linked exam title after clearing its deleted course',
  );
  await _enterMvpFormText(
    tester,
    formListKey: 'exam-form-list',
    fieldLabel: '教室',
    value: 'E2E-EXAM-UPDATED',
    scrollDelta: 180,
    label: 'the course-linked exam room after clearing its deleted course',
  );
  await _saveMvpForm(
    tester,
    formListKey: 'exam-form-list',
    saveActionKey: 'exam-save',
    label: 'the course-linked exam update action',
  );
  await _waitFor(
    tester,
    _appBarTitle('テスト'),
    label: 'the exam list after editing',
  );
  await _waitFor(
    tester,
    find.text(updatedTitle),
    label: 'the updated course-linked exam',
  );
  expect(find.text(currentTitle), findsNothing);

  await _tap(tester, find.text(updatedTitle));
  await _waitFor(
    tester,
    _appBarTitle('テストを編集'),
    label: 'the updated course-linked exam deletion form',
  );
  await _waitFor(
    tester,
    _textFormField('テスト名'),
    label: 'the loaded updated course-linked exam deletion form',
  );
  final deleteButton = find.widgetWithText(OutlinedButton, 'このテストを削除');
  await _tapMvpFormAction(
    tester,
    formListKey: 'exam-form-list',
    action: deleteButton,
    label: 'the course-linked exam delete action',
  );
  final confirmation = find.byType(AlertDialog);
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('テストを削除しますか？'),
    ),
    label: 'the course-linked exam deletion confirmation',
  );
  await _waitFor(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.text('端末ではすぐ非表示になり、削除は同期キューに保存されます。'),
    ),
    label: 'the exam queued-deletion explanation',
  );
  await _tap(
    tester,
    find.descendant(
      of: confirmation,
      matching: find.widgetWithText(FilledButton, '削除'),
    ),
  );
  await _waitFor(
    tester,
    _appBarTitle('テスト'),
    label: 'the exam list after deletion',
  );
  await _waitForGone(
    tester,
    find.text(updatedTitle),
    label: 'the deleted course-linked exam to disappear from the list',
  );
  expect(find.text(updatedTitle), findsNothing);
}

Future<void> _selectNoCourseForOrphanedLink(
  WidgetTester tester, {
  required String entityLabel,
}) async {
  await _waitFor(
    tester,
    find.text(_orphanedCourseLinkNotice),
    label: 'the orphaned $entityLabel course warning',
  );
  await _waitFor(
    tester,
    find.text(_orphanedCourseLinkSentinel),
    label: 'the orphaned $entityLabel course sentinel',
  );
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('授業'),
    optionText: find.text('なし'),
    label: 'the explicit no-course $entityLabel option',
  );
  await _waitForGone(
    tester,
    find.text(_orphanedCourseLinkSentinel),
    label: 'the cleared orphaned $entityLabel course sentinel',
  );
}

void _assertRemoteEntityUpdatedThenDeleted(
  Iterable<ScheduleDeltaChange> changes, {
  required String entityType,
  required String entityId,
  required String updatedTitle,
  required bool expectClearedCourseLink,
}) {
  final updated = changes.singleWhere(
    (change) =>
        change.entityType == entityType &&
        change.entityId == entityId &&
        change.operation == ScheduleDeltaOperation.upsert,
  );
  expect(updated.payload['title'], updatedTitle);
  expect(updated.deletedAt, isNull);
  if (expectClearedCourseLink) {
    expect(updated.payload, containsPair('courseId', isNull));
  }
  final deleted = changes.singleWhere(
    (change) =>
        change.entityType == entityType &&
        change.entityId == entityId &&
        change.operation == ScheduleDeltaOperation.delete,
  );
  expect(deleted.deletedAt, isNotNull);
  expect(deleted.payload['deletedAt'], isNotNull);
  expect(updated.changeCursor, lessThan(deleted.changeCursor));
  expect(deleted.serverVersion, greaterThan(updated.serverVersion));
}

Future<_UniversityRequestE2eResult> _createAndVerifyUniversityRequest(
  WidgetTester tester, {
  required SupabaseClient client,
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
}) async {
  await _tap(tester, find.byTooltip('設定'));
  await _waitFor(
    tester,
    _appBarTitle('設定'),
    label: 'the production settings before the university request',
  );
  await _tap(tester, find.text('大学・学期・時限'));
  await _waitFor(
    tester,
    _appBarTitle('大学・学期・時限'),
    label: 'the authenticated university settings before the request',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('university-settings-list')),
    label: 'the authenticated university settings list',
  );
  await _scrollUniversitySettingsTo(
    tester,
    find.byKey(const Key('request-university-button')),
    label: 'the university request action',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('request-university-button')),
    label: 'the university request action',
  );
  await _tap(tester, find.byKey(const Key('request-university-button')));
  await _waitFor(
    tester,
    find.text('未登録大学を申請'),
    label: 'the university request dialog',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-name')),
    environment.universityRequestTitle,
    label: 'the university request name',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-prefecture')),
    '石川県',
    label: 'the university request prefecture',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('university-request-url')),
    'https://university.example.test',
    label: 'the university request official URL',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tap(
    tester,
    find.byKey(const Key('submit-university-request-button')),
  );
  await _waitFor(
    tester,
    find.text('大学追加申請を受け付けました'),
    label: 'the accepted university request acknowledgement',
  );
  await _scrollUniversitySettingsTo(
    tester,
    find.text(environment.universityRequestTitle),
    label: 'the submitted university request history item',
  );
  await _waitFor(
    tester,
    find.text(environment.universityRequestTitle),
    label: 'the submitted university request history item',
  );
  await _waitFor(
    tester,
    find.text('審査中'),
    label: 'the pending university request status',
  );

  final requestRow = await client
      .from('university_requests')
      .select(
        'id,requested_by,name,normalized_name,prefecture,official_url,status',
      )
      .eq('name', environment.universityRequestTitle)
      .maybeSingle();
  expect(requestRow, isNotNull);
  final request = Map<String, Object?>.from(requestRow! as Map);
  final requestId = request['id'];
  expect(requestId, isA<String>());
  expect(request['requested_by'], ownerUserId);
  expect(request['name'], environment.universityRequestTitle);
  expect(
    request['normalized_name'],
    environment.universityRequestNormalizedTitle,
  );
  expect(request['prefecture'], '石川県');
  expect(request['official_url'], 'https://university.example.test');
  expect(request['status'], 'pending');

  return _UniversityRequestE2eResult(id: requestId as String);
}

Future<_PersonalTermE2eResult> _createAndVerifyCustomTermPeriod(
  WidgetTester tester, {
  required ProviderContainer container,
  required SupabaseClient client,
  required String ownerUserId,
  required _AndroidE2eEnvironment environment,
}) async {
  final originalContext = container.read(activeScheduleContextProvider);
  expect(originalContext, isNotNull);
  final originalTermId = originalContext!.termId;

  await _tap(tester, find.byTooltip('設定'));
  await _waitFor(
    tester,
    _appBarTitle('設定'),
    label: 'the production settings before personal term management',
  );
  await _tap(tester, find.text('大学・学期・時限'));
  await _waitFor(
    tester,
    _appBarTitle('大学・学期・時限'),
    label: 'the authenticated university settings',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('open-term-period-management')),
    label: 'the personal term-period management entry point',
  );
  await _tap(
    tester,
    find.byKey(const Key('open-term-period-management')),
  );
  await _waitFor(
    tester,
    _appBarTitle('学期・時限管理'),
    label: 'the production personal term-period management screen',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('term-period-management-list')),
    label: 'the active personal term-period management list',
    diagnostic: () => _safeTermPeriodDiagnostic(container, tester),
  );
  await _waitForCondition(
    tester,
    () {
      final snapshot = container.read(personalTermPeriodSnapshotProvider);
      final periods = container.read(
        personalPeriodSettingsProvider(originalTermId),
      );
      return snapshot.valueOrNull?.activeTerm?.id == originalTermId &&
          !periods.isLoading &&
          (periods.valueOrNull != null || periods.hasError);
    },
    label: 'the active personal period settings before term creation',
    diagnostic: () => _safeTermPeriodDiagnostic(container, tester),
  );
  final originalPeriods = container.read(
    personalPeriodSettingsProvider(originalTermId),
  );
  expect(
    originalPeriods.hasError,
    isFalse,
    reason:
        'The active personal period settings must load before term creation (error type: ${originalPeriods.hasError ? originalPeriods.error.runtimeType : 'none'}).',
  );
  expect(
    originalPeriods.valueOrNull,
    isNotNull,
    reason: 'The active personal period settings must contain loaded data.',
  );
  await tester.pump();
  await _scrollTermPeriodManagementTo(
    tester,
    find.byKey(const Key('create-personal-term-button')),
    label: 'the personal term creation action',
  );
  await _waitFor(
    tester,
    find.byKey(const Key('create-personal-term-button')),
    label: 'the personal term creation action',
    diagnostic: () => _safeTermPeriodDiagnostic(container, tester),
  );
  await _tap(tester, find.byKey(const Key('create-personal-term-button')));
  await _waitFor(
    tester,
    find.text('学期を追加'),
    label: 'the personal term creation dialog',
  );

  await _scrollDialogTo(
    tester,
    find.text('カスタム入力'),
    label: 'the custom term creation mode',
  );
  await _tap(tester, find.text('カスタム入力').last);
  await _waitFor(
    tester,
    find.byKey(const Key('custom-term-name')),
    label: 'the custom term form fields',
  );
  await _scrollDialogTo(
    tester,
    find.byKey(const Key('custom-term-type')),
    label: 'the custom term type selector',
  );
  await _selectDropdownMenuOption(
    tester,
    field: find.byKey(const Key('custom-term-type')),
    optionText: find.text('集中講義'),
    label: 'the intensive personal term type option',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('custom-term-name')),
    environment.customTermTitle,
    label: 'the custom term name',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('custom-term-year')),
    '2026',
    label: 'the custom term academic year',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('custom-term-start-date')),
    '2026-10-01',
    label: 'the custom term start date',
  );
  await _enterDialogText(
    tester,
    find.byKey(const Key('custom-term-end-date')),
    '2026-10-21',
    label: 'the custom term end date',
  );
  await _scrollDialogTo(
    tester,
    find.text('時限を手動編集'),
    label: 'the custom period source mode',
  );
  await _tap(tester, find.text('時限を手動編集').last);
  await _scrollDialogTo(
    tester,
    find.byKey(const Key('add-custom-period-button')),
    label: 'the manual period row action',
  );
  await _tap(tester, find.byKey(const Key('add-custom-period-button')));
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-day-0')),
    '1',
    label: 'the manual period weekday',
  );
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-number-0')),
    '1',
    label: 'the manual period number',
  );
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-start-0')),
    '08:50',
    label: 'the manual period start time',
  );
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-end-0')),
    '10:10',
    label: 'the manual period end time',
  );
  await _scrollDialogTo(
    tester,
    find.byKey(const Key('new-term-make-active')),
    label: 'the make-active selection',
  );
  final makeActive = tester.widget<SwitchListTile>(
    find.byKey(const Key('new-term-make-active')),
  );
  expect(makeActive.value, isTrue);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tap(
    tester,
    find.byKey(const Key('draft-create-personal-term-button')),
  );
  await _waitFor(
    tester,
    find.text('新しい学期を作成しますか？'),
    label: 'the custom personal term confirmation',
  );
  await _tap(tester, find.byKey(const Key('confirm-create-personal-term')));
  await _waitForCondition(
    tester,
    () {
      final snapshot = container.read(personalTermPeriodSnapshotProvider);
      return snapshot.valueOrNull?.activeTerm?.name ==
          environment.customTermTitle;
    },
    label: 'the created custom personal term in the authenticated snapshot',
    diagnostic: () => _safeTermCreationDiagnostic(
      container,
      tester,
      expectedTermTitle: environment.customTermTitle,
    ),
  );
  final createdSnapshot =
      container.read(personalTermPeriodSnapshotProvider).valueOrNull;
  expect(createdSnapshot, isNotNull);
  final createdTerm = createdSnapshot!.activeTerm;
  expect(createdTerm, isNotNull);
  final createdTermId = createdTerm!.id;
  final createdTermTile = find.byKey(ValueKey('personal-term-$createdTermId'));
  final createdTermTitle = find.descendant(
    of: createdTermTile,
    matching: find.text(environment.customTermTitle),
  );
  await _scrollTermPeriodManagementTo(
    tester,
    createdTermTile,
    label: 'the created custom personal term',
  );
  await _waitFor(
    tester,
    createdTermTitle,
    label: 'the created custom personal term',
    diagnostic: () => _safeTermCreationDiagnostic(
      container,
      tester,
      expectedTermTitle: environment.customTermTitle,
    ),
  );
  await _scrollTermPeriodManagementTo(
    tester,
    find.text('月曜 第1時限'),
    label: 'the active custom manual period',
    scrollDelta: -180,
  );
  await _waitFor(
    tester,
    find.text('月曜 第1時限'),
    label: 'the active custom manual period',
    diagnostic: () => _safeTermCreationDiagnostic(
      container,
      tester,
      expectedTermTitle: environment.customTermTitle,
    ),
  );
  await _waitFor(
    tester,
    find.text('08:50 〜 10:10'),
    label: 'the active custom manual period time',
    diagnostic: () => _safeTermCreationDiagnostic(
      container,
      tester,
      expectedTermTitle: environment.customTermTitle,
    ),
  );
  await _waitForCondition(
    tester,
    () =>
        container.read(activeScheduleContextProvider)?.termId == createdTermId,
    label: 'the active schedule context to use the custom personal term',
  );
  final activeContext = container.read(activeScheduleContextProvider);
  expect(activeContext, isNotNull);
  final termId = activeContext!.termId;
  expect(termId, isNot(originalTermId));
  expect(termId, createdTermId);

  final profileRow = await client
      .from('profiles')
      .select('user_id,active_term_id')
      .eq('user_id', ownerUserId)
      .maybeSingle();
  expect(profileRow, isNotNull);
  final profile = Map<String, Object?>.from(profileRow! as Map);
  expect(profile['user_id'], ownerUserId);
  expect(profile['active_term_id'], termId);

  final termRow = await client
      .from('terms')
      .select(
        'id,owner_user_id,university_id,name,academic_year,start_date,'
        'end_date,term_type,source_template_id,is_template,status,deleted_at',
      )
      .eq('id', termId)
      .maybeSingle();
  expect(termRow, isNotNull);
  final term = Map<String, Object?>.from(termRow! as Map);
  expect(term['id'], termId);
  expect(term['owner_user_id'], ownerUserId);
  expect(term['name'], environment.customTermTitle);
  expect(term['academic_year'], 2026);
  expect(term['start_date'], '2026-10-01');
  expect(term['end_date'], '2026-10-21');
  expect(term['term_type'], 'intensive');
  expect(term['source_template_id'], isNull);
  expect(term['is_template'], isFalse);
  expect(term['status'], 'active');
  expect(term['deleted_at'], isNull);

  final periodRows = await client
      .from('period_settings')
      .select(
        'owner_user_id,term_id,source_template_set_id,day_of_week,period_no,'
        'start_time,end_time,deleted_at',
      )
      .eq('owner_user_id', ownerUserId)
      .eq('term_id', termId)
      .isFilter('deleted_at', null);
  expect(periodRows, isA<List>());
  final periods = [
    for (final row in periodRows as List) Map<String, Object?>.from(row as Map),
  ];
  expect(periods, hasLength(1));
  final period = periods.single;
  expect(period['owner_user_id'], ownerUserId);
  expect(period['term_id'], termId);
  expect(period['source_template_set_id'], isNull);
  expect(period['day_of_week'], 1);
  expect(period['period_no'], 1);
  expect(period['start_time'].toString(), startsWith('08:50'));
  expect(period['end_time'].toString(), startsWith('10:10'));

  await _replaceAndVerifyActivePersonalPeriodSettings(
    tester,
    container: container,
    termId: termId,
  );
  final replacedPeriodRows = await client
      .from('period_settings')
      .select(
        'owner_user_id,term_id,source_template_set_id,day_of_week,period_no,'
        'start_time,end_time,deleted_at',
      )
      .eq('owner_user_id', ownerUserId)
      .eq('term_id', termId)
      .isFilter('deleted_at', null);
  expect(replacedPeriodRows, isA<List>());
  final replacedPeriods = [
    for (final row in replacedPeriodRows as List)
      Map<String, Object?>.from(row as Map),
  ];
  expect(replacedPeriods, hasLength(1));
  final replacedPeriod = replacedPeriods.single;
  expect(replacedPeriod['owner_user_id'], ownerUserId);
  expect(replacedPeriod['term_id'], termId);
  expect(replacedPeriod['source_template_set_id'], isNull);
  expect(replacedPeriod['day_of_week'], 1);
  expect(replacedPeriod['period_no'], 1);
  expect(replacedPeriod['start_time'].toString(), startsWith('09:00'));
  expect(replacedPeriod['end_time'].toString(), startsWith('10:30'));

  return _PersonalTermE2eResult(id: termId);
}

Future<void> _replaceAndVerifyActivePersonalPeriodSettings(
  WidgetTester tester, {
  required ProviderContainer container,
  required String termId,
}) async {
  await _waitFor(
    tester,
    find.byKey(const Key('edit-active-period-settings')),
    label: 'the active personal period edit action',
  );
  await _tapMvpFormAction(
    tester,
    formListKey: 'term-period-management-list',
    action: find.byKey(const Key('edit-active-period-settings')),
    label: 'the active personal period edit action',
  );
  await _waitFor(
    tester,
    find.text('時限設定を編集'),
    label: 'the active personal period edit dialog',
  );
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-start-0')),
    '09:00',
    label: 'the replacement personal period start time',
  );
  await _enterDialogText(
    tester,
    find.byKey(const ValueKey('period-draft-end-0')),
    '10:30',
    label: 'the replacement personal period end time',
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await _tap(
    tester,
    find.byKey(const Key('save-period-settings-draft-button')),
  );
  await _waitFor(
    tester,
    find.text('時限設定を置き換えますか？'),
    label: 'the active personal period replacement confirmation',
  );
  await _tap(
    tester,
    find.byKey(const Key('confirm-replace-personal-periods')),
  );
  await _waitFor(
    tester,
    find.text('時限設定を更新しました'),
    label: 'the active personal period replacement acknowledgement',
  );
  await _scrollTermPeriodManagementTo(
    tester,
    find.text('09:00 〜 10:30'),
    label: 'the updated active personal period time',
    scrollDelta: -180,
  );
  await _waitFor(
    tester,
    find.text('09:00 〜 10:30'),
    label: 'the updated active personal period time',
  );
  await _waitForCondition(
    tester,
    () {
      if (container.read(activeScheduleContextProvider)?.termId != termId) {
        return false;
      }
      final periods =
          container.read(personalPeriodSettingsProvider(termId)).valueOrNull;
      if (periods == null || periods.length != 1) return false;
      final period = periods.single;
      return period.sourceTemplateSetId == null &&
          period.dayOfWeek == 1 &&
          period.periodNo == 1 &&
          period.startTimeMinutes == 9 * 60 &&
          period.endTimeMinutes == 10 * 60 + 30;
    },
    label: 'the active personal period state after replacement',
  );
}

Future<void> _assertSecondUserCannotReadFirstUserTerm(
  SupabaseClient client, {
  required String termId,
}) async {
  final term =
      await client.from('terms').select('id').eq('id', termId).maybeSingle();
  expect(term, isNull);
  final periods =
      await client.from('period_settings').select('id').eq('term_id', termId);
  expect(periods, isA<List>());
  expect(periods, isEmpty);
}

Future<void> _assertSecondUserCannotReadFirstUserUniversityRequest(
  SupabaseClient client, {
  required String requestId,
}) async {
  final request = await client
      .from('university_requests')
      .select('id')
      .eq('id', requestId)
      .maybeSingle();
  expect(request, isNull);
}

Future<void> _enterDialogText(
  WidgetTester tester,
  Finder finder,
  String value, {
  required String label,
}) async {
  await _scrollDialogTo(tester, finder, label: label);
  await _tap(tester, finder);
  await tester.enterText(finder.first, value);
  await tester.pump();
}

Future<void> _scrollDialogTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
}) async {
  await _waitFor(tester, finder, label: label);
  final dialogScrollables = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    dialogScrollables,
    label: 'the scrollable dialog containing $label',
  );
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: dialogScrollables.last,
  );
  await tester.pump();
}

Future<void> _scrollTermPeriodManagementTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
  double scrollDelta = 180,
}) async {
  final pageScrollables = find.descendant(
    of: find.byKey(const Key('term-period-management-list')),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    pageScrollables,
    label: 'the personal term-period list scrollable for $label',
  );
  await tester.scrollUntilVisible(
    finder,
    scrollDelta,
    scrollable: pageScrollables.first,
  );
  await tester.pump();
}

Future<void> _scrollUniversitySettingsTo(
  WidgetTester tester,
  Finder finder, {
  required String label,
}) async {
  final pageScrollables = find.descendant(
    of: find.byKey(const Key('university-settings-list')),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    pageScrollables,
    label: 'the university settings list scrollable for $label',
  );
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: pageScrollables.first,
  );
  await tester.pump();
}

Future<void> _createExam(
  WidgetTester tester, {
  required String title,
  String? courseTitle,
}) async {
  await _tap(tester, find.byTooltip('追加'));
  await _waitFor(
    tester,
    find.text('テストを追加'),
    label: 'the Quick Add exam action',
  );
  await _tap(tester, find.text('テストを追加'));
  await _waitFor(
    tester,
    _appBarTitle('テストを作成'),
    label: 'the production exam form',
  );
  await _waitForGone(
    tester,
    find.byType(BottomSheet),
    label: 'Quick Add to dismiss its exam sheet before navigation',
  );
  await _waitForGone(
    tester,
    find.text('テストを追加'),
    label: 'the Quick Add exam action to close before navigation',
  );
  await tester.enterText(_textFormField('テスト名'), title);
  final selectedCourse = courseTitle ?? 'なし';
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('授業'),
    optionText: find.text(selectedCourse),
    label: 'the $selectedCourse exam course option',
  );
  await tester.enterText(_textFormField('教室'), 'E2E-EXAM');
  await tester.enterText(
    _textFormField('種別'),
    courseTitle == null ? '確認' : '中間',
  );
  await _saveMvpForm(
    tester,
    formListKey: 'exam-form-list',
    saveActionKey: 'exam-save',
    label: 'the exam save action',
  );
  await _waitFor(
    tester,
    _appBarTitle('テスト'),
    label: 'the saved production exam list',
  );
  await _waitFor(tester, find.text(title), label: 'the saved exam');
}

Future<void> _createAssignment(
  WidgetTester tester, {
  required String title,
  required String courseTitle,
  required DateTime dueAt,
}) async {
  await _openNavigationDestination(tester, '課題・テスト');
  await _tap(tester, find.byTooltip('課題を追加'));
  await _waitFor(
    tester,
    find.text('課題を作成'),
    label: 'the assignment form',
  );
  await tester.enterText(_textFormField('課題名'), title);
  await _dismissAndroidKeyboard(
    tester,
    label: 'the explicit assignment deadline picker',
    layoutContext: find.byKey(const Key('assignment-form-list')),
  );
  await _tap(tester, find.byKey(const Key('assignment-due-field')));
  await chooseOpenDateTimePickers(
    tester,
    civilDateTime: JapanTime.civil(dueAt).pickerDateTime,
  );
  await _selectDropdownMenuOption(
    tester,
    field: _dropdownFormField('授業'),
    optionText: find.text(courseTitle),
    label: 'the created course in the assignment form',
  );
  expect(_textFormField('提出URL'), findsNothing);
  await _enterMvpFormText(
    tester,
    formListKey: 'assignment-form-list',
    fieldLabel: 'メモ',
    value: '公開しない E2E メモ',
    scrollDelta: 180,
    label: 'the assignment private memo',
  );
  await _saveMvpForm(
    tester,
    formListKey: 'assignment-form-list',
    saveActionKey: 'assignment-save',
    label: 'the assignment save action',
  );
  await _waitFor(
    tester,
    _appBarTitle('課題・テスト'),
    label: 'the saved assignment list',
  );
}

Future<void> _saveMvpForm(
  WidgetTester tester, {
  required String formListKey,
  required String saveActionKey,
  required String label,
}) async {
  final formList = find.byKey(Key(formListKey));
  expect(formList, findsOneWidget);
  await _dismissAndroidKeyboard(
    tester,
    label: label,
    layoutContext: formList,
  );
  final formScrollables = find.descendant(
    of: formList,
    matching: find.byType(Scrollable),
  );
  final saveAction = find.descendant(
    of: formList,
    matching: find.byKey(Key(saveActionKey)),
  );
  await _waitFor(
    tester,
    formScrollables,
    label: 'the form scrollable for $label',
  );
  Future<void> materializeSaveAction() async {
    await tester.scrollUntilVisible(
      saveAction,
      180,
      scrollable: formScrollables.first,
    );
    expect(saveAction, findsOneWidget);
  }

  await materializeSaveAction();
  await _scrollMvpActionIntoSafeTapArea(
    tester,
    action: saveAction,
    scrollable: formScrollables,
    label: label,
    actionAlreadyVisible: true,
    rematerializeAction: materializeSaveAction,
  );
  final saveButton = tester.widget<FilledButton>(saveAction);
  expect(saveButton.onPressed, isNotNull);
  final tappableSaveSurface = find
      .descendant(
        of: saveAction,
        matching: find.byType(InkWell),
      )
      .hitTestable();
  if (tappableSaveSurface.evaluate().length != 1) {
    final actionRect = tester.getRect(saveAction);
    final snackBarCount = find.byType(SnackBar).hitTestable().evaluate().length;
    final modalBarrierCount = find.byType(ModalBarrier).evaluate().length;
    final hitTest = tester.hitTestOnBinding(actionRect.center);
    fail(
      'E2E_FAILURE: $label is enabled and inside the computed safe area but '
      'its interactive surface is not hit-testable '
      '(actionRect=$actionRect snackBars=$snackBarCount '
      'modalBarriers=$modalBarrierCount hitTest=$hitTest).',
    );
  }
  await tester.tap(tappableSaveSurface);
  await tester.pump();
}

Future<void> _tapMvpFormAction(
  WidgetTester tester, {
  required String formListKey,
  required Finder action,
  required String label,
}) async {
  final formList = find.byKey(Key(formListKey));
  expect(formList, findsOneWidget);
  final formScrollables = find.descendant(
    of: formList,
    matching: find.byType(Scrollable),
  );
  final scopedAction = find.descendant(of: formList, matching: action);
  await _waitFor(
    tester,
    formScrollables,
    label: 'the form scrollable for $label',
  );

  Future<void> materializeAction() async {
    await tester.scrollUntilVisible(
      scopedAction,
      200,
      scrollable: formScrollables.first,
    );
    expect(scopedAction, findsOneWidget);
  }

  await materializeAction();
  await _scrollMvpActionIntoSafeTapArea(
    tester,
    action: scopedAction,
    scrollable: formScrollables,
    label: label,
    actionAlreadyVisible: true,
    rematerializeAction: materializeAction,
  );
  final tappableAction = scopedAction.hitTestable();
  expect(tappableAction, findsOneWidget);
  await tester.tap(tappableAction);
  await tester.pump();
}

Future<void> _enterMvpFormText(
  WidgetTester tester, {
  required String formListKey,
  required String fieldLabel,
  required String value,
  required double scrollDelta,
  required String label,
}) async {
  final formScrollables = find.descendant(
    of: find.byKey(Key(formListKey)),
    matching: find.byType(Scrollable),
  );
  await _waitFor(
    tester,
    formScrollables,
    label: 'the form scrollable for $label',
  );
  final field = _textFormField(fieldLabel);
  await tester.scrollUntilVisible(
    field,
    scrollDelta,
    scrollable: formScrollables.first,
  );
  expect(field, findsOneWidget);
  // The field has just been brought into the form viewport. Do not call the
  // generic tap helper here: its default ensureVisible alignment can move a
  // text field beneath the persistent app bar before it receives the tap.
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _filterAssignmentsForCourse(
  WidgetTester tester, {
  required ProviderContainer container,
  required String title,
  required String courseTitle,
  required String expectedCourseId,
}) async {
  await _waitForCondition(
    tester,
    () {
      final state = container.read(demoAppControllerProvider).valueOrNull;
      final assignments = state?.assignments
          .where((assignment) => assignment.title == title)
          .toList(growable: false);
      return assignments?.length == 1 &&
          assignments!.single.courseId == expectedCourseId;
    },
    label: 'the linked assignment state before course filtering',
    diagnostic: () => _safeAssignmentCourseFilterDiagnostic(
      container,
      title,
      expectedCourseId,
    ),
  );
  final state = container.read(demoAppControllerProvider).valueOrNull;
  expect(state, isNotNull);
  final assignment = state!.assignments.singleWhere(
    (item) => item.title == title,
  );
  expect(assignment.courseId, expectedCourseId);
  final linkedCourseId = expectedCourseId;
  final coursesById = {
    for (final course in state.courses) course.id: course,
    for (final course in state.assignmentCourses) course.id: course,
  };
  final linkedCourse = coursesById[linkedCourseId];
  expect(linkedCourse, isNotNull);
  expect(linkedCourse!.title, courseTitle);

  final courseFilter = find.byKey(const Key('assignment-course-filter'));
  final courseOptionKey = ValueKey<String>(
    'assignment-course-option-$linkedCourseId',
  );
  await _selectDropdownMenuItemByKey(
    tester,
    field: courseFilter,
    optionKey: courseOptionKey,
    label: 'the assignment course in the course filter',
  );
  await _waitFor(
    tester,
    find.text(title),
    label: 'the assignment filtered by its linked course',
  );
}

Future<void> _waitForDropdownMenuItemKey(
  WidgetTester tester, {
  required Finder field,
  required Key optionKey,
  required String label,
}) {
  return _waitForCondition(
    tester,
    () {
      if (field.evaluate().length != 1) return false;
      final dropdownButton = find.descendant(
        of: field,
        matching: find.byWidgetPredicate(
          (widget) => widget is DropdownButton,
          description: 'a dropdown button',
        ),
      );
      if (dropdownButton.evaluate().length != 1) return false;
      final dropdown = tester.widget<DropdownButton<dynamic>>(dropdownButton);
      return (dropdown.items ?? const <DropdownMenuItem<dynamic>>[]).any(
        (item) => item.key == optionKey,
      );
    },
    label: label,
  );
}

Future<void> _selectDropdownMenuItemByKey(
  WidgetTester tester, {
  required Finder field,
  required Key optionKey,
  required String label,
}) async {
  // Position the field before checking its final readiness. Flutter snapshots
  // DropdownButton.items when the popup opens, so the asserted item/value and
  // the tapped field must come from the same rendered frame.
  await tester.ensureVisible(field);
  await tester.pump();
  await _waitForDropdownMenuItemKey(
    tester,
    field: field,
    optionKey: optionKey,
    label: 'the keyed $label in the visible field',
  );
  final fieldElements = field.evaluate().toList(growable: false);
  expect(fieldElements, hasLength(1));
  final readyFieldElement = fieldElements.single;
  final readyField = find.byElementPredicate(
    (element) => identical(element, readyFieldElement),
    description: 'the ready DropdownButton field for $label',
  );
  final dropdownButton = find.descendant(
    of: readyField,
    matching: find.byWidgetPredicate(
      (widget) => widget is DropdownButton,
      description: 'the ready dropdown button for $label',
    ),
  );
  expect(dropdownButton, findsOneWidget);
  final dropdown = tester.widget<DropdownButton<dynamic>>(dropdownButton);
  final sourceItems = (dropdown.items ?? const <DropdownMenuItem<dynamic>>[])
      .where((item) => item.key == optionKey)
      .toList(growable: false);
  expect(sourceItems, hasLength(1));
  final expectedValue = sourceItems.single.value;
  final expectedFieldValue =
      tester.state<FormFieldState<dynamic>>(readyField).value;
  // Resolve the framework's decorated DropdownButton GestureDetector rather
  // than tapping the broader FormField render subtree. If Android consumes
  // that first real gesture without creating a PopupRoute, the driver may
  // retry once only after revalidating the live field/key/value snapshot and
  // proving that no current popup exists.
  await openVerifiedDropdownWithSingleRetry(
    tester,
    field: field,
    optionKey: optionKey,
    expectedOptionValue: expectedValue,
    expectedFieldValue: expectedFieldValue,
    label: label,
  );
  final openMenuItem = await _waitForSinglePopupDropdownItem(
    tester,
    find.byKey(optionKey),
    label: label,
  );
  expect(openMenuItem, findsOneWidget);
  expect(
    tester.widget<DropdownMenuItem<dynamic>>(openMenuItem).value,
    expectedValue,
  );
  await tester.tapAt(tester.getCenter(openMenuItem));
  await tester.pump();
  await _waitForCondition(
    tester,
    () => tester.state<FormFieldState<dynamic>>(field).value == expectedValue,
    label: 'the selected $label form value',
  );
}

Future<void> _markAssignmentInProgress(
  WidgetTester tester,
  ProviderContainer container, {
  required String title,
}) async {
  final card = find.ancestor(
    of: find.text(title),
    matching: find.byType(Card),
  );
  await _waitFor(tester, card, label: 'the assignment card before progress');
  await _tap(
    tester,
    find.descendant(of: card, matching: find.byTooltip('状態を変更')),
  );
  await _waitFor(
    tester,
    find.text('進行中にする'),
    label: 'the assignment progress-state action',
  );
  await _tap(tester, find.text('進行中にする'));
  await _waitForCondition(
    tester,
    () {
      final state = container.read(demoAppControllerProvider).valueOrNull;
      final assignment =
          state?.assignments.where((item) => item.title == title);
      if (assignment == null || assignment.length != 1) return false;
      final assignmentId = assignment.single.id;
      return state!.assignmentStates[assignmentId]?.status ==
              AssignmentStatus.inProgress &&
          state.calendarItems.any(
            (item) =>
                item.kind == EventKind.assignmentDeadline &&
                item.title == title,
          );
    },
    label: 'the in-progress assignment to remain on the local calendar',
    diagnostic: () => _safeAssignmentProgressDiagnostic(container, title),
  );
  final state = container.read(demoAppControllerProvider).valueOrNull;
  expect(state, isNotNull);
  final assignment = state!.assignments.singleWhere(
    (item) => item.title == title,
  );
  final statusMenu = find.byKey(
    ValueKey('assignment-status-${assignment.id}'),
  );
  await _scrollAssignmentStatusIntoSafeTapArea(
    tester,
    statusMenu,
    label: 'the in-progress assignment status menu',
  );
  final progressChip = find.descendant(
    of: statusMenu,
    matching: find.text('進行中'),
  );
  await _waitFor(
    tester,
    progressChip,
    label: 'the scoped in-progress assignment status chip',
    diagnostic: () => _safeAssignmentProgressDiagnostic(container, title),
  );
  expect(progressChip, findsOneWidget);
}

Future<void> _scrollAssignmentStatusIntoSafeTapArea(
  WidgetTester tester,
  Finder statusMenu, {
  required String label,
}) async {
  final scrollable = find.ancestor(
    of: statusMenu,
    matching: find.byType(Scrollable),
  );
  await _scrollMvpActionIntoSafeTapArea(
    tester,
    action: statusMenu,
    scrollable: scrollable,
    label: label,
  );
}

Future<void> _scrollMvpActionIntoSafeTapArea(
  WidgetTester tester, {
  required Finder action,
  required Finder scrollable,
  required String label,
  bool actionAlreadyVisible = false,
  Future<void> Function()? rematerializeAction,
}) async {
  expect(scrollable, findsAtLeastNWidgets(1));
  expect(action, findsOneWidget);

  // Resolve the target synchronously at each rendered frame below. Waiting by
  // pumping here can evict a lazily built form action after it was verified.
  Element currentActionElement() {
    final elements = action.evaluate().toList(growable: false);
    if (elements.length != 1) {
      fail(
        'Expected exactly one $label while positioning it '
        '(found ${elements.length}).',
      );
    }
    return elements.single;
  }

  Future<void> ensureCurrentAction() async {
    final count = action.evaluate().length;
    if (count == 1) return;
    if (count > 1) {
      currentActionElement();
      return;
    }
    final rematerialize = rematerializeAction;
    if (rematerialize == null) {
      currentActionElement();
      return;
    }
    await rematerialize();
    currentActionElement();
  }

  if (!actionAlreadyVisible) {
    final initialActionElement = currentActionElement();
    await Scrollable.ensureVisible(
      initialActionElement,
      alignment: 0.5,
      duration: Duration.zero,
    );
    await tester.pump();
  }

  // Forms hide quick-add; list screens may retain it. Keep the whole action
  // above every control that is actually present. Resolve the action anew
  // after each pump because scrolling can rebuild its Element.
  final bounds = measureMvpActionTapBounds(tester);
  final safeTop = bounds.top;
  final safeBottom = bounds.bottom;
  Future<Rect> currentActionRect() async {
    await ensureCurrentAction();
    final actionElement = currentActionElement();
    final renderObject = actionElement.renderObject;
    if (renderObject is! RenderBox) {
      fail('The action for $label does not have a render box.');
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  if (actionAlreadyVisible) {
    final initialActionRect = await currentActionRect();
    if (initialActionRect.top < safeTop ||
        initialActionRect.bottom > safeBottom) {
      // scrollUntilVisible only guarantees partial visibility. Resolve the
      // actual ancestor chain before applying the strict safe-area correction.
      await Scrollable.ensureVisible(
        currentActionElement(),
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pump();
    }
  }

  for (var attempt = 0; attempt < 3; attempt++) {
    final actionRect = await currentActionRect();
    final correction = actionRect.top < safeTop
        ? actionRect.top - safeTop
        : actionRect.bottom > safeBottom
            ? actionRect.bottom - safeBottom
            : 0.0;
    if (correction == 0.0) break;
    final scrollState = tester.state<ScrollableState>(scrollable.first);
    final correctedOffset = (scrollState.position.pixels + correction)
        .clamp(
          scrollState.position.minScrollExtent,
          scrollState.position.maxScrollExtent,
        )
        .toDouble();
    if (correctedOffset == scrollState.position.pixels) break;
    scrollState.position.jumpTo(correctedOffset);
    await tester.pump();
  }
  final finalActionRect = await currentActionRect();
  expect(finalActionRect.top, greaterThanOrEqualTo(safeTop));
  expect(finalActionRect.bottom, lessThanOrEqualTo(safeBottom));
}

String _safeAssignmentProgressDiagnostic(
  ProviderContainer container,
  String title,
) {
  final snapshot = container.read(demoAppControllerProvider);
  if (snapshot.isLoading) return 'schedule=loading';
  if (snapshot.hasError) return 'schedule=error';
  final state = snapshot.valueOrNull;
  if (state == null) return 'schedule=empty';
  final assignments = state.assignments
      .where((assignment) => assignment.title == title)
      .toList(growable: false);
  final status = assignments.length == 1
      ? state.assignmentStates[assignments.single.id]?.status.name ?? 'absent'
      : 'unavailable';
  final hasDeadline = assignments.length == 1 &&
      state.calendarItems.any(
        (item) =>
            item.kind == EventKind.assignmentDeadline && item.title == title,
      );
  return 'schedule=data assignmentMatches=${assignments.length} '
      'status=$status deadline=$hasDeadline';
}

String _safeAssignmentCourseFilterDiagnostic(
  ProviderContainer container,
  String title,
  String expectedCourseId,
) {
  final snapshot = container.read(demoAppControllerProvider);
  if (snapshot.isLoading) return 'schedule=loading';
  if (snapshot.hasError) return 'schedule=error';
  final state = snapshot.valueOrNull;
  if (state == null) return 'schedule=empty';
  final assignments = state.assignments
      .where((assignment) => assignment.title == title)
      .toList(growable: false);
  final linkedCourseId =
      assignments.length == 1 ? assignments.single.courseId : null;
  final availableCourseIds = {
    for (final course in state.courses) course.id,
    for (final course in state.assignmentCourses) course.id,
  };
  final linkedCoursePresent =
      linkedCourseId != null && availableCourseIds.contains(linkedCourseId);
  return 'schedule=data assignmentMatches=${assignments.length} '
      'linkedExpected=${linkedCourseId == expectedCourseId} '
      'linkedCoursePresent=$linkedCoursePresent '
      'currentCourses=${state.courses.length} '
      'assignmentCourses=${state.assignmentCourses.length}';
}

Future<void> _synchronize(
  ProviderContainer container, {
  required _InjectedAppClock clock,
}) async {
  var result = await container
      .read(scheduleSyncRuntimeProvider.notifier)
      .trigger(SyncTrigger.manual);
  expect(result, isNotNull);
  final retryAt = result!.push.nextRetryAt;
  if (retryAt != null) {
    final now = clock.now();
    expect(
      retryAt.isAfter(now),
      isTrue,
      reason:
          'A scheduled Android E2E retry must be strictly after the injected clock.',
    );
    // A phase restart recreates the injected clock at the fixture instant.
    // Advance exactly to the durable retry deadline and manually exercise the
    // retry once; a second scheduled retry remains a hard test failure below.
    clock.advance(retryAt.difference(now));
    result = await container
        .read(scheduleSyncRuntimeProvider.notifier)
        .trigger(SyncTrigger.manual);
    expect(result, isNotNull);
  }
  expect(result!.push.failed, 0);
  expect(result.push.conflicts, 0);
  expect(
    result.push.nextRetryAt,
    isNull,
    reason:
        'A manual Android E2E sync must not leave its strict queue head waiting to retry.',
  );
  expect(
    result.blockedByLocalMutation,
    isFalse,
    reason:
        'A manual Android E2E sync must not leave pending local mutations blocking its pull.',
  );
}

Future<void> _signOutThroughSettings(
  WidgetTester tester, {
  required ProviderContainer container,
}) async {
  await _tap(tester, find.byTooltip('設定'));
  await _waitFor(
    tester,
    find.text('ログアウト'),
    label: 'the production logout action',
  );
  await _tap(tester, find.text('ログアウト'));
  await _waitFor(
    tester,
    find.byKey(const Key('sign-in-email')),
    label: 'the sign-in screen after logout',
  );
  await _waitForCondition(
    tester,
    () {
      final action = container.read(authActionControllerProvider);
      return !action.isLoading &&
          (action.valueOrNull?.name == 'signedOut' || action.hasError);
    },
    label: 'the logout action completion',
    diagnostic: () => _safeMagicLinkActionDiagnostic(container),
  );
  expect(
    container.read(authActionControllerProvider).valueOrNull?.name,
    'signedOut',
    reason: _safeMagicLinkActionDiagnostic(container),
  );
}

Future<void> _openNavigationDestination(
  WidgetTester tester,
  String label,
) async {
  final destination = find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );
  await _tap(tester, destination);
  await _waitFor(
    tester,
    _appBarTitle(label),
    label: 'the $label destination',
  );
}

Future<void> _openTimetableWeekView(WidgetTester tester) async {
  await _openNavigationDestination(tester, '時間割');
  final weekViewAction = find.text('週全体');
  await _waitFor(
    tester,
    weekViewAction,
    label: 'the timetable week-view action',
  );
  await _tap(tester, weekViewAction);
  await _waitFor(
    tester,
    find.byKey(const Key('timetable-week-view')),
    label: 'the timetable week view',
  );
}

Future<void> _selectSubmittedAssignmentFilter(
  WidgetTester tester, {
  required String label,
}) async {
  final submittedFilter = find.byKey(
    const Key('assignment-filter-done'),
  );
  await _waitFor(tester, submittedFilter, label: label);
  await _tap(tester, submittedFilter);
  await _waitForCondition(
    tester,
    () {
      final matches = submittedFilter.evaluate().toList(growable: false);
      return matches.length == 1 &&
          (matches.single.widget as ChoiceChip).selected;
    },
    label: '$label to be selected',
  );
  expect(tester.widget<ChoiceChip>(submittedFilter).selected, isTrue);
}

Finder _appBarTitle(String label) {
  return find.descendant(
    of: find.byType(AppBar),
    matching: find.text(label),
  );
}

Finder _textFormField(String label) {
  return find.ancestor(
    of: find.text(label),
    matching: find.byType(TextFormField),
  );
}

Finder _dropdownFormField(String label) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is DropdownButtonFormField &&
        widget.decoration.labelText == label,
    description: 'DropdownButtonFormField labeled $label',
  );
}

Future<void> _selectDropdownMenuOption(
  WidgetTester tester, {
  required Finder field,
  required Finder optionText,
  required String label,
}) async {
  await _tap(tester, field);
  await tester.pump(const Duration(milliseconds: 300));
  final allMenuItems = find.ancestor(
    of: optionText,
    matching: find.byWidgetPredicate(
      (widget) => widget is DropdownMenuItem,
      description: 'DropdownMenuItem for $label',
    ),
  );
  // DropdownButton retains closed-field items in an IndexedStack. Its open
  // menu owns the current PopupRoute's Scrollable subtree, which excludes an
  // enclosing modal bottom sheet without depending on element order. Items
  // outside the popup viewport are built lazily, so the helper scrolls the
  // open popup list before requiring the scoped item.
  final openMenuItem = await _waitForSinglePopupDropdownItem(
    tester,
    allMenuItems,
    label: label,
  );
  final openMenuText = find.descendant(of: openMenuItem, matching: optionText);
  // The helper has just materialized this exact popup item. Do not pump or
  // scroll again before tapping it: a lazy ListView can evict an offscreen
  // item in that extra frame.
  expect(openMenuText, findsOneWidget);
  final expectedValue =
      tester.widget<DropdownMenuItem<dynamic>>(openMenuItem).value;
  final popupRoute = ModalRoute.of(tester.element(openMenuItem));
  expect(popupRoute, isA<PopupRoute<dynamic>>());
  await tester.tapAt(tester.getCenter(openMenuText));
  await tester.pump();
  await _waitForCondition(
    tester,
    () => tester.state<FormFieldState<dynamic>>(field).value == expectedValue,
    label: 'the selected $label form value',
  );
  await waitForPopupRouteDismissal(
    tester,
    popupRoute! as PopupRoute<dynamic>,
    label: 'the selected $label popup route and its overlay to close',
  );
}

Future<Finder> _waitForSinglePopupDropdownItem(
  WidgetTester tester,
  Finder items, {
  required String label,
}) async {
  var lastCount = 0;
  var lastPopupScrollableCount = 0;
  var lastItemCenterInsidePopup = false;
  PopupRoute<dynamic>? popupRoute;
  Element? popupScrollableElement;
  Finder? popupScrollable;
  double? minScrollExtent;
  double? maxScrollExtent;
  double? viewportDimension;
  double? nextScanOffset;
  var scannedMaxExtent = false;
  final visitedOffsets = <double>[];
  var materializedRouteItemKeys = const <String>[];

  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (popupRoute == null) {
      final popupScrollableElements = _currentPopupRouteScrollableElements();
      lastPopupScrollableCount = popupScrollableElements.length;
      if (popupScrollableElements.length == 1) {
        popupScrollableElement = popupScrollableElements.single;
        final route = ModalRoute.of(popupScrollableElement);
        expect(route, isA<PopupRoute<dynamic>>());
        expect(route!.isCurrent, isTrue);
        popupRoute = route as PopupRoute<dynamic>;
        popupScrollable = find.byElementPredicate(
          (candidate) => identical(candidate, popupScrollableElement),
          description: 'the open DropdownButton popup scrollable for $label',
        );
        final position =
            tester.state<ScrollableState>(popupScrollable).position;
        minScrollExtent = position.minScrollExtent;
        maxScrollExtent = position.maxScrollExtent;
        viewportDimension = position.viewportDimension;
        expect(minScrollExtent.isFinite, isTrue);
        expect(maxScrollExtent.isFinite, isTrue);
        expect(position.pixels.isFinite, isTrue);
        expect(viewportDimension.isFinite, isTrue);
        expect(viewportDimension, greaterThan(0));
        expect(maxScrollExtent, greaterThanOrEqualTo(minScrollExtent));
        nextScanOffset = minScrollExtent;
      }
    }

    if (popupRoute != null && popupScrollable != null) {
      final openMenuItems = items.evaluate().where((element) {
        return identical(ModalRoute.of(element), popupRoute);
      }).toList(growable: false);
      lastCount = openMenuItems.length;
      if (openMenuItems.length > 1) {
        fail('Found more than one $label in the same DropdownButton popup.');
      }
      if (openMenuItems.length == 1) {
        final openMenuItemElement = openMenuItems.single;
        final openMenuItem = find.byElementPredicate(
          (element) => identical(element, openMenuItemElement),
          description: 'open DropdownButton popup menu item for $label',
        );
        final itemRect = tester.getRect(openMenuItem);
        final popupRect = tester.getRect(popupScrollable);
        lastItemCenterInsidePopup = itemRect.width > 0 &&
            itemRect.height > 0 &&
            popupRect.contains(itemRect.center);
        if (lastItemCenterInsidePopup) return openMenuItem;
      }

      materializedRouteItemKeys = find
          .byWidgetPredicate(
            (widget) => widget is DropdownMenuItem<dynamic>,
            description: 'materialized DropdownMenuItem widgets',
          )
          .evaluate()
          .where((element) => identical(ModalRoute.of(element), popupRoute))
          .map((element) => element.widget.key?.toString() ?? 'null')
          .toList(growable: false);

      if (nextScanOffset != null) {
        final position =
            tester.state<ScrollableState>(popupScrollable).position;
        final target = nextScanOffset;
        if ((position.pixels - target).abs() > 0.01) {
          position.jumpTo(target);
          await tester.pump();
        }
        visitedOffsets.add(target);
        if (target >= maxScrollExtent!) {
          scannedMaxExtent = true;
          nextScanOffset = null;
        } else {
          final step = viewportDimension! / 2;
          final candidate = target + step;
          nextScanOffset =
              candidate >= maxScrollExtent ? maxScrollExtent : candidate;
        }
      } else if (scannedMaxExtent) {
        break;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail(
    'Timed out waiting for exactly one open DropdownButton popup menu '
    'item for $label (found $lastCount; '
    'itemCenterInsidePopup=$lastItemCenterInsidePopup; '
    'popupScrollables=$lastPopupScrollableCount; '
    'popupRouteCurrent=${popupRoute?.isCurrent}; '
    'minScrollExtent=$minScrollExtent; maxScrollExtent=$maxScrollExtent; '
    'viewportDimension=$viewportDimension; visitedOffsets=$visitedOffsets; '
    'materializedRouteItemKeys=$materializedRouteItemKeys).',
  );
}

List<Element> _currentPopupRouteScrollableElements() {
  return find.byType(Scrollable).evaluate().where((element) {
    final route = ModalRoute.of(element);
    return route is PopupRoute && route.isCurrent;
  }).toList(growable: false);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsAtLeastNWidgets(1));
  final target = finder.first;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String label,
  String Function()? diagnostic,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final suffix = diagnostic == null ? '' : ' (${diagnostic()})';
  fail('Timed out waiting for $label$suffix.');
}

String _safeUniversityRequestDialogDiagnostic(WidgetTester tester) {
  final dialogVisible = find.byType(AlertDialog).evaluate().isNotEmpty;
  final submitAction = find.byKey(
    const Key('submit-university-request-button'),
  );
  final submitState = switch (submitAction.evaluate().toList(growable: false)) {
    [] => 'absent',
    [final element] => (element.widget as FilledButton).onPressed == null
        ? 'disabled'
        : 'enabled',
    _ => 'ambiguous',
  };
  final knownSubmissionError =
      find.text('大学追加申請を送信できませんでした').evaluate().isNotEmpty;
  return 'dialog=${dialogVisible ? 'visible' : 'absent'} '
      'submit=$submitState knownSubmissionError=$knownSubmissionError';
}

String _safeReauthenticationDiagnostic(ProviderContainer container) {
  final path = container
      .read(routerProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
  final route = switch (path) {
    '/' => 'home',
    '/sign-in' => 'sign-in',
    '/settings' => 'settings',
    '/onboarding' => 'onboarding',
    '/auth-loading' => 'auth-loading',
    _ => 'other',
  };
  final auth = container.read(authStateProvider);
  final onboarding = container.read(onboardingControllerProvider);
  final schedule = container.read(demoAppControllerProvider);
  final context = container.read(activeScheduleContextProvider);
  final authPhase = auth.isLoading
      ? 'loading'
      : auth.valueOrNull?.isSignedIn == true
          ? 'signed-in'
          : 'signed-out';
  final onboardingPhase = onboarding.isLoading
      ? 'loading'
      : onboarding.hasError
          ? 'error'
          : onboarding.valueOrNull?.hasActiveSchedule == true
              ? 'active'
              : 'inactive';
  final schedulePhase = schedule.isLoading
      ? 'loading'
      : schedule.hasError
          ? 'error'
          : 'data';
  return 'route=$route auth=$authPhase onboarding=$onboardingPhase '
      'context=${context == null ? 'absent' : 'active'} '
      'schedule=$schedulePhase';
}

String _safeTermPeriodDiagnostic(
  ProviderContainer container,
  WidgetTester tester,
) {
  final path = container
      .read(routerProvider)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
  final profile = container.read(onboardingControllerProvider);
  final catalog = container.read(onboardingCatalogProvider);
  final snapshot = container.read(personalTermPeriodSnapshotProvider);
  final context = container.read(activeScheduleContextProvider);
  final profilePhase = profile.isLoading
      ? 'loading'
      : profile.hasError
          ? 'error'
          : profile.valueOrNull?.hasActiveSchedule == true
              ? 'active'
              : 'inactive';
  final snapshotPhase = snapshot.isLoading
      ? 'loading'
      : snapshot.hasError
          ? 'error'
          : snapshot.valueOrNull?.activeTerm == null
              ? 'no-active-term'
              : 'active-term';
  final visibleState = find.text('初期設定を完了してください').evaluate().isNotEmpty
      ? 'onboarding-required'
      : find.text('有効な学期がありません').evaluate().isNotEmpty
          ? 'no-active-term'
          : find.text('学期設定を読み込めませんでした').evaluate().isNotEmpty
              ? 'load-error'
              : find.text('デモモードで実行中です').evaluate().isNotEmpty
                  ? 'demo'
                  : 'other';
  final termCreateAction = find.byKey(
    const Key('create-personal-term-button'),
  );
  final termCreateActionAnyRoute = find.byKey(
    const Key('create-personal-term-button'),
    skipOffstage: false,
  );
  final termManagementList = find.byKey(
    const Key('term-period-management-list'),
  );
  final termManagementListAnyRoute = find.byKey(
    const Key('term-period-management-list'),
    skipOffstage: false,
  );
  final universitySettingsList = find.byKey(
    const Key('university-settings-list'),
  );
  final universitySettingsListAnyRoute = find.byKey(
    const Key('university-settings-list'),
    skipOffstage: false,
  );
  final termAppBar = _appBarTitle('学期・時限管理');
  final termAppBarAnyRoute = find.descendant(
    of: find.byType(AppBar, skipOffstage: false),
    matching: find.text('学期・時限管理', skipOffstage: false),
    skipOffstage: false,
  );
  return 'route=${_safeTermPeriodRoute(path)} '
      'profile=$profilePhase '
      'catalog=${_safeAsyncPhase(catalog)} '
      'snapshot=$snapshotPhase '
      'context=${context == null ? 'absent' : 'active'} '
      'screen=$visibleState '
      'termAppBar=${termAppBar.evaluate().length}/'
      '${termAppBarAnyRoute.evaluate().length} '
      'termList=${termManagementList.evaluate().length}/'
      '${termManagementListAnyRoute.evaluate().length} '
      'createAction=${termCreateAction.evaluate().length}/'
      '${termCreateActionAnyRoute.evaluate().length} '
      'universityList=${universitySettingsList.evaluate().length}/'
      '${universitySettingsListAnyRoute.evaluate().length} '
      'progress=${find.byType(CircularProgressIndicator).evaluate().length}';
}

String _safeTermCreationDiagnostic(
  ProviderContainer container,
  WidgetTester tester, {
  required String expectedTermTitle,
}) {
  final snapshot = container.read(personalTermPeriodSnapshotProvider);
  final hasExpectedTerm = snapshot.valueOrNull?.terms
          .any((term) => term.name == expectedTermTitle) ??
      false;
  final expectedTermIsActive =
      snapshot.valueOrNull?.activeTerm?.name == expectedTermTitle;
  final creationDialogOpen =
      find.text('学期を追加').evaluate().isNotEmpty ? 'open' : 'closed';
  final confirmationOpen =
      find.text('新しい学期を作成しますか？').evaluate().isNotEmpty ? 'open' : 'closed';
  final mutationFailureVisible =
      find.text('学期または時限の更新に失敗しました').evaluate().isNotEmpty ||
          find.text('学期設定を取得または更新できませんでした').evaluate().isNotEmpty ||
          find.text('学期または時限の入力内容を確認してください').evaluate().isNotEmpty;
  return '${_safeTermPeriodDiagnostic(container, tester)} '
      'expectedTerm=${hasExpectedTerm ? 'present' : 'absent'} '
      'expectedActive=${expectedTermIsActive ? 'yes' : 'no'} '
      'createDialog=$creationDialogOpen '
      'confirmation=$confirmationOpen '
      'mutationFailure=${mutationFailureVisible ? 'visible' : 'absent'}';
}

String _safeTermPeriodRoute(String path) {
  return switch (path) {
    '/university/term-periods' => 'term-periods',
    '/university' => 'university',
    '/settings' => 'settings',
    '/assignments' => 'assignments',
    '/exams' => 'exams',
    '/' => 'home',
    _ => 'other',
  };
}

String _safeAsyncPhase<T>(AsyncValue<T> value) {
  if (value.isLoading) return 'loading';
  if (value.hasError) return 'error';
  return 'data';
}

Future<void> _waitForCondition(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String label,
  String Function()? diagnostic,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final suffix = diagnostic == null ? '' : ' (${diagnostic()})';
  fail('Timed out waiting for $label$suffix.');
}

Future<void> _dismissAndroidKeyboard(
  WidgetTester tester, {
  required String label,
  required Finder layoutContext,
}) async {
  expect(layoutContext, findsOneWidget);
  final scaffoldContext = find.ancestor(
    of: layoutContext,
    matching: find.byType(Scaffold),
  );
  expect(scaffoldContext, findsOneWidget);
  var hideRequestCount = 0;
  var focusedEditableClearCount = 0;
  var consecutiveSettledObservations = 0;
  var consecutiveStaleRawInsetObservations = 0;
  double? lastRawViewInset;

  Future<void> requestKeyboardHide() async {
    if (tester.binding.focusedEditable != null) {
      focusedEditableClearCount++;
    }
    tester.binding.focusedEditable = null;
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _androidE2ePlatform.invokeMethod<void>('hideImeAndRefreshInsets');
    hideRequestCount++;
  }

  await requestKeyboardHide();
  // Scaffold removes bottom viewInsets from the MediaQuery inherited by its
  // body, so the form's inherited zero cannot prove that Scaffold geometry has
  // settled. Require the raw platform view and the ambient MediaQuery at the
  // ancestor Scaffold to agree across three observations. A real Android IME
  // hide is asynchronous; retry only when its raw inset is demonstrably stuck.
  ({double view, double scaffoldMediaQuery, double bodyMediaQuery})?
      currentInsets() {
    final elements = layoutContext.evaluate().toList(growable: false);
    final scaffoldElements = scaffoldContext.evaluate().toList(growable: false);
    if (elements.length != 1 || scaffoldElements.length != 1) return null;
    final element = elements.single;
    return (
      view: View.of(element).viewInsets.bottom,
      scaffoldMediaQuery:
          MediaQuery.viewInsetsOf(scaffoldElements.single).bottom,
      bodyMediaQuery: MediaQuery.viewInsetsOf(element).bottom,
    );
  }

  int focusedEditableCount() => find
      .byType(EditableText, skipOffstage: false)
      .evaluate()
      .where((element) => (element.widget as EditableText).focusNode.hasFocus)
      .length;

  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    final insets = currentInsets();
    if (insets != null &&
        insets.view == 0 &&
        insets.scaffoldMediaQuery == 0 &&
        focusedEditableCount() == 0) {
      consecutiveSettledObservations++;
      consecutiveStaleRawInsetObservations = 0;
      lastRawViewInset = null;
      if (consecutiveSettledObservations >= 3) return;
    } else {
      consecutiveSettledObservations = 0;
      if (insets != null && insets.view > 0) {
        if (lastRawViewInset == insets.view) {
          consecutiveStaleRawInsetObservations++;
        } else {
          lastRawViewInset = insets.view;
          consecutiveStaleRawInsetObservations = 1;
        }
        if (consecutiveStaleRawInsetObservations >= 10 &&
            hideRequestCount < 3) {
          consecutiveStaleRawInsetObservations = 0;
          lastRawViewInset = null;
          await requestKeyboardHide();
        }
      } else {
        consecutiveStaleRawInsetObservations = 0;
        lastRawViewInset = null;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final insets = currentInsets();
  fail(
    'Timed out waiting for the Android keyboard and form layout to settle '
    'before $label '
    '(implicitViewInsetsBottom=${tester.view.viewInsets.bottom} '
    'layoutContextCount=${layoutContext.evaluate().length} '
    'scaffoldContextCount=${scaffoldContext.evaluate().length} '
    'layoutViewInsetsBottom=${insets?.view} '
    'scaffoldMediaQueryViewInsetsBottom=${insets?.scaffoldMediaQuery} '
    'bodyMediaQueryViewInsetsBottom=${insets?.bodyMediaQuery} '
    'hideRequestCount=$hideRequestCount '
    'focusedEditableClearCount=$focusedEditableClearCount '
    'bindingFocusedEditable=${tester.binding.focusedEditable != null} '
    'focusedEditableCount=${focusedEditableCount()} '
    'primaryFocus=${FocusManager.instance.primaryFocus?.debugLabel ?? 'none'} '
    'consecutiveStaleRawInsetObservations='
    '$consecutiveStaleRawInsetObservations '
    'consecutiveSettledObservations=$consecutiveSettledObservations).',
  );
}

String _safeMagicLinkActionDiagnostic(ProviderContainer container) {
  final action = container.read(authActionControllerProvider);
  if (action.isLoading) return 'action=loading';
  if (action.hasError) return 'action=error';
  return 'action=${action.valueOrNull?.name ?? 'none'}';
}

Future<void> _waitForGone(
  WidgetTester tester,
  Finder finder, {
  required String label,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Timed out waiting for $label.');
}
