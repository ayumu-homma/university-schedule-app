type JsonRecord = Record<string, unknown>;
type UserFixture = { id: string; email: string; password: string };

const authUrl = "http://p84-share01-20260928-v15-auth:9999";
const restUrl = "http://p84-share01-20260928-v15-rest:3000";
const titleCanary = "P108 group title canary";
const locationCanary = "P108 private location canary";
const descriptionCanary = "P108 private description canary";
const startAt = "2031-02-01T01:00:00Z";
const endAt = "2031-02-01T02:00:00Z";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function jwt(role: "anon" | "service_role"): Promise<string> {
  const secret = Deno.env.get("PGRST_JWT_SECRET");
  assert(secret, "isolated signing input unavailable");
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(new TextEncoder().encode(
    JSON.stringify({ alg: "HS256", typ: "JWT" }),
  ));
  const payload = base64Url(new TextEncoder().encode(JSON.stringify({
    iss: "supabase",
    role,
    aud: "authenticated",
    iat: now,
    exp: now + 300,
  })));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64Url(new Uint8Array(signature))}`;
}

async function createUser(role: "owner" | "member", adminToken: string) {
  const suffix = crypto.randomUUID();
  const user: UserFixture = {
    id: "",
    email: `p84-p108-${role}-${suffix}@example.invalid`,
    password: `P84 synthetic ${crypto.randomUUID()}!`,
  };
  const response = await fetch(`${authUrl}/admin/users`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${adminToken}`,
      apikey: adminToken,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      email: user.email,
      password: user.password,
      email_confirm: true,
      user_metadata: { display_name: `P108 synthetic ${role}` },
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as JsonRecord;
  assert(
    response.ok && typeof body.id === "string",
    `synthetic ${role} Auth setup failed: HTTP ${response.status}`,
  );
  user.id = body.id;
  return user;
}

async function signIn(user: UserFixture): Promise<string> {
  const response = await fetch(`${authUrl}/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: user.email, password: user.password }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as JsonRecord;
  assert(
    response.ok && typeof body.access_token === "string",
    `synthetic password session failed: HTTP ${response.status}`,
  );
  return body.access_token;
}

async function rest(
  path: string,
  serviceToken: string,
  init: RequestInit = {},
): Promise<{ status: number; body?: unknown }> {
  const headers = new Headers(init.headers);
  headers.set("authorization", `Bearer ${serviceToken}`);
  headers.set("apikey", serviceToken);
  if (init.body !== undefined) headers.set("content-type", "application/json");
  const response = await fetch(`${restUrl}${path}`, {
    ...init,
    headers,
    signal: AbortSignal.timeout(10_000),
  });
  const body = response.status === 204
    ? undefined
    : await response.json().catch(() => undefined);
  return { status: response.status, body };
}

async function rpc(
  name: string,
  args: JsonRecord,
  token: string,
): Promise<{ status: number; body?: unknown }> {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => undefined),
  };
}

async function rows(path: string, serviceToken: string): Promise<JsonRecord[]> {
  const result = await rest(path, serviceToken);
  assert(
    result.status === 200 && Array.isArray(result.body),
    "fixture inspection failed",
  );
  return result.body as JsonRecord[];
}

Deno.test("group default TITLE_ONLY is honored through current-head Auth/API", async () => {
  assert(
    Deno.env.get("P108_WRAPPER") === "1",
    "run through the isolated P108 cleanup wrapper",
  );
  const serviceToken = await jwt("service_role");
  const users: UserFixture[] = [];
  const groupId = crypto.randomUUID();

  users.push(await createUser("owner", serviceToken));
  users.push(await createUser("member", serviceToken));
  const [owner, member] = users;
  console.log("fixture_auth_users=2");
  const ownerToken = await signIn(owner);
  const memberToken = await signIn(member);

  const groupSeed = await rest("/groups", serviceToken, {
    method: "POST",
    headers: { prefer: "return=minimal" },
    body: JSON.stringify({
      id: groupId,
      owner_user_id: owner.id,
      name: `P84 P108 synthetic ${crypto.randomUUID()}`,
      type: "other",
      default_visibility: "TITLE_ONLY",
      event_create_policy: "member",
    }),
  });
  assert(
    groupSeed.status === 201,
    `synthetic group setup failed: HTTP ${groupSeed.status}`,
  );
  console.log("fixture_group=seeded");

  const memberSeed = await rest("/group_members", serviceToken, {
    method: "POST",
    headers: { prefer: "return=minimal" },
    body: JSON.stringify([
      { group_id: groupId, user_id: owner.id, role: "owner" },
      { group_id: groupId, user_id: member.id, role: "member" },
    ]),
  });
  assert(
    memberSeed.status === 201,
    `synthetic group membership setup failed: HTTP ${memberSeed.status}`,
  );
  console.log("fixture_members=seeded");

  const created = await rpc("create_group_event", {
    p_group_id: groupId,
    p_title: titleCanary,
    p_start_at: startAt,
    p_end_at: endAt,
    p_location: locationCanary,
    p_description: descriptionCanary,
    p_operation_id: crypto.randomUUID(),
  }, ownerToken);
  const createdRows = created.body as JsonRecord[] | undefined;
  assert(
    created.status === 200 && Array.isArray(createdRows) &&
      typeof createdRows[0]?.event_id === "string",
    `owner group-event RPC failed: HTTP ${created.status}`,
  );
  const eventId = createdRows[0].event_id;
  console.log("owner_create_group_event=200");

  const persisted = await rows(
    `/events?id=eq.${
      encodeURIComponent(eventId)
    }&select=visibility_level,title,location,description`,
    serviceToken,
  );
  assert(
    persisted.length === 1 && persisted[0].visibility_level === "TITLE_ONLY",
    "created group event did not persist the configured group visibility",
  );
  console.log("persisted_visibility=TITLE_ONLY");

  const projection = await rpc("get_visible_events", {
    viewer_id: member.id,
    range_start: "2031-02-01T00:00:00Z",
    range_end: "2031-02-02T00:00:00Z",
  }, memberToken);
  const projectedRows = projection.body as JsonRecord[] | undefined;
  const projected = Array.isArray(projectedRows)
    ? projectedRows.find((row) => row.event_id === eventId)
    : undefined;
  assert(
    projection.status === 200 && projected !== undefined &&
      projected.visibility_level === "TITLE_ONLY" &&
      projected.title === titleCanary &&
      Date.parse(String(projected.start_at)) === Date.parse(startAt) &&
      Date.parse(String(projected.end_at)) === Date.parse(endAt) &&
      projected.location === null && projected.description === null &&
      projected.group_id === null,
    "member projection did not match the TITLE_ONLY contract",
  );
  const projectedJson = JSON.stringify(projection.body);
  assert(
    !projectedJson.includes(locationCanary) &&
      !projectedJson.includes(descriptionCanary),
    "member projection included a private field canary",
  );
  console.log(
    "member_projection=TITLE_ONLY; private_canaries_absent; DB/Auth cleanup delegated to wrapper",
  );
});
