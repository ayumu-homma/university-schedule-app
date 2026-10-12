export const adminSections = [
  {
    title: '大学申請',
    table: 'university_requests',
    description: '大学追加申請の承認、却下、統合。',
  },
  {
    title: '授業テンプレ通報',
    table: 'course_template_reports',
    description: '不正確・不適切な授業テンプレの確認。',
  },
  {
    title: '重複候補',
    table: 'course_template_duplicate_candidates',
    description: '同大学内の重複テンプレ比較と統合判断。',
  },
  {
    title: '修正提案',
    table: 'course_template_edit_proposals',
    description: '授業テンプレのユーザー提案レビュー。',
  },
  {
    title: 'ユーザー/グループ通報',
    table: 'reports',
    description: 'UGC 通報、ブロック、非表示、警告対応。',
  },
  {
    title: '監査ログ',
    table: 'audit_logs',
    description: '管理操作と重要イベントの追跡。',
  },
];
