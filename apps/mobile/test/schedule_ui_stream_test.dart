import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/timetable_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  testWidgets('direct repository writes update rendered timetable stream',
      (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    var idCounter = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'ui-${idCounter++}',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          activeScheduleContextProvider.overrideWithValue(
            demoScheduleContext,
          ),
          demoScheduleDataEnabledProvider.overrideWithValue(true),
        ],
        child: const MaterialApp(home: TimetableScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The responsive timetable defaults to the focused day view. Switch to
    // the complete week before asserting a write in another weekday.
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    final courseId = await repository.createUserCourse(
      ownerUserId: demoUserId,
      termId: demoTermId,
      input: const UserCourseInput(
        title: 'UIストリーム反映',
        dayOfWeek: DateTime.wednesday,
        periodNo: 3,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('UIストリーム反映'), findsOneWidget);
    final courseTitle = tester.widget<Text>(find.text('UIストリーム反映'));
    final titleContext = tester.element(find.text('UIストリーム反映'));
    expect(
      courseTitle.style?.color,
      Theme.of(titleContext).colorScheme.onPrimaryContainer,
    );

    await repository.deleteUserCourse(
      courseId: courseId,
      ownerUserId: demoUserId,
      expectedVersion: 1,
    );
    await tester.pumpAndSettle();

    expect(find.text('UIストリーム反映'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });
}
