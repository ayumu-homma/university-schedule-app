import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('purges only the deleted owner and applies confirmed group actions',
      () async {
    const owner = 'deleted-user';
    const successor = 'next-owner';
    const peer = 'other-device-user';
    await db.customStatement(
      "INSERT INTO profiles(user_id, display_name) VALUES (?, 'Deleted'), (?, 'Peer')",
      [owner, peer],
    );
    await db.customStatement(
      "INSERT INTO groups(id, owner_user_id, name) VALUES ('transfer', ?, 'Transfer'), ('disband', ?, 'Disband'), ('peer-group', ?, 'Peer')",
      [owner, owner, peer],
    );
    await db.customStatement(
      "INSERT INTO group_members(group_id, user_id, role) VALUES ('transfer', ?, 'owner'), ('transfer', ?, 'member'), ('disband', ?, 'owner'), ('disband', ?, 'member'), ('peer-group', ?, 'member')",
      [owner, successor, owner, peer, owner],
    );
    await db.customStatement(
      "INSERT INTO calendars(id, owner_user_id, group_id, name) VALUES ('cal-transfer', ?, 'transfer', 'Shared'), ('cal-disband', ?, 'disband', 'Removed'), ('cal-peer', ?, 'peer-group', 'Peer')",
      [owner, owner, peer],
    );
    await db.customStatement(
      '''
      INSERT INTO events(id, owner_user_id, calendar_id, group_id, title, kind, start_at, end_at)
      VALUES ('event-transfer', ?, 'cal-transfer', 'transfer', 'Shared', 'class', '2026-09-23', '2026-09-23'),
             ('event-disband', ?, 'cal-disband', 'disband', 'Removed', 'class', '2026-09-23', '2026-09-23'),
             ('event-personal', ?, 'cal-personal', NULL, 'Private', 'personal', '2026-09-23', '2026-09-23'),
             ('event-peer', ?, 'cal-peer', 'peer-group', 'Peer event', 'class', '2026-09-23', '2026-09-23'),
             ('event-other-personal', ?, 'other-personal', NULL, 'Other', 'personal', '2026-09-23', '2026-09-23')
      ''',
      [owner, owner, owner, peer, peer],
    );
    await db.customStatement(
      "INSERT INTO event_comments(id, event_id, author_user_id, body) VALUES ('comment-own', 'event-transfer', ?, 'Private authored comment'), ('comment-peer', 'event-peer', ?, 'Peer comment'), ('comment-personal', 'event-personal', ?, 'Personal comment')",
      [owner, peer, owner],
    );
    await db.customStatement(
      "INSERT INTO friendships(id, requester_user_id, addressee_user_id, status) VALUES ('friendship-own', ?, ?, 'accepted'), ('friendship-peer', ?, ?, 'accepted')",
      [owner, peer, peer, successor],
    );

    final actions = <Map<String, Object?>>[
      {'group_id': 'transfer', 'action': 'transfer', 'successor_id': successor},
      {'group_id': 'disband', 'action': 'disband'},
    ];
    await db.purgeAccountData(ownerUserId: owner, groupActions: actions);
    await db.purgeAccountData(ownerUserId: owner, groupActions: actions);

    final transferred = await db
        .customSelect(
          "SELECT owner_user_id FROM groups WHERE id = 'transfer'",
        )
        .getSingle();
    expect(transferred.read<String>('owner_user_id'), successor);
    final sharedEvent = await db
        .customSelect(
          "SELECT owner_user_id FROM events WHERE id = 'event-transfer'",
        )
        .getSingle();
    expect(sharedEvent.read<String>('owner_user_id'), successor);
    expect(
      await db.customSelect("SELECT id FROM groups WHERE id = 'disband'").get(),
      isEmpty,
    );
    expect(
      await db
          .customSelect("SELECT id FROM events WHERE id = 'event-disband'")
          .get(),
      isEmpty,
    );
    expect(
      await db
          .customSelect("SELECT id FROM events WHERE id = 'event-personal'")
          .get(),
      isEmpty,
    );
    expect(
      await db
          .customSelect("SELECT id FROM events WHERE id = 'event-peer'")
          .get(),
      hasLength(1),
    );
    expect(
      await db
          .customSelect(
              "SELECT id FROM events WHERE id = 'event-other-personal'")
          .get(),
      hasLength(1),
    );
    expect(
      await db
          .customSelect(
            "SELECT id FROM event_comments WHERE author_user_id = '$owner'",
          )
          .get(),
      isEmpty,
    );
    final peerComments = await db
        .customSelect(
          "SELECT id FROM event_comments WHERE id = 'comment-peer'",
        )
        .get();
    expect(peerComments, hasLength(1));
    expect(
      await db
          .customSelect(
            "SELECT user_id FROM profiles WHERE user_id = '$owner'",
          )
          .get(),
      isEmpty,
    );
    expect(
      await db
          .customSelect(
              "SELECT id FROM friendships WHERE id = 'friendship-peer'")
          .get(),
      hasLength(1),
    );
  });
}
