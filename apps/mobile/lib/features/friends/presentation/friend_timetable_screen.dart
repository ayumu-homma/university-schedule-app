import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../../auth/application/auth_providers.dart';
import '../application/friend_providers.dart';
import '../domain/friend_models.dart';

class FriendTimetableScreen extends ConsumerStatefulWidget {
  const FriendTimetableScreen({
    required this.friendUserId,
    this.eventId,
    this.preview = false,
    @visibleForTesting this.loadOnInit = true,
    super.key,
  });

  final String friendUserId;
  final String? eventId;
  final bool preview;
  final bool loadOnInit;

  @override
  ConsumerState<FriendTimetableScreen> createState() =>
      _FriendTimetableScreenState();
}

class _FriendTimetableScreenState extends ConsumerState<FriendTimetableScreen> {
  FriendsController? _controller;
  final Object _view = Object();
  int _viewerIdentityEpoch = 0;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(friendsControllerProvider.notifier);
    _controller!.claimForegroundView(_view);
    if (widget.loadOnInit) Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      scheduleMicrotask(() => controller.releaseForegroundView(_view));
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FriendTimetableScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loadOnInit &&
        (oldWidget.friendUserId != widget.friendUserId ||
            oldWidget.eventId != widget.eventId ||
            oldWidget.preview != widget.preview)) {
      Future<void>.microtask(_load);
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final state = await ref.read(friendsControllerProvider.future);
    if (!mounted) return;
    final relationship = state.relationships
        .where((item) => item.otherUserId == widget.friendUserId)
        .firstOrNull;
    if (relationship == null || (!widget.preview && !relationship.isAccepted)) {
      return;
    }
    final controller = ref.read(friendsControllerProvider.notifier);
    _controller = controller;
    if (widget.preview) {
      await controller.previewFriend(relationship);
    } else {
      await controller.selectFriend(relationship);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentAuthSessionProvider, (previous, next) {
      if (previous?.userId != next?.userId) _viewerIdentityEpoch++;
    });
    final asyncState = ref.watch(friendsControllerProvider);
    final state = asyncState.valueOrNull ?? const FriendState();
    final relationship = state.relationships
        .where((item) => item.otherUserId == widget.friendUserId)
        .firstOrNull;
    final modeMatches = state.scheduleFriendId == widget.friendUserId &&
        state.schedulePreview == widget.preview;
    final rows = !modeMatches
        ? const <FriendSharedEvent>[]
        : widget.eventId == null
            ? state.schedule
            : state.schedule.where((item) => item.eventId == widget.eventId);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(context);
      },
      child: MvpScaffold(
        title: widget.preview ? '公開範囲プレビュー' : '友だちの時間割',
        selectedIndex: 4,
        showQuickAdd: false,
        actions: [
          if (relationship != null)
            IconButton(
              tooltip: '共有設定',
              onPressed: () => context.go(
                '/visibility/friend/${Uri.encodeComponent(widget.friendUserId)}',
              ),
              icon: const Icon(Icons.tune),
            ),
          if (relationship != null &&
              relationship.isAccepted &&
              !widget.preview)
            PopupMenuButton<String>(
              tooltip: '友だち操作',
              onSelected: (value) => unawaited(_relationshipAction(
                context,
                relationship,
                value,
              )),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'remove', child: Text('友だちから削除')),
                PopupMenuItem(value: 'block', child: Text('ブロック')),
              ],
            ),
        ],
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.eventId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _back(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('一覧に戻る'),
                ),
              ),
            if (relationship != null)
              Text(
                relationship.otherDisplayName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            const SizedBox(height: 8),
            const Text('時刻は日本時間で表示しています。'),
            const Text(
              'ここに表示されない予定は、非公開の可能性があります。空き時間の保証ではありません。',
            ),
            if (state.isLoading) ...[
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
            ] else if (state.errorMessage != null || state.isOffline) ...[
              const SizedBox(height: 24),
              EmptyState(
                icon: Icons.cloud_off_outlined,
                title: '共有予定を確認できません',
                message: state.errorMessage ?? '通信を確認してから、再読み込みしてください。',
                action: OutlinedButton.icon(
                  onPressed: () => unawaited(_load()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('再読み込み'),
                ),
              ),
            ] else if (!state.scheduleAllowed || rows.isEmpty) ...[
              const SizedBox(height: 24),
              const EmptyState(
                icon: Icons.visibility_off_outlined,
                title: '共有されている予定はありません',
                message: '非公開の予定は表示されません。',
              ),
            ] else ...[
              const SizedBox(height: 16),
              for (final row in rows)
                FriendSharedEventCard(
                  event: row,
                  onTap: widget.eventId == null
                      ? () => context.go(
                            widget.preview
                                ? '/shared/friend/${Uri.encodeComponent(widget.friendUserId)}/preview/event/${Uri.encodeComponent(row.eventId)}'
                                : '/shared/friend/${Uri.encodeComponent(widget.friendUserId)}/event/${Uri.encodeComponent(row.eventId)}',
                          )
                      : null,
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _back(BuildContext context) {
    final friend = Uri.encodeComponent(widget.friendUserId);
    context.go(widget.eventId != null
        ? '/shared/friend/$friend${widget.preview ? '/preview' : ''}'
        : widget.preview
            ? '/visibility/friend/$friend'
            : '/shared');
  }

  Future<void> _relationshipAction(
    BuildContext context,
    FriendRelationship relationship,
    String action,
  ) async {
    final viewerUserId = ref.read(currentAuthSessionProvider)?.userId;
    if (viewerUserId == null) return;
    final viewerIdentityEpoch = _viewerIdentityEpoch;
    final title = action == 'block' ? 'この人をブロックしますか？' : '友だちから削除しますか？';
    final detail =
        action == 'block' ? '相互の予定閲覧と新しい申請が停止します。' : '共有予定と公開範囲の設定が無効になります。';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _viewerIdentityEpoch != viewerIdentityEpoch ||
        ref.read(currentAuthSessionProvider)?.userId != viewerUserId) {
      return;
    }
    final currentRelationship = ref
        .read(friendsControllerProvider)
        .valueOrNull
        ?.relationships
        .where((item) =>
            item.id == relationship.id &&
            item.otherUserId == relationship.otherUserId &&
            item.incarnation == relationship.incarnation &&
            item.revision == relationship.revision &&
            item.isAccepted)
        .firstOrNull;
    if (currentRelationship == null) return;
    final controller = ref.read(friendsControllerProvider.notifier);
    final ok = action == 'block'
        ? await controller.blockUser(currentRelationship)
        : await controller.removeFriend(currentRelationship);
    if (ok && context.mounted) context.go('/shared');
  }
}

class FriendSharedEventCard extends StatelessWidget {
  const FriendSharedEventCard({required this.event, this.onTap, super.key});

  final FriendSharedEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final start = event.startAt.toUtc().add(const Duration(hours: 9));
    final end = event.endAt.toUtc().add(const Duration(hours: 9));
    final sameDay = start.year == end.year &&
        start.month == end.month &&
        start.day == end.day;
    final time =
        '${_date(start)} ${_clock(start)}〜${sameDay ? '' : '${_date(end)} '}${_clock(end)}';
    final title = event.title ?? '予定あり';
    final details = <String>[
      if (event.instructorName != null) '担当: ${event.instructorName!}',
      if (event.location != null) '場所: ${event.location!}',
      if (event.description != null) event.description!,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(time, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Icon(_icon(event.kind), size: 20),
                    PrivacyChip(level: event.visibilityLevel),
                  ]),
              const SizedBox(height: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              for (final detail in details) ...[
                const SizedBox(height: 6),
                Text(detail),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _clock(DateTime value) =>
      '${value.hour}:${value.minute.toString().padLeft(2, '0')}';

  String _date(DateTime local) {
    const weekdays = ['月', '火', '水', '木', '金', '土', '日'];
    return '${local.month}/${local.day}（${weekdays[local.weekday - 1]}）';
  }

  IconData _icon(String? kind) {
    return switch (kind) {
      'course' => Icons.school_outlined,
      'exam' => Icons.quiz_outlined,
      'routine' => Icons.repeat_outlined,
      _ => Icons.event_outlined,
    };
  }
}

class PrivacyChip extends StatelessWidget {
  const PrivacyChip({required this.level, super.key});

  final VisibilityLevel level;

  @override
  Widget build(BuildContext context) {
    return PrivacyBadge(level: level);
  }
}

class BlockedFriendsScreen extends ConsumerWidget {
  const BlockedFriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(friendsControllerProvider).valueOrNull ?? const FriendState();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/shared');
      },
      child: MvpScaffold(
        title: 'ブロック一覧',
        selectedIndex: 4,
        showQuickAdd: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('ブロック中は相互の予定閲覧と新しい申請ができません。解除しても以前の友だち関係や公開範囲は復活しません。'),
            if (state.errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                state.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            if (state.blockedUserIds.isEmpty)
              const EmptyState(
                icon: Icons.check_circle_outline,
                title: 'ブロックしている人はいません',
                message: '必要なときだけこの画面から解除できます。',
              )
            else
              for (final entry in state.blockedUsers.entries)
                ListTile(
                  leading: const Icon(Icons.block),
                  title: Text(entry.value),
                  subtitle: Text('ユーザー ${_shortId(entry.key)}'),
                  trailing: TextButton(
                    onPressed: state.isMutating
                        ? null
                        : () async {
                            await ref
                                .read(friendsControllerProvider.notifier)
                                .unblockUser(entry.key);
                          },
                    child: const Text('解除'),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  static String _shortId(String id) => id.length <= 8
      ? id
      : '${id.substring(0, 4)}…${id.substring(id.length - 4)}';
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
