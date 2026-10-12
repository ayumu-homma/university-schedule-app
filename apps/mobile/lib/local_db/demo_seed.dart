import 'package:drift/drift.dart';
import 'package:shared_domain/shared_domain.dart';

import 'app_database.dart';

class DriftDemoSeeder {
  const DriftDemoSeeder(this.db);

  final AppDatabase db;

  Future<void> seed() async {
    await db.batch((batch) {
      batch.insertAll(
          db.universities,
          [
            UniversitiesCompanion.insert(
              id: DemoData.university.id,
              name: DemoData.university.name,
              normalizedName: DemoData.university.normalizedName,
              prefecture: Value(DemoData.university.prefecture),
            ),
          ],
          mode: InsertMode.insertOrIgnore);
      batch.insertAll(
          db.terms,
          [
            TermsCompanion.insert(
              id: DemoData.term.id,
              universityId: DemoData.term.universityId,
              ownerUserId: const Value('demo-user'),
              name: DemoData.term.name,
              academicYear: DemoData.term.academicYear,
              startDate: DemoData.term.startDate,
              endDate: DemoData.term.endDate,
              termType: 'semester',
            ),
          ],
          mode: InsertMode.insertOrIgnore);
      batch.insertAll(
        db.periodSettings,
        [
          for (final setting in DemoData.periodSettings)
            PeriodSettingsCompanion.insert(
              id: setting.id,
              ownerUserId: setting.ownerUserId,
              universityId: DemoData.university.id,
              termId: DemoData.term.id,
              dayOfWeek: setting.dayOfWeek,
              periodNo: setting.periodNo,
              startTimeMinutes: setting.startTimeMinutes,
              endTimeMinutes: setting.endTimeMinutes,
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
        db.courseTemplatesCache,
        [
          for (final template in DemoData.courseTemplates)
            CourseTemplatesCacheCompanion.insert(
              id: template.id,
              universityId: template.universityId,
              academicYear: template.academicYear,
              termId: Value(template.termId),
              title: template.title,
              normalizedTitle: template.normalizedTitle,
              instructorName: Value(template.instructorName),
              normalizedInstructorName:
                  Value(template.normalizedInstructorName),
              dayOfWeek: Value(template.dayOfWeek),
              periodNo: Value(template.periodNo),
              room: Value(template.room),
              normalizedRoom: Value(template.normalizedRoom),
              copyCountTotal: Value(template.copyCountTotal),
              copyCountTerm: Value(template.copyCountTerm),
              trustScore: Value(template.trustScore.toDouble()),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
        db.userCourses,
        [
          for (final course in DemoData.userCourses)
            UserCoursesCompanion.insert(
              id: course.id,
              ownerUserId: course.ownerUserId,
              termId: course.termId,
              sourceTemplateId: Value(course.sourceTemplateId),
              title: course.title,
              normalizedTitle: course.normalizedTitle,
              instructorName: Value(course.instructorName),
              normalizedInstructorName: Value(course.normalizedInstructorName),
              dayOfWeek: Value(course.dayOfWeek),
              periodNo: Value(course.periodNo),
              room: Value(course.room),
              color: Value(course.color),
              visibilityLevel: Value(course.visibilityLevel.wireName),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
        db.assignments,
        [
          for (final assignment in DemoData.assignments)
            AssignmentsCompanion.insert(
              id: assignment.id,
              ownerUserId: assignment.ownerUserId,
              courseId: Value(assignment.courseId),
              title: assignment.title,
              description: Value(assignment.description),
              submissionUrl: Value(assignment.submissionUrl),
              dueAt: assignment.dueAt,
              visibilityLevel: Value(assignment.visibilityLevel.wireName),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
        db.assignmentUserStates,
        [
          for (final assignment in DemoData.assignments)
            AssignmentUserStatesCompanion.insert(
              assignmentId: assignment.id,
              userId: assignment.ownerUserId,
              status: const Value('notStarted'),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
        db.exams,
        [
          for (final exam in DemoData.exams)
            ExamsCompanion.insert(
              id: exam.id,
              ownerUserId: exam.ownerUserId,
              courseId: Value(exam.courseId),
              title: exam.title,
              startAt: exam.startAt,
              endAt: exam.endAt,
              room: Value(exam.room),
              scope: Value(exam.scope),
              visibilityLevel: Value(exam.visibilityLevel.wireName),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
      batch.insertAll(
          db.calendars,
          [
            CalendarsCompanion.insert(
              id: 'cal-personal',
              ownerUserId: 'demo-user',
              name: '個人予定',
              defaultVisibility: const Value('PRIVATE'),
            ),
          ],
          mode: InsertMode.insertOrIgnore);
      batch.insertAll(
        db.events,
        [
          for (final event in DemoData.events)
            EventsCompanion.insert(
              id: event.id,
              ownerUserId: event.ownerUserId,
              calendarId: event.calendarId,
              groupId: Value(event.groupId),
              title: event.title,
              kind: event.kind.name,
              startAt: event.startAt,
              endAt: event.endAt,
              location: Value(event.location),
              description: Value(event.description),
              rrule: Value(_encodeRecurrenceRule(event.recurrenceRule)),
              timezone: Value(event.timezone),
              visibilityLevel:
                  Value(event.visibilityLevel?.wireName ?? 'PRIVATE'),
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
  }

  String? _encodeRecurrenceRule(RecurrenceRule? rule) {
    if (rule == null || rule.frequency == RecurrenceFrequency.none) return null;
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
}
