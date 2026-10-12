import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_domain/shared_domain.dart';

import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/mvp_scaffold.dart';
import '../application/availability_controller.dart';
import '../domain/availability_models.dart';

class AvailabilityScreen extends ConsumerStatefulWidget {
  const AvailabilityScreen({super.key});

  @override
  ConsumerState<AvailabilityScreen> createState() => _AvailabilityScreenState();
}

class _AvailabilityScreenState extends ConsumerState<AvailabilityScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(availabilityControllerProvider.notifier).onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(availabilityControllerProvider);
    return asyncState.when(
      loading: () => const MvpScaffold(
        title: '空きコマ検索',
        selectedIndex: 4,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => MvpScaffold(
        title: '空きコマ検索',
        selectedIndex: 4,
        child: _FatalError(message: '$error'),
      ),
      data: (state) => MvpScaffold(
        title: '空きコマ検索',
        selectedIndex: 4,
        child: _AvailabilityContent(state: state),
      ),
    );
  }
}

class _AvailabilityContent extends ConsumerWidget {
  const _AvailabilityContent({required this.state});

  final AvailabilityState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(availabilityControllerProvider.notifier);
    final noFriends = state.friends.isEmpty &&
        state.status != AvailabilityStatus.loadingFriends &&
        state.errorKind == AvailabilityErrorKind.none;
    return ListView(
      key: const Key('availability-content'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '参加者の予定が重ならない時間を、JSTで検索します。自分は常に含まれます。',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          '共有スケジュールを使って算出します。自分の非公開予定は時間だけを埋まりとして扱い、他の参加者の非公開予定は結果に含めません。',
        ),
        const SizedBox(height: 16),
        _ConditionCard(state: state, controller: controller),
        const SizedBox(height: 16),
        Text('参加者', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              const CheckboxListTile(
                value: true,
                onChanged: null,
                secondary: Icon(Icons.person),
                title: Text('自分'),
                subtitle: Text('必ず検索に含まれます'),
              ),
              if (noFriends)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: EmptyState(
                    icon: Icons.people_outline,
                    title: '選択できる友だちがいません',
                    message: '承認済みの友だちを追加すると、一緒に空き時間を探せます。',
                    action: OutlinedButton(
                      onPressed: () => context.go('/shared'),
                      child: const Text('友だちを追加'),
                    ),
                  ),
                )
              else
                for (final friend in state.acceptedFriends)
                  CheckboxListTile(
                    key: Key('availability-friend-${friend.otherUserId}'),
                    value: state.selectedFriendIds.contains(friend.otherUserId),
                    onChanged: state.isLoading
                        ? null
                        : (_) => controller.toggleFriend(friend.otherUserId),
                    secondary: const Icon(Icons.person_outline),
                    title: Text(friend.otherDisplayName),
                    subtitle: const Text('承認済み'),
                  ),
            ],
          ),
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 12),
          _AvailabilityError(state: state, controller: controller),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('availability-search'),
          onPressed: state.isLoading || noFriends ? null : controller.search,
          icon: state.status == AvailabilityStatus.searching
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: Text(
            state.status == AvailabilityStatus.searching ? '検索中…' : '空き時間を検索',
          ),
        ),
        const SizedBox(height: 20),
        if (state.status == AvailabilityStatus.noCandidates)
          const EmptyState(
            icon: Icons.event_busy_outlined,
            title: '条件に合う時間がありません',
            message: '時間帯を広げるか、最小時間を短くして再検索してください。',
          )
        else if (state.status == AvailabilityStatus.success)
          _ResultsList(windows: state.windows),
      ],
    );
  }
}

class _ConditionCard extends StatelessWidget {
  const _ConditionCard({required this.state, required this.controller});

  final AvailabilityState state;
  final AvailabilityController controller;

  @override
  Widget build(BuildContext context) {
    final timeOptions = _timeOptions();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('検索条件', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              key: const Key('availability-date'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined),
              title: const Text('日付（日本時間）'),
              subtitle: Text(_dateLabel(state.selectedDate)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                  initialDate: DateTime(
                    state.selectedDate.year,
                    state.selectedDate.month,
                    state.selectedDate.day,
                  ),
                );
                if (picked != null) controller.setDate(picked);
              },
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const Key('availability-start'),
                    initialValue: state.startMinutes,
                    decoration: const InputDecoration(labelText: '開始'),
                    items: [
                      for (final value in timeOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_timeLabel(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) controller.setStartMinutes(value);
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('〜'),
                ),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: const Key('availability-end'),
                    initialValue: state.endMinutes,
                    decoration: const InputDecoration(labelText: '終了'),
                    items: [
                      for (final value in timeOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(_timeLabel(value)),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) controller.setEndMinutes(value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('availability-minimum-duration'),
              initialValue: state.minimumDurationMinutes,
              decoration: const InputDecoration(labelText: '最小時間'),
              items: [15, 30, 45, 60, 90, 120]
                  .map(
                    (value) => DropdownMenuItem(
                      value: value,
                      child: Text('$value分'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) controller.setMinimumDurationMinutes(value);
              },
            ),
            if (!state.hasValidRange) ...[
              const SizedBox(height: 8),
              Text(
                '開始時刻は終了時刻より前にしてください。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<int> _timeOptions() =>
      [for (var value = 0; value <= 24 * 60; value += 30) value];

  String _dateLabel(DateTime value) =>
      '${value.year}/${value.month}/${value.day}（${_weekday(value.weekday)}）';

  String _timeLabel(int value) {
    if (value == 24 * 60) return '24:00';
    return '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  }

  String _weekday(int value) => const {
        DateTime.monday: '月',
        DateTime.tuesday: '火',
        DateTime.wednesday: '水',
        DateTime.thursday: '木',
        DateTime.friday: '金',
        DateTime.saturday: '土',
        DateTime.sunday: '日',
      }[value]!;
}

class _AvailabilityError extends StatelessWidget {
  const _AvailabilityError({required this.state, required this.controller});

  final AvailabilityState state;
  final AvailabilityController controller;

  @override
  Widget build(BuildContext context) {
    final isAuthorization =
        state.errorKind == AvailabilityErrorKind.authorization;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline),
                const SizedBox(width: 8),
                Expanded(child: Text(state.errorMessage!)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: controller.retry,
                  child: const Text('再試行'),
                ),
                if (isAuthorization)
                  OutlinedButton(
                    onPressed: () => controller.setSelectedFriends(const []),
                    child: const Text('参加者を選び直す'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.windows});

  final List<TimeWindow> windows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('候補時間', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final window in windows)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text('${_time(window.startAt)} 〜 ${_time(window.endAt)}'),
              subtitle: Text('利用可能 ${_duration(window.duration)}'),
            ),
          ),
      ],
    );
  }

  String _time(DateTime value) =>
      '${JapanTime.civil(value).hour.toString().padLeft(2, '0')}:${JapanTime.civil(value).minute.toString().padLeft(2, '0')}';

  String _duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    if (hours == 0) return '$minutes分';
    if (minutes == 0) return '$hours時間';
    return '$hours時間$minutes分';
  }
}

class _FatalError extends StatelessWidget {
  const _FatalError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: '空きコマ検索を読み込めません',
      message: message,
    );
  }
}
