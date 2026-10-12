import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/availability/presentation/availability_screen.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/supabase_friend_repository.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'long Japanese names and 1.5x text scale keep controls and results reachable',
    (tester) async {
      final repository = _ScreenRepository();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.5),
          ),
          child: ProviderScope(
            overrides: [
              currentAuthSessionProvider.overrideWithValue(
                const AppAuthSession(userId: 'viewer'),
              ),
              friendRepositoryProvider.overrideWithValue(repository),
              appClockProvider.overrideWithValue(_ScreenClock()),
            ],
            child: const MaterialApp(home: AvailabilityScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('availability-start')), findsOneWidget);
      expect(find.byKey(const Key('availability-end')), findsOneWidget);
      final caveat = find.textContaining('他の参加者の非公開予定は結果に含めません');
      expect(caveat, findsOneWidget);
      final friendKey = find.byKey(const Key('availability-friend-friend'));
      await tester.drag(
        find.byKey(const Key('availability-content')),
        const Offset(0, -500),
      );
      await tester.pump();
      expect(friendKey, findsOneWidget);
      await tester.ensureVisible(friendKey);
      await tester.tap(friendKey);
      await tester.pump();

      final search = find.byKey(const Key('availability-search'));
      await tester.ensureVisible(search);
      expect(find.byKey(const Key('availability-start')), findsOneWidget);
      expect(find.byKey(const Key('availability-end')), findsOneWidget);
      expect(find.byKey(const Key('availability-minimum-duration')),
          findsOneWidget);
      await tester.tap(search);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('候補時間'));
      expect(find.text('候補時間'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ScreenClock implements AppClock {
  @override
  DateTime now() => DateTime.utc(2026, 6, 29, 1);
}

class _ScreenRepository extends UnavailableFriendRepository {
  @override
  Future<List<FriendRelationship>> listRelationships() async => [
        const FriendRelationship(
          id: 'friendship',
          otherUserId: 'friend',
          otherDisplayName: 'とても長い日本語の友だち表示名がここに入ります',
          status: FriendshipStatus.accepted,
        ),
      ];

  @override
  Future<List<FriendTerm>> listFriendTerms(String friendUserId) async => [
        FriendTerm(
          id: 'term-$friendUserId',
          name: '2026年度前期',
          academicYear: 2026,
          startDate: DateTime.utc(2026, 4, 1),
          endDate: DateTime.utc(2026, 9, 30),
        ),
      ];

  @override
  Future<FriendScheduleSnapshot> fetchSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async =>
      const FriendScheduleSnapshot(
        allowed: true,
        revision: 'screen',
        rows: [],
      );
}
