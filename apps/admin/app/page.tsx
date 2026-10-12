'use client';

import { FormEvent, useCallback, useEffect, useRef, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';

type Report = { report_id: string; target_type: string; target_id: string; reason: string; status: string; created_at: string; reporter_user_id: string; reporter_display_name: string; target_state: string | null };
type Detail = Report & { decision_reason: string | null; resolved_by: string | null; resolved_at: string | null; target_context: Record<string, unknown> | null };
type Audit = { audit_id: string; actor_user_id: string; action: string; target_type: string; target_id: string; metadata: Record<string, unknown>; created_at: string };
type UniversityRequest = { request_id: string; name: string; prefecture: string | null; official_url: string | null; status: string; created_at: string; version: number; decision_reason: string | null; merged_into_university_id: string | null; approved_university_id: string | null };
type Proposal = { proposal_id: string; template_id: string; proposed_by: string; proposed_payload: Record<string, unknown>; status: string; expected_template_version: number; version: number; created_at: string; decision_reason: string | null };
type ProposalChange = { proposal_id: string; before_payload: Record<string, unknown> | null; proposed_payload: Record<string, unknown>; expected_template_version: number; current_template_version: number; current_payload: Record<string, unknown>; snapshot_available: boolean };
type TemplateReport = { report_id: string; template_id: string; reason: string; status: string; reported_by: string; created_at: string; version: number; decision_reason: string | null };
type University = { university_id: string; name: string; normalized_name: string; aliases: string[]; prefecture: string | null; status: string; version: number; created_at: string };
type DuplicateCandidate = { candidate_id: string; university_id: string; template_a_id: string; template_b_id: string; score: number; status: string; version: number; created_at: string; template_a_title: string | null; template_b_title: string | null; template_a_version: number | null; template_b_version: number | null };
type SuspendedTarget = { target_type: 'user' | 'group'; target_id: string; display_name: string; reason: string; version: number; changed_at: string };
type RequestContext = { principal: string; epoch: number };
type AdminIntent =
  | { kind: 'report'; action: 'dismiss' | 'hide' | 'warn_user' | 'suspend_user' | 'suspend_group'; report: Detail; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'university-request'; action: 'approve' | 'reject' | 'merge'; request: UniversityRequest; targetId: string; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'proposal'; action: 'approve' | 'reject'; proposal: Proposal; change: ProposalChange; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'template-report'; action: 'dismiss' | 'hide'; report: TemplateReport; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'university-update'; university: University; name: string; status: string; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'template-merge'; candidate: DuplicateCandidate; direction: 'a-to-b' | 'b-to-a'; reason: string; ctx: RequestContext; operationId: string }
  | { kind: 'safety-restore'; target: SuspendedTarget; reason: string; ctx: RequestContext; operationId: string };
const PAGE_SIZE = 50;
const operationId = () => crypto.randomUUID();
const templateFieldLabels: Record<string, string> = {
  title: '授業名', instructor_name: '教員名', day_of_week: '曜日', period_no: '時限',
  room: '教室', credit_count: '単位数', syllabus_url: 'シラバスURL',
  external_course_code: '科目コード',
};
const displayTemplateValue = (value: unknown) => value === null ? '未設定' : value === undefined ? '—' : typeof value === 'string' ? value : JSON.stringify(value);

export default function Page() {
  const [user, setUser] = useState<User | null>(null); const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [reports, setReports] = useState<Report[]>([]); const [selected, setSelected] = useState<Detail | null>(null); const [audits, setAudits] = useState<Audit[]>([]);
  const [suspendedTargets, setSuspendedTargets] = useState<SuspendedTarget[]>([]);
  const [universityRequests, setUniversityRequests] = useState<UniversityRequest[]>([]); const [universities, setUniversities] = useState<University[]>([]); const [proposals, setProposals] = useState<Proposal[]>([]); const [templateReports, setTemplateReports] = useState<TemplateReport[]>([]); const [duplicates, setDuplicates] = useState<DuplicateCandidate[]>([]);
  const [phasePages, setPhasePages] = useState({ requests: 0, catalog: 0, proposals: 0, templateReports: 0, duplicates: 0 }); const [phaseMore, setPhaseMore] = useState({ requests: false, catalog: false, proposals: false, templateReports: false, duplicates: false }); const [phaseLoading, setPhaseLoading] = useState(false);
  const [targetUniversities, setTargetUniversities] = useState<University[]>([]); const [targetQuery, setTargetQuery] = useState(''); const [targetPage, setTargetPage] = useState(0); const [targetHasMore, setTargetHasMore] = useState(false); const [targetLoading, setTargetLoading] = useState(false);
  const [page, setPage] = useState(0); const [hasMore, setHasMore] = useState(false); const [loading, setLoading] = useState(false); const [error, setError] = useState<string | null>(null);
  const [intent, setIntent] = useState<AdminIntent | null>(null); const [mutating, setMutating] = useState(false);
  const principalRef = useRef<string | null>(null); const epochRef = useRef(0);
  const authEventSeenRef = useRef(false);
  const dialogRef = useRef<HTMLDivElement>(null); const returnFocusRef = useRef<HTMLElement | null>(null);
  const mutationSequenceRef = useRef(0); const mutationLockRef = useRef(false); const mutatingRef = useRef(false);
  const detailRequestRef = useRef(0); const reportPageRef = useRef(0); const targetRequestRef = useRef(0); const phasePagesRef = useRef(phasePages); const authorizationCheckRef = useRef(0);

  const clearProtected = useCallback(() => { epochRef.current += 1; principalRef.current = null; detailRequestRef.current += 1; targetRequestRef.current += 1; reportPageRef.current = 0; phasePagesRef.current = { requests: 0, catalog: 0, proposals: 0, templateReports: 0, duplicates: 0 }; setUser(null); setPassword(''); setReports([]); setSelected(null); setAudits([]); setSuspendedTargets([]); setUniversityRequests([]); setUniversities([]); setProposals([]); setTemplateReports([]); setDuplicates([]); setTargetUniversities([]); setPhasePages(phasePagesRef.current); setPhaseMore({ requests: false, catalog: false, proposals: false, templateReports: false, duplicates: false }); setTargetQuery(''); setTargetPage(0); setTargetHasMore(false); setTargetLoading(false); setIntent(null); mutationSequenceRef.current += 1; mutationLockRef.current = false; mutatingRef.current = false; setMutating(false); setPhaseLoading(false); setPage(0); setHasMore(false); setLoading(false); setError(null); }, []);
  const acceptSessionUser = useCallback((next: User | null) => {
    if (principalRef.current !== next?.id) { epochRef.current += 1; principalRef.current = next?.id ?? null; detailRequestRef.current += 1; targetRequestRef.current += 1; reportPageRef.current = 0; phasePagesRef.current = { requests: 0, catalog: 0, proposals: 0, templateReports: 0, duplicates: 0 }; setPassword(''); setReports([]); setSelected(null); setAudits([]); setSuspendedTargets([]); setUniversityRequests([]); setUniversities([]); setProposals([]); setTemplateReports([]); setDuplicates([]); setTargetUniversities([]); setPhasePages(phasePagesRef.current); setPhaseMore({ requests: false, catalog: false, proposals: false, templateReports: false, duplicates: false }); setTargetQuery(''); setTargetPage(0); setTargetHasMore(false); setTargetLoading(false); setIntent(null); mutationSequenceRef.current += 1; mutationLockRef.current = false; mutatingRef.current = false; setMutating(false); setPhaseLoading(false); setPage(0); setHasMore(false); }
    setUser(next);
  }, []);
  const context = useCallback((): RequestContext | null => principalRef.current ? { principal: principalRef.current, epoch: epochRef.current } : null, []);
  const current = useCallback((ctx: RequestContext) => principalRef.current === ctx.principal && epochRef.current === ctx.epoch, []);
  const denyAdminSession = useCallback((ctx: RequestContext) => {
    if (!current(ctx)) return;
    clearProtected();
    setError('管理者権限がありません。登録された global admin アカウントでログインしてください。');
    void supabase.auth.signOut({ scope: 'local' });
  }, [clearProtected, current]);
  const authzFailure = useCallback(async (ctx: RequestContext) => {
    if (!current(ctx)) return;
    const checkId = ++authorizationCheckRef.current;
    const { error: checkError } = await supabase.rpc('admin_list_pending_reports', { p_limit: 1, p_offset: 0 });
    if (!current(ctx) || checkId !== authorizationCheckRef.current) return;
    if (checkError?.code === '42501') { denyAdminSession(ctx); return; }
    if (checkError) { setError('管理権限を確認できませんでした。接続を確認して再試行してください。'); return; }
    setError('対象が見つからないか、現在の状態では操作できません。更新して確認してください。');
  }, [current, denyAdminSession]);
  const closeIntent = useCallback(() => { targetRequestRef.current += 1; setTargetLoading(false); setIntent(null); }, []);

  const loadReports = useCallback(async (pageNumber: number) => {
    const ctx = context(); if (!ctx) return;
    if (reportPageRef.current !== pageNumber) { reportPageRef.current = pageNumber; detailRequestRef.current += 1; setSelected(null); closeIntent(); }
    setLoading(true); setError(null);
    const { data, error: rpcError } = await supabase.rpc('admin_list_pending_reports', { p_limit: PAGE_SIZE, p_offset: pageNumber * PAGE_SIZE });
    if (!current(ctx)) return;
    if (rpcError) { if (rpcError.code === '42501') authzFailure(ctx); else setError(rpcError.message); setLoading(false); return; }
    setReports((data ?? []) as Report[]); setPage(pageNumber); setHasMore((data ?? []).length === PAGE_SIZE); setLoading(false);
  }, [authzFailure, closeIntent, context, current]);
  const loadAudits = useCallback(async () => {
    const ctx = context(); if (!ctx) return;
    const { data, error: rpcError } = await supabase.rpc('admin_list_audit_logs', { p_limit: PAGE_SIZE, p_offset: 0 });
    if (!current(ctx)) return;
    if (rpcError) { if (rpcError.code === '42501') authzFailure(ctx); else setError(rpcError.message); return; }
    setAudits((data ?? []) as Audit[]);
  }, [authzFailure, context, current]);
  const loadSuspendedTargets = useCallback(async () => {
    const ctx = context(); if (!ctx) return;
    const [users, groups] = await Promise.all([
      supabase.rpc('admin_list_suspended_targets', { p_target_type: 'user', p_limit: PAGE_SIZE, p_offset: 0 }),
      supabase.rpc('admin_list_suspended_targets', { p_target_type: 'group', p_limit: PAGE_SIZE, p_offset: 0 }),
    ]);
    if (!current(ctx)) return;
    const failure = users.error ?? groups.error;
    if (failure) { if (failure.code === '42501') authzFailure(ctx); else setError(failure.message); return; }
    setSuspendedTargets([...(users.data ?? []), ...(groups.data ?? [])] as SuspendedTarget[]);
  }, [authzFailure, context, current]);
  const loadDetail = useCallback(async (reportId: string) => {
    const ctx = context(); if (!ctx) return; const requestId = ++detailRequestRef.current; setSelected(null); setError(null);
    const { data, error: rpcError } = await supabase.rpc('admin_get_report', { p_report_id: reportId });
    if (!current(ctx) || requestId !== detailRequestRef.current) return;
    if (rpcError) { if (rpcError.code === '42501') authzFailure(ctx); else setError(rpcError.message); return; }
    setSelected((data?.[0] ?? null) as Detail | null);
  }, [authzFailure, context, current]);
  const loadPhase16 = useCallback(async (pages = phasePagesRef.current) => {
    const ctx = context(); if (!ctx) return;
    setPhaseLoading(true);
    const [requests, catalog, nextProposals, nextReports, nextDuplicates] = await Promise.all([
      supabase.rpc('admin_list_university_requests', { p_limit: PAGE_SIZE, p_offset: pages.requests * PAGE_SIZE }),
      supabase.rpc('admin_list_universities', { p_limit: PAGE_SIZE, p_offset: pages.catalog * PAGE_SIZE }),
      supabase.rpc('admin_list_course_template_proposals', { p_limit: PAGE_SIZE, p_offset: pages.proposals * PAGE_SIZE }),
      supabase.rpc('admin_list_course_template_reports', { p_limit: PAGE_SIZE, p_offset: pages.templateReports * PAGE_SIZE }),
      supabase.rpc('admin_list_course_template_duplicates', { p_limit: PAGE_SIZE, p_offset: pages.duplicates * PAGE_SIZE }),
    ]);
    if (!current(ctx)) return;
    const failure = requests.error ?? catalog.error ?? nextProposals.error ?? nextReports.error ?? nextDuplicates.error;
    if (failure) { if (failure.code === '42501') authzFailure(ctx); else setError(failure.message); setPhaseLoading(false); return; }
    setUniversityRequests((requests.data ?? []) as UniversityRequest[]); setUniversities((catalog.data ?? []) as University[]); setProposals((nextProposals.data ?? []) as Proposal[]); setTemplateReports((nextReports.data ?? []) as TemplateReport[]); setDuplicates((nextDuplicates.data ?? []) as DuplicateCandidate[]);
    setPhaseMore({ requests: (requests.data ?? []).length === PAGE_SIZE, catalog: (catalog.data ?? []).length === PAGE_SIZE, proposals: (nextProposals.data ?? []).length === PAGE_SIZE, templateReports: (nextReports.data ?? []).length === PAGE_SIZE, duplicates: (nextDuplicates.data ?? []).length === PAGE_SIZE });
    setPhaseLoading(false);
  }, [authzFailure, context, current]);

  const loadTargetUniversities = useCallback(async (pageNumber: number, reset: boolean, ctx: RequestContext) => {
    const requestId = ++targetRequestRef.current; setTargetLoading(true);
    const { data, error: rpcError } = await supabase.rpc('admin_list_universities', { p_limit: PAGE_SIZE, p_offset: pageNumber * PAGE_SIZE });
    if (!current(ctx) || requestId !== targetRequestRef.current) return;
    if (rpcError) { if (rpcError.code === '42501') authzFailure(ctx); else setError(rpcError.message); setTargetLoading(false); return; }
    const rows = (data ?? []) as University[];
    setTargetUniversities((previous) => reset ? rows : [...previous.filter((university) => !rows.some((row) => row.university_id === university.university_id)), ...rows]);
    setTargetPage(pageNumber); setTargetHasMore(rows.length === PAGE_SIZE); setTargetLoading(false);
  }, [authzFailure, current]);

  function changePhasePage(queue: keyof typeof phasePages, direction: -1 | 1) {
    if (phaseLoading || (direction > 0 && !phaseMore[queue])) return;
    const pages = { ...phasePages, [queue]: Math.max(0, phasePages[queue] + direction) };
    phasePagesRef.current = pages; setPhasePages(pages); void loadPhase16(pages);
  }

  useEffect(() => {
    let mounted = true;
    void supabase.auth.getSession().then(({ data }) => {
      // An auth event may have already cleared or replaced this session while
      // the initial request was in flight. In that case the late response is
      // stale and must not restore the previous principal.
      if (mounted && !authEventSeenRef.current) acceptSessionUser(data.session?.user ?? null);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      authEventSeenRef.current = true;
      acceptSessionUser(session?.user ?? null);
    });
    return () => { mounted = false; listener.subscription.unsubscribe(); };
  }, [acceptSessionUser]);
  useEffect(() => { if (user) { void loadReports(0); void loadAudits(); void loadPhase16(); void loadSuspendedTargets(); } }, [user, loadAudits, loadPhase16, loadReports, loadSuspendedTargets]);

  const intentOpen = Boolean(intent);
  useEffect(() => {
    if (!intentOpen) { returnFocusRef.current?.focus(); returnFocusRef.current = null; return; }
    const dialog = dialogRef.current;
    const first = dialog?.querySelector<HTMLElement>('textarea, input, select, button');
    first?.focus();
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape' && !mutatingRef.current) { event.preventDefault(); closeIntent(); }
      if (event.key === 'Tab' && dialog) {
        const items = [...dialog.querySelectorAll<HTMLElement>('textarea, input, select, button')].filter((item) => !item.matches(':disabled'));
        if (!items.length) { event.preventDefault(); dialog.focus(); return; }
        const firstItem = items[0]; const lastItem = items[items.length - 1];
        if (!dialog.contains(document.activeElement) || !items.includes(document.activeElement as HTMLElement)) { event.preventDefault(); (event.shiftKey ? lastItem : firstItem).focus(); }
        else if (event.shiftKey && document.activeElement === firstItem) { event.preventDefault(); lastItem.focus(); }
        else if (!event.shiftKey && document.activeElement === lastItem) { event.preventDefault(); firstItem.focus(); }
      }
    }
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [closeIntent, intentOpen]);

  function openIntent(next: AdminIntent) {
    targetRequestRef.current += 1;
    returnFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    setError(null); setIntent(next);
  }
  function editIntent(patch: Partial<AdminIntent>) {
    setIntent((previous) => {
      if (!previous) return previous;
      const changed = Object.entries(patch).some(([key, value]) => previous[key as keyof AdminIntent] !== value);
      return { ...previous, ...patch, operationId: changed ? operationId() : previous.operationId } as AdminIntent;
    });
  }
  function openReasonIntent(next: AdminIntent) {
    openIntent({ ...next, reason: '', operationId: operationId() } as AdminIntent);
  }
  function openSafetyRestore(target: SuspendedTarget) {
    const ctx = context(); if (!ctx) return;
    openReasonIntent({ kind: 'safety-restore', target, reason: '', ctx, operationId: operationId() });
  }
  function openUniversityEdit(university: University) {
    const ctx = context(); if (!ctx) return;
    openIntent({ kind: 'university-update', university, name: university.name, status: university.status, reason: '', ctx, operationId: operationId() });
  }
  function openTemplateMerge(candidate: DuplicateCandidate) {
    const ctx = context(); if (!ctx) return;
    openIntent({ kind: 'template-merge', candidate, direction: 'a-to-b', reason: '', ctx, operationId: operationId() });
  }
  function openReportDecision(action: 'dismiss' | 'hide' | 'warn_user' | 'suspend_user' | 'suspend_group') {
    const ctx = context(); if (!ctx || !selected) return;
    openReasonIntent({ kind: 'report', action, report: selected, reason: '', ctx, operationId: operationId() });
  }
  function openUniversityDecision(request: UniversityRequest, action: 'approve' | 'reject' | 'merge') {
    const ctx = context(); if (!ctx) return;
    openReasonIntent({ kind: 'university-request', action, request, targetId: '', reason: '', ctx, operationId: operationId() });
    if (action === 'merge') { setTargetUniversities([]); setTargetQuery(''); setTargetPage(0); setTargetHasMore(false); void loadTargetUniversities(0, true, ctx); }
  }
  async function openProposalDecision(proposal: Proposal, action: 'approve' | 'reject') {
    const ctx = context(); if (!ctx) return;
    setPhaseLoading(true); setError(null);
    const { data, error: rpcError } = await supabase.rpc('admin_get_course_template_proposal_change', { p_proposal_id: proposal.proposal_id });
    if (!current(ctx)) return;
    setPhaseLoading(false);
    if (rpcError) { if (rpcError.code === '42501') authzFailure(ctx); else setError(rpcError.message); return; }
    const change = ((data ?? []) as ProposalChange[])[0];
    if (!change) { setError('提案の比較情報を取得できません。キューを更新して再確認してください。'); return; }
    openReasonIntent({ kind: 'proposal', action, proposal, change, reason: '', ctx, operationId: operationId() });
  }
  function openTemplateReportDecision(report: TemplateReport, action: 'dismiss' | 'hide') {
    const ctx = context(); if (!ctx) return;
    openReasonIntent({ kind: 'template-report', action, report, reason: '', ctx, operationId: operationId() });
  }

  async function submitIntent(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const pending = intent;
    if (!pending || mutating || mutationLockRef.current) return;
    if (!current(pending.ctx)) return;
    if (!pending.reason.trim()) { setError('理由を入力してください。'); return; }
    if (pending.kind === 'university-update' && !pending.name.trim()) { setError('大学名を入力してください。'); return; }
    if (pending.kind === 'university-request' && pending.action === 'merge' && !pending.targetId.trim()) { setError('統合先 university ID を入力してください。'); return; }
    let rpcName: string; let rpcArgs: Record<string, unknown>;
    switch (pending.kind) {
      case 'report':
        rpcName = 'admin_resolve_report';
        rpcArgs = { p_report_id: pending.report.report_id, p_action: pending.action, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      case 'university-request':
        rpcName = 'admin_resolve_university_request';
        rpcArgs = { p_request_id: pending.request.request_id, p_action: pending.action, p_target_university_id: pending.action === 'merge' ? pending.targetId.trim() : null, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      case 'proposal':
        rpcName = 'admin_resolve_course_template_proposal';
        rpcArgs = { p_proposal_id: pending.proposal.proposal_id, p_action: pending.action, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      case 'template-report':
        rpcName = 'admin_resolve_course_template_report';
        rpcArgs = { p_report_id: pending.report.report_id, p_action: pending.action, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      case 'university-update':
        rpcName = 'admin_update_university';
        rpcArgs = { p_university_id: pending.university.university_id, p_name: pending.name.trim(), p_aliases: pending.university.aliases, p_prefecture: pending.university.prefecture, p_status: pending.status, p_expected_version: pending.university.version, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      case 'template-merge': {
        const aToB = pending.direction === 'a-to-b';
        const sourceId = aToB ? pending.candidate.template_a_id : pending.candidate.template_b_id;
        const targetId = aToB ? pending.candidate.template_b_id : pending.candidate.template_a_id;
        const sourceVersion = aToB ? pending.candidate.template_a_version : pending.candidate.template_b_version;
        const targetVersion = aToB ? pending.candidate.template_b_version : pending.candidate.template_a_version;
        if (sourceVersion == null || targetVersion == null) { setError('テンプレートの現在バージョンを取得できません。'); return; }
        rpcName = 'admin_merge_course_templates';
        rpcArgs = { p_source_template_id: sourceId, p_target_template_id: targetId, p_expected_source_version: sourceVersion, p_expected_target_version: targetVersion, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
      }
      case 'safety-restore':
        rpcName = 'admin_set_safety_state';
        rpcArgs = { p_target_type: pending.target.target_type, p_target_id: pending.target.target_id, p_restore: true, p_expected_version: pending.target.version, p_reason: pending.reason.trim(), p_operation_id: pending.operationId };
        break;
    }
    // The auth snapshot is checked immediately before crossing the mutation boundary.
    if (!current(pending.ctx)) return;
    mutationLockRef.current = true; mutatingRef.current = true; const sequence = ++mutationSequenceRef.current; setMutating(true); setLoading(true); setError(null);
    try {
      const { error: rpcError } = await supabase.rpc(rpcName, rpcArgs);
      if (!current(pending.ctx) || sequence !== mutationSequenceRef.current) return;
      if (rpcError) { if (rpcError.code === '42501') authzFailure(pending.ctx); else setError(rpcError.message); return; }
      closeIntent();
      if (pending.kind === 'report') setSelected(null);
      await Promise.all([pending.kind === 'report' ? loadReports(page) : loadPhase16(), loadAudits(), loadSuspendedTargets()]);
    } finally {
      if (sequence === mutationSequenceRef.current) { mutationLockRef.current = false; mutatingRef.current = false; setMutating(false); setLoading(false); }
    }
  }

  async function signIn(event: FormEvent<HTMLFormElement>) { event.preventDefault(); setLoading(true); setError(null); const { error: signInError } = await supabase.auth.signInWithPassword({ email, password }); if (signInError) setError(signInError.message); setLoading(false); }
  async function signOut() { await supabase.auth.signOut(); clearProtected(); }
  if (!user) return <main className="page narrow"><p className="badge">Phase 15 / Global moderation</p><h1>管理者ログイン</h1><p className="muted">グループ Owner/Admin ではなく、DBで登録されたglobal adminだけが利用できます。</p><form className="card stack" onSubmit={signIn}><label>メール<input required type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label><label>パスワード<input required type="password" value={password} onChange={(event) => setPassword(event.target.value)} /></label><button disabled={loading} type="submit">{loading ? '確認中…' : 'ログイン'}</button>{error && <p className="error" role="alert">{error}</p>}</form></main>;

  const intentTitle = intent?.kind === 'report' ? ({ dismiss: '通報を却下する', hide: '対象を非表示にする', warn_user: '対象者へ警告する', suspend_user: '対象者を利用停止にする', suspend_group: 'グループを停止する' }[intent.action])
    : intent?.kind === 'university-request' ? ({ approve: '大学申請を承認する', reject: '大学申請を却下する', merge: '大学申請を既存大学へ統合する' }[intent.action])
      : intent?.kind === 'proposal' ? (intent.action === 'approve' ? '授業テンプレ修正案を採用する' : '授業テンプレ修正案を却下する')
        : intent?.kind === 'template-report' ? (intent.action === 'hide' ? '授業テンプレを非表示にする' : 'テンプレ通報を却下する')
          : intent?.kind === 'university-update' ? '大学マスタを更新する'
            : intent?.kind === 'template-merge' ? '授業テンプレを統合する'
              : intent?.kind === 'safety-restore' ? '利用停止を解除する' : '';

  function phaseControls(queue: keyof typeof phasePages) {
    return <div className="queue-pagination"><button className="secondary" disabled={phaseLoading || phasePages[queue] === 0} onClick={() => changePhasePage(queue, -1)}>前へ</button><span>ページ {phasePages[queue] + 1}</span><button className="secondary" disabled={phaseLoading || !phaseMore[queue]} onClick={() => changePhasePage(queue, 1)}>次へ</button></div>;
  }

  return <main className="page">
    <header className="toolbar"><div><p className="badge">Phase 16 / Global administration</p><h1>大学・授業テンプレ管理</h1><p className="muted">{user.email} — global admin RPCで保護された画面</p></div><button className="secondary" onClick={signOut}>ログアウト</button></header>
    {error && <div className="error banner" role="alert">{error}<button className="secondary" onClick={() => void loadReports(page)}>再試行</button></div>}
    <div className="admin-grid"><section className="card"><div className="section-heading"><h2>保留中の通報</h2><button className="secondary" disabled={loading} onClick={() => void loadReports(page)}>更新</button></div>{loading && <p className="muted">読み込み中…</p>}{!loading && reports.length === 0 && <p className="muted">保留中の通報はありません。</p>}<div className="report-list">{reports.map((report) => <button className={`report-row ${selected?.report_id === report.report_id ? 'selected' : ''}`} key={report.report_id} onClick={() => void loadDetail(report.report_id)}><strong>{report.target_type}</strong><span>{report.reason}</span><small>{report.reporter_display_name} · {new Date(report.created_at).toLocaleString('ja-JP')}</small></button>)}</div><div className="pagination"><button className="secondary" disabled={loading || page === 0} onClick={() => void loadReports(page - 1)}>前へ</button><span>ページ {page + 1}</span><button className="secondary" disabled={loading || !hasMore} onClick={() => void loadReports(page + 1)}>次へ</button></div></section>
      <section className="card detail"><h2>詳細と判断</h2>{!selected ? <p className="muted">通報を選択してください。</p> : <><dl><dt>対象</dt><dd>{selected.target_type}:{selected.target_id}</dd><dt>通報者</dt><dd>{selected.reporter_display_name} ({selected.reporter_user_id})</dd><dt>理由</dt><dd>{selected.reason}</dd><dt>状態</dt><dd>{selected.status}</dd></dl>{selected.target_context && <><h3>対象コンテキスト</h3><pre className="context">{JSON.stringify(selected.target_context, null, 2)}</pre></>}<div className="actions"><button disabled={loading} onClick={() => openReportDecision('dismiss')}>却下（変更なし）</button>{['event', 'comment'].includes(selected.target_type) && <button className="danger" disabled={loading} onClick={() => openReportDecision('hide')}>対象を非表示</button>}{['event', 'comment', 'user'].includes(selected.target_type) && <><button disabled={loading} onClick={() => openReportDecision('warn_user')}>対象者へ警告</button><button className="danger" disabled={loading} onClick={() => openReportDecision('suspend_user')}>対象者を利用停止</button></>}{selected.target_type === 'group' && <button className="danger" disabled={loading} onClick={() => openReportDecision('suspend_group')}>グループを停止</button>}</div></>}</section></div>
    <section className="card phase16-grid"><div className="section-heading"><h2>停止中のアカウント・グループ</h2><button className="secondary" disabled={loading} onClick={() => void loadSuspendedTargets()}>更新</button></div>{suspendedTargets.length === 0 ? <p className="muted">停止中の対象はありません。</p> : <div className="report-list">{suspendedTargets.map((target) => <article className="report-row" key={`${target.target_type}:${target.target_id}`}><strong>{target.target_type === 'user' ? 'アカウント' : 'グループ'} · {target.display_name}</strong><span>{target.reason}</span><small>{target.target_id} · v{target.version} · {new Date(target.changed_at).toLocaleString('ja-JP')}</small><button disabled={loading} onClick={() => openSafetyRestore(target)}>停止を解除</button></article>)}</div>}</section>
    <section className="card phase16-grid"><div className="section-heading"><h2>大学申請</h2>{phaseControls('requests')}<button className="secondary" disabled={phaseLoading} onClick={() => void loadPhase16()}>更新</button></div>{universityRequests.length === 0 ? <p className="muted">保留中の大学申請はありません。</p> : <div className="report-list">{universityRequests.map((request) => <article className="report-row" key={request.request_id}><strong>{request.name}</strong><span>{request.prefecture ?? '都道府県未設定'}</span><small>{new Date(request.created_at).toLocaleString('ja-JP')}</small><div className="actions"><button disabled={loading} onClick={() => openUniversityDecision(request, 'approve')}>承認（新規/既存）</button><button disabled={loading} onClick={() => openUniversityDecision(request, 'reject')}>却下</button><button disabled={loading} onClick={() => openUniversityDecision(request, 'merge')}>既存へ統合</button></div></article>)}</div>}</section>
    <section className="card phase16-grid"><div className="section-heading"><h2>大学マスタ</h2>{phaseControls('catalog')}<button className="secondary" disabled={phaseLoading} onClick={() => void loadPhase16()}>更新</button></div>{universities.length === 0 ? <p className="muted">大学マスタはありません。</p> : <div className="report-list">{universities.map((university) => <article className="report-row" key={university.university_id}><strong>{university.name}</strong><span>{university.prefecture ?? '都道府県未設定'} · {university.status} · v{university.version}</span><button onClick={() => openUniversityEdit(university)}>名称・状態を編集</button></article>)}</div>}</section>
    <section className="card phase16-grid"><div className="section-heading"><h2>授業テンプレ修正提案</h2>{phaseControls('proposals')}<button className="secondary" disabled={phaseLoading} onClick={() => void loadPhase16()}>更新</button></div>{proposals.length === 0 ? <p className="muted">保留中の提案はありません。</p> : <div className="report-list">{proposals.map((proposal) => <article className="report-row" key={proposal.proposal_id}><strong>{proposal.template_id}</strong><code>{JSON.stringify(proposal.proposed_payload)}</code><div className="actions"><button disabled={loading} onClick={() => openProposalDecision(proposal, 'approve')}>採用</button><button disabled={loading} onClick={() => openProposalDecision(proposal, 'reject')}>却下</button></div></article>)}</div>}</section>
    <section className="card phase16-grid"><div className="section-heading"><h2>授業テンプレ通報</h2>{phaseControls('templateReports')}<button className="secondary" disabled={phaseLoading} onClick={() => void loadPhase16()}>更新</button></div>{templateReports.length === 0 ? <p className="muted">保留中のテンプレ通報はありません。</p> : <div className="report-list">{templateReports.map((report) => <article className="report-row" key={report.report_id}><strong>{report.template_id}</strong><span>{report.reason}</span><div className="actions"><button disabled={loading} onClick={() => openTemplateReportDecision(report, 'dismiss')}>却下</button><button className="danger" disabled={loading} onClick={() => openTemplateReportDecision(report, 'hide')}>非表示</button></div></article>)}</div>}</section>
    <section className="card phase16-grid"><div className="section-heading"><h2>重複候補の比較・統合</h2>{phaseControls('duplicates')}<button className="secondary" disabled={phaseLoading} onClick={() => void loadPhase16()}>更新</button></div>{duplicates.length === 0 ? <p className="muted">保留中の重複候補はありません。</p> : <div className="report-list">{duplicates.map((candidate) => <article className="report-row" key={candidate.candidate_id}><strong>類似度 {candidate.score}</strong><span className="duplicate-compare"><span>A: {candidate.template_a_title ?? candidate.template_a_id} · v{candidate.template_a_version ?? '?'}</span><span>B: {candidate.template_b_title ?? candidate.template_b_id} · v{candidate.template_b_version ?? '?'}</span></span><small>候補 v{candidate.version}</small><button disabled={loading} onClick={() => openTemplateMerge(candidate)}>比較して統合</button></article>)}</div>}</section>
    <section className="card audit"><div className="section-heading"><h2>監査ログ</h2><button className="secondary" onClick={() => void loadAudits()}>更新</button></div>{audits.length === 0 ? <p className="muted">監査ログはありません。</p> : <div className="audit-list">{audits.map((audit) => <article key={audit.audit_id}><strong>{audit.action}</strong><span>{audit.target_type}:{audit.target_id}</span><small>{new Date(audit.created_at).toLocaleString('ja-JP')}</small><code>{JSON.stringify(audit.metadata)}</code></article>)}</div>}</section>
    {intent && <div className="dialog-backdrop"><div className="admin-dialog" role="dialog" aria-modal="true" aria-labelledby="intent-heading" ref={dialogRef} tabIndex={-1}>
      <form className="stack" onSubmit={submitIntent}>
        <h2 id="intent-heading">{intentTitle}</h2>
        <fieldset disabled={mutating} className="dialog-fields"><div className="intent-summary">
          {intent.kind === 'report' && <><strong>{intent.report.target_type}:{intent.report.target_id}</strong><p>通報者: {intent.report.reporter_display_name}</p><p>通報理由: {intent.report.reason}</p><p>{({ dismiss: '通報を却下し、対象の状態は変更しません。', hide: '対象を全利用者から非表示にします。', warn_user: '対象者はサーバー側で特定し、警告を本人だけが読める通知として記録します。', suspend_user: '対象者はサーバー側で特定し、利用を停止します。停止中は同期・共有APIへのアクセスが制限されます。', suspend_group: '対象グループの共有と操作を停止し、保留中の招待を取り消します。' }[intent.action])}</p></>}
          {intent.kind === 'university-request' && <><strong>{intent.request.name}</strong><p>申請ID: {intent.request.request_id}</p><p>都道府県: {intent.request.prefecture ?? '未設定'}</p>{intent.action === 'merge' && <><label>大学を検索<input type="search" value={targetQuery} onChange={(event) => setTargetQuery(event.target.value)} placeholder="大学名、ID、都道府県" /></label><label>統合先の大学<select required value={intent.targetId} onChange={(event) => editIntent({ targetId: event.target.value })}><option value="">選択してください</option>{targetUniversities.filter((university) => university.status === 'active' && (`${university.name} ${university.university_id} ${university.prefecture ?? ''}`.toLocaleLowerCase().includes(targetQuery.trim().toLocaleLowerCase()) || university.university_id === intent.targetId)).map((university) => <option key={university.university_id} value={university.university_id}>{university.name} · {university.university_id}</option>)}</select></label><p>{targetUniversities.length} 大学を読み込み済み。検索は読み込み済みの大学に適用されます。</p><button type="button" className="secondary" disabled={targetLoading || !targetHasMore} onClick={() => void loadTargetUniversities(targetPage + 1, false, intent.ctx)}>{targetLoading ? '読み込み中…' : 'さらに大学を読み込む'}</button></>}</>}
          {intent.kind === 'proposal' && <>
            <strong>対象テンプレート: {intent.proposal.template_id}</strong>
            <p>提案者: {intent.proposal.proposed_by}</p>
            <p>提出時のテンプレート v{intent.change.expected_template_version} · 現在 v{intent.change.current_template_version}</p>
            {!intent.change.snapshot_available && <p className="muted">この提案には変更前の保存記録がありません。過去の値を推測して表示せず、現在値と提案値を並べています。</p>}
            {intent.change.current_template_version !== intent.change.expected_template_version && <p className="error" role="alert">提案提出後にテンプレートが更新されています。採用はバージョン不一致で拒否されるため、現在値を確認してから再審査してください。</p>}
            <div className="proposal-diff-wrap">
              <table className="proposal-diff">
                <thead><tr><th>項目</th><th>変更前</th><th>提案値</th><th>現在値</th></tr></thead>
                <tbody>{Object.entries(intent.change.proposed_payload).map(([key, value]) => <tr key={key}>
                  <th scope="row">{templateFieldLabels[key] ?? key}</th>
                  <td>{intent.change.snapshot_available ? displayTemplateValue(intent.change.before_payload?.[key]) : '記録なし'}</td>
                  <td>{displayTemplateValue(value)}</td>
                  <td>{displayTemplateValue(intent.change.current_payload[key])}</td>
                </tr>)}</tbody>
              </table>
            </div>
          </>}
          {intent.kind === 'template-report' && <><strong>対象テンプレート: {intent.report.template_id}</strong><p>通報理由: {intent.report.reason}</p><p>{intent.action === 'hide' ? '対象を全利用者から非表示にします。' : '通報を却下し、対象の状態は変更しません。'}</p></>}
          {intent.kind === 'university-update' && <><strong>{intent.university.name}</strong><p>ID: {intent.university.university_id} · 現在 v{intent.university.version}</p><label>大学名<input required maxLength={160} value={intent.name} onChange={(event) => editIntent({ name: event.target.value })} /></label><label>状態<select value={intent.status} onChange={(event) => editIntent({ status: event.target.value })}><option value="active">active（公開）</option><option value="hidden">hidden（非表示）</option></select></label><p>別名と都道府県は現在の値を保持します。</p></>}
          {intent.kind === 'template-merge' && <><strong>統合方向を選択</strong><p>A: {intent.candidate.template_a_title ?? intent.candidate.template_a_id} · {intent.candidate.template_a_id} · v{intent.candidate.template_a_version ?? '不明'}</p><p>B: {intent.candidate.template_b_title ?? intent.candidate.template_b_id} · {intent.candidate.template_b_id} · v{intent.candidate.template_b_version ?? '不明'}</p><fieldset className="direction-options"><legend>残すテンプレートを選択</legend><label><input type="radio" name="merge-direction" value="a-to-b" checked={intent.direction === 'a-to-b'} onChange={() => editIntent({ direction: 'a-to-b' })} /> A → B（AをBへ統合）</label><label><input type="radio" name="merge-direction" value="b-to-a" checked={intent.direction === 'b-to-a'} onChange={() => editIntent({ direction: 'b-to-a' })} /> B → A（BをAへ統合）</label></fieldset><p>実行: {(intent.direction === 'a-to-b' ? intent.candidate.template_a_id : intent.candidate.template_b_id)} → {(intent.direction === 'a-to-b' ? intent.candidate.template_b_id : intent.candidate.template_a_id)}</p><p>統合後に残るテンプレート: {intent.direction === 'a-to-b' ? intent.candidate.template_b_id : intent.candidate.template_a_id}</p><p>バージョン検証: source v{intent.direction === 'a-to-b' ? intent.candidate.template_a_version ?? '不明' : intent.candidate.template_b_version ?? '不明'}、target v{intent.direction === 'a-to-b' ? intent.candidate.template_b_version ?? '不明' : intent.candidate.template_a_version ?? '不明'}</p></>}
          {intent.kind === 'safety-restore' && <><strong>{intent.target.target_type === 'user' ? 'アカウント' : 'グループ'}: {intent.target.display_name}</strong><p>ID: {intent.target.target_id}</p><p>現在の停止理由: {intent.target.reason}</p><p>停止バージョン: {intent.target.version}</p><p>解除後も取消済みの招待や以前の端末登録は復活しません。</p></>}
        </div>
        <label>理由<textarea required rows={4} value={intent.reason} onChange={(event) => editIntent({ reason: event.target.value })} placeholder="判断の根拠" /></label></fieldset>
        {error && <p className="error" role="alert">{error}</p>}
        <div className="actions"><button type="button" className="secondary" disabled={mutating} onClick={() => setIntent(null)}>キャンセル</button><button type="submit" className={intent.kind === 'report' && ['hide', 'suspend_user', 'suspend_group'].includes(intent.action) || intent.kind === 'template-report' && intent.action === 'hide' ? 'danger' : ''} disabled={mutating || intent.kind === 'proposal' && intent.action === 'approve' && intent.change.current_template_version !== intent.change.expected_template_version}>{mutating ? '実行中…' : 'この内容で実行'}</button></div>
      </form>
    </div></div>}
  </main>;
}
