import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/core/config/storage_region.dart';
import 'package:university_schedule_mobile/core/error/app_error.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/shared_friend_cache_database.dart';
import 'package:university_schedule_mobile/features/friends/data/supabase_friend_repository.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/friends/presentation/shared_screen.dart';
import 'package:university_schedule_mobile/features/friends/presentation/friend_timetable_screen.dart';
import 'package:university_schedule_mobile/features/visibility/presentation/visibility_settings_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

final _owner = StateProvider<String>((ref) => 'viewer-a');
const _friend = FriendRelationship(
  id: 'relationship',
  otherUserId: 'friend',
  otherDisplayName: 'Friend',
  status: FriendshipStatus.accepted,
  incarnation: 'incarnation',
  revision: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Harness h;
  setUp(() async {
    h = _Harness();
    await h.ready();
  });
  tearDown(() async {
    h.container.dispose();
    await h.db.close();
  });

  test('disposing a previous screen cannot clear its replacement detail view',
      () async {
    final list = Object(), detail = Object();
    h.controller.claimForegroundView(list);
    await h.controller.selectFriend(_friend);
    h.controller.claimForegroundView(detail);
    await h.controller.selectFriend(_friend);
    h.controller.releaseForegroundView(list);
    expect(h.state.schedule.single.title, 'Full title');
    expect(await h.rows(), hasLength(1));
    h.controller.releaseForegroundView(detail);
    await _until(() => !h.state.scheduleAllowed);
    expect(h.state.schedule, isEmpty);
    expect(await h.rows(), isEmpty);
  });

  test('real SQLite replaces FULL with denied and never keeps full rows',
      () async {
    await h.controller.selectFriend(_friend);
    expect(h.state.schedule.single.title, 'Full title');
    expect((await h.rows()).single.location, 'Full room');
    h.repo.next =
        const FriendScheduleSnapshot(allowed: false, revision: '0', rows: []);
    await h.controller.refreshSelected();
    expect(h.state.schedule, isEmpty);
    expect(h.state.scheduleAllowed, isFalse);
    expect(await h.rows(), isEmpty);
  });

  test(
      'old success and old error cannot replace or clear a newer FULL snapshot',
      () async {
    for (final error in [false, true]) {
      final delayed = Completer<FriendScheduleSnapshot>();
      h.repo.held = delayed;
      final old = h.controller.selectFriend(_friend);
      await _until(() => h.repo.pendingReads == 1);
      h.repo.held = null;
      h.repo.next = _full('New title');
      await h.controller.selectFriend(_friend);
      if (error) {
        delayed.completeError(const NetworkError('old failure'));
      } else {
        delayed.complete(_full('Old title'));
      }
      await old;
      expect(h.state.schedule.single.title, 'New title');
      expect(h.state.errorMessage, isNull);
      expect((await h.rows()).single.title, 'New title');
    }
  });

  test(
      'A to B to A during initial native read rejects the old same-owner response',
      () async {
    final initial = Completer<NativeScopeState>();
    final original = h.native.scope;
    h.native.holds[1] = initial;
    final old = h.controller.selectFriend(_friend);
    await _until(() => h.native.reads == 1);
    await h.switchOwner('viewer-b');
    await h.switchOwner('viewer-a');
    await h.controller.selectFriend(_friend);
    initial.complete(original);
    await old;
    expect(h.repo.fetches, 1);
    expect(h.state.schedule.single.title, 'Full title');
    expect((await h.rows()).every((r) => r.viewerUserId == 'viewer-a'), isTrue);
  });

  test(
      'invalidation while final native read awaits prevents cache/UI resurrection',
      () async {
    final finalRead = Completer<NativeScopeState>();
    h.native.holds[5] = finalRead;
    final loading = h.controller.selectFriend(_friend);
    await _until(() => h.native.reads == 5);
    expect(await h.rows(), hasLength(1));
    await h.controller.onConnectionLost();
    finalRead.complete(h.native.scope);
    await loading;
    expect(h.state.schedule, isEmpty);
    expect(await h.rows(), isEmpty);
  });

  for (final change in ['generation', 'owner', 'region']) {
    test('native $change change after RPC rejects publication', () async {
      final delayed = Completer<FriendScheduleSnapshot>();
      h.repo.held = delayed;
      final loading = h.controller.selectFriend(_friend);
      await _until(() => h.repo.pendingReads == 1);
      final old = h.native.scope;
      h.native.scope = NativeScopeState(
        regionId: change == 'region' ? 'other-region' : old.regionId,
        ownerHash: change == 'owner' ? 'other-owner' : old.ownerHash,
        activationToken: old.activationToken,
        generation:
            change == 'generation' ? old.generation + 1 : old.generation,
        active: true,
      );
      delayed.complete(_full('Old title'));
      await loading;
      expect(h.state.schedule, isEmpty);
      expect(await h.rows(), isEmpty);
    });
  }

  test('request-start deadline expires even while RPC is held', () async {
    h.container.updateOverrides([
      ...h.overrides,
      friendAuthorizationLeaseDurationProvider
          .overrideWithValue(const Duration(milliseconds: 80)),
    ]);
    final delayed = Completer<FriendScheduleSnapshot>();
    h.repo.held = delayed;
    final loading = h.controller.selectFriend(_friend);
    await _until(() => h.repo.pendingReads == 1);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    delayed.complete(_full('Late title'));
    await loading;
    expect(h.state.schedule, isEmpty);
    expect(await h.rows(), isEmpty);
  });

  test('background reconnect cannot fetch; resume restores exact preview mode',
      () async {
    await h.controller.previewFriend(_friend);
    expect(h.repo.termOwners.last, 'viewer-a');
    expect(h.state.schedulePreview, isTrue);
    final reads = h.repo.previews;
    await h.controller.onAppPaused();
    await h.controller.onConnectionRestored();
    expect(h.repo.previews, reads);
    expect(h.state.schedule, isEmpty);
    await h.controller.onAppResumed();
    expect(h.repo.previews, reads + 1);
    expect(h.state.schedulePreview, isTrue);
    final row = (await h.rows()).single;
    expect(row.accessMode, 'owner-preview');
    expect(row.effectiveViewerUserId, 'friend');
    expect(row.sourceOwnerUserId, 'viewer-a');
  });

  testWidgets(
      'visibility settings opens rendered preview using only projected schedule rows',
      (tester) async {
    h.repo.next = FriendScheduleSnapshot(
      allowed: true,
      revision: 'preview-projection',
      rows: [
        FriendSharedEvent(
          eventId: 'full-preview',
          ownerUserId: 'friend',
          startAt: DateTime.utc(2026, 10, 7, 4),
          endAt: DateTime.utc(2026, 10, 7, 5),
          visibilityLevel: VisibilityLevel.full,
          title: 'Visible full event',
          location: 'Visible location',
          description: 'Visible description',
        ),
        FriendSharedEvent(
          eventId: 'busy-preview',
          ownerUserId: 'friend',
          startAt: DateTime.utc(2026, 10, 7, 5),
          endAt: DateTime.utc(2026, 10, 7, 6),
          visibilityLevel: VisibilityLevel.busyOnly,
          title: '予定あり',
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/visibility/friend/friend',
      routes: [
        GoRoute(
          path: '/visibility/friend/:userId',
          builder: (context, state) => VisibilitySettingsScreen(
            friendUserId: state.pathParameters['userId']!,
          ),
        ),
        GoRoute(
          path: '/shared/friend/:userId/preview',
          builder: (context, state) => FriendTimetableScreen(
            friendUserId: state.pathParameters['userId']!,
            preview: true,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('相手からの見え方を確認'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path,
        '/shared/friend/friend/preview');
    expect(find.text('公開範囲プレビュー'), findsOneWidget);
    expect(h.repo.previews, 1);
    expect(h.repo.fetches, 0);
    expect(h.repo.termOwners.last, 'viewer-a');
    expect(h.state.schedulePreview, isTrue);
    expect(find.text('Visible full event'), findsOneWidget);
    expect(find.text('場所: Visible location'), findsOneWidget);
    expect(find.text('Visible description'), findsOneWidget);
    expect(find.text('予定あり'), findsOneWidget);
    expect(find.byTooltip('友だち操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
      'new invite preview wins and duplicate request submits only confirmed token',
      () async {
    final first = Completer<FriendInvitationPreview>();
    h.repo.inviteHold = first;
    final old = h.controller.previewInvitation('first');
    await _until(() => h.repo.previewTokens.length == 1);
    h.repo.inviteHold = null;
    await h.controller.previewInvitation('second');
    first.complete(_preview('first'));
    await old;
    expect(h.state.preview!.invitationId, 'second');
    final request = Completer<FriendRelationship>();
    h.repo.requestHold = request;
    final pending = h.controller.requestInvitation();
    expect(await h.controller.requestInvitation(), isFalse);
    request.complete(_friend.copyWith(status: FriendshipStatus.pending));
    expect(await pending, isTrue);
    expect(h.repo.requestTokens, ['second']);
  });

  test('active invite is reused without a second repository create', () async {
    final first = await h.controller.createInvitation();
    final second = await h.controller.createInvitation();

    expect(first, isNotNull);
    expect(second?.id, first?.id);
    expect(second?.token, first?.token);
    expect(h.repo.createInvitations, 1);
  });

  test('username searches fence stale responses and clear after errors',
      () async {
    final oldResult = Completer<List<FriendUsernameMatch>>();
    final newResult = Completer<List<FriendUsernameMatch>>();
    h.repo.searchHolds.addAll([oldResult, newResult]);

    h.controller.onUsernameQueryChanged('first_user');
    await Future<void>.delayed(const Duration(milliseconds: 330));
    await _until(() => h.repo.usernameQueries.length == 1);
    h.controller.onUsernameQueryChanged('second_user');
    expect(h.state.usernameMatches, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 330));
    await _until(() => h.repo.usernameQueries.length == 2);

    newResult.complete([_usernameMatch('second_user', 'second')]);
    await _until(() => h.state.usernameMatches.isNotEmpty);
    oldResult.complete([_usernameMatch('first_user', 'first')]);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.usernameMatches.single.userId, 'second');
    expect(h.state.usernameQuery, 'second_user');

    final failed = Completer<List<FriendUsernameMatch>>();
    h.repo.searchHolds.add(failed);
    h.controller.onUsernameQueryChanged('failure_user');
    await Future<void>.delayed(const Duration(milliseconds: 330));
    await _until(() => h.repo.usernameQueries.length == 3);
    failed.completeError(const NetworkError('offline'));
    await _until(() => h.state.usernameError != null);
    expect(h.state.usernameQuery, isEmpty);
    expect(h.state.usernameMatches, isEmpty);
    expect(h.state.isSearchingUsername, isFalse);
  });

  for (final invalidation in ['query edit', 'offline', 'realtime']) {
    for (final fails in [false, true]) {
      test(
          'delayed username request clears busy after $invalidation '
          '${fails ? 'failure' : 'success'}', () async {
        h.repo.usernameResult = [_usernameMatch('friend_user', 'friend-user')];
        h.controller.onUsernameQueryChanged('friend_user');
        await Future<void>.delayed(const Duration(milliseconds: 330));
        await _until(() => h.state.usernameMatches.isNotEmpty);

        final delayed = Completer<FriendRelationship>();
        h.repo.friendUsernameRequestHold = delayed;
        final submitted = h.controller
            .confirmUsernameFriendRequest(h.state.usernameMatches.single);
        expect(h.state.isMutating, isTrue);

        switch (invalidation) {
          case 'query edit':
            h.controller.onUsernameQueryChanged('another_user');
            await Future<void>.delayed(const Duration(milliseconds: 330));
            await _until(() => h.repo.usernameQueries.length == 2);
            await _until(() => !h.state.isSearchingUsername);
            break;
          case 'offline':
            await h.controller.onConnectionLost();
            break;
          case 'realtime':
            await h.controller.onFriendInvalidated();
            break;
        }

        if (fails) {
          delayed.completeError(const NetworkError('stale request failure'));
        } else {
          delayed.complete(_friend.copyWith(
            status: FriendshipStatus.pending,
          ));
        }
        expect(await submitted, isFalse);
        expect(h.state.isMutating, isFalse);
        expect(h.state.relationships.single.status, FriendshipStatus.accepted);
        if (invalidation == 'query edit') {
          expect(h.state.usernameQuery, 'another_user');
        } else {
          expect(h.state.usernameQuery, isEmpty);
        }
        expect(h.state.usernameError, isNull);
      });
    }
  }

  test('account A to B to A discards an outstanding username search', () async {
    final delayed = Completer<List<FriendUsernameMatch>>();
    h.repo.searchHolds.add(delayed);
    h.controller.onUsernameQueryChanged('friend_user');
    await Future<void>.delayed(const Duration(milliseconds: 330));
    await _until(() => h.repo.usernameQueries.length == 1);
    await h.switchOwner('viewer-b');
    await h.switchOwner('viewer-a');
    delayed.complete([_usernameMatch('friend_user', 'stale')]);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.usernameMatches, isEmpty);
    expect(h.state.usernameQuery, isEmpty);
  });

  testWidgets('shared screen supports opt-in, exact search, and confirmation',
      (tester) async {
    h.repo.friendUsername =
        const FriendUsernameProfile(username: 'my_user', searchable: false);
    h.repo.usernameResult = [_usernameMatch('friend_user', 'friend-user')];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const MaterialApp(home: SharedScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('friend-username-field')));
    await tester.enterText(
        find.byKey(const Key('friend-username-field')), 'My_Name');
    await tester.ensureVisible(find.byKey(const Key('friend-username-opt-in')));
    await tester.tap(find.byKey(const Key('friend-username-opt-in')));
    await tester.ensureVisible(find.byKey(const Key('friend-username-save')));
    await tester.tap(find.byKey(const Key('friend-username-save')));
    await tester.pumpAndSettle();
    expect(h.repo.savedUsername, 'my_name');
    expect(h.repo.savedSearchable, isTrue);

    await tester.ensureVisible(find.byKey(const Key('friend-username-search')));
    await tester.enterText(
      find.byKey(const Key('friend-username-search')),
      'FRIEND_USER',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Friendly Name'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('friend-username-result')));
    await tester.tap(find.byKey(const Key('friend-username-result')));
    await tester.pumpAndSettle();
    expect(find.text('@friend_user'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const Key('friend-username-confirm')));
    final delayedRequest = Completer<FriendRelationship>();
    h.repo.friendUsernameRequestHold = delayedRequest;
    await tester.tap(find.byKey(const Key('friend-username-confirm')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('friend-username-search')))
          .enabled,
      isFalse,
    );
    delayedRequest.complete(_friend.copyWith(status: FriendshipStatus.pending));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('friend-username-search')))
          .enabled,
      isTrue,
    );
    expect(h.repo.requestedUsername, 'friend_user');
    expect(h.repo.requestedUserId, 'friend-user');
    expect(
        h.repo.requestOperationId,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )));
  });

  testWidgets(
      'username confirmation hides prior-account search result after account switch',
      (tester) async {
    h.repo.friendUsername =
        const FriendUsernameProfile(username: 'viewer_a', searchable: false);
    h.repo.usernameResult = [_usernameMatch('friend_user', 'friend-user')];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const MaterialApp(home: SharedScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('friend-username-search')));
    await tester.enterText(
      find.byKey(const Key('friend-username-search')),
      'friend_user',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('friend-username-result')));
    await tester.tap(find.byKey(const Key('friend-username-result')));
    await tester.pumpAndSettle();
    expect(find.text('Friendly Name'), findsOneWidget);
    expect(find.text('@friend_user'), findsOneWidget);

    await h.switchOwner('viewer-b');
    await tester.pumpAndSettle();

    expect(find.text('Friendly Name'), findsNothing);
    expect(find.text('@friend_user'), findsNothing);
    expect(find.byKey(const Key('friend-username-confirm')), findsNothing);
    expect(h.repo.requestedUserId, isNull);
  });

  testWidgets(
      'username confirmation does not render prior-account result if viewer changes before first dialog frame',
      (tester) async {
    h.repo.friendUsername =
        const FriendUsernameProfile(username: 'viewer_a', searchable: false);
    h.repo.usernameResult = [_usernameMatch('friend_user', 'friend-user')];
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const MaterialApp(home: SharedScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('friend-username-search')));
    await tester.enterText(
      find.byKey(const Key('friend-username-search')),
      'friend_user',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('friend-username-result')));
    await tester.tap(find.byKey(const Key('friend-username-result')));

    await h.switchOwner('viewer-b');
    await tester.pumpAndSettle();

    expect(find.text('Friendly Name'), findsNothing);
    expect(find.text('@friend_user'), findsNothing);
    expect(find.byKey(const Key('friend-username-confirm')), findsNothing);
    expect(h.repo.requestedUserId, isNull);
  });

  testWidgets(
      'block confirmation removes only its target, and explicit unblock does not restore friendship',
      (tester) async {
    const target = FriendRelationship(
      id: 'relationship-target',
      otherUserId: 'friend',
      otherDisplayName: 'Target A',
      status: FriendshipStatus.accepted,
      incarnation: 'target-incarnation',
      revision: 1,
    );
    const unrelated = FriendRelationship(
      id: 'relationship-unrelated',
      otherUserId: 'unrelated',
      otherDisplayName: 'Independent B',
      status: FriendshipStatus.accepted,
      incarnation: 'unrelated-incarnation',
      revision: 1,
    );
    h.repo.relationships = [target, unrelated];
    await h.controller.refreshRelationships();
    final router = GoRouter(
      initialLocation: '/shared/friend/friend',
      routes: [
        GoRoute(
          path: '/shared/friend/:userId',
          builder: (context, state) => FriendTimetableScreen(
            friendUserId: state.pathParameters['userId']!,
          ),
        ),
        GoRoute(
          path: '/shared/blocked',
          builder: (context, state) => const BlockedFriendsScreen(),
        ),
        GoRoute(
          path: '/shared',
          builder: (context, state) => const SharedScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Target A'), findsOneWidget);

    await tester.tap(find.byTooltip('友だち操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブロック'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(h.repo.blockCalls, 0);
    expect(find.text('Target A'), findsOneWidget);

    await tester.tap(find.byTooltip('友だち操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ブロック'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('実行'));
    await tester.pumpAndSettle();
    expect(h.repo.blockCalls, 1);
    expect(h.repo.blockedUsers, {'friend': 'Target A'});
    expect(
        h.state.relationships.map((item) => item.otherUserId), ['unrelated']);
    expect(router.routeInformationProvider.value.uri.path, '/shared');
    expect(find.text('Target A'), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('Independent B'), findsOneWidget);

    final blockedListButton = find.textContaining('ブロック一覧');
    await tester.ensureVisible(blockedListButton);
    await tester.tap(blockedListButton);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Target A'), findsOneWidget);
    expect(find.text('Independent B'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, '解除'));
    await tester.pumpAndSettle();
    expect(h.repo.unblockCalls, 1);
    expect(h.repo.blockedUsers, isEmpty);
    expect(find.text('ブロックしている人はいません'), findsOneWidget);

    router.go('/shared');
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('Target A'), findsNothing);
    expect(find.text('Independent B'), findsOneWidget);
  });

  for (final action in ['ブロック', '友だちから削除']) {
    testWidgets(
        '$action confirmation is discarded after an A to B to A viewer switch',
        (tester) async {
      h.repo.relationships = [_friend];
      await h.controller.refreshRelationships();
      final router = GoRouter(
        initialLocation: '/shared/friend/friend',
        routes: [
          GoRoute(
            path: '/shared/friend/:userId',
            builder: (context, state) => FriendTimetableScreen(
              friendUserId: state.pathParameters['userId']!,
            ),
          ),
          GoRoute(
            path: '/shared',
            builder: (context, state) => const SharedScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('友だち操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(
        find.text(action == 'ブロック' ? 'この人をブロックしますか？' : '友だちから削除しますか？'),
        findsOneWidget,
      );

      await h.switchOwner('viewer-b');
      await tester.pumpAndSettle();
      await h.switchOwner('viewer-a');
      await tester.pumpAndSettle();
      await tester.tap(find.text('実行'));
      await tester.pumpAndSettle();

      expect(h.repo.blockCalls, 0);
      expect(h.repo.removeCalls, 0);
      expect(h.repo.relationships, contains(_friend));
    });
  }

  for (final action in ['ブロック', '友だちから削除']) {
    testWidgets(
        '$action confirmation is discarded when its relationship revision changes',
        (tester) async {
      h.repo.relationships = [_friend];
      await h.controller.refreshRelationships();
      final router = GoRouter(
        initialLocation: '/shared/friend/friend',
        routes: [
          GoRoute(
            path: '/shared/friend/:userId',
            builder: (context, state) => FriendTimetableScreen(
              friendUserId: state.pathParameters['userId']!,
            ),
          ),
          GoRoute(
            path: '/shared',
            builder: (context, state) => const SharedScreen(),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('友だち操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('実行'), findsOneWidget);

      h.repo.relationships = [_friend.copyWith(revision: 2)];
      await h.controller.refreshRelationships();
      await tester.pumpAndSettle();
      await tester.tap(find.text('実行'));
      await tester.pumpAndSettle();

      expect(h.repo.blockCalls, 0);
      expect(h.repo.removeCalls, 0);
      expect(h.repo.relationships.single.revision, 2);
    });
  }

  test('claimed, revoked, and expired summaries are not active', () async {
    final now = DateTime.now();
    expect(
      FriendInvitationSummary(
        id: 'claimed',
        expiresAt: now.add(const Duration(days: 1)),
        claimed: true,
      ).isActive,
      isFalse,
    );
    expect(
      FriendInvitationSummary(
        id: 'revoked',
        expiresAt: now.add(const Duration(days: 1)),
        revoked: true,
      ).isActive,
      isFalse,
    );
    expect(
      FriendInvitationSummary(
        id: 'expired',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ).isActive,
      isFalse,
    );

    final first = await h.controller.createInvitation();
    expect(first, isNotNull);
    h.repo.invitations = [
      FriendInvitationSummary(
        id: first!.id,
        expiresAt: first.expiresAt,
        claimed: true,
      ),
    ];
    await h.controller.refreshRelationships();
    expect(h.state.pendingInvitation, isNull);
  });

  test('account switch clears in-memory pending invite reuse', () async {
    final first = await h.controller.createInvitation();
    expect(first, isNotNull);
    await h.switchOwner('viewer-b');
    expect(h.state.pendingInvitation, isNull);
    expect(await h.controller.createInvitation(), isNotNull);
    expect(h.repo.createInvitations, 2);
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'controlled async boundary was reached');
}

FriendInvitationPreview _preview(String token) => FriendInvitationPreview(
      invitationId: token,
      issuerUserId: 'friend',
      issuerDisplayName: 'Friend',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      status: 'active',
    );

FriendScheduleSnapshot _full(String title) => FriendScheduleSnapshot(
      allowed: true,
      revision: title,
      rows: [
        FriendSharedEvent(
            eventId: 'opaque-event',
            ownerUserId: 'friend',
            startAt: DateTime.utc(2026, 10, 7, 4),
            endAt: DateTime.utc(2026, 10, 7, 5),
            visibilityLevel: VisibilityLevel.full,
            title: title,
            location: 'Full room')
      ],
    );

class _Harness {
  final db = SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
  final repo = _Repo();
  final native = _Native();
  late final config = AppConfig.validated(environment: 'local', demoMode: true);
  late final overrides = [
    appConfigProvider.overrideWithValue(config),
    currentAuthSessionProvider
        .overrideWith((ref) => AppAuthSession(userId: ref.watch(_owner))),
    activeScheduleContextProvider.overrideWith((ref) => ActiveScheduleContext(
          ownerUserId: ref.watch(_owner),
          universityId: 'university',
          termId: 'term',
          academicYear: 2026,
          primaryCalendarId: 'calendar',
        )),
    sharedFriendCacheDatabaseProvider.overrideWithValue(db),
    friendRepositoryProvider.overrideWithValue(repo),
    nativeScopeBridgeProvider.overrideWithValue(native),
  ];
  late final container = ProviderContainer(overrides: [
    ...overrides,
    friendAuthorizationLeaseDurationProvider
        .overrideWithValue(const Duration(seconds: 60)),
  ]);
  FriendsController get controller =>
      container.read(friendsControllerProvider.notifier);
  FriendState get state =>
      container.read(friendsControllerProvider).requireValue;
  Future<List<SharedFriendCacheRow>> rows() =>
      db.select(db.sharedFriendCacheRows).get();
  Future<void> ready() async {
    _nativeOwner('viewer-a');
    await container.read(friendsControllerProvider.future);
  }

  void _nativeOwner(String owner) {
    native.scope = NativeScopeState(
        regionId: StorageRegion.fromConfig(config).id,
        ownerHash: sha256.convert(utf8.encode(owner)).toString(),
        activationToken: 'activation',
        generation: 1,
        active: true);
  }

  Future<void> switchOwner(String owner) async {
    _nativeOwner(owner);
    container.read(_owner.notifier).state = owner;
    await container.read(friendsControllerProvider.future);
  }
}

class _Native extends NativeScopeBridge {
  late NativeScopeState scope;
  int reads = 0;
  final holds = <int, Completer<NativeScopeState>>{};
  @override
  Future<NativeScopeState> current() async => holds[++reads]?.future ?? scope;
}

class _Repo extends UnavailableFriendRepository {
  FriendScheduleSnapshot next = _full('Full title');
  Completer<FriendScheduleSnapshot>? held;
  Completer<FriendInvitationPreview>? inviteHold;
  Completer<FriendRelationship>? requestHold;
  Completer<FriendRelationship>? friendUsernameRequestHold;
  int pendingReads = 0, fetches = 0, previews = 0;
  final termOwners = <String>[];
  final previewTokens = <String>[];
  final requestTokens = <String>[];
  final usernameQueries = <String>[];
  final searchHolds = <Completer<List<FriendUsernameMatch>>>[];
  FriendUsernameProfile? friendUsername;
  List<FriendUsernameMatch> usernameResult = [];
  String? savedUsername;
  bool? savedSearchable;
  String? requestedUsername;
  String? requestedUserId;
  String? requestOperationId;
  var createInvitations = 0;
  List<FriendInvitationSummary> invitations = [];
  List<FriendRelationship> relationships = [_friend];
  final Map<String, String> blockedUsers = {};
  var blockCalls = 0;
  var removeCalls = 0;
  var unblockCalls = 0;
  @override
  Future<List<FriendRelationship>> listRelationships() async => relationships;
  @override
  Future<Map<String, String>> listBlockedUsers() async => blockedUsers;

  @override
  Future<void> blockUser(String userId) async {
    blockCalls++;
    final matches = relationships
        .where((relationship) => relationship.otherUserId == userId);
    final blocked = matches.isEmpty ? null : matches.first;
    relationships
        .removeWhere((relationship) => relationship.otherUserId == userId);
    if (blocked != null) blockedUsers[userId] = blocked.otherDisplayName;
  }

  @override
  Future<void> removeFriend(FriendRelationship relationship) async {
    removeCalls++;
    relationships.removeWhere((item) => item.id == relationship.id);
  }

  @override
  Future<void> unblockUser(String userId) async {
    unblockCalls++;
    blockedUsers.remove(userId);
  }

  @override
  Future<List<FriendInvitationSummary>> listInvitations() async => invitations;

  @override
  Future<FriendUsernameProfile?> getMyFriendUsername() async => friendUsername;

  @override
  Future<FriendUsernameProfile> setMyFriendUsername({
    required String? username,
    required bool searchable,
  }) async {
    savedUsername = username;
    savedSearchable = searchable;
    return friendUsername = FriendUsernameProfile(
      username: username,
      searchable: searchable,
    );
  }

  @override
  Future<List<FriendUsernameMatch>> findFriendByUsername(String username) {
    usernameQueries.add(username);
    if (searchHolds.isNotEmpty) return searchHolds.removeAt(0).future;
    return Future.value(usernameResult);
  }

  @override
  Future<FriendRelationship> requestFriendByUsername({
    required FriendUsernameMatch target,
    required String shownUsername,
    required String operationId,
  }) async {
    requestedUsername = shownUsername;
    requestedUserId = target.userId;
    requestOperationId = operationId;
    final hold = friendUsernameRequestHold;
    if (hold != null) return hold.future;
    return FriendRelationship(
      id: 'username-request',
      otherUserId: target.userId,
      otherDisplayName: target.displayName,
      status: FriendshipStatus.pending,
      isRequester: true,
      incarnation: 'username-incarnation',
      revision: 1,
    );
  }

  @override
  Future<FriendInvitation> createInvitation(
      {required DateTime expiresAt}) async {
    createInvitations++;
    final result = FriendInvitation(
      id: 'invite-$createInvitations',
      token: 'opaque-test-value',
      expiresAt: expiresAt,
    );
    invitations = [
      FriendInvitationSummary(id: result.id, expiresAt: result.expiresAt),
    ];
    return result;
  }

  @override
  Future<List<FriendVisibilityRule>> listVisibilityRules(
          FriendRelationship relationship) async =>
      [];
  @override
  Future<List<FriendTerm>> listFriendTerms(String friendUserId) async {
    termOwners.add(friendUserId);
    return [
      FriendTerm(
          id: 'source-term',
          name: 'Term',
          academicYear: 2026,
          startDate: DateTime.utc(2026, 1),
          endDate: DateTime.utc(2099))
    ];
  }

  Future<FriendScheduleSnapshot> _response() async {
    final wait = held;
    if (wait == null) return next;
    pendingReads++;
    try {
      return await wait.future;
    } finally {
      pendingReads--;
    }
  }

  @override
  Future<FriendScheduleSnapshot> fetchSchedule(
      {required String friendUserId,
      required String termId,
      required DateTime rangeStart,
      required DateTime rangeEnd}) {
    fetches++;
    return _response();
  }

  @override
  Future<FriendScheduleSnapshot> previewSchedule(
      {required String friendUserId,
      required String termId,
      required DateTime rangeStart,
      required DateTime rangeEnd}) {
    previews++;
    return _response();
  }

  @override
  Future<FriendInvitationPreview> previewInvitation(String token) async {
    previewTokens.add(token);
    return inviteHold?.future ?? _preview(token);
  }

  @override
  Future<FriendRelationship> requestInvitation(String token) async {
    requestTokens.add(token);
    return requestHold!.future;
  }
}

FriendUsernameMatch _usernameMatch(String username, String userId) =>
    FriendUsernameMatch(
      userId: userId,
      username: username,
      displayName: 'Friendly Name',
    );
