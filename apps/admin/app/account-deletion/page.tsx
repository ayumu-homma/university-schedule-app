'use client';

import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { resolveAccountDeletionRedirectTo } from '../../lib/account-deletion-url.mjs';

type Successor = { user_id: string; display_name: string };
type DeletionGroup = {
  group_id: string;
  name: string;
  member_count: number;
  successors: Successor[];
};
type GroupAction = { group_id: string; action: 'delete' | 'transfer' | 'disband'; successor_id?: string };
type DeletionContext = { operation_id: string; phase: string; group_actions: GroupAction[] };
type Decision = { action: 'transfer' | 'disband'; successorId?: string };

export default function AccountDeletionPage() {
  const [userId, setUserId] = useState<string | null>(null);
  const [email, setEmail] = useState('');
  const [signedInEmail, setSignedInEmail] = useState('');
  const [emailLinkSent, setEmailLinkSent] = useState(false);
  const [groups, setGroups] = useState<DeletionGroup[]>([]);
  const [decisions, setDecisions] = useState<Record<string, Decision>>({});
  const [confirmation, setConfirmation] = useState('');
  const [pending, setPending] = useState<DeletionContext | null>(null);
  const [busy, setBusy] = useState(false);
  const [ready, setReady] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');

  const loadOwnerState = useCallback(async (expectedUserId: string) => {
    const { data: contextRows, error: contextError } = await supabase.rpc(
      'get_my_account_deletion_context',
    );
    if (contextError) throw new Error('deletion_context_unavailable');
    const rows = Array.isArray(contextRows) ? contextRows as DeletionContext[] : [];
    const active = rows.find((row) => row.phase !== 'complete');
    if (active) {
      setPending(active);
      setGroups([]);
      return;
    }

    const { data: preflight, error: preflightError } = await supabase.rpc(
      'get_my_account_deletion_preflight',
    );
    if (preflightError) throw new Error('deletion_preflight_unavailable');
    const current = await supabase.auth.getUser();
    if (current.data.user?.id !== expectedUserId) throw new Error('account_changed');
    const payload = preflight as { groups?: DeletionGroup[] } | null;
    setGroups(Array.isArray(payload?.groups) ? payload.groups : []);
    setPending(null);
  }, []);

  useEffect(() => {
    let live = true;
    const applySession = async (id: string | null, nextEmail: string) => {
      if (!live) return;
      setUserId(id);
      setSignedInEmail(nextEmail);
      setReady(true);
      if (!id) return;
      try {
        await loadOwnerState(id);
      } catch {
        if (live) setError('削除状態を確認できませんでした。時間をおいて再度お試しください。');
      }
    };

    void supabase.auth.getSession().then(({ data }) => {
      void applySession(data.session?.user.id ?? null, data.session?.user.email ?? '');
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      void applySession(session?.user.id ?? null, session?.user.email ?? '');
    });
    return () => {
      live = false;
      listener.subscription.unsubscribe();
    };
  }, [loadOwnerState]);

  const canConfirm = useMemo(() => {
    if (confirmation !== '削除') return false;
    return groups.every((group) => {
      if (group.member_count <= 1) return true;
      const decision = decisions[group.group_id];
      if (!decision) return false;
      return decision.action === 'disband' || Boolean(decision.successorId);
    });
  }, [confirmation, decisions, groups]);

  async function sendSignInLink(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const redirectTo = resolveAccountDeletionRedirectTo({
        appEnv: process.env.NEXT_PUBLIC_APP_ENV,
        configuredUrl: process.env.NEXT_PUBLIC_ACCOUNT_DELETION_URL,
        nodeEnv: process.env.NODE_ENV,
        currentOrigin: window.location.origin,
      });
      if (!redirectTo) throw new Error('account_deletion_url_not_configured');
      const { error: signInError } = await supabase.auth.signInWithOtp({
        email: email.trim(),
        options: { emailRedirectTo: redirectTo, shouldCreateUser: false },
      });
      if (signInError) throw signInError;
      setEmailLinkSent(true);
      setNotice('既存アカウントの場合、確認リンクを送信しました。メールのリンクから戻って続けてください。');
    } catch {
      setError('確認リンクを送信できませんでした。メールアドレスと通信設定を確認してください。');
    } finally {
      setBusy(false);
    }
  }

  function chooseGroup(group: DeletionGroup, action: 'transfer' | 'disband') {
    setDecisions((current) => ({
      ...current,
      [group.group_id]: {
        action,
        successorId: action === 'transfer' ? group.successors[0]?.user_id : undefined,
      },
    }));
  }

  async function runWorker(operationId: string) {
    const current = await supabase.auth.getUser();
    if (current.data.user?.id !== userId) throw new Error('account_changed');
    const { data, error: workerError } = await supabase.functions.invoke(
      'process-account-deletion',
      { body: { operation_id: operationId } },
    );
    if (workerError || data?.phase !== 'complete') {
      throw new Error('deletion_worker_incomplete');
    }
    await supabase.auth.signOut({ scope: 'local' });
    setUserId(null);
    setPending(null);
    setNotice('アカウントとサーバーデータを削除しました。');
  }

  async function requestDeletion() {
    if (!userId || !canConfirm || busy) return;
    setBusy(true);
    setError('');
    setNotice('');
    try {
      const current = await supabase.auth.getUser();
      if (current.data.user?.id !== userId) throw new Error('account_changed');
      const groupActions: GroupAction[] = groups.map((group) => {
        if (group.member_count <= 1) return { group_id: group.group_id, action: 'delete' };
        const decision = decisions[group.group_id];
        return decision.action === 'transfer'
          ? { group_id: group.group_id, action: 'transfer', successor_id: decision.successorId }
          : { group_id: group.group_id, action: 'disband' };
      });
      const operationId = crypto.randomUUID();
      const { error: requestError } = await supabase.rpc('request_account_deletion', {
        p_operation_id: operationId,
        p_group_actions: groupActions,
      });
      if (requestError) throw new Error('deletion_request_rejected');
      setPending({ operation_id: operationId, phase: 'requested', group_actions: groupActions });
      await runWorker(operationId);
    } catch {
      setError('削除を完了できませんでした。申請済みの場合は、同じアカウントで再度開いて処理を再開してください。');
      if (userId) {
        try { await loadOwnerState(userId); } catch { /* Keep the retry guidance visible. */ }
      }
    } finally {
      setBusy(false);
    }
  }

  async function resumeDeletion() {
    if (!userId || !pending || busy) return;
    setBusy(true);
    setError('');
    try {
      await runWorker(pending.operation_id);
    } catch {
      setError('削除処理を再開できませんでした。しばらくしてからもう一度お試しください。');
      try { await loadOwnerState(userId); } catch { /* Keep the retry guidance visible. */ }
    } finally {
      setBusy(false);
    }
  }

  if (!ready) return <main className="page narrow"><p>アカウント状態を確認しています…</p></main>;

  return (
    <main className="page narrow deletion-page">
      <p className="badge">アカウントとデータの削除</p>
      <h1>アカウント削除</h1>
      <p className="muted">
        個人データ、予定、連携情報、ログイン情報を削除します。共有コメントは匿名化されます。
        共有グループは削除前に移管先または解散を選びます。
      </p>

      {notice && <p className="deletion-notice" role="status">{notice}</p>}
      {error && <p className="error" role="alert">{error}</p>}

      {!userId && (
        <form className="card stack" onSubmit={sendSignInLink}>
          <h2>本人確認</h2>
          <p>登録済みメールアドレスへ一度限りの確認リンクを送ります。リンクから戻ると削除を続けられます。</p>
          <label htmlFor="deletion-email">登録済みメールアドレス</label>
          <input id="deletion-email" required type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} />
          <button disabled={busy}>{busy ? '送信中…' : '確認リンクを送信'}</button>
          {emailLinkSent && <p className="muted">メールが届かない場合は、迷惑メールと登録アドレスを確認してください。</p>}
        </form>
      )}

      {userId && pending && (
        <section className="card stack" aria-live="polite">
          <h2>削除処理を再開</h2>
          <p>確認済みの申請があります（状態: {pending.phase}）。完了するまでサーバーデータの削除を続けます。</p>
          <button className="danger" disabled={busy} onClick={() => void resumeDeletion()}>{busy ? '処理中…' : '削除処理を再開'}</button>
          <button className="secondary" disabled={busy} onClick={() => void supabase.auth.signOut({ scope: 'local' })}>ログアウト</button>
        </section>
      )}

      {userId && !pending && (
        <section className="card stack">
          <p>確認済みアカウント: <strong>{signedInEmail}</strong></p>
          {groups.length > 0 && <h2>管理している共有グループ</h2>}
          {groups.map((group) => {
            const decision = decisions[group.group_id];
            return (
              <fieldset className="deletion-group" key={group.group_id}>
                <legend>{group.name}</legend>
                {group.member_count <= 1 ? (
                  <p>あなたのみのグループは、アカウント削除時に削除されます。</p>
                ) : (
                  <>
                    <p>共有グループ · {group.member_count} 人</p>
                    <label className="deletion-choice">
                      <input type="radio" name={`group-${group.group_id}`} checked={decision?.action === 'transfer'} disabled={group.successors.length === 0} onChange={() => chooseGroup(group, 'transfer')} />
                      メンバーへ管理を移す
                    </label>
                    {decision?.action === 'transfer' && group.successors.length > 0 && (
                      <label htmlFor={`successor-${group.group_id}`}>移管先
                        <select id={`successor-${group.group_id}`} value={decision.successorId} onChange={(event) => setDecisions((current) => ({ ...current, [group.group_id]: { action: 'transfer', successorId: event.target.value } }))}>
                          {group.successors.map((member) => <option key={member.user_id} value={member.user_id}>{member.display_name}</option>)}
                        </select>
                      </label>
                    )}
                    <label className="deletion-choice">
                      <input type="radio" name={`group-${group.group_id}`} checked={decision?.action === 'disband'} onChange={() => chooseGroup(group, 'disband')} />
                      グループと共有データを削除する
                    </label>
                    {group.successors.length === 0 && <p className="muted">移管可能なメンバーがいません。解散を選択してください。</p>}
                  </>
                )}
              </fieldset>
            );
          })}
          <label htmlFor="deletion-confirmation">続けるには「削除」と入力してください。</label>
          <input id="deletion-confirmation" value={confirmation} onChange={(event) => setConfirmation(event.target.value)} autoComplete="off" />
          <button className="danger" disabled={!canConfirm || busy} onClick={() => void requestDeletion()}>{busy ? '削除中…' : 'アカウントとデータを削除'}</button>
          <button className="secondary" disabled={busy} onClick={() => void supabase.auth.signOut({ scope: 'local' })}>ログアウト</button>
        </section>
      )}
    </main>
  );
}
