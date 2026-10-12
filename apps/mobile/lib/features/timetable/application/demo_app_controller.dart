import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_coordinator.dart';
import '../../../core/sync/sync_worker.dart';
import '../../../core/time/app_clock.dart';
import '../../assignment/application/assignment_undo.dart';
import '../data/local_schedule_repository.dart';
import 'schedule_sync_runtime.dart';

class DemoAppState {
  const DemoAppState({
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

  final List<CourseTemplate> templates;
  final List<PeriodSetting> periodSettings;
  final List<UserCourse> courses;
  final List<UserCourse> assignmentCourses;
  final List<Assignment> assignments;
  final Map<String, AssignmentUserState> assignmentStates;
  final List<Exam> exams;
  final List<ScheduleEvent> events;
  final List<EventException> eventExceptions;
  final List<CalendarProjectionItem> calendarItems;
  final WidgetSnapshot widgetSnapshot;
  final List<PendingMutation> pendingMutations;
  final SyncQueueCounts syncQueueCounts;

  DemoAppState copyWith({
    List<CourseTemplate>? templates,
    List<PeriodSetting>? periodSettings,
    List<UserCourse>? courses,
    List<UserCourse>? assignmentCourses,
    List<Assignment>? assignments,
    Map<String, AssignmentUserState>? assignmentStates,
    List<Exam>? exams,
    List<ScheduleEvent>? events,
    List<EventException>? eventExceptions,
    List<CalendarProjectionItem>? calendarItems,
    WidgetSnapshot? widgetSnapshot,
    List<PendingMutation>? pendingMutations,
    SyncQueueCounts? syncQueueCounts,
  }) {
    return DemoAppState(
      templates: templates ?? this.templates,
      periodSettings: periodSettings ?? this.periodSettings,
      courses: courses ?? this.courses,
      assignmentCourses: assignmentCourses ?? this.assignmentCourses,
      assignments: assignments ?? this.assignments,
      assignmentStates: assignmentStates ?? this.assignmentStates,
      exams: exams ?? this.exams,
      events: events ?? this.events,
      eventExceptions: eventExceptions ?? this.eventExceptions,
      calendarItems: calendarItems ?? this.calendarItems,
      widgetSnapshot: widgetSnapshot ?? this.widgetSnapshot,
      pendingMutations: pendingMutations ?? this.pendingMutations,
      syncQueueCounts: syncQueueCounts ?? this.syncQueueCounts,
    );
  }

  factory DemoAppState.fromLocalSnapshot(LocalScheduleSnapshot snapshot) {
    return DemoAppState(
      templates: snapshot.templates,
      periodSettings: snapshot.periodSettings,
      courses: snapshot.courses,
      assignmentCourses: snapshot.assignmentCourses,
      assignments: snapshot.assignments,
      assignmentStates: snapshot.assignmentStates,
      exams: snapshot.exams,
      events: snapshot.events,
      eventExceptions: snapshot.eventExceptions,
      calendarItems: snapshot.calendarItems,
      widgetSnapshot: snapshot.widgetSnapshot,
      pendingMutations: snapshot.pendingMutations,
      syncQueueCounts: snapshot.syncQueueCounts,
    );
  }

  factory DemoAppState.empty({required DateTime now}) {
    return DemoAppState(
      templates: const [],
      periodSettings: const [],
      courses: const [],
      assignmentCourses: const [],
      assignments: const [],
      assignmentStates: const {},
      exams: const [],
      events: const [],
      eventExceptions: const [],
      calendarItems: const [],
      widgetSnapshot: WidgetSnapshot.empty(now),
      pendingMutations: const [],
      syncQueueCounts: const SyncQueueCounts(
        pending: 0,
        synced: 0,
        failed: 0,
      ),
    );
  }
}

final demoAppControllerProvider =
    StreamNotifierProvider<DemoAppController, DemoAppState>(
  DemoAppController.new,
);

/// Resolves an owned active course across all terms for edit forms.
///
/// The main timetable snapshot intentionally contains only the active term,
/// whereas assignments and exams can retain a historical link to a course in
/// another active term. A missing current-term row is therefore not enough to
/// classify a link as deleted.
final activeCourseByIdProvider =
    FutureProvider.autoDispose.family<UserCourse?, String>((ref, courseId) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  return ref.watch(scheduleRepositoryProvider).activeCourseById(
        ownerUserId: context.ownerUserId,
        courseId: courseId,
      );
});

class DemoAppController extends StreamNotifier<DemoAppState> {
  final _normalizer = CourseNormalizer();
  final Map<String, AssignmentUndoReceipt> _submissionUndoReceipts = {};

  @override
  Stream<DemoAppState> build() {
    final context = ref.watch(activeScheduleContextProvider);
    final now = ref.watch(appClockProvider).now();
    if (context == null) {
      return Stream.value(DemoAppState.empty(now: now));
    }
    context.validate();
    return ref
        .watch(scheduleRepositoryProvider)
        .watchSnapshot(
          now: now,
          ownerUserId: context.ownerUserId,
          universityId: context.universityId,
          termId: context.termId,
          academicYear: context.academicYear,
        )
        .map(DemoAppState.fromLocalSnapshot);
  }

  ActiveScheduleContext get _context =>
      ref.read(requiredActiveScheduleContextProvider);

  List<CourseTemplate> searchTemplates({
    String query = '',
    int? weekday,
    int? period,
  }) {
    final current = state.valueOrNull;
    if (current == null) return const [];
    final normalizedQuery = _normalizer.normalizeTitle(query);
    final templates = current.templates
        .where((template) => weekday == null || template.dayOfWeek == weekday)
        .where((template) => period == null || template.periodNo == period)
        .where((template) {
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

  Future<String> copyTemplate(CourseTemplate template) async {
    final context = _context;
    final repository = ref.read(scheduleRepositoryProvider);
    final id = await repository.copyTemplate(
      templateId: template.id,
      ownerUserId: context.ownerUserId,
      termId: context.termId,
    );
    return id;
  }

  Future<String> createUserCourse(UserCourseInput input) async {
    final context = _context;
    final id = await ref.read(scheduleRepositoryProvider).createUserCourse(
          ownerUserId: context.ownerUserId,
          termId: context.termId,
          input: input,
        );
    return id;
  }

  Future<void> updateUserCourse(
    String courseId,
    int expectedVersion,
    UserCourseInput input,
  ) async {
    final context = _context;
    await ref.read(scheduleRepositoryProvider).updateUserCourse(
          courseId: courseId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
          input: input,
        );
  }

  Future<void> deleteUserCourse(
    String courseId,
    int expectedVersion,
  ) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).deleteUserCourse(
          courseId: courseId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
        );
  }

  Future<String> createAssignment(AssignmentInput input) async {
    final context = _context;
    final id = await ref.read(scheduleRepositoryProvider).createAssignment(
          ownerUserId: context.ownerUserId,
          input: input,
        );
    return id;
  }

  Future<void> updateAssignment(
    String assignmentId,
    int expectedVersion,
    AssignmentInput input,
  ) async {
    final context = _context;
    await ref.read(scheduleRepositoryProvider).updateAssignment(
          assignmentId: assignmentId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
          input: input,
        );
  }

  Future<void> deleteAssignment(
    String assignmentId,
    int expectedVersion,
  ) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).deleteAssignment(
          assignmentId: assignmentId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
        );
  }

  Future<String> createExam(ExamInput input) async {
    final context = _context;
    final id = await ref.read(scheduleRepositoryProvider).createExam(
          ownerUserId: context.ownerUserId,
          input: input,
        );
    return id;
  }

  Future<void> updateExam(
    String examId,
    int expectedVersion,
    ExamInput input,
  ) async {
    final context = _context;
    await ref.read(scheduleRepositoryProvider).updateExam(
          examId: examId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
          input: input,
        );
  }

  Future<void> deleteExam(String examId, int expectedVersion) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).deleteExam(
          examId: examId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
        );
  }

  Future<String> createEvent(EventInput input) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).createEvent(
          ownerUserId: context.ownerUserId,
          input: input.withCalendarId(
            input.calendarId ?? context.primaryCalendarId,
          ),
        );
  }

  Future<void> updateEvent(
    String eventId,
    int expectedVersion,
    EventInput input,
  ) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).updateEvent(
          eventId: eventId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
          input: input.withCalendarId(
            input.calendarId ?? context.primaryCalendarId,
          ),
        );
  }

  Future<void> deleteEvent(String eventId, int expectedVersion) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).deleteEvent(
          eventId: eventId,
          ownerUserId: context.ownerUserId,
          expectedVersion: expectedVersion,
        );
  }

  Future<String> createEventException(
    String eventId,
    EventExceptionInput input,
  ) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).createEventException(
          eventId: eventId,
          ownerUserId: context.ownerUserId,
          input: input,
        );
  }

  Future<void> updateEventException(
    String exceptionId,
    String eventId,
    EventExceptionInput input,
  ) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).updateEventException(
          exceptionId: exceptionId,
          eventId: eventId,
          ownerUserId: context.ownerUserId,
          input: input,
        );
  }

  Future<void> deleteEventException(String exceptionId, String eventId) {
    final context = _context;
    return ref.read(scheduleRepositoryProvider).deleteEventException(
          exceptionId: exceptionId,
          eventId: eventId,
          ownerUserId: context.ownerUserId,
        );
  }

  Future<void> submitAssignment(String assignmentId) async {
    final context = _context;
    final receipt =
        await ref.read(scheduleRepositoryProvider).submitAssignmentWithReceipt(
              assignmentId: assignmentId,
              userId: context.ownerUserId,
              submittedAt: ref.read(appClockProvider).now(),
            );
    _submissionUndoReceipts[assignmentId] = receipt;
  }

  /// Submits an assignment and returns an undo operation that is independent
  /// of the originating screen's lifetime.
  ///
  /// Keeping the old [submitAssignment] signature preserves the existing
  /// controller API; this operation is available only when that path produced
  /// a repository-backed guarded receipt.
  Future<AssignmentUndoOperation> submitAssignmentWithUndo(
    String assignmentId,
  ) async {
    await submitAssignment(assignmentId);

    final receipt = _submissionUndoReceipts[assignmentId];
    if (receipt == null) {
      throw StateError('The guarded submission receipt is unavailable.');
    }
    return AssignmentUndoOperation(
      receipt: receipt,
      undo: undoAssignmentSubmission,
    );
  }

  Future<void> undoAssignmentSubmission(
    AssignmentUndoReceipt receipt,
  ) async {
    final context = _context;
    if (context.ownerUserId != receipt.ownerUserId) {
      throw ArgumentError.value(
        receipt.ownerUserId,
        'receipt.ownerUserId',
        'Assignment owner no longer matches the active user',
      );
    }
    await ref.read(scheduleRepositoryProvider).undoAssignmentSubmission(
          receipt: receipt,
          updatedAt: ref.read(appClockProvider).now(),
        );
  }

  Future<void> setAssignmentStatus(
    String assignmentId,
    AssignmentStatus status,
  ) async {
    final context = _context;
    await ref.read(scheduleRepositoryProvider).updateAssignmentState(
          assignmentId: assignmentId,
          userId: context.ownerUserId,
          status: status,
          updatedAt: ref.read(appClockProvider).now(),
        );
  }

  Future<SyncWorkerRunResult> processPendingSync() async {
    final result = await ref.read(syncWorkerProvider).processPending();
    return result;
  }

  Future<void> resolveSyncConflictServerWins(String clientMutationId) async {
    await ref
        .read(scheduleSyncStoreProvider)
        .resolveConflictServerWins(clientMutationId);
    await ref
        .read(scheduleSyncRuntimeProvider.notifier)
        .trigger(SyncTrigger.localMutation);
  }

  Future<WidgetSnapshot> regenerateWidgetSnapshot(
    WidgetSnapshotSettings settings,
  ) async {
    final context = _context;
    final snapshot =
        await ref.read(scheduleRepositoryProvider).saveWidgetSnapshot(
              ownerUserId: context.ownerUserId,
              universityId: context.universityId,
              termId: context.termId,
              settings: settings,
              generatedAt: ref.read(appClockProvider).now(),
            );
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(widgetSnapshot: snapshot));
    }
    return snapshot;
  }
}
