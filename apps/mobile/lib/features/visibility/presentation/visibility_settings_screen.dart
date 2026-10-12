import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/privacy_badge.dart';
import '../../friends/application/friend_providers.dart';
import '../../friends/domain/friend_models.dart';
import '../../timetable/application/demo_app_controller.dart';

class VisibilitySettingsScreen extends ConsumerWidget {
  const VisibilitySettingsScreen({this.friendUserId, super.key});

  final String? friendUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(friendsControllerProvider).valueOrNull ?? const FriendState();
    final friends = state.relationships
        .where((item) => item.isAccepted)
        .where(
          (item) => friendUserId == null || item.otherUserId == friendUserId,
        )
        .toList(growable: false);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          context.go(friendUserId == null
              ? '/shared'
              : '/shared/friend/${Uri.encodeComponent(friendUserId!)}');
        }
      },
      child: MvpScaffold(
        title: '公開範囲',
        selectedIndex: 4,
        showQuickAdd: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '初期値は自分のみです。友だちごとに、時間・タイトル・詳細のどこまで見せるかを選べます。保存後、相手の時間割には許可された範囲だけ表示されます。',
            ),
            const SizedBox(height: 16),
            for (final friend in friends)
              _FriendVisibilityCard(
                friend: friend,
                rules: state.visibilityRules[friend.otherUserId] ?? const [],
              ),
            if (friends.isEmpty)
              const EmptyState(
                icon: Icons.people_outline,
                title: '設定できる友だちはいません',
                message: '承認済みの友だちが表示されます。',
              ),
            const SizedBox(height: 20),
            const Divider(),
            const Text('公開範囲の意味',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final level in VisibilityLevel.values)
              ListTile(
                leading: PrivacyBadge(level: level),
                title: Text(_title(level)),
                subtitle: Text(_description(level)),
              ),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('非公開は空き時間の保証ではありません'),
              subtitle: Text('相手には予定を返さず、空いているかどうかも判断できない表示にします。'),
            ),
          ],
        ),
      ),
    );
  }

  String _title(VisibilityLevel level) => switch (level) {
        VisibilityLevel.private => '自分のみ',
        VisibilityLevel.busyOnly => '予定ありのみ',
        VisibilityLevel.titleOnly => 'タイトルのみ',
        VisibilityLevel.full => '詳細まで',
      };

  String _description(VisibilityLevel level) => switch (level) {
        VisibilityLevel.private => '対象の予定を返しません',
        VisibilityLevel.busyOnly => '時間と「予定あり」だけを返します',
        VisibilityLevel.titleOnly => '許可されたタイトル・時間・種別を返します',
        VisibilityLevel.full => '許可された詳細まで返します。個人メモや提出状態は含みません',
      };
}

class _FriendVisibilityCard extends ConsumerStatefulWidget {
  const _FriendVisibilityCard({required this.friend, required this.rules});

  final FriendRelationship friend;
  final List<FriendVisibilityRule> rules;

  @override
  ConsumerState<_FriendVisibilityCard> createState() =>
      _FriendVisibilityCardState();
}

class _FriendVisibilityCardState extends ConsumerState<_FriendVisibilityCard> {
  String _targetKind = 'default';
  VisibilityLevel _level = VisibilityLevel.private;
  VisibilityLevel _savedLevel = VisibilityLevel.private;
  bool _inherit = false;
  bool _savedInherit = false;
  bool _saving = false;
  late final TextEditingController _targetController;

  @override
  void initState() {
    super.initState();
    _level = widget.friend.visibilityLevel;
    _targetController = TextEditingController();
    _applyRule();
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _FriendVisibilityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rules != widget.rules ||
        oldWidget.friend.revision != widget.friend.revision) {
      _applyRule();
    }
  }

  void _applyRule() {
    FriendVisibilityRule? rule;
    for (final item in widget.rules) {
      if (item.targetKind != _targetKind) continue;
      if (_targetKind == 'event_kind') {
        if (item.targetValue == _targetController.text) {
          rule = item;
          break;
        }
        continue;
      }
      if (_targetKind == 'default' || item.targetId == _targetController.text) {
        rule = item;
        break;
      }
    }
    void apply() {
      _savedLevel = rule?.level ?? widget.friend.visibilityLevel;
      // An absent individual/kind rule is inheritance, not an explicit PRIVATE
      // decision. Only the server projection can certify the effective level.
      _savedInherit = rule?.inherited ?? (_targetKind != 'default');
      _level = _savedLevel;
      _inherit = _savedInherit;
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetNeedsValue = _targetKind != 'default';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.friend.otherDisplayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '相手からの見え方を確認',
                  onPressed: () => context.go(
                    '/shared/friend/${Uri.encodeComponent(widget.friend.otherUserId)}/preview',
                  ),
                  icon: const Icon(Icons.preview_outlined),
                ),
              ],
            ),
            Text(
              '誰に何を共有するか',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            DropdownButtonFormField<String>(
              initialValue: _targetKind,
              decoration: const InputDecoration(labelText: '対象'),
              items: const [
                DropdownMenuItem(value: 'default', child: Text('この友だちへの初期値')),
                DropdownMenuItem(value: 'event_kind', child: Text('種別')),
                DropdownMenuItem(value: 'course', child: Text('個別コース')),
                DropdownMenuItem(value: 'event', child: Text('個別予定')),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _targetKind = value;
                        _targetController.clear();
                        _inherit = false;
                      });
                      _applyRule();
                    },
            ),
            if (targetNeedsValue) _targetField(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('初期値に戻す'),
              subtitle: const Text('上位の公開範囲を継承します'),
              value: _inherit,
              onChanged:
                  _saving ? null : (value) => setState(() => _inherit = value),
            ),
            Text(
              targetNeedsValue && _targetController.text.isEmpty
                  ? '対象を選択してください'
                  : '保存値: ${_savedInherit ? '上位の設定を継承' : _levelTitle(_savedLevel)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_level != _savedLevel || _inherit != _savedInherit)
              Text(
                '編集中: ${_inherit ? '上位の設定を継承' : _levelTitle(_level)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '予定自体が「自分のみ」の場合、ここで範囲を広げても共有されません。予定の編集画面で確認できます。',
              ),
            ),
            RadioGroup<VisibilityLevel>(
              groupValue: _level,
              onChanged: (selected) {
                if (_saving || _inherit || selected == null) return;
                setState(() => _level = selected);
              },
              child: Column(
                children: [
                  for (final level in VisibilityLevel.values)
                    RadioListTile<VisibilityLevel>(
                      contentPadding: EdgeInsets.zero,
                      value: level,
                      enabled: !_saving && !_inherit,
                      selected: _level == level,
                      title: Text(_levelTitle(level)),
                      subtitle: Text(_levelDescription(level)),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _saving ||
                        (_targetKind != 'default' &&
                            _targetController.text.trim().isEmpty)
                    ? null
                    : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetField() {
    if (_targetKind == 'event_kind') {
      const kinds = {
        'normal': '通常の予定',
        'routine': '繰り返し予定',
        'course': '授業',
        'assignment_deadline': '課題の締切',
        'exam': '試験',
      };
      return DropdownButtonFormField<String>(
        key: ValueKey('kind:${_targetController.text}'),
        isExpanded: true,
        initialValue: kinds.containsKey(_targetController.text)
            ? _targetController.text
            : null,
        decoration: const InputDecoration(labelText: '予定の種別'),
        items: [
          for (final entry in kinds.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: _saving
            ? null
            : (value) {
                if (value == null) return;
                _targetController.text = value;
                _applyRule();
              },
      );
    }
    final snapshot = ref.watch(demoAppControllerProvider).valueOrNull;
    if (_targetKind == 'event') {
      final events = snapshot?.events ?? const [];
      return DropdownButtonFormField<String>(
        key: ValueKey('event:${_targetController.text}'),
        isExpanded: true,
        initialValue: events.any((event) => event.id == _targetController.text)
            ? _targetController.text
            : null,
        decoration: const InputDecoration(labelText: '個別予定'),
        items: [
          for (final event in events)
            DropdownMenuItem(value: event.id, child: Text(event.title)),
        ],
        onChanged: _saving
            ? null
            : (value) {
                if (value == null) return;
                _targetController.text = value;
                _applyRule();
              },
      );
    }
    final courses = snapshot?.courses
            .where((course) => course.id.trim().isNotEmpty)
            .toList(growable: false) ??
        const [];
    final selected =
        courses.any((course) => course.id == _targetController.text)
            ? _targetController.text
            : null;
    if (courses.isEmpty) {
      return const InputDecorator(
        decoration: InputDecoration(labelText: '個別コース'),
        child: Text('現在の学期に選べる授業がありません'),
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('course:${_targetController.text}'),
      isExpanded: true,
      initialValue: selected,
      decoration: const InputDecoration(labelText: '個別コース'),
      items: [
        for (final course in courses)
          DropdownMenuItem(value: course.id, child: Text(course.title)),
      ],
      onChanged: _saving
          ? null
          : (value) {
              if (value == null) return;
              _targetController.text = value;
              _applyRule();
            },
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final target = _targetController.text.trim();
    final ok = await ref.read(friendsControllerProvider.notifier).setVisibility(
          widget.friend,
          _level,
          targetKind: _targetKind,
          targetId: _targetKind == 'default' || _targetKind == 'event_kind'
              ? null
              : target,
          targetValue: _targetKind == 'event_kind' ? target : null,
          inherit: _inherit,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _savedLevel = _level;
        _savedInherit = _inherit;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '公開範囲を保存しました' : '保存できませんでした')),
    );
  }

  String _levelTitle(VisibilityLevel level) => switch (level) {
        VisibilityLevel.private => '自分のみ',
        VisibilityLevel.busyOnly => '予定ありのみ',
        VisibilityLevel.titleOnly => 'タイトルのみ',
        VisibilityLevel.full => '詳細まで',
      };

  String _levelDescription(VisibilityLevel level) => switch (level) {
        VisibilityLevel.private => '予定を共有しません',
        VisibilityLevel.busyOnly => '時刻と予定ありだけ',
        VisibilityLevel.titleOnly => 'タイトルと種別まで',
        VisibilityLevel.full => '許可された予定詳細まで',
      };
}
