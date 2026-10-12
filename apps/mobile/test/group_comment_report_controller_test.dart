import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:university_schedule_mobile/features/auth/application/auth_providers.dart';
import 'package:university_schedule_mobile/features/auth/domain/auth_models.dart';
import 'package:university_schedule_mobile/features/groups/application/group_providers.dart';
import 'package:university_schedule_mobile/features/groups/data/supabase_group_repository.dart';
import 'package:university_schedule_mobile/features/groups/domain/group_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('report failure is generic and emits no app-side Dart logs', () async {
    const reporterId = 'synthetic-reporter-id';
    const commentId = 'synthetic-comment-id';
    const reason = 'synthetic-report-reason';
    final repository = _FailingReportRepository(
      errorDetails: '$reporterId | $commentId | $reason',
    );
    final container = ProviderContainer(overrides: [
      currentAuthSessionProvider.overrideWithValue(
        const AppAuthSession(userId: reporterId),
      ),
      groupRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(groupsControllerProvider.future);

    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    late final bool succeeded;
    try {
      succeeded = await runZoned(
        () => container.read(groupsControllerProvider.notifier).reportContent(
              targetType: 'comment',
              targetId: commentId,
              reason: reason,
            ),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => logs.add(line),
        ),
      );
    } finally {
      debugPrint = originalDebugPrint;
    }

    expect(succeeded, isFalse);
    expect(repository.receivedCommentId, commentId);
    expect(repository.receivedReason, reason);
    expect(logs, isEmpty);
    final state = container.read(groupsControllerProvider).requireValue;
    expect(state.errorMessage, 'グループ操作に失敗しました。通信と権限を確認してください。');
    expect(state.errorMessage, isNot(contains(reporterId)));
    expect(state.errorMessage, isNot(contains(commentId)));
    expect(state.errorMessage, isNot(contains(reason)));
    expect(state.errorMessage, isNot(contains(repository.errorDetails)));
  });
}

class _FailingReportRepository extends UnavailableGroupRepository {
  _FailingReportRepository({required this.errorDetails});

  final String errorDetails;
  String? receivedCommentId;
  String? receivedReason;

  @override
  Future<List<GroupSummary>> listGroups() async => [];

  @override
  Future<void> reportGroupContent({
    required String targetType,
    required String targetId,
    required String reason,
  }) async {
    receivedCommentId = targetId;
    receivedReason = reason;
    throw StateError(errorDetails);
  }
}
