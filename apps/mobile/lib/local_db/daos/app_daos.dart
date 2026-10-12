part of '../app_database.dart';

@DriftAccessor(tables: [Profiles])
class ProfileDao extends DatabaseAccessor<AppDatabase> with _$ProfileDaoMixin {
  ProfileDao(super.db);

  Stream<Profile?> watchProfile(String userId) {
    return (select(profiles)..where((row) => row.userId.equals(userId)))
        .watchSingleOrNull();
  }
}

@DriftAccessor(tables: [UserCourses, PeriodSettings])
class TimetableDao extends DatabaseAccessor<AppDatabase>
    with _$TimetableDaoMixin {
  TimetableDao(super.db);

  Stream<List<UserCourse>> watchCoursesForTerm(
      String ownerUserId, String termId) {
    return (select(userCourses)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.termId.equals(termId) &
              row.deletedAt.isNull())
          ..orderBy([
            (row) => OrderingTerm(expression: row.dayOfWeek),
            (row) => OrderingTerm(expression: row.periodNo)
          ]))
        .watch();
  }

  Future<List<UserCourse>> coursesForTerm(String ownerUserId, String termId) {
    return (select(userCourses)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.termId.equals(termId) &
              row.deletedAt.isNull())
          ..orderBy([
            (row) => OrderingTerm(expression: row.dayOfWeek),
            (row) => OrderingTerm(expression: row.periodNo)
          ]))
        .get();
  }

  Future<UserCourse?> courseById(String courseId, String ownerUserId) {
    return (select(userCourses)
          ..where((row) =>
              row.id.equals(courseId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  /// Resolves active courses across all terms for assignment history.
  ///
  /// The timetable itself is deliberately limited to the active term, while a
  /// retained assignment can still point at an earlier term's course.
  Future<List<UserCourse>> activeCoursesByIds(
    String ownerUserId,
    Iterable<String> courseIds,
  ) async {
    final ids = courseIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return const [];
    return (select(userCourses)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.id.isIn(ids) &
              row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.title)]))
        .get();
  }

  Future<List<PeriodSetting>> periodSettingsForContext({
    required String ownerUserId,
    required String universityId,
    required String termId,
  }) {
    return (select(periodSettings)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.universityId.equals(universityId) &
              row.termId.equals(termId) &
              row.deletedAt.isNull())
          ..orderBy([
            (row) => OrderingTerm(expression: row.dayOfWeek),
            (row) => OrderingTerm(expression: row.periodNo)
          ]))
        .get();
  }

  Future<void> upsertCourse(UserCoursesCompanion course) {
    return into(userCourses).insertOnConflictUpdate(course);
  }
}

@DriftAccessor(tables: [CourseTemplatesCache])
class CourseTemplateDao extends DatabaseAccessor<AppDatabase>
    with _$CourseTemplateDaoMixin {
  CourseTemplateDao(super.db);

  Stream<List<CourseTemplatesCacheData>> watchCachedTemplates(
      String universityId) {
    return (select(courseTemplatesCache)
          ..where((row) => row.universityId.equals(universityId))
          ..orderBy([
            (row) => OrderingTerm(
                expression: row.copyCountTerm, mode: OrderingMode.desc),
            (row) => OrderingTerm(
                expression: row.copyCountTotal, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<List<CourseTemplatesCacheData>> cachedTemplates(String universityId) {
    return (select(courseTemplatesCache)
          ..where((row) => row.universityId.equals(universityId))
          ..orderBy([
            (row) => OrderingTerm(
                expression: row.copyCountTerm, mode: OrderingMode.desc),
            (row) => OrderingTerm(
                expression: row.copyCountTotal, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Future<CourseTemplatesCacheData?> templateById(String templateId) {
    return (select(courseTemplatesCache)
          ..where((row) => row.id.equals(templateId)))
        .getSingleOrNull();
  }

  Future<void> upsertTemplate(CourseTemplatesCacheCompanion template) {
    return into(courseTemplatesCache).insertOnConflictUpdate(template);
  }
}

@DriftAccessor(tables: [Assignments, AssignmentUserStates])
class AssignmentDao extends DatabaseAccessor<AppDatabase>
    with _$AssignmentDaoMixin {
  AssignmentDao(super.db);

  Stream<List<Assignment>> watchAssignments(String ownerUserId) {
    return (select(assignments)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.dueAt)]))
        .watch();
  }

  Future<List<Assignment>> assignmentsForUser(String ownerUserId) {
    return (select(assignments)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.dueAt)]))
        .get();
  }

  Future<Assignment?> assignmentById(String assignmentId, String ownerUserId) {
    return (select(assignments)
          ..where((row) =>
              row.id.equals(assignmentId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<List<AssignmentUserState>> statesForUser(String userId) {
    return (select(assignmentUserStates)
          ..where(
            (row) => row.userId.equals(userId) & row.deletedAt.isNull(),
          ))
        .get();
  }

  Future<AssignmentUserState?> stateForAssignment({
    required String assignmentId,
    required String userId,
  }) {
    return (select(assignmentUserStates)
          ..where((row) =>
              row.assignmentId.equals(assignmentId) &
              row.userId.equals(userId)))
        .getSingleOrNull();
  }

  Future<void> upsertAssignment(AssignmentsCompanion assignment) {
    return into(assignments).insertOnConflictUpdate(assignment);
  }

  Future<void> submitAssignment({
    required String assignmentId,
    required String userId,
    required DateTime submittedAt,
  }) {
    return into(assignmentUserStates).insertOnConflictUpdate(
      AssignmentUserStatesCompanion.insert(
        assignmentId: assignmentId,
        userId: userId,
        status: const Value('submitted'),
        submittedAt: Value(submittedAt),
      ),
    );
  }
}

@DriftAccessor(tables: [Exams])
class ExamDao extends DatabaseAccessor<AppDatabase> with _$ExamDaoMixin {
  ExamDao(super.db);

  Stream<List<Exam>> watchExams(String ownerUserId) {
    return (select(exams)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .watch();
  }

  Future<List<Exam>> examsForUser(String ownerUserId) {
    return (select(exams)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .get();
  }

  Future<Exam?> examById(String examId, String ownerUserId) {
    return (select(exams)
          ..where((row) =>
              row.id.equals(examId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<void> upsertExam(ExamsCompanion exam) {
    return into(exams).insertOnConflictUpdate(exam);
  }
}

@DriftAccessor(tables: [
  Events,
  EventExceptions,
  EventParticipants,
  EventComments,
  EventReactions
])
class EventDao extends DatabaseAccessor<AppDatabase> with _$EventDaoMixin {
  EventDao(super.db);

  Stream<List<Event>> watchEventsInRange(
    String ownerUserId,
    DateTime start,
    DateTime end,
  ) {
    return (select(events)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull() &
              row.startAt.isSmallerThanValue(end) &
              row.endAt.isBiggerThanValue(start))
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .watch();
  }

  Future<Event?> eventById(String eventId, String ownerUserId) {
    return (select(events)
          ..where((row) =>
              row.id.equals(eventId) &
              row.ownerUserId.equals(ownerUserId) &
              row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  Future<void> upsertEvent(EventsCompanion event) {
    return into(events).insertOnConflictUpdate(event);
  }

  Future<List<Event>> eventsForUser(String ownerUserId) {
    return (select(events)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.deletedAt.isNull())
          ..orderBy([(row) => OrderingTerm(expression: row.startAt)]))
        .get();
  }

  Future<List<EventException>> exceptionsForEvents(Iterable<String> eventIds) {
    final ids = eventIds.toList();
    if (ids.isEmpty) return Future.value([]);
    return (select(eventExceptions)
          ..where(
            (row) => row.eventId.isIn(ids) & row.deletedAt.isNull(),
          ))
        .get();
  }

  Stream<List<EventException>> watchExceptions(String eventId) {
    return (select(eventExceptions)
          ..where(
            (row) => row.eventId.equals(eventId) & row.deletedAt.isNull(),
          ))
        .watch();
  }
}

@DriftAccessor(tables: [CalendarDisplayPreferences])
class CalendarDisplayPreferencesDao extends DatabaseAccessor<AppDatabase>
    with _$CalendarDisplayPreferencesDaoMixin {
  CalendarDisplayPreferencesDao(super.db);

  Stream<CalendarDisplayPreference?> watchForOwner(String ownerUserId) {
    return (select(calendarDisplayPreferences)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .watchSingleOrNull();
  }

  Future<CalendarDisplayPreference?> preferencesForOwner(String ownerUserId) {
    return (select(calendarDisplayPreferences)
          ..where((row) => row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<void> savePreferences({
    required String ownerUserId,
    required bool showCourses,
    required bool showAssignmentDeadlines,
    required bool showExams,
    required bool showPersonalEvents,
    required DateTime updatedAt,
  }) async {
    if (ownerUserId.trim().isEmpty) {
      throw ArgumentError.value(
          ownerUserId, 'ownerUserId', 'must not be empty');
    }
    await into(calendarDisplayPreferences).insertOnConflictUpdate(
      CalendarDisplayPreferencesCompanion.insert(
        ownerUserId: ownerUserId,
        showCourses: Value(showCourses),
        showAssignmentDeadlines: Value(showAssignmentDeadlines),
        showExams: Value(showExams),
        showPersonalEvents: Value(showPersonalEvents),
        updatedAt: Value(updatedAt),
      ),
    );
  }
}

@DriftAccessor(tables: [Groups, GroupMembers])
class GroupDao extends DatabaseAccessor<AppDatabase> with _$GroupDaoMixin {
  GroupDao(super.db);

  Stream<List<Group>> watchJoinedGroups(String userId) {
    final query = select(groups).join([
      innerJoin(groupMembers, groupMembers.groupId.equalsExp(groups.id)),
    ])
      ..where(groupMembers.userId.equals(userId) & groups.deletedAt.isNull());
    return query
        .watch()
        .map((rows) => rows.map((row) => row.readTable(groups)).toList());
  }
}

@DriftAccessor(
  tables: [
    EmailConnections,
    EmailSources,
    EmailCandidates,
    EmailCandidateUpdates,
    EmailDismissalTombstones,
    EmailReconciliationReceipts,
    EmailScheduleEntityLinks,
  ],
)
class EmailImportDao extends DatabaseAccessor<AppDatabase>
    with _$EmailImportDaoMixin {
  EmailImportDao(super.db);

  Stream<List<EmailConnection>> watchConnections(String ownerUserId) {
    return (select(emailConnections)
          ..where((row) => row.ownerUserId.equals(ownerUserId))
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }

  Future<EmailConnection?> connectionById({
    required String ownerUserId,
    required String connectionId,
  }) {
    return (select(emailConnections)
          ..where((row) =>
              row.id.equals(connectionId) &
              row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Stream<List<EmailCandidate>> watchReviewCandidates(String ownerUserId) {
    return (select(emailCandidates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.reviewState.isIn(const [
                'needs_review',
                'ready_for_review',
                'update_available',
                'failed',
              ]))
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }

  Future<EmailCandidate?> candidateById({
    required String ownerUserId,
    required String candidateId,
  }) {
    return (select(emailCandidates)
          ..where((row) =>
              row.id.equals(candidateId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<EmailSource?> sourceById({
    required String ownerUserId,
    required String sourceId,
  }) {
    return (select(emailSources)
          ..where((row) =>
              row.id.equals(sourceId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<EmailSource?> sourceByThreadContentHash({
    required String ownerUserId,
    required String connectionId,
    required String providerThreadId,
    required String sanitizedContentHash,
    required String excludingSourceId,
  }) {
    return (select(emailSources)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.connectionId.equals(connectionId) &
                row.providerThreadId.equals(providerThreadId) &
                row.sanitizedContentHash.equals(sanitizedContentHash) &
                row.id.equals(excludingSourceId).not(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<List<EmailCandidate>> confirmedCandidatesForThread({
    required String ownerUserId,
    required String connectionId,
    required String providerThreadId,
  }) {
    final query = select(emailCandidates).join([
      innerJoin(
        emailSources,
        emailSources.id.equalsExp(emailCandidates.sourceId),
      ),
    ])
      ..where(
        emailCandidates.ownerUserId.equals(ownerUserId) &
            emailCandidates.reviewState.equals('confirmed') &
            emailSources.ownerUserId.equals(ownerUserId) &
            emailSources.connectionId.equals(connectionId) &
            emailSources.providerThreadId.equals(providerThreadId),
      )
      ..orderBy([
        OrderingTerm(
          expression: emailCandidates.confirmedAt,
          mode: OrderingMode.desc,
        ),
      ]);
    return query.map((row) => row.readTable(emailCandidates)).get();
  }

  Future<EmailDismissalTombstone?> dismissalById({
    required String ownerUserId,
    required String tombstoneId,
  }) {
    return (select(emailDismissalTombstones)
          ..where(
            (row) =>
                row.id.equals(tombstoneId) &
                row.ownerUserId.equals(ownerUserId),
          ))
        .getSingleOrNull();
  }

  Future<bool> isDismissedDuplicate({
    required String ownerUserId,
    required String provider,
    required String providerAccountHash,
    required String providerMessageIdHash,
    required String providerThreadIdHash,
    required String sanitizedContentHash,
    required String semanticFingerprint,
  }) async {
    final match = await (select(emailDismissalTombstones)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.provider.equals(provider) &
                row.providerAccountHash.equals(providerAccountHash) &
                (row.providerMessageIdHash.equals(providerMessageIdHash) |
                    (row.providerThreadIdHash.equals(providerThreadIdHash) &
                        (row.sanitizedContentHash.equals(sanitizedContentHash) |
                            row.semanticFingerprint
                                .equals(semanticFingerprint)))),
          )
          ..limit(1))
        .getSingleOrNull();
    return match != null;
  }

  Future<List<EmailCandidateUpdate>> pendingUpdates({
    required String ownerUserId,
    required String candidateId,
  }) {
    return (select(emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidateId) &
              row.state.equals('pending'))
          ..orderBy([(row) => OrderingTerm(expression: row.createdAt)]))
        .get();
  }

  Stream<List<EmailCandidateUpdate>> watchPendingUpdates(
    String ownerUserId,
  ) {
    return (select(emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) & row.state.equals('pending'))
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.createdAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .watch();
  }

  Future<EmailCandidateUpdate?> candidateUpdateById({
    required String ownerUserId,
    required String updateId,
  }) {
    return (select(emailCandidateUpdates)
          ..where((row) =>
              row.id.equals(updateId) & row.ownerUserId.equals(ownerUserId)))
        .getSingleOrNull();
  }

  Future<List<EmailCandidateUpdate>> updatesForCandidate({
    required String ownerUserId,
    required String candidateId,
  }) {
    return (select(emailCandidateUpdates)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.candidateId.equals(candidateId))
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.createdAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
  }

  Future<void> upsertConnection({
    required String ownerUserId,
    required EmailConnectionsCompanion connection,
  }) async {
    _requireEmailWriteOwner(ownerUserId, connection.ownerUserId);
    if (connection.id.present) {
      final existing = await (select(emailConnections)
            ..where((row) => row.id.equals(connection.id.value)))
          .getSingleOrNull();
      _rejectEmailOwnerTakeover(ownerUserId, existing?.ownerUserId);
    }
    await into(emailConnections).insertOnConflictUpdate(connection);
  }

  Future<void> upsertSource({
    required String ownerUserId,
    required EmailSourcesCompanion source,
  }) async {
    _requireEmailWriteOwner(ownerUserId, source.ownerUserId);
    if (source.id.present) {
      final existing = await (select(emailSources)
            ..where((row) => row.id.equals(source.id.value)))
          .getSingleOrNull();
      _rejectEmailOwnerTakeover(ownerUserId, existing?.ownerUserId);
    }
    await into(emailSources).insertOnConflictUpdate(source);
  }

  Future<void> upsertCandidate({
    required String ownerUserId,
    required EmailCandidatesCompanion candidate,
  }) async {
    _requireEmailWriteOwner(ownerUserId, candidate.ownerUserId);
    if (candidate.id.present) {
      final existing = await (select(emailCandidates)
            ..where((row) => row.id.equals(candidate.id.value)))
          .getSingleOrNull();
      _rejectEmailOwnerTakeover(ownerUserId, existing?.ownerUserId);
    }
    await into(emailCandidates).insertOnConflictUpdate(candidate);
  }

  Future<void> upsertCandidateUpdate({
    required String ownerUserId,
    required EmailCandidateUpdatesCompanion update,
  }) async {
    _requireEmailWriteOwner(ownerUserId, update.ownerUserId);
    if (update.id.present) {
      final existing = await (select(emailCandidateUpdates)
            ..where((row) => row.id.equals(update.id.value)))
          .getSingleOrNull();
      _rejectEmailOwnerTakeover(ownerUserId, existing?.ownerUserId);
    }
    await into(emailCandidateUpdates).insertOnConflictUpdate(update);
  }

  Future<void> insertCandidateUpdate({
    required String ownerUserId,
    required EmailCandidateUpdatesCompanion update,
  }) async {
    _requireEmailWriteOwner(ownerUserId, update.ownerUserId);
    if (!update.id.present) {
      throw ArgumentError('Email update proposals require a stable id.');
    }
    final existing = await (select(emailCandidateUpdates)
          ..where((row) => row.id.equals(update.id.value)))
        .getSingleOrNull();
    _rejectEmailOwnerTakeover(ownerUserId, existing?.ownerUserId);
    if (existing != null) {
      throw StateError('Email update proposal already exists.');
    }
    await into(emailCandidateUpdates).insert(update);
  }

  Future<bool> dismissAndPruneCandidate({
    required String ownerUserId,
    required String candidateId,
    required DateTime dismissedAt,
  }) {
    return transaction(() async {
      final candidate = await candidateById(
        ownerUserId: ownerUserId,
        candidateId: candidateId,
      );
      if (candidate == null) {
        return await dismissalById(
              ownerUserId: ownerUserId,
              tombstoneId: candidateId,
            ) !=
            null;
      }
      if (candidate.reviewState == 'confirmed') {
        throw StateError('Confirmed email candidates cannot be dismissed.');
      }
      final source = await sourceById(
        ownerUserId: ownerUserId,
        sourceId: candidate.sourceId,
      );
      if (source == null) {
        throw StateError('Email candidate source is unavailable.');
      }
      final connection = await connectionById(
        ownerUserId: ownerUserId,
        connectionId: source.connectionId,
      );
      if (connection == null) {
        throw StateError('Email connection is unavailable.');
      }
      await into(emailDismissalTombstones).insert(
        EmailDismissalTombstonesCompanion.insert(
          id: candidate.id,
          ownerUserId: ownerUserId,
          provider: connection.provider,
          providerAccountHash: connection.providerAccountHash,
          providerMessageIdHash: emailProviderIdentifierHash(
            kind: 'message',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerMessageId,
          ),
          providerThreadIdHash: emailProviderIdentifierHash(
            kind: 'thread',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerThreadId,
          ),
          sanitizedContentHash: source.sanitizedContentHash,
          semanticFingerprint: candidate.semanticFingerprint,
          dismissedAt: dismissedAt.toUtc(),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      await into(emailReconciliationReceipts).insert(
        EmailReconciliationReceiptsCompanion.insert(
          id: 'dismissal:${candidate.id}',
          ownerUserId: ownerUserId,
          connectionId: source.connectionId,
          action: 'dismissal',
          localReferenceId: candidate.id,
          provider: connection.provider,
          providerAccountHash: connection.providerAccountHash,
          providerMessageIdHash: emailProviderIdentifierHash(
            kind: 'message',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerMessageId,
          ),
          providerThreadIdHash: emailProviderIdentifierHash(
            kind: 'thread',
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            rawIdentifier: source.providerThreadId,
          ),
          sanitizedContentHash: source.sanitizedContentHash,
          idempotencyKey: 'email-dismissal-${candidate.id}',
          createdAt: Value(dismissedAt.toUtc()),
          updatedAt: Value(dismissedAt.toUtc()),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      final deleted = await (delete(emailSources)
            ..where((row) =>
                row.id.equals(source.id) & row.ownerUserId.equals(ownerUserId)))
          .go();
      if (deleted != 1) {
        throw StateError('Email dismissal pruning did not delete its source.');
      }
      return true;
    });
  }

  /// Applies a trusted server suppression acknowledgement to a cached failed
  /// review. Unlike a user dismissal, this never creates a reconciliation
  /// receipt: the server has already committed the dismissal/dedupe outcome.
  Future<bool> pruneSuppressedFailedSource({
    required String ownerUserId,
    required String connectionId,
    required String providerMessageIdHash,
    required bool retainDismissalTombstone,
    required DateTime suppressedAt,
  }) {
    return transaction(() async {
      final connection = await connectionById(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      );
      if (connection == null) {
        throw StateError('Email connection is unavailable.');
      }
      final failedSources = await (select(emailSources)
            ..where(
              (row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.connectionId.equals(connectionId) &
                  row.processingState.equals('failed'),
            ))
          .get();
      final matchingSources = failedSources.where(
        (source) =>
            emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ) ==
            providerMessageIdHash,
      );
      if (matchingSources.length != 1) return false;
      final source = matchingSources.single;
      final candidate = await (select(emailCandidates)
            ..where(
              (row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.sourceId.equals(source.id),
            ))
          .getSingleOrNull();
      if (candidate == null || candidate.reviewState != 'failed') return false;
      if (retainDismissalTombstone) {
        await into(emailDismissalTombstones).insert(
          EmailDismissalTombstonesCompanion.insert(
            id: candidate.id,
            ownerUserId: ownerUserId,
            provider: connection.provider,
            providerAccountHash: connection.providerAccountHash,
            providerMessageIdHash: emailProviderIdentifierHash(
              kind: 'message',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerMessageId,
            ),
            providerThreadIdHash: emailProviderIdentifierHash(
              kind: 'thread',
              provider: connection.provider,
              providerAccountHash: connection.providerAccountHash,
              rawIdentifier: source.providerThreadId,
            ),
            sanitizedContentHash: source.sanitizedContentHash,
            semanticFingerprint: candidate.semanticFingerprint,
            dismissedAt: suppressedAt.toUtc(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
      final deleted = await (delete(emailSources)
            ..where(
              (row) =>
                  row.id.equals(source.id) &
                  row.ownerUserId.equals(ownerUserId),
            ))
          .go();
      if (deleted != 1) {
        throw StateError('Suppressed email source pruning was not atomic.');
      }
      return true;
    });
  }

  /// Removes only provider-derived rows and their private reconciliation
  /// outbox for this exact owner/connection. Minimal dismissal hashes have no
  /// connection foreign key and intentionally survive reconnects; linked
  /// Assignment, Exam and Event rows remain user-owned.
  Future<int> deleteDerivedDataForConnection({
    required String ownerUserId,
    required String connectionId,
  }) {
    return transaction(() async {
      final connection = await connectionById(
        ownerUserId: ownerUserId,
        connectionId: connectionId,
      );
      if (connection == null) return 0;
      await (delete(emailReconciliationReceipts)
            ..where((row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.connectionId.equals(connectionId)))
          .go();
      final deleted = await (delete(emailConnections)
            ..where((row) =>
                row.id.equals(connectionId) &
                row.ownerUserId.equals(ownerUserId)))
          .go();
      if (deleted != 1) {
        throw StateError('Email connection changed during derived deletion.');
      }
      return deleted;
    });
  }

  void _requireEmailWriteOwner(
    String expectedOwnerUserId,
    Value<String> companionOwner,
  ) {
    if (expectedOwnerUserId.trim().isEmpty ||
        !companionOwner.present ||
        companionOwner.value != expectedOwnerUserId) {
      throw ArgumentError('Email cache writes require the active owner.');
    }
  }

  void _rejectEmailOwnerTakeover(
    String expectedOwnerUserId,
    String? existingOwnerUserId,
  ) {
    if (existingOwnerUserId != null &&
        existingOwnerUserId != expectedOwnerUserId) {
      throw StateError('Email cache row belongs to another owner.');
    }
  }
}

@DriftAccessor(tables: [WidgetSnapshots])
class WidgetSnapshotDao extends DatabaseAccessor<AppDatabase>
    with _$WidgetSnapshotDaoMixin {
  WidgetSnapshotDao(super.db);

  Future<void> saveSnapshot(WidgetSnapshotsCompanion snapshot) {
    return into(widgetSnapshots).insertOnConflictUpdate(snapshot);
  }

  Future<WidgetSnapshot?> latestForUser(String ownerUserId) {
    return (select(widgetSnapshots)
          ..where((row) => row.ownerUserId.equals(ownerUserId))
          ..orderBy([
            (row) => OrderingTerm(
                expression: row.generatedAt, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
  }
}

@DriftAccessor(
  tables: [SyncQueueEntries, SyncQueueSequenceStates, SyncCursors],
)
class SyncQueueDao extends DatabaseAccessor<AppDatabase>
    with _$SyncQueueDaoMixin {
  SyncQueueDao(super.db);

  Future<List<SyncQueueEntry>> pendingMutations(String ownerUserId) {
    return (select(syncQueueEntries)
          ..where((row) =>
              row.ownerUserId.equals(ownerUserId) &
              row.status.equals('pending'))
          ..orderBy([
            (row) => OrderingTerm(expression: row.enqueueSequence),
          ]))
        .get();
  }

  Future<List<SyncQueueEntry>> allMutations(String ownerUserId) {
    return (select(syncQueueEntries)
          ..where((row) => row.ownerUserId.equals(ownerUserId))
          ..orderBy([
            (row) => OrderingTerm(expression: row.enqueueSequence),
          ]))
        .get();
  }

  Future<void> enqueue(SyncQueueEntriesCompanion mutation) {
    return transaction(() async {
      final existing = await (select(syncQueueEntries)
            ..where(
              (row) => row.clientMutationId.equals(
                mutation.clientMutationId.value,
              ),
            ))
          .getSingleOrNull();
      if (existing != null) {
        await into(syncQueueEntries).insertOnConflictUpdate(
          mutation.copyWith(
            enqueueSequence: Value(existing.enqueueSequence),
          ),
        );
        return;
      }

      final sequence = await _takeNextEnqueueSequence();
      await into(syncQueueEntries).insert(
        mutation.copyWith(enqueueSequence: Value(sequence)),
      );
    });
  }

  Future<int> _takeNextEnqueueSequence() async {
    final state = await (select(syncQueueSequenceStates)
          ..where((row) => row.id.equals(1)))
        .getSingle();
    final sequence = state.nextValue;
    final updated = await (update(syncQueueSequenceStates)
          ..where(
            (row) => row.id.equals(1) & row.nextValue.equals(state.nextValue),
          ))
        .write(
      SyncQueueSequenceStatesCompanion(
        nextValue: Value(sequence + 1),
      ),
    );
    if (updated != 1) {
      throw StateError('Unable to reserve a sync queue sequence.');
    }
    return sequence;
  }

  Future<SyncQueueEntry?> claimNext(String ownerUserId, DateTime now) {
    return transaction(() async {
      final candidate = await (select(syncQueueEntries)
            ..where(
              (row) =>
                  row.ownerUserId.equals(ownerUserId) &
                  row.status.isIn(
                    const ['pending', 'processing', 'failed', 'conflict'],
                  ),
            )
            ..orderBy([
              (row) => OrderingTerm(expression: row.enqueueSequence),
            ])
            ..limit(1))
          .getSingleOrNull();
      if (candidate == null) return null;
      if (candidate.status == 'processing' || candidate.status == 'conflict') {
        return null;
      }
      if (candidate.status == 'failed' &&
          candidate.nextRetryAt != null &&
          candidate.nextRetryAt!.isAfter(now)) {
        return null;
      }

      final changed = await (update(syncQueueEntries)
            ..where(
              (row) =>
                  row.clientMutationId.equals(candidate.clientMutationId) &
                  row.ownerUserId.equals(ownerUserId) &
                  row.status.equals(candidate.status),
            ))
          .write(
        SyncQueueEntriesCompanion(
          status: const Value('processing'),
          attemptCount: Value(candidate.attemptCount + 1),
          lastAttemptAt: Value(now),
          claimedAt: Value(now),
          nextRetryAt: const Value(null),
          errorMessage: const Value(null),
        ),
      );
      if (changed != 1) return null;

      return (select(syncQueueEntries)
            ..where(
              (row) =>
                  row.clientMutationId.equals(candidate.clientMutationId) &
                  row.ownerUserId.equals(ownerUserId),
            ))
          .getSingle();
    });
  }

  Future<DateTime?> blockedUntil(String ownerUserId) async {
    final head = await (select(syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.status.isIn(
                  const ['pending', 'processing', 'failed', 'conflict'],
                ),
          )
          ..orderBy([
            (row) => OrderingTerm(expression: row.enqueueSequence),
          ])
          ..limit(1))
        .getSingleOrNull();
    return head?.status == 'failed' ? head?.nextRetryAt : null;
  }

  Future<int> recoverAbandoned(
    String ownerUserId,
    DateTime claimedBefore,
  ) {
    return (update(syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.status.equals('processing') &
                (row.claimedAt.isNull() |
                    row.claimedAt.isSmallerOrEqualValue(claimedBefore)),
          ))
        .write(
      const SyncQueueEntriesCompanion(
        status: Value('pending'),
        claimedAt: Value(null),
        nextRetryAt: Value(null),
        errorMessage: Value(null),
      ),
    );
  }

  Future<int> recoverAllProcessing(String ownerUserId) {
    return (update(syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.status.equals('processing'),
          ))
        .write(
      const SyncQueueEntriesCompanion(
        status: Value('pending'),
        claimedAt: Value(null),
        nextRetryAt: Value(null),
        errorMessage: Value(null),
      ),
    );
  }

  Future<List<SyncQueueEntry>> activeMutationsForEntity({
    required String ownerUserId,
    required String entityType,
    required String entityId,
  }) {
    return (select(syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.entityType.equals(entityType) &
                row.entityId.equals(entityId) &
                row.status.isIn(
                  const ['pending', 'processing', 'failed', 'conflict'],
                ),
          )
          ..orderBy([
            (row) => OrderingTerm(expression: row.enqueueSequence),
          ]))
        .get();
  }

  Stream<int> watchActionableCount(String ownerUserId) {
    final count = syncQueueEntries.clientMutationId.count();
    final query = selectOnly(syncQueueEntries)
      ..addColumns([count])
      ..where(
        syncQueueEntries.ownerUserId.equals(ownerUserId) &
            syncQueueEntries.status.isIn(
              const ['pending', 'processing', 'failed', 'conflict'],
            ),
      );
    return query.watchSingle().map((row) => row.read(count) ?? 0).distinct();
  }

  Stream<List<SyncQueueEntry>> watchActionableMutations(String ownerUserId) {
    return (select(syncQueueEntries)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) &
                row.status.isIn(
                  const ['pending', 'processing', 'failed', 'conflict'],
                ),
          )
          ..orderBy([
            (row) => OrderingTerm(expression: row.enqueueSequence),
          ]))
        .watch();
  }

  Future<bool> markSynced(
    String ownerUserId,
    String clientMutationId,
    DateTime syncedAt, {
    required int attemptCount,
    int? serverVersion,
  }) async {
    final changed = await (update(syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId) &
              row.status.equals('processing') &
              row.attemptCount.equals(attemptCount)))
        .write(
      SyncQueueEntriesCompanion(
        status: const Value('synced'),
        payloadJson: const Value('{}'),
        serverVersion:
            serverVersion == null ? const Value.absent() : Value(serverVersion),
        nextRetryAt: const Value(null),
        claimedAt: const Value(null),
        syncedAt: Value(syncedAt),
        completionProvenance: const Value(scheduleSyncCompletionRemoteApplied),
        errorMessage: const Value(null),
        serverPayloadJson: const Value(null),
        conflictCursor: const Value(null),
      ),
    );
    return changed == 1;
  }

  Future<bool> markFailed(
    String ownerUserId,
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    DateTime? nextRetryAt,
  }) async {
    final changed = await (update(syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId) &
              row.status.equals('processing') &
              row.attemptCount.equals(attemptCount)))
        .write(
      SyncQueueEntriesCompanion(
        status: const Value('failed'),
        nextRetryAt: Value(nextRetryAt),
        claimedAt: const Value(null),
        syncedAt: const Value(null),
        completionProvenance: const Value(null),
        errorMessage: Value(errorMessage),
      ),
    );
    return changed == 1;
  }

  Future<bool> markConflict(
    String ownerUserId,
    String clientMutationId,
    String errorMessage, {
    required int attemptCount,
    int? serverVersion,
    String? serverPayloadJson,
    int? conflictCursor,
  }) async {
    final changed = await (update(syncQueueEntries)
          ..where((row) =>
              row.clientMutationId.equals(clientMutationId) &
              row.ownerUserId.equals(ownerUserId) &
              row.status.equals('processing') &
              row.attemptCount.equals(attemptCount)))
        .write(
      SyncQueueEntriesCompanion(
        status: const Value('conflict'),
        serverVersion:
            serverVersion == null ? const Value.absent() : Value(serverVersion),
        serverPayloadJson: serverPayloadJson == null
            ? const Value.absent()
            : Value(serverPayloadJson),
        conflictCursor: conflictCursor == null
            ? const Value.absent()
            : Value(conflictCursor),
        nextRetryAt: const Value(null),
        claimedAt: const Value(null),
        syncedAt: const Value(null),
        completionProvenance: const Value(null),
        errorMessage: Value(errorMessage),
      ),
    );
    return changed == 1;
  }

  Future<bool> resolveConflictServerWins(
    String ownerUserId,
    String clientMutationId,
    DateTime resolvedAt,
  ) async {
    final changed = await (update(syncQueueEntries)
          ..where(
            (row) =>
                row.clientMutationId.equals(clientMutationId) &
                row.ownerUserId.equals(ownerUserId) &
                row.status.equals('conflict'),
          ))
        .write(
      SyncQueueEntriesCompanion(
        status: const Value('synced'),
        payloadJson: const Value('{}'),
        serverPayloadJson: const Value(null),
        conflictCursor: const Value(null),
        nextRetryAt: const Value(null),
        claimedAt: const Value(null),
        syncedAt: Value(resolvedAt),
        completionProvenance: const Value(scheduleSyncCompletionServerWins),
        errorMessage: const Value(null),
      ),
    );
    return changed == 1;
  }

  Future<int> deleteAcknowledgedBefore(DateTime cutoff) {
    return (delete(syncQueueEntries)
          ..where(
            (row) =>
                (row.status.equals('synced') |
                    row.status.equals('quarantined')) &
                row.syncedAt.isNotNull() &
                row.syncedAt.isSmallerThanValue(cutoff) &
                row.payloadJson.equals('{}') &
                row.errorMessage.isNull(),
          ))
        .go();
  }

  Future<int> readCursor(
    String ownerUserId, {
    String stream = 'schedule',
  }) async {
    final row = await (select(syncCursors)
          ..where(
            (row) =>
                row.ownerUserId.equals(ownerUserId) & row.stream.equals(stream),
          ))
        .getSingleOrNull();
    return row?.cursor ?? 0;
  }

  Future<void> writeCursor({
    required String ownerUserId,
    required int cursor,
    required DateTime updatedAt,
    String stream = 'schedule',
  }) {
    return into(syncCursors).insertOnConflictUpdate(
      SyncCursorsCompanion.insert(
        ownerUserId: ownerUserId,
        stream: Value(stream),
        cursor: Value(cursor),
        updatedAt: Value(updatedAt),
      ),
    );
  }
}
