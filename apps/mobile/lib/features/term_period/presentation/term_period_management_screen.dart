import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../onboarding/application/onboarding_providers.dart';
import '../../onboarding/domain/onboarding_models.dart';
import '../application/term_period_providers.dart';
import '../domain/term_period_models.dart';

class TermPeriodManagementScreen extends ConsumerStatefulWidget {
  const TermPeriodManagementScreen({super.key});

  @override
  ConsumerState<TermPeriodManagementScreen> createState() =>
      _TermPeriodManagementScreenState();
}

class _TermPeriodManagementScreenState
    extends ConsumerState<TermPeriodManagementScreen> {
  bool _isMutating = false;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appConfigProvider).demoMode) {
      return const MvpScaffold(
        title: '学期・時限管理',
        selectedIndex: 0,
        child: EmptyState(
          icon: Icons.science_outlined,
          title: 'デモモードで実行中です',
          message: '学期と時限の個人設定は Supabase モードで利用できます。',
        ),
      );
    }

    final profileState = ref.watch(onboardingControllerProvider);
    final catalogState = ref.watch(onboardingCatalogProvider);
    final snapshotState = ref.watch(personalTermPeriodSnapshotProvider);

    return MvpScaffold(
      title: '学期・時限管理',
      selectedIndex: 0,
      child: _bodyFor(
        profileState: profileState,
        catalogState: catalogState,
        snapshotState: snapshotState,
      ),
    );
  }

  Widget _bodyFor({
    required AsyncValue<OnboardingProfile?> profileState,
    required AsyncValue<OnboardingCatalog> catalogState,
    required AsyncValue<PersonalTermPeriodSnapshot> snapshotState,
  }) {
    if (profileState.hasError ||
        catalogState.hasError ||
        snapshotState.hasError) {
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: '学期設定を読み込めませんでした',
        message: '通信状態を確認して、もう一度お試しください。',
        action: FilledButton.icon(
          onPressed: _isMutating ? null : _reload,
          icon: const Icon(Icons.refresh),
          label: const Text('再読み込み'),
        ),
      );
    }
    final profile = profileState.valueOrNull;
    final catalog = catalogState.valueOrNull;
    final snapshot = snapshotState.valueOrNull;
    if (profile == null || catalog == null || snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!profile.hasActiveSchedule) {
      return const EmptyState(
        icon: Icons.calendar_month_outlined,
        title: '初期設定を完了してください',
        message: '学期と時限の管理には、大学と最初の学期の設定が必要です。',
      );
    }
    return _content(profile, catalog, snapshot);
  }

  Widget _content(
    OnboardingProfile profile,
    OnboardingCatalog catalog,
    PersonalTermPeriodSnapshot snapshot,
  ) {
    final activeTerm = snapshot.activeTerm;
    if (activeTerm == null) {
      return EmptyState(
        icon: Icons.calendar_month_outlined,
        title: '有効な学期がありません',
        message: '新しい学期を追加して、現在の学期として設定してください。',
        action: FilledButton.icon(
          key: const Key('create-personal-term-button'),
          onPressed: _isMutating
              ? null
              : () => _createTerm(
                    profile,
                    catalog,
                    hasActiveTerm: false,
                  ),
          icon: const Icon(Icons.add),
          label: const Text('学期を追加'),
        ),
      );
    }

    final periodState =
        ref.watch(personalPeriodSettingsProvider(activeTerm.id));
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        key: const Key('term-period-management-list'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
        children: [
          _ActiveTermCard(
            term: activeTerm,
            periods: periodState,
            mutating: _isMutating,
            onEditPeriods: periodState.valueOrNull == null
                ? null
                : () => _editPeriods(
                      profile,
                      catalog,
                      activeTerm,
                      periodState.valueOrNull!,
                    ),
            onRetryPeriods: () =>
                ref.invalidate(personalPeriodSettingsProvider(activeTerm.id)),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '個人学期',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      FilledButton.icon(
                        key: const Key('create-personal-term-button'),
                        onPressed: _isMutating
                            ? null
                            : () => _createTerm(
                                  profile,
                                  catalog,
                                  hasActiveTerm: true,
                                ),
                        icon: _isMutating
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add),
                        label: const Text('学期を追加'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '学期はあなたのアカウントだけに保存されます。'
                    '有効にした学期が時間割と授業追加に使われます。',
                  ),
                  const SizedBox(height: 12),
                  for (final term in snapshot.terms)
                    _PersonalTermTile(
                      term: term,
                      active: term.id == activeTerm.id,
                      mutating: _isMutating,
                      onActivate: () => _activateTerm(term),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reload() async {
    ref.invalidate(personalTermPeriodSnapshotProvider);
    ref.invalidate(onboardingCatalogProvider);
    await ref.read(onboardingControllerProvider.notifier).retryProfileRestore();
  }

  Future<void> _createTerm(
    OnboardingProfile profile,
    OnboardingCatalog catalog, {
    required bool hasActiveTerm,
  }) async {
    final draft = await showDialog<PersonalTermCreateInput>(
      context: context,
      builder: (dialogContext) => _TermCreateDialog(
        profile: profile,
        catalog: catalog,
        hasActiveTerm: hasActiveTerm,
      ),
    );
    if (draft == null || !mounted) return;
    final confirmed = await _confirm(
      title: '新しい学期を作成しますか？',
      message:
          draft.makeActive ? '作成後、この学期を現在の学期として有効にします。' : '作成後も現在の学期は変更しません。',
      confirmLabel: '作成する',
      confirmKey: const Key('confirm-create-personal-term'),
    );
    if (!confirmed || !mounted) return;

    await _mutate(() async {
      final result =
          await ref.read(termPeriodRepositoryProvider).createTerm(draft);
      await _refreshAfterMutation(result.activeTermId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('学期を作成しました')),
      );
    });
  }

  Future<void> _activateTerm(PersonalTerm term) async {
    final confirmed = await _confirm(
      title: 'この学期を有効にしますか？',
      message: '${term.name}を現在の学期に設定します。授業追加と時間割の対象も切り替わります。',
      confirmLabel: '有効にする',
      confirmKey: const Key('confirm-activate-personal-term'),
    );
    if (!confirmed || !mounted) return;

    await _mutate(() async {
      await ref.read(termPeriodRepositoryProvider).activateTerm(term.id);
      await _refreshAfterMutation(term.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${term.name}を現在の学期にしました')),
      );
    });
  }

  Future<void> _editPeriods(
    OnboardingProfile profile,
    OnboardingCatalog catalog,
    PersonalTerm term,
    List<PersonalPeriodSetting> periods,
  ) async {
    final input = await showDialog<PeriodSettingsInput>(
      context: context,
      builder: (_) => _PeriodSettingsDialog(
        profile: profile,
        catalog: catalog,
        term: term,
        currentPeriods: periods,
      ),
    );
    if (input == null || !mounted) return;
    final confirmed = await _confirm(
      title: '時限設定を置き換えますか？',
      message: 'この学期の時限設定を、選択した内容にまとめて置き換えます。',
      confirmLabel: '置き換える',
      confirmKey: const Key('confirm-replace-personal-periods'),
    );
    if (!confirmed || !mounted) return;

    await _mutate(() async {
      await ref
          .read(termPeriodRepositoryProvider)
          .replacePeriods(termId: term.id, input: input);
      await _refreshAfterMutation(term.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('時限設定を更新しました')),
      );
    });
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required Key confirmKey,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                key: confirmKey,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    if (_isMutating) return;
    setState(() => _isMutating = true);
    try {
      await operation();
    } on AppError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('学期または時限の更新に失敗しました')),
      );
    } finally {
      if (mounted) setState(() => _isMutating = false);
    }
  }

  Future<void> _refreshAfterMutation(String termId) async {
    ref.invalidate(personalPeriodSettingsProvider(termId));
    ref.invalidate(personalTermPeriodSnapshotProvider);
    await ref.read(onboardingControllerProvider.notifier).retryProfileRestore();
  }
}

class _ActiveTermCard extends StatelessWidget {
  const _ActiveTermCard({
    required this.term,
    required this.periods,
    required this.mutating,
    required this.onEditPeriods,
    required this.onRetryPeriods,
  });

  final PersonalTerm term;
  final AsyncValue<List<PersonalPeriodSetting>> periods;
  final bool mutating;
  final VoidCallback? onEditPeriods;
  final VoidCallback onRetryPeriods;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_today_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '現在の学期',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Chip(label: Text('現在')),
              ],
            ),
            const SizedBox(height: 8),
            Text(term.name, style: Theme.of(context).textTheme.titleLarge),
            Text('${term.academicYear}年度 ・ ${term.type.label}'),
            Text('${_dateText(term.startDate)} 〜 ${_dateText(term.endDate)}'),
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '時限設定',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('edit-active-period-settings'),
                  onPressed: mutating ? null : onEditPeriods,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('編集'),
                ),
              ],
            ),
            periods.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.error_outline),
                title: const Text('時限設定を取得できませんでした'),
                trailing: IconButton(
                  tooltip: '再読み込み',
                  onPressed: onRetryPeriods,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              data: (items) => items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('時限設定がありません。編集から追加してください。'),
                    )
                  : Column(
                      children: [
                        for (final item in items)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.schedule_outlined),
                            title: Text(
                              '${_weekdayLabel(item.dayOfWeek)}曜 '
                              '第${item.periodNo}時限',
                            ),
                            subtitle: Text(
                              '${_timeText(item.startTimeMinutes)} 〜 '
                              '${_timeText(item.endTimeMinutes)}',
                            ),
                            trailing: item.sourceTemplateSetId == null
                                ? const Text('手動')
                                : const Text('テンプレート'),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonalTermTile extends StatelessWidget {
  const _PersonalTermTile({
    required this.term,
    required this.active,
    required this.mutating,
    required this.onActivate,
  });

  final PersonalTerm term;
  final bool active;
  final bool mutating;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('personal-term-${term.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        active ? Icons.check_circle_outline : Icons.calendar_month_outlined,
      ),
      title: Text(term.name),
      subtitle: Text(
        '${term.academicYear}年度 ・ ${term.type.label} ・ '
        '${_dateText(term.startDate)}〜${_dateText(term.endDate)}',
      ),
      trailing: active
          ? const Chip(label: Text('現在'))
          : OutlinedButton(
              key: ValueKey('activate-term-${term.id}'),
              onPressed: mutating ? null : onActivate,
              child: const Text('有効にする'),
            ),
    );
  }
}

enum _TermCreationMode { template, custom }

class _TermCreateDialog extends StatefulWidget {
  const _TermCreateDialog({
    required this.profile,
    required this.catalog,
    required this.hasActiveTerm,
  });

  final OnboardingProfile profile;
  final OnboardingCatalog catalog;
  final bool hasActiveTerm;

  @override
  State<_TermCreateDialog> createState() => _TermCreateDialogState();
}

class _TermCreateDialogState extends State<_TermCreateDialog> {
  final _formKey = GlobalKey<FormState>();
  final _periodEditorKey = GlobalKey<_PeriodSourceFieldsState>();
  final _nameController = TextEditingController();
  final _yearController = TextEditingController();
  final _startDateController = TextEditingController();
  final _endDateController = TextEditingController();

  late _TermCreationMode _mode;
  String? _templateTermId;
  PersonalTermType _customType = PersonalTermType.semester;
  bool _makeActive = true;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final terms = _templateTerms;
    _mode =
        terms.isEmpty ? _TermCreationMode.custom : _TermCreationMode.template;
    if (terms.length == 1) _templateTermId = terms.single.id;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _yearController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  List<TermTemplateOption> get _templateTerms {
    final universityId = widget.profile.universityId;
    if (universityId == null) return const [];
    return widget.catalog.termsFor(universityId);
  }

  int? get _selectedAcademicYear {
    if (_mode == _TermCreationMode.template) {
      for (final term in _templateTerms) {
        if (term.id == _templateTermId) return term.academicYear;
      }
      return null;
    }
    return int.tryParse(_yearController.text.trim());
  }

  List<PeriodTemplateSetOption> get _eligiblePeriodSets {
    final universityId = widget.profile.universityId;
    final academicYear = _selectedAcademicYear;
    if (universityId == null || academicYear == null) return const [];
    return widget.catalog.periodSetsFor(
      universityId: universityId,
      campusId: widget.profile.campusId,
      academicYear: academicYear,
      userType: widget.profile.userType,
    );
  }

  @override
  Widget build(BuildContext context) {
    final terms = _templateTerms;
    final periodSets = _eligiblePeriodSets;
    return AlertDialog(
      title: const Text('学期を追加'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<_TermCreationMode>(
                  segments: [
                    ButtonSegment(
                      value: _TermCreationMode.template,
                      enabled: terms.isNotEmpty,
                      label: const Text('テンプレートから複製'),
                      icon: const Icon(Icons.content_copy_outlined),
                    ),
                    const ButtonSegment(
                      value: _TermCreationMode.custom,
                      label: Text('カスタム入力'),
                      icon: Icon(Icons.edit_calendar_outlined),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selected) {
                    if (selected.isEmpty) return;
                    setState(() {
                      _mode = selected.single;
                      _formError = null;
                    });
                  },
                ),
                const SizedBox(height: 16),
                if (_mode == _TermCreationMode.template) ...[
                  if (terms.isEmpty)
                    const Text('利用できる学期テンプレートがありません。')
                  else
                    DropdownButtonFormField<String>(
                      key: const Key('term-template-select'),
                      initialValue: _templateTermId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '学期テンプレート'),
                      items: [
                        for (final term in terms)
                          DropdownMenuItem(
                            value: term.id,
                            child:
                                Text('${term.name} (${term.academicYear}年度)'),
                          ),
                      ],
                      validator: (value) =>
                          value == null ? '学期を選択してください' : null,
                      onChanged: (value) => setState(() {
                        _templateTermId = value;
                        _formError = null;
                      }),
                    ),
                ] else ...[
                  TextFormField(
                    key: const Key('custom-term-name'),
                    controller: _nameController,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '学期名'),
                    validator: (value) =>
                        (value?.trim().isEmpty ?? true) ? '学期名を入力してください' : null,
                  ),
                  TextFormField(
                    key: const Key('custom-term-year'),
                    controller: _yearController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '年度'),
                    validator: (value) {
                      final year = int.tryParse(value?.trim() ?? '');
                      return year == null || year < 1900 || year > 2200
                          ? '1900〜2200の年度を入力してください'
                          : null;
                    },
                    onChanged: (_) => setState(() => _formError = null),
                  ),
                  DropdownButtonFormField<PersonalTermType>(
                    key: const Key('custom-term-type'),
                    initialValue: _customType,
                    decoration: const InputDecoration(labelText: '学期種別'),
                    items: [
                      for (final type in PersonalTermType.values)
                        DropdownMenuItem(value: type, child: Text(type.label)),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _customType = value);
                    },
                  ),
                  TextFormField(
                    key: const Key('custom-term-start-date'),
                    controller: _startDateController,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '開始日',
                      hintText: 'YYYY-MM-DD',
                    ),
                    validator: (value) => _parseDateOnly(value) == null
                        ? 'YYYY-MM-DD形式で開始日を入力してください'
                        : null,
                  ),
                  TextFormField(
                    key: const Key('custom-term-end-date'),
                    controller: _endDateController,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '終了日',
                      hintText: 'YYYY-MM-DD',
                    ),
                    validator: (value) {
                      final start = _parseDateOnly(_startDateController.text);
                      final end = _parseDateOnly(value);
                      return end == null ||
                              (start != null && end.isBefore(start))
                          ? '開始日以降の終了日を入力してください'
                          : null;
                    },
                  ),
                ],
                const SizedBox(height: 12),
                _PeriodSourceFields(
                  key: _periodEditorKey,
                  templateSets: periodSets,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const Key('new-term-make-active'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('作成後に現在の学期へ設定'),
                  value: _makeActive,
                  onChanged: widget.hasActiveTerm
                      ? (value) => setState(() => _makeActive = value)
                      : null,
                ),
                if (!widget.hasActiveTerm) const Text('最初の学期は現在の学期として作成されます。'),
                if (_formError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _formError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('draft-create-personal-term-button'),
          onPressed: _submit,
          child: const Text('作成内容を確認'),
        ),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final periodSettings = _periodEditorKey.currentState?.buildInput();
    if (periodSettings == null) {
      setState(() => _formError = '時限設定を確認してください。');
      return;
    }

    try {
      final input = switch (_mode) {
        _TermCreationMode.template => PersonalTermCreateInput.fromTemplate(
            termTemplateId: _templateTermId ?? '',
            periodSettings: periodSettings,
            makeActive: _makeActive,
          ),
        _TermCreationMode.custom => PersonalTermCreateInput.custom(
            customName: _nameController.text,
            customAcademicYear: int.tryParse(_yearController.text.trim()),
            customStartDate: _parseDateOnly(_startDateController.text),
            customEndDate: _parseDateOnly(_endDateController.text),
            customType: _customType,
            periodSettings: periodSettings,
            makeActive: _makeActive,
          ),
      };
      input.validate();
      Navigator.pop(context, input);
    } on ArgumentError {
      setState(() => _formError = '学期と時限の入力内容を確認してください。');
    }
  }
}

class _PeriodSettingsDialog extends StatefulWidget {
  const _PeriodSettingsDialog({
    required this.profile,
    required this.catalog,
    required this.term,
    required this.currentPeriods,
  });

  final OnboardingProfile profile;
  final OnboardingCatalog catalog;
  final PersonalTerm term;
  final List<PersonalPeriodSetting> currentPeriods;

  @override
  State<_PeriodSettingsDialog> createState() => _PeriodSettingsDialogState();
}

class _PeriodSettingsDialogState extends State<_PeriodSettingsDialog> {
  final _periodEditorKey = GlobalKey<_PeriodSourceFieldsState>();
  String? _error;

  List<PeriodTemplateSetOption> get _periodSets {
    final universityId = widget.profile.universityId;
    if (universityId == null) return const [];
    return widget.catalog.periodSetsFor(
      universityId: universityId,
      campusId: widget.profile.campusId,
      academicYear: widget.term.academicYear,
      userType: widget.profile.userType,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sourceIds = widget.currentPeriods
        .map((period) => period.sourceTemplateSetId)
        .whereType<String>()
        .toSet();
    final initialTemplateSetId =
        sourceIds.length == 1 ? sourceIds.single : null;
    return AlertDialog(
      title: const Text('時限設定を編集'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.term.name}の時限を設定します。'),
              const SizedBox(height: 12),
              _PeriodSourceFields(
                key: _periodEditorKey,
                templateSets: _periodSets,
                initialTemplateSetId: initialTemplateSetId,
                autoSelectSingleTemplate: widget.currentPeriods.isEmpty,
                initialPeriods: [
                  for (final period in widget.currentPeriods)
                    PersonalPeriodDraft(
                      dayOfWeek: period.dayOfWeek,
                      periodNo: period.periodNo,
                      startTimeMinutes: period.startTimeMinutes,
                      endTimeMinutes: period.endTimeMinutes,
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          key: const Key('save-period-settings-draft-button'),
          onPressed: _submit,
          child: const Text('変更内容を確認'),
        ),
      ],
    );
  }

  void _submit() {
    final input = _periodEditorKey.currentState?.buildInput();
    if (input == null) {
      setState(() => _error = '時限設定を確認してください。');
      return;
    }
    Navigator.pop(context, input);
  }
}

enum _PeriodSource { template, custom }

class _PeriodSourceFields extends StatefulWidget {
  const _PeriodSourceFields({
    super.key,
    required this.templateSets,
    this.initialTemplateSetId,
    this.autoSelectSingleTemplate = true,
    this.initialPeriods = const [],
  });

  final List<PeriodTemplateSetOption> templateSets;
  final String? initialTemplateSetId;
  final bool autoSelectSingleTemplate;
  final List<PersonalPeriodDraft> initialPeriods;

  @override
  State<_PeriodSourceFields> createState() => _PeriodSourceFieldsState();
}

class _PeriodSourceFieldsState extends State<_PeriodSourceFields> {
  late _PeriodSource _source;
  String? _templateSetId;
  late List<_PeriodDraftControllers> _rows;
  String? _error;
  var _sourceWasExplicitlySelected = false;

  @override
  void initState() {
    super.initState();
    _templateSetId = _containsTemplate(widget.initialTemplateSetId)
        ? widget.initialTemplateSetId
        : (_canAutoSelectSingleTemplate ? widget.templateSets.single.id : null);
    _source =
        _templateSetId != null ? _PeriodSource.template : _PeriodSource.custom;
    _rows = [
      for (final period in widget.initialPeriods)
        _PeriodDraftControllers.fromDraft(period),
    ];
  }

  @override
  void didUpdateWidget(covariant _PeriodSourceFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_containsTemplate(_templateSetId)) {
      final shouldAutoSelect =
          _canAutoSelectSingleTemplate && !_sourceWasExplicitlySelected;
      _templateSetId = shouldAutoSelect ? widget.templateSets.single.id : null;
      if (_templateSetId != null) {
        _source = _PeriodSource.template;
      } else if (_source == _PeriodSource.template) {
        _source = _PeriodSource.custom;
      }
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  bool _containsTemplate(String? id) =>
      id != null && widget.templateSets.any((item) => item.id == id);

  bool get _canAutoSelectSingleTemplate =>
      widget.autoSelectSingleTemplate &&
      widget.initialPeriods.isEmpty &&
      widget.templateSets.length == 1;

  PeriodSettingsInput? buildInput() {
    if (_source == _PeriodSource.template) {
      final templateSetId = _templateSetId;
      if (templateSetId == null) {
        setState(() => _error = '時限テンプレートを選択してください。');
        return null;
      }
      return PeriodTemplateSettingsInput(templateSetId);
    }
    if (_rows.isEmpty) {
      setState(() => _error = '少なくとも1つの時限を追加してください。');
      return null;
    }
    final periods = <PersonalPeriodDraft>[];
    for (final row in _rows) {
      final draft = row.toDraft();
      if (draft == null) {
        setState(() => _error = '曜日・時限・開始時刻・終了時刻を確認してください。');
        return null;
      }
      periods.add(draft);
    }
    try {
      final input = CustomPeriodSettingsInput(periods);
      input.validate();
      return input;
    } on ArgumentError {
      setState(() => _error = '時限の重複または時間の重なりを確認してください。');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('時限設定', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<_PeriodSource>(
          segments: [
            ButtonSegment(
              value: _PeriodSource.template,
              enabled: widget.templateSets.isNotEmpty,
              label: const Text('テンプレートを使用'),
              icon: const Icon(Icons.layers_outlined),
            ),
            const ButtonSegment(
              value: _PeriodSource.custom,
              label: Text('時限を手動編集'),
              icon: Icon(Icons.edit_outlined),
            ),
          ],
          selected: {_source},
          onSelectionChanged: (selected) {
            if (selected.isEmpty) return;
            setState(() {
              _source = selected.single;
              _sourceWasExplicitlySelected = true;
              _error = null;
            });
          },
        ),
        const SizedBox(height: 8),
        if (_source == _PeriodSource.template) ...[
          if (widget.templateSets.isEmpty)
            const Text('利用できる時限テンプレートがありません。手動編集を選択してください。')
          else
            DropdownButtonFormField<String>(
              key: const Key('period-template-set-select'),
              initialValue: _templateSetId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '時限テンプレート'),
              items: [
                for (final set in widget.templateSets)
                  DropdownMenuItem(value: set.id, child: Text(set.name)),
              ],
              onChanged: (value) => setState(() {
                _templateSetId = value;
                _error = null;
              }),
            ),
        ] else ...[
          if (_rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('時限を追加して、曜日・時限・開始時刻・終了時刻を入力してください。'),
            ),
          for (var index = 0; index < _rows.length; index++)
            _CustomPeriodRow(
              index: index,
              controllers: _rows[index],
              onRemove: () => _removeRow(index),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('add-custom-period-button'),
              onPressed: _addRow,
              icon: const Icon(Icons.add),
              label: const Text('時限を追加'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  void _addRow() {
    setState(() {
      _rows.add(_PeriodDraftControllers());
      _error = null;
    });
  }

  void _removeRow(int index) {
    setState(() {
      _rows.removeAt(index).dispose();
      _error = null;
    });
  }
}

class _CustomPeriodRow extends StatelessWidget {
  const _CustomPeriodRow({
    required this.index,
    required this.controllers,
    required this.onRemove,
  });

  final int index;
  final _PeriodDraftControllers controllers;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text('時限 ${index + 1}')),
                IconButton(
                  tooltip: 'この時限を削除',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('period-draft-day-$index'),
                    controller: controllers.day,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '曜日 (1〜7)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('period-draft-number-$index'),
                    controller: controllers.period,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '時限 (1〜9)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('period-draft-start-$index'),
                    controller: controllers.start,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '開始',
                      hintText: 'HH:MM',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('period-draft-end-$index'),
                    controller: controllers.end,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '終了',
                      hintText: 'HH:MM',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodDraftControllers {
  _PeriodDraftControllers()
      : day = TextEditingController(),
        period = TextEditingController(),
        start = TextEditingController(),
        end = TextEditingController();

  _PeriodDraftControllers.fromDraft(PersonalPeriodDraft draft)
      : day = TextEditingController(text: '${draft.dayOfWeek}'),
        period = TextEditingController(text: '${draft.periodNo}'),
        start = TextEditingController(text: _timeText(draft.startTimeMinutes)),
        end = TextEditingController(text: _timeText(draft.endTimeMinutes));

  final TextEditingController day;
  final TextEditingController period;
  final TextEditingController start;
  final TextEditingController end;

  PersonalPeriodDraft? toDraft() {
    final dayOfWeek = int.tryParse(day.text.trim());
    final periodNo = int.tryParse(period.text.trim());
    final startMinutes = _parseTimeMinutes(start.text);
    final endMinutes = _parseTimeMinutes(end.text);
    if (dayOfWeek == null ||
        periodNo == null ||
        startMinutes == null ||
        endMinutes == null) {
      return null;
    }
    return PersonalPeriodDraft(
      dayOfWeek: dayOfWeek,
      periodNo: periodNo,
      startTimeMinutes: startMinutes,
      endTimeMinutes: endMinutes,
    );
  }

  void dispose() {
    day.dispose();
    period.dispose();
    start.dispose();
    end.dispose();
  }
}

DateTime? _parseDateOnly(String? value) {
  final match =
      RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final year = int.tryParse(match.group(1) ?? '');
  final month = int.tryParse(match.group(2) ?? '');
  final day = int.tryParse(match.group(3) ?? '');
  if (year == null || month == null || day == null) return null;
  final result = DateTime(year, month, day);
  return result.year == year && result.month == month && result.day == day
      ? result
      : null;
}

int? _parseTimeMinutes(String? value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '');
  if (hour == null ||
      minute == null ||
      hour < 0 ||
      hour > 24 ||
      minute < 0 ||
      minute > 59 ||
      (hour == 24 && minute != 0)) {
    return null;
  }
  return hour * 60 + minute;
}

String _weekdayLabel(int dayOfWeek) {
  const labels = ['月', '火', '水', '木', '金', '土', '日'];
  return dayOfWeek >= 1 && dayOfWeek <= labels.length
      ? labels[dayOfWeek - 1]
      : '$dayOfWeek';
}

String _dateText(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';

String _timeText(int minutes) {
  final hour = minutes ~/ 60;
  final minute = minutes % 60;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
