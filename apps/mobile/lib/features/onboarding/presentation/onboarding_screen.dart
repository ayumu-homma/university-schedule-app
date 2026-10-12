import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/error/app_error.dart';
import '../../auth/application/auth_providers.dart';
import '../../university/presentation/university_request_dialog.dart';
import '../application/onboarding_providers.dart';
import '../domain/onboarding_models.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _entryYearController = TextEditingController();
  final _customTermNameController = TextEditingController();
  final _customTermYearController = TextEditingController();
  final _customTermStartDateController = TextEditingController();
  final _customTermEndDateController = TextEditingController();
  final List<_OnboardingPeriodDraftControllers> _customPeriodRows = [];

  OnboardingUserType _userType = OnboardingUserType.undergraduate;
  _OnboardingTermSource _termSource = _OnboardingTermSource.template;
  _OnboardingPeriodSource _periodSource = _OnboardingPeriodSource.template;
  OnboardingCustomTermType _customTermType = OnboardingCustomTermType.semester;
  String? _formUserId;
  String? _universityId;
  String? _campusId;
  String? _termTemplateId;
  String? _periodTemplateSetId;
  String? _idempotencyKey;
  String? _formError;
  var _termSourceWasExplicitlySelected = false;
  var _periodSourceWasExplicitlySelected = false;

  @override
  void dispose() {
    _entryYearController.dispose();
    _customTermNameController.dispose();
    _customTermYearController.dispose();
    _customTermStartDateController.dispose();
    _customTermEndDateController.dispose();
    _clearCustomPeriodRows();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileState = ref.watch(onboardingControllerProvider);
    final profile = profileState.valueOrNull;
    final session = ref.watch(currentAuthSessionProvider);
    if (profile == null || profile.userId != session?.userId) {
      if (profileState.isLoading) return const _OnboardingLoadingScreen();
      if (profile != null) return const _OnboardingLoadingScreen();
      return _OnboardingFailureScreen(
        message: _safeMessage(profileState.error),
        onRetry: () => ref
            .read(onboardingControllerProvider.notifier)
            .retryProfileRestore(),
      );
    }

    final catalogState = ref.watch(onboardingCatalogProvider);
    return catalogState.when(
      data: (catalog) => _buildForm(
        context,
        catalog,
        profile: profile,
        profileState: profileState,
      ),
      loading: () => const _OnboardingLoadingScreen(),
      error: (error, stackTrace) => _OnboardingFailureScreen(
        message: _safeMessage(error),
        onRetry: () => ref.invalidate(onboardingCatalogProvider),
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    OnboardingCatalog catalog, {
    required OnboardingProfile profile,
    required AsyncValue<OnboardingProfile?> profileState,
  }) {
    _resetForProfile(profile.userId);
    _applySafeDefaults(catalog);
    final universityId = _universityId;
    final terms = universityId == null
        ? const <TermTemplateOption>[]
        : catalog.termsFor(universityId);
    final selectedTerm = _findTerm(terms, _termTemplateId);
    final selectedAcademicYear = _termSource == _OnboardingTermSource.template
        ? selectedTerm?.academicYear
        : int.tryParse(_customTermYearController.text.trim());
    final campuses = universityId == null
        ? const <CampusOption>[]
        : catalog.campusesFor(universityId);
    _selectCampusDefault(campuses);
    final periodSets = universityId == null || selectedAcademicYear == null
        ? const <PeriodTemplateSetOption>[]
        : catalog.periodSetsFor(
            universityId: universityId,
            campusId: _campusId,
            academicYear: selectedAcademicYear,
            userType: _userType,
          );
    _selectPeriodDefault(periodSets);

    final isSubmitting = profileState.isLoading;
    final hasTermSelection = _termSource == _OnboardingTermSource.template
        ? selectedTerm != null
        : true;
    final hasPeriodSelection = _periodSource == _OnboardingPeriodSource.template
        ? _periodTemplateSetId != null
        : true;
    final canSubmit = !isSubmitting &&
        universityId != null &&
        (campuses.isEmpty || _campusId != null) &&
        hasTermSelection &&
        hasPeriodSelection;

    return Scaffold(
      appBar: AppBar(title: const Text('初期設定')),
      body: Form(
        key: _formKey,
        child: ListView(
          key: const Key('onboarding-form-list'),
          // Keep the last action above Android's system-navigation area after
          // long onboarding paths (including a university request) are added.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 160),
          children: [
            Text(
              '大学と学期、授業時間を選択または入力してください。',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (profileState.hasError) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: _safeMessage(profileState.error)),
            ],
            if (_formError != null) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: _formError!),
            ],
            const SizedBox(height: 20),
            DropdownButtonFormField<OnboardingUserType>(
              key: const Key('onboarding-user-type'),
              initialValue: _userType,
              decoration: const InputDecoration(labelText: 'ユーザー種別'),
              items: [
                for (final type in OnboardingUserType.values)
                  DropdownMenuItem(value: type, child: Text(type.label)),
              ],
              onChanged: isSubmitting
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _userType = value;
                        _periodTemplateSetId = null;
                        _formError = null;
                        _resetSubmissionIdentity();
                      });
                    },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('onboarding-university-$_universityId'),
              initialValue: _universityId,
              decoration: const InputDecoration(labelText: '大学'),
              items: [
                for (final option in catalog.universities)
                  DropdownMenuItem(value: option.id, child: Text(option.name)),
              ],
              onChanged:
                  isSubmitting ? null : (value) => _selectUniversity(value),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('onboarding-request-university-button'),
                onPressed: isSubmitting ? null : _requestUniversity,
                icon: const Icon(Icons.add_business_outlined),
                label: const Text('見つからない大学を申請'),
              ),
            ),
            const Text(
              '一覧にない大学は公式情報を添えて申請できます。承認後に選択してください。',
            ),
            if (campuses.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('onboarding-campus-$_campusId'),
                initialValue: _campusId,
                decoration: const InputDecoration(labelText: 'キャンパス'),
                items: [
                  for (final option in campuses)
                    DropdownMenuItem(
                        value: option.id, child: Text(option.name)),
                ],
                onChanged: isSubmitting
                    ? null
                    : (value) {
                        setState(() {
                          _campusId = value;
                          _periodTemplateSetId = null;
                          _formError = null;
                          _resetSubmissionIdentity();
                        });
                      },
              ),
            ],
            const SizedBox(height: 16),
            Text('学期', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<_OnboardingTermSource>(
              key: const Key('onboarding-term-source'),
              segments: [
                ButtonSegment(
                  value: _OnboardingTermSource.template,
                  enabled: terms.isNotEmpty,
                  label: const Text('学期テンプレート'),
                  icon: const Icon(Icons.layers_outlined),
                ),
                const ButtonSegment(
                  value: _OnboardingTermSource.custom,
                  label: Text('学期を手入力'),
                  icon: Icon(Icons.edit_calendar_outlined),
                ),
              ],
              selected: {_termSource},
              onSelectionChanged: isSubmitting
                  ? null
                  : (selected) {
                      if (selected.isEmpty) return;
                      setState(() {
                        _termSource = selected.single;
                        _termSourceWasExplicitlySelected = true;
                        _periodTemplateSetId = null;
                        _formError = null;
                        _resetSubmissionIdentity();
                      });
                    },
            ),
            const SizedBox(height: 8),
            if (_termSource == _OnboardingTermSource.template) ...[
              if (terms.isEmpty)
                const Text('利用できる学期テンプレートがありません。学期を手入力してください。')
              else
                DropdownButtonFormField<String>(
                  key: ValueKey('onboarding-term-$_termTemplateId'),
                  initialValue: _termTemplateId,
                  decoration: const InputDecoration(labelText: '学期テンプレート'),
                  items: [
                    for (final option in terms)
                      DropdownMenuItem(
                        value: option.id,
                        child: Text(option.name),
                      ),
                  ],
                  validator: (value) => value == null ? '学期を選択してください' : null,
                  onChanged: isSubmitting
                      ? null
                      : (value) {
                          setState(() {
                            _termTemplateId = value;
                            _periodTemplateSetId = null;
                            _formError = null;
                            _resetSubmissionIdentity();
                          });
                        },
                ),
            ] else ...[
              _CustomTermFields(
                enabled: !isSubmitting,
                nameController: _customTermNameController,
                yearController: _customTermYearController,
                startDateController: _customTermStartDateController,
                endDateController: _customTermEndDateController,
                type: _customTermType,
                onTypeChanged: (value) => setState(() {
                  _customTermType = value;
                  _formError = null;
                  _resetSubmissionIdentity();
                }),
                onChanged: _markInputChanged,
                onAcademicYearChanged: () => _markInputChanged(rebuild: true),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('onboarding-entry-year'),
              controller: _entryYearController,
              enabled: !isSubmitting,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '入学年度'),
              validator: (value) {
                final year = int.tryParse(value?.trim() ?? '');
                return year == null || year < 1900 || year > 2200
                    ? '1900〜2200の年を入力してください'
                    : null;
              },
              onChanged: (_) => _markInputChanged(),
            ),
            const SizedBox(height: 16),
            Text('時限設定', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<_OnboardingPeriodSource>(
              key: const Key('onboarding-period-source'),
              segments: [
                ButtonSegment(
                  value: _OnboardingPeriodSource.template,
                  enabled: periodSets.isNotEmpty,
                  label: const Text('時限テンプレート'),
                  icon: const Icon(Icons.layers_outlined),
                ),
                const ButtonSegment(
                  value: _OnboardingPeriodSource.custom,
                  label: Text('時限を手入力'),
                  icon: Icon(Icons.edit_outlined),
                ),
              ],
              selected: {_periodSource},
              onSelectionChanged: isSubmitting
                  ? null
                  : (selected) {
                      if (selected.isEmpty) return;
                      setState(() {
                        _periodSource = selected.single;
                        _periodSourceWasExplicitlySelected = true;
                        _formError = null;
                        _resetSubmissionIdentity();
                      });
                    },
            ),
            const SizedBox(height: 8),
            if (_periodSource == _OnboardingPeriodSource.template) ...[
              if (periodSets.isEmpty)
                const Text('利用できる時限テンプレートがありません。時限を手入力してください。')
              else
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'onboarding-period-set-$_periodTemplateSetId',
                  ),
                  initialValue: _periodTemplateSetId,
                  decoration: const InputDecoration(labelText: '時限テンプレート'),
                  items: [
                    for (final option in periodSets)
                      DropdownMenuItem(
                        value: option.id,
                        child: Text(option.name),
                      ),
                  ],
                  validator: (value) =>
                      value == null ? '時限テンプレートを選択してください' : null,
                  onChanged: isSubmitting
                      ? null
                      : (value) {
                          setState(() {
                            _periodTemplateSetId = value;
                            _formError = null;
                            _resetSubmissionIdentity();
                          });
                        },
                ),
            ] else ...[
              if (_customPeriodRows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('時限を追加して、曜日・時限・開始時刻・終了時刻を入力してください。'),
                ),
              for (var index = 0; index < _customPeriodRows.length; index++)
                _OnboardingCustomPeriodRow(
                  index: index,
                  enabled: !isSubmitting,
                  controllers: _customPeriodRows[index],
                  onChanged: _markInputChanged,
                  onRemove: isSubmitting ? null : () => _removePeriodRow(index),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('onboarding-add-custom-period-button'),
                  onPressed: isSubmitting ? null : _addPeriodRow,
                  icon: const Icon(Icons.add),
                  label: const Text('時限を追加'),
                ),
              ),
            ],
            if (catalog.universities.isEmpty) ...[
              const SizedBox(height: 12),
              const Text('現在選択できる大学がありません。上の申請から追加を依頼できます。'),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('complete-onboarding-button'),
              onPressed: canSubmit ? _complete : null,
              icon: isSubmitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: const Text('設定を保存して開始'),
            ),
          ],
        ),
      ),
    );
  }

  void _resetForProfile(String userId) {
    if (_formUserId == userId) return;
    _formUserId = userId;
    _userType = OnboardingUserType.undergraduate;
    _termSource = _OnboardingTermSource.template;
    _periodSource = _OnboardingPeriodSource.template;
    _customTermType = OnboardingCustomTermType.semester;
    _universityId = null;
    _campusId = null;
    _termTemplateId = null;
    _periodTemplateSetId = null;
    _idempotencyKey = null;
    _formError = null;
    _termSourceWasExplicitlySelected = false;
    _periodSourceWasExplicitlySelected = false;
    _entryYearController.clear();
    _clearCustomTermFields();
    _clearCustomPeriodRows();
  }

  void _applySafeDefaults(OnboardingCatalog catalog) {
    if (!catalog.universities.any((option) => option.id == _universityId)) {
      _universityId = null;
    }
    if (_universityId == null && catalog.universities.length == 1) {
      _universityId = catalog.universities.single.id;
    }
    final universityId = _universityId;
    if (universityId == null) return;

    final terms = catalog.termsFor(universityId);
    if (terms.isEmpty && _termSource == _OnboardingTermSource.template) {
      _termSource = _OnboardingTermSource.custom;
      _termSourceWasExplicitlySelected = false;
    } else if (!_termSourceWasExplicitlySelected && terms.isNotEmpty) {
      _termSource = _OnboardingTermSource.template;
    }
    if (!terms.any((option) => option.id == _termTemplateId)) {
      _termTemplateId = null;
    }
    if (_termSource == _OnboardingTermSource.template &&
        _termTemplateId == null &&
        terms.length == 1) {
      _termTemplateId = terms.single.id;
    }
  }

  void _selectUniversity(String? universityId) {
    setState(() {
      _universityId = universityId;
      _campusId = null;
      _termTemplateId = null;
      _periodTemplateSetId = null;
      _termSource = _OnboardingTermSource.template;
      _periodSource = _OnboardingPeriodSource.template;
      _termSourceWasExplicitlySelected = false;
      _periodSourceWasExplicitlySelected = false;
      _formError = null;
      _clearCustomTermFields();
      _clearCustomPeriodRows();
      _resetSubmissionIdentity();
    });
  }

  void _selectCampusDefault(List<CampusOption> campuses) {
    if (!campuses.any((option) => option.id == _campusId)) {
      _campusId = null;
    }
    if (_campusId != null || campuses.isEmpty) return;
    final main = campuses.where((option) => option.isMain).toList();
    if (main.length == 1) {
      _campusId = main.single.id;
    } else if (campuses.length == 1) {
      _campusId = campuses.single.id;
    }
  }

  void _selectPeriodDefault(List<PeriodTemplateSetOption> options) {
    if (!options.any((option) => option.id == _periodTemplateSetId)) {
      _periodTemplateSetId = null;
    }
    if (options.isEmpty) {
      _periodSource = _OnboardingPeriodSource.custom;
      _periodSourceWasExplicitlySelected = false;
      return;
    }
    if (!_periodSourceWasExplicitlySelected) {
      _periodSource = _OnboardingPeriodSource.template;
    }
    if (_periodSource != _OnboardingPeriodSource.template ||
        _periodTemplateSetId != null) {
      return;
    }
    final defaults = options.where((option) => option.isDefault).toList();
    if (defaults.length == 1) {
      _periodTemplateSetId = defaults.single.id;
    } else if (options.length == 1) {
      _periodTemplateSetId = options.single.id;
    }
  }

  TermTemplateOption? _findTerm(
    List<TermTemplateOption> terms,
    String? id,
  ) {
    for (final term in terms) {
      if (term.id == id) return term;
    }
    return null;
  }

  OnboardingCustomTerm? _buildCustomTerm() {
    final academicYear = int.tryParse(_customTermYearController.text.trim());
    final startDate = _parseDateOnly(_customTermStartDateController.text);
    final endDate = _parseDateOnly(_customTermEndDateController.text);
    if (academicYear == null || startDate == null || endDate == null) {
      return null;
    }
    return OnboardingCustomTerm(
      name: _customTermNameController.text,
      academicYear: academicYear,
      startDate: startDate,
      endDate: endDate,
      type: _customTermType,
    );
  }

  List<OnboardingPeriodDraft>? _buildCustomPeriods() {
    final periods = <OnboardingPeriodDraft>[];
    for (final row in _customPeriodRows) {
      final period = row.toDraft();
      if (period == null) return null;
      periods.add(period);
    }
    return periods;
  }

  void _addPeriodRow() {
    setState(() {
      _customPeriodRows.add(_OnboardingPeriodDraftControllers());
      _formError = null;
      _resetSubmissionIdentity();
    });
  }

  void _removePeriodRow(int index) {
    setState(() {
      _customPeriodRows.removeAt(index).dispose();
      _formError = null;
      _resetSubmissionIdentity();
    });
  }

  void _clearCustomPeriodRows() {
    for (final row in _customPeriodRows) {
      row.dispose();
    }
    _customPeriodRows.clear();
  }

  void _clearCustomTermFields() {
    _customTermNameController.clear();
    _customTermYearController.clear();
    _customTermStartDateController.clear();
    _customTermEndDateController.clear();
  }

  void _markInputChanged({bool rebuild = false}) {
    if (rebuild || _formError != null || _idempotencyKey != null) {
      setState(() {
        _formError = null;
        _resetSubmissionIdentity();
      });
      return;
    }
    _resetSubmissionIdentity();
  }

  void _resetSubmissionIdentity() {
    _idempotencyKey = null;
  }

  Future<void> _complete() async {
    if (_formKey.currentState?.validate() != true) return;
    final universityId = _universityId;
    final entryAcademicYear = int.tryParse(_entryYearController.text.trim());
    final customTerm =
        _termSource == _OnboardingTermSource.custom ? _buildCustomTerm() : null;
    final customPeriods = _periodSource == _OnboardingPeriodSource.custom
        ? _buildCustomPeriods()
        : null;
    if (universityId == null ||
        entryAcademicYear == null ||
        (_termSource == _OnboardingTermSource.custom && customTerm == null) ||
        (_periodSource == _OnboardingPeriodSource.custom &&
            customPeriods == null)) {
      setState(() => _formError = '学期と時限の入力内容を確認してください。');
      return;
    }

    final idempotencyKey = _idempotencyKey ?? const Uuid().v4();
    final completion = OnboardingCompletion(
      idempotencyKey: idempotencyKey,
      userType: _userType,
      universityId: universityId,
      campusId: _campusId,
      entryAcademicYear: entryAcademicYear,
      termTemplateId: _termSource == _OnboardingTermSource.template
          ? _termTemplateId
          : null,
      customTerm: customTerm,
      periodTemplateSetId: _periodSource == _OnboardingPeriodSource.template
          ? _periodTemplateSetId
          : null,
      customPeriods: customPeriods,
    );
    try {
      completion.validate();
    } on ArgumentError {
      setState(() => _formError = '学期と時限の入力内容を確認してください。');
      return;
    }

    _idempotencyKey = idempotencyKey;
    await ref
        .read(onboardingControllerProvider.notifier)
        .completeOnboarding(completion);
  }

  Future<void> _requestUniversity() async {
    final requestId = await showUniversityRequestDialog(context);
    if (requestId == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('大学追加申請を受け付けました。審査後に大学を選択できます。'),
      ),
    );
  }

  String _safeMessage(Object? error) {
    return error is AppError ? error.message : '設定を読み込めませんでした。もう一度お試しください。';
  }
}

enum _OnboardingTermSource { template, custom }

enum _OnboardingPeriodSource { template, custom }

class _OnboardingLoadingScreen extends StatelessWidget {
  const _OnboardingLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: Center(child: CircularProgressIndicator())),
    );
  }
}

class _OnboardingFailureScreen extends StatelessWidget {
  const _OnboardingFailureScreen({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('初期設定')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('再試行')),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

class _CustomTermFields extends StatelessWidget {
  const _CustomTermFields({
    required this.enabled,
    required this.nameController,
    required this.yearController,
    required this.startDateController,
    required this.endDateController,
    required this.type,
    required this.onTypeChanged,
    required this.onChanged,
    required this.onAcademicYearChanged,
  });

  final bool enabled;
  final TextEditingController nameController;
  final TextEditingController yearController;
  final TextEditingController startDateController;
  final TextEditingController endDateController;
  final OnboardingCustomTermType type;
  final ValueChanged<OnboardingCustomTermType> onTypeChanged;
  final VoidCallback onChanged;
  final VoidCallback onAcademicYearChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
          key: const Key('onboarding-custom-term-name'),
          controller: nameController,
          enabled: enabled,
          maxLength: 100,
          decoration: const InputDecoration(labelText: '学期名'),
          validator: (value) =>
              (value?.trim().isEmpty ?? true) ? '学期名を入力してください' : null,
          onChanged: (_) => onChanged(),
        ),
        TextFormField(
          key: const Key('onboarding-custom-term-year'),
          controller: yearController,
          enabled: enabled,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '年度'),
          validator: (value) {
            final year = int.tryParse(value?.trim() ?? '');
            return year == null || year < 1900 || year > 2200
                ? '1900〜2200の年度を入力してください'
                : null;
          },
          onChanged: (_) => onAcademicYearChanged(),
        ),
        DropdownButtonFormField<OnboardingCustomTermType>(
          key: const Key('onboarding-custom-term-type'),
          initialValue: type,
          decoration: const InputDecoration(labelText: '学期種別'),
          items: [
            for (final option in OnboardingCustomTermType.values)
              DropdownMenuItem(value: option, child: Text(option.label)),
          ],
          onChanged: !enabled
              ? null
              : (value) {
                  if (value != null) onTypeChanged(value);
                },
        ),
        TextFormField(
          key: const Key('onboarding-custom-term-start-date'),
          controller: startDateController,
          enabled: enabled,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: '開始日',
            hintText: 'YYYY-MM-DD',
          ),
          validator: (value) => _parseDateOnly(value) == null
              ? 'YYYY-MM-DD形式で開始日を入力してください'
              : null,
          onChanged: (_) => onChanged(),
        ),
        TextFormField(
          key: const Key('onboarding-custom-term-end-date'),
          controller: endDateController,
          enabled: enabled,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: '終了日',
            hintText: 'YYYY-MM-DD',
          ),
          validator: (value) {
            final start = _parseDateOnly(startDateController.text);
            final end = _parseDateOnly(value);
            return end == null || (start != null && end.isBefore(start))
                ? '開始日以降の終了日を入力してください'
                : null;
          },
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}

class _OnboardingCustomPeriodRow extends StatelessWidget {
  const _OnboardingCustomPeriodRow({
    required this.index,
    required this.enabled,
    required this.controllers,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final bool enabled;
  final _OnboardingPeriodDraftControllers controllers;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

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
                  child: TextFormField(
                    key: ValueKey('onboarding-period-draft-day-$index'),
                    controller: controllers.day,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '曜日 (1〜7)'),
                    validator: (value) {
                      final day = int.tryParse(value?.trim() ?? '');
                      return day == null || day < 1 || day > 7
                          ? '1〜7を入力'
                          : null;
                    },
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('onboarding-period-draft-number-$index'),
                    controller: controllers.period,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '時限 (1〜9)'),
                    validator: (value) {
                      final period = int.tryParse(value?.trim() ?? '');
                      return period == null || period < 1 || period > 9
                          ? '1〜9を入力'
                          : null;
                    },
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('onboarding-period-draft-start-$index'),
                    controller: controllers.start,
                    enabled: enabled,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '開始',
                      hintText: 'HH:MM',
                    ),
                    validator: (value) =>
                        _parseTimeMinutes(value) == null ? 'HH:MM形式で入力' : null,
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('onboarding-period-draft-end-$index'),
                    controller: controllers.end,
                    enabled: enabled,
                    keyboardType: TextInputType.datetime,
                    decoration: const InputDecoration(
                      labelText: '終了',
                      hintText: 'HH:MM',
                    ),
                    validator: (value) {
                      final start = _parseTimeMinutes(controllers.start.text);
                      final end = _parseTimeMinutes(value);
                      return end == null || (start != null && end <= start)
                          ? '開始時刻より後を入力'
                          : null;
                    },
                    onChanged: (_) => onChanged(),
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

class _OnboardingPeriodDraftControllers {
  _OnboardingPeriodDraftControllers()
      : day = TextEditingController(),
        period = TextEditingController(),
        start = TextEditingController(),
        end = TextEditingController();

  final TextEditingController day;
  final TextEditingController period;
  final TextEditingController start;
  final TextEditingController end;

  OnboardingPeriodDraft? toDraft() {
    final dayOfWeek = int.tryParse(day.text.trim());
    final periodNo = int.tryParse(period.text.trim());
    final startTimeMinutes = _parseTimeMinutes(start.text);
    final endTimeMinutes = _parseTimeMinutes(end.text);
    if (dayOfWeek == null ||
        periodNo == null ||
        startTimeMinutes == null ||
        endTimeMinutes == null) {
      return null;
    }
    return OnboardingPeriodDraft(
      dayOfWeek: dayOfWeek,
      periodNo: periodNo,
      startTimeMinutes: startTimeMinutes,
      endTimeMinutes: endTimeMinutes,
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
  final year = int.tryParse(match?.group(1) ?? '');
  final month = int.tryParse(match?.group(2) ?? '');
  final day = int.tryParse(match?.group(3) ?? '');
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day
      ? parsed
      : null;
}

int? _parseTimeMinutes(String? value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value?.trim() ?? '');
  final hour = int.tryParse(match?.group(1) ?? '');
  final minute = int.tryParse(match?.group(2) ?? '');
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
