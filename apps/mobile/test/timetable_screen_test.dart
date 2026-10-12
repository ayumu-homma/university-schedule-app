import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/app/theme/app_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/features/timetable/presentation/timetable_screen.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  testWidgets(
    '日表示は360dp・大きな文字で時間と明示操作を保つ',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = local.AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpTimetable(
        tester,
        db,
        textScale: 1.3,
        // Sunday 16:00 UTC is Monday 01:00 in Japan.
        now: DateTime.utc(2026, 8, 9, 16),
      );

      expect(find.byKey(const Key('timetable-day-view')), findsOneWidget);
      expect(find.textContaining('09:00'), findsOneWidget);
      expect(find.textContaining('〜 10:30'), findsOneWidget);
      expect(find.text('アルゴリズムとデータ構造Ⅰ'), findsOneWidget);
      expect(
        find.byTooltip('アルゴリズムとデータ構造Ⅰの操作'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('日表示の初期曜日は注入時計をJSTへ変換して選ぶ', (tester) async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpTimetable(
      tester,
      db,
      // Monday 16:00 UTC is Tuesday 01:00 in Japan.
      now: DateTime.utc(2026, 8, 10, 16),
    );

    final tuesday = find.byKey(const ValueKey<String>('timetable-day-2'));
    expect(tuesday, findsOneWidget);
    expect(tester.widget<ChoiceChip>(tuesday).selected, isTrue);
    expect(find.text('Academic English'), findsOneWidget);
    expect(find.text('アルゴリズムとデータ構造Ⅰ'), findsNothing);
  });

  testWidgets('週表示は横スクロールなしで空きコマを追加操作にする', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpTimetable(tester, db);
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('timetable-week-view')), findsOneWidget);
    final horizontalScrollables =
        tester.widgetList<Scrollable>(find.byType(Scrollable)).where(
              (widget) =>
                  widget.axisDirection == AxisDirection.left ||
                  widget.axisDirection == AxisDirection.right,
            );
    expect(horizontalScrollables, isEmpty);
    expect(find.text('空き'), findsNothing);
    expect(
      find.bySemanticsLabel('月曜日 1限に授業を追加'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('週表示は授業名を中央に縮小し教室を下部pillに表示する', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpTimetable(
      tester,
      db,
      textScale: 1.3,
      courses: [
        _course(
            id: 'room-course',
            title: '長い授業タイトルの折返し確認用テキスト',
            room: '  23号館 218教室  '),
        _course(id: 'null-room-course', title: '教室なし', weekday: 2),
        _course(
          id: 'empty-room-course',
          title: '空文字教室',
          weekday: 3,
          room: '',
        ),
        _course(
          id: 'blank-room-course',
          title: '空白教室',
          weekday: 4,
          room: ' \t ',
        ),
      ],
      assignments: [
        Assignment(
          id: 'room-assignment',
          ownerUserId: 'test-user',
          title: '提出物',
          dueAt: DateTime.utc(2026, 8, 12),
          courseId: 'room-course',
        ),
      ],
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    final title = tester.widget<Text>(find.text('長い授業タイトルの折返し確認用テキスト'));
    expect(title.textAlign, TextAlign.center);
    expect(title.maxLines, 4);
    expect(title.style!.fontSize, lessThan(14));
    final roomFinder =
        find.byKey(const ValueKey('week-course-room-room-course'));
    expect(roomFinder, findsOneWidget);
    expect(tester.widget<Text>(roomFinder).data, '23号館 218教室');
    final roomRect = tester.getRect(
      find.byKey(const ValueKey('week-course-room-pill-room-course')),
    );
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('week-course-cell-room-course')),
    );
    expect(roomRect.width, cardRect.width - 8);
    expect(roomRect.center.dx, closeTo(cardRect.center.dx, 0.01));
    expect(cardRect.bottom - roomRect.bottom, lessThanOrEqualTo(12));
    expect(
      find.byKey(const ValueKey('week-course-room-null-room-course')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('week-course-room-empty-room-course')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('week-course-room-blank-room-course')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('empty-course-cell-1-2')), findsOneWidget);
    expect(find.text('● 1'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('課題1件、試験0件')),
      findsOneWidget,
    );
    await tester.tap(
      find.byTooltip('長い授業タイトルの折返し確認用テキストの操作'),
    );
    await tester.pumpAndSettle();
    expect(find.text('詳細を見る'), findsOneWidget);
    expect(find.text('編集'), findsOneWidget);
    expect(find.text('削除'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('週表示の長いタイトルは412dpとtablet darkでも安定する', (tester) async {
    for (final size in const [Size(412, 900), Size(1024, 1200)]) {
      await tester.binding.setSurfaceSize(size);
      final db = local.AppDatabase(NativeDatabase.memory());

      await _pumpTimetable(
        tester,
        db,
        textScale: 1.5,
        dark: size.width > 500,
        courses: [
          _course(
            id: 'long-title',
            title: 'とても長い授業名が狭い時間割セルの中で複数行にわたって自然に表示されることを確認する',
            room: '23・218',
          ),
        ],
      );
      await tester.tap(find.text('週全体'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('week-course-room-long-title')),
          findsOneWidget);
      expect(find.byTooltip('とても長い授業名が狭い時間割セルの中で複数行にわたって自然に表示されることを確認する'),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('empty-course-cell-1-2')), findsOneWidget);
      final longTitleCard = tester.getRect(
        find.byKey(const ValueKey('week-course-cell-long-title')),
      );
      expect(longTitleCard.height, greaterThan(124));
      final roomPillRect = tester.getRect(
        find.byKey(const ValueKey('week-course-room-pill-long-title')),
      );
      expect(roomPillRect.center.dx, closeTo(longTitleCard.center.dx, 0.01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await db.close();
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('実アプリthemeの412dp幅で教室番号を省略せず表示する', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _pumpTimetable(
      tester,
      db,
      courses: [_course(id: 'full-room', title: '情報セキュリティ', room: '23・218')],
    );
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();
    final room = find.byKey(const ValueKey('week-course-room-full-room'));
    expect(tester.widget<Text>(room).data, '23・218');
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('week-course-cell-full-room')),
    );
    final pillRect = tester.getRect(
      find.byKey(const ValueKey('week-course-room-pill-full-room')),
    );
    expect(pillRect.center.dx, closeTo(cardRect.center.dx, 0.01));
    expect(tester.getRect(room).center.dx, closeTo(cardRect.center.dx, 0.01));
    expect(
        tester.renderObject<RenderParagraph>(room).didExceedMaxLines, isFalse);
    expect(
      tester.getRect(room).width,
      lessThanOrEqualTo(tester
          .getRect(find.byKey(
            const ValueKey('week-course-room-pill-full-room'),
          ))
          .width),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('週表示はtablet幅とdark themeで使用できる', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpTimetable(tester, db, dark: true);
    await tester.tap(find.text('週全体'));
    await tester.pumpAndSettle();

    expect(find.text('Academic English'), findsOneWidget);
    expect(find.byKey(const Key('timetable-week-view')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('時間割の読み込み失敗は内部例外を表示しない', (tester) async {
    const internalDetail =
        'service_role=super-secret-internal-diagnostic-payload';
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpTimetable(
      tester,
      db,
      controller: _FailingDemoAppController(
        StateError(internalDetail),
      ),
    );

    expect(find.byKey(const Key('timetable-load-error')), findsOneWidget);
    expect(find.text('時間割を読み込めませんでした'), findsOneWidget);
    expect(find.textContaining(internalDetail), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });
}

Future<void> _pumpTimetable(
  WidgetTester tester,
  local.AppDatabase db, {
  double textScale = 1,
  bool dark = false,
  DateTime? now,
  DemoAppController? controller,
  List<UserCourse>? courses,
  List<Assignment>? assignments,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        activeScheduleContextProvider.overrideWithValue(demoScheduleContext),
        demoScheduleDataEnabledProvider.overrideWithValue(true),
        appClockProvider.overrideWithValue(
          _FixedAppClock(now ?? DateTime.utc(2026, 8, 10, 16)),
        ),
        if (controller != null || courses != null)
          demoAppControllerProvider.overrideWith(
            () =>
                controller ??
                _FixedDemoAppController(
                  DemoAppState.empty(now: now ?? DateTime.utc(2026, 8, 10, 16))
                      .copyWith(
                    courses: courses!,
                    assignments: assignments ?? const [],
                  ),
                ),
          ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const TimetableScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

UserCourse _course({
  required String id,
  required String title,
  int weekday = 1,
  String? room,
}) =>
    UserCourse(
      id: id,
      ownerUserId: 'test-user',
      termId: 'test-term',
      title: title,
      normalizedTitle: title.toLowerCase(),
      dayOfWeek: weekday,
      periodNo: 1,
      room: room,
    );

class _FixedDemoAppController extends DemoAppController {
  _FixedDemoAppController(this.value);

  final DemoAppState value;

  @override
  Stream<DemoAppState> build() => Stream.value(value);
}

class _FailingDemoAppController extends DemoAppController {
  _FailingDemoAppController(this.failure);

  final Object failure;

  @override
  Stream<DemoAppState> build() => Stream.error(failure);
}

class _FixedAppClock implements AppClock {
  const _FixedAppClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}
