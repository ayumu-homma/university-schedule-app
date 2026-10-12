import 'package:flutter/material.dart';
import 'package:shared_domain/shared_domain.dart';

import '../domain/email_timezone.dart';

String emailConnectionStatusLabel(EmailConnectionStatus status) =>
    switch (status) {
      EmailConnectionStatus.disconnected => '未接続',
      EmailConnectionStatus.connecting => '接続中',
      EmailConnectionStatus.connected => '接続済み',
      EmailConnectionStatus.reauthRequired => '再認証が必要',
      EmailConnectionStatus.rateLimited => 'しばらく待って再試行',
      EmailConnectionStatus.failed => '接続エラー',
      EmailConnectionStatus.disconnecting => '切断中',
    };

String emailReviewStateLabel(EmailCandidateReviewState state) =>
    switch (state) {
      EmailCandidateReviewState.needsReview => '要確認',
      EmailCandidateReviewState.readyForReview => '確認できます',
      EmailCandidateReviewState.updateAvailable => '更新候補',
      EmailCandidateReviewState.confirmed => '追加済み',
      EmailCandidateReviewState.dismissed => '除外済み',
      EmailCandidateReviewState.failed => '処理に失敗',
    };

String emailCandidateTypeLabel(EmailCandidateType type) => switch (type) {
      EmailCandidateType.assignment => '課題',
      EmailCandidateType.exam => 'テスト',
      EmailCandidateType.event => '予定',
      EmailCandidateType.announcement => 'お知らせ',
      EmailCandidateType.unknown => '未分類',
    };

IconData emailCandidateTypeIcon(EmailCandidateType? type) => switch (type) {
      EmailCandidateType.assignment => Icons.assignment_outlined,
      EmailCandidateType.exam => Icons.quiz_outlined,
      EmailCandidateType.event => Icons.event_outlined,
      EmailCandidateType.announcement => Icons.campaign_outlined,
      EmailCandidateType.unknown || null => Icons.help_outline,
    };

String emailErrorMessage(EmailErrorCategory? category) => switch (category) {
      EmailErrorCategory.authorizationRevoked => 'Gmail の認証が切れています。再接続してください。',
      EmailErrorCategory.cursorExpired => '同期位置を更新して、もう一度取得してください。',
      EmailErrorCategory.rateLimited => '取得回数の上限に達しました。時間をおいて再試行してください。',
      EmailErrorCategory.timeout => '通信が時間内に完了しませんでした。もう一度お試しください。',
      EmailErrorCategory.networkUnavailable => 'ネットワークに接続してから再試行してください。',
      EmailErrorCategory.providerUnavailable =>
        'Gmail に接続できませんでした。時間をおいてお試しください。',
      EmailErrorCategory.configurationMissing => 'メール取込の準備が完了していません。',
      EmailErrorCategory.malformedContent => 'このメールは安全に読み取れませんでした。',
      EmailErrorCategory.oversizedContent => 'このメールは取込可能なサイズを超えています。',
      EmailErrorCategory.unsafeContent => '安全に処理できない内容が含まれていました。',
      EmailErrorCategory.invalidExtraction => '候補を作成できませんでした。',
      EmailErrorCategory.unsupportedSchema => 'この候補の形式には対応していません。',
      EmailErrorCategory.unsafeUrl => '安全でない URL が含まれていました。',
      EmailErrorCategory.validationFailed => '入力内容を確認してください。',
      EmailErrorCategory.internalError || null => '処理を完了できませんでした。もう一度お試しください。',
    };

String emailActionFailureMessage({
  required EmailConnectionStatus? connectionStatus,
  required EmailErrorCategory? errorCategory,
}) {
  return switch (connectionStatus) {
    EmailConnectionStatus.reauthRequired => 'Gmail の認証が切れています。再接続してください。',
    EmailConnectionStatus.rateLimited => '取得回数の上限に達しました。時間をおいて再試行してください。',
    EmailConnectionStatus.disconnected => 'Gmail は接続されていません。',
    EmailConnectionStatus.connecting => 'Gmail への接続が完了しませんでした。',
    EmailConnectionStatus.disconnecting => 'Gmail の接続解除が完了しませんでした。',
    EmailConnectionStatus.failed => emailErrorMessage(errorCategory),
    EmailConnectionStatus.connected || null => emailErrorMessage(errorCategory),
  };
}

String emailWarningLabel(String warning) => switch (warning) {
      'ambiguous_date' => '日付または時刻を確認してください',
      'ambiguous_year' => '年を確認してください',
      'ambiguous_time' => '時刻を確認してください',
      'ambiguous_course' => '授業を確認してください',
      'missing_title' => 'タイトルを入力してください',
      'missing_date_time' => '日時を入力してください',
      'relative_date' => '相対的な日付の解釈を確認してください',
      'low_confidence' => '抽出精度が低いため、すべての項目を確認してください',
      'untrusted_instruction_ignored' => 'メール内の指示文は無視しました',
      _ => '抽出結果を確認してください',
    };

String emailEvidenceFieldLabel(String field) => switch (field) {
      'title' => 'タイトル',
      'course_hint.name' => '授業名',
      'course_hint.code' => '授業コード',
      'due.at' => '締切',
      'due.raw_text' => '締切表記',
      'start_at' => '開始日時',
      'end_at' => '終了日時',
      'location' => '場所',
      'submission_url' => '提出先 URL',
      'summary' => '概要',
      _ => '候補情報',
    };

String formatEmailDateTime(
  DateTime? value, {
  String timeZone = JapanTime.timeZone,
}) {
  if (value == null) return '未設定';
  final civil = emailDateTimeInTimezone(value, timeZone);
  String two(int number) => number.toString().padLeft(2, '0');
  return '${civil.year}/${two(civil.month)}/${two(civil.day)} '
      '${two(civil.hour)}:${two(civil.minute)}';
}

String formatEmailInputDateTime(
  DateTime? value, {
  String timeZone = JapanTime.timeZone,
}) {
  if (value == null) return '';
  final civil = emailDateTimeInTimezone(value, timeZone);
  String two(int number) => number.toString().padLeft(2, '0');
  return '${civil.year}-${two(civil.month)}-${two(civil.day)} '
      '${two(civil.hour)}:${two(civil.minute)}';
}
