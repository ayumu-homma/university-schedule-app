import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:university_schedule_mobile/core/sync/sync_queue.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/exam/presentation/exam_list_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';

void main() {
  final now = _jst(2026, 8, 10, 10);

  testWidgets('テストを今日・今週・それ以降・終了済みに分ける', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _state(
      now: now,
      exams: [
        _exam('past', '終了した小テスト', _jst(2026, 8, 10, 8)),
        _exam('today', '今日の中間試験', _jst(2026, 8, 10, 15)),
        _exam('week', '今週の発表', _jst(2026, 8, 12, 13)),
        _exam('later', '来週以降の期末試験', _jst(2026, 8, 20, 11)),
      ],
    );

    await tester.pumpWidget(_testApp(state: state, now: now));
    await tester.pumpAndSettle();

    expect(find.text('今日のテスト（1件）'), findsOneWidget);
    expect(find.text('今週のテスト（1件）'), findsOneWidget);
    expect(find.text('それ以降のテスト（1件）'), findsOneWidget);
    expect(find.text('終了したテスト（1件）'), findsOneWidget);
    expect(find.text('今日の中間試験'), findsOneWidget);
    expect(find.text('来週以降の期末試験'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空状態は追加アクションと説明を示す', (tester) async {
    await tester.pumpWidget(_testApp(state: _state(now: now), now: now));
    await tester.pumpAndSettle();

    expect(find.text('テストはまだありません'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'テストを作成'), findsOneWidget);
  });
}

Widget _testApp({required DemoAppState state, required DateTime now}) {
  return ProviderScope(
    overrides: [
      appClockProvider.overrideWithValue(_FixedClock(now)),
      demoAppControllerProvider.overrideWith(
        () => _TestDemoAppController(state),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const ExamListScreen(),
    ),
  );
}

class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

class _TestDemoAppController extends DemoAppController {
  _TestDemoAppController(this.initialState);

  final DemoAppState initialState;

  @override
  Stream<DemoAppState> build() => Stream.value(initialState);
}

DateTime _jst(int year, int month, int day, [int hour = 0, int minute = 0]) =>
    JapanTime.at(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
    );

Exam _exam(String id, String title, DateTime startAt) => Exam(
      id: id,
      ownerUserId: 'student',
      title: title,
      startAt: startAt,
      endAt: startAt.add(const Duration(minutes: 90)),
      room: 'A101',
    );

DemoAppState _state({
  required DateTime now,
  List<Exam> exams = const [],
}) {
  return DemoAppState(
    templates: const [],
    periodSettings: const [],
    courses: const [],
    assignments: const [],
    assignmentStates: const {},
    exams: exams,
    events: const [],
    eventExceptions: const [],
    calendarItems: const [],
    widgetSnapshot: WidgetSnapshot.empty(now),
    pendingMutations: const [],
    syncQueueCounts: const SyncQueueCounts(pending: 0, synced: 0, failed: 0),
  );
}
