import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_tokens.dart';

/// A composition-root supplied banner for the ordinary signed-in scaffold.
///
/// Keeping this scope provider-agnostic lets individual feature screen tests
/// use [MvpScaffold] without bootstrapping application-wide dependencies.
class MvpScaffoldBannerScope extends InheritedWidget {
  const MvpScaffoldBannerScope({
    required this.banner,
    required super.child,
    super.key,
  });

  final Widget? banner;

  static Widget? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MvpScaffoldBannerScope>()
        ?.banner;
  }

  @override
  bool updateShouldNotify(MvpScaffoldBannerScope oldWidget) {
    return !identical(banner, oldWidget.banner);
  }
}

class MvpScaffold extends StatelessWidget {
  const MvpScaffold({
    required this.title,
    required this.selectedIndex,
    required this.child,
    this.actions = const [],
    this.onBeforeNavigate,
    this.showQuickAdd = true,
    super.key,
  });

  final String title;
  final int selectedIndex;
  final Widget child;
  final List<Widget> actions;
  final Future<bool> Function()? onBeforeNavigate;
  final bool showQuickAdd;

  @override
  Widget build(BuildContext context) {
    final banner = MvpScaffoldBannerScope.maybeOf(context);
    final size = MediaQuery.sizeOf(context);
    final showRail = size.width >= AppBreakpoints.tablet && size.height >= 480;
    final content = banner == null
        ? child
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [banner, Expanded(child: child)],
          );
    final destinations = const [
      NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'ホーム'),
      NavigationDestination(
          icon: Icon(Icons.table_chart_outlined),
          selectedIcon: Icon(Icons.table_chart),
          label: '時間割'),
      NavigationDestination(
          icon: Icon(Icons.assignment_outlined),
          selectedIcon: Icon(Icons.assignment),
          label: '課題・テスト'),
      NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: 'カレンダー'),
      NavigationDestination(
          icon: Icon(Icons.groups_outlined),
          selectedIcon: Icon(Icons.groups),
          label: '共有'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          ...actions,
          IconButton(
            tooltip: '設定',
            onPressed: () => _navigate(context, '/settings'),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: showRail
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: selectedIndex,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -1,
                    onDestinationSelected: (index) =>
                        _navigateToDestination(context, index),
                    destinations: [
                      for (final destination in destinations)
                        NavigationRailDestination(
                          icon: destination.icon,
                          selectedIcon: destination.selectedIcon,
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      floatingActionButton: showQuickAdd
          ? FloatingActionButton(
              tooltip: '追加',
              onPressed: () => _showQuickAdd(context),
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: showRail
          ? null
          : NavigationBar(
              height: _navigationBarHeight(context),
              selectedIndex: selectedIndex,
              destinations: destinations,
              onDestinationSelected: (index) =>
                  _navigateToDestination(context, index),
            ),
    );
  }

  Future<void> _navigateToDestination(
          BuildContext context, int index) =>
      _navigate(
          context,
          const [
            '/',
            '/timetable',
            '/assignments',
            '/calendar',
            '/shared'
          ][index]);

  double _navigationBarHeight(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final scaledLabelHeight = mediaQuery.textScaler.scale(12);
    final hasNarrowDestination = mediaQuery.size.width < 360;
    final needsWrappedLabelRoom = scaledLabelHeight > 16;
    if (hasNarrowDestination || needsWrappedLabelRoom) return 88;
    return 72;
  }

  Future<void> _showQuickAdd(BuildContext pageContext) async {
    final location = await showModalBottomSheet<String>(
      context: pageContext,
      showDragHandle: true,
      isScrollControlled: true,
      sheetAnimationStyle: MediaQuery.disableAnimationsOf(pageContext)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(
              duration: AppMotion.standard,
              reverseDuration: AppMotion.quick,
            ),
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: const Text('資料から予定を見つける'),
                subtitle: const Text('課題・試験候補を確認して一括登録'),
                onTap: () => Navigator.of(sheetContext).pop('/document-import'),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: const Text('授業を追加'),
                onTap: () => Navigator.of(sheetContext).pop('/courses/manual'),
              ),
              ListTile(
                leading: const Icon(Icons.assignment_outlined),
                title: const Text('課題を追加'),
                onTap: () => Navigator.of(sheetContext).pop('/assignments/new'),
              ),
              ListTile(
                leading: const Icon(Icons.quiz_outlined),
                title: const Text('テストを追加'),
                onTap: () => Navigator.of(sheetContext).pop('/exams/new'),
              ),
              ListTile(
                leading: const Icon(Icons.event_outlined),
                title: const Text('予定を追加'),
                onTap: () => Navigator.of(sheetContext).pop('/events/new'),
              ),
              ListTile(
                leading: const Icon(Icons.repeat_outlined),
                title: const Text('ルーティンを追加'),
                onTap: () => Navigator.of(sheetContext).pop('/routines/new'),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('グループイベントを追加'),
                onTap: () => Navigator.of(sheetContext).pop('/shared'),
              ),
            ],
          ),
        );
      },
    );
    if (location != null && pageContext.mounted) {
      await _navigate(pageContext, location);
    }
  }

  Future<void> _navigate(BuildContext context, String location) async {
    if (onBeforeNavigate != null && !await onBeforeNavigate!()) return;
    if (context.mounted) context.go(location);
  }
}
