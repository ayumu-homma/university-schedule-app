type Principal = { id: string; email: string; password: string };
type Fixture = {
  anon_key: string;
  group_id: string;
  event_id: string;
  event_title: string;
  event_location: string;
  event_description: string;
  users: { owner: Principal; member: Principal; outsider: Principal };
};
type RpcResponse = {
  status: number;
  code?: string;
  body: unknown;
  text: string;
};

const fixturePath = Deno.env.get("P149_FIXTURE_PATH");
if (!fixturePath) throw new Error("P149 fixture path unavailable");
const fixture = JSON.parse(await Deno.readTextFile(fixturePath)) as Fixture;
const apiUrl = "http://gateway:8000";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function accessToken(principal: Principal): Promise<string> {
  const response = await fetch("http://auth:9999/token?grant_type=password", {
    method: "POST",
    headers: { apikey: fixture.anon_key, "content-type": "application/json" },
    body: JSON.stringify({
      email: principal.email,
      password: principal.password,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const payload = await response.json().catch(() => ({})) as {
    access_token?: unknown;
  };
  assert(
    response.status === 200 && typeof payload.access_token === "string",
    "synthetic GoTrue password grant failed",
  );
  return payload.access_token;
}

async function rpc(
  name: string,
  args: Record<string, unknown>,
  token: string,
): Promise<RpcResponse> {
  const response = await fetch(`${apiUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: fixture.anon_key,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }
  const code = typeof body === "object" && body !== null && "code" in body
    ? String((body as { code: unknown }).code)
    : undefined;
  return { status: response.status, code, body, text };
}

function rows(response: RpcResponse): Array<Record<string, unknown>> {
  assert(
    response.status === 200 && Array.isArray(response.body),
    "member RPC did not return its expected row array",
  );
  return response.body as Array<Record<string, unknown>>;
}

function hasDetails(response: RpcResponse): boolean {
  return rows(response).some((row) =>
    row.event_id === fixture.event_id &&
    row.title === fixture.event_title &&
    row.location === fixture.event_location &&
    row.description === fixture.event_description
  );
}

Deno.test("P149 PRIVATE group event is member-only detail and absent from shared projection", async () => {
  const memberToken = await accessToken(fixture.users.member);
  const outsiderToken = await accessToken(fixture.users.outsider);

  const memberList = await rpc("list_group_events", {
    p_group_id: fixture.group_id,
  }, memberToken);
  assert(
    hasDetails(memberList),
    "group member did not receive PRIVATE event details from list RPC",
  );
  const memberDetail = await rpc("get_group_event", {
    p_event_id: fixture.event_id,
  }, memberToken);
  assert(
    hasDetails(memberDetail),
    "group member did not receive PRIVATE event details from detail RPC",
  );

  const projection = await rpc("get_visible_events", {
    viewer_id: fixture.users.member.id,
    range_start: "2026-10-01T00:00:00Z",
    range_end: "2026-11-01T00:00:00Z",
  }, memberToken);
  assert(
    projection.status === 200 && Array.isArray(projection.body),
    "shared schedule projection failed for the authenticated group member",
  );
  assert(
    !projection.text.includes(fixture.event_title) &&
      !projection.text.includes(fixture.event_location) &&
      !projection.text.includes(fixture.event_description) &&
      !(projection.body as Array<Record<string, unknown>>).some((row) =>
        row.event_id === fixture.event_id
      ),
    "PRIVATE group event leaked into the shared schedule projection",
  );

  for (
    const [name, args] of [
      ["list_group_events", { p_group_id: fixture.group_id }],
      ["get_group_event", { p_event_id: fixture.event_id }],
    ] as const
  ) {
    const denied = await rpc(name, args, outsiderToken);
    assert(
      denied.status === 403 && denied.code === "42501",
      `nonmember ${name} did not preserve the SQLSTATE 42501 access-denial contract`,
    );
    assert(
      !denied.text.includes(fixture.event_title) &&
        !denied.text.includes(fixture.event_location) &&
        !denied.text.includes(fixture.event_description),
      `nonmember ${name} response included a private event canary`,
    );
  }

  console.log(
    "P149 member direct details=2x200; shared projection omits PRIVATE event; outsider direct reads=2x403/42501; canaries absent from denied/projection responses",
  );
});
