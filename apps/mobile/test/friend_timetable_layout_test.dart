import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/friends/presentation/friend_timetable_screen.dart';

void main() {
  for (final busy in [false, true]) {
    testWidgets(
        'large dark ${busy ? 'BUSY' : 'FULL'} card keeps Japanese time and full title readable',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const title = 'Phase8-大学生活と情報社会のための実践的な共同研究とコミュニケーション演習';
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(
            body: ListView(padding: const EdgeInsets.all(16), children: [
          FriendSharedEventCard(
              event: FriendSharedEvent(
            eventId: 'opaque',
            ownerUserId: 'owner',
            startAt: DateTime.utc(2026, 10, 7, 4, 15),
            endAt: DateTime.utc(2026, 10, 7, 5, 55),
            visibilityLevel:
                busy ? VisibilityLevel.busyOnly : VisibilityLevel.full,
            title: busy ? '予定あり' : title,
            location: busy ? null : 'Phase8-Room-203',
          )),
        ])),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('10/7（水） 13:15〜14:55'), findsOneWidget);
      expect(find.text(busy ? '予定あり' : title), findsOneWidget);
      if (!busy) {
        await tester.ensureVisible(find.text('場所: Phase8-Room-203'));
        expect(tester.takeException(), isNull);
      }
    });
  }
}
