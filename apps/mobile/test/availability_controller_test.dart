import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/time/app_clock.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/availability/application/availability_controller.dart';
import 'package:university_schedule_mobile/features/availability/domain/availability_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/supabase_friend_repository.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('self and multiple accepted friends produce common windows', () async {
    final repository = _AvailabilityRepository();
    final container = _container(repository);
    addTearDown(container.dispose);

    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a', 'friend-b']);
    controller.setDate(DateTime.utc(2026, 6, 29));
    controller.setStartMinutes(9 * 60);
    controller.setEndMinutes(12 * 60);
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.status, AvailabilityStatus.success);
    expect(state.windows.map((window) => window.duration), [
      const Duration(hours: 1),
    ]);
    expect(repository.fetchedOwners, ['viewer', 'friend-a', 'friend-b']);
  });

  test('self PRIVATE blocks own time while friend PRIVATE stays redacted',
      () async {
    final repository = _AvailabilityRepository()
      ..selfVisibility = VisibilityLevel.private
      ..friendAVisibility = VisibilityLevel.private;
    final container = _container(repository);
    addTearDown(container.dispose);

    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    controller.setDate(DateTime.utc(2026, 6, 29));
    controller.setStartMinutes(9 * 60);
    controller.setEndMinutes(12 * 60);
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.status, AvailabilityStatus.success);
    expect(state.windows.map((window) => window.duration), [
      const Duration(hours: 1),
      const Duration(hours: 1),
    ]);
    expect(state.windows.first.startAt.hour, 0);
    expect(state.windows.last.startAt.hour, 2);
    expect(repository.fetchedOwners, ['viewer', 'friend-a']);
  });

  test('invalid ranges retain inputs and expose actionable validation',
      () async {
    final container = _container(_AvailabilityRepository());
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setStartMinutes(18 * 60);
    controller.setEndMinutes(9 * 60);
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.errorKind, AvailabilityErrorKind.validation);
    expect(state.startMinutes, 18 * 60);
    expect(state.endMinutes, 9 * 60);
    expect(state.errorMessage, contains('終了時刻'));
  });

  test('valid conditions require at least one accepted friend', () async {
    final container = _container(_AvailabilityRepository());
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.errorKind, AvailabilityErrorKind.validation);
    expect(state.errorMessage, contains('少なくとも1人'));
  });

  test('retry after a search error reruns the same search', () async {
    final repository = _AvailabilityRepository()..failFetch = true;
    final container = _container(repository);
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    await controller.search();
    expect(
      container.read(availabilityControllerProvider).requireValue.errorKind,
      AvailabilityErrorKind.network,
    );
    final fetchedBeforeRetry = repository.fetchCount;
    repository.failFetch = false;
    await controller.retry();
    final state = container.read(availabilityControllerProvider).requireValue;
    expect(repository.fetchCount, greaterThan(fetchedBeforeRetry));
    expect(state.status, AvailabilityStatus.success);
    expect(state.selectedFriendIds, {'friend-a'});
  });

  test('minimum duration cannot exceed the selected search range', () async {
    final container = _container(_AvailabilityRepository());
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    controller.setStartMinutes(9 * 60);
    controller.setEndMinutes(10 * 60);
    controller.setMinimumDurationMinutes(120);
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.errorKind, AvailabilityErrorKind.validation);
    expect(state.errorMessage, contains('検索範囲以内'));
  });

  test('term boundaries preserve JST civil dates from backend instants',
      () async {
    final repository = _AvailabilityRepository()
      ..termStart = DateTime.utc(2026, 6, 28, 15)
      ..termEnd = DateTime.utc(2026, 6, 29, 14, 59);
    final container = _container(repository);
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    controller.setDate(DateTime.utc(2026, 6, 29));
    await controller.search();

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.status, AvailabilityStatus.success);
    expect(repository.termLookups, contains('friend-a'));
  });

  test(
      'relationship revision loss during fetch fails closed and intersects selection',
      () async {
    final repository = _AvailabilityRepository();
    final held = Completer<FriendScheduleSnapshot>();
    repository.held = held;
    final container = _container(repository);
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a', 'friend-b']);
    final search = controller.search();
    await _until(() => repository.fetchedOwners.isNotEmpty);
    repository.relationshipResponses = [
      _relationships(revisionA: 2, includeFriendB: false),
      _relationships(revisionA: 2, includeFriendB: false),
    ];
    held.complete(_snapshot('released', 1, 2));
    await search;

    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.errorKind, AvailabilityErrorKind.authorization);
    expect(state.windows, isEmpty);
    expect(state.friends.map((friend) => friend.otherUserId), ['friend-a']);
    expect(state.selectedFriendIds, {'friend-a'});
  });

  test('auto-dispose clears results when availability screen is re-entered',
      () async {
    final repository = _AvailabilityRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'viewer'),
      ),
      friendRepositoryProvider.overrideWithValue(repository),
      appClockProvider.overrideWithValue(_FixedClock()),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(
      availabilityControllerProvider,
      (_, __) {},
      fireImmediately: false,
    );
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    await controller.search();
    expect(
      container.read(availabilityControllerProvider).requireValue.status,
      AvailabilityStatus.success,
    );

    subscription.close();
    await Future<void>.delayed(Duration.zero);
    final fresh = await container.read(availabilityControllerProvider.future);
    expect(fresh.selectedFriendIds, isEmpty);
    expect(fresh.windows, isEmpty);
  });

  test('app resume invalidation clears displayed results but retains inputs',
      () async {
    final container = _container(_AvailabilityRepository());
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    controller.setStartMinutes(10 * 60);
    await controller.search();
    expect(
      container.read(availabilityControllerProvider).requireValue.status,
      AvailabilityStatus.success,
    );

    controller.onAppResumed();
    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.status, AvailabilityStatus.ready);
    expect(state.windows, isEmpty);
    expect(state.hasSearched, isFalse);
    expect(state.startMinutes, 10 * 60);
    expect(state.selectedFriendIds, {'friend-a'});
  });

  test('authorization lease clears a displayed result without polling',
      () async {
    final container = _container(
      _AvailabilityRepository(),
      leaseDuration: const Duration(milliseconds: 20),
    );
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    await controller.search();
    expect(
      container.read(availabilityControllerProvider).requireValue.status,
      AvailabilityStatus.success,
    );

    await _until(() => container
        .read(availabilityControllerProvider)
        .requireValue
        .windows
        .isEmpty);
    final state = container.read(availabilityControllerProvider).requireValue;
    expect(state.status, AvailabilityStatus.ready);
    expect(state.hasSearched, isFalse);
  });

  test('late response cannot overwrite newer conditions', () async {
    final repository = _AvailabilityRepository();
    final held = Completer<FriendScheduleSnapshot>();
    repository.held = held;
    final container = _container(repository);
    addTearDown(container.dispose);
    final controller = container.read(availabilityControllerProvider.notifier);
    await container.read(availabilityControllerProvider.future);
    controller.setSelectedFriends(['friend-a']);
    final oldSearch = controller.search();
    await _until(() => repository.fetchedOwners.isNotEmpty);
    controller.setEndMinutes(10 * 60);
    repository.held = null;
    await controller.search();
    final current = container.read(availabilityControllerProvider).requireValue;
    held.complete(_snapshot('late', 9, 10));
    await oldSearch;

    final finalState =
        container.read(availabilityControllerProvider).requireValue;
    expect(finalState.endMinutes, 10 * 60);
    expect(finalState.windows, isNotEmpty);
    expect(finalState.windows.single.endAt.hour, 1);
    expect(current.endMinutes, 10 * 60);
  });
}

ProviderContainer _container(
  _AvailabilityRepository repository, {
  Duration leaseDuration = const Duration(seconds: 60),
}) {
  final container = ProviderContainer(overrides: [
    currentAuthSessionProvider.overrideWithValue(
      const AppAuthSession(userId: 'viewer'),
    ),
    friendRepositoryProvider.overrideWithValue(repository),
    appClockProvider.overrideWithValue(_FixedClock()),
    friendAuthorizationLeaseDurationProvider.overrideWithValue(leaseDuration),
  ]);
  container.listen(availabilityControllerProvider, (_, __) {},
      fireImmediately: false);
  return container;
}

List<FriendRelationship> _relationships({
  int revisionA = 1,
  bool includeFriendB = true,
}) =>
    [
      FriendRelationship(
        id: 'a',
        otherUserId: 'friend-a',
        otherDisplayName: 'A',
        status: FriendshipStatus.accepted,
        incarnation: 'incarnation-a',
        revision: revisionA,
      ),
      if (includeFriendB)
        const FriendRelationship(
          id: 'b',
          otherUserId: 'friend-b',
          otherDisplayName: 'B',
          status: FriendshipStatus.accepted,
          incarnation: 'incarnation-b',
          revision: 1,
        ),
    ];

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

class _FixedClock implements AppClock {
  @override
  DateTime now() => DateTime.utc(2026, 6, 29, 1);
}

class _AvailabilityRepository extends UnavailableFriendRepository {
  final fetchedOwners = <String>[];
  final termLookups = <String>[];
  Completer<FriendScheduleSnapshot>? held;
  bool failFetch = false;
  int fetchCount = 0;
  VisibilityLevel selfVisibility = VisibilityLevel.busyOnly;
  VisibilityLevel friendAVisibility = VisibilityLevel.busyOnly;
  DateTime termStart = DateTime.utc(2026, 4, 1);
  DateTime termEnd = DateTime.utc(2026, 9, 30);
  List<List<FriendRelationship>> relationshipResponses = [];

  @override
  Future<List<FriendRelationship>> listRelationships() async {
    if (relationshipResponses.isNotEmpty) {
      return relationshipResponses.removeAt(0);
    }
    return _relationships();
  }

  @override
  Future<List<FriendTerm>> listFriendTerms(String friendUserId) async {
    termLookups.add(friendUserId);
    return [
      FriendTerm(
        id: 'term-$friendUserId',
        name: 'Spring',
        academicYear: 2026,
        startDate: termStart,
        endDate: termEnd,
      ),
    ];
  }

  @override
  Future<FriendScheduleSnapshot> fetchSchedule({
    required String friendUserId,
    required String termId,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) async {
    fetchedOwners.add(friendUserId);
    fetchCount++;
    if (failFetch) throw const NetworkError('一時的な通信エラー');
    final wait = held;
    if (wait != null) return wait.future;
    if (friendUserId == 'viewer') {
      return _snapshot('self', 1, 2, visibility: selfVisibility);
    }
    if (friendUserId == 'friend-a') {
      return _snapshot('a', 2, 2, visibility: friendAVisibility);
    }
    return _snapshot('b', 0, 1);
  }
}

FriendScheduleSnapshot _snapshot(
  String id,
  int startHour,
  int endHour, {
  VisibilityLevel visibility = VisibilityLevel.busyOnly,
}) =>
    FriendScheduleSnapshot(
      allowed: true,
      revision: id,
      rows: [
        FriendSharedEvent(
          eventId: id,
          ownerUserId: id,
          startAt: DateTime.utc(2026, 6, 29, startHour),
          endAt: DateTime.utc(2026, 6, 29, endHour),
          visibilityLevel: visibility,
        ),
      ],
    );
