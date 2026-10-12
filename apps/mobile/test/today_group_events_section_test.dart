import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';
import 'package:university_schedule_mobile/features/today/presentation/today_group_events_section.dart';

void main() {
  testWidgets('Today lists only current group events from joined groups',
      (tester) async {
    final repository = _TodayGroupRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(_localConfig),
        currentAuthSessionProvider.overrideWith(
          (ref) => const AppAuthSession(userId: 'member'),
        ),
        groupRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: SingleChildScrollView(
          child: TodayGroupEventsSection(
            rangeStart: DateTime.utc(2026, 10, 13, 15),
            rangeEnd: DateTime.utc(2026, 10, 14, 15),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('今日のグループ予定'), findsOneWidget);
    expect(find.text('Today group event'), findsOneWidget);
    expect(find.text('Tomorrow group event'), findsNothing);
    expect(find.text('Cancelled group event'), findsNothing);
    expect(find.textContaining('Study group'), findsOneWidget);
    expect(repository.listGroupsCalls, 1);
    expect(repository.listGroupEventsCalls, ['group-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed-out Today does not query group event RPCs',
      (tester) async {
    final repository = _TodayGroupRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(_localConfig),
        currentAuthSessionProvider.overrideWith((ref) => null),
        groupRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: TodayGroupEventsSection(
          rangeStart: DateTime.utc(2026, 10, 13, 15),
          rangeEnd: DateTime.utc(2026, 10, 14, 15),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('今日のグループ予定はありません。'), findsOneWidget);
    expect(repository.listGroupsCalls, 0);
    expect(repository.listGroupEventsCalls, isEmpty);
  });
}

final _localConfig = AppConfig.validated(
  environment: 'local',
  demoMode: false,
  supabaseUrl: 'http://127.0.0.1:54321',
  legacySupabaseAnonKey: 'synthetic-anon-placeholder',
);

class _TodayGroupRepository extends UnavailableGroupRepository {
  static const group = GroupSummary(
    id: 'group-a',
    name: 'Study group',
    ownerUserId: 'owner',
    type: GroupType.other,
  );

  int listGroupsCalls = 0;
  final listGroupEventsCalls = <String>[];

  @override
  Future<List<GroupSummary>> listGroups() async {
    listGroupsCalls++;
    return const [group];
  }

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async {
    listGroupEventsCalls.add(groupId);
    return [
      _event('today', groupId, DateTime.utc(2026, 10, 14, 1)),
      _event('tomorrow', groupId, DateTime.utc(2026, 10, 15, 1)),
      _event('cancelled', groupId, DateTime.utc(2026, 10, 14, 4),
          cancelled: true),
      _event('wrong-group', 'other-group', DateTime.utc(2026, 10, 14, 6)),
    ];
  }

  GroupEventSummary _event(
    String suffix,
    String groupId,
    DateTime startAt, {
    bool cancelled = false,
  }) =>
      GroupEventSummary(
        eventId: '$suffix-event',
        groupId: groupId,
        title: switch (suffix) {
          'today' => 'Today group event',
          'tomorrow' => 'Tomorrow group event',
          'cancelled' => 'Cancelled group event',
          _ => 'Wrong group event',
        },
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        createdBy: 'owner',
        version: 1,
        cancelled: cancelled,
      );
}
