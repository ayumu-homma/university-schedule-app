import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/time/app_clock.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../data/supabase_course_template_repository.dart';

class CourseTemplateSearchFilter {
  const CourseTemplateSearchFilter({
    this.query = '',
    this.instructor = '',
    this.weekday,
    this.period,
  });

  final String query;
  final String instructor;
  final int? weekday;
  final int? period;

  @override
  bool operator ==(Object other) {
    return other is CourseTemplateSearchFilter &&
        other.query == query &&
        other.instructor == instructor &&
        other.weekday == weekday &&
        other.period == period;
  }

  @override
  int get hashCode => Object.hash(query, instructor, weekday, period);
}

final courseTemplateRepositoryProvider = Provider<CourseTemplateRepository>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  if (config.demoMode) {
    return ref.watch(scheduleRepositoryProvider);
  }

  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    throw StateError(
      'SupabaseClient is unavailable for the production course catalog.',
    );
  }
  final context = ref.watch(requiredActiveScheduleContextProvider);
  return SupabaseCourseTemplateRepository(
    client: client,
    db: ref.watch(appDatabaseProvider),
    context: context,
    clock: ref.watch(appClockProvider).now,
    offlineFirst: true,
  );
});

final courseTemplateSearchProvider = FutureProvider.autoDispose
    .family<List<CourseTemplate>, CourseTemplateSearchFilter>((ref, filter) {
  final context = ref.watch(requiredActiveScheduleContextProvider);
  return ref.watch(courseTemplateRepositoryProvider).searchTemplates(
        universityId: context.universityId,
        academicYear: context.academicYear,
        query: filter.query,
        instructor: filter.instructor,
        weekday: filter.weekday,
        period: filter.period,
      );
});
