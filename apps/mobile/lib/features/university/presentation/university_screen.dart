import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config_provider.dart';
import '../../../core/error/app_error.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../../onboarding/application/onboarding_providers.dart';
import '../../onboarding/domain/onboarding_models.dart';
import '../../timetable/application/demo_app_controller.dart';
import '../application/university_settings_providers.dart';
import 'university_request_dialog.dart';

class UniversityScreen extends ConsumerStatefulWidget {
  const UniversityScreen({super.key});

  @override
  ConsumerState<UniversityScreen> createState() => _UniversityScreenState();
}

class _UniversityScreenState extends ConsumerState<UniversityScreen> {
  bool _changingUniversity = false;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appConfigProvider).demoMode) {
      return const MvpScaffold(
        title: '大学設定',
        selectedIndex: 0,
        child: EmptyState(
          icon: Icons.science_outlined,
          title: 'デモモードで実行中です',
          message: '大学の検索・変更・追加申請は Supabase モードで利用できます。',
        ),
      );
    }

    final profileState = ref.watch(onboardingControllerProvider);
    final catalogState = ref.watch(onboardingCatalogProvider);
    return MvpScaffold(
      title: '大学・学期・時限',
      selectedIndex: 0,
      child: switch ((profileState, catalogState)) {
        (AsyncData(value: final profile?), AsyncData(value: final catalog)) =>
          _content(profile, catalog),
        (AsyncError(), _) || (_, AsyncError()) => EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '大学設定を読み込めませんでした',
            message: '通信状態を確認して、もう一度お試しください。',
            action: FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込み'),
            ),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _content(OnboardingProfile profile, OnboardingCatalog catalog) {
    final university = _universityFor(catalog, profile.universityId);
    if (university == null) {
      return EmptyState(
        icon: Icons.school_outlined,
        title: '大学を選択してください',
        message: '全国の登録済み大学から検索して、初期設定を完了してください。',
        action: FilledButton(
          onPressed: () => context.go('/onboarding'),
          child: const Text('初期設定へ'),
        ),
      );
    }
    final campus = _campusFor(catalog, profile.campusId);
    final periodCount =
        ref.watch(demoAppControllerProvider).valueOrNull?.periodSettings.length;
    final requests = ref.watch(universityRequestsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        _retry();
        await Future.wait([
          ref.read(onboardingControllerProvider.future),
          ref.read(onboardingCatalogProvider.future),
          ref.read(universityRequestsProvider.future),
        ]);
      },
      child: ListView(
        key: const Key('university-settings-list'),
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('所属大学', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.school_outlined),
                    title: Text(university.name),
                    subtitle: campus == null ? null : Text(campus.name),
                    trailing: _VerificationBadge(
                      verified: profile.universityVerified,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      key: const Key('change-university-button'),
                      onPressed: _changingUniversity
                          ? null
                          : () => _changeUniversity(
                                profile: profile,
                                catalog: catalog,
                              ),
                      icon: _changingUniversity
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: const Text('全国の大学から変更'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.calendar_view_month_outlined),
                  title: const Text('現在の学期'),
                  subtitle: Text(
                    profile.activeTerm == null
                        ? '未設定'
                        : '${profile.activeTerm!.name} '
                            '(${profile.activeTerm!.academicYear}年度)',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('時限設定'),
                  subtitle: Text(
                    periodCount == null ? '読み込み中' : '$periodCount コマ設定済み',
                  ),
                ),
                ListTile(
                  key: const Key('open-term-period-management'),
                  leading: const Icon(Icons.tune_outlined),
                  title: const Text('学期・時限を管理'),
                  subtitle: const Text('個人学期の追加・切替と時限設定の編集'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/university/term-periods'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '未登録大学の追加申請',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '検索で見つからない大学は、公式情報を添えて申請できます。'
                    '審査状況はこの端末からいつでも確認できます。',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('request-university-button'),
                    onPressed: _requestUniversity,
                    icon: const Icon(Icons.add_business_outlined),
                    label: const Text('大学を追加申請'),
                  ),
                  const SizedBox(height: 12),
                  Text('申請履歴', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  requests.when(
                    data: (items) => items.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('申請履歴はありません'),
                          )
                        : Column(
                            children: [
                              for (final item in items)
                                UniversityRequestTile(request: item),
                            ],
                          ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, __) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.error_outline),
                      title: const Text('申請履歴を取得できませんでした'),
                      trailing: IconButton(
                        tooltip: '再読み込み',
                        onPressed: () => ref.invalidate(
                          universityRequestsProvider,
                        ),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _retry() {
    ref.invalidate(onboardingControllerProvider);
    ref.invalidate(onboardingCatalogProvider);
    ref.invalidate(universityRequestsProvider);
  }

  Future<void> _changeUniversity({
    required OnboardingProfile profile,
    required OnboardingCatalog catalog,
  }) async {
    final selected = await showSearch<UniversityOption?>(
      context: context,
      delegate: _UniversitySearchDelegate(
        universities: catalog.universities,
        currentUniversityId: profile.universityId,
      ),
    );
    if (selected == null || selected.id == profile.universityId || !mounted) {
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('所属大学を変更しますか？'),
            content: Text(
              '${selected.name}へ変更すると、キャンパス・学期・時限を'
              'もう一度設定します。既存の予定は削除されません。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('変更して再設定'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _changingUniversity = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(universitySettingsRepositoryProvider)
          .changeUniversity(selected.id);
      _retry();
      if (!mounted) return;
      context.go('/onboarding');
    } on AppError catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('大学を変更できませんでした')),
      );
    } finally {
      if (mounted) setState(() => _changingUniversity = false);
    }
  }

  Future<void> _requestUniversity() async {
    final requestId = await showUniversityRequestDialog(context);
    if (requestId == null || !mounted) return;
    ref.invalidate(universityRequestsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('大学追加申請を受け付けました')),
    );
  }

  UniversityOption? _universityFor(
    OnboardingCatalog catalog,
    String? universityId,
  ) {
    for (final option in catalog.universities) {
      if (option.id == universityId) return option;
    }
    return null;
  }

  CampusOption? _campusFor(OnboardingCatalog catalog, String? campusId) {
    for (final option in catalog.campuses) {
      if (option.id == campusId) return option;
    }
    return null;
  }
}

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.verified});

  final bool verified;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: verified ? '大学メール認証済み' : '大学メール未認証',
      child: Chip(
        avatar: Icon(
          verified ? Icons.verified : Icons.verified_outlined,
          size: 18,
        ),
        label: Text(verified ? '認証済み' : '未認証'),
      ),
    );
  }
}

class _UniversitySearchDelegate extends SearchDelegate<UniversityOption?> {
  _UniversitySearchDelegate({
    required this.universities,
    required this.currentUniversityId,
  });

  final List<UniversityOption> universities;
  final String? currentUniversityId;

  @override
  String get searchFieldLabel => '大学名を検索';

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            tooltip: '検索語を消去',
            onPressed: () => query = '',
            icon: const Icon(Icons.clear),
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        tooltip: '戻る',
        onPressed: () => close(context, null),
        icon: const Icon(Icons.arrow_back),
      );

  @override
  Widget buildResults(BuildContext context) => _results();

  @override
  Widget buildSuggestions(BuildContext context) => _results();

  Widget _results() {
    final normalizedQuery = query.trim().toLowerCase();
    final matches = universities
        .where(
          (option) =>
              normalizedQuery.isEmpty ||
              option.name.toLowerCase().contains(normalizedQuery),
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off_outlined,
        title: '該当する大学がありません',
        message: '大学設定画面へ戻り、未登録大学の追加申請を利用してください。',
      );
    }
    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final option = matches[index];
        final current = option.id == currentUniversityId;
        return ListTile(
          leading: const Icon(Icons.school_outlined),
          title: Text(option.name),
          trailing: current ? const Text('現在') : null,
          enabled: !current,
          onTap: current ? null : () => close(context, option),
        );
      },
    );
  }
}
