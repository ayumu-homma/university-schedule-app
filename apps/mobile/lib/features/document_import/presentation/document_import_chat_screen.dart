import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../shared/widgets/app_status_badge.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/responsive_content.dart';
import '../application/document_import_controller.dart';
import '../domain/document_import_models.dart';

class DocumentImportChatScreen extends ConsumerWidget {
  const DocumentImportChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(documentImportControllerProvider);
    final available = ref.watch(documentImportAvailableProvider);
    final demoMode = ref.watch(appConfigProvider).demoMode;
    final courses =
        ref.watch(documentImportCourseOptionsProvider).valueOrNull ??
            const <DocumentCourseOption>[];
    final controller = ref.read(documentImportControllerProvider.notifier);
    final value = asyncState.valueOrNull;
    final selectedCount = value?.batch?.candidates
            .where((candidate) => candidate.canConfirm)
            .length ??
        0;

    return Scaffold(
      key: const Key('document-import-screen'),
      appBar: AppBar(
        title: const Text('資料から予定を見つける'),
        actions: [
          if (value?.batch != null)
            IconButton(
              tooltip: '資料キャッシュを削除',
              onPressed: value!.isBusy
                  ? null
                  : () => _confirmDelete(context, controller),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: SafeArea(
        child: ResponsiveContent(
          maxWidth: 760,
          child: asyncState.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const EmptyState(
              icon: Icons.error_outline,
              title: '候補を読み込めませんでした',
              message: 'もう一度この画面を開いてください。',
            ),
            data: (state) => ListView(
              key: ValueKey(
                'document-import-list-${state.batch?.sourceId ?? 'empty'}',
              ),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              children: [
                const _ChatBubble(
                  assistant: true,
                  child: Text(
                    'PDF・画像・テキストから課題と試験の候補を探します。'
                    '予定へ登録するのは、あなたが確認した候補だけです。',
                  ),
                ),
                const SizedBox(height: 12),
                if (!available)
                  const _FeatureUnavailableCard()
                else ...[
                  _UploadActions(
                    busy: state.isBusy,
                    demoMode: demoMode,
                    onPick: controller.pickAndAnalyze,
                    onDemo: controller.analyzeSyntheticDemo,
                  ),
                  if (state.isBusy) ...[
                    const SizedBox(height: 16),
                    _ProgressMessage(
                      phase: state.phase,
                      onCancel:
                          state.phase == DocumentImportUiPhase.uploading ||
                                  state.phase == DocumentImportUiPhase.analyzing
                              ? controller.cancelAnalysis
                              : null,
                    ),
                  ],
                  if (state.errorCategory != null) ...[
                    const SizedBox(height: 16),
                    _ErrorMessage(category: state.errorCategory!),
                  ],
                  if (state.batch != null) ...[
                    const SizedBox(height: 20),
                    const _ChatBubble(
                      assistant: false,
                      child: Text('この資料から課題と試験を探して'),
                    ),
                    const SizedBox(height: 12),
                    _ResultHeader(
                      state: state,
                      onAll: () => controller.setAllSelected(true),
                      onNone: () => controller.setAllSelected(false),
                      onRetry: controller.retryPendingReviewSync,
                    ),
                    const SizedBox(height: 12),
                    for (var index = 0;
                        index < state.batch!.candidates.length;
                        index++) ...[
                      _CandidateCard(
                        key: Key('document-candidate-card-$index'),
                        index: index,
                        review: state.batch!.candidates[index],
                        busy: state.isBusy,
                        courses: courses,
                        onSelected: (selected) => controller.setSelected(
                          state.batch!.candidates[index].localId,
                          selected,
                        ),
                        onExclude: () => controller.exclude(
                          state.batch!.candidates[index].localId,
                        ),
                        onRestore: () => controller.restore(
                          state.batch!.candidates[index].localId,
                        ),
                        onEdit: () => _editCandidate(
                          context,
                          controller,
                          state.batch!.candidates[index],
                          courses,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: value?.batch == null || !available
          ? null
          : SafeArea(
              child: Material(
                elevation: 8,
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 728),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('document-confirm-button'),
                          onPressed: value!.isBusy || selectedCount == 0
                              ? null
                              : controller.confirmSelected,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (value.isBusy)
                                const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                const Icon(Icons.playlist_add_check),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '選択した$selectedCount件を登録',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _editCandidate(
    BuildContext context,
    DocumentImportController controller,
    DocumentCandidateReview review,
    List<DocumentCourseOption> courses,
  ) async {
    final edit = await showDialog<DocumentCandidateEdit>(
      context: context,
      builder: (context) => _CandidateEditor(
        review: review,
        courses: courses,
      ),
    );
    if (edit != null) await controller.edit(review.localId, edit);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    DocumentImportController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('資料キャッシュを削除しますか？'),
        content: const Text(
          '候補と資料ファイルを削除します。すでに登録した課題・試験は残ります。',
        ),
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
    if (confirmed == true) await controller.deleteCurrentSource();
  }
}

class _UploadActions extends StatelessWidget {
  const _UploadActions({
    required this.busy,
    required this.demoMode,
    required this.onPick,
    required this.onDemo,
  });

  final bool busy;
  final bool demoMode;
  final VoidCallback onPick;
  final VoidCallback onDemo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ChatBubble(
      assistant: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            key: const Key('document-import-pick-button'),
            onPressed: busy ? null : onPick,
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.onPrimaryContainer,
              side: BorderSide(
                color: colors.onPrimaryContainer.withValues(alpha: 0.72),
              ),
            ),
            icon: const Icon(Icons.upload_file),
            label: const Text('PDF・画像・テキストを選ぶ'),
          ),
          if (demoMode) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('document-import-demo-button'),
              onPressed: busy ? null : onDemo,
              icon: const Icon(Icons.science_outlined),
              label: const Text('合成資料で試す（デモ）'),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '対応: PDF / PNG / JPEG / TXT（最大10 MB）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
          ),
        ],
      ),
    );
  }
}

class _ProgressMessage extends StatelessWidget {
  const _ProgressMessage({required this.phase, this.onCancel});

  final DocumentImportUiPhase phase;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final message = switch (phase) {
      DocumentImportUiPhase.picking => '資料を選択しています…',
      DocumentImportUiPhase.uploading => '非公開領域へアップロードしています…',
      DocumentImportUiPhase.analyzing => '課題と試験の候補を解析しています…',
      DocumentImportUiPhase.confirming => '選択した候補を登録しています…',
      DocumentImportUiPhase.retrying => '未完了の処理を再試行しています…',
      _ => '処理しています…',
    };
    return _ChatBubble(
      assistant: true,
      child: Semantics(
        liveRegion: true,
        label: message,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(message)),
              ],
            ),
            if (onCancel != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('document-import-cancel-button'),
                  onPressed: onCancel,
                  icon: const Icon(Icons.close),
                  label: const Text('キャンセル'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({
    required this.state,
    required this.onAll,
    required this.onNone,
    required this.onRetry,
  });

  final DocumentImportViewState state;
  final VoidCallback onAll;
  final VoidCallback onNone;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final batch = state.batch!;
    final remaining = batch.candidates
        .where((candidate) =>
            candidate.reviewState == DocumentCandidateReviewState.needsReview)
        .length;
    final hasPendingReviewSync = batch.candidates.any(
      (candidate) => candidate.remoteSyncPending,
    );
    final hasRetryableWork = state.failedCount > 0 || hasPendingReviewSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChatBubble(
          assistant: true,
          child: Text('${batch.candidates.length}件の候補が見つかりました。'
              '根拠と日時を確認してください。'),
        ),
        if (state.phase == DocumentImportUiPhase.completed) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${state.confirmedCount}件を登録しました'
                      '${state.failedCount == 0 ? '' : '／${state.failedCount}件失敗'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => context.go('/assignments'),
                          child: const Text('課題一覧を見る'),
                        ),
                        TextButton(
                          onPressed: () => context.go('/exams'),
                          child: const Text('試験一覧を見る'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (hasRetryableWork) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const Key('document-import-retry-button'),
              onPressed: state.isBusy ? null : onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(
                state.failedCount > 0 ? '失敗した候補を再試行' : '未同期の変更を再試行',
              ),
            ),
          ),
        ],
        if (remaining > 0) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(onPressed: onAll, child: const Text('すべて選択')),
              TextButton(onPressed: onNone, child: const Text('すべて解除')),
            ],
          ),
        ],
      ],
    );
  }
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.index,
    required this.review,
    required this.busy,
    required this.courses,
    required this.onSelected,
    required this.onExclude,
    required this.onRestore,
    required this.onEdit,
    super.key,
  });

  final int index;
  final DocumentCandidateReview review;
  final bool busy;
  final List<DocumentCourseOption> courses;
  final ValueChanged<bool> onSelected;
  final VoidCallback onExclude;
  final VoidCallback onRestore;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final candidate = review.candidate;
    final excluded =
        review.reviewState == DocumentCandidateReviewState.excluded;
    final confirmed =
        review.reviewState == DocumentCandidateReviewState.confirmed;
    final courseName = review.courseId == null
        ? candidate.courseHint.name ?? '授業未紐付け'
        : courses
                .where((course) => course.id == review.courseId)
                .map((course) => course.title)
                .firstOrNull ??
            candidate.courseHint.name ??
            '授業未紐付け';
    return Opacity(
      opacity: excluded ? 0.66 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!excluded && !confirmed)
                    Checkbox(
                      key: Key('candidate-select-$index'),
                      value: review.isSelected,
                      onChanged:
                          busy ? null : (value) => onSelected(value ?? false),
                      semanticLabel: '${candidate.title}を登録対象にする',
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            AppStatusBadge(
                              label: candidate.type ==
                                      DocumentCandidateType.assignment
                                  ? '課題'
                                  : '試験',
                              icon: candidate.type ==
                                      DocumentCandidateType.assignment
                                  ? Icons.assignment_outlined
                                  : Icons.quiz_outlined,
                              tone: AppStatusTone.info,
                            ),
                            if (excluded)
                              const AppStatusBadge(
                                label: '除外',
                                icon: Icons.remove_circle_outline,
                                tone: AppStatusTone.neutral,
                              ),
                            if (confirmed)
                              const AppStatusBadge(
                                label: '登録済み',
                                icon: Icons.check_circle_outline,
                                tone: AppStatusTone.success,
                              ),
                            if (review.remoteSyncPending)
                              const AppStatusBadge(
                                label: '同期待ち',
                                icon: Icons.sync,
                                tone: AppStatusTone.warning,
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          candidate.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _MetadataLine(icon: Icons.school_outlined, text: courseName),
              _MetadataLine(
                icon: Icons.schedule_outlined,
                text: _dateLabel(candidate),
              ),
              if (candidate.location != null)
                _MetadataLine(
                  icon: Icons.place_outlined,
                  text: candidate.location!,
                ),
              if (candidate.warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final warning in candidate.warnings)
                      AppStatusBadge(
                        label: _warningLabel(warning),
                        icon: Icons.warning_amber_outlined,
                        tone: AppStatusTone.warning,
                      ),
                  ],
                ),
              ],
              const Divider(height: 24),
              Text('根拠', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final evidence in candidate.evidence)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${evidence.pageNumber == null ? '' : 'p.${evidence.pageNumber}  '}'
                    '${evidence.section == null ? '' : '${evidence.section} — '}'
                    '${evidence.excerpt}',
                  ),
                ),
              if (!confirmed) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (excluded)
                      Semantics(
                        button: true,
                        enabled: !busy,
                        label: '「${candidate.title}」を候補へ戻す',
                        onTap: busy ? null : onRestore,
                        excludeSemantics: true,
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : onRestore,
                          icon: const Icon(Icons.undo),
                          label: const Text('候補へ戻す'),
                        ),
                      )
                    else ...[
                      Semantics(
                        button: true,
                        enabled: !busy,
                        label: '「${candidate.title}」を編集',
                        onTap: busy ? null : onEdit,
                        excludeSemantics: true,
                        child: OutlinedButton.icon(
                          key: Key('candidate-edit-$index'),
                          onPressed: busy ? null : onEdit,
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('編集'),
                        ),
                      ),
                      Semantics(
                        button: true,
                        enabled: !busy,
                        label: '「${candidate.title}」を除外',
                        onTap: busy ? null : onExclude,
                        excludeSemantics: true,
                        child: TextButton.icon(
                          key: Key('candidate-exclude-$index'),
                          onPressed: busy ? null : onExclude,
                          icon: const Icon(Icons.remove_circle_outline),
                          label: const Text('除外'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CandidateEditor extends StatefulWidget {
  const _CandidateEditor({required this.review, required this.courses});

  final DocumentCandidateReview review;
  final List<DocumentCourseOption> courses;

  @override
  State<_CandidateEditor> createState() => _CandidateEditorState();
}

class _CandidateEditorState extends State<_CandidateEditor> {
  late final TextEditingController _title;
  late final TextEditingController _courseHint;
  late final TextEditingController _location;
  late DocumentCandidateType _type;
  late String _courseId;
  DateTime? _date;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;
  bool _allDay = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final candidate = widget.review.candidate;
    _title = TextEditingController(text: candidate.title);
    _courseHint = TextEditingController(text: candidate.courseHint.name);
    _location = TextEditingController(text: candidate.location);
    _type = candidate.type;
    _courseId = widget.review.courseId ?? '';
    _allDay = candidate.allDay;
    final anchor = candidate.dueAt ?? candidate.startAt;
    if (anchor != null) {
      final jst = _toJst(anchor);
      _date = DateTime(jst.year, jst.month, jst.day);
      _startTime = TimeOfDay(hour: jst.hour, minute: jst.minute);
    }
    if (candidate.endAt != null) {
      final end = _toJst(candidate.endAt!);
      _endTime = TimeOfDay(hour: end.hour, minute: end.minute);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _courseHint.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('候補を編集'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<DocumentCandidateType>(
                key: const Key('candidate-type-editor'),
                segments: const [
                  ButtonSegment(
                    value: DocumentCandidateType.assignment,
                    label: Text('課題'),
                    icon: Icon(Icons.assignment_outlined),
                  ),
                  ButtonSegment(
                    value: DocumentCandidateType.exam,
                    label: Text('試験'),
                    icon: Icon(Icons.quiz_outlined),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (value) => setState(() {
                  _type = value.single;
                  if (_type == DocumentCandidateType.exam) {
                    _allDay = false;
                    _endTime ??= const TimeOfDay(hour: 12, minute: 0);
                  }
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('candidate-title-editor'),
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'タイトル（必須）',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _courseId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '授業への紐付け'),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text(
                      '紐付けなし',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final course in widget.courses)
                    DropdownMenuItem(
                      value: course.id,
                      child: Text(
                        course.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _courseId = value ?? ''),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _courseHint,
                decoration: const InputDecoration(
                  labelText: '資料内の授業名（任意）',
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined),
                title: Text(_date == null
                    ? '日付を選択（必須）'
                    : DateFormat('yyyy/MM/dd').format(_date!)),
                onTap: _pickDate,
              ),
              if (_type == DocumentCandidateType.assignment)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allDay,
                  onChanged: (value) => setState(() => _allDay = value),
                  title: const Text('時刻指定なし'),
                ),
              if (!_allDay)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(_startTime == null
                      ? '開始・期限時刻を選択（必須）'
                      : '開始・期限 ${_startTime!.format(context)}'),
                  onTap: () => _pickTime(end: false),
                ),
              if (_type == DocumentCandidateType.exam)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_outlined),
                  title: Text(_endTime == null
                      ? '終了時刻を選択（必須）'
                      : '終了 ${_endTime!.format(context)}'),
                  onTap: () => _pickTime(end: true),
                ),
              if (_type == DocumentCandidateType.exam)
                TextField(
                  controller: _location,
                  decoration: const InputDecoration(labelText: '教室（任意）'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  key: const Key('candidate-editor-error'),
                  container: true,
                  liveRegion: true,
                  label: _error!,
                  excludeSemantics: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('candidate-editor-save'),
          onPressed: _save,
          child: const Text('候補を更新'),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime(2026, 8, 10),
      firstDate: DateTime(2020),
      lastDate: DateTime(2200),
    );
    if (selected != null && mounted) setState(() => _date = selected);
  }

  Future<void> _pickTime({required bool end}) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: end
          ? _endTime ?? const TimeOfDay(hour: 12, minute: 0)
          : _startTime ?? const TimeOfDay(hour: 23, minute: 59),
    );
    if (selected != null && mounted) {
      setState(() => end ? _endTime = selected : _startTime = selected);
    }
  }

  void _save() {
    if (_title.text.trim().isEmpty ||
        _date == null ||
        (!_allDay && _startTime == null) ||
        (_type == DocumentCandidateType.exam && _endTime == null)) {
      setState(() => _error = '必須項目を確認してください。');
      return;
    }
    final original = widget.review.candidate;
    final start = _allDay ? null : _fromJst(_date!, _startTime!);
    DateTime? end;
    if (_type == DocumentCandidateType.exam) {
      end = _fromJst(_date!, _endTime!);
      if (!end.isAfter(start!)) {
        setState(() => _error = '終了時刻は開始時刻より後にしてください。');
        return;
      }
    }
    final due = _type == DocumentCandidateType.assignment
        ? (_allDay
            ? _fromJst(_date!, const TimeOfDay(hour: 23, minute: 59))
            : start)
        : null;
    final location = _location.text.trim();
    final edited = original.copyWith(
      type: _type,
      title: _title.text.trim(),
      courseHint: DocumentCourseHint(
        name: _courseHint.text.trim().isEmpty ? null : _courseHint.text.trim(),
        code: original.courseHint.code,
      ),
      dueAt: due,
      clearDueAt: _type == DocumentCandidateType.exam,
      allDay: _type == DocumentCandidateType.assignment && _allDay,
      startAt: _type == DocumentCandidateType.exam ? start : null,
      clearStartAt: _type == DocumentCandidateType.assignment,
      endAt: _type == DocumentCandidateType.exam ? end : null,
      clearEndAt: _type == DocumentCandidateType.assignment,
      location: _type == DocumentCandidateType.exam
          ? (location.isEmpty ? null : location)
          : null,
      clearLocation:
          _type == DocumentCandidateType.assignment || location.isEmpty,
    );
    Navigator.pop(
      context,
      DocumentCandidateEdit(
        candidate: edited,
        courseId: _courseId.isEmpty ? null : _courseId,
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.assistant, required this.child});

  final bool assistant;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = assistant ? colors.onSurface : colors.onPrimaryContainer;
    return Align(
      alignment: assistant ? Alignment.centerLeft : Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: assistant
                ? colors.surfaceContainerHighest
                : colors.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureUnavailableCard extends StatelessWidget {
  const _FeatureUnavailableCard();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.lock_outline,
      title: '資料解析は無効です',
      message: '管理者がサーバー側の資料解析を有効にすると利用できます。',
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.category});

  final DocumentImportErrorCategory category;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_errorLabel(category)),
        ),
      ),
    );
  }
}

class _MetadataLine extends StatelessWidget {
  const _MetadataLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

DateTime _toJst(DateTime value) => value.toUtc().add(const Duration(hours: 9));

DateTime _fromJst(DateTime date, TimeOfDay time) => DateTime.utc(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ).subtract(const Duration(hours: 9));

String _dateLabel(DocumentScheduleCandidate candidate) {
  final format = DateFormat('yyyy/MM/dd HH:mm');
  if (candidate.type == DocumentCandidateType.assignment) {
    if (candidate.dueAt == null) return '期限未確定（編集が必要）';
    if (candidate.allDay) {
      return '${DateFormat('yyyy/MM/dd').format(_toJst(candidate.dueAt!))} 終日';
    }
    return '期限 ${format.format(_toJst(candidate.dueAt!))}';
  }
  if (candidate.startAt == null || candidate.endAt == null) {
    return '試験日時未確定（編集が必要）';
  }
  return '${format.format(_toJst(candidate.startAt!))}〜'
      '${DateFormat('HH:mm').format(_toJst(candidate.endAt!))}';
}

String _warningLabel(DocumentCandidateWarning warning) => switch (warning) {
      DocumentCandidateWarning.missingYear => '年を確認',
      DocumentCandidateWarning.missingDate => '日付を確認',
      DocumentCandidateWarning.missingTime => '時刻を確認',
      DocumentCandidateWarning.ambiguousCourse => '授業を確認',
      DocumentCandidateWarning.duplicateMention => '重複候補',
      DocumentCandidateWarning.relativeDate => '相対日付',
      DocumentCandidateWarning.lowConfidence => '要確認',
    };

String _errorLabel(DocumentImportErrorCategory category) => switch (category) {
      DocumentImportErrorCategory.unsupportedType =>
        'PDF、PNG、JPEG、TXTのいずれかを選んでください。',
      DocumentImportErrorCategory.oversizedFile ||
      DocumentImportErrorCategory.oversizedDocument =>
        '資料が上限を超えています（最大10 MB）。',
      DocumentImportErrorCategory.corruptDocument ||
      DocumentImportErrorCategory.encryptedDocument ||
      DocumentImportErrorCategory.spoofedMediaType ||
      DocumentImportErrorCategory.unsafeContent =>
        'この資料は安全に読み取れませんでした。別のファイルを確認してください。',
      DocumentImportErrorCategory.rateLimited =>
        '解析回数の上限に達しました。時間をおいて再試行してください。',
      DocumentImportErrorCategory.timeout ||
      DocumentImportErrorCategory.networkUnavailable ||
      DocumentImportErrorCategory.providerUnavailable =>
        '通信または解析サービスを利用できません。候補キャッシュは保持されています。',
      DocumentImportErrorCategory.configurationMissing =>
        '資料解析は現在利用できません。サーバー設定を確認してください。',
      DocumentImportErrorCategory.cancelled => '処理をキャンセルしました。',
      DocumentImportErrorCategory.invalidExtraction ||
      DocumentImportErrorCategory.internalError =>
        '候補を安全に検証できませんでした。資料を確認して再試行してください。',
    };
