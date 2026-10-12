import 'package:drift/drift.dart';

class Profiles extends Table {
  TextColumn get userId => text().named('user_id')();
  TextColumn get displayName => text().named('display_name')();
  TextColumn get userType =>
      text().named('user_type').withDefault(const Constant('other'))();
  TextColumn get username => text().nullable()();
  TextColumn get universityId => text().named('university_id').nullable()();
  TextColumn get campusId => text().named('campus_id').nullable()();
  TextColumn get facultyId => text().named('faculty_id').nullable()();
  TextColumn get departmentId => text().named('department_id').nullable()();
  TextColumn get activeTermId => text().named('active_term_id').nullable()();
  TextColumn get primaryCalendarId =>
      text().named('primary_calendar_id').nullable()();
  IntColumn get entryAcademicYear =>
      integer().named('entry_academic_year').nullable()();
  IntColumn get grade => integer().nullable()();
  BoolColumn get universityVerified => boolean()
      .named('university_verified')
      .withDefault(const Constant(false))();
  BoolColumn get searchableByUsername => boolean()
      .named('searchable_by_username')
      .withDefault(const Constant(false))();
  TextColumn get defaultVisibility => text()
      .named('default_visibility')
      .withDefault(const Constant('PRIVATE'))();
  TextColumn get onboardingStatus => text()
      .named('onboarding_status')
      .withDefault(const Constant('not_started'))();
  TextColumn get onboardingStep =>
      text().named('onboarding_step').withDefault(const Constant('profile'))();
  DateTimeColumn get onboardingCompletedAt =>
      dateTime().named('onboarding_completed_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {userId};
}

class Universities extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get normalizedName => text().named('normalized_name')();
  TextColumn get prefecture => text().nullable()();
  TextColumn get aliasesJson =>
      text().named('aliases_json').withDefault(const Constant('[]'))();
  TextColumn get domainHintsJson =>
      text().named('domain_hints_json').withDefault(const Constant('[]'))();
  TextColumn get officialWebDomain =>
      text().named('official_web_domain').nullable()();
  TextColumn get timezone => text().withDefault(const Constant('Asia/Tokyo'))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Campuses extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get configKey => text().named('config_key')();
  TextColumn get name => text()();
  TextColumn get normalizedName => text().named('normalized_name')();
  BoolColumn get isMain =>
      boolean().named('is_main').withDefault(const Constant(false))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get effectiveFrom =>
      dateTime().named('effective_from').nullable()();
  DateTimeColumn get effectiveTo =>
      dateTime().named('effective_to').nullable()();
  TextColumn get sourceUrl => text().named('source_url').nullable()();
  DateTimeColumn get sourceCheckedAt =>
      dateTime().named('source_checked_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Faculties extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get configKey => text().named('config_key')();
  TextColumn get name => text()();
  TextColumn get normalizedName => text().named('normalized_name')();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get effectiveFrom =>
      dateTime().named('effective_from').nullable()();
  DateTimeColumn get effectiveTo =>
      dateTime().named('effective_to').nullable()();
  TextColumn get sourceUrl => text().named('source_url').nullable()();
  DateTimeColumn get sourceCheckedAt =>
      dateTime().named('source_checked_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Departments extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get facultyId => text().named('faculty_id')();
  TextColumn get configKey => text().named('config_key')();
  TextColumn get name => text()();
  TextColumn get normalizedName => text().named('normalized_name')();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get effectiveFrom =>
      dateTime().named('effective_from').nullable()();
  DateTimeColumn get effectiveTo =>
      dateTime().named('effective_to').nullable()();
  TextColumn get sourceUrl => text().named('source_url').nullable()();
  DateTimeColumn get sourceCheckedAt =>
      dateTime().named('source_checked_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class UniversityDomains extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get configKey => text().named('config_key')();
  TextColumn get domain => text()();
  TextColumn get kind => text()();
  BoolColumn get verificationEnabled => boolean()
      .named('verification_enabled')
      .withDefault(const Constant(false))();
  BoolColumn get matchSubdomains =>
      boolean().named('match_subdomains').withDefault(const Constant(false))();
  IntColumn get cohortStartAcademicYear =>
      integer().named('cohort_start_academic_year').nullable()();
  IntColumn get cohortEndAcademicYear =>
      integer().named('cohort_end_academic_year').nullable()();
  DateTimeColumn get effectiveFrom =>
      dateTime().named('effective_from').nullable()();
  DateTimeColumn get effectiveTo =>
      dateTime().named('effective_to').nullable()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get sourceUrl => text().named('source_url').nullable()();
  DateTimeColumn get sourceCheckedAt =>
      dateTime().named('source_checked_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Terms extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get configKey => text().named('config_key').nullable()();
  TextColumn get ownerUserId => text().named('owner_user_id').nullable()();
  TextColumn get sourceTemplateId =>
      text().named('source_template_id').nullable()();
  TextColumn get name => text()();
  IntColumn get academicYear => integer().named('academic_year')();
  DateTimeColumn get startDate => dateTime().named('start_date')();
  DateTimeColumn get endDate => dateTime().named('end_date')();
  DateTimeColumn get instructionStartDate =>
      dateTime().named('instruction_start_date').nullable()();
  DateTimeColumn get instructionEndDate =>
      dateTime().named('instruction_end_date').nullable()();
  TextColumn get termType => text().named('term_type')();
  BoolColumn get isTemplate =>
      boolean().named('is_template').withDefault(const Constant(false))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PeriodTemplateSets extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get campusId => text().named('campus_id').nullable()();
  TextColumn get configKey => text().named('config_key')();
  TextColumn get name => text()();
  IntColumn get academicYear => integer().named('academic_year').nullable()();
  TextColumn get userType => text().named('user_type').nullable()();
  DateTimeColumn get effectiveFrom =>
      dateTime().named('effective_from').nullable()();
  DateTimeColumn get effectiveTo =>
      dateTime().named('effective_to').nullable()();
  BoolColumn get isDefault =>
      boolean().named('is_default').withDefault(const Constant(false))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get sourceUrl => text().named('source_url').nullable()();
  DateTimeColumn get sourceCheckedAt =>
      dateTime().named('source_checked_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PeriodTemplates extends Table {
  TextColumn get id => text()();
  TextColumn get templateSetId => text().named('template_set_id')();
  TextColumn get universityId => text().named('university_id')();
  IntColumn get dayOfWeek => integer().named('day_of_week')();
  IntColumn get periodNo => integer().named('period_no')();
  IntColumn get startTimeMinutes => integer().named('start_time_minutes')();
  IntColumn get endTimeMinutes => integer().named('end_time_minutes')();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PeriodSettings extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get universityId => text().named('university_id')();
  TextColumn get termId => text().named('term_id')();
  TextColumn get sourceTemplateSetId =>
      text().named('source_template_set_id').nullable()();
  IntColumn get dayOfWeek => integer().named('day_of_week')();
  IntColumn get periodNo => integer().named('period_no')();
  IntColumn get startTimeMinutes => integer().named('start_time_minutes')();
  IntColumn get endTimeMinutes => integer().named('end_time_minutes')();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class OnboardingDrafts extends Table {
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get universityId => text().named('university_id').nullable()();
  TextColumn get campusId => text().named('campus_id').nullable()();
  TextColumn get facultyId => text().named('faculty_id').nullable()();
  TextColumn get departmentId => text().named('department_id').nullable()();
  IntColumn get entryAcademicYear =>
      integer().named('entry_academic_year').nullable()();
  TextColumn get sourceTermTemplateId =>
      text().named('source_term_template_id').nullable()();
  TextColumn get termName => text().named('term_name').nullable()();
  IntColumn get academicYear => integer().named('academic_year').nullable()();
  DateTimeColumn get termStartDate =>
      dateTime().named('term_start_date').nullable()();
  DateTimeColumn get termEndDate =>
      dateTime().named('term_end_date').nullable()();
  DateTimeColumn get instructionStartDate =>
      dateTime().named('instruction_start_date').nullable()();
  DateTimeColumn get instructionEndDate =>
      dateTime().named('instruction_end_date').nullable()();
  TextColumn get periodTemplateSetId =>
      text().named('period_template_set_id').nullable()();
  TextColumn get customPeriodsJson =>
      text().named('custom_periods_json').withDefault(const Constant('[]'))();
  TextColumn get currentStep =>
      text().named('current_step').withDefault(const Constant('profile'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {ownerUserId};
}

class CourseTemplatesCache extends Table {
  TextColumn get id => text()();
  TextColumn get universityId => text().named('university_id')();
  IntColumn get academicYear => integer().named('academic_year')();
  TextColumn get termId => text().named('term_id').nullable()();
  TextColumn get title => text()();
  TextColumn get normalizedTitle => text().named('normalized_title')();
  TextColumn get instructorName => text().named('instructor_name').nullable()();
  TextColumn get normalizedInstructorName =>
      text().named('normalized_instructor_name').nullable()();
  IntColumn get dayOfWeek => integer().named('day_of_week').nullable()();
  IntColumn get periodNo => integer().named('period_no').nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get normalizedRoom => text().named('normalized_room').nullable()();
  IntColumn get copyCountTotal =>
      integer().named('copy_count_total').withDefault(const Constant(0))();
  IntColumn get copyCountTerm =>
      integer().named('copy_count_term').withDefault(const Constant(0))();
  RealColumn get trustScore =>
      real().named('trust_score').withDefault(const Constant(0))();
  DateTimeColumn get cachedAt =>
      dateTime().named('cached_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class UserCourses extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get termId => text().named('term_id')();
  TextColumn get sourceTemplateId =>
      text().named('source_template_id').nullable()();
  TextColumn get title => text()();
  TextColumn get normalizedTitle => text().named('normalized_title')();
  TextColumn get instructorName => text().named('instructor_name').nullable()();
  TextColumn get normalizedInstructorName =>
      text().named('normalized_instructor_name').nullable()();
  IntColumn get dayOfWeek => integer().named('day_of_week').nullable()();
  IntColumn get periodNo => integer().named('period_no').nullable()();
  TextColumn get room => text().nullable()();
  TextColumn get color => text().nullable()();
  TextColumn get visibilityLevel =>
      text().named('visibility_level').withDefault(const Constant('PRIVATE'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Assignments extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get courseId => text().named('course_id').nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get submissionUrl => text().named('submission_url').nullable()();
  TextColumn get priority => text().nullable()();
  DateTimeColumn get dueAt => dateTime().named('due_at')();
  TextColumn get visibilityLevel =>
      text().named('visibility_level').withDefault(const Constant('PRIVATE'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AssignmentUserStates extends Table {
  TextColumn get assignmentId => text().named('assignment_id')();
  TextColumn get userId => text().named('user_id')();
  TextColumn get status => text().withDefault(const Constant('notStarted'))();
  DateTimeColumn get submittedAt =>
      dateTime().named('submitted_at').nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {assignmentId, userId};
}

class Exams extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get courseId => text().named('course_id').nullable()();
  TextColumn get title => text()();
  DateTimeColumn get startAt => dateTime().named('start_at')();
  DateTimeColumn get endAt => dateTime().named('end_at')();
  TextColumn get room => text().nullable()();
  TextColumn get scope => text().nullable()();
  TextColumn get memo => text().nullable()();
  TextColumn get examType => text().named('exam_type').nullable()();
  TextColumn get visibilityLevel =>
      text().named('visibility_level').withDefault(const Constant('PRIVATE'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Calendars extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get groupId => text().named('group_id').nullable()();
  TextColumn get name => text()();
  TextColumn get defaultVisibility => text()
      .named('default_visibility')
      .nullable()
      .withDefault(const Constant('PRIVATE'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Events extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get calendarId => text().named('calendar_id')();
  TextColumn get groupId => text().named('group_id').nullable()();
  TextColumn get title => text()();
  TextColumn get kind => text()();
  DateTimeColumn get startAt => dateTime().named('start_at')();
  DateTimeColumn get endAt => dateTime().named('end_at')();
  BoolColumn get isAllDay =>
      boolean().named('is_all_day').withDefault(const Constant(false))();
  TextColumn get location => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get rrule => text().nullable()();
  TextColumn get timezone => text().withDefault(const Constant('Asia/Tokyo'))();
  TextColumn get visibilityLevel => text()
      .named('visibility_level')
      .nullable()
      .withDefault(const Constant('PRIVATE'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class EventExceptions extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get eventId => text().named('event_id')();
  DateTimeColumn get recurrenceId => dateTime().named('recurrence_id')();
  TextColumn get mode => text()();
  DateTimeColumn get overrideStartAt =>
      dateTime().named('override_start_at').nullable()();
  DateTimeColumn get overrideEndAt =>
      dateTime().named('override_end_at').nullable()();
  TextColumn get overridePayloadJson =>
      text().named('override_payload_json').withDefault(const Constant('{}'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Device-local calendar display choices. These settings are intentionally
/// scoped to the signed-in owner and are never added to the sync queue.
class CalendarDisplayPreferences extends Table {
  TextColumn get ownerUserId => text().named('owner_user_id')();
  BoolColumn get showCourses =>
      boolean().named('show_courses').withDefault(const Constant(true))();
  BoolColumn get showAssignmentDeadlines => boolean()
      .named('show_assignment_deadlines')
      .withDefault(const Constant(true))();
  BoolColumn get showExams =>
      boolean().named('show_exams').withDefault(const Constant(true))();
  BoolColumn get showPersonalEvents => boolean()
      .named('show_personal_events')
      .withDefault(const Constant(true))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {ownerUserId};
}

class Friendships extends Table {
  TextColumn get id => text()();
  TextColumn get requesterUserId => text().named('requester_user_id')();
  TextColumn get addresseeUserId => text().named('addressee_user_id')();
  TextColumn get status => text()();
  TextColumn get visibilityLevel =>
      text().named('visibility_level').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get name => text()();
  TextColumn get type => text().withDefault(const Constant('other'))();
  TextColumn get defaultVisibility => text()
      .named('default_visibility')
      .withDefault(const Constant('TITLE_ONLY'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class GroupMembers extends Table {
  TextColumn get groupId => text().named('group_id')();
  TextColumn get userId => text().named('user_id')();
  TextColumn get role => text().withDefault(const Constant('member'))();
  TextColumn get visibilityLevel =>
      text().named('visibility_level').nullable()();
  DateTimeColumn get joinedAt =>
      dateTime().named('joined_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {groupId, userId};
}

class EventParticipants extends Table {
  TextColumn get eventId => text().named('event_id')();
  TextColumn get userId => text().named('user_id')();
  TextColumn get status => text().withDefault(const Constant('unanswered'))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {eventId, userId};
}

class EventComments extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text().named('event_id')();
  TextColumn get authorUserId => text().named('author_user_id')();
  TextColumn get body => text()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().named('deleted_at').nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class EventReactions extends Table {
  TextColumn get eventId => text().named('event_id')();
  TextColumn get userId => text().named('user_id')();
  TextColumn get reaction => text()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {eventId, userId, reaction};
}

/// Device cache of a provider connection. OAuth and provider credentials are
/// intentionally absent; the trusted server is the only credential boundary.
class EmailConnections extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get provider => text()();
  TextColumn get providerAccountHash => text().named('provider_account_hash')();
  TextColumn get accountHint => text().named('account_hint').nullable()();
  TextColumn get scopesJson =>
      text().named('scopes_json').withDefault(const Constant('[]'))();
  TextColumn get cursor => text().nullable()();
  TextColumn get state => text().withDefault(const Constant('disconnected'))();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  DateTimeColumn get retryAfter => dateTime().named('retry_after').nullable()();
  DateTimeColumn get lastSyncedAt =>
      dateTime().named('last_synced_at').nullable()();
  DateTimeColumn get disconnectedAt =>
      dateTime().named('disconnected_at').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Durable source metadata. Sanitized content itself is never stored here.
class EmailSources extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get connectionId => text()
      .named('connection_id')
      .references(EmailConnections, #id, onDelete: KeyAction.cascade)();
  TextColumn get providerMessageId => text().named('provider_message_id')();
  TextColumn get providerThreadId => text().named('provider_thread_id')();
  DateTimeColumn get receivedAt => dateTime().named('received_at')();
  TextColumn get sanitizedContentHash =>
      text().named('sanitized_content_hash')();
  TextColumn get evidenceExcerptsJson => text()
      .named('evidence_excerpts_json')
      .withDefault(const Constant('[]'))();
  TextColumn get processingState =>
      text().named('processing_state').withDefault(const Constant('pending'))();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {connectionId, providerMessageId},
      ];
}

/// Validated candidate payload and private review state. The JSON column is a
/// normalized schema-1.0 proposal, never a copy of the source message. A
/// failed row uses the content-free `{}` sentinel and is never decoded as a
/// proposal by the review store.
class EmailCandidates extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get sourceId => text()
      .named('source_id')
      .references(EmailSources, #id, onDelete: KeyAction.cascade)();
  TextColumn get schemaVersion => text().named('schema_version')();
  TextColumn get candidateType => text().named('candidate_type')();
  TextColumn get normalizedPayloadJson =>
      text().named('normalized_payload_json')();
  TextColumn get reviewState => text()
      .named('review_state')
      .withDefault(const Constant('needs_review'))();
  TextColumn get semanticFingerprint => text().named('semantic_fingerprint')();
  TextColumn get linkedEntityType =>
      text().named('linked_entity_type').nullable()();
  TextColumn get linkedEntityId =>
      text().named('linked_entity_id').nullable()();
  TextColumn get confirmationIdempotencyKey =>
      text().named('confirmation_idempotency_key').nullable()();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  BoolColumn get requiresUserConfirmation => boolean()
      .named('requires_user_confirmation')
      .withDefault(const Constant(true))();
  DateTimeColumn get confirmedAt =>
      dateTime().named('confirmed_at').nullable()();
  DateTimeColumn get dismissedAt =>
      dateTime().named('dismissed_at').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class EmailCandidateUpdates extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get candidateId => text()
      .named('candidate_id')
      .references(EmailCandidates, #id, onDelete: KeyAction.cascade)();
  TextColumn get sourceId => text()
      .named('source_id')
      .references(EmailSources, #id, onDelete: KeyAction.cascade)();
  TextColumn get fieldDiffJson => text().named('field_diff_json')();
  TextColumn get proposedPayloadJson => text().named('proposed_payload_json')();
  TextColumn get semanticFingerprint => text().named('semantic_fingerprint')();
  IntColumn get baseEntityVersion =>
      integer().named('base_entity_version').withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  TextColumn get resolutionIdempotencyKey =>
      text().named('resolution_idempotency_key').nullable()();
  DateTimeColumn get resolvedAt => dateTime().named('resolved_at').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Minimal dismissal memory. Raw provider identifiers, message content,
/// excerpts and normalized proposal JSON are deliberately not retained.
/// Provider/account and message/thread identities are irreversible hashes so
/// a dismissal survives reconnects without restoring the discarded payload.
class EmailDismissalTombstones extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get provider => text()();
  TextColumn get providerAccountHash => text().named('provider_account_hash')();
  TextColumn get providerMessageIdHash =>
      text().named('provider_message_id_hash')();
  TextColumn get providerThreadIdHash =>
      text().named('provider_thread_id_hash')();
  TextColumn get sanitizedContentHash =>
      text().named('sanitized_content_hash')();
  TextColumn get semanticFingerprint => text().named('semantic_fingerprint')();
  DateTimeColumn get dismissedAt => dateTime().named('dismissed_at')();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {
          ownerUserId,
          provider,
          providerAccountHash,
          providerMessageIdHash,
        },
        {
          ownerUserId,
          provider,
          providerAccountHash,
          providerThreadIdHash,
          sanitizedContentHash,
        },
        {
          ownerUserId,
          provider,
          providerAccountHash,
          providerThreadIdHash,
          semanticFingerprint,
        },
      ];
}

/// Durable, owner-scoped outbox for review decisions that must be
/// acknowledged by the trusted email-import endpoint. Provider identifiers
/// are retained only as account-domain-separated hashes; source bodies,
/// credentials, and raw provider identifiers are never stored here.
class EmailReconciliationReceipts extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get connectionId => text().named('connection_id')();
  TextColumn get action => text()();
  TextColumn get localReferenceId => text().named('local_reference_id')();
  TextColumn get provider => text()();
  TextColumn get providerAccountHash => text().named('provider_account_hash')();
  TextColumn get providerMessageIdHash =>
      text().named('provider_message_id_hash')();
  TextColumn get providerThreadIdHash =>
      text().named('provider_thread_id_hash')();
  TextColumn get sanitizedContentHash =>
      text().named('sanitized_content_hash')();
  TextColumn get reviewedPayloadJson =>
      text().named('reviewed_payload_json').nullable()();
  TextColumn get resolution => text().nullable()();
  TextColumn get entityType => text().named('entity_type').nullable()();
  TextColumn get entityId => text().named('entity_id').nullable()();
  TextColumn get idempotencyKey => text().named('idempotency_key')();
  TextColumn get requiredSyncMutationId =>
      text().named('required_sync_mutation_id').nullable()();
  DateTimeColumn get scheduleAckedAt =>
      dateTime().named('schedule_acked_at').nullable()();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount =>
      integer().named('attempt_count').withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt =>
      dateTime().named('next_retry_at').nullable()();
  DateTimeColumn get lastAttemptAt =>
      dateTime().named('last_attempt_at').nullable()();
  DateTimeColumn get reconciledAt =>
      dateTime().named('reconciled_at').nullable()();
  BoolColumn get replayed => boolean().nullable()();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {idempotencyKey},
        {ownerUserId, action, localReferenceId},
      ];
}

/// Private provenance from a confirmed email proposal to the user-owned
/// schedule entity it created. Deleting provider-derived cache data removes
/// this link but never cascades into the canonical schedule tables.
class EmailScheduleEntityLinks extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get sourceId => text()
      .named('source_id')
      .references(EmailSources, #id, onDelete: KeyAction.cascade)();
  TextColumn get candidateId => text()
      .named('candidate_id')
      .references(EmailCandidates, #id, onDelete: KeyAction.cascade)();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get confirmationIdempotencyKey =>
      text().named('confirmation_idempotency_key')();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {candidateId},
        {confirmationIdempotencyKey},
        {ownerUserId, entityType, entityId},
      ];
}

/// Content-free, append-only proof that an ordinary schedule edit advanced an
/// entity originally created from a confirmed email candidate. The hashes
/// authenticate the canonical entity payload before and after the edit without
/// retaining schedule content outside the canonical table or sync retention.
class EmailScheduleEditReceipts extends Table {
  TextColumn get mutationId => text().named('mutation_id')();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get candidateId => text()
      .named('candidate_id')
      .references(EmailCandidates, #id, onDelete: KeyAction.cascade)();
  TextColumn get linkId => text()
      .named('link_id')
      .references(EmailScheduleEntityLinks, #id, onDelete: KeyAction.cascade)();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get provenance => text()();
  IntColumn get baseEntityVersion => integer().named('base_entity_version')();
  IntColumn get entityVersion => integer().named('entity_version')();
  TextColumn get basePayloadFingerprint =>
      text().named('base_payload_fingerprint')();
  TextColumn get payloadFingerprint => text().named('payload_fingerprint')();
  TextColumn get candidatePayloadFingerprint =>
      text().named('candidate_payload_fingerprint')();
  DateTimeColumn get entityUpdatedAt => dateTime().named('entity_updated_at')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column<Object>> get primaryKey => {mutationId};
}

/// Owner-private metadata for a selected class document. Original filenames
/// and raw bytes are deliberately not persisted in Drift.
class DocumentSourcesCache extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get storagePath => text().named('storage_path').nullable()();
  TextColumn get mediaType => text().named('media_type')();
  IntColumn get byteSize => integer().named('byte_size')();
  TextColumn get contentHash => text().named('content_hash')();
  TextColumn get processingState => text()
      .named('processing_state')
      .withDefault(const Constant('selected'))();
  TextColumn get errorCategory => text().named('error_category').nullable()();
  IntColumn get candidateCount =>
      integer().named('candidate_count').withDefault(const Constant(0))();
  IntColumn get remoteVersion => integer().named('remote_version').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {ownerUserId, contentHash},
      ];
}

/// Strict normalized candidate JSON and local review state. This table is a
/// cache only; no canonical schedule row exists until explicit confirmation.
class DocumentCandidatesCache extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get sourceId => text()
      .named('source_id')
      .references(DocumentSourcesCache, #id, onDelete: KeyAction.cascade)();
  TextColumn get candidateKey => text().named('candidate_key')();
  TextColumn get remoteCandidateId =>
      text().named('remote_candidate_id').nullable()();
  TextColumn get schemaVersion => text().named('schema_version')();
  TextColumn get candidateType => text().named('candidate_type')();
  TextColumn get normalizedPayloadJson =>
      text().named('normalized_payload_json')();
  TextColumn get reviewState => text()
      .named('review_state')
      .withDefault(const Constant('needs_review'))();
  BoolColumn get isSelected =>
      boolean().named('is_selected').withDefault(const Constant(true))();
  TextColumn get courseId => text().named('course_id').nullable()();
  IntColumn get remoteVersion => integer().named('remote_version').nullable()();
  TextColumn get remoteSyncState =>
      text().named('remote_sync_state').withDefault(const Constant('synced'))();
  TextColumn get linkedEntityType =>
      text().named('linked_entity_type').nullable()();
  TextColumn get linkedEntityId =>
      text().named('linked_entity_id').nullable()();
  DateTimeColumn get confirmedAt =>
      dateTime().named('confirmed_at').nullable()();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {sourceId, candidateKey},
        {remoteCandidateId},
      ];
}

/// Private provenance from a confirmed document candidate to its canonical
/// schedule entity. Source deletion cascades through this link, never through
/// [Assignments] or [Exams], so user-created schedule data is retained.
class DocumentScheduleEntityLinks extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get sourceId => text()
      .named('source_id')
      .references(DocumentSourcesCache, #id, onDelete: KeyAction.cascade)();
  TextColumn get candidateCacheId => text()
      .named('candidate_cache_id')
      .references(DocumentCandidatesCache, #id, onDelete: KeyAction.cascade)();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get confirmationIdempotencyKey =>
      text().named('confirmation_idempotency_key')();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {candidateCacheId},
        {confirmationIdempotencyKey},
      ];
}

/// Durable request boundary consumed by the later platform-notification
/// phase. A row records the reviewed reminder policy atomically with the
/// entity, but does not claim that an OS notification has been scheduled.
class NotificationScheduleRequests extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get sourceType => text()
      .named('source_type')
      .withDefault(const Constant('email_confirmation'))();
  TextColumn get sourceId => text().named('source_id')();
  TextColumn get idempotencyKey => text().named('idempotency_key')();
  DateTimeColumn get anchorAt => dateTime().named('anchor_at')();
  BoolColumn get allDay =>
      boolean().named('all_day').withDefault(const Constant(false))();
  TextColumn get timezone => text().withDefault(const Constant('Asia/Tokyo'))();
  TextColumn get remindersMinutesJson => text()
      .named('reminders_minutes_json')
      .withDefault(const Constant('[]'))();
  TextColumn get targetPath => text().named('target_path')();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {idempotencyKey},
        {ownerUserId, entityType, entityId},
      ];
}

/// User-controlled policy for ordinary (non-morning-alarm) reminders.
///
/// This table deliberately remains separate from [NotificationScheduleRequests],
/// which is the reviewed email/document import boundary.  The settings are
/// additive and safe to sync because they contain no notification payload.
class LocalNotificationSettings extends Table {
  TextColumn get ownerUserId => text().named('owner_user_id')();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  BoolColumn get courseEnabled =>
      boolean().named('course_enabled').withDefault(const Constant(true))();
  BoolColumn get assignmentEnabled =>
      boolean().named('assignment_enabled').withDefault(const Constant(true))();
  BoolColumn get examEnabled =>
      boolean().named('exam_enabled').withDefault(const Constant(true))();
  BoolColumn get eventEnabled =>
      boolean().named('event_enabled').withDefault(const Constant(true))();
  BoolColumn get routineEnabled =>
      boolean().named('routine_enabled').withDefault(const Constant(true))();
  BoolColumn get personalEnabled =>
      boolean().named('personal_enabled').withDefault(const Constant(true))();
  IntColumn get courseReminderMinutes => integer()
      .named('course_reminder_minutes')
      .withDefault(const Constant(-10))();
  IntColumn get assignmentReminderMinutes => integer()
      .named('assignment_reminder_minutes')
      .withDefault(const Constant(-180))();
  IntColumn get examReminderMinutes => integer()
      .named('exam_reminder_minutes')
      .withDefault(const Constant(-10080))();
  IntColumn get eventReminderMinutes => integer()
      .named('event_reminder_minutes')
      .withDefault(const Constant(-60))();
  IntColumn get examDayHour =>
      integer().named('exam_day_hour').withDefault(const Constant(8))();
  IntColumn get examDayMinute =>
      integer().named('exam_day_minute').withDefault(const Constant(0))();
  IntColumn get quietStartMinutes =>
      integer().named('quiet_start_minutes').nullable()();
  IntColumn get quietEndMinutes =>
      integer().named('quiet_end_minutes').nullable()();
  // Notification tables are also read by Android's SQLite coordinator. Keep
  // these timestamps as epoch milliseconds explicitly instead of Drift's
  // DateTime mapping (which uses Unix seconds by default).
  IntColumn get updatedAt =>
      integer().named('updated_at').withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {ownerUserId};
}

/// Complete desired projection for the active owner.  OS alarm identities are
/// derived from [id] and [fingerprint]; [sourceEpoch] is a freshness fence.
class LocalNotificationOccurrences extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get kind => text()();
  TextColumn get sourceEntityId => text().named('source_entity_id')();
  IntColumn get occurrenceAt => integer().named('occurrence_at')();
  IntColumn get triggerAt => integer().named('trigger_at')();
  TextColumn get targetPath => text().named('target_path')();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get rule => text()();
  TextColumn get fingerprint => text()();
  IntColumn get sourceEpoch => integer().named('source_epoch')();
  IntColumn get projectionEpoch => integer().named('projection_epoch')();
  TextColumn get status => text().withDefault(const Constant('desired'))();
  TextColumn get reason => text().withDefault(const Constant('eligible'))();
  IntColumn get updatedAt =>
      integer().named('updated_at').withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {ownerUserId, fingerprint},
      ];
}

class LocalNotificationProjectionStates extends Table {
  TextColumn get ownerUserId => text().named('owner_user_id')();
  IntColumn get sourceEpoch => integer().named('source_epoch')();
  IntColumn get projectionEpoch => integer().named('projection_epoch')();
  BoolColumn get capped => boolean().withDefault(const Constant(false))();
  TextColumn get blockedReason => text().named('blocked_reason').nullable()();
  IntColumn get plannedAt =>
      integer().named('planned_at').withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {ownerUserId};
}

class SyncQueueEntries extends Table {
  TextColumn get clientMutationId => text().named('client_mutation_id')();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get idempotencyKey => text().named('idempotency_key').nullable()();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get operation => text()();
  TextColumn get payloadJson => text().named('payload_json')();
  IntColumn get baseVersion => integer().named('base_version').nullable()();
  IntColumn get serverVersion => integer().named('server_version').nullable()();
  TextColumn get serverPayloadJson =>
      text().named('server_payload_json').nullable()();
  IntColumn get conflictCursor =>
      integer().named('conflict_cursor').nullable()();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  IntColumn get enqueueSequence =>
      integer().named('enqueue_sequence').withDefault(const Constant(0))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount =>
      integer().named('attempt_count').withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt =>
      dateTime().named('next_retry_at').nullable()();
  DateTimeColumn get lastAttemptAt =>
      dateTime().named('last_attempt_at').nullable()();
  DateTimeColumn get claimedAt => dateTime().named('claimed_at').nullable()();
  DateTimeColumn get syncedAt => dateTime().named('synced_at').nullable()();

  /// Why a terminal `synced` row stopped being actionable. Only a trusted
  /// remote-applied acknowledgement may release dependent outbox work;
  /// choosing the server copy for a conflict is deliberately distinct.
  TextColumn get completionProvenance =>
      text().named('completion_provenance').nullable()();
  TextColumn get errorMessage => text().named('error_message').nullable()();

  @override
  Set<Column<Object>> get primaryKey => {clientMutationId};
}

/// A single durable counter used to assign causal ordering to local sync
/// mutations. Queue rows retain the assigned value after an app restart.
class SyncQueueSequenceStates extends Table {
  IntColumn get id => integer()();
  IntColumn get nextValue => integer().named('next_value')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class SyncCursors extends Table {
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get stream => text().withDefault(const Constant('schedule'))();
  IntColumn get cursor => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column<Object>> get primaryKey => {ownerUserId, stream};
}

class WidgetSnapshots extends Table {
  TextColumn get id => text()();
  TextColumn get ownerUserId => text().named('owner_user_id')();
  TextColumn get payloadJson => text().named('payload_json')();
  DateTimeColumn get generatedAt => dateTime().named('generated_at')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
