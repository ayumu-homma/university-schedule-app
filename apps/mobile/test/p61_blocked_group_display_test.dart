import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:drift/native.dart';
import 'package:university_schedule_mobile/core/config/app_config.dart';
import 'package:university_schedule_mobile/core/config/app_config_provider.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/data/shared_friend_cache_database.dart';
import 'package:university_schedule_mobile/features/friends/data/supabase_friend_repository.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';
import 'package:university_schedule_mobile/features/groups/presentation/group_detail_screen.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('group create draft is discarded after account switch',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final repository = _AccountBoundGroupDraftRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(repository),
      friendsControllerProvider
          .overrideWith(_KnownEmptyBlockListController.new),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: GroupListTab())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('グループを作成'));
    await tester.pumpAndSettle();

    final createDialog = find.byType(AlertDialog).last;
    await tester.enterText(
      find.descendant(
        of: createDialog,
        matching: find.byWidgetPredicate((widget) =>
            widget is TextField && widget.decoration?.labelText == 'グループ名'),
      ),
      'Private draft from account A',
    );
    await tester.enterText(
      find.descendant(
        of: createDialog,
        matching: find.byWidgetPredicate((widget) =>
            widget is TextField && widget.decoration?.labelText == '説明（任意）'),
      ),
      'Private description draft from account A',
    );

    container.read(sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('Private draft from account A'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('Private description draft from account A'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('ログイン状態が変わりました'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: changedDialog, matching: find.text('閉じる')),
    );
    await tester.pumpAndSettle();
    expect(repository.groupCreateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group edit draft hides account A details after account switch',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final repository = _AccountBoundGroupDraftRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(repository),
      friendsControllerProvider
          .overrideWith(_KnownEmptyBlockListController.new),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('グループを編集'), 200);
    await tester.tap(find.text('グループを編集'));
    await tester.pumpAndSettle();

    final editDialog = find.byType(AlertDialog).last;
    expect(
      tester
          .widget<TextField>(find.descendant(
            of: editDialog,
            matching: find.byWidgetPredicate((widget) =>
                widget is TextField && widget.decoration?.labelText == 'グループ名'),
          ))
          .controller
          ?.text,
      'Private group A',
    );
    expect(find.text('Private description from account A'), findsOneWidget);

    container.read(sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('Private description from account A'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: changedDialog,
        matching: find.text('ログイン状態が変わりました'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: changedDialog, matching: find.text('閉じる')),
    );
    await tester.pumpAndSettle();
    expect(repository.groupUpdateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'event detail stops showing account A content after account switch',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final repository = _P61GroupRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(repository),
      friendsControllerProvider
          .overrideWith(_KnownEmptyBlockListController.new),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();

    var dialog = find.byType(AlertDialog).last;
    expect(find.descendant(of: dialog, matching: find.text('Existing event')),
        findsOneWidget);
    expect(
      find.descendant(
          of: dialog, matching: find.text('Blocked member comment')),
      findsOneWidget,
    );

    container.read(sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    dialog = find.byType(AlertDialog).last;
    expect(find.descendant(of: dialog, matching: find.text('Existing event')),
        findsNothing);
    expect(
      find.descendant(
          of: dialog, matching: find.text('Blocked member comment')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment edit dialog hides old account draft and skips update',
      (tester) async {
    final sessionState = StateProvider<AppAuthSession?>(
      (ref) => const AppAuthSession(userId: 'viewer'),
    );
    final repository = _UpdateTrackingP61GroupRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
      groupRepositoryProvider.overrideWithValue(repository),
      friendsControllerProvider
          .overrideWith(_KnownEmptyBlockListController.new),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byKey(const Key('group-comment-own-comment')),
      matching: find.byTooltip('コメント操作'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == 'edit',
    ));
    await tester.pumpAndSettle();

    final editDialog = find.byType(AlertDialog).last;
    final editField = find.descendant(
      of: editDialog,
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(editField).controller?.text,
      'Private comment from account A',
    );
    await tester.enterText(editField, 'Private draft from account A');

    container.read(sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();

    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(of: changedDialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: changedDialog,
          matching: find.text('Private draft from account A')),
      findsNothing,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.byType(TextField)),
      findsNothing,
    );

    await tester.tap(find.descendant(
      of: changedDialog,
      matching: find.text('閉じる'),
    ));
    await tester.pumpAndSettle();
    expect(repository.commentUpdateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('event edit form hides prior account values after a switch',
      (tester) async {
    final harness = await _openAccountBoundEvent(tester);
    await tester.tap(find.text('編集').last);
    await tester.pumpAndSettle();

    final editDialog = find.byType(AlertDialog).last;
    final titleField = find.descendant(
      of: editDialog,
      matching: find.byWidgetPredicate((widget) =>
          widget is TextField && widget.decoration?.labelText == 'タイトル'),
    );
    expect(tester.widget<TextField>(titleField).controller?.text,
        'Existing event');

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();
    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(of: changedDialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.byType(TextField)),
      findsNothing,
    );
    await tester
        .tap(find.descendant(of: changedDialog, matching: find.text('閉じる')));
    await tester.pumpAndSettle();
    expect(harness.repository.eventUpdateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('date picker hides and dismisses safely after account switch',
      (tester) async {
    final harness = await _openAccountBoundEvent(tester);
    await tester.tap(find.text('編集').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.calendar_today).first);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(of: changedDialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    await tester
        .tap(find.descendant(of: changedDialog, matching: find.text('閉じる')));
    await tester.pumpAndSettle();
    expect(harness.repository.eventUpdateCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment delete confirmation is cancelled by account change',
      (tester) async {
    final harness = await _openAccountBoundEvent(tester);
    await tester.tap(find.descendant(
      of: find.byKey(const Key('group-comment-own-comment')),
      matching: find.byTooltip('コメント操作'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == 'delete',
    ));
    await tester.pumpAndSettle();
    expect(find.text('コメントを削除しますか？'), findsOneWidget);

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(of: dialog, matching: find.text('コメントを削除しますか？')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('閉じる')));
    await tester.pumpAndSettle();
    expect(harness.repository.commentDeleteCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment report input is hidden and discarded on account change',
      (tester) async {
    final harness = await _openAccountBoundEvent(tester);
    await tester.tap(find.descendant(
      of: find.byKey(const Key('group-comment-own-comment')),
      matching: find.byTooltip('コメント操作'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == 'report',
    ));
    await tester.pumpAndSettle();
    final reportDialog = find.byType(AlertDialog).last;
    final reasonField = find.descendant(
      of: reportDialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(reasonField, 'Private report reason from account A');

    harness.container.read(harness.sessionState.notifier).state =
        const AppAuthSession(userId: 'second-viewer');
    await tester.pumpAndSettle();
    final changedDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
          of: changedDialog,
          matching: find.text('Private report reason from account A')),
      findsNothing,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      find.descendant(of: changedDialog, matching: find.text('ログイン状態が変わりました')),
      findsOneWidget,
    );
    await tester
        .tap(find.descendant(of: changedDialog, matching: find.text('閉じる')));
    await tester.pumpAndSettle();
    expect(harness.repository.reportCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'outgoing-blocked member identity is hidden while role, controls, and authored content remain',
      (tester) async {
    final repository = _P61GroupRepository();
    final friendsController = _P61FriendsController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider.overrideWith(() => friendsController),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-blocked')),
      180,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('group-member-blocked')),
        matching: find.text('ブロック中のメンバー'),
      ),
      findsOneWidget,
    );
    expect(find.text('Blocked Person'), findsNothing);
    final blockedTile = tester.widget<ListTile>(
      find.byKey(const Key('group-member-blocked')),
    );
    expect(blockedTile.onTap, isNull);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-third')),
      200,
    );
    expect(find.text('Third Person'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);

    final blockedRow = find.byKey(const Key('group-member-blocked'));
    await tester.tap(find.descendant(
      of: blockedRow,
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Memberに降格'), findsOneWidget);
    expect(find.text('メンバーを削除'), findsOneWidget);
    expect(find.text('Ownerを移譲'), findsOneWidget);
    await tester.tap(find.text('メンバーを削除'));
    await tester.pumpAndSettle();
    expect(find.text('メンバーを削除しますか？'), findsOneWidget);
    expect(find.text('Blocked Person'), findsNothing);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-availability-search')));
    await tester.pumpAndSettle();
    final availabilityDialog = find.byType(AlertDialog).last;
    expect(
      find.descendant(
        of: availabilityDialog,
        matching: find.text('Third Person'),
      ),
      findsOneWidget,
    );
    friendsController.publish(const FriendState());
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.text('Third Person'),
      ),
      findsOneWidget,
    );
    friendsController.publish(const FriendState(
      blockedUserIds: {'blocked'},
      blockStatusLoaded: true,
      blockStatusViewerUserId: 'viewer',
    ));
    await tester.pump();
    expect(find.text('Blocked Person'), findsNothing);
    expect(find.text('Blocked Person'), findsNothing);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('group-event-event')),
      200,
    );
    await tester.tap(find.byKey(const Key('group-event-event')));
    await tester.pumpAndSettle();
    expect(find.text('Blocked member comment'), findsOneWidget);
    expect(find.text('Third member comment'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('group-comment-blocked-comment')),
        matching: find.textContaining('ブロック中のメンバー'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('group-comment-third-comment')),
        matching: find.textContaining('メンバー ·'),
      ),
      findsOneWidget,
    );
    expect(find.text('Blocked Person'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'loaded group projection preserves unrelated names while friend block list is unavailable',
      (tester) async {
    final repository = _P61GroupRepository()
      ..blockedMemberUserIds = {'blocked'};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider
              .overrideWith(_UnknownBlockListController.new),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-blocked')),
      180,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('group-member-blocked')),
        matching: find.text('ブロック中のメンバー'),
      ),
      findsOneWidget,
    );
    expect(find.text('Blocked Person'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-third')),
      200,
    );
    expect(find.text('Third Person'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('foreign-viewer friend block state cannot hide unrelated members',
      (tester) async {
    final repository = _P61GroupRepository()
      ..blockedMemberUserIds = {'blocked'};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider
              .overrideWith(_ForeignViewerBlockedListController.new),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Person'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-third')),
      200,
    );
    expect(find.text('Third Person'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unresolved group projection hides other member names until loaded',
      (tester) async {
    final repository = _P61GroupRepository()..failBlockedMemberLookup = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider
              .overrideWith(_UnknownBlockListController.new),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Person'), findsNothing);
    expect(find.text('Third Person'), findsNothing);
    expect(find.text('閲覧者'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming block projection hides only the in-group target',
      (tester) async {
    final repository = _P61GroupRepository()
      ..blockedMemberUserIds = {'blocked'};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider
              .overrideWith(_KnownEmptyBlockListController.new),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Person'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('group-member-third')),
      200,
    );
    expect(find.text('Third Person'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('group-member-blocked')),
        matching: find.text('admin'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('RPC error leaves names hidden instead of treating it as empty',
      (tester) async {
    final repository = _P61GroupRepository()..failBlockedMemberLookup = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(repository),
          friendsControllerProvider
              .overrideWith(_KnownEmptyBlockListController.new),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Person'), findsNothing);
    expect(find.text('Third Person'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('block projection from a previous account cannot reveal names',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentAuthSessionProvider.overrideWithValue(
            const AppAuthSession(userId: 'new-viewer'),
          ),
          groupRepositoryProvider.overrideWithValue(_P61GroupRepository()),
          groupsControllerProvider.overrideWith(
            _StaleBlockProjectionGroupsController.new,
          ),
          friendsControllerProvider.overrideWith(
            () => _KnownEmptyBlockListForUserController('new-viewer'),
          ),
        ],
        child: const MaterialApp(
          home: GroupDetailScreen(groupId: 'group'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Blocked Person'), findsNothing);
    expect(find.text('Third Person'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('group switch and unblock refresh replace the scoped projection',
      () async {
    final repository = _ScopedProjectionGroupRepository();
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'viewer'),
      ),
      groupRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);

    await container.read(groupsControllerProvider.future);
    final controller = container.read(groupsControllerProvider.notifier);
    expect(await controller.open('group-one'), isTrue);
    var state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusGroupId, 'group-one');
    expect(state.blockedMemberStatusViewerUserId, 'viewer');
    expect(state.blockedMemberUserIds, {'incoming-one'});

    expect(await controller.open('group-two'), isTrue);
    state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusGroupId, 'group-two');
    expect(state.blockedMemberUserIds, {'outgoing-two'});

    repository.blockedByGroup['group-two'] = <String>{};
    await controller.refreshMemberBlockStatus('group-two');
    state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusLoaded, isTrue);
    expect(state.blockedMemberStatusGroupId, 'group-two');
    expect(state.blockedMemberUserIds, isEmpty);

    repository.failProjection = true;
    await controller.refreshMemberBlockStatus('group-two');
    state = container.read(groupsControllerProvider).requireValue;
    expect(state.blockedMemberStatusLoaded, isFalse);
    expect(state.blockedMemberUserIds, isEmpty);
  });

  test('successful block followed by failed block-list refresh stays unknown',
      () async {
    final database =
        SharedFriendCacheDatabase.forExecutor(NativeDatabase.memory());
    final repository = _RefreshFailsAfterBlockRepository();
    final container = ProviderContainer(overrides: [
      appConfigProvider.overrideWithValue(
        AppConfig.validated(environment: 'local', demoMode: true),
      ),
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: 'viewer'),
      ),
      activeScheduleContextProvider.overrideWithValue(
        const ActiveScheduleContext(
          ownerUserId: 'viewer',
          universityId: 'university',
          termId: 'term',
          academicYear: 2026,
          primaryCalendarId: 'calendar',
        ),
      ),
      sharedFriendCacheDatabaseProvider.overrideWithValue(database),
      friendRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(friendsControllerProvider.future);
    expect(
      container.read(friendsControllerProvider).requireValue.blockStatusLoaded,
      isTrue,
    );

    final blocked = await container
        .read(friendsControllerProvider.notifier)
        .blockUser(const FriendRelationship(
          id: 'relationship',
          otherUserId: 'blocked',
          otherDisplayName: 'Blocked Person',
          status: FriendshipStatus.accepted,
          incarnation: 'incarnation',
          revision: 1,
        ));

    expect(blocked, isTrue);
    final state = container.read(friendsControllerProvider).requireValue;
    expect(state.isOffline, isFalse);
    expect(state.blockStatusLoaded, isFalse);
  });
}

Future<_AccountBoundHarness> _openAccountBoundEvent(WidgetTester tester) async {
  final sessionState = StateProvider<AppAuthSession?>(
    (ref) => const AppAuthSession(userId: 'viewer'),
  );
  final repository = _UpdateTrackingP61GroupRepository();
  final container = ProviderContainer(overrides: [
    currentAuthSessionProvider.overrideWith((ref) => ref.watch(sessionState)),
    groupRepositoryProvider.overrideWithValue(repository),
    friendsControllerProvider.overrideWith(_KnownEmptyBlockListController.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: GroupDetailScreen(groupId: 'group')),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('group-event-event')));
  await tester.pumpAndSettle();
  return _AccountBoundHarness(sessionState, repository, container);
}

class _AccountBoundHarness {
  const _AccountBoundHarness(
      this.sessionState, this.repository, this.container);

  final StateProvider<AppAuthSession?> sessionState;
  final _UpdateTrackingP61GroupRepository repository;
  final ProviderContainer container;
}

class _P61FriendsController extends FriendsController {
  void publish(FriendState value) {
    state = AsyncData(value);
  }

  @override
  Future<FriendState> build() async => const FriendState(
        blockedUserIds: {'blocked'},
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'viewer',
      );
}

class _UnknownBlockListController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState();
}

class _ForeignViewerBlockedListController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        blockedUserIds: {'third'},
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'different-viewer',
      );
}

class _KnownEmptyBlockListController extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        blockStatusLoaded: true,
        blockStatusViewerUserId: 'viewer',
      );
}

class _KnownEmptyBlockListForUserController extends FriendsController {
  _KnownEmptyBlockListForUserController(this.userId);
  final String userId;

  @override
  Future<FriendState> build() async => FriendState(
        blockStatusLoaded: true,
        blockStatusViewerUserId: userId,
      );
}

class _StaleBlockProjectionGroupsController extends GroupsController {
  @override
  Future<GroupState> build() async => const GroupState(
        selected: GroupSummary(
          id: 'group',
          name: 'Test group',
          ownerUserId: 'old-viewer',
          type: GroupType.other,
          role: GroupRole.owner,
        ),
        members: [
          GroupMemberSummary(
            groupId: 'group',
            userId: 'old-viewer',
            displayName: '閲覧者',
            role: GroupRole.owner,
          ),
          GroupMemberSummary(
            groupId: 'group',
            userId: 'blocked',
            displayName: 'Blocked Person',
            role: GroupRole.member,
          ),
          GroupMemberSummary(
            groupId: 'group',
            userId: 'third',
            displayName: 'Third Person',
            role: GroupRole.member,
          ),
        ],
        blockedMemberUserIds: {'blocked'},
        blockedMemberStatusLoaded: true,
        blockedMemberStatusGroupId: 'group',
        blockedMemberStatusViewerUserId: 'old-viewer',
      );

  @override
  Future<bool> open(String id) async => false;
}

class _ScopedProjectionGroupRepository extends _P61GroupRepository {
  final Map<String, Set<String>> blockedByGroup = {
    'group-one': {'incoming-one'},
    'group-two': {'outgoing-two'},
  };
  bool failProjection = false;

  @override
  Future<GroupSummary> getGroup(String groupId) async => GroupSummary(
        id: groupId,
        name: groupId,
        ownerUserId: 'viewer',
        type: GroupType.other,
        role: GroupRole.owner,
      );

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => [
        GroupMemberSummary(
          groupId: groupId,
          userId: 'viewer',
          displayName: 'Viewer',
          role: GroupRole.owner,
        ),
        GroupMemberSummary(
          groupId: groupId,
          userId: 'incoming-one',
          displayName: 'Incoming',
          role: GroupRole.member,
        ),
        GroupMemberSummary(
          groupId: groupId,
          userId: 'outgoing-two',
          displayName: 'Outgoing',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) async {
    if (failProjection) throw StateError('synthetic RPC unavailable');
    return blockedByGroup[groupId] ?? const {};
  }
}

class _RefreshFailsAfterBlockRepository extends UnavailableFriendRepository {
  final Map<String, String> blockedUsers = {};
  bool failBlockedList = false;

  @override
  Future<List<FriendRelationship>> listRelationships() async => const [];

  @override
  Future<Map<String, String>> listBlockedUsers() async {
    if (failBlockedList) throw StateError('synthetic refresh failure');
    return blockedUsers;
  }

  @override
  Future<List<FriendInvitationSummary>> listInvitations() async => const [];

  @override
  Future<FriendUsernameProfile?> getMyFriendUsername() async => null;

  @override
  Future<void> blockUser(String userId) async {
    blockedUsers[userId] = 'Blocked Person';
    failBlockedList = true;
  }
}

class _P61GroupRepository extends UnavailableGroupRepository {
  Set<String> blockedMemberUserIds = {'blocked'};
  bool failBlockedMemberLookup = false;
  final group = const GroupSummary(
    id: 'group',
    name: 'Test group',
    ownerUserId: 'viewer',
    type: GroupType.other,
    role: GroupRole.owner,
  );

  final event = GroupEventSummary(
    eventId: 'event',
    groupId: 'group',
    title: 'Existing event',
    startAt: DateTime.utc(2026, 10, 1, 9),
    endAt: DateTime.utc(2026, 10, 1, 10),
    createdBy: 'blocked',
    version: 1,
  );

  @override
  Future<List<GroupSummary>> listGroups() async => [group];

  @override
  Future<GroupSummary> getGroup(String groupId) async => group;

  @override
  Future<List<GroupMemberSummary>> listMembers(String groupId) async => [
        const GroupMemberSummary(
          groupId: 'group',
          userId: 'viewer',
          displayName: '閲覧者',
          role: GroupRole.owner,
        ),
        const GroupMemberSummary(
          groupId: 'group',
          userId: 'blocked',
          displayName: 'Blocked Person',
          role: GroupRole.admin,
        ),
        const GroupMemberSummary(
          groupId: 'group',
          userId: 'third',
          displayName: 'Third Person',
          role: GroupRole.member,
        ),
      ];

  @override
  Future<Set<String>> listBlockedGroupMembers(String groupId) async {
    if (failBlockedMemberLookup) {
      throw StateError('synthetic unavailable block projection');
    }
    return blockedMemberUserIds;
  }

  @override
  Future<List<GroupInviteSummary>> listInvites(String groupId) async => [];

  @override
  Future<List<GroupEventSummary>> listGroupEvents(String groupId) async =>
      [event];

  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) async =>
      GroupEventContent(
        eventId: eventId,
        groupId: 'group',
        generation: 'fake-generation',
        rsvps: const [],
        comments: [
          _comment('blocked-comment', 'blocked', 'Blocked member comment'),
          _comment('third-comment', 'third', 'Third member comment'),
        ],
        reactions: const [],
      );

  @override
  Future<bool> validateGroupEventContent({
    required String eventId,
    required String generation,
  }) async =>
      eventId == 'event' && generation == 'fake-generation';
}

class _UpdateTrackingP61GroupRepository extends _P61GroupRepository {
  int commentUpdateCalls = 0;
  int commentDeleteCalls = 0;
  int reportCalls = 0;
  int eventUpdateCalls = 0;

  @override
  Future<GroupEventContent> getGroupEventContent(String eventId) async =>
      GroupEventContent(
        eventId: eventId,
        groupId: 'group',
        generation: 'fake-generation',
        rsvps: const [],
        comments: [
          _comment('own-comment', 'viewer', 'Private comment from account A')
        ],
        reactions: const [],
      );

  @override
  Future<GroupEventComment> updateGroupEventComment({
    required String commentId,
    required String body,
    required int expectedVersion,
  }) async {
    commentUpdateCalls++;
    return _comment(commentId, 'blocked', body);
  }

  @override
  Future<void> deleteGroupEventComment({
    required String commentId,
    required int expectedVersion,
  }) async {
    commentDeleteCalls++;
  }

  @override
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) async {
    reportCalls++;
  }

  @override
  Future<GroupEventSummary> updateGroupEvent({
    required String eventId,
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    String? location,
    String? description,
    required int expectedVersion,
  }) async {
    eventUpdateCalls++;
    return event;
  }
}

class _AccountBoundGroupDraftRepository extends _P61GroupRepository {
  static const _privateGroup = GroupSummary(
    id: 'group',
    name: 'Private group A',
    ownerUserId: 'viewer',
    type: GroupType.other,
    description: 'Private description from account A',
    role: GroupRole.owner,
  );

  int groupCreateCalls = 0;
  int groupUpdateCalls = 0;

  @override
  Future<GroupSummary> createGroup({
    required String name,
    required String type,
    String? description,
    required String eventCreatePolicy,
  }) async {
    groupCreateCalls++;
    return _privateGroup;
  }

  @override
  Future<List<GroupSummary>> listGroups() async => [_privateGroup];

  @override
  Future<GroupSummary> getGroup(String groupId) async => _privateGroup;

  @override
  Future<GroupSummary> updateGroup({
    required String groupId,
    required String name,
    required String type,
    String? description,
    required String eventCreatePolicy,
  }) async {
    groupUpdateCalls++;
    return _privateGroup;
  }
}

GroupEventComment _comment(String id, String authorId, String body) =>
    GroupEventComment(
      commentId: id,
      eventId: 'event',
      authorUserId: authorId,
      body: body,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 1),
      version: 1,
    );
