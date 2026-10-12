import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error.dart';
import '../../../core/config/app_config_provider.dart';
import '../../../core/sync/drift_sync_queue.dart';
import '../../../core/sync/drift_schedule_sync_store.dart';
import '../../../core/sync/remote_schedule_gateway.dart';
import '../../../core/sync/sync_coordinator.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_worker.dart';
import '../../../core/time/app_clock.dart';
import '../../../local_db/app_database.dart' as local;
import '../../../local_db/app_database_provider.dart';
import '../../../local_db/demo_seed.dart';
import '../../auth/application/auth_providers.dart';
import '../../email_import/data/email_candidate_dedupe.dart';
import '../../onboarding/application/onboarding_providers.dart';

export '../../../local_db/app_database_provider.dart' show appDatabaseProvider;

const demoUserId = 'demo-user';
const demoUniversityId = 'demo-university';
const demoTermId = 'demo-term-2026-spring';
const demoPersonalCalendarId = 'cal-personal';

// Calendar list view intentionally stays finite: recurrence expansion walks
// candidate dates from DTSTART, so projecting an unbounded agenda would make
// a long-running daily routine increasingly expensive. The presentation makes
// this window explicit to the user.
const _calendarAgendaHorizon = Duration(days: 90);

class ActiveScheduleContext {
  const ActiveScheduleContext({
    required this.ownerUserId,
    required this.universityId,
    required this.termId,
    required this.academicYear,
    required this.primaryCalendarId,
  });

  final String ownerUserId;
  final String universityId;
  final String termId;
  final int academicYear;
  final String primaryCalendarId;

  void validate() {
    if (ownerUserId.trim().isEmpty ||
        universityId.trim().isEmpty ||
        termId.trim().isEmpty ||
        primaryCalendarId.trim().isEmpty ||
        academicYear < 1900 ||
        academicYear > 2200) {
      throw StateError('The active schedule context is incomplete.');
    }
  }
}

const demoScheduleContext = ActiveScheduleContext(
  ownerUserId: demoUserId,
  universityId: demoUniversityId,
  termId: demoTermId,
  academicYear: 2026,
  primaryCalendarId: demoPersonalCalendarId,
);

/// The currently usable schedule context, if authentication and onboarding
/// have both completed. UI consumers must treat a missing context as an auth
/// transition rather than reusing data that belonged to the previous user.
final activeScheduleContextProvider = Provider<ActiveScheduleContext?>((ref) {
  final session = ref.watch(currentAuthSessionProvider);
  final profile = ref.watch(onboardingControllerProvider).valueOrNull;
  if (session == null ||
      profile == null ||
      profile.userId != session.userId ||
      !profile.hasActiveSchedule) {
    return null;
  }
  final term = profile.activeTerm!;
  return ActiveScheduleContext(
    ownerUserId: session.userId,
    universityId: profile.universityId!,
    termId: term.id,
    academicYear: term.academicYear,
    primaryCalendarId: profile.primaryCalendarId!,
  );
});

/// Capability boundary for operations that may read or write user-scoped
/// schedule data. Presentation code should watch [activeScheduleContextProvider]
/// and render a transition state when it is null instead.
final requiredActiveScheduleContextProvider =
    Provider<ActiveScheduleContext>((ref) {
  final context = ref.watch(activeScheduleContextProvider);
  if (context == null) {
    throw StateError(
      'ActiveScheduleContext requires completed authenticated onboarding.',
    );
  }
  context.validate();
  return context;
});

/// Must only be enabled by a composition root that validated demo AppConfig.
final demoScheduleDataEnabledProvider = Provider<bool>((ref) => false);

class UserCourseInput {
  const UserCourseInput({
    required this.title,
    required this.dayOfWeek,
    required this.periodNo,
    this.room,
    this.instructorName,
    this.color,
    this.visibilityLevel = domain.VisibilityLevel.private,
  });

  final String title;
  final int dayOfWeek;
  final int periodNo;
  final String? room;
  final String? instructorName;
  final String? color;
  final domain.VisibilityLevel visibilityLevel;
}

class AssignmentInput {
  const AssignmentInput({
    required this.title,
    required this.dueAt,
    this.courseId,
    this.submissionUrl,
    this.memo,
    this.priority,
    this.visibilityLevel = domain.VisibilityLevel.private,
  });

  final String title;
  final DateTime dueAt;
  final String? courseId;
  final String? submissionUrl;
  final String? memo;
  final String? priority;
  final domain.VisibilityLevel visibilityLevel;
}

/// The immutable identity of a submission that may be undone safely.
///
/// [resultingVersion] is the version written by the submission. An undo must
/// still point at that exact version; this prevents a delayed SnackBar from
/// overwriting a newer state change for the same assignment.
class AssignmentUndoReceipt {
  const AssignmentUndoReceipt({
    required this.assignmentId,
    required this.ownerUserId,
    required this.previousState,
    required this.resultingVersion,
  });

  final String assignmentId;
  final String ownerUserId;
  final domain.AssignmentUserState? previousState;
  final int resultingVersion;
}

class ExamInput {
  const ExamInput({
    required this.title,
    required this.startAt,
    required this.endAt,
    this.courseId,
    this.room,
    this.memo,
    this.examType,
    this.visibilityLevel = domain.VisibilityLevel.private,
  });

  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? courseId;
  final String? room;
  final String? memo;
  final String? examType;
  final domain.VisibilityLevel visibilityLevel;
}

class EventInput {
  const EventInput({
    required this.title,
    required this.startAt,
    required this.endAt,
    this.calendarId,
    this.location,
    this.description,
    this.isAllDay,
    this.visibilityLevel = domain.VisibilityLevel.private,
    this.kind = domain.EventKind.normal,
    this.recurrenceRule,
  });

  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String? calendarId;
  final String? location;
  final String? description;
  final bool? isAllDay;
  final domain.VisibilityLevel? visibilityLevel;
  final domain.EventKind kind;
  final domain.RecurrenceRule? recurrenceRule;

  EventInput withCalendarId(String value) {
    return EventInput(
      title: title,
      startAt: startAt,
      endAt: endAt,
      calendarId: value,
      location: location,
      description: description,
      isAllDay: isAllDay,
      visibilityLevel: visibilityLevel,
      kind: kind,
      recurrenceRule: recurrenceRule,
    );
  }

  EventInput withIsAllDay(bool value) {
    return EventInput(
      title: title,
      startAt: startAt,
      endAt: endAt,
      calendarId: calendarId,
      location: location,
      description: description,
      isAllDay: value,
      visibilityLevel: visibilityLevel,
      kind: kind,
      recurrenceRule: recurrenceRule,
    );
  }
}

class EventExceptionInput {
  const EventExceptionInput({
    required this.recurrenceId,
    required this.mode,
    this.overrideStartAt,
    this.overrideEndAt,
    this.overrideTitle,
    this.overrideLocation,
    this.overrideDescription,
    this.overrideVisibility,
  });

  final DateTime recurrenceId;
  final domain.EventExceptionMode mode;
  final DateTime? overrideStartAt;
  final DateTime? overrideEndAt;
  final String? overrideTitle;
  final String? overrideLocation;
  final String? overrideDescription;
  final domain.VisibilityLevel? overrideVisibility;
}

final scheduleRepositoryProvider = Provider<ScheduleRepository>((ref) {
  return DriftScheduleRepository(
    ref.watch(appDatabaseProvider),
    enableDemoData: ref.watch(demoScheduleDataEnabledProvider),
    clock: ref.watch(appClockProvider).now,
  );
});

final syncQueueProvider = Provider<SyncQueue>((ref) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  return DriftSyncQueue(
    ref.watch(appDatabaseProvider),
    ownerUserId: context.ownerUserId,
  );
});

final remoteScheduleGatewayProvider = Provider<RemoteScheduleGateway>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.demoMode) {
    return FakeRemoteScheduleGateway();
  }
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    throw StateError('SupabaseClient is unavailable for schedule sync.');
  }
  return SupabaseScheduleGateway(client: client);
});

final syncMutationDispatcherProvider = Provider<SyncMutationDispatcher>((ref) {
  return SyncMutationDispatcher(ref.watch(remoteScheduleGatewayProvider));
});

final scheduleSyncStoreProvider = Provider<DriftScheduleSyncStore>((ref) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  return DriftScheduleSyncStore(
    ref.watch(appDatabaseProvider),
    ownerUserId: context.ownerUserId,
    clock: ref.watch(appClockProvider).now,
  );
});

final syncWorkerProvider = Provider.autoDispose<SyncWorker>((ref) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  final database = ref.watch(appDatabaseProvider);
  final queue = ref.watch(syncQueueProvider);
  final dispatcher = ref.watch(syncMutationDispatcherProvider);
  final store = ref.watch(scheduleSyncStoreProvider);
  var leaseActive = true;
  ref.onDispose(() => leaseActive = false);
  return SyncWorker(
    queue: queue,
    dispatcher: dispatcher,
    store: store,
    clock: ref.watch(appClockProvider).now,
    isContextCurrent: () {
      if (!leaseActive) return false;
      final current = ref.read(activeScheduleContextProvider);
      return identical(ref.read(appDatabaseProvider), database) &&
          current?.ownerUserId == context.ownerUserId &&
          current?.universityId == context.universityId &&
          current?.termId == context.termId &&
          current?.academicYear == context.academicYear &&
          current?.primaryCalendarId == context.primaryCalendarId;
    },
  );
});

final syncCoordinatorProvider = Provider.autoDispose<SyncCoordinator>((ref) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  final ownerUserId = context.ownerUserId;
  final database = ref.read(appDatabaseProvider);
  var leaseActive = true;
  ref.onDispose(() => leaseActive = false);
  bool contextIsCurrent() {
    if (!leaseActive || !identical(ref.read(appDatabaseProvider), database)) {
      return false;
    }
    final active = ref.read(activeScheduleContextProvider);
    return active?.ownerUserId == context.ownerUserId &&
        active?.universityId == context.universityId &&
        active?.termId == context.termId &&
        active?.academicYear == context.academicYear &&
        active?.primaryCalendarId == context.primaryCalendarId;
  }

  final coordinator = SyncCoordinator(
    ownerUserId: ownerUserId,
    worker: ref.watch(syncWorkerProvider),
    gateway: ref.watch(remoteScheduleGatewayProvider),
    store: ref.watch(scheduleSyncStoreProvider),
    isOwnerActive: () {
      final session = ref.read(currentAuthSessionProvider);
      final profile = ref.read(onboardingControllerProvider).valueOrNull;
      return contextIsCurrent() &&
          session?.userId == ownerUserId &&
          profile?.userId == ownerUserId;
    },
    isContextCurrent: contextIsCurrent,
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

abstract interface class TimetableRepository {
  Future<List<domain.UserCourse>> coursesForTerm({
    required String ownerUserId,
    required String termId,
  });

  /// Finds an active owned course across every term.
  ///
  /// Assignment and exam history can remain linked to a course in a
  /// non-selected term, so callers must not infer deletion from a current-term
  /// timetable snapshot alone.
  Future<domain.UserCourse?> activeCourseById({
    required String ownerUserId,
    required String courseId,
  });

  /// Resolves the active courses referenced by assignments across all terms.
  /// This is a bounded bulk lookup, not one query per visible assignment.
  Future<List<domain.UserCourse>> activeCoursesByIds({
    required String ownerUserId,
    required Iterable<String> courseIds,
  });

  Future<String> createUserCourse({
    required String ownerUserId,
    required String termId,
    required UserCourseInput input,
  });

  Future<void> updateUserCourse({
    required String courseId,
    required String ownerUserId,
    required int expectedVersion,
    required UserCourseInput input,
  });

  Future<void> deleteUserCourse({
    required String courseId,
    required String ownerUserId,
    required int expectedVersion,
  });
}

abstract interface class CourseTemplateRepository {
  Future<List<domain.CourseTemplate>> searchTemplates({
    required String universityId,
    required int academicYear,
    String? termId,
    String query,
    String instructor,
    int? weekday,
    int? period,
  });

  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  });
}

/// Optional contribution/update capability layered on top of the existing
/// search/copy repository contract. Keeping it separate avoids forcing demo
/// and test-only catalog fakes to implement authenticated server workflows.
abstract interface class CourseTemplateContributionRepository {
  Future<Map<String, Object?>> publishTemplate({
    required String courseId,
    String? operationId,
  });

  Future<Map<String, Object?>> submitEditProposal({
    required String templateId,
    required Map<String, Object?> proposedPayload,
    required int expectedVersion,
    String? operationId,
  });

  Future<Map<String, Object?>> reportTemplate({
    required String templateId,
    required String reason,
    String? operationId,
  });

  Future<Map<String, Object?>> templateDetails(String templateId);

  Future<Map<String, Object?>> templateUpdate(String courseId);

  Future<Map<String, Object?>> reviewTemplateUpdate({
    required String courseId,
    required String action,
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  });
}

extension CourseTemplateContributionExtension on CourseTemplateRepository {
  CourseTemplateContributionRepository get _contribution {
    final capability = this;
    if (capability is CourseTemplateContributionRepository) {
      return capability as CourseTemplateContributionRepository;
    }
    throw const PermissionError('この授業テンプレート操作は利用できません。');
  }

  Future<Map<String, Object?>> publishTemplate(
          {required String courseId, String? operationId}) =>
      _contribution.publishTemplate(
          courseId: courseId, operationId: operationId);
  Future<Map<String, Object?>> submitEditProposal(
          {required String templateId,
          required Map<String, Object?> proposedPayload,
          required int expectedVersion,
          String? operationId}) =>
      _contribution.submitEditProposal(
          templateId: templateId,
          proposedPayload: proposedPayload,
          expectedVersion: expectedVersion,
          operationId: operationId);
  Future<Map<String, Object?>> reportTemplate(
          {required String templateId,
          required String reason,
          String? operationId}) =>
      _contribution.reportTemplate(
          templateId: templateId, reason: reason, operationId: operationId);
  Future<Map<String, Object?>> templateDetails(String templateId) =>
      _contribution.templateDetails(templateId);
  Future<Map<String, Object?>> templateUpdate(String courseId) =>
      _contribution.templateUpdate(courseId);
  Future<Map<String, Object?>> reviewTemplateUpdate(
          {required String courseId,
          required String action,
          int? expectedTemplateVersion,
          int? expectedCourseVersion}) =>
      _contribution.reviewTemplateUpdate(
          courseId: courseId,
          action: action,
          expectedTemplateVersion: expectedTemplateVersion,
          expectedCourseVersion: expectedCourseVersion);
}

abstract interface class AssignmentRepository {
  Future<List<domain.Assignment>> assignmentsForUser(String ownerUserId);

  Future<Map<String, domain.AssignmentUserState>> assignmentStatesForUser(
    String userId,
  );

  Future<void> submitAssignment({
    required String assignmentId,
    required String userId,
    required DateTime submittedAt,
  });

  /// Submits an assignment and returns the versioned receipt used by Undo.
  Future<AssignmentUndoReceipt> submitAssignmentWithReceipt({
    required String assignmentId,
    required String userId,
    required DateTime submittedAt,
  });

  /// Restores the state captured by a submission receipt if that submission is
  /// still the current state. Implementations must perform the identity and
  /// version guard in the same transaction as the write and outbox enqueue.
  Future<void> undoAssignmentSubmission({
    required AssignmentUndoReceipt receipt,
    required DateTime updatedAt,
  });

  /// Persists a non-submitted personal state. Submitted state changes use the
  /// dedicated [submitAssignment] path so the submission timestamp remains an
  /// explicit, auditable action.
  Future<void> updateAssignmentState({
    required String assignmentId,
    required String userId,
    required domain.AssignmentStatus status,
    required DateTime updatedAt,
  });

  Future<String> createAssignment({
    required String ownerUserId,
    required AssignmentInput input,
  });

  Future<void> updateAssignment({
    required String assignmentId,
    required String ownerUserId,
    required int expectedVersion,
    required AssignmentInput input,
  });

  Future<void> deleteAssignment({
    required String assignmentId,
    required String ownerUserId,
    required int expectedVersion,
  });
}

abstract interface class ExamRepository {
  Future<List<domain.Exam>> examsForUser(String ownerUserId);

  Future<String> createExam({
    required String ownerUserId,
    required ExamInput input,
  });

  Future<void> updateExam({
    required String examId,
    required String ownerUserId,
    required int expectedVersion,
    required ExamInput input,
  });

  Future<void> deleteExam({
    required String examId,
    required String ownerUserId,
    required int expectedVersion,
  });
}

abstract interface class EventRepository {
  Future<List<domain.ScheduleEvent>> eventsForUser(String ownerUserId);

  Future<List<domain.EventException>> eventExceptionsForEvent({
    required String eventId,
    required String ownerUserId,
  });

  Future<String> createEvent({
    required String ownerUserId,
    required EventInput input,
  });

  Future<void> updateEvent({
    required String eventId,
    required String ownerUserId,
    required int expectedVersion,
    required EventInput input,
  });

  Future<void> deleteEvent({
    required String eventId,
    required String ownerUserId,
    required int expectedVersion,
  });

  Future<String> createEventException({
    required String eventId,
    required String ownerUserId,
    required EventExceptionInput input,
  });

  Future<void> updateEventException({
    required String exceptionId,
    required String eventId,
    required String ownerUserId,
    required EventExceptionInput input,
  });

  Future<void> deleteEventException({
    required String exceptionId,
    required String eventId,
    required String ownerUserId,
  });
}

abstract interface class SyncMutationRepository {
  Future<List<PendingMutation>> pendingMutations({
    required String ownerUserId,
  });

  Future<SyncQueueCounts> syncQueueCounts({required String ownerUserId});
}

abstract interface class CalendarProjectionRepository {
  Future<List<domain.CalendarProjectionItem>> calendarProjection({
    required String ownerUserId,
    required String universityId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  });
}

abstract interface class ScheduleRepository
    implements
        TimetableRepository,
        CourseTemplateRepository,
        AssignmentRepository,
        ExamRepository,
        EventRepository,
        CourseTemplateContributionRepository,
        SyncMutationRepository,
        CalendarProjectionRepository {
  Future<void> ensureDemoDataSeeded();

  Future<LocalScheduleSnapshot> loadSnapshot({
    required DateTime now,
    required String ownerUserId,
    required String universityId,
    required String termId,
    required int academicYear,
  });

  Stream<LocalScheduleSnapshot> watchSnapshot({
    required DateTime now,
    required String ownerUserId,
    required String universityId,
    required String termId,
    required int academicYear,
  });

  Future<domain.WidgetSnapshot> saveWidgetSnapshot({
    required String ownerUserId,
    required String universityId,
    required String termId,
    required domain.WidgetSnapshotSettings settings,
    required DateTime generatedAt,
  });
}

class LocalScheduleSnapshot {
  const LocalScheduleSnapshot({
    required this.templates,
    required this.periodSettings,
    required this.courses,
    this.assignmentCourses = const [],
    required this.assignments,
    required this.assignmentStates,
    required this.exams,
    required this.events,
    required this.eventExceptions,
    required this.calendarItems,
    required this.widgetSnapshot,
    required this.pendingMutations,
    required this.syncQueueCounts,
  });

  final List<domain.CourseTemplate> templates;
  final List<domain.PeriodSetting> periodSettings;
  final List<domain.UserCourse> courses;
  final List<domain.UserCourse> assignmentCourses;
  final List<domain.Assignment> assignments;
  final Map<String, domain.AssignmentUserState> assignmentStates;
  final List<domain.Exam> exams;
  final List<domain.ScheduleEvent> events;
  final List<domain.EventException> eventExceptions;
  final List<domain.CalendarProjectionItem> calendarItems;
  final domain.WidgetSnapshot widgetSnapshot;
  final List<PendingMutation> pendingMutations;
  final SyncQueueCounts syncQueueCounts;
}

class DriftScheduleRepository implements ScheduleRepository {
  DriftScheduleRepository(
    this.db, {
    String Function()? createId,
    this.enableDemoData = false,
    domain.CourseNormalizer? normalizer,
    domain.CalendarProjectionService? calendarProjectionService,
    domain.WidgetSnapshotGenerator? widgetSnapshotGenerator,
    DateTime Function()? clock,
  })  : _createId = createId ?? (() => const Uuid().v4()),
        _clock = clock ?? DateTime.now,
        _normalizer = normalizer ?? domain.CourseNormalizer(),
        _calendarProjectionService =
            calendarProjectionService ?? domain.CalendarProjectionService(),
        _widgetSnapshotGenerator =
            widgetSnapshotGenerator ?? domain.WidgetSnapshotGenerator();

  final local.AppDatabase db;
  final bool enableDemoData;
  final String Function() _createId;
  final DateTime Function() _clock;
  final domain.CourseNormalizer _normalizer;
  final domain.CalendarProjectionService _calendarProjectionService;
  final domain.WidgetSnapshotGenerator _widgetSnapshotGenerator;
  bool _initialized = false;
  bool _demoDataSeeded = false;
  Future<void>? _demoDataSeedOperation;

  @override
  Future<void> ensureDemoDataSeeded() async {
    if (!enableDemoData || _demoDataSeeded) return;
    final inFlight = _demoDataSeedOperation;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final operation = DriftDemoSeeder(db).seed();
    _demoDataSeedOperation = operation;
    try {
      await operation;
      _demoDataSeeded = true;
    } finally {
      _demoDataSeedOperation = null;
    }
  }

  Future<void> _initializeLocalData() async {
    if (_initialized) return;
    await DriftSyncQueue.cleanupAcknowledgedGlobally(
      db,
      now: emailScheduleSqliteTimestamp(_clock()),
    );
    await ensureDemoDataSeeded();
    _initialized = true;
  }

  @override
  Future<LocalScheduleSnapshot> loadSnapshot({
    required DateTime now,
    required String ownerUserId,
    required String universityId,
    required String termId,
    required int academicYear,
  }) async {
    final normalizedNow = now.toUtc();
    _validateContext(
      ownerUserId: ownerUserId,
      universityId: universityId,
      termId: termId,
      academicYear: academicYear,
    );
    await _initializeLocalData();
    final templates = await searchTemplates(
      universityId: universityId,
      academicYear: academicYear,
      termId: termId,
    );
    final periodSettings = await _periodSettingsForContext(
      ownerUserId: ownerUserId,
      universityId: universityId,
      termId: termId,
    );
    final courses = await coursesForTerm(
      ownerUserId: ownerUserId,
      termId: termId,
    );
    final assignments = await assignmentsForUser(ownerUserId);
    final assignmentCourses = await activeCoursesByIds(
      ownerUserId: ownerUserId,
      courseIds: assignments
          .map((assignment) => assignment.courseId)
          .whereType<String>(),
    );
    final assignmentStates = await assignmentStatesForUser(ownerUserId);
    final exams = await _examsForUser(ownerUserId);
    final events = await _eventsForUser(ownerUserId);
    final eventExceptions = await _eventExceptionsFor(events);
    final calendarItems = _calendarProjectionService.project(
      rangeStart: _calendarRangeStart(normalizedNow),
      rangeEnd: _calendarRangeEnd(normalizedNow),
      courses: courses,
      periodSettings: periodSettings,
      assignments: assignments,
      assignmentStates: assignmentStates,
      exams: exams,
      events: events,
      eventExceptions: eventExceptions,
    );
    final widgetSnapshot = _widgetSnapshotGenerator.generate(
      courses: courses,
      generatedAt: normalizedNow,
      periodSettings: periodSettings,
      settings: await _widgetSnapshotSettingsForUser(ownerUserId),
    );
    final pending = await pendingMutations(ownerUserId: ownerUserId);
    final counts = await syncQueueCounts(ownerUserId: ownerUserId);

    return LocalScheduleSnapshot(
      templates: templates,
      periodSettings: periodSettings,
      courses: courses,
      assignmentCourses: assignmentCourses,
      assignments: assignments,
      assignmentStates: assignmentStates,
      exams: exams,
      events: events,
      eventExceptions: eventExceptions,
      calendarItems: calendarItems,
      widgetSnapshot: widgetSnapshot,
      pendingMutations: pending,
      syncQueueCounts: counts,
    );
  }

  @override
  Stream<LocalScheduleSnapshot> watchSnapshot({
    required DateTime now,
    required String ownerUserId,
    required String universityId,
    required String termId,
    required int academicYear,
  }) async* {
    _validateContext(
      ownerUserId: ownerUserId,
      universityId: universityId,
      termId: termId,
      academicYear: academicYear,
    );
    await _initializeLocalData();
    final changes = db.customSelect(
      'SELECT 1 AS schedule_change',
      readsFrom: {
        db.courseTemplatesCache,
        db.periodSettings,
        db.userCourses,
        db.assignments,
        db.assignmentUserStates,
        db.exams,
        db.calendars,
        db.events,
        db.eventExceptions,
        db.syncQueueEntries,
        db.widgetSnapshots,
      },
    ).watch();
    await for (final _ in changes) {
      yield await loadSnapshot(
        now: now,
        ownerUserId: ownerUserId,
        universityId: universityId,
        termId: termId,
        academicYear: academicYear,
      );
    }
  }

  @override
  Future<List<domain.Exam>> examsForUser(String ownerUserId) {
    return _examsForUser(ownerUserId);
  }

  @override
  Future<String> createExam({
    required String ownerUserId,
    required ExamInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeExamInput(input);
    _requireScheduleTitle(normalizedInput.title, 'Exam');
    if (!normalizedInput.endAt.isAfter(normalizedInput.startAt)) {
      throw ArgumentError.value(
        normalizedInput.endAt,
        'endAt',
        'Exam must end later',
      );
    }
    final examId = _createId();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCourseIfPresent(normalizedInput.courseId, ownerUserId);
      await db.examDao.upsertExam(
        local.ExamsCompanion.insert(
          id: examId,
          ownerUserId: ownerUserId,
          courseId: Value(normalizedInput.courseId),
          title: normalizedInput.title,
          startAt: normalizedInput.startAt,
          endAt: normalizedInput.endAt,
          room: Value(normalizedInput.room),
          memo: Value(normalizedInput.memo),
          examType: Value(normalizedInput.examType),
          visibilityLevel: Value(normalizedInput.visibilityLevel.wireName),
          updatedAt: Value(now),
        ),
      );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: examId,
        operation: SyncOperation.create,
        payload: _examPayload(
          id: examId,
          ownerUserId: ownerUserId,
          input: normalizedInput,
          updatedAt: now,
        ),
        createdAt: now,
      );
    });
    return examId;
  }

  @override
  Future<void> updateExam({
    required String examId,
    required String ownerUserId,
    required int expectedVersion,
    required ExamInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeExamInput(input);
    _requireScheduleTitle(normalizedInput.title, 'Exam');
    if (!normalizedInput.endAt.isAfter(normalizedInput.startAt)) {
      throw ArgumentError.value(
        normalizedInput.endAt,
        'endAt',
        'Exam must end later',
      );
    }
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCourseIfPresent(normalizedInput.courseId, ownerUserId);
      final existing = await (db.select(db.exams)
            ..where(
              (row) =>
                  row.id.equals(examId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(examId, 'examId', 'Exam not found');
      }
      _requireExpectedVersion(
        entityType: 'Exam',
        entityId: examId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.exams)
            ..where(
              (row) =>
                  row.id.equals(examId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.ExamsCompanion(
          courseId: Value(normalizedInput.courseId),
          title: Value(normalizedInput.title),
          startAt: Value(normalizedInput.startAt),
          endAt: Value(normalizedInput.endAt),
          room: Value(normalizedInput.room),
          memo: Value(normalizedInput.memo),
          examType: Value(normalizedInput.examType),
          visibilityLevel: Value(normalizedInput.visibilityLevel.wireName),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Exam', examId);
      final basePayload = _examRowPayload(existing);
      final nextPayload = _examPayload(
        id: examId,
        ownerUserId: ownerUserId,
        input: normalizedInput,
        updatedAt: now,
        version: nextVersion,
      );
      final nextReceiptPayload = {...nextPayload, 'scope': existing.scope};
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: examId,
        operation: SyncOperation.update,
        payload: nextReceiptPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: examId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: nextReceiptPayload,
        notificationAnchor: normalizedInput.startAt,
        updatedAt: now,
      );
    });
  }

  @override
  Future<void> deleteExam({
    required String examId,
    required String ownerUserId,
    required int expectedVersion,
  }) async {
    await ensureDemoDataSeeded();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final existing = await (db.select(db.exams)
            ..where(
              (row) =>
                  row.id.equals(examId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(examId, 'examId', 'Exam not found');
      }
      _requireExpectedVersion(
        entityType: 'Exam',
        entityId: examId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.exams)
            ..where(
              (row) =>
                  row.id.equals(examId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.ExamsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Exam', examId);
      final basePayload = _examRowPayload(existing);
      final deletedPayload = <String, Object?>{
        ...basePayload,
        'deletedAt': now,
        'updatedAt': now,
        'version': nextVersion,
      };
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: examId,
        operation: SyncOperation.delete,
        payload: deletedPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'exam',
        entityId: examId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: deletedPayload,
        notificationAnchor: existing.startAt,
        updatedAt: now,
        deleted: true,
      );
    });
  }

  @override
  Future<List<domain.UserCourse>> coursesForTerm({
    required String ownerUserId,
    required String termId,
  }) async {
    final rows = await db.timetableDao.coursesForTerm(ownerUserId, termId);
    return rows.map(_courseFromRow).toList();
  }

  @override
  Future<domain.UserCourse?> activeCourseById({
    required String ownerUserId,
    required String courseId,
  }) async {
    final row = await db.timetableDao.courseById(courseId, ownerUserId);
    return row == null ? null : _courseFromRow(row);
  }

  @override
  Future<List<domain.UserCourse>> activeCoursesByIds({
    required String ownerUserId,
    required Iterable<String> courseIds,
  }) async {
    final rows = await db.timetableDao.activeCoursesByIds(
      ownerUserId,
      courseIds,
    );
    return rows.map(_courseFromRow).toList();
  }

  @override
  Future<String> createUserCourse({
    required String ownerUserId,
    required String termId,
    required UserCourseInput input,
  }) async {
    await ensureDemoDataSeeded();
    final courseId = _createId();
    final normalizedTitle = _normalizer.normalizeTitle(input.title);
    final normalizedInstructor =
        _normalizer.normalizeInstructor(input.instructorName);
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await db.timetableDao.upsertCourse(
        local.UserCoursesCompanion.insert(
          id: courseId,
          ownerUserId: ownerUserId,
          termId: termId,
          title: input.title,
          normalizedTitle: normalizedTitle,
          instructorName: Value(input.instructorName),
          normalizedInstructorName: Value(normalizedInstructor),
          dayOfWeek: Value(input.dayOfWeek),
          periodNo: Value(input.periodNo),
          room: Value(input.room),
          color: Value(input.color),
          visibilityLevel: Value(input.visibilityLevel.wireName),
          updatedAt: Value(now),
        ),
      );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'user_course',
        entityId: courseId,
        operation: SyncOperation.create,
        payload: _coursePayload(
          id: courseId,
          ownerUserId: ownerUserId,
          termId: termId,
          input: input,
          normalizedTitle: normalizedTitle,
          normalizedInstructorName: normalizedInstructor,
          updatedAt: now,
        ),
        createdAt: now,
      );
    });
    return courseId;
  }

  @override
  Future<void> updateUserCourse({
    required String courseId,
    required String ownerUserId,
    required int expectedVersion,
    required UserCourseInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedTitle = _normalizer.normalizeTitle(input.title);
    final normalizedInstructor =
        _normalizer.normalizeInstructor(input.instructorName);
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final existing = await (db.select(db.userCourses)
            ..where(
              (row) =>
                  row.id.equals(courseId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(courseId, 'courseId', 'Course not found');
      }
      _requireExpectedVersion(
        entityType: 'Course',
        entityId: courseId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.userCourses)
            ..where(
              (row) =>
                  row.id.equals(courseId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.UserCoursesCompanion(
          title: Value(input.title),
          normalizedTitle: Value(normalizedTitle),
          instructorName: Value(input.instructorName),
          normalizedInstructorName: Value(normalizedInstructor),
          dayOfWeek: Value(input.dayOfWeek),
          periodNo: Value(input.periodNo),
          room: Value(input.room),
          color: Value(input.color),
          visibilityLevel: Value(input.visibilityLevel.wireName),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Course', courseId);
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'user_course',
        entityId: courseId,
        operation: SyncOperation.update,
        payload: _coursePayload(
          id: courseId,
          ownerUserId: ownerUserId,
          termId: existing.termId,
          input: input,
          normalizedTitle: normalizedTitle,
          normalizedInstructorName: normalizedInstructor,
          sourceTemplateId: existing.sourceTemplateId,
          updatedAt: now,
          version: nextVersion,
        ),
        createdAt: now,
        baseVersion: existing.version,
      );
    });
  }

  @override
  Future<void> deleteUserCourse({
    required String courseId,
    required String ownerUserId,
    required int expectedVersion,
  }) async {
    await ensureDemoDataSeeded();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final existing = await (db.select(db.userCourses)
            ..where(
              (row) =>
                  row.id.equals(courseId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(courseId, 'courseId', 'Course not found');
      }
      _requireExpectedVersion(
        entityType: 'Course',
        entityId: courseId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.userCourses)
            ..where(
              (row) =>
                  row.id.equals(courseId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.UserCoursesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Course', courseId);
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'user_course',
        entityId: courseId,
        operation: SyncOperation.delete,
        payload: _deletePayload(
          id: courseId,
          ownerUserId: ownerUserId,
          deletedAt: now,
          version: nextVersion,
        ),
        createdAt: now,
        baseVersion: existing.version,
      );
    });
  }

  @override
  Future<List<domain.CourseTemplate>> searchTemplates({
    required String universityId,
    required int academicYear,
    String? termId,
    String query = '',
    String instructor = '',
    int? weekday,
    int? period,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedQuery = _normalizer.normalizeTitle(query);
    final normalizedInstructor = _normalizer.normalizeInstructor(instructor);
    final rows = await db.courseTemplateDao.cachedTemplates(universityId);
    final templates = rows
        .map(_templateFromRow)
        .where((template) => template.academicYear == academicYear)
        .where((template) => termId == null || template.termId == termId)
        .where((template) => weekday == null || template.dayOfWeek == weekday)
        .where((template) => period == null || template.periodNo == period)
        .where((template) {
      if (normalizedInstructor.isEmpty) return true;
      return (template.normalizedInstructorName ?? '')
          .contains(normalizedInstructor);
    }).where((template) {
      if (normalizedQuery.isEmpty) return true;
      final instructor = template.normalizedInstructorName ?? '';
      return template.normalizedTitle.contains(normalizedQuery) ||
          instructor.contains(normalizedQuery);
    }).toList();

    return _normalizer.rankTemplates(
      templates,
      query: query,
      dayOfWeek: weekday,
      periodNo: period,
    );
  }

  @override
  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  }) async {
    await ensureDemoDataSeeded();
    return db.transaction(() async {
      final template = await db.courseTemplateDao.templateById(templateId);
      if (template == null) {
        throw ArgumentError.value(
            templateId, 'templateId', 'Template not found');
      }

      final now = emailScheduleSqliteTimestamp(_clock());
      await (db.update(db.courseTemplatesCache)
            ..where((row) => row.id.equals(templateId)))
          .write(
        local.CourseTemplatesCacheCompanion(
          copyCountTotal: Value(template.copyCountTotal + 1),
          copyCountTerm: Value(template.copyCountTerm + 1),
          cachedAt: Value(now),
        ),
      );

      final courseId = _createId();
      final input = UserCourseInput(
        title: template.title,
        dayOfWeek: template.dayOfWeek ?? DateTime.monday,
        periodNo: template.periodNo ?? 1,
        room: template.room,
        instructorName: template.instructorName,
        color: '#2F80ED',
        visibilityLevel: domain.VisibilityLevel.private,
      );
      await db.timetableDao.upsertCourse(
        local.UserCoursesCompanion.insert(
          id: courseId,
          ownerUserId: ownerUserId,
          termId: termId,
          sourceTemplateId: Value(template.id),
          title: template.title,
          normalizedTitle: template.normalizedTitle,
          instructorName: Value(template.instructorName),
          normalizedInstructorName: Value(template.normalizedInstructorName),
          dayOfWeek: Value(template.dayOfWeek),
          periodNo: Value(template.periodNo),
          room: Value(template.room),
          color: const Value('#2F80ED'),
          visibilityLevel: const Value('PRIVATE'),
          updatedAt: Value(now),
        ),
      );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'user_course',
        entityId: courseId,
        operation: SyncOperation.create,
        payload: _coursePayload(
          id: courseId,
          ownerUserId: ownerUserId,
          termId: termId,
          input: input,
          normalizedTitle: template.normalizedTitle,
          normalizedInstructorName: template.normalizedInstructorName,
          sourceTemplateId: template.id,
          updatedAt: now,
        ),
        createdAt: now,
      );
      return courseId;
    });
  }

  @override
  Future<Map<String, Object?>> publishTemplate({
    required String courseId,
    String? operationId,
  }) async {
    throw const PermissionError('デモモードでは授業テンプレートを公開できません。');
  }

  @override
  Future<Map<String, Object?>> submitEditProposal({
    required String templateId,
    required Map<String, Object?> proposedPayload,
    required int expectedVersion,
    String? operationId,
  }) async {
    throw const PermissionError('デモモードでは授業テンプレートを提案できません。');
  }

  @override
  Future<Map<String, Object?>> reportTemplate({
    required String templateId,
    required String reason,
    String? operationId,
  }) async {
    throw const PermissionError('デモモードでは授業テンプレートを通報できません。');
  }

  @override
  Future<Map<String, Object?>> templateDetails(String templateId) async {
    throw const PermissionError('デモモードでは授業テンプレートを表示できません。');
  }

  @override
  Future<Map<String, Object?>> templateUpdate(String courseId) async {
    return const {'available': false, 'state': 'none'};
  }

  @override
  Future<Map<String, Object?>> reviewTemplateUpdate({
    required String courseId,
    required String action,
    int? expectedTemplateVersion,
    int? expectedCourseVersion,
  }) async {
    throw const PermissionError('デモモードでは授業テンプレート更新を適用できません。');
  }

  @override
  Future<List<domain.Assignment>> assignmentsForUser(String ownerUserId) async {
    final rows = await db.assignmentDao.assignmentsForUser(ownerUserId);
    return rows.map(_assignmentFromRow).toList();
  }

  @override
  Future<Map<String, domain.AssignmentUserState>> assignmentStatesForUser(
    String userId,
  ) async {
    final rows = await db.assignmentDao.statesForUser(userId);
    return {
      for (final row in rows) row.assignmentId: _assignmentStateFromRow(row),
    };
  }

  @override
  Future<void> submitAssignment({
    required String assignmentId,
    required String userId,
    required DateTime submittedAt,
  }) async {
    await submitAssignmentWithReceipt(
      assignmentId: assignmentId,
      userId: userId,
      submittedAt: submittedAt,
    );
  }

  @override
  Future<AssignmentUndoReceipt> submitAssignmentWithReceipt({
    required String assignmentId,
    required String userId,
    required DateTime submittedAt,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedSubmittedAt = submittedAt.toUtc();
    return db.transaction(() async {
      final assignment = await (db.select(db.assignments)
            ..where((row) =>
                row.id.equals(assignmentId) &
                row.ownerUserId.equals(userId) &
                row.deletedAt.isNull()))
          .getSingleOrNull();
      if (assignment == null) {
        throw ArgumentError.value(
          assignmentId,
          'assignmentId',
          'Assignment is unavailable for this owner',
        );
      }
      final existingState = await db.assignmentDao.stateForAssignment(
        assignmentId: assignmentId,
        userId: userId,
      );
      final nextVersion = (existingState?.version ?? 0) + 1;
      final previousState =
          existingState == null || existingState.deletedAt != null
              ? null
              : domain.AssignmentUserState(
                  assignmentId: existingState.assignmentId,
                  userId: existingState.userId,
                  status: _assignmentStatusFromWire(existingState.status),
                  submittedAt: existingState.submittedAt?.toUtc(),
                  note: existingState.note,
                  version: existingState.version,
                );
      await db.into(db.assignmentUserStates).insertOnConflictUpdate(
            local.AssignmentUserStatesCompanion.insert(
              assignmentId: assignmentId,
              userId: userId,
              status: const Value('submitted'),
              submittedAt: Value(normalizedSubmittedAt),
              updatedAt: Value(normalizedSubmittedAt),
              deletedAt: const Value(null),
              version: Value(nextVersion),
            ),
          );
      await _enqueueMutation(
        ownerUserId: userId,
        entityType: 'assignment_user_state',
        entityId: assignmentId,
        operation: SyncOperation.submit,
        payload: {
          'assignmentId': assignmentId,
          'userId': userId,
          'status': 'submitted',
          'submittedAt': normalizedSubmittedAt,
          'updatedAt': normalizedSubmittedAt,
          'version': nextVersion,
        },
        createdAt: normalizedSubmittedAt,
        baseVersion: existingState?.version,
      );
      return AssignmentUndoReceipt(
        assignmentId: assignmentId,
        ownerUserId: userId,
        previousState: previousState,
        resultingVersion: nextVersion,
      );
    });
  }

  @override
  Future<void> undoAssignmentSubmission({
    required AssignmentUndoReceipt receipt,
    required DateTime updatedAt,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedUpdatedAt = updatedAt.toUtc();
    await db.transaction(() async {
      final assignment = await (db.select(db.assignments)
            ..where((row) =>
                row.id.equals(receipt.assignmentId) &
                row.ownerUserId.equals(receipt.ownerUserId) &
                row.deletedAt.isNull()))
          .getSingleOrNull();
      if (assignment == null) {
        throw ArgumentError.value(
          receipt.assignmentId,
          'receipt',
          'Assignment is unavailable for this owner',
        );
      }
      final currentState = await db.assignmentDao.stateForAssignment(
        assignmentId: receipt.assignmentId,
        userId: receipt.ownerUserId,
      );
      if (currentState == null ||
          currentState.deletedAt != null ||
          currentState.status != 'submitted' ||
          currentState.version != receipt.resultingVersion) {
        throw const ConflictError(
          'The assignment changed before the submission could be undone.',
        );
      }

      final previousState = receipt.previousState;
      final restoredStatus =
          previousState?.status ?? domain.AssignmentStatus.notStarted;
      // `overdue` is a derived read-time state. If an older client persisted
      // it, restore the canonical not-started state rather than enqueueing an
      // invalid direct overdue mutation.
      final persistedStatus = restoredStatus == domain.AssignmentStatus.overdue
          ? domain.AssignmentStatus.notStarted
          : restoredStatus;
      final nextVersion = currentState.version + 1;
      await db.into(db.assignmentUserStates).insertOnConflictUpdate(
            local.AssignmentUserStatesCompanion.insert(
              assignmentId: receipt.assignmentId,
              userId: receipt.ownerUserId,
              status: Value(persistedStatus.name),
              submittedAt: Value(previousState?.submittedAt?.toUtc()),
              note: Value(previousState?.note),
              updatedAt: Value(normalizedUpdatedAt),
              deletedAt: const Value(null),
              version: Value(nextVersion),
            ),
          );
      await _enqueueMutation(
        ownerUserId: receipt.ownerUserId,
        entityType: 'assignment_user_state',
        entityId: receipt.assignmentId,
        // The submission always materializes a current row, so Undo is an
        // update against that guarded row even when the prior state was the
        // canonical absent/not-started state.
        operation: SyncOperation.update,
        payload: {
          'assignmentId': receipt.assignmentId,
          'userId': receipt.ownerUserId,
          'status': persistedStatus.name,
          'submittedAt': previousState?.submittedAt?.toUtc(),
          'note': previousState?.note,
          'updatedAt': normalizedUpdatedAt,
          'version': nextVersion,
        },
        createdAt: normalizedUpdatedAt,
        baseVersion: currentState.version,
      );
    });
  }

  @override
  Future<void> updateAssignmentState({
    required String assignmentId,
    required String userId,
    required domain.AssignmentStatus status,
    required DateTime updatedAt,
  }) async {
    if (status == domain.AssignmentStatus.submitted ||
        status == domain.AssignmentStatus.overdue) {
      throw ArgumentError.value(
        status,
        'status',
        'Only not-started and in-progress states can be updated directly',
      );
    }
    await ensureDemoDataSeeded();
    final normalizedUpdatedAt = updatedAt.toUtc();
    await db.transaction(() async {
      final assignment = await (db.select(db.assignments)
            ..where((row) =>
                row.id.equals(assignmentId) &
                row.ownerUserId.equals(userId) &
                row.deletedAt.isNull()))
          .getSingleOrNull();
      if (assignment == null) {
        throw ArgumentError.value(
          assignmentId,
          'assignmentId',
          'Assignment is unavailable for this owner',
        );
      }
      final existingState = await db.assignmentDao.stateForAssignment(
        assignmentId: assignmentId,
        userId: userId,
      );
      // No row is the canonical representation of not-started. Avoid creating
      // a redundant outbox mutation when a caller asks for that same state.
      if (existingState == null &&
          status == domain.AssignmentStatus.notStarted) {
        return;
      }
      final nextVersion = (existingState?.version ?? 0) + 1;
      await db.into(db.assignmentUserStates).insertOnConflictUpdate(
            local.AssignmentUserStatesCompanion.insert(
              assignmentId: assignmentId,
              userId: userId,
              status: Value(status.name),
              submittedAt: const Value(null),
              note: Value(existingState?.note),
              updatedAt: Value(normalizedUpdatedAt),
              deletedAt: const Value(null),
              version: Value(nextVersion),
            ),
          );
      await _enqueueMutation(
        ownerUserId: userId,
        entityType: 'assignment_user_state',
        entityId: assignmentId,
        operation:
            existingState == null ? SyncOperation.create : SyncOperation.update,
        payload: {
          'assignmentId': assignmentId,
          'userId': userId,
          'status': status.name,
          'submittedAt': null,
          'updatedAt': normalizedUpdatedAt,
          'version': nextVersion,
        },
        createdAt: normalizedUpdatedAt,
        baseVersion: existingState?.version,
      );
    });
  }

  @override
  Future<String> createAssignment({
    required String ownerUserId,
    required AssignmentInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeAssignmentInput(input);
    _requireScheduleTitle(normalizedInput.title, 'Assignment');
    final assignmentId = _createId();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCourseIfPresent(normalizedInput.courseId, ownerUserId);
      await db.assignmentDao.upsertAssignment(
        local.AssignmentsCompanion.insert(
          id: assignmentId,
          ownerUserId: ownerUserId,
          courseId: Value(normalizedInput.courseId),
          title: normalizedInput.title,
          description: Value(normalizedInput.memo),
          submissionUrl: Value(normalizedInput.submissionUrl),
          priority: Value(normalizedInput.priority),
          dueAt: normalizedInput.dueAt,
          visibilityLevel: Value(normalizedInput.visibilityLevel.wireName),
          updatedAt: Value(now),
        ),
      );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: assignmentId,
        operation: SyncOperation.create,
        payload: _assignmentPayload(
          id: assignmentId,
          ownerUserId: ownerUserId,
          input: normalizedInput,
          updatedAt: now,
        ),
        createdAt: now,
      );
    });
    return assignmentId;
  }

  @override
  Future<void> updateAssignment({
    required String assignmentId,
    required String ownerUserId,
    required int expectedVersion,
    required AssignmentInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeAssignmentInput(input);
    _requireScheduleTitle(normalizedInput.title, 'Assignment');
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCourseIfPresent(normalizedInput.courseId, ownerUserId);
      final existing = await (db.select(db.assignments)
            ..where(
              (row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(
          assignmentId,
          'assignmentId',
          'Assignment not found',
        );
      }
      _requireExpectedVersion(
        entityType: 'Assignment',
        entityId: assignmentId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.assignments)
            ..where(
              (row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.AssignmentsCompanion(
          courseId: Value(normalizedInput.courseId),
          title: Value(normalizedInput.title),
          description: Value(normalizedInput.memo),
          submissionUrl: Value(normalizedInput.submissionUrl),
          priority: Value(normalizedInput.priority),
          dueAt: Value(normalizedInput.dueAt),
          visibilityLevel: Value(normalizedInput.visibilityLevel.wireName),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Assignment', assignmentId);
      final basePayload = _assignmentRowPayload(existing);
      final nextPayload = _assignmentPayload(
        id: assignmentId,
        ownerUserId: ownerUserId,
        input: normalizedInput,
        updatedAt: now,
        version: nextVersion,
      );
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: assignmentId,
        operation: SyncOperation.update,
        payload: nextPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: assignmentId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: nextPayload,
        notificationAnchor: normalizedInput.dueAt,
        updatedAt: now,
      );
    });
  }

  @override
  Future<void> deleteAssignment({
    required String assignmentId,
    required String ownerUserId,
    required int expectedVersion,
  }) async {
    await ensureDemoDataSeeded();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final existing = await (db.select(db.assignments)
            ..where(
              (row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(
          assignmentId,
          'assignmentId',
          'Assignment not found',
        );
      }
      _requireExpectedVersion(
        entityType: 'Assignment',
        entityId: assignmentId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.assignments)
            ..where(
              (row) =>
                  row.id.equals(assignmentId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.AssignmentsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Assignment', assignmentId);
      final basePayload = _assignmentRowPayload(existing);
      final deletedPayload = <String, Object?>{
        ...basePayload,
        'deletedAt': now,
        'updatedAt': now,
        'version': nextVersion,
      };
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: assignmentId,
        operation: SyncOperation.delete,
        payload: deletedPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'assignment',
        entityId: assignmentId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: deletedPayload,
        notificationAnchor: existing.dueAt,
        updatedAt: now,
        deleted: true,
      );
    });
  }

  @override
  Future<List<domain.ScheduleEvent>> eventsForUser(String ownerUserId) {
    return _eventsForUser(ownerUserId);
  }

  @override
  Future<List<domain.EventException>> eventExceptionsForEvent({
    required String eventId,
    required String ownerUserId,
  }) async {
    await ensureDemoDataSeeded();
    await _requireOwnedActiveEvent(eventId: eventId, ownerUserId: ownerUserId);
    final rows = await db.eventDao.exceptionsForEvents([eventId]);
    return rows.map(_eventExceptionFromRow).toList();
  }

  @override
  Future<String> createEvent({
    required String ownerUserId,
    required EventInput input,
  }) async {
    await ensureDemoDataSeeded();
    final resolvedInput = _normalizeEventInput(_resolveEventInput(input))
        .withIsAllDay(input.isAllDay ?? false);
    _validateEventInput(resolvedInput);
    final eventId = _createId();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCalendar(resolvedInput.calendarId!, ownerUserId);
      await db.into(db.events).insert(
            local.EventsCompanion.insert(
              id: eventId,
              ownerUserId: ownerUserId,
              calendarId: resolvedInput.calendarId!,
              title: resolvedInput.title,
              kind: resolvedInput.kind.name,
              startAt: resolvedInput.startAt,
              endAt: resolvedInput.endAt,
              isAllDay: Value(resolvedInput.isAllDay!),
              location: Value(resolvedInput.location),
              description: Value(resolvedInput.description),
              rrule: Value(_encodeRecurrenceRule(resolvedInput.recurrenceRule)),
              visibilityLevel: Value(resolvedInput.visibilityLevel?.wireName),
              updatedAt: Value(now),
            ),
          );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: eventId,
        operation: SyncOperation.create,
        payload: _eventPayload(
          id: eventId,
          ownerUserId: ownerUserId,
          input: resolvedInput,
          kind: resolvedInput.kind,
          updatedAt: now,
        ),
        createdAt: now,
      );
    });
    return eventId;
  }

  @override
  Future<void> updateEvent({
    required String eventId,
    required String ownerUserId,
    required int expectedVersion,
    required EventInput input,
  }) async {
    await ensureDemoDataSeeded();
    final resolvedInput = _normalizeEventInput(_resolveEventInput(input));
    _validateEventInput(resolvedInput);
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedCalendar(resolvedInput.calendarId!, ownerUserId);
      final existing = await (db.select(db.events)
            ..where(
              (row) =>
                  row.id.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(eventId, 'eventId', 'Event not found');
      }
      _requireExpectedVersion(
        entityType: 'Event',
        entityId: eventId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      if (existing.kind != resolvedInput.kind.name) {
        throw const ValidationError(
          'An event cannot change between personal and routine types.',
        );
      }
      final persistedInput = resolvedInput.withIsAllDay(
        resolvedInput.isAllDay ?? existing.isAllDay,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.events)
            ..where(
              (row) =>
                  row.id.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.EventsCompanion(
          calendarId: Value(persistedInput.calendarId!),
          title: Value(persistedInput.title),
          startAt: Value(persistedInput.startAt),
          endAt: Value(persistedInput.endAt),
          isAllDay: Value(persistedInput.isAllDay!),
          location: Value(persistedInput.location),
          description: Value(persistedInput.description),
          rrule: Value(_encodeRecurrenceRule(persistedInput.recurrenceRule)),
          visibilityLevel: Value(persistedInput.visibilityLevel?.wireName),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Event', eventId);
      final basePayload = _eventRowPayload(existing);
      final nextPayload = _eventPayload(
        id: eventId,
        ownerUserId: ownerUserId,
        input: persistedInput,
        kind: persistedInput.kind,
        updatedAt: now,
        version: nextVersion,
      );
      final nextReceiptPayload = {...nextPayload, 'groupId': existing.groupId};
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: eventId,
        operation: SyncOperation.update,
        payload: nextReceiptPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: eventId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: nextReceiptPayload,
        notificationAnchor: persistedInput.startAt,
        updatedAt: now,
      );
    });
  }

  @override
  Future<void> deleteEvent({
    required String eventId,
    required String ownerUserId,
    required int expectedVersion,
  }) async {
    await ensureDemoDataSeeded();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final existing = await (db.select(db.events)
            ..where(
              (row) =>
                  row.id.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(eventId, 'eventId', 'Event not found');
      }
      _requireExpectedVersion(
        entityType: 'Event',
        entityId: eventId,
        expectedVersion: expectedVersion,
        actualVersion: existing.version,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.events)
            ..where(
              (row) =>
                  row.id.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(expectedVersion),
            ))
          .write(
        local.EventsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Event', eventId);
      final basePayload = _eventRowPayload(existing);
      final deletedPayload = <String, Object?>{
        ...basePayload,
        'deletedAt': now,
        'updatedAt': now,
        'version': nextVersion,
      };
      final mutationId = await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: eventId,
        operation: SyncOperation.delete,
        payload: deletedPayload,
        createdAt: now,
        baseVersion: existing.version,
      );
      await _recordEmailScheduleEdit(
        ownerUserId: ownerUserId,
        entityType: 'event',
        entityId: eventId,
        mutationId: mutationId,
        baseVersion: existing.version,
        entityVersion: nextVersion,
        basePayload: basePayload,
        payload: deletedPayload,
        notificationAnchor: existing.startAt,
        updatedAt: now,
        deleted: true,
      );
    });
  }

  @override
  Future<String> createEventException({
    required String eventId,
    required String ownerUserId,
    required EventExceptionInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeEventExceptionInput(input);
    final exceptionId = _createId();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final event = await _requireOwnedActiveEvent(
        eventId: eventId,
        ownerUserId: ownerUserId,
      );
      _validateEventExceptionInput(normalizedInput, _eventFromRow(event));
      await _ensureExceptionRecurrenceIsAvailable(
        eventId: eventId,
        recurrenceId: normalizedInput.recurrenceId,
      );
      await db.into(db.eventExceptions).insert(
            local.EventExceptionsCompanion.insert(
              id: exceptionId,
              ownerUserId: ownerUserId,
              eventId: eventId,
              recurrenceId: normalizedInput.recurrenceId,
              mode: normalizedInput.mode.name,
              overrideStartAt: Value(normalizedInput.overrideStartAt),
              overrideEndAt: Value(normalizedInput.overrideEndAt),
              overridePayloadJson: Value(
                _encodeEventExceptionPayload(normalizedInput),
              ),
              updatedAt: Value(now),
              version: const Value(1),
            ),
          );
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event_exception',
        entityId: exceptionId,
        operation: SyncOperation.create,
        payload: _eventExceptionPayload(
          id: exceptionId,
          ownerUserId: ownerUserId,
          eventId: eventId,
          input: normalizedInput,
          updatedAt: now,
          version: 1,
        ),
        createdAt: now,
      );
    });
    return exceptionId;
  }

  @override
  Future<void> updateEventException({
    required String exceptionId,
    required String eventId,
    required String ownerUserId,
    required EventExceptionInput input,
  }) async {
    await ensureDemoDataSeeded();
    final normalizedInput = _normalizeEventExceptionInput(input);
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      final event = await _requireOwnedActiveEvent(
        eventId: eventId,
        ownerUserId: ownerUserId,
      );
      _validateEventExceptionInput(normalizedInput, _eventFromRow(event));
      final existing = await (db.select(db.eventExceptions)
            ..where(
              (row) =>
                  row.id.equals(exceptionId) &
                  row.eventId.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(
          exceptionId,
          'exceptionId',
          'Event exception not found',
        );
      }
      await _ensureExceptionRecurrenceIsAvailable(
        eventId: eventId,
        recurrenceId: normalizedInput.recurrenceId,
        excludingExceptionId: exceptionId,
      );
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.eventExceptions)
            ..where(
              (row) =>
                  row.id.equals(exceptionId) &
                  row.eventId.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(existing.version),
            ))
          .write(
        local.EventExceptionsCompanion(
          recurrenceId: Value(normalizedInput.recurrenceId),
          mode: Value(normalizedInput.mode.name),
          overrideStartAt: Value(normalizedInput.overrideStartAt),
          overrideEndAt: Value(normalizedInput.overrideEndAt),
          overridePayloadJson: Value(
            _encodeEventExceptionPayload(normalizedInput),
          ),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Event exception', exceptionId);
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event_exception',
        entityId: exceptionId,
        operation: SyncOperation.update,
        payload: _eventExceptionPayload(
          id: exceptionId,
          ownerUserId: ownerUserId,
          eventId: eventId,
          input: normalizedInput,
          updatedAt: now,
          version: nextVersion,
        ),
        createdAt: now,
        baseVersion: existing.version,
      );
    });
  }

  @override
  Future<void> deleteEventException({
    required String exceptionId,
    required String eventId,
    required String ownerUserId,
  }) async {
    await ensureDemoDataSeeded();
    final now = emailScheduleSqliteTimestamp(_clock());
    await db.transaction(() async {
      await _requireOwnedActiveEvent(
          eventId: eventId, ownerUserId: ownerUserId);
      final existing = await (db.select(db.eventExceptions)
            ..where(
              (row) =>
                  row.id.equals(exceptionId) &
                  row.eventId.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull(),
            ))
          .getSingleOrNull();
      if (existing == null) {
        throw ArgumentError.value(
          exceptionId,
          'exceptionId',
          'Event exception not found',
        );
      }
      final nextVersion = existing.version + 1;
      final changed = await (db.update(db.eventExceptions)
            ..where(
              (row) =>
                  row.id.equals(exceptionId) &
                  row.eventId.equals(eventId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.deletedAt.isNull() &
                  row.version.equals(existing.version),
            ))
          .write(
        local.EventExceptionsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          version: Value(nextVersion),
        ),
      );
      _requireSingleOptimisticWrite(changed, 'Event exception', exceptionId);
      await _enqueueMutation(
        ownerUserId: ownerUserId,
        entityType: 'event_exception',
        entityId: exceptionId,
        operation: SyncOperation.delete,
        payload: _deletePayload(
          id: exceptionId,
          ownerUserId: ownerUserId,
          deletedAt: now,
          version: nextVersion,
        ),
        createdAt: now,
        baseVersion: existing.version,
      );
    });
  }

  @override
  Future<List<domain.CalendarProjectionItem>> calendarProjection({
    required String ownerUserId,
    required String universityId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    await _initializeLocalData();
    final events = await _eventsForUser(ownerUserId);
    return _calendarProjectionService.project(
      rangeStart: rangeStart.toUtc(),
      rangeEnd: rangeEnd.toUtc(),
      courses: await coursesForTerm(ownerUserId: ownerUserId, termId: termId),
      periodSettings: await _periodSettingsForContext(
        ownerUserId: ownerUserId,
        universityId: universityId,
        termId: termId,
      ),
      assignments: await assignmentsForUser(ownerUserId),
      assignmentStates: await assignmentStatesForUser(ownerUserId),
      exams: await _examsForUser(ownerUserId),
      events: events,
      eventExceptions: await _eventExceptionsFor(events),
    );
  }

  @override
  Future<domain.WidgetSnapshot> saveWidgetSnapshot({
    required String ownerUserId,
    required String universityId,
    required String termId,
    required domain.WidgetSnapshotSettings settings,
    required DateTime generatedAt,
  }) async {
    final normalizedGeneratedAt = generatedAt.toUtc();
    final snapshot = _widgetSnapshotGenerator.generate(
      courses: await coursesForTerm(
        ownerUserId: ownerUserId,
        termId: termId,
      ),
      generatedAt: normalizedGeneratedAt,
      periodSettings: await _periodSettingsForContext(
        ownerUserId: ownerUserId,
        universityId: universityId,
        termId: termId,
      ),
      settings: settings,
    );
    await db.widgetSnapshotDao.saveSnapshot(
      local.WidgetSnapshotsCompanion.insert(
        id: 'weekly-$ownerUserId',
        ownerUserId: ownerUserId,
        payloadJson: jsonEncode(snapshot.toJson()),
        generatedAt: normalizedGeneratedAt,
      ),
    );
    return snapshot;
  }

  @override
  Future<List<PendingMutation>> pendingMutations({
    required String ownerUserId,
  }) {
    return DriftSyncQueue(db, ownerUserId: ownerUserId).pending();
  }

  @override
  Future<SyncQueueCounts> syncQueueCounts({required String ownerUserId}) {
    return DriftSyncQueue(db, ownerUserId: ownerUserId).counts();
  }

  Future<String> _enqueueMutation({
    required String ownerUserId,
    required String entityType,
    required String entityId,
    required SyncOperation operation,
    required Map<String, Object?> payload,
    required DateTime createdAt,
    int? baseVersion,
  }) async {
    final mutationId = _createId();
    await DriftSyncQueue(db, ownerUserId: ownerUserId).enqueue(
      PendingMutation(
        clientMutationId: mutationId,
        ownerUserId: ownerUserId,
        idempotencyKey: mutationId,
        entityType: entityType,
        entityId: entityId,
        operation: operation,
        payload: payload,
        baseVersion: baseVersion,
        createdAt: createdAt.toUtc(),
      ),
    );
    return mutationId;
  }

  Future<void> _recordEmailScheduleEdit({
    required String ownerUserId,
    required String entityType,
    required String entityId,
    required String mutationId,
    required int baseVersion,
    required int entityVersion,
    required Map<String, Object?> basePayload,
    required Map<String, Object?> payload,
    required DateTime notificationAnchor,
    required DateTime updatedAt,
    bool deleted = false,
  }) async {
    final links = await (db.select(db.emailScheduleEntityLinks)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.entityType.equals(entityType) &
              row.entityId.equals(entityId)))
        .get();
    if (links.isEmpty) return;
    if (links.length != 1) {
      throw StateError('Email schedule edit provenance is ambiguous.');
    }
    final link = links.single;
    final candidate = await db.emailImportDao.candidateById(
      ownerUserId: ownerUserId,
      candidateId: link.candidateId,
    );
    if (candidate == null ||
        candidate.reviewState != 'confirmed' ||
        candidate.linkedEntityType != entityType ||
        candidate.linkedEntityId != entityId ||
        candidate.confirmationIdempotencyKey !=
            link.confirmationIdempotencyKey) {
      throw StateError('Email schedule edit candidate is unavailable.');
    }
    final candidatePayload = const domain.EmailCandidatePayloadCodec().decode(
      candidate.normalizedPayloadJson,
    );
    final receiptEntityType = domain.EmailCandidateType.fromWire(entityType);
    final canonicalBasePayload = emailScheduleReplayPayload(
      entityType: receiptEntityType,
      payload: basePayload,
    );
    final canonicalPayload = emailScheduleReplayPayload(
      entityType: receiptEntityType,
      payload: payload,
    );
    await db.into(db.emailScheduleEditReceipts).insert(
          local.EmailScheduleEditReceiptsCompanion.insert(
            mutationId: mutationId,
            ownerUserId: ownerUserId,
            candidateId: candidate.id,
            linkId: link.id,
            entityType: entityType,
            entityId: entityId,
            provenance: 'user_edit',
            baseEntityVersion: baseVersion,
            entityVersion: entityVersion,
            basePayloadFingerprint:
                emailSchedulePayloadFingerprint(canonicalBasePayload),
            payloadFingerprint:
                emailSchedulePayloadFingerprint(canonicalPayload),
            candidatePayloadFingerprint:
                emailCandidatePayloadFingerprint(candidatePayload),
            entityUpdatedAt: emailScheduleSqliteTimestamp(updatedAt),
            createdAt: emailScheduleSqliteTimestamp(updatedAt),
          ),
        );

    final requests = await (db.select(db.notificationScheduleRequests)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.sourceType.equals('email_confirmation') &
              row.sourceId.equals(candidate.id) &
              row.entityType.equals(entityType) &
              row.entityId.equals(entityId) &
              row.idempotencyKey.equals(link.confirmationIdempotencyKey)))
        .get();
    if (requests.length != 1) {
      throw StateError('Email schedule edit notification is unavailable.');
    }
    final changed = await (db.update(db.notificationScheduleRequests)
          ..where((row) =>
              row.id.equals(requests.single.id) &
              row.ownerUserId.equals(ownerUserId)))
        .write(
      local.NotificationScheduleRequestsCompanion(
        anchorAt: Value(notificationAnchor.toUtc()),
        state: Value(deleted ? 'cancelled' : 'pending'),
        updatedAt: Value(updatedAt.toUtc()),
      ),
    );
    if (changed != 1) {
      throw StateError('Email schedule edit notification changed.');
    }
  }

  Future<List<domain.PeriodSetting>> _periodSettingsForContext({
    required String ownerUserId,
    required String universityId,
    required String termId,
  }) async {
    final rows = await db.timetableDao.periodSettingsForContext(
      ownerUserId: ownerUserId,
      universityId: universityId,
      termId: termId,
    );
    return rows.map(_periodSettingFromRow).toList();
  }

  Future<domain.WidgetSnapshotSettings> _widgetSnapshotSettingsForUser(
    String ownerUserId,
  ) async {
    final row = await db.widgetSnapshotDao.latestForUser(ownerUserId);
    if (row == null) return const domain.WidgetSnapshotSettings();
    try {
      final decoded = jsonDecode(row.payloadJson);
      if (decoded is! Map) {
        throw const FormatException('Widget snapshot must be an object.');
      }
      final snapshot = domain.WidgetSnapshot.fromJson(
        Map<String, Object?>.from(decoded),
      );
      return domain.WidgetSnapshotSettings(
        privacyMode: snapshot.privacyMode,
      );
    } on FormatException {
      // Old or malformed local payloads must not expose course details.
      return const domain.WidgetSnapshotSettings(
        privacyMode: domain.WidgetPrivacyMode.busyOnly,
      );
    }
  }

  void _validateContext({
    required String ownerUserId,
    required String universityId,
    required String termId,
    required int academicYear,
  }) {
    if (ownerUserId.trim().isEmpty ||
        universityId.trim().isEmpty ||
        termId.trim().isEmpty ||
        academicYear < 1900 ||
        academicYear > 2200) {
      throw StateError('The schedule query context is incomplete.');
    }
  }

  Future<List<domain.Exam>> _examsForUser(String ownerUserId) async {
    final rows = await db.examDao.examsForUser(ownerUserId);
    return rows.map(_examFromRow).toList();
  }

  Future<List<domain.ScheduleEvent>> _eventsForUser(String ownerUserId) async {
    final rows = await db.eventDao.eventsForUser(ownerUserId);
    return rows.map(_eventFromRow).toList();
  }

  Future<List<domain.EventException>> _eventExceptionsFor(
    Iterable<domain.ScheduleEvent> events,
  ) async {
    final rows =
        await db.eventDao.exceptionsForEvents(events.map((event) => event.id));
    return rows.map(_eventExceptionFromRow).toList();
  }

  DateTime _calendarRangeStart(DateTime now) {
    final civil = domain.JapanTime.civil(now);
    final monthStart = domain.JapanTime.at(
      year: civil.year,
      month: civil.month,
      day: 1,
    );
    return domain.JapanTime.startOfWeek(monthStart);
  }

  DateTime _calendarRangeEnd(DateTime now) {
    return domain.JapanTime.startOfDay(now).add(_calendarAgendaHorizon);
  }

  domain.CourseTemplate _templateFromRow(
    local.CourseTemplatesCacheData row,
  ) {
    return domain.CourseTemplate(
      id: row.id,
      universityId: row.universityId,
      academicYear: row.academicYear,
      termId: row.termId,
      title: row.title,
      normalizedTitle: row.normalizedTitle,
      instructorName: row.instructorName,
      normalizedInstructorName: row.normalizedInstructorName,
      dayOfWeek: row.dayOfWeek,
      periodNo: row.periodNo,
      room: row.room,
      normalizedRoom: row.normalizedRoom,
      copyCountTotal: row.copyCountTotal,
      copyCountTerm: row.copyCountTerm,
      trustScore: row.trustScore,
    );
  }

  domain.UserCourse _courseFromRow(local.UserCourse row) {
    return domain.UserCourse(
      id: row.id,
      ownerUserId: row.ownerUserId,
      termId: row.termId,
      sourceTemplateId: row.sourceTemplateId,
      title: row.title,
      normalizedTitle: row.normalizedTitle,
      instructorName: row.instructorName,
      normalizedInstructorName: row.normalizedInstructorName,
      dayOfWeek: row.dayOfWeek,
      periodNo: row.periodNo,
      room: row.room,
      color: row.color,
      visibilityLevel: domain.VisibilityLevel.fromWire(row.visibilityLevel),
      version: row.version,
    );
  }

  domain.PeriodSetting _periodSettingFromRow(local.PeriodSetting row) {
    return domain.PeriodSetting(
      id: row.id,
      ownerUserId: row.ownerUserId,
      dayOfWeek: row.dayOfWeek,
      periodNo: row.periodNo,
      startTimeMinutes: row.startTimeMinutes,
      endTimeMinutes: row.endTimeMinutes,
    );
  }

  domain.Assignment _assignmentFromRow(local.Assignment row) {
    return domain.Assignment(
      id: row.id,
      ownerUserId: row.ownerUserId,
      title: row.title,
      dueAt: row.dueAt.toUtc(),
      courseId: row.courseId,
      description: row.description,
      submissionUrl: row.submissionUrl,
      priority: row.priority,
      visibilityLevel: domain.VisibilityLevel.fromWire(row.visibilityLevel),
      version: row.version,
    );
  }

  domain.AssignmentUserState _assignmentStateFromRow(
    local.AssignmentUserState row,
  ) {
    return domain.AssignmentUserState(
      assignmentId: row.assignmentId,
      userId: row.userId,
      status: _assignmentStatusFromWire(row.status),
      submittedAt: row.submittedAt?.toUtc(),
      note: row.note,
      version: row.version,
    );
  }

  domain.Exam _examFromRow(local.Exam row) {
    return domain.Exam(
      id: row.id,
      ownerUserId: row.ownerUserId,
      title: row.title,
      startAt: row.startAt.toUtc(),
      endAt: row.endAt.toUtc(),
      courseId: row.courseId,
      room: row.room,
      scope: row.scope,
      memo: row.memo,
      examType: row.examType,
      visibilityLevel: domain.VisibilityLevel.fromWire(row.visibilityLevel),
      version: row.version,
    );
  }

  domain.ScheduleEvent _eventFromRow(local.Event row) {
    return domain.ScheduleEvent(
      id: row.id,
      ownerUserId: row.ownerUserId,
      calendarId: row.calendarId,
      title: row.title,
      kind: _eventKindFromWire(row.kind),
      startAt: row.startAt.toUtc(),
      endAt: row.endAt.toUtc(),
      isAllDay: row.isAllDay,
      groupId: row.groupId,
      location: row.location,
      description: row.description,
      recurrenceRule: _decodeRecurrenceRule(
        row.rrule,
        timezone: row.timezone,
      ),
      timezone: row.timezone,
      visibilityLevel: row.visibilityLevel == null
          ? null
          : domain.VisibilityLevel.fromWire(row.visibilityLevel!),
      version: row.version,
    );
  }

  domain.EventException _eventExceptionFromRow(local.EventException row) {
    final payload = _decodeJsonObject(row.overridePayloadJson);
    return domain.EventException(
      id: row.id,
      eventId: row.eventId,
      recurrenceId: row.recurrenceId.toUtc(),
      mode: _eventExceptionModeFromWire(row.mode),
      overrideStartAt: row.overrideStartAt?.toUtc(),
      overrideEndAt: row.overrideEndAt?.toUtc(),
      overrideTitle: payload['title'] as String?,
      overrideLocation: payload['location'] as String?,
      overrideDescription: payload['description'] as String?,
      overrideVisibility: payload['visibilityLevel'] is String
          ? domain.VisibilityLevel.fromWire(
              payload['visibilityLevel'] as String)
          : null,
    );
  }

  domain.AssignmentStatus _assignmentStatusFromWire(String value) {
    return domain.AssignmentStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => domain.AssignmentStatus.notStarted,
    );
  }

  domain.EventKind _eventKindFromWire(String value) {
    return domain.EventKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => domain.EventKind.normal,
    );
  }

  domain.EventExceptionMode _eventExceptionModeFromWire(String value) {
    return domain.EventExceptionMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => domain.EventExceptionMode.modified,
    );
  }

  domain.RecurrenceRule? _decodeRecurrenceRule(
    String? raw, {
    required String timezone,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final parts = <String, String>{};
    for (final segment in raw.split(';')) {
      final equalsIndex = segment.indexOf('=');
      if (equalsIndex <= 0) continue;
      parts[segment.substring(0, equalsIndex).toUpperCase()] =
          segment.substring(equalsIndex + 1);
    }
    final frequency = domain.RecurrenceFrequency.values.firstWhere(
      (item) => item.name.toUpperCase() == parts['FREQ'],
      orElse: () => domain.RecurrenceFrequency.none,
    );
    return domain.RecurrenceRule(
      frequency: frequency,
      interval: int.tryParse(parts['INTERVAL'] ?? '') ?? 1,
      byWeekdays: parts['BYDAY']
              ?.split(',')
              .map(int.tryParse)
              .whereType<int>()
              .toList() ??
          const [],
      count: int.tryParse(parts['COUNT'] ?? ''),
      until: _decodeRecurrenceUntil(parts['UNTIL'], timezone: timezone),
      monthDay: int.tryParse(parts['MONTHDAY'] ?? ''),
      nth: int.tryParse(parts['NTH'] ?? ''),
      weekday: int.tryParse(parts['WEEKDAY'] ?? ''),
    );
  }

  DateTime? _decodeRecurrenceUntil(
    String? raw, {
    required String timezone,
  }) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    final hasExplicitOffset = RegExp(
      r'[t ][^ ]*(z|[+-][0-9]{2}:?[0-9]{2})$',
      caseSensitive: false,
    ).hasMatch(raw);
    if (hasExplicitOffset) return parsed.toUtc();
    if (domain.JapanTime.isSupportedTimeZone(timezone)) {
      return domain.JapanTime.fromCivil(parsed);
    }
    return null;
  }

  Map<String, Object?> _decodeJsonObject(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  Map<String, Object?> _coursePayload({
    required String id,
    required String ownerUserId,
    required String termId,
    required UserCourseInput input,
    required String normalizedTitle,
    String? normalizedInstructorName,
    required DateTime updatedAt,
    String? sourceTemplateId,
    int version = 1,
  }) {
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'termId': termId,
      'sourceTemplateId': sourceTemplateId,
      'title': input.title,
      'normalizedTitle': normalizedTitle,
      'instructorName': input.instructorName,
      'normalizedInstructorName': normalizedInstructorName,
      'dayOfWeek': input.dayOfWeek,
      'periodNo': input.periodNo,
      'room': input.room,
      'color': input.color,
      'visibilityLevel': input.visibilityLevel.wireName,
      'updatedAt': updatedAt,
      'version': version,
    };
  }

  Map<String, Object?> _assignmentPayload({
    required String id,
    required String ownerUserId,
    required AssignmentInput input,
    required DateTime updatedAt,
    int version = 1,
  }) {
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'courseId': input.courseId,
      'title': input.title,
      'dueAt': input.dueAt.toUtc(),
      'submissionUrl': input.submissionUrl,
      'memo': input.memo,
      'priority': input.priority,
      'visibilityLevel': input.visibilityLevel.wireName,
      'updatedAt': updatedAt.toUtc(),
      'version': version,
    };
  }

  Map<String, Object?> _assignmentRowPayload(local.Assignment row) {
    return {
      'id': row.id,
      'ownerUserId': row.ownerUserId,
      'courseId': row.courseId,
      'title': row.title,
      'dueAt': row.dueAt.toUtc(),
      'submissionUrl': row.submissionUrl,
      'memo': row.description,
      'priority': row.priority,
      'visibilityLevel': row.visibilityLevel,
      'updatedAt': row.updatedAt.toUtc(),
      'version': row.version,
      'deletedAt': row.deletedAt?.toUtc(),
    };
  }

  Map<String, Object?> _examPayload({
    required String id,
    required String ownerUserId,
    required ExamInput input,
    required DateTime updatedAt,
    int version = 1,
  }) {
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'courseId': input.courseId,
      'title': input.title,
      'startAt': input.startAt.toUtc(),
      'endAt': input.endAt.toUtc(),
      'room': input.room,
      'memo': input.memo,
      'examType': input.examType,
      'visibilityLevel': input.visibilityLevel.wireName,
      'updatedAt': updatedAt.toUtc(),
      'version': version,
    };
  }

  Map<String, Object?> _examRowPayload(local.Exam row) {
    return {
      'id': row.id,
      'ownerUserId': row.ownerUserId,
      'courseId': row.courseId,
      'title': row.title,
      'startAt': row.startAt.toUtc(),
      'endAt': row.endAt.toUtc(),
      'room': row.room,
      'scope': row.scope,
      'memo': row.memo,
      'examType': row.examType,
      'visibilityLevel': row.visibilityLevel,
      'updatedAt': row.updatedAt.toUtc(),
      'version': row.version,
      'deletedAt': row.deletedAt?.toUtc(),
    };
  }

  Map<String, Object?> _eventPayload({
    required String id,
    required String ownerUserId,
    required EventInput input,
    required domain.EventKind kind,
    required DateTime updatedAt,
    int version = 1,
  }) {
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'calendarId': input.calendarId!,
      'title': input.title,
      'kind': kind.name,
      'startAt': input.startAt.toUtc(),
      'endAt': input.endAt.toUtc(),
      'isAllDay': input.isAllDay ?? false,
      'location': input.location,
      'description': input.description,
      'rrule': _encodeRecurrenceRule(input.recurrenceRule),
      'timezone': domain.japanTimeZone,
      'visibilityLevel': input.visibilityLevel?.wireName,
      'updatedAt': updatedAt.toUtc(),
      'version': version,
    };
  }

  Map<String, Object?> _eventRowPayload(local.Event row) {
    return {
      'id': row.id,
      'ownerUserId': row.ownerUserId,
      'calendarId': row.calendarId,
      'groupId': row.groupId,
      'title': row.title,
      'kind': row.kind,
      'startAt': row.startAt.toUtc(),
      'endAt': row.endAt.toUtc(),
      'isAllDay': row.isAllDay,
      'location': row.location,
      'description': row.description,
      'rrule': row.rrule,
      'timezone': row.timezone,
      'visibilityLevel': row.visibilityLevel,
      'updatedAt': row.updatedAt.toUtc(),
      'version': row.version,
      'deletedAt': row.deletedAt?.toUtc(),
    };
  }

  Map<String, Object?> _eventExceptionPayload({
    required String id,
    required String ownerUserId,
    required String eventId,
    required EventExceptionInput input,
    required DateTime updatedAt,
    required int version,
  }) {
    final isModified = input.mode == domain.EventExceptionMode.modified;
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'eventId': eventId,
      'recurrenceId': input.recurrenceId.toUtc(),
      'mode': input.mode.name,
      'overrideStartAt': isModified ? input.overrideStartAt?.toUtc() : null,
      'overrideEndAt': isModified ? input.overrideEndAt?.toUtc() : null,
      'overrideTitle': isModified ? input.overrideTitle : null,
      'overrideLocation': isModified ? input.overrideLocation : null,
      'overrideDescription': isModified ? input.overrideDescription : null,
      'overrideVisibility':
          isModified ? input.overrideVisibility?.wireName : null,
      'updatedAt': updatedAt.toUtc(),
      'deletedAt': null,
      'version': version,
    };
  }

  Map<String, Object?> _deletePayload({
    required String id,
    required String ownerUserId,
    required DateTime deletedAt,
    required int version,
  }) {
    return {
      'id': id,
      'ownerUserId': ownerUserId,
      'deletedAt': deletedAt.toUtc(),
      'updatedAt': deletedAt.toUtc(),
      'version': version,
    };
  }

  String? _encodeRecurrenceRule(domain.RecurrenceRule? rule) {
    if (rule == null || rule.frequency == domain.RecurrenceFrequency.none) {
      return null;
    }
    final parts = <String>[
      'FREQ=${rule.frequency.name.toUpperCase()}',
      if (rule.interval != 1) 'INTERVAL=${rule.interval}',
      if (rule.byWeekdays.isNotEmpty) 'BYDAY=${rule.byWeekdays.join(',')}',
      if (rule.count != null) 'COUNT=${rule.count}',
      if (rule.until != null) 'UNTIL=${rule.until!.toUtc().toIso8601String()}',
      if (rule.monthDay != null) 'MONTHDAY=${rule.monthDay}',
      if (rule.nth != null) 'NTH=${rule.nth}',
      if (rule.weekday != null) 'WEEKDAY=${rule.weekday}',
    ];
    return parts.join(';');
  }

  String _encodeEventExceptionPayload(EventExceptionInput input) {
    return jsonEncode({
      'title': input.overrideTitle,
      'location': input.overrideLocation,
      'description': input.overrideDescription,
      'visibilityLevel': input.overrideVisibility?.wireName,
    });
  }

  EventInput _resolveEventInput(EventInput input) {
    final calendarId = input.calendarId?.trim();
    if (calendarId != null && calendarId.isNotEmpty) {
      return input.withCalendarId(calendarId);
    }
    if (enableDemoData) {
      return input.withCalendarId(demoPersonalCalendarId);
    }
    throw const ValidationError('A personal calendar is required.');
  }

  AssignmentInput _normalizeAssignmentInput(AssignmentInput input) {
    return AssignmentInput(
      title: input.title.trim(),
      dueAt: input.dueAt.toUtc(),
      courseId: input.courseId,
      submissionUrl: _serverNullifiedText(input.submissionUrl),
      memo: _serverNullifiedText(input.memo),
      priority: _serverNullifiedText(input.priority),
      visibilityLevel: input.visibilityLevel,
    );
  }

  ExamInput _normalizeExamInput(ExamInput input) {
    return ExamInput(
      title: input.title.trim(),
      startAt: input.startAt.toUtc(),
      endAt: input.endAt.toUtc(),
      courseId: input.courseId,
      room: _serverNullifiedText(input.room),
      memo: _serverNullifiedText(input.memo),
      examType: _serverNullifiedText(input.examType),
      visibilityLevel: input.visibilityLevel,
    );
  }

  EventInput _normalizeEventInput(EventInput input) {
    final rule = input.recurrenceRule;
    return EventInput(
      title: input.title.trim(),
      startAt: input.startAt.toUtc(),
      endAt: input.endAt.toUtc(),
      calendarId: input.calendarId,
      location: _serverNullifiedText(input.location),
      description: _serverNullifiedText(input.description),
      isAllDay: input.isAllDay,
      visibilityLevel: input.visibilityLevel,
      kind: input.kind,
      recurrenceRule: rule == null
          ? null
          : domain.RecurrenceRule(
              frequency: rule.frequency,
              interval: rule.interval,
              byWeekdays: rule.byWeekdays,
              count: rule.count,
              until: rule.until?.toUtc(),
              monthDay: rule.monthDay,
              nth: rule.nth,
              weekday: rule.weekday,
            ),
    );
  }

  String? _serverNullifiedText(String? value) {
    return value == null || value.isEmpty ? null : value;
  }

  void _requireScheduleTitle(String title, String entityName) {
    if (title.isEmpty) {
      throw ValidationError('$entityName title is required.');
    }
  }

  EventExceptionInput _normalizeEventExceptionInput(
    EventExceptionInput input,
  ) {
    return EventExceptionInput(
      recurrenceId: input.recurrenceId.toUtc(),
      mode: input.mode,
      overrideStartAt: input.overrideStartAt?.toUtc(),
      overrideEndAt: input.overrideEndAt?.toUtc(),
      overrideTitle: input.overrideTitle,
      overrideLocation: input.overrideLocation,
      overrideDescription: input.overrideDescription,
      overrideVisibility: input.overrideVisibility,
    );
  }

  void _validateEventInput(EventInput input) {
    if (input.title.trim().isEmpty) {
      throw const ValidationError('Event title is required.');
    }
    if (!input.endAt.isAfter(input.startAt)) {
      throw const ValidationError('Event must end after it starts.');
    }
    final rule = input.recurrenceRule;
    if (input.kind == domain.EventKind.normal) {
      if (rule != null && rule.frequency != domain.RecurrenceFrequency.none) {
        throw const ValidationError('Personal events cannot have recurrence.');
      }
      return;
    }
    if (input.kind != domain.EventKind.routine ||
        rule == null ||
        rule.frequency == domain.RecurrenceFrequency.none) {
      throw const ValidationError('Routines require a recurrence rule.');
    }
    if (rule.interval < 1) {
      throw const ValidationError('Recurrence interval must be positive.');
    }
    final hasEndDate = rule.until != null;
    final hasCount = rule.count != null;
    if (hasEndDate == hasCount) {
      throw const ValidationError(
        'A routine must end on a date or after a positive number of occurrences.',
      );
    }
    if (rule.count != null && rule.count! < 1) {
      throw const ValidationError('Routine occurrence count must be positive.');
    }
    if (rule.until != null && rule.until!.isBefore(input.startAt)) {
      throw const ValidationError(
          'Routine end date cannot be before its start.');
    }
    if (rule.byWeekdays.any(
      (weekday) => weekday < DateTime.monday || weekday > DateTime.sunday,
    )) {
      throw const ValidationError(
          'Routine weekdays must be Monday through Sunday.');
    }
    if (rule.monthDay != null && (rule.monthDay! < 1 || rule.monthDay! > 31)) {
      throw const ValidationError(
          'Routine month day must be between 1 and 31.');
    }
    if (rule.frequency == domain.RecurrenceFrequency.nthWeekday &&
        ((rule.nth ?? 0) < 1 ||
            (rule.nth ?? 0) > 5 ||
            (rule.weekday ?? 0) < DateTime.monday ||
            (rule.weekday ?? 0) > DateTime.sunday)) {
      throw const ValidationError(
        'Nth-weekday routines need a valid weekday and ordinal.',
      );
    }
  }

  void _validateEventExceptionInput(
    EventExceptionInput input,
    domain.ScheduleEvent event,
  ) {
    if (event.kind != domain.EventKind.routine ||
        event.recurrenceRule == null ||
        event.recurrenceRule!.frequency == domain.RecurrenceFrequency.none) {
      throw const ValidationError('Exceptions can only be added to routines.');
    }
    if (!_routineHasOccurrence(event, input.recurrenceId)) {
      throw const ValidationError(
          'The selected date is not a routine occurrence.');
    }
    final hasOverride = input.overrideStartAt != null ||
        input.overrideEndAt != null ||
        input.overrideTitle?.trim().isNotEmpty == true ||
        input.overrideLocation?.trim().isNotEmpty == true ||
        input.overrideDescription?.trim().isNotEmpty == true ||
        input.overrideVisibility != null;
    if (input.mode == domain.EventExceptionMode.cancelled) {
      if (hasOverride) {
        throw const ValidationError(
          'Cancelled routine occurrences cannot include edits.',
        );
      }
      return;
    }
    if (!hasOverride) {
      throw const ValidationError(
          'A changed occurrence needs at least one edit.');
    }
    final startAt = input.overrideStartAt ?? input.recurrenceId;
    final endAt = input.overrideEndAt ?? startAt.add(event.duration);
    if (!endAt.isAfter(startAt)) {
      throw const ValidationError(
        'Changed occurrence must end after it starts.',
      );
    }
  }

  bool _routineHasOccurrence(
    domain.ScheduleEvent event,
    DateTime recurrenceId,
  ) {
    final normalizedRecurrenceId = recurrenceId.toUtc();
    final occurrences = domain.RecurrenceExpander().expand(
      event: event,
      rangeStart: normalizedRecurrenceId,
      rangeEnd: normalizedRecurrenceId.add(const Duration(milliseconds: 1)),
    );
    return occurrences.any(
      (occurrence) => occurrence.recurrenceId.toUtc() == normalizedRecurrenceId,
    );
  }

  Future<void> _ensureExceptionRecurrenceIsAvailable({
    required String eventId,
    required DateTime recurrenceId,
    String? excludingExceptionId,
  }) async {
    final normalizedRecurrenceId = recurrenceId.toUtc();
    final existing = await (db.select(db.eventExceptions)
          ..where((row) =>
              row.eventId.equals(eventId) &
              row.recurrenceId.equals(normalizedRecurrenceId) &
              row.deletedAt.isNull()))
        .get();
    if (existing.any((row) => row.id != excludingExceptionId)) {
      throw const ValidationError(
        'This routine occurrence already has an exception.',
      );
    }
  }

  Future<local.Event> _requireOwnedActiveEvent({
    required String eventId,
    required String ownerUserId,
  }) async {
    final event = await (db.select(db.events)
          ..where(
            (row) =>
                row.id.equals(eventId) &
                row.ownerUserId.equals(ownerUserId) &
                row.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (event == null) {
      throw ArgumentError.value(eventId, 'eventId', 'Event not found');
    }
    return event;
  }

  Future<void> _requireOwnedCalendar(
    String calendarId,
    String ownerUserId,
  ) async {
    final calendar = await (db.select(db.calendars)
          ..where((row) =>
              row.id.equals(calendarId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
    if (calendar == null) {
      throw ArgumentError.value(
        calendarId,
        'calendarId',
        'Calendar is unavailable for this owner',
      );
    }
  }

  Future<void> _requireOwnedCourseIfPresent(
    String? courseId,
    String ownerUserId,
  ) async {
    if (courseId == null) return;
    final course = await (db.select(db.userCourses)
          ..where((row) =>
              row.id.equals(courseId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
    if (course == null) {
      throw ArgumentError.value(
        courseId,
        'courseId',
        'Course is unavailable for this owner',
      );
    }
  }

  void _requireExpectedVersion({
    required String entityType,
    required String entityId,
    required int expectedVersion,
    required int actualVersion,
  }) {
    if (expectedVersion == actualVersion) return;
    throw ConflictError(
      '$entityType $entityId changed locally '
      '(expected v$expectedVersion, found v$actualVersion).',
    );
  }

  void _requireSingleOptimisticWrite(
    int changed,
    String entityType,
    String entityId,
  ) {
    if (changed == 1) return;
    throw ConflictError('$entityType $entityId changed during this edit.');
  }
}
