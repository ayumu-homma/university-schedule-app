import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/mvp_scaffold.dart';
import '../data/calendar_visibility_repository.dart';

class CalendarVisibilityScreen extends ConsumerStatefulWidget {
  const CalendarVisibilityScreen({super.key});

  @override
  ConsumerState<CalendarVisibilityScreen> createState() =>
      _CalendarVisibilityScreenState();
}

class _CalendarVisibilityScreenState
    extends ConsumerState<CalendarVisibilityScreen> {
  VisibilityLevel? _visibility;
  bool _loaded = false;
  bool _saving = false;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ref.read(calendarVisibilityRepositoryProvider).load();
      if (!mounted) return;
      setState(() {
        _visibility = value;
        _loaded = true;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MvpScaffold(
      title: 'カレンダーの公開範囲',
      selectedIndex: 3,
      showQuickAdd: false,
      child: _loadError != null
          ? const Center(child: Text('公開範囲を読み込めませんでした。'))
          : !_loaded
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'この個人カレンダーの予定に個別の公開範囲がない場合に使われます。',
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<VisibilityLevel?>(
                      key: const Key('calendar-default-visibility'),
                      initialValue: _visibility,
                      decoration: const InputDecoration(labelText: '既定の公開範囲'),
                      items: const [
                        DropdownMenuItem<VisibilityLevel?>(
                          value: null,
                          child: Text('未設定（自分のみ）'),
                        ),
                        DropdownMenuItem<VisibilityLevel?>(
                          value: VisibilityLevel.private,
                          child: Text('常に自分のみ'),
                        ),
                        DropdownMenuItem<VisibilityLevel?>(
                          value: VisibilityLevel.busyOnly,
                          child: Text('予定ありのみ'),
                        ),
                        DropdownMenuItem<VisibilityLevel?>(
                          value: VisibilityLevel.titleOnly,
                          child: Text('タイトルまで'),
                        ),
                        DropdownMenuItem<VisibilityLevel?>(
                          value: VisibilityLevel.full,
                          child: Text('詳細まで'),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _visibility = value),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('save-calendar-default-visibility'),
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ],
                ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(calendarVisibilityRepositoryProvider).save(_visibility);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('公開範囲を保存しました。')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('公開範囲を保存できませんでした。')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
