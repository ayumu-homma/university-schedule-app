import 'course_normalization.dart';
import 'enums.dart';
import 'japan_time.dart';
import 'models.dart';

class DemoData {
  static final normalizer = CourseNormalizer();

  static final university = University(
    id: 'demo-university',
    name: '東京サンプル大学',
    normalizedName: '東京サンプル大学',
    prefecture: '東京都',
    aliases: const ['サンプル大'],
    domainHints: const ['sample-u.ac.jp'],
  );

  static final term = Term(
    id: 'demo-term-2026-spring',
    universityId: university.id,
    name: '2026 前期',
    academicYear: 2026,
    startDate: DateTime(2026, 4, 1),
    endDate: DateTime(2026, 8, 7),
    termType: TermType.semester,
  );

  static final periodSettings = [
    for (var weekday = DateTime.monday;
        weekday <= DateTime.friday;
        weekday++) ...[
      PeriodSetting(
        id: 'period-$weekday-1',
        ownerUserId: 'demo-user',
        dayOfWeek: weekday,
        periodNo: 1,
        startTimeMinutes: 9 * 60,
        endTimeMinutes: 10 * 60 + 30,
      ),
      PeriodSetting(
        id: 'period-$weekday-2',
        ownerUserId: 'demo-user',
        dayOfWeek: weekday,
        periodNo: 2,
        startTimeMinutes: 10 * 60 + 40,
        endTimeMinutes: 12 * 60 + 10,
      ),
      PeriodSetting(
        id: 'period-$weekday-3',
        ownerUserId: 'demo-user',
        dayOfWeek: weekday,
        periodNo: 3,
        startTimeMinutes: 13 * 60,
        endTimeMinutes: 14 * 60 + 30,
      ),
      PeriodSetting(
        id: 'period-$weekday-4',
        ownerUserId: 'demo-user',
        dayOfWeek: weekday,
        periodNo: 4,
        startTimeMinutes: 14 * 60 + 40,
        endTimeMinutes: 16 * 60 + 10,
      ),
      PeriodSetting(
        id: 'period-$weekday-5',
        ownerUserId: 'demo-user',
        dayOfWeek: weekday,
        periodNo: 5,
        startTimeMinutes: 16 * 60 + 20,
        endTimeMinutes: 17 * 60 + 50,
      ),
    ],
  ];

  static final courseTemplates = [
    normalizer.normalizeTemplate(
      CourseTemplate(
        id: 'tmpl-algo-1',
        universityId: university.id,
        academicYear: 2026,
        termId: term.id,
        title: 'アルゴリズムとデータ構造Ⅰ',
        normalizedTitle: '',
        instructorName: '山田 太郎 教授',
        dayOfWeek: DateTime.monday,
        periodNo: 2,
        room: 'A101',
        copyCountTotal: 124,
        copyCountTerm: 31,
        trustScore: 8,
      ),
    ),
    normalizer.normalizeTemplate(
      CourseTemplate(
        id: 'tmpl-english',
        universityId: university.id,
        academicYear: 2026,
        termId: term.id,
        title: 'Academic English',
        normalizedTitle: '',
        instructorName: 'Suzuki Prof.',
        dayOfWeek: DateTime.tuesday,
        periodNo: 1,
        room: 'B203',
        copyCountTotal: 88,
        copyCountTerm: 22,
        trustScore: 5,
      ),
    ),
  ];

  static final userCourses = [
    UserCourse(
      id: 'course-algo',
      ownerUserId: 'demo-user',
      termId: term.id,
      title: 'アルゴリズムとデータ構造Ⅰ',
      normalizedTitle: normalizer.normalizeTitle('アルゴリズムとデータ構造Ⅰ'),
      sourceTemplateId: 'tmpl-algo-1',
      instructorName: '山田 太郎',
      dayOfWeek: DateTime.monday,
      periodNo: 2,
      room: 'A101',
      color: '#2F80ED',
      visibilityLevel: VisibilityLevel.titleOnly,
    ),
    UserCourse(
      id: 'course-english',
      ownerUserId: 'demo-user',
      termId: term.id,
      title: 'Academic English',
      normalizedTitle: normalizer.normalizeTitle('Academic English'),
      sourceTemplateId: 'tmpl-english',
      instructorName: 'Suzuki',
      dayOfWeek: DateTime.tuesday,
      periodNo: 1,
      room: 'B203',
      color: '#27AE60',
      visibilityLevel: VisibilityLevel.busyOnly,
    ),
  ];

  static final assignments = [
    Assignment(
      id: 'assignment-report-1',
      ownerUserId: 'demo-user',
      courseId: 'course-algo',
      title: '計算量レポート',
      dueAt: JapanTime.at(year: 2026, month: 7, day: 3, hour: 23, minute: 59),
      submissionUrl: 'https://lms.example.edu/assignments/1',
    ),
  ];

  static final exams = [
    Exam(
      id: 'exam-midterm-1',
      ownerUserId: 'demo-user',
      courseId: 'course-algo',
      title: '中間テスト',
      startAt:
          JapanTime.at(year: 2026, month: 7, day: 10, hour: 10, minute: 40),
      endAt: JapanTime.at(year: 2026, month: 7, day: 10, hour: 12, minute: 10),
      room: 'A101',
    ),
  ];

  static final events = [
    ScheduleEvent(
      id: 'event-club',
      ownerUserId: 'demo-user',
      calendarId: 'cal-personal',
      title: 'サークル定例',
      kind: EventKind.routine,
      startAt: JapanTime.at(year: 2026, month: 6, day: 29, hour: 18),
      endAt: JapanTime.at(year: 2026, month: 6, day: 29, hour: 20),
      location: '学生会館',
      recurrenceRule: const RecurrenceRule(
        frequency: RecurrenceFrequency.weekly,
        byWeekdays: [DateTime.monday],
      ),
      visibilityLevel: VisibilityLevel.titleOnly,
    ),
  ];
}
