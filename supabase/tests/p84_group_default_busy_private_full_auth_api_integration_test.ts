type JsonRecord = Record<string, unknown>;
type UserFixture = { id: string; email: string; password: string };

const authUrl = "http://p84-share01-20260928-v15-auth:9999";
const restUrl = "http://p84-share01-20260928-v15-rest:3000";
const fullTitle = "P109 full event title";
const fullLocation = "P109 full location canary";
const fullDescription = "P109 full description canary";
const busyTitleCanary = "P109 busy title canary";
const busyLocation = "P109 busy location canary";
const busyDescription = "P109 busy description canary";
const privateTitle = "P109 private event canary";
const privateLocation = "P109 private location canary";
const privateDescription = "P109 private description canary";
const rangeStart = "2032-04-01T00:00:00Z";
const rangeEnd = "2032-04-02T00:00:00Z";

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
    email: `p84-p109-${role}-${suffix}@example.invalid`,
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
      user_metadata: { display_name: `P109 synthetic ${role}` },
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

Deno.test("group BUSY_ONLY, PRIVATE, and FULL defaults use current-head Auth/API projection", async () => {
  assert(
    Deno.env.get("P109_WRAPPER") === "1",
    "run through isolated P109 cleanup wrapper",
  );
  const serviceToken = await jwt("service_role");
  const owner = await createUser("owner", serviceToken);
  const member = await createUser("member", serviceToken);
  const ownerToken = await signIn(owner);
  const memberToken = await signIn(member);
  const groupId = crypto.randomUUID();

  const groupSeed = await rest("/groups", serviceToken, {
    method: "POST",
    headers: { prefer: "return=minimal" },
    body: JSON.stringify({
      id: groupId,
      owner_user_id: owner.id,
      name: `P84 P109 synthetic ${crypto.randomUUID()}`,
      type: "other",
      default_visibility: "FULL",
      event_create_policy: "member",
    }),
  });
  assert(
    groupSeed.status === 201,
    `synthetic group setup failed: HTTP ${groupSeed.status}`,
  );

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

  const createdEventIds: string[] = [];
  const create = async (
    title: string,
    location: string,
    description: string,
    hour: number,
  ): Promise<string> => {
    const created = await rpc("create_group_event", {
      p_group_id: groupId,
      p_title: title,
      p_start_at: `2032-04-01T${String(hour).padStart(2, "0")}:00:00Z`,
      p_end_at: `2032-04-01T${String(hour + 1).padStart(2, "0")}:00:00Z`,
      p_location: location,
      p_description: description,
      p_operation_id: crypto.randomUUID(),
    }, ownerToken);
    const result = created.body as JsonRecord[] | undefined;
    assert(
      created.status === 200 && Array.isArray(result) &&
        typeof result[0]?.event_id === "string",
      `owner group-event RPC failed: HTTP ${created.status}`,
    );
    createdEventIds.push(result[0].event_id);
    return result[0].event_id;
  };

  const fullEventId = await create(fullTitle, fullLocation, fullDescription, 1);

  for (
    const [level, title, location, description, hour] of [
      ["BUSY_ONLY", busyTitleCanary, busyLocation, busyDescription, 3],
      ["PRIVATE", privateTitle, privateLocation, privateDescription, 5],
    ] as const
  ) {
    const groupUpdate = await rest(
      `/groups?id=eq.${encodeURIComponent(groupId)}`,
      serviceToken,
      { method: "PATCH", body: JSON.stringify({ default_visibility: level }) },
    );
    assert(
      groupUpdate.status === 204,
      `synthetic group visibility update failed: HTTP ${groupUpdate.status}`,
    );
    const calendarUpdate = await rest(
      `/calendars?group_id=eq.${encodeURIComponent(groupId)}`,
      serviceToken,
      { method: "PATCH", body: JSON.stringify({ default_visibility: level }) },
    );
    assert(
      calendarUpdate.status === 204,
      `synthetic calendar visibility update failed: HTTP ${calendarUpdate.status}`,
    );
    await create(title, location, description, hour);
  }

  const stored = await rows(
    `/events?group_id=eq.${
      encodeURIComponent(groupId)
    }&select=id,visibility_level`,
    serviceToken,
  );
  assert(
    stored.length === 3 &&
      stored.every((row) =>
        typeof row.id === "string" && typeof row.visibility_level === "string"
      ),
    "current-head group events did not persist all three configured defaults",
  );
  const storedById = new Map(
    stored.map((row) => [String(row.id), row.visibility_level]),
  );
  assert(
    storedById.get(fullEventId) === "FULL" &&
      storedById.get(createdEventIds[1]) === "BUSY_ONLY" &&
      storedById.get(createdEventIds[2]) === "PRIVATE",
    "created group events did not persist each configured default",
  );

  const projection = await rpc("get_visible_events", {
    viewer_id: member.id,
    range_start: rangeStart,
    range_end: rangeEnd,
  }, memberToken);
  const projectedRows = projection.body as JsonRecord[] | undefined;
  assert(
    projection.status === 200 && Array.isArray(projectedRows),
    "member projection request failed",
  );
  const full = projectedRows.find((row) => row.event_id === fullEventId);
  const busy = projectedRows.find((row) =>
    row.title === "予定あり" && row.visibility_level === "BUSY_ONLY"
  );
  const privateIsAbsent = !projectedRows.some((row) =>
    row.title === privateTitle || row.location === privateLocation ||
    row.description === privateDescription
  );
  assert(
    full?.visibility_level === "FULL" && full.title === fullTitle &&
      full.location === fullLocation && full.description === fullDescription &&
      full.group_id === groupId,
    "FULL group-default projection did not retain its configured details",
  );
  assert(
    busy !== undefined && busy.location === null && busy.description === null &&
      busy.kind === null && busy.group_id === null &&
      busy.visibility_level === "BUSY_ONLY",
    "BUSY_ONLY group-default projection included detail fields",
  );
  assert(
    privateIsAbsent,
    "PRIVATE group-default projection exposed an event or canary",
  );
  const projectionJson = JSON.stringify(projection.body);
  assert(
    !projectionJson.includes(busyTitleCanary) &&
      !projectionJson.includes(busyLocation) &&
      !projectionJson.includes(busyDescription) &&
      !projectionJson.includes(privateTitle) &&
      !projectionJson.includes(privateLocation) &&
      !projectionJson.includes(privateDescription),
    "BUSY_ONLY or PRIVATE canary appeared in the member projection",
  );

  console.log(
    "owner_group_event_create=3x200; persisted_defaults=FULL,BUSY_ONLY,PRIVATE; member_projection=FULL-details,BUSY_ONLY-opaque,PRIVATE-absent; cleanup=delegated-to-container-psql-wrapper",
  );
});
