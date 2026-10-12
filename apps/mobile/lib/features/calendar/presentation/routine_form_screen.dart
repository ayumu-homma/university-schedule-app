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

class RoutineFormScreen extends ConsumerStatefulWidget {
  const RoutineFormScreen({this.routineId, super.key});

  final String? routineId;

  @override
  ConsumerState<RoutineFormScreen> createState() => _RoutineFormScreenState();
}

class _RoutineFormScreenState extends ConsumerState<RoutineFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _countController = TextEditingController(text: '1');

  late DateTime _startAt;
  late DateTime _endAt;
  late DateTime _recurrenceUntil;
  _RoutineFrequency _frequency = _RoutineFrequency.weekly;
  _RoutineEndMode _endMode = _RoutineEndMode.until;
  VisibilityLevel _visibility = VisibilityLevel.private;
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
    final startCivil = JapanTime.civil(_startAt);
    _recurrenceUntil = _endOfDay(
      DateTime.utc(startCivil.year + 1, startCivil.month, startCivil.day),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(demoAppControllerProvider);
    return asyncState.when(
      data: (state) {
        final routine = _routineById(state.events, widget.routineId);
        if (widget.routineId != null && routine == null) {
          return const MvpScaffold(
            title: 'ルーティンを編集',
            selectedIndex: 3,
            showQuickAdd: false,
            child: Center(child: Text('ルーティンが見つかりません')),
          );
        }
        _initialize(routine);
        final exceptions = state.eventExceptions
            .where((exception) => exception.eventId == routine?.id)
            .toList()
          ..sort(
              (left, right) => left.recurrenceId.compareTo(right.recurrenceId));
        return UnsavedChangesGuard(
          hasUnsavedChanges: _hasUnsavedChanges,
          isSaving: _saving,
          child: MvpScaffold(
            title: routine == null ? 'ルーティンを作成' : 'ルーティンを編集',
            selectedIndex: 3,
            showQuickAdd: false,
            onBeforeNavigate: _confirmNavigation,
            child: Form(
              key: _formKey,
              onChanged: _markDirty,
              child: ListView(
                key: const Key('routine-form-list'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'ルーティン名',
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
                  DropdownButtonFormField<_RoutineFrequency>(
                    initialValue: _frequency,
                    decoration: const InputDecoration(
                      labelText: '繰り返し',
                      suffixText: '必須',
                    ),
                    items: [
                      for (final frequency in _RoutineFrequency.values)
                        DropdownMenuItem(
                          value: frequency,
                          child: Text(frequency.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _frequency = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _frequencyDescription(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Text('繰り返しの終了',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<_RoutineEndMode>(
                    segments: const [
                      ButtonSegment(
                        value: _RoutineEndMode.until,
                        label: Text('終了日'),
                      ),
                      ButtonSegment(
                        value: _RoutineEndMode.count,
                        label: Text('回数'),
                      ),
                    ],
                    selected: {_endMode},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _hasUnsavedChanges = true;
                        _endMode = selection.single;
                      });
                    },
                  ),
                  if (_endMode == _RoutineEndMode.until) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      leading: const Icon(Icons.event_available_outlined),
                      title: const Text('繰り返し終了日'),
                      subtitle: Text('${_formatDate(_recurrenceUntil)} · 必須'),
                      onTap: _pickRecurrenceUntil,
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _countController,
                      decoration: const InputDecoration(
                        labelText: '回数',
                        suffixText: '必須',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (_endMode != _RoutineEndMode.count) return null;
                        final count = int.tryParse(value?.trim() ?? '');
                        return count == null || count < 1
                            ? '1以上の回数を入力してください'
                            : null;
                      },
                    ),
                  ],
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
                  DropdownButtonFormField<VisibilityLevel>(
                    initialValue: _visibility,
                    decoration: const InputDecoration(
                      labelText: '公開範囲',
                      suffixText: '必須',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: VisibilityLevel.private,
                        child: Text('自分のみ'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.busyOnly,
                        child: Text('予定ありのみ'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.titleOnly,
                        child: Text('タイトルまで'),
                      ),
                      DropdownMenuItem(
                        value: VisibilityLevel.full,
                        child: Text('詳細まで'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _visibility = value);
                    },
                  ),
                  if (routine != null) ...[
                    const Divider(height: 40),
                    Text(
                      '特定の回の変更・削除',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text('一度だけ時間や内容を変更したり、その回だけ削除できます。'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _saving ? null : () => _openExceptionEditor(routine),
                      icon: const Icon(Icons.edit_calendar_outlined),
                      label: const Text('例外を追加'),
                    ),
                    if (exceptions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('設定済みの例外はありません。'),
                      )
                    else
                      for (final exception in exceptions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            exception.mode == EventExceptionMode.cancelled
                                ? Icons.event_busy_outlined
                                : Icons.edit_calendar_outlined,
                          ),
                          title: Text(_formatDateTime(exception.recurrenceId)),
                          subtitle: Text(_exceptionSummary(exception)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _saving
                              ? null
                              : () => _openExceptionEditor(
                                    routine,
                                    exception: exception,
                                  ),
                        ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('routine-save'),
                    onPressed: _saving ? null : () => _save(routine),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                  if (routine != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : () => _deleteRoutine(routine),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('このルーティンを削除'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const MvpScaffold(
        title: 'ルーティン',
        selectedIndex: 3,
        showQuickAdd: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => MvpScaffold(
        title: 'ルーティン',
        selectedIndex: 3,
        showQuickAdd: false,
        child: Center(child: Text('読み込みに失敗しました: $error')),
      ),
    );
  }

  void _initialize(ScheduleEvent? routine) {
    if (_initialized) return;
    _initialized = true;
    _titleController.text = routine?.title ?? '';
    _locationController.text = routine?.location ?? '';
    _descriptionController.text = routine?.description ?? '';
    _startAt = routine?.startAt ?? _startAt;
    _endAt = routine?.endAt ?? _endAt;
    _visibility = routine?.visibilityLevel ?? VisibilityLevel.private;
    _loadedVersion = routine?.version;
    _loadedCalendarId = routine?.calendarId;
    final rule = routine?.recurrenceRule;
    if (rule == null) return;
    _frequency = _RoutineFrequency.fromRule(rule);
    if (rule.count != null) {
      _endMode = _RoutineEndMode.count;
      _countController.text = rule.count.toString();
    } else if (rule.until != null) {
      _endMode = _RoutineEndMode.until;
      _recurrenceUntil = _endOfDay(JapanTime.civil(rule.until!).pickerDateTime);
    }
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

  Future<void> _pickRecurrenceUntil() async {
    final startCivil = JapanTime.civil(_startAt).pickerDateTime;
    final date = await showDatePicker(
      context: context,
      initialDate: JapanTime.civil(_recurrenceUntil).pickerDateTime,
      firstDate: DateTime.utc(
        startCivil.year,
        startCivil.month,
        startCivil.day,
      ),
      lastDate: _dateYearsFromNow(10, endOfYear: true),
    );
    if (date == null || !mounted) return;
    setState(() {
      _hasUnsavedChanges = true;
      _recurrenceUntil = _endOfDay(date);
    });
  }

  Future<void> _save(ScheduleEvent? routine) async {
    if (!_formKey.currentState!.validate()) return;
    if (!_endAt.isAfter(_startAt)) {
      _showMessage('終了は開始より後にしてください');
      return;
    }
    if (_endMode == _RoutineEndMode.until &&
        _recurrenceUntil.isBefore(_startAt)) {
      _showMessage('繰り返し終了日は開始日以降にしてください');
      return;
    }
    final rule = _buildRule();
    if (rule == null) {
      _showMessage('1以上の回数を入力してください');
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
      visibilityLevel: _visibility,
      kind: EventKind.routine,
      recurrenceRule: rule,
    );
    try {
      if (routine == null) {
        await ref.read(demoAppControllerProvider.notifier).createEvent(input);
      } else {
        await ref
            .read(demoAppControllerProvider.notifier)
            .updateEvent(routine.id, _loadedVersion!, input);
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

  Future<void> _deleteRoutine(ScheduleEvent routine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ルーティンを削除しますか？'),
        content: const Text('すべての繰り返し予定と設定済みの例外が対象になります。'),
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
          .deleteEvent(routine.id, _loadedVersion!);
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

  Future<void> _openExceptionEditor(
    ScheduleEvent routine, {
    EventException? exception,
  }) async {
    final result = await showModalBottomSheet<_ExceptionEditResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _RoutineExceptionEditor(
        routine: routine,
        exception: exception,
      ),
    );
    if (result == null || !mounted) return;
    if (!result.delete && result.input?.mode == EventExceptionMode.cancelled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('この回を削除しますか？'),
          content: const Text('この回のルーティン予定はカレンダーに表示されなくなります。'),
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
    }
    if (result.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('例外設定を削除しますか？'),
          content: const Text('この回は、ルーティンの通常設定に戻ります。'),
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
    }
    setState(() => _saving = true);
    try {
      final controller = ref.read(demoAppControllerProvider.notifier);
      if (result.delete) {
        await controller.deleteEventException(exception!.id, routine.id);
      } else if (exception == null) {
        await controller.createEventException(routine.id, result.input!);
      } else {
        await controller.updateEventException(
          exception.id,
          routine.id,
          result.input!,
        );
      }
      if (mounted) {
        _showMessage(result.delete ? '例外設定を削除しました' : '例外設定を保存しました');
      }
    } catch (error) {
      _showOperationError(error, action: result.delete ? '例外設定の削除' : '例外設定の保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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

  RecurrenceRule? _buildRule() {
    final count = _endMode == _RoutineEndMode.count
        ? int.tryParse(_countController.text.trim())
        : null;
    if (_endMode == _RoutineEndMode.count && (count == null || count < 1)) {
      return null;
    }
    final until = _endMode == _RoutineEndMode.until ? _recurrenceUntil : null;
    return _frequency.toRule(
      startAt: _startAt,
      until: until,
      count: count,
    );
  }

  ScheduleEvent? _routineById(List<ScheduleEvent> events, String? id) {
    if (id == null) return null;
    for (final event in events) {
      if (event.id == id && event.kind == EventKind.routine) return event;
    }
    return null;
  }

  String _frequencyDescription() {
    final start = JapanTime.civil(_startAt);
    final weekday = _weekdayLabel(start.weekday);
    return switch (_frequency) {
      _RoutineFrequency.daily => '毎日',
      _RoutineFrequency.weekly => '毎週 $weekday',
      _RoutineFrequency.biweekly => '隔週 $weekday',
      _RoutineFrequency.monthly => '毎月 ${start.day}日',
      _RoutineFrequency.nthWeekday => '毎月第${(start.day - 1) ~/ 7 + 1}$weekday',
      _RoutineFrequency.weekdays => '月曜から金曜',
    };
  }

  String _exceptionSummary(EventException exception) {
    if (exception.mode == EventExceptionMode.cancelled) return 'この回を削除';
    final start = exception.overrideStartAt;
    final title = exception.overrideTitle;
    if (title != null && title.trim().isNotEmpty) return '変更: $title';
    if (start != null) return '変更: ${_formatDateTime(start)}';
    return 'この回を変更';
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _showOperationError(Object error, {required String action}) {
    if (!mounted) return;
    final message = error is ConflictError
        ? '別の変更が反映されました。画面を開き直して確認してください。'
        : error is ValidationError
            ? error.message
            : '$actionに失敗しました。もう一度お試しください。';
    _showMessage(message);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDateTime(DateTime value) {
    final civil = JapanTime.civil(value);
    final minute = civil.minute.toString().padLeft(2, '0');
    return '${civil.year}/${civil.month}/${civil.day} ${civil.hour}:$minute';
  }

  String _formatDate(DateTime value) {
    final civil = JapanTime.civil(value);
    return '${civil.year}/${civil.month}/${civil.day}';
  }

  DateTime _dateYearsFromNow(int years, {bool endOfYear = false}) {
    final now = JapanTime.civil(ref.read(appClockProvider).now());
    return endOfYear
        ? DateTime.utc(now.year + years, 12, 31)
        : DateTime.utc(now.year + years, now.month, now.day);
  }
}

enum _RoutineFrequency {
  daily('毎日'),
  weekly('毎週'),
  biweekly('隔週'),
  monthly('毎月'),
  nthWeekday('毎月第n曜日'),
  weekdays('平日のみ');

  const _RoutineFrequency(this.label);

  final String label;

  static _RoutineFrequency fromRule(RecurrenceRule rule) {
    if (rule.frequency == RecurrenceFrequency.weekly && rule.interval == 2) {
      return _RoutineFrequency.biweekly;
    }
    return switch (rule.frequency) {
      RecurrenceFrequency.daily => _RoutineFrequency.daily,
      RecurrenceFrequency.weekly => _RoutineFrequency.weekly,
      RecurrenceFrequency.monthly => _RoutineFrequency.monthly,
      RecurrenceFrequency.nthWeekday => _RoutineFrequency.nthWeekday,
      RecurrenceFrequency.weekdays => _RoutineFrequency.weekdays,
      RecurrenceFrequency.none => _RoutineFrequency.weekly,
    };
  }

  RecurrenceRule toRule({
    required DateTime startAt,
    required DateTime? until,
    required int? count,
  }) {
    final start = JapanTime.civil(startAt);
    return switch (this) {
      _RoutineFrequency.daily => _rule(
          RecurrenceFrequency.daily,
          until: until,
          count: count,
        ),
      _RoutineFrequency.weekly => _rule(
          RecurrenceFrequency.weekly,
          until: until,
          count: count,
          byWeekdays: [start.weekday],
        ),
      _RoutineFrequency.biweekly => _rule(
          RecurrenceFrequency.weekly,
          until: until,
          count: count,
          interval: 2,
          byWeekdays: [start.weekday],
        ),
      _RoutineFrequency.monthly => _rule(
          RecurrenceFrequency.monthly,
          until: until,
          count: count,
          monthDay: start.day,
        ),
      _RoutineFrequency.nthWeekday => _rule(
          RecurrenceFrequency.nthWeekday,
          until: until,
          count: count,
          nth: (start.day - 1) ~/ 7 + 1,
          weekday: start.weekday,
        ),
      _RoutineFrequency.weekdays => _rule(
          RecurrenceFrequency.weekdays,
          until: until,
          count: count,
        ),
    };
  }

  static RecurrenceRule _rule(
    RecurrenceFrequency frequency, {
    required DateTime? until,
    required int? count,
    int interval = 1,
    List<int> byWeekdays = const [],
    int? monthDay,
    int? nth,
    int? weekday,
  }) {
    return RecurrenceRule(
      frequency: frequency,
      interval: interval,
      byWeekdays: byWeekdays,
      until: until,
      count: count,
      monthDay: monthDay,
      nth: nth,
      weekday: weekday,
    );
  }
}

enum _RoutineEndMode { until, count }

class _ExceptionEditResult {
  const _ExceptionEditResult.save(this.input) : delete = false;

  const _ExceptionEditResult.delete()
      : input = null,
        delete = true;

  final EventExceptionInput? input;
  final bool delete;
}

class _RoutineExceptionEditor extends StatefulWidget {
  const _RoutineExceptionEditor({required this.routine, this.exception});

  final ScheduleEvent routine;
  final EventException? exception;

  @override
  State<_RoutineExceptionEditor> createState() =>
      _RoutineExceptionEditorState();
}

class _RoutineExceptionEditorState extends State<_RoutineExceptionEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _descriptionController;
  late DateTime _recurrenceId;
  late DateTime _overrideStartAt;
  late DateTime _overrideEndAt;
  late EventExceptionMode _mode;

  @override
  void initState() {
    super.initState();
    final exception = widget.exception;
    _recurrenceId = exception?.recurrenceId ?? widget.routine.startAt;
    _overrideStartAt = exception?.overrideStartAt ?? _recurrenceId;
    _overrideEndAt = exception?.overrideEndAt ??
        _overrideStartAt.add(widget.routine.duration);
    _mode = exception?.mode ?? EventExceptionMode.cancelled;
    _titleController = TextEditingController(
      text: exception?.overrideTitle ?? widget.routine.title,
    );
    _locationController = TextEditingController(
      text: exception?.overrideLocation ?? widget.routine.location ?? '',
    );
    _descriptionController = TextEditingController(
      text: exception?.overrideDescription ?? widget.routine.description ?? '',
    );
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
    final isEditing = widget.exception != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEditing ? '例外を編集' : '例外を追加',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('対象の回'),
                  subtitle: Text(_formatDateTime(_recurrenceId)),
                  onTap: _pickOccurrenceDate,
                ),
                DropdownButtonFormField<EventExceptionMode>(
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'この回の扱い'),
                  items: const [
                    DropdownMenuItem(
                      value: EventExceptionMode.cancelled,
                      child: Text('この回を削除'),
                    ),
                    DropdownMenuItem(
                      value: EventExceptionMode.modified,
                      child: Text('この回を変更'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _mode = value);
                  },
                ),
                if (_mode == EventExceptionMode.modified) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'この回の予定名'),
                    validator: (value) =>
                        _mode == EventExceptionMode.modified &&
                                (value == null || value.trim().isEmpty)
                            ? '必須です'
                            : null,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_arrow_outlined),
                    title: const Text('変更後の開始'),
                    subtitle: Text(_formatDateTime(_overrideStartAt)),
                    onTap: () => _pickOverrideDateTime(isStart: true),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.stop_outlined),
                    title: const Text('変更後の終了'),
                    subtitle: Text(_formatDateTime(_overrideEndAt)),
                    onTap: () => _pickOverrideDateTime(isStart: false),
                  ),
                  TextFormField(
                    controller: _locationController,
                    decoration: const InputDecoration(labelText: '場所'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(labelText: 'メモ'),
                    maxLines: 2,
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _save,
                  child: const Text('例外設定を保存'),
                ),
                if (isEditing)
                  TextButton.icon(
                    onPressed: () => Navigator.pop(
                        context, const _ExceptionEditResult.delete()),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('例外設定を削除'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickOccurrenceDate() async {
    final rule = widget.routine.recurrenceRule;
    final routineStart = JapanTime.civil(widget.routine.startAt);
    final lastDate = rule?.until == null
        ? DateTime.utc(routineStart.year + 10, 12, 31)
        : JapanTime.civil(rule!.until!).pickerDateTime;
    final date = await showDatePicker(
      context: context,
      initialDate: JapanTime.civil(_recurrenceId).pickerDateTime,
      firstDate: DateTime.utc(
        routineStart.year,
        routineStart.month,
        routineStart.day,
      ),
      lastDate: lastDate,
    );
    if (date == null || !mounted) return;
    setState(() {
      final duration = _overrideEndAt.difference(_overrideStartAt);
      final overrideStart = JapanTime.civil(_overrideStartAt);
      _recurrenceId = JapanTime.at(
        year: date.year,
        month: date.month,
        day: date.day,
        hour: routineStart.hour,
        minute: routineStart.minute,
        second: routineStart.second,
        millisecond: routineStart.millisecond,
        microsecond: routineStart.microsecond,
      );
      _overrideStartAt = JapanTime.at(
        year: date.year,
        month: date.month,
        day: date.day,
        hour: overrideStart.hour,
        minute: overrideStart.minute,
        second: overrideStart.second,
        millisecond: overrideStart.millisecond,
        microsecond: overrideStart.microsecond,
      );
      _overrideEndAt = _overrideStartAt.add(duration);
    });
  }

  Future<void> _pickOverrideDateTime({required bool isStart}) async {
    final current = isStart ? _overrideStartAt : _overrideEndAt;
    final currentCivil = JapanTime.civil(current).pickerDateTime;
    final routineStart = JapanTime.civil(widget.routine.startAt);
    final date = await showDatePicker(
      context: context,
      initialDate: currentCivil,
      firstDate: DateTime.utc(routineStart.year - 1),
      lastDate: DateTime.utc(routineStart.year + 10, 12, 31),
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
      if (isStart) {
        _overrideStartAt = next;
        if (!_overrideEndAt.isAfter(_overrideStartAt)) {
          _overrideEndAt = _overrideStartAt.add(widget.routine.duration);
        }
      } else {
        _overrideEndAt = next;
      }
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_mode == EventExceptionMode.modified &&
        !_overrideEndAt.isAfter(_overrideStartAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('変更後の終了は開始より後にしてください')),
      );
      return;
    }
    final input = _mode == EventExceptionMode.cancelled
        ? EventExceptionInput(
            recurrenceId: _recurrenceId,
            mode: EventExceptionMode.cancelled,
          )
        : EventExceptionInput(
            recurrenceId: _recurrenceId,
            mode: EventExceptionMode.modified,
            overrideStartAt: _overrideStartAt,
            overrideEndAt: _overrideEndAt,
            overrideTitle: _blankToNull(_titleController.text),
            overrideLocation: _blankToNull(_locationController.text),
            overrideDescription: _blankToNull(_descriptionController.text),
          );
    Navigator.pop(context, _ExceptionEditResult.save(input));
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _formatDateTime(DateTime value) {
    final civil = JapanTime.civil(value);
    final minute = civil.minute.toString().padLeft(2, '0');
    return '${civil.year}/${civil.month}/${civil.day} ${civil.hour}:$minute';
  }
}

DateTime _endOfDay(DateTime date) => JapanTime.at(
      year: date.year,
      month: date.month,
      day: date.day,
      hour: 23,
      minute: 59,
      second: 59,
      millisecond: 999,
    );

String _weekdayLabel(int weekday) {
  return switch (weekday) {
    DateTime.monday => '月曜',
    DateTime.tuesday => '火曜',
    DateTime.wednesday => '水曜',
    DateTime.thursday => '木曜',
    DateTime.friday => '金曜',
    DateTime.saturday => '土曜',
    DateTime.sunday => '日曜',
    _ => '',
  };
}
