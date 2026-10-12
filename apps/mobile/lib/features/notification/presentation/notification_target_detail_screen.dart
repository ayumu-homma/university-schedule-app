import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/mvp_scaffold.dart';
import '../../timetable/application/demo_app_controller.dart';

/// Read-only destination used by ordinary notification taps for entities
/// whose existing product flow only exposed an edit form.  The active
/// schedule provider is the owner boundary; the ID is resolved again here so
/// a stale notification cannot display another owner's row.
class NotificationTargetDetailScreen extends ConsumerWidget {
  const NotificationTargetDetailScreen({
    required this.kind,
    required this.id,
    super.key,
  });

  final String kind;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(demoAppControllerProvider);
    return state.when(
      loading: () => const MvpScaffold(
        title: '予定詳細',
        selectedIndex: 0,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => MvpScaffold(
        title: '予定詳細',
        selectedIndex: 0,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
      data: (snapshot) {
        final detail = _resolve(snapshot);
        if (detail == null) {
          return const MvpScaffold(
            title: '予定詳細',
            selectedIndex: 0,
            child: Center(child: Text('予定が見つかりません')),
          );
        }
        return _NotificationDetailContent(
          kind: kind,
          id: id,
          detail: detail,
        );
      },
    );
  }

  _NotificationDetail? _resolve(DemoAppState state) {
    if (kind == 'exam') {
      for (final exam in state.exams) {
        if (exam.id == id) {
          return _NotificationDetail(
            title: exam.title,
            startAt: exam.startAt,
            endAt: exam.endAt,
            lines: [
              if (exam.examType?.trim().isNotEmpty == true)
                '種別: ${exam.examType}',
              if (exam.room?.trim().isNotEmpty == true) '教室: ${exam.room}',
              if (exam.memo?.trim().isNotEmpty == true) 'メモ: ${exam.memo}',
            ],
            editPath: '/exam/$id/edit',
          );
        }
      }
      return null;
    }
    for (final event in state.events) {
      if (event.id != id ||
          (kind == 'event' && event.kind != EventKind.normal) ||
          (kind == 'routine' && event.kind != EventKind.routine)) {
        continue;
      }
      return _NotificationDetail(
        title: event.title,
        startAt: event.startAt,
        endAt: event.endAt,
        lines: [
          if (event.location?.trim().isNotEmpty == true)
            '場所: ${event.location}',
          if (event.description?.trim().isNotEmpty == true)
            'メモ: ${event.description}',
          if (event.recurrenceRule != null) '繰り返しの初回',
        ],
        editPath: kind == 'routine' ? '/routine/$id/edit' : '/event/$id/edit',
      );
    }
    return null;
  }
}

class _NotificationDetailContent extends StatelessWidget {
  const _NotificationDetailContent({
    required this.kind,
    required this.id,
    required this.detail,
  });

  final String kind;
  final String id;
  final _NotificationDetail detail;

  @override
  Widget build(BuildContext context) {
    final title = switch (kind) {
      'exam' => '試験詳細',
      'routine' => 'ルーティン詳細',
      _ => '予定詳細',
    };
    return MvpScaffold(
      title: title,
      selectedIndex: 0,
      actions: [
        IconButton(
          tooltip: '編集',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => context.go(detail.editPath),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(detail.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.schedule_outlined),
            title: Text(_formatDateTime(detail.startAt)),
            subtitle: Text('終了 ${_formatDateTime(detail.endAt)}'),
          ),
          for (final line in detail.lines)
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text(line),
            ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    final civil = JapanTime.civil(value);
    final minute = civil.minute.toString().padLeft(2, '0');
    return '${civil.year}/${civil.month}/${civil.day} '
        '${civil.hour.toString().padLeft(2, '0')}:$minute';
  }
}

class _NotificationDetail {
  const _NotificationDetail({
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.lines,
    required this.editPath,
  });

  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final List<String> lines;
  final String editPath;
}
