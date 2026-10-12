import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../application/local_notification_platform.dart';
import '../application/local_notification_runtime.dart';
import '../application/morning_alarm_controller.dart';

class NotificationInboxScreen extends ConsumerStatefulWidget {
  const NotificationInboxScreen({super.key});

  @override
  ConsumerState<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState
    extends ConsumerState<NotificationInboxScreen> with WidgetsBindingObserver {
  late Future<List<Map<String, Object?>>> _inbox;
  var _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inbox = _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<List<Map<String, Object?>>> _load() {
    final generation = ++_requestGeneration;
    final requestScope = _snapshotKey();
    return ref.read(localNotificationPlatformProvider).readInbox().then((rows) {
      if (!mounted ||
          generation != _requestGeneration ||
          requestScope != _snapshotKey()) {
        return const [];
      }
      return rows;
    });
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _inbox = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(activeScheduleContextProvider);
    ref.watch(morningAlarmControllerProvider);
    ref.watch(demoAppControllerProvider);
    ref.watch(localNotificationRuntimeProvider);
    ref.listen(activeScheduleContextProvider, (_, __) => _refresh());
    ref.listen(morningAlarmControllerProvider, (_, __) => _refresh());
    ref.listen(demoAppControllerProvider, (_, __) => _refresh());
    ref.listen(localNotificationRuntimeProvider, (_, __) => _refresh());
    return MvpScaffold(
      title: '通知の受信箱',
      selectedIndex: 0,
      actions: [
        IconButton(
          tooltip: 'グループ通知',
          onPressed: () => context.push('/notifications/groups'),
          icon: const Icon(Icons.groups_outlined),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<Map<String, Object?>>>(
          future: _inbox,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(children: [
                const SizedBox(height: 180),
                const Center(child: Text('通知を読み込めませんでした')),
                Center(
                    child: TextButton(
                        onPressed: _refresh, child: const Text('再試行'))),
              ]);
            }
            final rows = snapshot.data ?? const [];
            if (rows.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 180),
                Center(child: Text('受信箱に通知はありません')),
              ]);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = rows[index];
                final title = row['title'] as String? ?? '予定';
                final targetPath = row['targetPath'] as String?;
                final represented = row['representedInSummary'] == true;
                return ListTile(
                  key: Key('notification-inbox-${row['identity'] ?? index}'),
                  title: Text(title),
                  subtitle: represented ? const Text('まとめて通知') : null,
                  trailing: targetPath == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: targetPath == null || !_isSafeTarget(targetPath)
                      ? null
                      : () => _openCurrent(context, row),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _openCurrent(
    BuildContext context,
    Map<String, Object?> row,
  ) async {
    final identity = row['identity'] as String?;
    final targetPath = row['targetPath'] as String?;
    if (identity == null || targetPath == null || !_isSafeTarget(targetPath)) {
      return;
    }
    final currentContext = ref.read(activeScheduleContextProvider);
    if (currentContext == null || !mounted) return;
    final scopeAtTap = _snapshotKey();
    final requestGenerationAtTap = _requestGeneration;
    List<Map<String, Object?>> currentRows;
    try {
      currentRows = await ref
          .read(localNotificationPlatformProvider)
          .readInbox(identity: identity);
    } on Object {
      if (mounted && context.mounted) {
        _refresh();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('通知の状態が更新されました。再読み込みしてください。')),
        );
      }
      return;
    }
    if (!mounted ||
        requestGenerationAtTap != _requestGeneration ||
        scopeAtTap != _snapshotKey()) {
      _refresh();
      return;
    }
    Map<String, Object?>? current;
    for (final entry in currentRows) {
      if (entry['identity'] == identity && entry['targetPath'] == targetPath) {
        current = entry;
        break;
      }
    }
    if (current == null) {
      _refresh();
      return;
    }
    if (!context.mounted) return;
    context.push(targetPath);
  }

  bool _isSafeTarget(String path) => RegExp(
        r'^/(course|assignment|exam|event|routine)/[^/?#]+$',
      ).hasMatch(path);

  String _snapshotKey() {
    final context = ref.read(activeScheduleContextProvider);
    final scope = ref.read(morningAlarmControllerProvider).valueOrNull?.scope;
    return [
      context?.ownerUserId,
      context?.universityId,
      context?.termId,
      context?.academicYear,
      context?.primaryCalendarId,
      scope?.regionId,
      scope?.ownerHash,
      scope?.activationToken,
      scope?.generation,
      scope?.active,
    ].map((value) => value?.toString() ?? '<null>').join('|');
  }
}
