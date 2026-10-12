import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:university_schedule_mobile/core/native/native_scope_bridge.dart';
import 'package:university_schedule_mobile/features/notification/application/local_notification_platform.dart';
import 'package:university_schedule_mobile/features/notification/application/local_notification_runtime.dart';
import 'package:university_schedule_mobile/features/notification/application/morning_alarm_controller.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/morning_alarm_models.dart';
import 'package:university_schedule_mobile/features/notification/presentation/notification_inbox_screen.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  testWidgets('renders every native inbox member and disables unsafe targets',
      (tester) async {
    final rows = [
      for (var index = 0; index < 201; index++)
        {
          'identity': 'member-$index',
          'title': 'Member $index',
          'targetPath':
              index == 200 ? 'https://invalid.example' : '/event/e-$index',
          'representedInSummary': true,
        },
    ];
    final fake = _FakeNotificationPlatform(rows);
    await _pumpInbox(tester, fake);
    await tester.pumpAndSettle();
    expect(fake.readInboxCalls, greaterThanOrEqualTo(1));
    expect(find.text('Member 0'), findsOneWidget);
    expect(
        find.byKey(const Key('notification-inbox-member-200')), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    expect(find.text('Member 200'), findsOneWidget);
    final unsafe = tester.widget<ListTile>(
      find.byKey(const Key('notification-inbox-member-200')),
    );
    expect(unsafe.onTap, isNull);
  });

  testWidgets('reloads and hides a row after the canonical source changes',
      (tester) async {
    final fake = _FakeNotificationPlatform([_row('assignment-1', 'Draft')]);
    await _pumpInbox(tester, fake);
    await tester.pumpAndSettle();
    expect(find.text('Draft'), findsOneWidget);

    fake.rows = const [];
    final container = _containerFor(tester);
    final schedule =
        container.read(demoAppControllerProvider.notifier) as _Schedule;
    schedule.emit();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fake.readInboxCalls, greaterThanOrEqualTo(2));
    expect(find.text('Draft'), findsNothing);
    expect(find.text('受信箱に通知はありません'), findsOneWidget);
  });

  testWidgets('discards same-owner activation ABA results from an old load',
      (tester) async {
    final current = _row('event-1', 'Owner A');
    final fake = _FakeNotificationPlatform([current]);
    await _pumpInbox(tester, fake);
    await tester.pumpAndSettle();
    expect(find.text('Owner A'), findsOneWidget);

    fake.deferReads = true;
    final container = _containerFor(tester);
    final alarm =
        container.read(morningAlarmControllerProvider.notifier) as _Alarm;
    alarm.publish(_scope(2));
    await tester.pump();
    alarm.publish(_scope(1));
    await tester.pump();
    expect(fake.pendingReads.length, greaterThanOrEqualTo(2));

    fake.completeNext(rows: [_row('event-1', 'Stale B')]);
    await tester.pump();
    expect(find.text('Stale B'), findsNothing);

    fake.completeNext(rows: [current]);
    await tester.pump();
    expect(find.text('Owner A'), findsOneWidget);
  });

  testWidgets('rejects navigation when owner-same scope changes during tap',
      (tester) async {
    final row = _row('event-1', 'Tap me');
    final fake = _FakeNotificationPlatform([row]);
    final router = _router();
    addTearDown(router.dispose);
    await _pumpInbox(tester, fake, router: router);
    await tester.pumpAndSettle();
    expect(find.text('Tap me'), findsOneWidget);

    fake.deferReads = true;
    await tester.tap(find.byKey(const Key('notification-inbox-event-1')));
    await tester.pump();
    final container = _containerFor(tester);
    final alarm =
        container.read(morningAlarmControllerProvider.notifier) as _Alarm;
    alarm.publish(_scope(2));
    await tester.pump();
    alarm.publish(_scope(1));
    await tester.pump();

    fake.completeNext(rows: [row]);
    await tester.pump();
    expect(find.text('opened:event-1'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('revalidates canonical identity and target path before routing',
      (tester) async {
    final row = _row('event-1', 'Canonical event');
    final fake = _FakeNotificationPlatform([row]);
    fake.identityResponses['event-1'] = [
      _row('event-1', 'Canonical event', path: '/event/other')
    ];
    final router = _router();
    addTearDown(router.dispose);
    await _pumpInbox(tester, fake, router: router);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notification-inbox-event-1')));
    await tester.pump();
    expect(find.text('opened:event-1'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(fake.requestedIdentities, contains('event-1'));
  });

  testWidgets('recovers from a native inbox lookup failure by reloading',
      (tester) async {
    final row = _row('event-1', 'Recoverable event');
    final fake = _FakeNotificationPlatform([row]);
    await _pumpInbox(tester, fake);
    await tester.pumpAndSettle();

    fake.failNextRead = StateError('native lookup unavailable');
    await tester.tap(find.byKey(const Key('notification-inbox-event-1')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Recoverable event'), findsOneWidget);
    expect(find.text('通知の状態が更新されました。再読み込みしてください。'), findsOneWidget);
    expect(fake.readInboxCalls, greaterThanOrEqualTo(3));
  });
}

const _context = ActiveScheduleContext(
  ownerUserId: 'owner-a',
  universityId: 'university-a',
  termId: 'term-a',
  academicYear: 2026,
  primaryCalendarId: 'calendar-a',
);

List<Override> _overrides(_FakeNotificationPlatform fake) => [
      localNotificationPlatformProvider.overrideWithValue(fake),
      activeScheduleContextProvider.overrideWithValue(_context),
      demoAppControllerProvider.overrideWith(_Schedule.new),
      morningAlarmControllerProvider.overrideWith(_Alarm.new),
      localNotificationRuntimeProvider.overrideWith(_Runtime.new),
    ];

Future<void> _pumpInbox(
  WidgetTester tester,
  _FakeNotificationPlatform fake, {
  GoRouter? router,
}) async {
  final child = router == null
      ? const MaterialApp(home: NotificationInboxScreen())
      : MaterialApp.router(routerConfig: router);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(fake),
      child: child,
    ),
  );
  await tester.pump();
  await tester.pump();
}

ProviderContainer _containerFor(WidgetTester tester) {
  return ProviderScope.containerOf(
    tester.element(find.byType(NotificationInboxScreen)),
  );
}

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const NotificationInboxScreen(),
        ),
        GoRoute(
          path: '/event/:id',
          builder: (_, state) => Scaffold(
            body: Text('opened:${state.pathParameters['id']}'),
          ),
        ),
      ],
    );

Map<String, Object?> _row(String identity, String title, {String? path}) => {
      'identity': identity,
      'title': title,
      'targetPath': path ?? '/event/$identity',
      'representedInSummary': true,
    };

NativeScopeState _scope(int generation) => NativeScopeState(
      regionId: 'test-region',
      ownerHash: 'owner-hash',
      activationToken: 'activation-$generation',
      generation: generation,
      active: true,
    );

MorningAlarmPlatformState _alarmState(NativeScopeState scope) =>
    MorningAlarmPlatformState(
      ownerUserId: _context.ownerUserId,
      settings: MorningAlarmSettings(ownerUserId: _context.ownerUserId),
      capabilities: const MorningAlarmCapabilities.unavailable(),
      nextOccurrence: null,
      scope: scope,
    );

class _Alarm extends MorningAlarmController {
  @override
  Future<MorningAlarmPlatformState> build() async => _alarmState(_scope(1));

  void publish(NativeScopeState scope) => state = AsyncData(_alarmState(scope));
}

class _Runtime extends LocalNotificationRuntime {
  @override
  Future<LocalNotificationPlatformState> build() async =>
      const LocalNotificationPlatformState(
        permission: 'granted',
        exactAlarm: 'granted',
        scheduledCount: 0,
      );
}

class _Schedule extends DemoAppController {
  final _updates = StreamController<DemoAppState>.broadcast();

  @override
  Stream<DemoAppState> build() async* {
    ref.onDispose(() {
      _updates.close();
    });
    yield DemoAppState.empty(now: DateTime.utc(2026, 9, 20));
    yield* _updates.stream;
  }

  void emit() =>
      _updates.add(DemoAppState.empty(now: DateTime.utc(2026, 9, 20)));
}

class _PendingRead {
  _PendingRead(this.identity, this.completer);

  final String? identity;
  final Completer<List<Map<String, Object?>>> completer;
}

class _FakeNotificationPlatform implements LocalNotificationPlatform {
  _FakeNotificationPlatform(this.rows);

  List<Map<String, Object?>> rows;
  bool deferReads = false;
  Object? failNextRead;
  final pendingReads = <_PendingRead>[];
  final requestedIdentities = <String?>[];
  final identityResponses = <String, List<Map<String, Object?>>>{};
  var readInboxCalls = 0;

  @override
  Future<List<Map<String, Object?>>> readInbox({String? identity}) {
    readInboxCalls += 1;
    requestedIdentities.add(identity);
    final error = failNextRead;
    failNextRead = null;
    if (deferReads) {
      final completer = Completer<List<Map<String, Object?>>>();
      pendingReads.add(_PendingRead(identity, completer));
      return completer.future;
    }
    if (error != null) return Future<List<Map<String, Object?>>>.error(error);
    return Future.value(_response(identity));
  }

  void completeNext({List<Map<String, Object?>>? rows}) {
    final pending = pendingReads.removeAt(0);
    pending.completer.complete(rows ?? _response(pending.identity));
  }

  List<Map<String, Object?>> _response(String? identity) {
    final selected =
        identity == null ? rows : identityResponses[identity] ?? rows;
    return selected.map((row) => Map<String, Object?>.from(row)).toList();
  }

  @override
  Future<LocalNotificationPlatformState> publishProjection({
    required Map<String, Object?> payload,
  }) async =>
      const LocalNotificationPlatformState(
        permission: 'granted',
        exactAlarm: 'granted',
        scheduledCount: 0,
      );

  @override
  Future<LocalNotificationPlatformState> reconcile({
    required String databasePath,
    required NativeScopeState scope,
    required List<LocalNotificationPlan> plans,
  }) async =>
      const LocalNotificationPlatformState(
        permission: 'granted',
        exactAlarm: 'granted',
        scheduledCount: 0,
      );

  @override
  Future<void> openExactAlarmSettings() async {}

  @override
  Future<void> openNotificationSettings() async {}
}
