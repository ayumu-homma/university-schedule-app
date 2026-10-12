type Fixture = {
  anon_key: string;
  owner: { id: string; token: string };
  reporter: { id: string; token: string };
  outsider: { id: string; token: string };
  admin: { id: string; token: string };
  group_id: string;
  event_id: string;
  calendar_id: string;
  comment_id: string;
  report_operation_id: string;
  resolve_operation_id: string;
  cleanup_prefix: string;
};

type RpcResult = {
  status: number;
  code?: string;
  body: unknown;
};

const fixturePath = Deno.env.get("P133_FIXTURE_PATH");
if (!fixturePath) throw new Error("P133 private fixture path is missing");
const fixture = JSON.parse(await Deno.readTextFile(fixturePath)) as Fixture;
const apiUrl = "http://gateway:8000/rest/v1";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function rpc(
  name: string,
  args: Record<string, unknown>,
  token?: string,
): Promise<RpcResult> {
  const headers = new Headers({
    apikey: fixture.anon_key,
    "content-type": "application/json",
  });
  if (token) headers.set("authorization", `Bearer ${token}`);
  const response = await fetch(`${apiUrl}/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => undefined) as
    | { code?: unknown }
    | unknown;
  const code = (body as { code?: unknown } | undefined)?.code;
  return {
    status: response.status,
    body,
    code: typeof code === "string" ? code : undefined,
  };
}

Deno.test("P133 group comment report and global moderation use GoTrue/PostgREST", async () => {
  const ownerToken = fixture.owner.token;
  const reporterToken = fixture.reporter.token;
  const outsiderToken = fixture.outsider.token;
  const adminToken = fixture.admin.token;

  const reportArgs = {
    p_target_type: "comment",
    p_target_id: fixture.comment_id,
    p_reason: "P133 synthetic moderation report reason",
    p_operation_id: fixture.report_operation_id,
  };
  const created = await rpc(
    "create_group_content_report",
    reportArgs,
    reporterToken,
  );
  assert(
    created.status === 200,
    "group member could not submit comment report",
  );
  assert(
    Array.isArray(created.body),
    "report creation response was not an array",
  );
  const report = (created.body as Array<Record<string, unknown>>)[0];
  assert(report?.status === "pending", "submitted report was not pending");
  assert(report?.target_type === "comment", "report target type changed");
  assert(
    report?.target_id === fixture.comment_id,
    "report targeted wrong comment",
  );
  assert(typeof report.report_id === "string", "report id was not returned");

  const replay = await rpc(
    "create_group_content_report",
    reportArgs,
    reporterToken,
  );
  assert(replay.status === 200, "exact report operation replay failed");
  const replayRow = (replay.body as Array<Record<string, unknown>>)[0];
  assert(
    replayRow?.report_id === report.report_id,
    "exact report replay created a different report",
  );

  const outsiderReport = await rpc(
    "create_group_content_report",
    { ...reportArgs, p_operation_id: crypto.randomUUID() },
    outsiderToken,
  );
  assert(
    outsiderReport.status === 403 && outsiderReport.code === "42501",
    "nonmember could submit a comment report",
  );
  const anonymousReport = await rpc(
    "create_group_content_report",
    { ...reportArgs, p_operation_id: crypto.randomUUID() },
  );
  assert(
    anonymousReport.status === 401 && anonymousReport.code === "42501",
    "anonymous caller could submit a comment report",
  );

  for (
    const [principal, token] of [
      ["owner", ownerToken],
      ["reporter", reporterToken],
    ] as const
  ) {
    const list = await rpc(
      "admin_list_pending_reports",
      { p_limit: 10, p_offset: 0 },
      token,
    );
    assert(
      list.status === 403 && list.code === "42501",
      `${principal} could access global moderation queue`,
    );
    const detail = await rpc(
      "admin_get_report",
      { p_report_id: report.report_id },
      token,
    );
    assert(
      detail.status === 403 && detail.code === "42501",
      `${principal} could access global moderation detail`,
    );
  }

  const queue = await rpc(
    "admin_list_pending_reports",
    { p_limit: 10, p_offset: 0 },
    adminToken,
  );
  assert(queue.status === 200, "registered global admin could not load queue");
  assert(Array.isArray(queue.body), "admin queue response was not an array");
  assert(
    (queue.body as Array<Record<string, unknown>>).some((row) =>
      row.report_id === report.report_id && row.status === "pending"
    ),
    "pending comment report was absent from the admin queue",
  );

  const detail = await rpc(
    "admin_get_report",
    { p_report_id: report.report_id },
    adminToken,
  );
  assert(detail.status === 200, "admin could not load report detail");
  const detailRow = (detail.body as Array<Record<string, unknown>>)[0];
  const context = detailRow?.target_context as
    | Record<string, unknown>
    | undefined;
  assert(
    context?.comment_id === fixture.comment_id &&
      context.body === "P133 synthetic comment body",
    "admin detail did not resolve the comment target context",
  );

  const resolveArgs = {
    p_report_id: report.report_id,
    p_action: "hide",
    p_reason: "P133 synthetic hide decision",
    p_operation_id: fixture.resolve_operation_id,
  };
  const resolved = await rpc("admin_resolve_report", resolveArgs, adminToken);
  assert(resolved.status === 200, "admin hide action failed");
  const resolvedRow = (resolved.body as Array<Record<string, unknown>>)[0];
  assert(
    resolvedRow?.status === "actioned",
    "report did not reach actioned state",
  );
  assert(
    resolvedRow?.target_state === "hidden",
    "comment was not transitioned to hidden",
  );

  const replayResolve = await rpc(
    "admin_resolve_report",
    resolveArgs,
    adminToken,
  );
  assert(replayResolve.status === 200, "exact moderation replay failed");
  const replayResolveRow =
    (replayResolve.body as Array<Record<string, unknown>>)[0];
  assert(
    replayResolveRow?.audit_id === resolvedRow.audit_id,
    "exact moderation replay created another audit entry",
  );

  const comments = await rpc(
    "list_group_event_comments",
    { p_event_id: fixture.event_id },
    reporterToken,
  );
  assert(comments.status === 200, "member could not reload group comments");
  assert(
    Array.isArray(comments.body) &&
      !(comments.body as Array<Record<string, unknown>>).some((row) =>
        row.comment_id === fixture.comment_id
      ),
    "moderated comment remained in the member projection",
  );

  const audits = await rpc(
    "admin_list_audit_logs",
    { p_limit: 20, p_offset: 0 },
    adminToken,
  );
  assert(audits.status === 200, "admin could not reload the audit queue");
  assert(
    Array.isArray(audits.body) &&
      (audits.body as Array<Record<string, unknown>>).filter((row) =>
          row.audit_id === resolvedRow.audit_id &&
          row.target_id === fixture.comment_id
        ).length === 1,
    "moderation audit was absent or duplicated",
  );

  console.log(
    "report=200/pending; exact_report_replay=same_id; outsider=403/42501; anonymous=401/42501; nonadmin_queue_detail=403/42501; admin_queue_detail=200; hide=200/actioned/hidden; exact_hide_replay=same_audit; member_projection=hidden; audit=1",
  );
});
