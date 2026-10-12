import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../auth/application/auth_providers.dart';
import '../application/email_review_providers.dart';
import '../domain/email_review_models.dart';
import '../domain/email_timezone.dart';
import 'email_review_labels.dart';

class EmailCandidateReviewScreen extends ConsumerWidget {
  const EmailCandidateReviewScreen({
    required this.candidateId,
    super.key,
  });

  final String candidateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentationEnabled =
        ref.watch(emailImportPresentationEnabledProvider);
    final session = ref.watch(currentAuthSessionProvider);
    if (!presentationEnabled) {
      return const _ReviewMessageScreen(
        message: 'メール取込は現在利用できません',
      );
    }
    if (session == null) {
      return const _ReviewMessageScreen(
        message: 'メール候補を確認するにはログインが必要です',
      );
    }
    final candidates = ref.watch(
      emailReviewCandidatesProvider(session.userId),
    );
    return candidates.when(
      loading: () => Scaffold(
        body: SafeArea(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: 'メール候補を読み込み中',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      ),
      error: (_, __) => _ReviewMessageScreen(
        message: 'メール候補を読み込めませんでした',
        actionLabel: '再読み込み',
        onAction: () => ref.invalidate(
          emailReviewCandidatesProvider(session.userId),
        ),
      ),
      data: (items) {
        final candidate =
            items.where((item) => item.id == candidateId).firstOrNull;
        if (candidate == null) {
          return const _ReviewMessageScreen(
            message: 'メール候補が見つかりません',
          );
        }
        if (candidate.state == EmailCandidateReviewState.dismissed) {
          return const _DismissedCandidateScreen();
        }
        if (candidate.payload == null) {
          return _MalformedCandidateScreen(
            ownerUserId: session.userId,
            candidate: candidate,
          );
        }
        return _EmailCandidateReviewForm(
          ownerUserId: session.userId,
          candidate: candidate,
        );
      },
    );
  }
}

class _EmailCandidateReviewForm extends ConsumerStatefulWidget {
  const _EmailCandidateReviewForm({
    required this.ownerUserId,
    required this.candidate,
  });

  final String ownerUserId;
  final EmailReviewCandidate candidate;

  @override
  ConsumerState<_EmailCandidateReviewForm> createState() =>
      _EmailCandidateReviewFormState();
}

class _EmailCandidateReviewFormState
    extends ConsumerState<_EmailCandidateReviewForm> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _courseNameController = TextEditingController();
  final _courseCodeController = TextEditingController();
  final _dueController = TextEditingController();
  final _timezoneController = TextEditingController();
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  final _locationController = TextEditingController();
  final _urlController = TextEditingController();
  final _remindersController = TextEditingController();
  final _codec = const EmailCandidatePayloadCodec();

  late EmailCandidateType _candidateType;
  late bool _dueAllDay;
  late String _editingTimezone;
  String? _selectedCourseId;
  var _reviewAcknowledged = false;
  var _initializedCandidateId = '';

  Iterable<TextEditingController> get _controllers => [
        _titleController,
        _courseNameController,
        _courseCodeController,
        _dueController,
        _timezoneController,
        _startController,
        _endController,
        _locationController,
        _urlController,
        _remindersController,
      ];

  @override
  void initState() {
    super.initState();
    _initialize(widget.candidate);
    for (final controller in _controllers) {
      controller.addListener(_fieldChanged);
    }
  }

  @override
  void didUpdateWidget(covariant _EmailCandidateReviewForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candidate.id != widget.candidate.id) {
      _initialize(widget.candidate);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_fieldChanged)
        ..dispose();
    }
    super.dispose();
  }

  void _initialize(EmailReviewCandidate candidate) {
    if (_initializedCandidateId == candidate.id) return;
    final payload = candidate.payload!;
    _initializedCandidateId = candidate.id;
    _candidateType = payload.candidateType;
    _dueAllDay = payload.due.allDay;
    _editingTimezone = candidate.timezone;
    _titleController.text = payload.title ?? '';
    _courseNameController.text = payload.courseHint.name ?? '';
    _courseCodeController.text = payload.courseHint.code ?? '';
    _dueController.text = formatEmailInputDateTime(
      payload.due.at,
      timeZone: _editingTimezone,
    );
    _timezoneController.text = _editingTimezone;
    _startController.text = formatEmailInputDateTime(
      payload.startAt,
      timeZone: _editingTimezone,
    );
    _endController.text = formatEmailInputDateTime(
      payload.endAt,
      timeZone: _editingTimezone,
    );
    _locationController.text = payload.location ?? '';
    _urlController.text = payload.submissionUrl ?? '';
    _remindersController.text = payload.suggestedRemindersMinutes.join(', ');
    _reviewAcknowledged = false;
  }

  void _fieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final payload = candidate.payload!;
    final network = ref.watch(emailNetworkAvailableProvider).valueOrNull;
    final action = ref.watch(emailReviewActionControllerProvider);
    final ownedCourses = ref.watch(emailOwnedCoursesProvider);
    _listenForFeedback();
    final readOnly = candidate.isHistory;
    final draft = _tryBuildPayload();
    final canSave = !readOnly && !action.isBusy && draft != null;
    final canConfirm = canSave &&
        candidate.state != EmailCandidateReviewState.updateAvailable &&
        _reviewAcknowledged &&
        _isCompleteForConfirmation(draft);

    return Scaffold(
      appBar: AppBar(
        title: const Text('メール候補を確認'),
        actions: [
          if (!readOnly)
            TextButton(
              key: const Key('save-email-candidate-button'),
              onPressed: canSave ? () => _save(draft) : null,
              child: const Text('保存'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (network == false) const _ReviewOfflineBanner(),
            if (action.isBusy)
              Semantics(
                liveRegion: true,
                label: _operationLabel(action.operation),
                child: const LinearProgressIndicator(),
              ),
            if (candidate.state == EmailCandidateReviewState.updateAvailable)
              Material(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.update_outlined),
                  title: Text('変更候補があります'),
                  subtitle: Text('追加済みの予定は自動では変更されません。差分を確認して操作してください。'),
                ),
              ),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('email-candidate-review-${candidate.id}'),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    key: const Key('email-candidate-review-list'),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                    children: [
                      _StateHeader(candidate: candidate),
                      const SizedBox(height: 16),
                      const _PrivateCreationNotice(),
                      const SizedBox(height: 20),
                      Text(
                        '候補の内容',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<EmailCandidateType>(
                        key: const Key('email-candidate-type-field'),
                        initialValue: _candidateType,
                        decoration: const InputDecoration(labelText: '種類'),
                        items: EmailCandidateType.values
                            .map(
                              (type) => DropdownMenuItem(
                                value: type,
                                child: Text(emailCandidateTypeLabel(type)),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: readOnly
                            ? null
                            : (value) => setState(() {
                                  _candidateType = value ?? _candidateType;
                                  if (_candidateType ==
                                          EmailCandidateType.event ||
                                      _candidateType ==
                                          EmailCandidateType.announcement ||
                                      _candidateType ==
                                          EmailCandidateType.unknown) {
                                    _selectedCourseId = null;
                                  }
                                }),
                      ),
                      if (_candidateType == EmailCandidateType.announcement ||
                          _candidateType == EmailCandidateType.unknown) ...[
                        const SizedBox(height: 8),
                        Text(
                          'この種類のままでは追加できません。内容を確認し、課題・テスト・予定のいずれかへ変更してください。',
                          key: const Key('email-unsupported-type-message'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-title-field'),
                        controller: _titleController,
                        enabled: !readOnly,
                        maxLength:
                            EmailCandidatePayloadCodec.maxTitleCharacters,
                        decoration: const InputDecoration(labelText: 'タイトル'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-course-field'),
                        controller: _courseNameController,
                        enabled: !readOnly,
                        maxLength:
                            EmailCandidatePayloadCodec.maxCourseNameCharacters,
                        decoration: const InputDecoration(labelText: '授業名'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-course-code-field'),
                        controller: _courseCodeController,
                        enabled: !readOnly,
                        maxLength:
                            EmailCandidatePayloadCodec.maxCourseCodeCharacters,
                        decoration: const InputDecoration(labelText: '授業コード'),
                      ),
                      const SizedBox(height: 12),
                      if (_candidateType == EmailCandidateType.assignment ||
                          _candidateType == EmailCandidateType.exam) ...[
                        DropdownButtonFormField<String>(
                          key: const Key('email-candidate-owned-course-field'),
                          initialValue: _selectedCourseId ?? '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '登録済み授業への紐付け',
                            helperText: '候補の授業名から自動選択はしません',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('紐付けない'),
                            ),
                            for (final course in ownedCourses)
                              DropdownMenuItem(
                                value: course.id,
                                child: Text(
                                  course.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: readOnly
                              ? null
                              : (value) => setState(
                                    () => _selectedCourseId =
                                        value == null || value.isEmpty
                                            ? null
                                            : value,
                                  ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        key: const Key('email-candidate-due-field'),
                        controller: _dueController,
                        enabled: !readOnly,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: '締切（設定タイムゾーン）',
                          hintText: '2026-07-31 23:59',
                        ),
                        validator: _optionalDateTimeValidator,
                      ),
                      CheckboxListTile(
                        key: const Key('email-candidate-all-day-field'),
                        contentPadding: EdgeInsets.zero,
                        value: _dueAllDay,
                        onChanged: readOnly
                            ? null
                            : (value) => setState(
                                  () => _dueAllDay = value ?? false,
                                ),
                        title: const Text('終日締切'),
                      ),
                      TextFormField(
                        key: const Key('email-candidate-timezone-field'),
                        controller: _timezoneController,
                        enabled: !readOnly,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: '締切のタイムゾーン（メール設定）',
                          helperText: 'メール取込時の設定を保持します',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-start-field'),
                        controller: _startController,
                        enabled: !readOnly,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: '開始日時（設定タイムゾーン）',
                          hintText: '2026-08-01 10:00',
                        ),
                        validator: _optionalDateTimeValidator,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-end-field'),
                        controller: _endController,
                        enabled: !readOnly,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: '終了日時（設定タイムゾーン）',
                          hintText: '2026-08-01 11:00',
                        ),
                        validator: _optionalDateTimeValidator,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-location-field'),
                        controller: _locationController,
                        enabled: !readOnly,
                        maxLength:
                            EmailCandidatePayloadCodec.maxLocationCharacters,
                        decoration: const InputDecoration(labelText: '場所'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-url-field'),
                        controller: _urlController,
                        enabled: !readOnly,
                        keyboardType: TextInputType.url,
                        maxLength: EmailCandidatePayloadCodec
                            .maxSubmissionUrlCharacters,
                        decoration: const InputDecoration(
                          labelText: '提出先 URL',
                          hintText: 'https://...',
                        ),
                        validator: _urlValidator,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: const Key('email-candidate-reminders-field'),
                        controller: _remindersController,
                        enabled: !readOnly,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '通知リクエスト（何分前）',
                          hintText: '1440, 180',
                          helperText: '通知の実配信ではなく、追加時に保存する通知リクエストです',
                        ),
                        validator: _remindersValidator,
                      ),
                      if (payload.summary != null) ...[
                        const SizedBox(height: 20),
                        Text(
                          '概要',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(payload.summary!),
                      ],
                      const SizedBox(height: 24),
                      _WarningsSection(warnings: payload.warnings),
                      const SizedBox(height: 24),
                      _ConfidenceSection(confidence: payload.confidence),
                      const SizedBox(height: 24),
                      _EvidenceSection(evidence: payload.evidence),
                      if (!readOnly) ...[
                        const SizedBox(height: 24),
                        CheckboxListTile(
                          key: const Key('email-review-acknowledgement'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _reviewAcknowledged,
                          onChanged: action.isBusy
                              ? null
                              : (value) => setState(
                                    () => _reviewAcknowledged = value ?? false,
                                  ),
                          title: const Text('候補の内容と注意事項を確認しました'),
                          subtitle: const Text(
                            '「追加」を押した場合も、自分だけの予定として作成されます。',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: const Key('confirm-email-candidate-button'),
                              onPressed:
                                  canConfirm ? () => _confirm(draft) : null,
                              icon: const Icon(Icons.add_task),
                              label: const Text('追加'),
                            ),
                            OutlinedButton.icon(
                              key: const Key('dismiss-email-candidate-button'),
                              onPressed: action.isBusy ? null : _dismiss,
                              icon: const Icon(Icons.remove_circle_outline),
                              label: const Text('除外'),
                            ),
                            if (candidate.state ==
                                EmailCandidateReviewState.failed)
                              OutlinedButton.icon(
                                key: const Key('retry-email-candidate-button'),
                                onPressed: network == true && !action.isBusy
                                    ? _retry
                                    : null,
                                icon: const Icon(Icons.refresh),
                                label: const Text('再試行'),
                              ),
                          ],
                        ),
                        if (!canConfirm) ...[
                          const SizedBox(height: 12),
                          const Text(
                            '追加するには、種類・タイトル・必要な日時を入力し、確認欄をオンにしてください。',
                            key: Key('email-confirmation-disabled-reason'),
                          ),
                        ],
                      ] else ...[
                        const SizedBox(height: 24),
                        ListTile(
                          leading: Icon(
                            candidate.state ==
                                    EmailCandidateReviewState.confirmed
                                ? Icons.check_circle_outline
                                : Icons.remove_circle_outline,
                          ),
                          title: Text(emailReviewStateLabel(candidate.state)),
                          subtitle: const Text('この候補は確認待ち一覧には表示されません。'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  EmailCandidatePayload? _tryBuildPayload() {
    try {
      final original = widget.candidate.payload!;
      final dueAt = _parseOptionalDateTime(
        _dueController.text,
        referenceInstant: original.due.at,
      );
      final startAt = _parseOptionalDateTime(
        _startController.text,
        referenceInstant: original.startAt,
      );
      final endAt = _parseOptionalDateTime(
        _endController.text,
        referenceInstant: original.endAt,
      );
      if ((_dueController.text.trim().isNotEmpty && dueAt == null) ||
          (_startController.text.trim().isNotEmpty && startAt == null) ||
          (_endController.text.trim().isNotEmpty && endAt == null)) {
        return null;
      }
      final payload = EmailCandidatePayload(
        schemaVersion: original.schemaVersion,
        candidateType: _candidateType,
        title: _nullableText(_titleController.text),
        courseHint: EmailCourseHint(
          name: _nullableText(_courseNameController.text),
          code: _nullableText(_courseCodeController.text),
        ),
        due: EmailDueCandidate(
          at: dueAt,
          allDay: dueAt != null && _dueAllDay,
          timezone: _editingTimezone,
          rawText: original.due.rawText,
        ),
        startAt: startAt,
        endAt: endAt,
        location: _nullableText(_locationController.text),
        submissionUrl: _nullableText(_urlController.text),
        summary: original.summary,
        suggestedRemindersMinutes: _parseReminders(_remindersController.text),
        confidence: original.confidence,
        evidence: original.evidence,
        warnings: original.warnings,
        requiresUserConfirmation: true,
      );
      _codec.toJson(payload);
      return payload;
    } on Object {
      return null;
    }
  }

  bool _isCompleteForConfirmation(EmailCandidatePayload? payload) {
    if (payload == null ||
        payload.title == null ||
        payload.title!.trim().isEmpty) {
      return false;
    }
    return switch (payload.candidateType) {
      EmailCandidateType.assignment => payload.due.at != null,
      EmailCandidateType.exam => payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.event => payload.startAt != null &&
          payload.endAt != null &&
          payload.submissionUrl == null,
      EmailCandidateType.announcement || EmailCandidateType.unknown => false,
    };
  }

  Future<void> _save(EmailCandidatePayload? payload) async {
    if (payload == null || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await ref.read(emailReviewActionControllerProvider.notifier).saveDraft(
          ownerUserId: widget.ownerUserId,
          candidateId: widget.candidate.id,
          payload: payload,
        );
  }

  Future<void> _confirm(EmailCandidatePayload? payload) async {
    if (payload == null ||
        !_isCompleteForConfirmation(payload) ||
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('この候補を追加しますか？'),
            content: Text(
              '${emailCandidateTypeLabel(payload.candidateType)}「${payload.title}」を'
              '自分だけの予定として追加します。公開や共有は行いません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('戻る'),
              ),
              FilledButton(
                key: const Key('confirm-private-email-add-button'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('追加する'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final success = await ref
        .read(emailReviewActionControllerProvider.notifier)
        .saveAndConfirm(
          ownerUserId: widget.ownerUserId,
          candidateId: widget.candidate.id,
          payload: payload,
          warningsAcknowledged: _reviewAcknowledged,
          courseId: switch (payload.candidateType) {
            EmailCandidateType.assignment ||
            EmailCandidateType.exam =>
              _selectedCourseId,
            EmailCandidateType.event ||
            EmailCandidateType.announcement ||
            EmailCandidateType.unknown =>
              null,
          },
        );
    if (success && mounted) context.go('/email-import');
  }

  Future<void> _dismiss() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('この候補を除外しますか？'),
            content: const Text('確認待ちから除外します。課題・テスト・予定は作成されません。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                key: const Key('confirm-email-dismiss-button'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('除外する'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final success = await ref
        .read(emailReviewActionControllerProvider.notifier)
        .dismissMany(
      ownerUserId: widget.ownerUserId,
      candidateIds: [widget.candidate.id],
    );
    if (success && mounted) context.go('/email-import');
  }

  Future<void> _retry() async {
    await ref.read(emailReviewActionControllerProvider.notifier).retryMany(
      ownerUserId: widget.ownerUserId,
      candidateIds: [widget.candidate.id],
    );
  }

  void _listenForFeedback() {
    ref.listen<EmailReviewActionState>(emailReviewActionControllerProvider, (
      previous,
      next,
    ) {
      if (!mounted || next.isBusy) return;
      final expectedAuthorizationHandoff =
          next.connectionStatus == EmailConnectionStatus.connecting &&
              (next.success == EmailReviewSuccess.authorizationOpened ||
                  next.success == EmailReviewSuccess.authorizationPending);
      final message = next.failureCategory != null ||
              (next.connectionStatus != null &&
                  next.connectionStatus != EmailConnectionStatus.connected &&
                  !expectedAuthorizationHandoff)
          ? emailActionFailureMessage(
              connectionStatus: next.connectionStatus,
              errorCategory: next.failureCategory,
            )
          : switch (next.success) {
              EmailReviewSuccess.saved => '変更を保存しました',
              EmailReviewSuccess.dismissed => '候補を除外しました',
              EmailReviewSuccess.retryCompleted => '候補の再処理が完了しました',
              EmailReviewSuccess.confirmed => '予定に追加しました',
              EmailReviewSuccess.connected => 'Gmail に接続しました',
              EmailReviewSuccess.authorizationOpened => 'Google の認証画面を開きました',
              EmailReviewSuccess.authorizationPending => 'Gmail の認証はまだ完了していません',
              EmailReviewSuccess.refreshed => '新着メールの確認が完了しました',
              EmailReviewSuccess.disconnected => 'Gmail の接続を解除しました',
              EmailReviewSuccess.accountDataDeleted => 'メール取込データを削除しました',
              null => null,
            };
      if (message == null ||
          (previous?.failureCategory == next.failureCategory &&
              previous?.success == next.success &&
              previous?.connectionStatus == next.connectionStatus)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }

  String? _optionalDateTimeValidator(String? value) {
    if ((value ?? '').trim().isEmpty) return null;
    return _parseOptionalDateTime(value!) == null
        ? '日時は 2026-07-31 23:59 の形式で入力してください'
        : null;
  }

  String? _urlValidator(String? value) {
    final normalized = (value ?? '').trim();
    if (normalized.isEmpty) return null;
    if (_candidateType != EmailCandidateType.assignment) {
      return '提出先 URL は課題だけに設定できます';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return 'HTTPS URL を入力してください';
    }
    return null;
  }

  String? _remindersValidator(String? value) {
    try {
      _parseReminders(value ?? '');
      return null;
    } on Object {
      return '0〜40320分の整数を、カンマ区切りで入力してください';
    }
  }

  DateTime? _parseOptionalDateTime(
    String value, {
    DateTime? referenceInstant,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    return parseEmailCivilDateTime(
      normalized,
      timeZone: _editingTimezone,
      referenceInstant: referenceInstant,
    );
  }

  List<int> _parseReminders(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return const [];
    final reminders = normalized
        .split(RegExp(r'[,、\s]+'))
        .where((item) => item.isNotEmpty)
        .map(int.parse)
        .toList(growable: false);
    if (reminders.length > EmailCandidatePayloadCodec.maxReminderItems ||
        reminders.toSet().length != reminders.length ||
        reminders.any(
          (item) =>
              item < EmailCandidatePayloadCodec.minReminderMinutes ||
              item > EmailCandidatePayloadCodec.maxReminderMinutes,
        )) {
      throw const FormatException('invalid reminder request');
    }
    return reminders;
  }

  String? _nullableText(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  String _operationLabel(EmailReviewOperation operation) => switch (operation) {
        EmailReviewOperation.saving => '変更を保存中',
        EmailReviewOperation.confirming => '予定を追加中',
        EmailReviewOperation.dismissing => '候補を除外中',
        EmailReviewOperation.retrying => '候補を再処理中',
        EmailReviewOperation.refreshing => '新着メールを確認中',
        EmailReviewOperation.connecting => 'Gmail に接続中',
        EmailReviewOperation.checkingAuthorization => 'Gmail の接続状態を確認中',
        EmailReviewOperation.disconnecting => 'Gmail の接続を解除中',
        EmailReviewOperation.deletingAccountData => 'メール取込データを削除中',
        EmailReviewOperation.idle => '処理中',
      };
}

class _StateHeader extends StatelessWidget {
  const _StateHeader({required this.candidate});

  final EmailReviewCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final payload = candidate.payload!;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Chip(
          avatar: Icon(emailCandidateTypeIcon(payload.candidateType), size: 18),
          label: Text(emailCandidateTypeLabel(payload.candidateType)),
        ),
        Chip(label: Text(emailReviewStateLabel(candidate.state))),
        Text('信頼度 ${(payload.confidence.overall * 100).round()}%'),
      ],
    );
  }
}

class _PrivateCreationNotice extends StatelessWidget {
  const _PrivateCreationNotice();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'まだ予定は作成されていません。「追加」を押した候補だけが、自分のみ（PRIVATE）で作成されます。',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarningsSection extends StatelessWidget {
  const _WarningsSection({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('注意事項', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (warnings.isEmpty)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle_outline),
            title: Text('抽出時の注意事項はありません'),
          )
        else
          for (final warning in warnings)
            ListTile(
              key: Key('email-warning-$warning'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.warning_amber_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(emailWarningLabel(warning)),
            ),
      ],
    );
  }
}

class _ConfidenceSection extends StatelessWidget {
  const _ConfidenceSection({required this.confidence});

  final EmailCandidateConfidence confidence;

  @override
  Widget build(BuildContext context) {
    String percent(double value) => '${(value * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('抽出の信頼度', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('全体 ${percent(confidence.overall)}')),
            Chip(label: Text('タイトル ${percent(confidence.title)}')),
            Chip(label: Text('授業 ${percent(confidence.course)}')),
            Chip(label: Text('日時 ${percent(confidence.dateTime)}')),
          ],
        ),
      ],
    );
  }
}

class _EvidenceSection extends StatelessWidget {
  const _EvidenceSection({required this.evidence});

  final List<EmailCandidateEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('根拠', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (evidence.isEmpty)
          const Text('表示できる根拠はありません')
        else
          for (var index = 0; index < evidence.length; index++)
            Card(
              key: Key('email-evidence-$index'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emailEvidenceFieldLabel(evidence[index].field),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(evidence[index].text),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _ReviewOfflineBanner extends StatelessWidget {
  const _ReviewOfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const ListTile(
        key: Key('email-offline-banner'),
        dense: true,
        leading: Icon(Icons.cloud_off_outlined),
        title: Text('オフラインです'),
        subtitle: Text('編集・保存・除外と、端末内の明示的な追加は続けられます。新着取得はできません。'),
      ),
    );
  }
}

class _MalformedCandidateScreen extends ConsumerWidget {
  const _MalformedCandidateScreen({
    required this.ownerUserId,
    required this.candidate,
  });

  final String ownerUserId;
  final EmailReviewCandidate candidate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(emailNetworkAvailableProvider).valueOrNull == true;
    final action = ref.watch(emailReviewActionControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('メール候補を確認')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                const Text('この候補は安全に表示できませんでした'),
                const SizedBox(height: 8),
                Text(emailErrorMessage(candidate.errorCategory)),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (candidate.canRetry)
                      FilledButton.icon(
                        key:
                            const Key('retry-malformed-email-candidate-button'),
                        onPressed: online && !action.isBusy
                            ? () => ref
                                    .read(
                                  emailReviewActionControllerProvider.notifier,
                                )
                                    .retryMany(
                                  ownerUserId: ownerUserId,
                                  candidateIds: [candidate.id],
                                )
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
                      ),
                    OutlinedButton.icon(
                      key:
                          const Key('dismiss-malformed-email-candidate-button'),
                      onPressed: action.isBusy
                          ? null
                          : () async {
                              final success = await ref
                                  .read(
                                emailReviewActionControllerProvider.notifier,
                              )
                                  .dismissMany(
                                ownerUserId: ownerUserId,
                                candidateIds: [candidate.id],
                              );
                              if (success && context.mounted) {
                                context.go('/email-import');
                              }
                            },
                      icon: const Icon(Icons.remove_circle_outline),
                      label: const Text('除外'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissedCandidateScreen extends StatelessWidget {
  const _DismissedCandidateScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('メール候補の履歴')),
      body: const SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.remove_circle_outline, size: 48),
                SizedBox(height: 16),
                Text('この候補は除外済みです'),
                SizedBox(height: 8),
                Text(
                  '再表示を防ぐ最小限の識別情報だけを保持し、内容と根拠は削除しました。',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReviewMessageScreen extends StatelessWidget {
  const _ReviewMessageScreen({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('メール候補を確認')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
