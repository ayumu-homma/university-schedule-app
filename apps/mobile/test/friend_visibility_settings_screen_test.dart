import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/friends/application/friend_providers.dart';
import 'package:university_schedule_mobile/features/friends/domain/friend_models.dart';
import 'package:university_schedule_mobile/features/visibility/presentation/visibility_settings_screen.dart';

void main() {
  testWidgets('missing kind rule is shown as inherited, not saved PRIVATE',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [friendsControllerProvider.overrideWith(_Friends.new)],
      child: const MaterialApp(home: VisibilitySettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('保存値: 詳細まで'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('種別').last);
    await tester.pumpAndSettle();
    expect(find.text('対象を選択してください'), findsOneWidget);
    expect(find.text('保存値: 自分のみ'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('授業').last);
    await tester.pumpAndSettle();
    expect(find.text('保存値: 上位の設定を継承'), findsOneWidget);
    expect(find.text('保存値: 自分のみ'), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
  });
}

class _Friends extends FriendsController {
  @override
  Future<FriendState> build() async => const FriendState(
        relationships: [
          FriendRelationship(
            id: 'relation',
            otherUserId: 'friend',
            otherDisplayName: '友だち',
            status: FriendshipStatus.accepted,
          ),
        ],
        visibilityRules: {
          'friend': [
            FriendVisibilityRule(
              targetKind: 'default',
              level: VisibilityLevel.full,
            ),
          ],
        },
      );
}
