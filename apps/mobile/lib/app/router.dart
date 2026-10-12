import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config_provider.dart';
import '../features/assignment/presentation/assignment_form_screen.dart';
import '../features/assignment/presentation/assignment_detail_screen.dart';
import '../features/assignment/presentation/assignment_list_screen.dart';
import '../features/auth/application/auth_providers.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/availability/presentation/availability_screen.dart';
import '../features/calendar/presentation/calendar_screen.dart';
import '../features/calendar/presentation/calendar_visibility_screen.dart';
import '../features/calendar/presentation/event_form_screen.dart';
import '../features/calendar/presentation/routine_form_screen.dart';
import '../features/course_template/presentation/course_detail_screen.dart';
import '../features/course_template/presentation/course_form_screen.dart';
import '../features/course_template/presentation/course_search_screen.dart';
import '../features/document_import/presentation/document_import_chat_screen.dart';
import '../features/email_import/presentation/email_candidate_inbox_screen.dart';
import '../features/email_import/presentation/email_candidate_review_screen.dart';
import '../features/email_import/presentation/email_candidate_update_review_screen.dart';
import '../features/email_import/presentation/email_import_settings_screen.dart';
import '../features/exam/presentation/exam_form_screen.dart';
import '../features/exam/presentation/exam_list_screen.dart';
import '../features/friends/presentation/shared_screen.dart';
import '../features/friends/presentation/friend_invite_qr.dart';
import '../features/friends/presentation/friend_timetable_screen.dart';
import '../features/groups/presentation/group_detail_screen.dart';
import '../features/notification/presentation/notification_settings_screen.dart';
import '../features/notification/presentation/notification_inbox_screen.dart';
import '../features/notification/presentation/server_notification_inbox_screen.dart';
import '../features/notification/presentation/notification_target_detail_screen.dart';
import '../features/onboarding/application/onboarding_providers.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/term_period/presentation/term_period_management_screen.dart';
import '../features/today/presentation/today_screen.dart';
import '../features/timetable/presentation/home_screen.dart';
import '../features/timetable/presentation/timetable_screen.dart';
import '../features/university/presentation/university_screen.dart';
import '../features/visibility/presentation/visibility_settings_screen.dart';
import '../features/widget_bridge/presentation/widget_settings_screen.dart';
import 'deep_link_controller.dart';
import 'navigation_guard.dart';

final onboardingGateProvider = Provider<AsyncValue<OnboardingGateStatus>>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  final auth = ref.watch(authStateProvider);
  if (auth.isLoading) {
    return const AsyncLoading();
  }
  if (auth.valueOrNull?.isSignedIn != true) {
    return const AsyncData(OnboardingGateStatus.required);
  }
  if (config.demoMode) {
    return const AsyncData(OnboardingGateStatus.completed);
  }

  final onboarding = ref.watch(onboardingControllerProvider);
  final profile = onboarding.valueOrNull;
  final sessionUserId = auth.valueOrNull?.session?.userId;
  if (profile != null && profile.userId == sessionUserId) {
    return AsyncData(
      profile.hasActiveSchedule
          ? OnboardingGateStatus.completed
          : OnboardingGateStatus.required,
    );
  }
  return onboarding.isLoading
      ? const AsyncLoading()
      : const AsyncData(OnboardingGateStatus.required);
});

final routerProvider = Provider<GoRouter>((ref) {
  final config = ref.watch(appConfigProvider);
  final normalizer = DeepLinkNormalizer(config);
  final pendingLinks = ref.watch(pendingDeepLinkStoreProvider);
  final refreshNotifier = _RouterRefreshNotifier();

  ref.listen(authStateProvider, (_, __) => refreshNotifier.refresh());
  ref.listen(onboardingGateProvider, (_, __) => refreshNotifier.refresh());

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      final onboarding = ref.read(onboardingGateProvider);
      final authStatus = auth.isLoading
          ? AuthGateStatus.loading
          : auth.valueOrNull?.isSignedIn == true
              ? AuthGateStatus.signedIn
              : AuthGateStatus.signedOut;
      final onboardingStatus = onboarding.isLoading
          ? OnboardingGateStatus.loading
          : onboarding.valueOrNull ?? OnboardingGateStatus.required;
      return resolveAppRedirect(
        authStatus: authStatus,
        onboardingStatus: onboardingStatus,
        currentLocation: state.uri.toString(),
        pendingLinks: pendingLinks,
        normalizer: normalizer,
      );
    },
    errorBuilder: (context, state) => const _RouteNotFoundScreen(),
    routes: _routes,
  );

  DeepLinkController? deepLinkController;
  if (config.platformDeepLinksEnabled) {
    deepLinkController = DeepLinkController(
      router: router,
      normalizer: normalizer,
      onIncomingLocation: (location) {
        if (location.startsWith('/invite/friend/') ||
            location.startsWith('/invite/group/')) {
          pendingLinks.captureIncoming(location, normalizer);
        }
      },
    )..start();
  }

  ref.onDispose(() {
    deepLinkController?.dispose();
    refreshNotifier.dispose();
    router.dispose();
  });
  return router;
});

final List<RouteBase> _routes = [
  GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
  GoRoute(path: '/today', builder: (context, state) => const TodayScreen()),
  GoRoute(
    path: '/auth-loading',
    builder: (context, state) => const _AuthLoadingScreen(),
  ),
  GoRoute(
    path: '/auth/callback',
    builder: (context, state) => const _AuthLoadingScreen(),
  ),
  GoRoute(path: '/sign-in', builder: (context, state) => const SignInScreen()),
  GoRoute(
    path: '/onboarding',
    builder: (context, state) => const OnboardingScreen(),
  ),
  GoRoute(
    path: '/university',
    builder: (context, state) => const UniversityScreen(),
  ),
  GoRoute(
    path: '/university/term-periods',
    builder: (context, state) => const TermPeriodManagementScreen(),
  ),
  GoRoute(
    path: '/timetable',
    builder: (context, state) => const TimetableScreen(),
  ),
  GoRoute(
    path: '/courses/search',
    builder: (context, state) => CourseSearchScreen(
      initialWeekday: int.tryParse(state.uri.queryParameters['weekday'] ?? ''),
      initialPeriod: int.tryParse(state.uri.queryParameters['period'] ?? ''),
    ),
  ),
  GoRoute(
    path: '/courses/manual',
    builder: (context, state) => CourseFormScreen(
      initialWeekday: int.tryParse(state.uri.queryParameters['weekday'] ?? ''),
      initialPeriod: int.tryParse(state.uri.queryParameters['period'] ?? ''),
      firstCourseContinuation:
          state.uri.queryParameters['firstCourse'] == 'true',
    ),
  ),
  GoRoute(
    path: '/course/:id',
    builder: (context, state) =>
        CourseDetailScreen(courseId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/course/:id/edit',
    builder: (context, state) =>
        CourseFormScreen(courseId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/assignments',
    builder: (context, state) => const AssignmentListScreen(),
  ),
  GoRoute(
    path: '/assignments/new',
    builder: (context, state) => AssignmentFormScreen(
      initialCourseId: _optionalQueryParameter(
        state.uri.queryParameters['courseId'],
      ),
    ),
  ),
  GoRoute(
    path: '/assignment/:id',
    builder: (context, state) => AssignmentDetailScreen(
      assignmentId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/assignment/:id/edit',
    builder: (context, state) =>
        AssignmentFormScreen(assignmentId: state.pathParameters['id']!),
  ),
  GoRoute(path: '/exams', builder: (context, state) => const ExamListScreen()),
  GoRoute(
    path: '/exams/new',
    builder: (context, state) => const ExamFormScreen(),
  ),
  GoRoute(
    path: '/exam/:id/edit',
    builder: (context, state) =>
        ExamFormScreen(examId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/exam/:id',
    builder: (context, state) => NotificationTargetDetailScreen(
      kind: 'exam',
      id: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/calendar',
    builder: (context, state) => const CalendarScreen(),
  ),
  GoRoute(
    path: '/calendar/visibility',
    builder: (context, state) => const CalendarVisibilityScreen(),
  ),
  GoRoute(
    path: '/events/new',
    builder: (context, state) => const EventFormScreen(),
  ),
  GoRoute(
    path: '/event/:id/edit',
    builder: (context, state) =>
        EventFormScreen(eventId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/event/:id',
    builder: (context, state) => NotificationTargetDetailScreen(
      kind: 'event',
      id: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/routines/new',
    builder: (context, state) => const RoutineFormScreen(),
  ),
  GoRoute(
    path: '/routine/:id/edit',
    builder: (context, state) =>
        RoutineFormScreen(routineId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/routine/:id',
    builder: (context, state) => NotificationTargetDetailScreen(
      kind: 'routine',
      id: state.pathParameters['id']!,
    ),
  ),
  GoRoute(path: '/shared', builder: (context, state) => const SharedScreen()),
  GoRoute(
    path: '/shared/invite/qr',
    builder: (context, state) => const FriendInviteQrScreen(),
  ),
  GoRoute(
    path: '/shared/scan',
    builder: (context, state) => const FriendInviteScannerScreen(),
  ),
  GoRoute(
    path: '/shared/blocked',
    builder: (context, state) => const BlockedFriendsScreen(),
  ),
  GoRoute(
    path: '/shared/friend/:id',
    builder: (context, state) => FriendTimetableScreen(
      friendUserId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/shared/friend/:id/event/:eventId',
    builder: (context, state) => FriendTimetableScreen(
      friendUserId: state.pathParameters['id']!,
      eventId: state.pathParameters['eventId'],
    ),
  ),
  GoRoute(
    path: '/shared/friend/:id/preview',
    builder: (context, state) => FriendTimetableScreen(
      friendUserId: state.pathParameters['id']!,
      preview: true,
    ),
  ),
  GoRoute(
    path: '/shared/friend/:id/preview/event/:eventId',
    builder: (context, state) => FriendTimetableScreen(
      friendUserId: state.pathParameters['id']!,
      eventId: state.pathParameters['eventId'],
      preview: true,
    ),
  ),
  GoRoute(
    path: '/availability',
    builder: (context, state) => const AvailabilityScreen(),
  ),
  GoRoute(
    path: '/group/:id',
    builder: (context, state) =>
        GroupDetailScreen(groupId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/visibility',
    builder: (context, state) => const VisibilitySettingsScreen(),
  ),
  GoRoute(
    path: '/visibility/friend/:id',
    builder: (context, state) => VisibilitySettingsScreen(
      friendUserId: state.pathParameters['id'],
    ),
  ),
  GoRoute(
    path: '/notifications',
    builder: (context, state) => const NotificationSettingsScreen(),
  ),
  GoRoute(
    path: '/notifications/inbox',
    builder: (context, state) => const NotificationInboxScreen(),
  ),
  GoRoute(
    path: '/notifications/groups',
    builder: (context, state) => const ServerNotificationInboxScreen(),
  ),
  GoRoute(
    path: '/widgets',
    builder: (context, state) => const WidgetSettingsScreen(),
  ),
  GoRoute(
    path: '/settings/email-import',
    builder: (context, state) {
      final callback =
          EmailAuthorizationCallbackParameters.fromInternalUri(state.uri);
      return EmailImportSettingsScreen(
        callbackRequestedConnectionId: callback?.requestedConnectionId,
        callbackCorrelationId: callback?.correlationId,
      );
    },
  ),
  GoRoute(
    path: '/email-import',
    builder: (context, state) => const EmailCandidateInboxScreen(),
  ),
  GoRoute(
    path: '/email-import/update/:id',
    builder: (context, state) => EmailCandidateUpdateReviewScreen(
      updateId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/email-import/:id',
    builder: (context, state) => EmailCandidateReviewScreen(
      candidateId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/document-import',
    builder: (context, state) => const DocumentImportChatScreen(),
  ),
  GoRoute(
    path: '/settings',
    builder: (context, state) => const SettingsScreen(),
  ),
  GoRoute(
    path: '/invite/group/:token',
    builder: (context, state) =>
        GroupDetailScreen(inviteToken: state.pathParameters['token']),
  ),
  GoRoute(
    path: '/invite/friend/:token',
    builder: (context, state) =>
        FriendInvitationScreen(token: state.pathParameters['token']!),
  ),
];

String? _optionalQueryParameter(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: Center(child: CircularProgressIndicator())),
    );
  }
}

class _RouteNotFoundScreen extends StatelessWidget {
  const _RouteNotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ページを開けません')),
      body: Center(
        child: FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('ホームへ戻る'),
        ),
      ),
    );
  }
}
