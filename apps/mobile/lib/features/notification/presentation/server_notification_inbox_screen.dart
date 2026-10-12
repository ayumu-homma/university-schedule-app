import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/mvp_scaffold.dart';
import '../../auth/application/auth_providers.dart';
import '../application/server_notification_providers.dart';
import '../domain/server_notification.dart';

class ServerNotificationInboxScreen extends ConsumerStatefulWidget {
  const ServerNotificationInboxScreen({super.key});

  @override
  ConsumerState<ServerNotificationInboxScreen> createState() =>
      _ServerNotificationInboxScreenState();
}

class _ServerNotificationInboxScreenState
    extends ConsumerState<ServerNotificationInboxScreen> {
  List<ServerNotification> _notifications = const [];
  List<TargetedGroupInvitation> _invitations = const [];
  String? _error;
  String? _loadingUserId;
  var _generation = 0;
  var _loading = true;
  var _loadingMore = false;
  var _hasMore = false;
  final Set<String> _busyInvitations = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(currentAuthSessionProvider);
    ref.listen(currentAuthSessionProvider, (previous, next) {
      if (previous?.userId != next?.userId) {
        setState(() {
          _notifications = const [];
          _invitations = const [];
          _busyInvitations.clear();
          _error = null;
          _loading = true;
        });
        _reload();
      }
    });
    if (session?.userId != _loadingUserId && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    }
    return MvpScaffold(
      title: 'グループ通知',
      selectedIndex: 4,
      actions: [
        IconButton(
          tooltip: '再読み込み',
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _reload,
        child: _content(),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(children: [
        const SizedBox(height: 150),
        const Center(child: Text('グループ通知を読み込めませんでした')),
        Center(
          child: TextButton(onPressed: _reload, child: const Text('再試行')),
        ),
      ]);
    }
    if (_notifications.isEmpty && _invitations.isEmpty) {
      return ListView(children: const [
        SizedBox(height: 150),
        Center(child: Text('グループ通知はありません')),
      ]);
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_invitations.isNotEmpty) ...[
          Text('グループへの招待', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._invitations.map(_invitationCard),
          const SizedBox(height: 16),
        ],
        if (_notifications.isNotEmpty) ...[
          Text('お知らせ', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ..._notifications.map(_notificationTile),
          if (_hasMore)
            Center(
              child: TextButton(
                onPressed: _loadingMore ? null : _loadMore,
                child: _loadingMore
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('さらに読み込む'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _invitationCard(TargetedGroupInvitation invitation) {
    final busy = _busyInvitations.contains(invitation.id);
    return Card(
      key: Key('targeted-invitation-${invitation.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(invitation.groupName,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('${invitation.inviterName} さんからの招待'),
            Text('期限: ${_date(invitation.expiresAt)}'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                onPressed: busy ? null : () => _respond(invitation, false),
                child: const Text('辞退'),
              ),
              FilledButton(
                onPressed: busy ? null : () => _respond(invitation, true),
                child: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('参加する'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _notificationTile(ServerNotification notification) {
    final isUnread = notification.readAt == null;
    return Card(
      child: ListTile(
        key: Key('server-notification-${notification.id}'),
        leading: Icon(isUnread
            ? Icons.notifications_active_outlined
            : Icons.notifications_none),
        title: Text(_title(notification.type)),
        subtitle: Text(_date(notification.createdAt)),
        trailing: notification.type == 'group_invitation'
            ? null
            : const Icon(Icons.chevron_right),
        onTap: notification.type == 'group_invitation'
            ? null
            : () => _openGroup(notification),
      ),
    );
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    final userId = ref.read(currentAuthSessionProvider)?.userId;
    setState(() {
      _loading = true;
      _loadingUserId = userId;
      _error = null;
    });
    if (userId == null) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _notifications = const [];
          _invitations = const [];
        });
      }
      return;
    }
    try {
      final repository = ref.read(serverNotificationRepositoryProvider);
      final notifications = await repository.list(limit: 30);
      final invitations = await repository.listInvitations();
      if (!mounted ||
          generation != _generation ||
          ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      setState(() {
        _notifications = notifications;
        _hasMore = notifications.length == 30;
        _invitations = invitations;
        _loading = false;
      });
    } on Object {
      if (!mounted ||
          generation != _generation ||
          ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      setState(() {
        _notifications = const [];
        _hasMore = false;
        _invitations = const [];
        _loading = false;
        _error = 'load_failed';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _notifications.isEmpty) return;
    final userId = ref.read(currentAuthSessionProvider)?.userId;
    if (userId == null) return;
    final generation = _generation;
    final last = _notifications.last;
    setState(() => _loadingMore = true);
    try {
      final page = await ref.read(serverNotificationRepositoryProvider).list(
            before: last.createdAt,
            beforeId: last.id,
            limit: 30,
          );
      if (!mounted ||
          generation != _generation ||
          ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      setState(() {
        final known = _notifications.map((row) => row.id).toSet();
        _notifications = [
          ..._notifications,
          ...page.where((row) => !known.contains(row.id)),
        ];
        _hasMore = page.length == 30;
      });
    } on Object {
      if (mounted &&
          generation == _generation &&
          ref.read(currentAuthSessionProvider)?.userId == userId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('続きの通知を読み込めませんでした。')),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _respond(TargetedGroupInvitation invitation, bool accept) async {
    final userId = ref.read(currentAuthSessionProvider)?.userId;
    if (userId == null || !_busyInvitations.add(invitation.id)) {
      return;
    }
    setState(() {});
    final generation = _generation;
    try {
      await ref.read(serverNotificationRepositoryProvider).respondToInvitation(
            invitation.id,
            accept: accept,
          );
      if (!mounted ||
          generation != _generation ||
          ref.read(currentAuthSessionProvider)?.userId != userId) {
        return;
      }
      await _reload();
    } on Object {
      if (mounted && ref.read(currentAuthSessionProvider)?.userId == userId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('招待の状態を更新できませんでした。再読み込みしてください。')),
        );
        await _reload();
      }
    } finally {
      _busyInvitations.remove(invitation.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openGroup(ServerNotification notification) async {
    final userId = ref.read(currentAuthSessionProvider)?.userId;
    if (userId == null || notification.groupId.isEmpty) return;
    final generation = _generation;
    try {
      final stillAuthorized = await ref
          .read(serverNotificationRepositoryProvider)
          .markRead(notification.id);
      if (!mounted ||
          generation != _generation ||
          ref.read(currentAuthSessionProvider)?.userId != userId ||
          !stillAuthorized) {
        await _reload();
        return;
      }
      setState(() {
        _notifications = _notifications
            .map((row) => row.id == notification.id
                ? ServerNotification(
                    id: row.id,
                    type: row.type,
                    groupId: row.groupId,
                    eventId: row.eventId,
                    invitationId: row.invitationId,
                    createdAt: row.createdAt,
                    readAt: row.readAt ?? DateTime.now().toUtc(),
                  )
                : row)
            .toList(growable: false);
      });
      context.push('/group/${notification.groupId}');
    } on Object {
      if (mounted && ref.read(currentAuthSessionProvider)?.userId == userId) {
        await _reload();
      }
    }
  }

  String _title(String type) => switch (type) {
        'group_invitation' => 'グループへの招待',
        'group_event_created' => 'グループ予定が追加されました',
        'group_event_updated' => 'グループ予定が更新されました',
        'group_comment' => 'グループ予定にコメントがあります',
        _ => 'グループのお知らせ',
      };

  String _date(DateTime value) {
    final local = value.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
