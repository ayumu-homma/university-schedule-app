import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/course_template/application/course_template_providers.dart';
import 'package:university_schedule_mobile/features/course_template/presentation/course_search_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  testWidgets('failed template copy restores the action and permits one retry',
      (tester) async {
    _useTallViewport(tester);
    final repository = _FakeCourseTemplateRepository(deferCopies: true);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const CourseSearchScreen(),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (_, state) => Scaffold(
            body: Text('course:${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            AppConfig.validated(
              environment: 'test',
              demoMode: false,
              supabaseUrl: 'http://127.0.0.1:54321',
              supabasePublishableKey: 'test-publishable-key',
            ),
          ),
          activeScheduleContextProvider.overrideWithValue(_context),
          courseTemplateRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _pumpUntil(tester, find.text('分散システム'));

    await tester.tap(find.text('コピー'));
    await tester.pump();
    expect(repository.copyCalls, hasLength(1));
    expect(find.text('コピー'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    repository.copyCompleters.first.completeError(
      StateError('synthetic transient copy failure'),
    );
    await tester.pumpAndSettle();
    expect(find.text('授業テンプレートをコピーできませんでした'), findsOneWidget);
    expect(find.text('分散システム'), findsOneWidget);
    expect(find.text('コピー'), findsOneWidget);
    expect(repository.copyCalls, hasLength(1));

    await tester.tap(find.text('コピー'));
    await tester.pump();
    expect(repository.copyCalls, hasLength(2));
    expect(repository.copyCalls.last, (
      templateId: _template.id,
      ownerUserId: _context.ownerUserId,
      termId: _context.termId,
    ));
    repository.copyCompleters.last.complete('copied-course');
    await tester.pumpAndSettle();

    expect(find.text('course:copied-course'), findsOneWidget);
    expect(repository.copyCalls, hasLength(2));
  });

  testWidgets('uses the authenticated repository for search filters and copy',
      (tester) async {
    final repository = _FakeCourseTemplateRepository();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const CourseSearchScreen(
            initialWeekday: 1,
            initialPeriod: 2,
          ),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (_, state) => Scaffold(
            body: Text('course:${state.pathParameters['id']}'),
          ),
        ),
        GoRoute(
          path: '/courses/manual',
          builder: (_, __) => const Scaffold(body: Text('manual course')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/timetable',
          builder: (_, __) => const Scaffold(body: Text('timetable')),
        ),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const Scaffold(body: Text('assignments')),
        ),
        GoRoute(
          path: '/calendar',
          builder: (_, __) => const Scaffold(body: Text('calendar')),
        ),
        GoRoute(
          path: '/shared',
          builder: (_, __) => const Scaffold(body: Text('shared')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            AppConfig.validated(
              environment: 'test',
              demoMode: false,
              supabaseUrl: 'http://127.0.0.1:54321',
              supabasePublishableKey: 'test-publishable-key',
            ),
          ),
          activeScheduleContextProvider.overrideWithValue(_context),
          courseTemplateRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await _pumpUntil(tester, find.text('分散システム'));
    expect(repository.searches.single.weekday, 1);
    expect(repository.searches.single.period, 2);

    await tester.enterText(
      find.byKey(const Key('course-template-query')),
      '分散',
    );
    await tester.enterText(
      find.byKey(const Key('course-template-instructor')),
      '山田',
    );
    await tester.tap(find.byKey(const Key('course-template-search-submit')));
    await _pumpUntilCondition(
      tester,
      () => repository.searches.length >= 2,
    );
    await _pumpUntil(tester, find.text('コピー'));

    expect(repository.searches.last.query, '分散');
    expect(repository.searches.last.instructor, '山田');
    expect(repository.searches.last.universityId, _context.universityId);
    expect(repository.searches.last.academicYear, _context.academicYear);

    await tester.tap(find.text('コピー'));
    await _pumpUntil(tester, find.text('course:copied-course'));
    expect(repository.copyOwnerUserId, _context.ownerUserId);
    expect(repository.copyTermId, _context.termId);
  });

  testWidgets('shows server order and duplicate candidates without authors',
      (tester) async {
    tester.view.physicalSize = const Size(360, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeCourseTemplateRepository(
      templates: const [_template, _duplicateTemplate],
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const CourseSearchScreen(),
        ),
        GoRoute(
          path: '/course/:id',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/courses/manual',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/timetable',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/calendar',
          builder: (_, __) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/shared',
          builder: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            AppConfig.validated(
              environment: 'test',
              demoMode: false,
              supabaseUrl: 'http://127.0.0.1:54321',
              supabasePublishableKey: 'test-publishable-key',
            ),
          ),
          activeScheduleContextProvider.overrideWithValue(_context),
          courseTemplateRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    final searchList = find.byKey(const Key('course-template-search-list'));
    final searchScrollable = find
        .descendant(
          of: searchList,
          matching: find.byType(Scrollable),
        )
        .first;
    final searchSummary = find.text('同大学内の検索結果 2件（関連度・コピー数順）');
    await tester.scrollUntilVisible(
      searchSummary,
      180,
      scrollable: searchScrollable,
    );
    await tester.pump();
    expect(searchSummary, findsOneWidget);
    final lowerRankText = find.text('検索順位 2');
    if (lowerRankText.evaluate().isNotEmpty) {
      expect(
        tester.getRect(lowerRankText).top,
        greaterThan(tester.getRect(searchList).bottom),
      );
    } else {
      expect(lowerRankText, findsNothing);
    }
    final primaryCard = find.ancestor(
      of: find.text('検索順位 1'),
      matching: find.byType(Card),
    );
    await tester.scrollUntilVisible(
      primaryCard,
      180,
      scrollable: searchScrollable,
    );
    await tester.pump();
    expect(primaryCard, findsOneWidget);
    expect(
      find.descendant(
        of: primaryCard,
        matching: find.text(_template.title),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: primaryCard,
        matching: find.text('学期内コピー 4'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: primaryCard,
        matching: find.text('総コピー 12'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: primaryCard,
        matching: find.text('検索結果内の重複候補 2件'),
      ),
      findsOneWidget,
    );

    final duplicateCard = find.ancestor(
      of: lowerRankText,
      matching: find.byType(Card),
    );
    await tester.scrollUntilVisible(
      duplicateCard,
      180,
      scrollable: searchScrollable,
    );
    await tester.pump();
    expect(duplicateCard, findsOneWidget);
    expect(
      find.descendant(
        of: duplicateCard,
        matching: find.text('検索順位 2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: duplicateCard,
        matching: find.text(_duplicateTemplate.title),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: duplicateCard,
        matching: find.text('学期内コピー 3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: duplicateCard,
        matching: find.text('総コピー 8'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: duplicateCard,
        matching: find.text('検索結果内の重複候補 2件'),
      ),
      findsOneWidget,
    );
    expect(find.text('server-only-author'), findsNothing);
  });
}

const _context = ActiveScheduleContext(
  ownerUserId: '11111111-1111-4111-8111-111111111111',
  universityId: '22222222-2222-4222-8222-222222222222',
  termId: '33333333-3333-4333-8333-333333333333',
  academicYear: 2026,
  primaryCalendarId: '44444444-4444-4444-8444-444444444444',
);

class _SearchInvocation {
  const _SearchInvocation({
    required this.universityId,
    required this.academicYear,
    required this.query,
    required this.instructor,
    required this.weekday,
    required this.period,
  });

  final String universityId;
  final int academicYear;
  final String query;
  final String instructor;
  final int? weekday;
  final int? period;
}

class _FakeCourseTemplateRepository implements CourseTemplateRepository {
  _FakeCourseTemplateRepository({
    this.templates = const [_template],
    this.deferCopies = false,
  });

  final searches = <_SearchInvocation>[];
  final List<CourseTemplate> templates;
  final bool deferCopies;
  final copyCalls =
      <({String templateId, String ownerUserId, String termId})>[];
  final copyCompleters = <Completer<String>>[];
  String? copyOwnerUserId;
  String? copyTermId;

  @override
  Future<String> copyTemplate({
    required String templateId,
    required String ownerUserId,
    required String termId,
  }) async {
    expect(templateId, _template.id);
    copyOwnerUserId = ownerUserId;
    copyTermId = termId;
    copyCalls.add((
      templateId: templateId,
      ownerUserId: ownerUserId,
      termId: termId,
    ));
    if (deferCopies) {
      final completer = Completer<String>();
      copyCompleters.add(completer);
      return completer.future;
    }
    return 'copied-course';
  }

  @override
  Future<List<CourseTemplate>> searchTemplates({
    required String universityId,
    required int academicYear,
    String? termId,
    String query = '',
    String instructor = '',
    int? weekday,
    int? period,
  }) async {
    searches.add(
      _SearchInvocation(
        universityId: universityId,
        academicYear: academicYear,
        query: query,
        instructor: instructor,
        weekday: weekday,
        period: period,
      ),
    );
    return templates;
  }
}

const _template = CourseTemplate(
  id: '55555555-5555-4555-8555-555555555555',
  universityId: '22222222-2222-4222-8222-222222222222',
  academicYear: 2026,
  title: '分散システム',
  normalizedTitle: '分散システム',
  instructorName: '山田 太郎',
  normalizedInstructorName: '山田太郎',
  dayOfWeek: 1,
  periodNo: 2,
  copyCountTotal: 12,
  copyCountTerm: 4,
  duplicateKey: '分散システム:山田太郎:1:2',
  rankScore: 123.45,
);

const _duplicateTemplate = CourseTemplate(
  id: '66666666-6666-4666-8666-666666666666',
  universityId: '22222222-2222-4222-8222-222222222222',
  academicYear: 2026,
  title: '分散システム（別教室）',
  normalizedTitle: '分散システム別教室',
  instructorName: '山田 太郎',
  normalizedInstructorName: '山田太郎',
  dayOfWeek: 1,
  periodNo: 2,
  copyCountTotal: 8,
  copyCountTerm: 3,
  duplicateKey: '分散システム:山田太郎:1:2',
  rankScore: 120,
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for the expected widget.');
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Timed out waiting for the expected state.');
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
