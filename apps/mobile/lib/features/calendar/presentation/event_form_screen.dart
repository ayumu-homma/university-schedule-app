import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/error/app_error.dart';
import '../../../core/time/app_clock.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../../shared/widgets/unsaved_changes_guard.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../../notification/presentation/ordinary_notification_permission_prompt.dart';

enum _EventVisibilityChoice {
  inherit,
  private,
  busyOnly,
  titleOnly,
  full;

  VisibilityLevel? get visibilityLevel => switch (this) {
        _EventVisibilityChoice.inherit => null,
        _EventVisibilityChoice.private => VisibilityLevel.private,
        _EventVisibilityChoice.busyOnly => VisibilityLevel.busyOnly,
        _EventVisibilityChoice.titleOnly => VisibilityLevel.titleOnly,
        _EventVisibilityChoice.full => VisibilityLevel.full,
      };

  static _EventVisibilityChoice fromVisibilityLevel(
    VisibilityLevel? visibilityLevel,
  ) =>
      switch (visibilityLevel) {
        null => _EventVisibilityChoice.inherit,
        VisibilityLevel.private => _EventVisibilityChoice.private,
        VisibilityLevel.busyOnly => _EventVisibilityChoice.busyOnly,
        VisibilityLevel.titleOnly => _EventVisibilityChoice.titleOnly,
        VisibilityLevel.full => _EventVisibilityChoice.full,
      };
}

class EventFormScreen extends ConsumerStatefulWidget {
  const EventFormScreen({this.eventId, super.key});

  final String? eventId;

  @override
  ConsumerState<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends ConsumerState<EventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();

  late DateTime _startAt;
  late DateTime _endAt;
  _EventVisibilityChoice _visibility = _EventVisibilityChoice.private;
  int? _loadedVersion;
  String? _loadedCalendarId;
  bool _initialized = false;
  bool _saving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    final now = JapanTime.civil(ref.read(appClockProvider).now());
    _startAt = JapanTime.at(
      year: now.year,
      month: now.month,
      day: now.day,
      hour: now.hour + 1,
    );
    _endAt = _startAt.add(const Duration(hours: 1));
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final event = _eventById(state.events, widget.eventId);
        if (widget.eventId != null && event == null) {
          return const MvpScaffold(
            title: '予定を編集',
            selectedIndex: 3,
            showQuickAdd: false,
            child: Center(child: Text('予定が見つかりません')),
          );
        }
        _initialize(event);
        return UnsavedChangesGuard(
          hasUnsavedChanges: _hasUnsavedChanges,
          isSaving: _saving,
          child: MvpScaffold(
            title: event == null ? '予定を作成' : '予定を編集',
            selectedIndex: 3,
            showQuickAdd: false,
            onBeforeNavigate: _confirmNavigation,
            child: Form(
              key: _formKey,
              onChanged: _markDirty,
              child: ListView(
                key: const Key('event-form-list'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: '予定名',
                      suffixText: '必須',
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '必須です' : null,
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(Icons.play_arrow_outlined),
                    title: const Text('開始'),
                    subtitle: Text('${_formatDateTime(_startAt)} · 必須'),
                    onTap: () => _pickDateTime(isStart: true),
                  ),
                  ListTile(
                    leading: const Icon(Icons.stop_outlined),
                    title: const Text('終了'),
                    subtitle: Text('${_formatDateTime(_endAt)} · 必須'),
                    onTap: () => _pickDateTime(isStart: false),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _locationController,
                    decoration: const InputDecoration(
                      labelText: '場所',
                      suffixText: '任意',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'メモ',
                      suffixText: '任意',
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<_EventVisibilityChoice>(
                    key: const Key('event-visibility'),
                    initialValue: _visibility,
                    decoration: const InputDecoration(
                      labelText: '公開範囲',
                      suffixText: '予定ごとの設定',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: _EventVisibilityChoice.inherit,
                        child: Text('カレンダーの設定に従う'),
                      ),
                      DropdownMenuItem(
                        value: _EventVisibilityChoice.private,
                        child: Text('自分のみ'),
                      ),
                      DropdownMenuItem(
                        value: _EventVisibilityChoice.busyOnly,
                        child: Text('予定ありのみ'),
                      ),
                      DropdownMenuItem(
                        value: _EventVisibilityChoice.titleOnly,
                        child: Text('タイトルまで'),
                      ),
                      DropdownMenuItem(
                        value: _EventVisibilityChoice.full,
                        child: Text('詳細まで'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _visibility = value;
                          _hasUnsavedChanges = true;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('event-save'),
                    onPressed: _saving ? null : () => _save(event),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                  if (event != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : () => _delete(event),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('この予定を削除'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const MvpScaffold(
        title: '予定',
        selectedIndex: 3,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: '予定',
        selectedIndex: 3,
        showQuickAdd: false,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  void _initialize(ScheduleEvent? event) {
    if (_initialized) return;
    _initialized = true;
    _titleController.text = event?.title ?? '';
    _locationController.text = event?.location ?? '';
    _descriptionController.text = event?.description ?? '';
    _startAt = event?.startAt ?? _startAt;
    _endAt = event?.endAt ?? _endAt;
    _visibility = _EventVisibilityChoice.fromVisibilityLevel(
      event?.visibilityLevel ??
          (event == null ? VisibilityLevel.private : null),
    );
    _loadedVersion = event?.version;
    _loadedCalendarId = event?.calendarId;
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final current = isStart ? _startAt : _endAt;
    final currentCivil = JapanTime.civil(current).pickerDateTime;
    final date = await showDatePicker(
      context: context,
      initialDate: currentCivil,
      firstDate: _dateYearsFromNow(-1),
      lastDate: _dateYearsFromNow(5, endOfYear: true),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentCivil),
    );
    if (time == null || !mounted) return;
    final next = JapanTime.at(
      year: date.year,
      month: date.month,
      day: date.day,
      hour: time.hour,
      minute: time.minute,
    );
    setState(() {
      _hasUnsavedChanges = true;
      if (isStart) {
        _startAt = next;
        if (!_endAt.isAfter(_startAt)) {
          _endAt = _startAt.add(const Duration(hours: 1));
        }
      } else {
        _endAt = next;
      }
    });
  }

  Future<void> _save(ScheduleEvent? event) async {
    if (!_formKey.currentState!.validate()) return;
    if (!_endAt.isAfter(_startAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('終了は開始より後にしてください')),
      );
      return;
    }
    setState(() => _saving = true);
    final input = EventInput(
      title: _titleController.text.trim(),
      startAt: _startAt,
      endAt: _endAt,
      calendarId: _loadedCalendarId,
      location: _blankToNull(_locationController.text),
      description: _blankToNull(_descriptionController.text),
      visibilityLevel: _visibility.visibilityLevel,
    );
    try {
      if (event == null) {
        await ref.read(demoAppControllerProvider.notifier).createEvent(input);
      } else {
        await ref
            .read(demoAppControllerProvider.notifier)
            .updateEvent(event.id, _loadedVersion!, input);
      }
      if (event == null && mounted) {
        await offerPostRegistrationNotificationPermissionPrompt(
          context,
          ref,
        );
      }
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/calendar');
      }
    } catch (error) {
      _showOperationError(error, action: '保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(ScheduleEvent event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('予定を削除しますか？'),
        content: const Text('端末ではすぐ非表示になり、削除は同期キューに保存されます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(demoAppControllerProvider.notifier)
          .deleteEvent(event.id, _loadedVersion!);
      if (mounted) {
        setState(() => _hasUnsavedChanges = false);
        context.go('/calendar');
      }
    } catch (error) {
      _showOperationError(error, action: '削除');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  ScheduleEvent? _eventById(List<ScheduleEvent> events, String? id) {
    if (id == null) return null;
    for (final event in events) {
      if (event.id == id && event.kind == EventKind.normal) return event;
    }
    return null;
  }

  void _markDirty() {
    if (!_initialized || _hasUnsavedChanges) return;
    setState(() => _hasUnsavedChanges = true);
  }

  Future<bool> _confirmNavigation() async {
    final discard = await confirmDiscardUnsavedChanges(
      context,
      hasUnsavedChanges: _hasUnsavedChanges,
      isSaving: _saving,
    );
    if (discard && mounted && _hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = false);
    }
    return discard;
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showOperationError(Object error, {required String action}) {
    if (!mounted) return;
    final message = error is ConflictError
        ? '別の変更が反映されました。画面を開き直して確認してください。'
        : '$actionに失敗しました。もう一度お試しください。';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDateTime(DateTime value) {
    final civil = JapanTime.civil(value);
    final minute = civil.minute.toString().padLeft(2, '0');
    return '${civil.year}/${civil.month}/${civil.day} ${civil.hour}:$minute';
  }

  DateTime _dateYearsFromNow(int years, {bool endOfYear = false}) {
    final now = JapanTime.civil(ref.read(appClockProvider).now());
    return endOfYear
        ? DateTime.utc(now.year + years, 12, 31)
        : DateTime.utc(now.year + years, now.month, now.day);
  }
}
