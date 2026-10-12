import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/app_tokens.dart';

enum PrototypeExperiment { today, add, submission }

enum PrototypeVariant { a, b }

enum PrototypeFixture { normal, noCourses, empty, longText }

enum PrototypeAssignmentStatus { open, inProgress, submitted }

enum _DeadlineBucket { today, overdue, later, unset }

_DeadlineBucket _deadlineBucket(String? label) {
  if (label == null) return _DeadlineBucket.unset;
  final match =
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})$').firstMatch(label);
  if (match == null) return _DeadlineBucket.later;
  final date = DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
  final now = DateTime(2026, 9, 18, 8, 30);
  if (date.isBefore(now)) return _DeadlineBucket.overdue;
  return date.year == now.year && date.month == now.month && date.day == now.day
      ? _DeadlineBucket.today
      : _DeadlineBucket.later;
}

DateTime? _parseDue(String? label) {
  if (label == null) return null;
  final match =
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})$').firstMatch(label);
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
  );
}

class PrototypeCourse {
  const PrototypeCourse({
    required this.id,
    required this.title,
    required this.room,
    required this.start,
    required this.end,
  });

  final String id;
  final String title;
  final String room;
  final String start;
  final String end;
}

class PrototypeAssignment {
  const PrototypeAssignment({
    required this.id,
    required this.title,
    required this.courseId,
    required this.dueLabel,
    required this.status,
    this.url = '',
    this.memo = '',
    this.priority = '通常',
    this.history = const [],
    this.previousStatus,
    this.previousHistory,
    this.originatedFromCourse = false,
  });

  final String id;
  final String title;
  final String? courseId;
  final String? dueLabel;
  final PrototypeAssignmentStatus status;
  final String url;
  final String memo;
  final String priority;
  final List<String> history;
  final PrototypeAssignmentStatus? previousStatus;
  final List<String>? previousHistory;
  final bool originatedFromCourse;

  PrototypeAssignment copyWith({
    String? title,
    String? courseId,
    String? dueLabel,
    PrototypeAssignmentStatus? status,
    String? url,
    String? memo,
    String? priority,
    List<String>? history,
    PrototypeAssignmentStatus? previousStatus,
    List<String>? previousHistory,
    bool clearPrevious = false,
    bool? originatedFromCourse,
  }) {
    return PrototypeAssignment(
      id: id,
      title: title ?? this.title,
      courseId: courseId ?? this.courseId,
      dueLabel: dueLabel ?? this.dueLabel,
      status: status ?? this.status,
      url: url ?? this.url,
      memo: memo ?? this.memo,
      priority: priority ?? this.priority,
      history: history ?? this.history,
      previousStatus:
          clearPrevious ? null : (previousStatus ?? this.previousStatus),
      previousHistory:
          clearPrevious ? null : (previousHistory ?? this.previousHistory),
      originatedFromCourse: originatedFromCourse ?? this.originatedFromCourse,
    );
  }
}

class PrototypeDraft {
  const PrototypeDraft({
    this.title = '',
    this.courseId,
    this.dueLabel,
    this.url = '',
    this.memo = '',
    this.priority = '通常',
    this.editingId,
    this.inheritedCourse = false,
    this.error,
  });

  final String title;
  final String? courseId;
  final String? dueLabel;
  final String url;
  final String memo;
  final String priority;
  final String? editingId;
  final bool inheritedCourse;
  final String? error;

  PrototypeDraft copyWith({
    String? title,
    String? courseId,
    bool clearCourse = false,
    String? dueLabel,
    bool clearDue = false,
    String? url,
    String? memo,
    String? priority,
    String? editingId,
    bool clearEditingId = false,
    bool? inheritedCourse,
    String? error,
    bool clearError = false,
  }) {
    return PrototypeDraft(
      title: title ?? this.title,
      courseId: clearCourse ? null : (courseId ?? this.courseId),
      dueLabel: clearDue ? null : (dueLabel ?? this.dueLabel),
      url: url ?? this.url,
      memo: memo ?? this.memo,
      priority: priority ?? this.priority,
      editingId: clearEditingId ? null : (editingId ?? this.editingId),
      inheritedCourse: inheritedCourse ?? this.inheritedCourse,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PrototypeState {
  const PrototypeState({
    required this.experiment,
    required this.variant,
    required this.fixture,
    required this.darkMode,
    required this.courses,
    required this.assignments,
    required this.draft,
    this.introAcknowledged = false,
    this.externalMessage,
    this.savedMessage,
  });

  final PrototypeExperiment experiment;
  final PrototypeVariant variant;
  final PrototypeFixture fixture;
  final bool darkMode;
  final List<PrototypeCourse> courses;
  final List<PrototypeAssignment> assignments;
  final PrototypeDraft draft;
  final bool introAcknowledged;
  final String? externalMessage;
  final String? savedMessage;

  PrototypeState copyWith({
    PrototypeExperiment? experiment,
    PrototypeVariant? variant,
    PrototypeFixture? fixture,
    bool? darkMode,
    List<PrototypeCourse>? courses,
    List<PrototypeAssignment>? assignments,
    PrototypeDraft? draft,
    bool? introAcknowledged,
    String? externalMessage,
    bool clearExternal = false,
    String? savedMessage,
    bool clearSaved = false,
  }) {
    return PrototypeState(
      experiment: experiment ?? this.experiment,
      variant: variant ?? this.variant,
      fixture: fixture ?? this.fixture,
      darkMode: darkMode ?? this.darkMode,
      courses: courses ?? this.courses,
      assignments: assignments ?? this.assignments,
      draft: draft ?? this.draft,
      introAcknowledged: introAcknowledged ?? this.introAcknowledged,
      externalMessage:
          clearExternal ? null : (externalMessage ?? this.externalMessage),
      savedMessage: clearSaved ? null : (savedMessage ?? this.savedMessage),
    );
  }
}

final prototypeControllerProvider =
    NotifierProvider<PrototypeController, PrototypeState>(
  PrototypeController.new,
);

class PrototypeController extends Notifier<PrototypeState> {
  bool _darkMode = false;
  bool _introAcknowledged = false;
  int _revision = 0;

  int get revision => _revision;

  @override
  PrototypeState build() => _seed(
        experiment: PrototypeExperiment.today,
        variant: PrototypeVariant.a,
        fixture: PrototypeFixture.normal,
      );

  void setExperiment(PrototypeExperiment value) {
    state = _seed(
      experiment: value,
      variant: state.variant,
      fixture: state.fixture,
    );
  }

  void setVariant(PrototypeVariant value) {
    state = _seed(
      experiment: state.experiment,
      variant: value,
      fixture: state.fixture,
    );
  }

  void setFixture(PrototypeFixture value) {
    state = _seed(
      experiment: state.experiment,
      variant: state.variant,
      fixture: value,
    );
  }

  void toggleDarkMode() {
    _darkMode = !_darkMode;
    state = state.copyWith(darkMode: _darkMode);
  }

  void acknowledgeIntro() {
    _introAcknowledged = true;
    state = state.copyWith(introAcknowledged: true);
  }

  void reset() {
    state = _seed(
      experiment: state.experiment,
      variant: state.variant,
      fixture: state.fixture,
    );
  }

  void beginAdd({String? courseId, bool inheritedCourse = false}) {
    state = state.copyWith(
      draft:
          PrototypeDraft(courseId: courseId, inheritedCourse: inheritedCourse),
      clearSaved: true,
    );
  }

  void beginEdit(PrototypeAssignment assignment) {
    state = state.copyWith(
      draft: PrototypeDraft(
        title: assignment.title,
        courseId: assignment.courseId,
        dueLabel: assignment.dueLabel,
        url: assignment.url,
        memo: assignment.memo,
        priority: assignment.priority,
        editingId: assignment.id,
        inheritedCourse: assignment.originatedFromCourse,
      ),
      clearSaved: true,
    );
  }

  void updateDraft({
    String? title,
    String? courseId,
    bool clearCourse = false,
    String? dueLabel,
    bool clearDue = false,
    String? url,
    String? memo,
    String? priority,
  }) {
    final changingCourse = courseId != null || clearCourse;
    state = state.copyWith(
      draft: state.draft.copyWith(
        title: title,
        courseId: courseId,
        clearCourse: clearCourse,
        dueLabel: dueLabel,
        clearDue: clearDue,
        url: url,
        memo: memo,
        priority: priority,
        inheritedCourse: changingCourse ? false : null,
        clearError: true,
      ),
    );
  }

  bool validateDraft() {
    final draft = state.draft;
    final error = draft.title.trim().isEmpty
        ? '課題名を入力してください。'
        : draft.dueLabel == null
            ? '締切を選択してください。日付は自動設定されません。'
            : null;
    if (error == null) return true;
    state = state.copyWith(draft: draft.copyWith(error: error));
    return false;
  }

  String? saveDraft() {
    if (!validateDraft()) return null;
    final editingId = state.draft.editingId;
    final id = editingId ?? 'created-${state.assignments.length + 1}';
    final existing = editingId == null
        ? null
        : state.assignments.where((item) => item.id == editingId).firstOrNull;
    final assignment = PrototypeAssignment(
      id: id,
      title: state.draft.title.trim(),
      courseId: state.draft.courseId,
      dueLabel: state.draft.dueLabel,
      status: existing?.status ?? PrototypeAssignmentStatus.open,
      url: state.draft.url.trim(),
      memo: state.draft.memo.trim(),
      priority: state.draft.priority,
      history: existing?.history ?? const [],
      previousStatus: existing?.previousStatus,
      previousHistory: existing?.previousHistory,
      originatedFromCourse: state.draft.inheritedCourse,
    );
    state = state.copyWith(
      assignments: editingId == null
          ? [...state.assignments, assignment]
          : [
              for (final item in state.assignments)
                item.id == editingId ? assignment : item,
            ],
      savedMessage: '課題を保存しました。',
      draft: const PrototypeDraft(),
    );
    _revision++;
    return id;
  }

  void discardDraft() {
    state = state.copyWith(draft: const PrototypeDraft(), clearSaved: true);
  }

  void openExternal(PrototypeAssignment assignment) {
    state = state.copyWith(
      externalMessage: assignment.url.isEmpty
          ? '提出先URLは未設定です。'
          : '試作：外部画面は開かず、送信もしません。対象URL：${assignment.url}',
    );
  }

  int recordSubmission(String assignmentId) {
    _revision++;
    state = state.copyWith(
      assignments: [
        for (final assignment in state.assignments)
          if (assignment.id == assignmentId)
            assignment.copyWith(
              status: PrototypeAssignmentStatus.submitted,
              previousStatus: assignment.status,
              previousHistory: assignment.history,
              history: [
                ...assignment.history,
                '2026-09-18 08:30 JST に提出済みを記録',
              ],
            )
          else
            assignment,
      ],
      clearExternal: true,
    );
    return _revision;
  }

  void undoSubmission(String assignmentId) {
    _revision++;
    state = state.copyWith(
      assignments: [
        for (final assignment in state.assignments)
          if (assignment.id == assignmentId)
            assignment.copyWith(
              status:
                  assignment.previousStatus ?? PrototypeAssignmentStatus.open,
              history: [
                ...assignment.history,
                '2026-09-18 08:30 JST に Undo で提出前の状態へ復元',
              ],
              clearPrevious: true,
            )
          else
            assignment,
      ],
    );
  }

  bool undoSubmissionIfCurrent(String assignmentId, int expectedRevision) {
    if (expectedRevision != _revision) return false;
    final assignment =
        state.assignments.where((item) => item.id == assignmentId).firstOrNull;
    if (assignment == null ||
        assignment.status != PrototypeAssignmentStatus.submitted) {
      return false;
    }
    undoSubmission(assignmentId);
    return true;
  }

  PrototypeState _seed({
    required PrototypeExperiment experiment,
    required PrototypeVariant variant,
    required PrototypeFixture fixture,
  }) {
    _revision++;
    final long = fixture == PrototypeFixture.longText;
    final courses = fixture == PrototypeFixture.noCourses ||
            fixture == PrototypeFixture.empty
        ? const <PrototypeCourse>[]
        : [
            PrototypeCourse(
              id: 'course-a',
              title: long ? 'データ構造とアルゴリズム（情報工学部・第1クォーター）' : 'データ構造とアルゴリズム',
              room: 'TEST-A101',
              start: '09:00',
              end: '10:30',
            ),
            PrototypeCourse(
              id: 'course-b',
              title: long ? '地域政策とフィールドワーク（地域連携プロジェクト実習）' : '地域政策とフィールドワーク',
              room: 'TEST-B203',
              start: '13:00',
              end: '14:30',
            ),
          ];
    if (fixture == PrototypeFixture.empty) {
      return PrototypeState(
        experiment: experiment,
        variant: variant,
        fixture: fixture,
        darkMode: _darkMode,
        introAcknowledged: _introAcknowledged,
        courses: courses,
        assignments: const [],
        draft: const PrototypeDraft(),
      );
    }
    final assignments = [
      PrototypeAssignment(
        id: 'due-today',
        title: long ? '地域政策とフィールドワーク最終レポート提出用資料の整理' : '最終レポート提出',
        courseId: courses.isEmpty ? null : courses.last.id,
        dueLabel: '2026/09/18 23:59',
        status: PrototypeAssignmentStatus.open,
        url: 'https://example.invalid/submit',
        originatedFromCourse: courses.isNotEmpty,
      ),
      PrototypeAssignment(
        id: 'overdue',
        title: long ? 'アルゴリズム演習の長い日本語課題名（期限超過）' : '演習シート提出',
        courseId: courses.isEmpty ? null : courses.first.id,
        dueLabel: '2026/09/17 18:00',
        status: PrototypeAssignmentStatus.inProgress,
        originatedFromCourse: courses.isNotEmpty,
      ),
      if (long)
        const PrototypeAssignment(
          id: 'history',
          title: '提出済み履歴：非常に長いタイトルの課題を確認する',
          courseId: 'course-a',
          dueLabel: '2026/09/16 23:59',
          status: PrototypeAssignmentStatus.submitted,
          history: ['2026-09-17 20:10 JST に提出済みを記録'],
          originatedFromCourse: true,
        ),
    ];
    return PrototypeState(
      experiment: experiment,
      variant: variant,
      fixture: fixture,
      darkMode: _darkMode,
      introAcknowledged: _introAcknowledged,
      courses: courses,
      assignments: fixture == PrototypeFixture.noCourses
          ? assignments
              .map((item) =>
                  item.copyWith(courseId: null, originatedFromCourse: false))
              .toList()
          : assignments,
      draft: const PrototypeDraft(),
    );
  }
}

class UiPrototypeApp extends ConsumerWidget {
  const UiPrototypeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(prototypeControllerProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Phase 3 UI Prototype',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: state.darkMode ? ThemeMode.dark : ThemeMode.light,
      routerConfig: _router,
    );
  }
}

final _router = GoRouter(
  initialLocation: '/today',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          _PrototypeShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
            path: '/today', builder: (_, __) => const PrototypeTodayScreen()),
        GoRoute(
          path: '/assignments',
          builder: (_, __) => const PrototypeAssignmentListScreen(),
        ),
        GoRoute(path: '/add', builder: (_, __) => const PrototypeAddScreen()),
        GoRoute(
          path: '/add/confirm',
          builder: (_, __) => const PrototypeAddConfirmScreen(),
        ),
        GoRoute(
          path: '/assignment/:id',
          builder: (_, state) => PrototypeAssignmentDetailScreen(
            assignmentId: state.pathParameters['id']!,
          ),
        ),
      ],
    ),
  ],
);

class _PrototypeShell extends ConsumerStatefulWidget {
  const _PrototypeShell({required this.location, required this.child});

  final Widget child;
  final String location;

  @override
  ConsumerState<_PrototypeShell> createState() => _PrototypeShellState();
}

class _PrototypeShellState extends ConsumerState<_PrototypeShell> {
  bool _introShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(prototypeControllerProvider).introAcknowledged) {
        return;
      }
      _showIntro();
    });
  }

  Future<void> _showIntro() async {
    if (_introShown) return;
    _introShown = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('比較試作を始める')),
            IconButton(
              key: const Key('prototype-intro-close'),
              tooltip: '閉じる',
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        content: const SingleChildScrollView(
          child: Text(
            'これはUI比較のための試作です。表示内容は合成データで、通常アプリのデータベースには保存されません。提出先を開く操作も外部ページを開かず、送信や提出済みの記録を行いません。',
          ),
        ),
        actions: [
          FilledButton(
            key: const Key('prototype-intro-acknowledge'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('始める'),
          ),
        ],
      ),
    );
    if (mounted) {
      ref.read(prototypeControllerProvider.notifier).acknowledgeIntro();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.location == '/today',
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && widget.location != '/today') {
          context.go(_backTarget(widget.location));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: widget.location == '/today'
              ? null
              : IconButton(
                  key: const Key('prototype-back'),
                  tooltip: '戻る',
                  onPressed: () => context.go(_backTarget(widget.location)),
                  icon: const Icon(Icons.arrow_back),
                ),
          title: Text(_routeTitle(widget.location)),
          actions: [
            IconButton(
              key: const Key('prototype-settings'),
              tooltip: '比較設定',
              onPressed: () => _showSettings(context),
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        body: widget.child,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _navIndex,
          onDestinationSelected: (index) {
            context.go(switch (index) {
              0 => '/today',
              1 => '/assignments',
              _ => '/add',
            });
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
            NavigationDestination(
                icon: Icon(Icons.assignment_outlined), label: '課題'),
            NavigationDestination(icon: Icon(Icons.add_task), label: '追加'),
          ],
        ),
      ),
    );
  }

  int get _navIndex {
    if (widget.location == '/assignments' ||
        widget.location.startsWith('/assignment/')) {
      return 1;
    }
    if (widget.location == '/add' || widget.location == '/add/confirm') {
      return 2;
    }
    return 0;
  }

  Future<void> _showSettings(
    BuildContext shellContext,
  ) async {
    await showModalBottomSheet<void>(
      context: shellContext,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _PrototypeSettingsPanel(
        onClose: () => Navigator.of(sheetContext).pop(),
        onChanged: (experiment) {
          Navigator.of(sheetContext).pop();
          _navigateExperiment(shellContext, experiment);
        },
      ),
    );
  }
}

String _routeTitle(String location) {
  if (location == '/today') return '今日';
  if (location == '/assignments') return '課題';
  if (location == '/add') return '課題を追加';
  if (location == '/add/confirm') return '内容の確認';
  if (location.startsWith('/assignment/')) return '課題の詳細';
  return '今日';
}

class _PrototypeSettingsPanel extends ConsumerWidget {
  const _PrototypeSettingsPanel({
    required this.onClose,
    required this.onChanged,
  });

  final VoidCallback onClose;
  final ValueChanged<PrototypeExperiment> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(prototypeControllerProvider);
    final controller = ref.read(prototypeControllerProvider.notifier);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('比較設定',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  key: const Key('prototype-settings-close'),
                  tooltip: '閉じる',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text('条件を変更するとfixtureを初期状態に戻して対象画面へ移動します。'),
            const SizedBox(height: AppSpacing.sm),
            _PrototypeControls(
              state: state,
              controller: controller,
              onExperimentChanged: onChanged,
              onVariantChanged: (_) => onChanged(state.experiment),
              onFixtureChanged: (_) => onChanged(state.experiment),
              onReset: () => onChanged(state.experiment),
            ),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('表示テーマ'),
              subtitle: Text(state.darkMode ? 'ダーク' : 'ライト'),
              trailing: IconButton(
                key: const Key('prototype-theme-toggle'),
                tooltip: 'テーマを切り替え',
                onPressed: controller.toggleDarkMode,
                icon: Icon(state.darkMode ? Icons.light_mode : Icons.dark_mode),
              ),
            ),
            const Text('表示内容は合成データです。固定時計は2026/09/18 08:30 JSTです。'),
          ],
        ),
      ),
    );
  }
}

String _backTarget(String location) {
  if (location == '/add/confirm') return '/add';
  if (location == '/add' || location == '/assignments') return '/today';
  if (location.startsWith('/assignment/')) return '/assignments';
  return '/today';
}

void _recordSubmissionWithUndo(
  BuildContext context,
  PrototypeController controller,
  String assignmentId,
) {
  final messenger = ScaffoldMessenger.of(context);
  final expectedRevision = controller.recordSubmission(assignmentId);
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: const Text('提出済みを記録しました。'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (controller.undoSubmissionIfCurrent(
                assignmentId, expectedRevision)) {
              messenger.clearSnackBars();
              messenger.showSnackBar(
                const SnackBar(content: Text('提出前の状態へ復元しました。履歴に記録しました。')),
              );
            } else {
              messenger.clearSnackBars();
              messenger.showSnackBar(
                const SnackBar(content: Text('この操作は期限切れです。最新の状態を確認してください。')),
              );
            }
          },
        ),
      ),
    );
}

void _restoreSubmissionWithFeedback(
  BuildContext context,
  PrototypeController controller,
  String assignmentId,
) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  controller.undoSubmission(assignmentId);
  messenger.showSnackBar(
    const SnackBar(content: Text('提出前の状態へ復元しました。履歴に記録しました。')),
  );
}

Future<void> _showExternalFeedback(
  BuildContext context,
  PrototypeController controller,
  PrototypeAssignment assignment,
) async {
  controller.openExternal(assignment);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('提出先を確認'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('提出先URL'),
            const SizedBox(height: AppSpacing.xs),
            SelectableText(assignment.url.isEmpty ? '未設定' : assignment.url),
            const SizedBox(height: AppSpacing.md),
            const Text('この試作では外部ページを開きません。送信や提出済みの記録も行いません。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('prototype-external-close'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}

class _PrototypeRouteBack extends StatelessWidget {
  const _PrototypeRouteBack({required this.target, required this.child});

  final String target;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) context.go(target);
        },
        child: child,
      );
}

class _PrototypeControls extends StatelessWidget {
  const _PrototypeControls({
    required this.state,
    required this.controller,
    this.onExperimentChanged,
    this.onVariantChanged,
    this.onFixtureChanged,
    this.onReset,
  });

  final PrototypeState state;
  final PrototypeController controller;
  final ValueChanged<PrototypeExperiment>? onExperimentChanged;
  final ValueChanged<PrototypeVariant>? onVariantChanged;
  final ValueChanged<PrototypeFixture>? onFixtureChanged;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
        child: Column(
          children: [
            DropdownButtonFormField<PrototypeExperiment>(
              isExpanded: true,
              key: const Key('prototype-experiment-selector'),
              initialValue: state.experiment,
              decoration: const InputDecoration(labelText: '比較'),
              items: const [
                DropdownMenuItem(
                    value: PrototypeExperiment.today, child: Text('E1 Today')),
                DropdownMenuItem(
                    value: PrototypeExperiment.add, child: Text('E2 課題追加')),
                DropdownMenuItem(
                    value: PrototypeExperiment.submission,
                    child: Text('E3 提出記録')),
              ],
              onChanged: (value) {
                if (value != null) {
                  controller.setExperiment(value);
                  if (onExperimentChanged != null) {
                    onExperimentChanged!(value);
                  } else {
                    _navigateExperiment(context, value);
                  }
                }
              },
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<PrototypeVariant>(
                    isExpanded: true,
                    key: const Key('prototype-variant-selector'),
                    initialValue: state.variant,
                    decoration: const InputDecoration(labelText: '案'),
                    items: const [
                      DropdownMenuItem(
                          value: PrototypeVariant.a, child: Text('A')),
                      DropdownMenuItem(
                          value: PrototypeVariant.b, child: Text('B')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        controller.setVariant(value);
                        if (onVariantChanged != null) {
                          onVariantChanged!(value);
                        } else {
                          _navigateExperiment(context, state.experiment);
                        }
                      }
                    },
                  ),
                ),
                IconButton(
                  key: const Key('prototype-reset'),
                  tooltip: 'fixtureをリセット',
                  onPressed: () {
                    controller.reset();
                    ScaffoldMessenger.of(context).clearSnackBars();
                    if (onReset != null) {
                      onReset!();
                    } else {
                      _navigateExperiment(context, state.experiment);
                    }
                  },
                  icon: const Icon(Icons.restart_alt),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<PrototypeFixture>(
                  isExpanded: true,
                  key: const Key('prototype-fixture-selector'),
                  initialValue: state.fixture,
                  decoration: const InputDecoration(labelText: 'fixture'),
                  items: const [
                    DropdownMenuItem(
                        value: PrototypeFixture.normal, child: Text('通常日')),
                    DropdownMenuItem(
                        value: PrototypeFixture.noCourses, child: Text('授業なし')),
                    DropdownMenuItem(
                        value: PrototypeFixture.empty, child: Text('空状態')),
                    DropdownMenuItem(
                        value: PrototypeFixture.longText, child: Text('長文・履歴')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      controller.setFixture(value);
                      if (onFixtureChanged != null) {
                        onFixtureChanged!(value);
                      } else {
                        _navigateExperiment(context, state.experiment);
                      }
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xxs),
                  child: Text(
                    '2026/09/18 08:30 JST 固定',
                    key: const Key('prototype-fixed-clock'),
                    style: Theme.of(context).textTheme.labelMedium,
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

void _navigateExperiment(BuildContext context, PrototypeExperiment experiment) {
  ScaffoldMessenger.of(context).clearSnackBars();
  context.go(switch (experiment) {
    PrototypeExperiment.today => '/today',
    PrototypeExperiment.add => '/add',
    PrototypeExperiment.submission => '/assignments',
  });
}

class PrototypeTodayScreen extends ConsumerWidget {
  const PrototypeTodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(prototypeControllerProvider);
    final isTimeline = state.experiment == PrototypeExperiment.today &&
        state.variant == PrototypeVariant.b;
    final due = state.assignments
        .where((a) => _deadlineBucket(a.dueLabel) == _DeadlineBucket.today)
        .toList();
    final overdue = state.assignments
        .where((a) => _deadlineBucket(a.dueLabel) == _DeadlineBucket.overdue)
        .toList();
    return ListView(
      key: const Key('prototype-today-scroll'),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
      children: [
        Text('9月18日（金）', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.xxs),
        const SizedBox(height: AppSpacing.md),
        if (isTimeline) ...[
          _SectionCard(
            key: const Key('prototype-deadline-band'),
            title: '課題の締切',
            icon: Icons.schedule,
            child: Column(
              children: [
                _AssignmentSummaryList(items: due, label: '今日締切'),
                _AssignmentSummaryList(items: overdue, label: '期限超過'),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            key: const Key('prototype-timeline'),
            title: '今日の授業',
            icon: Icons.timeline,
            child: _CourseList(
              courses: state.courses,
              onAddCourse: (course) => _beginCourseAdd(context, ref, course),
            ),
          ),
        ] else ...[
          if (state.courses.isNotEmpty)
            _SectionCard(
              key: const Key('prototype-next-class'),
              title: '次の授業',
              icon: Icons.arrow_forward,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state.courses.first.start,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(state.courses.first.title,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                      '${state.courses.first.end}まで・教室 ${state.courses.first.room}',
                      style: Theme.of(context).textTheme.labelLarge),
                  TextButton.icon(
                    key: const Key('prototype-add-from-next-course'),
                    onPressed: () =>
                        _beginCourseAdd(context, ref, state.courses.first),
                    icon: const Icon(Icons.add),
                    label: const Text('この授業に課題を追加'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            key: const Key('prototype-grouped-deadlines'),
            title: '課題の締切',
            icon: Icons.assignment_outlined,
            child: Column(
              children: [
                _AssignmentSummaryList(items: due, label: '今日締切'),
                _AssignmentSummaryList(items: overdue, label: '期限超過'),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _SectionCard(
            key: const Key('prototype-grouped-courses'),
            title: '今日の授業',
            icon: Icons.school_outlined,
            child: _CourseList(
              courses: state.courses.skip(1).toList(),
              onAddCourse: (course) => _beginCourseAdd(context, ref, course),
            ),
          ),
        ],
        if (state.courses.isEmpty && state.assignments.isEmpty)
          const _EmptyPrototypeState(),
        if (state.courses.isEmpty && state.assignments.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.md),
            child: Text('授業はありません。課題の締切はこのまま確認できます。'),
          ),
      ],
    );
  }
}

class PrototypeAssignmentListScreen extends ConsumerWidget {
  const PrototypeAssignmentListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(prototypeControllerProvider);
    final controller = ref.read(prototypeControllerProvider.notifier);
    final listActions = state.experiment != PrototypeExperiment.submission ||
        state.variant == PrototypeVariant.a;
    return _PrototypeRouteBack(
      target: '/today',
      child: ListView(
        key: const Key('prototype-assignment-list'),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
        children: [
          Text('課題一覧', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.xs),
          const Text('状態の記録と提出先の確認は別操作です。'),
          const SizedBox(height: AppSpacing.md),
          if (state.assignments.isEmpty) const _EmptyPrototypeState(),
          for (var index = 0; index < state.assignments.length; index++) ...[
            if (index > 0) const SizedBox(height: AppSpacing.md),
            _AssignmentCard(
              assignment: state.assignments[index],
              courses: state.courses,
              showListRecordAction: listActions,
              showListExternalAction: true,
              onOpen: () =>
                  context.go('/assignment/${state.assignments[index].id}'),
              onOpenExternal: () => _showExternalFeedback(
                  context, controller, state.assignments[index]),
              onRecord: () => _recordSubmissionWithUndo(
                  context, controller, state.assignments[index].id),
              onUndo: () => _restoreSubmissionWithFeedback(
                  context, controller, state.assignments[index].id),
            ),
          ],
        ],
      ),
    );
  }
}

class PrototypeAssignmentDetailScreen extends ConsumerWidget {
  const PrototypeAssignmentDetailScreen(
      {required this.assignmentId, super.key});

  final String assignmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(prototypeControllerProvider);
    final controller = ref.read(prototypeControllerProvider.notifier);
    final assignment =
        state.assignments.where((a) => a.id == assignmentId).firstOrNull;
    if (assignment == null) return const _EmptyPrototypeState();
    final course =
        state.courses.where((c) => c.id == assignment.courseId).firstOrNull;
    return _PrototypeRouteBack(
      target: '/assignments',
      child: ListView(
        key: const Key('prototype-assignment-detail'),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
        children: [
          Text(assignment.title,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          _DetailRow(label: '科目', value: course?.title ?? '授業なし'),
          _DetailRow(label: '締切', value: assignment.dueLabel ?? '未設定'),
          _DetailRow(
              label: '提出先',
              value: assignment.url.isEmpty ? '未設定' : assignment.url),
          _DetailRow(label: '状態', value: _statusLabel(assignment.status)),
          if (assignment.memo.isNotEmpty)
            _DetailRow(label: 'メモ', value: assignment.memo),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                key: const Key('prototype-open-external'),
                onPressed: () =>
                    _showExternalFeedback(context, controller, assignment),
                icon: const Icon(Icons.open_in_new),
                label: const Text('提出先を開く'),
              ),
              FilledButton.icon(
                key: const Key('prototype-record-submission'),
                onPressed:
                    assignment.status == PrototypeAssignmentStatus.submitted
                        ? null
                        : () => _recordSubmissionWithUndo(
                            context, controller, assignment.id),
                icon: const Icon(Icons.check),
                label: const Text('提出済みを記録'),
              ),
              if (assignment.status == PrototypeAssignmentStatus.submitted)
                OutlinedButton.icon(
                  key: const Key('prototype-undo-submission'),
                  onPressed: () {
                    _restoreSubmissionWithFeedback(
                        context, controller, assignment.id);
                  },
                  icon: const Icon(Icons.undo),
                  label: const Text('未提出へ戻す'),
                ),
              OutlinedButton.icon(
                key: const Key('prototype-edit-assignment'),
                onPressed: () {
                  controller.beginEdit(assignment);
                  context.go('/add');
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('編集'),
              ),
            ],
          ),
          if (assignment.history.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Text('提出履歴', style: Theme.of(context).textTheme.titleMedium),
            for (final item in assignment.history)
              ListTile(leading: const Icon(Icons.history), title: Text(item)),
          ],
        ],
      ),
    );
  }
}

class PrototypeAddScreen extends ConsumerStatefulWidget {
  const PrototypeAddScreen({super.key});

  @override
  ConsumerState<PrototypeAddScreen> createState() => _PrototypeAddScreenState();
}

class _PrototypeAddScreenState extends ConsumerState<PrototypeAddScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _memoController;
  String? _draftFingerprint;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(prototypeControllerProvider).draft;
    _titleController = TextEditingController(text: draft.title);
    _memoController = TextEditingController(text: draft.memo);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(prototypeControllerProvider);
    final controller = ref.read(prototypeControllerProvider.notifier);
    final draft = state.draft;
    final fingerprint =
        '${draft.title}|${draft.url}|${draft.memo}|${draft.editingId}';
    if (_draftFingerprint != fingerprint) {
      _draftFingerprint = fingerprint;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_titleController.text != draft.title) {
          _titleController.value = TextEditingValue(
              text: draft.title,
              selection: TextSelection.collapsed(offset: draft.title.length));
        }
        if (_memoController.text != draft.memo) {
          _memoController.value = TextEditingValue(
              text: draft.memo,
              selection: TextSelection.collapsed(offset: draft.memo.length));
        }
      });
    }
    final isStepB = state.experiment == PrototypeExperiment.add &&
        state.variant == PrototypeVariant.b;
    return _PrototypeRouteBack(
      target: '/today',
      child: ListView(
        key: const Key('prototype-add-form'),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
        children: [
          if (draft.editingId != null) ...[
            Text('課題を編集', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.xs),
          ],
          Text(draft.editingId != null
              ? '既存の締切と提出状態を保ったまま内容を編集できます。'
              : '新規締切は未設定です。締切の選択だけで保存は確定しません。'),
          const SizedBox(height: AppSpacing.md),
          Text('基本情報', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const Key('prototype-title-field'),
            controller: _titleController,
            decoration: InputDecoration(
                labelText: '課題名（必須）',
                errorText:
                    draft.error?.contains('課題名') == true ? draft.error : null),
            onChanged: (value) => controller.updateDraft(title: value),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            key: const Key('prototype-course-field'),
            initialValue: draft.courseId,
            decoration: const InputDecoration(labelText: '科目（任意）'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('授業なし')),
              for (final course in state.courses)
                DropdownMenuItem<String?>(
                  value: course.id,
                  child: Text(
                    course.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => controller.updateDraft(
                courseId: value, clearCourse: value == null),
          ),
          if (draft.courseId != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Text(
                '選択中の科目：${state.courses.where((c) => c.id == draft.courseId).firstOrNull?.title ?? '授業なし'}',
                key: const Key('prototype-selected-course-full'),
              ),
            ),
          if (draft.courseId != null && draft.inheritedCourse)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xxs),
              child: Text('授業起点の科目を引き継いでいます。変更できます。'),
            ),
          const SizedBox(height: AppSpacing.md),
          ListTile(
            key: const Key('prototype-due-field'),
            contentPadding: EdgeInsets.zero,
            title: Text(draft.dueLabel ?? '締切（必須）を選択（未設定）'),
            subtitle: draft.error?.contains('締切') == true
                ? Text(draft.error!)
                : Text(draft.dueLabel == null ? '日付を選ぶまで未設定' : '選択した締切'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final currentDue = _parseDue(draft.dueLabel);
              final date = await showDatePicker(
                context: context,
                firstDate: DateTime(2026, 1),
                lastDate: DateTime(2027, 12),
                initialDate: currentDue ?? DateTime(2026, 9, 18),
                currentDate: DateTime(2026, 9, 18),
              );
              if (!context.mounted) return;
              if (date != null) {
                final time = await showTimePicker(
                  context: context,
                  initialTime: currentDue == null
                      ? const TimeOfDay(hour: 23, minute: 59)
                      : TimeOfDay.fromDateTime(currentDue),
                );
                if (!context.mounted) return;
                if (time != null) {
                  controller.updateDraft(
                    dueLabel:
                        '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                  );
                }
              }
            },
          ),
          if (!isStepB) const SizedBox(height: AppSpacing.md),
          if (!isStepB) ..._optionalFields(context, controller, draft),
          if (isStepB)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: FilledButton(
                key: const Key('prototype-next-confirm'),
                onPressed: () {
                  if (controller.validateDraft()) context.go('/add/confirm');
                },
                child: const Text('確認へ'),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: FilledButton(
                key: const Key('prototype-save-add'),
                onPressed: () {
                  final id = controller.saveDraft();
                  if (id != null) context.go('/assignment/$id');
                },
                child: const Text('保存'),
              ),
            ),
          TextButton(
            key: const Key('prototype-discard-draft'),
            onPressed: () {
              controller.discardDraft();
              context.go('/today');
            },
            child: const Text('入力を破棄して戻る'),
          ),
        ],
      ),
    );
  }

  List<Widget> _optionalFields(BuildContext context,
          PrototypeController controller, PrototypeDraft draft) =>
      [
        const SizedBox(height: AppSpacing.md),
        Text('任意の情報', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          key: const Key('prototype-memo-field'),
          controller: _memoController,
          decoration: const InputDecoration(labelText: 'メモ（任意）'),
          maxLines: 3,
          onChanged: (value) => controller.updateDraft(memo: value),
        ),
        const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<String>(
          isExpanded: true,
          key: const Key('prototype-priority-field'),
          initialValue: draft.priority,
          decoration: const InputDecoration(labelText: '優先度'),
          items: const [
            DropdownMenuItem(value: '通常', child: Text('通常')),
            DropdownMenuItem(value: '高', child: Text('高')),
          ],
          onChanged: (value) {
            if (value != null) controller.updateDraft(priority: value);
          },
        ),
      ];
}

class PrototypeAddConfirmScreen extends ConsumerStatefulWidget {
  const PrototypeAddConfirmScreen({super.key});

  @override
  ConsumerState<PrototypeAddConfirmScreen> createState() =>
      _PrototypeAddConfirmScreenState();
}

class _PrototypeAddConfirmScreenState
    extends ConsumerState<PrototypeAddConfirmScreen> {
  late final TextEditingController _memoController;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(prototypeControllerProvider).draft;
    _memoController = TextEditingController(text: draft.memo);
  }

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final state = ref.watch(prototypeControllerProvider);
    final controller = ref.read(prototypeControllerProvider.notifier);
    final draft = state.draft;
    return _PrototypeRouteBack(
      target: '/add',
      child: ListView(
        key: const Key('prototype-add-confirm'),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
        children: [
          Text('保存前に確認', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          _DetailRow(
              label: '課題名', value: draft.title.isEmpty ? '未入力' : draft.title),
          _DetailRow(
              label: '科目',
              value: state.courses
                      .where((c) => c.id == draft.courseId)
                      .firstOrNull
                      ?.title ??
                  '授業なし'),
          _DetailRow(label: '締切', value: draft.dueLabel ?? '未設定'),
          const SizedBox(height: AppSpacing.sm),
          Text('任意の情報', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: const Key('prototype-confirm-memo-field'),
            controller: _memoController,
            decoration: const InputDecoration(labelText: 'メモ（任意）'),
            maxLines: 3,
            onChanged: (value) => controller.updateDraft(memo: value),
          ),
          const SizedBox(height: AppSpacing.sm),
          DropdownButtonFormField<String>(
            isExpanded: true,
            key: const Key('prototype-confirm-priority-field'),
            initialValue: draft.priority,
            decoration: const InputDecoration(labelText: '優先度'),
            items: const [
              DropdownMenuItem(value: '通常', child: Text('通常')),
              DropdownMenuItem(value: '高', child: Text('高')),
            ],
            onChanged: (value) {
              if (value != null) controller.updateDraft(priority: value);
            },
          ),
          if (state.draft.error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(state.draft.error!,
                  key: const Key('prototype-add-error')),
            ),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            key: const Key('prototype-confirm-save'),
            onPressed: () {
              final id = controller.saveDraft();
              if (id != null) context.go('/assignment/$id');
            },
            child: const Text('この内容で保存'),
          ),
          TextButton(
            key: const Key('prototype-confirm-back'),
            onPressed: () => context.go('/add'),
            child: const Text('入力へ戻る'),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard(
      {required this.title,
      required this.icon,
      required this.child,
      super.key});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: AppSizes.iconMedium),
            const SizedBox(width: AppSpacing.xs),
            Text(title, style: Theme.of(context).textTheme.titleMedium)
          ]),
          const SizedBox(height: AppSpacing.sm),
          child,
        ]),
      ),
    );
  }
}

class _AssignmentSummaryList extends StatelessWidget {
  const _AssignmentSummaryList({required this.items, required this.label});

  final List<PrototypeAssignment> items;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return ListTile(title: Text('$label：なし'));
    return Column(
      children: [
        for (final item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(item.status == PrototypeAssignmentStatus.submitted
                ? Icons.check_circle
                : Icons.assignment_outlined),
            title: Text(item.title),
            subtitle: Text(
                '${_summaryDeadline(item, label)}・${_statusLabel(item.status)}'),
          ),
      ],
    );
  }
}

String _summaryDeadline(PrototypeAssignment item, String bucketLabel) {
  final due = _parseDue(item.dueLabel);
  if (due == null) return '締切未設定';
  final time =
      '${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}';
  final date = '${due.month}/${due.day}';
  if (item.status == PrototypeAssignmentStatus.submitted) {
    return '$date $time';
  }
  if (bucketLabel == '今日締切') return '今日 $time';
  if (bucketLabel == '期限超過') return '期限超過 $date $time';
  return '$date $time';
}

String _assignmentDeadlineLabel(PrototypeAssignment assignment) {
  final bucket = _deadlineBucket(assignment.dueLabel);
  if (assignment.status == PrototypeAssignmentStatus.submitted) {
    return '締切 ${_summaryDeadline(assignment, '締切')}';
  }
  if (bucket == _DeadlineBucket.today) {
    return _summaryDeadline(assignment, '今日締切');
  }
  if (bucket == _DeadlineBucket.overdue) {
    return _summaryDeadline(assignment, '期限超過');
  }
  return '締切 ${_summaryDeadline(assignment, '締切')}';
}

class _CourseList extends StatelessWidget {
  const _CourseList({required this.courses, required this.onAddCourse});

  final List<PrototypeCourse> courses;
  final ValueChanged<PrototypeCourse> onAddCourse;

  @override
  Widget build(BuildContext context) {
    if (courses.isEmpty) return const ListTile(title: Text('今日の授業はありません'));
    return Column(
      children: [
        for (final course in courses)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              width: 64,
              child: Text('${course.start}\n${course.end}',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            title: Text(course.title,
                style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text('教室 ${course.room}',
                style: Theme.of(context).textTheme.labelLarge),
            trailing: IconButton(
              key: Key('prototype-add-from-course-${course.id}'),
              tooltip: 'この授業に課題を追加',
              onPressed: () => onAddCourse(course),
              icon: const Icon(Icons.add_task),
            ),
          ),
      ],
    );
  }
}

void _beginCourseAdd(
  BuildContext context,
  WidgetRef ref,
  PrototypeCourse course,
) {
  ref.read(prototypeControllerProvider.notifier).beginAdd(
        courseId: course.id,
        inheritedCourse: true,
      );
  context.go('/add');
}

class _AssignmentCard extends StatelessWidget {
  const _AssignmentCard({
    required this.assignment,
    required this.courses,
    required this.showListRecordAction,
    required this.showListExternalAction,
    required this.onOpen,
    required this.onOpenExternal,
    required this.onRecord,
    required this.onUndo,
  });

  final PrototypeAssignment assignment;
  final List<PrototypeCourse> courses;
  final bool showListRecordAction;
  final bool showListExternalAction;
  final VoidCallback onOpen;
  final VoidCallback onOpenExternal;
  final VoidCallback onRecord;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final course =
        courses.where((c) => c.id == assignment.courseId).firstOrNull;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: onOpen,
            title: Text(assignment.title,
                style: Theme.of(context).textTheme.titleMedium),
            trailing: Chip(label: Text(_statusLabel(assignment.status))),
          ),
          Text(course?.title ?? '授業なし',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.schedule, size: AppSizes.iconSmall),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  _assignmentDeadlineLabel(assignment),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
            if (showListExternalAction)
              OutlinedButton(
                  onPressed: onOpenExternal, child: const Text('提出先を開く')),
            if (showListRecordAction &&
                assignment.status != PrototypeAssignmentStatus.submitted)
              OutlinedButton(onPressed: onRecord, child: const Text('提出済みを記録')),
            if (assignment.status == PrototypeAssignmentStatus.submitted)
              TextButton(onPressed: onUndo, child: const Text('Undo')),
            TextButton(onPressed: onOpen, child: const Text('詳細')),
          ]),
        ]),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 72,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
        Expanded(child: Text(value)),
      ]),
    );
  }
}

class _EmptyPrototypeState extends StatelessWidget {
  const _EmptyPrototypeState();

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(children: [
            const Icon(Icons.inbox_outlined, size: AppSizes.iconLarge),
            const SizedBox(height: AppSpacing.sm),
            const Text('予定と課題はありません'),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.icon(
              key: const Key('prototype-empty-add'),
              onPressed: () => context.go('/add'),
              icon: const Icon(Icons.add),
              label: const Text('課題を追加'),
            ),
          ]),
        ),
      );
}

String _statusLabel(PrototypeAssignmentStatus status) => switch (status) {
      PrototypeAssignmentStatus.open => '未提出',
      PrototypeAssignmentStatus.inProgress => '進行中',
      PrototypeAssignmentStatus.submitted => '提出済み履歴',
    };
