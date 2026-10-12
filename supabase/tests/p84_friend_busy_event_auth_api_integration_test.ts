interface User {
  id: string;
  email: string;
  password: string;
}
interface Fixture {
  owner: User;
  friend: User;
  anonKey: string;
  friendshipId: string;
  incarnation: string;
  eventId: string;
}
interface TokenResponse {
  access_token?: unknown;
}

const fixture = JSON.parse(
  await Deno.readTextFile("/scratch/fixtures.json"),
) as Fixture;
const authUrl = "http://p84-share01-20260928-v13-auth:9999";
const restUrl = "http://p84-share01-20260928-v13-rest:3000";
const titleCanary = "P98 BUSY API title canary";
const locationCanary = "P98 BUSY API location canary";
const descriptionCanary = "P98 BUSY API description canary";
const range = {
  p_range_start: "2031-05-01T00:00:00Z",
  p_range_end: "2031-05-02T00:00:00Z",
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function signIn(user: User): Promise<string> {
  const response = await fetch(`${authUrl}/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: user.email, password: user.password }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as TokenResponse;
  assert(
    response.ok && typeof body.access_token === "string",
    `synthetic GoTrue sign-in failed: HTTP ${response.status}`,
  );
  return body.access_token;
}

async function rpc(name: string, token: string, body: Record<string, unknown>) {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: fixture.anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error(`${name} returned non-JSON HTTP ${response.status}`);
  }
  return { status: response.status, text, value };
}

function items(value: unknown): Record<string, unknown>[] {
  const rows = (value as { rows?: { items?: unknown } } | null)?.rows?.items;
  assert(
    Array.isArray(rows),
    "preview_friend_schedule returned invalid rows.items",
  );
  return rows as Record<string, unknown>[];
}

function assertNoCanaries(text: string, where: string): void {
  assert(
    !text.includes(titleCanary) && !text.includes(locationCanary) &&
      !text.includes(descriptionCanary),
    `${where} contained a sensitive canary`,
  );
}

Deno.test("GoTrue friend receives only BUSY_ONLY for event-specific restriction over FULL", async () => {
  const ownerToken = await signIn(fixture.owner);
  const friendToken = await signIn(fixture.friend);
  const previewArgs = {
    p_friend_user_id: fixture.friend.id,
    p_term_id: null,
    ...range,
  };
  const beforePreview = await rpc(
    "preview_friend_schedule",
    ownerToken,
    previewArgs,
  );
  assert(beforePreview.status === 200, "FULL preview control failed");
  const beforeEvent = items(beforePreview.value).find((item) =>
    item.title === titleCanary
  );
  assert(
    beforeEvent?.visibility_level === "FULL" &&
      beforeEvent.location === locationCanary &&
      beforeEvent.description === descriptionCanary,
    "FULL preview control did not expose expected test-only fields",
  );
  const beforeDirect = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    beforeDirect.status === 200 && Array.isArray(beforeDirect.value),
    "FULL direct projection control failed",
  );
  const fullEvent = (beforeDirect.value as Record<string, unknown>[])
    .find((row) => row.event_id === fixture.eventId);
  assert(
    fullEvent?.visibility_level === "FULL" &&
      fullEvent.location === locationCanary &&
      fullEvent.description === descriptionCanary,
    "FULL direct control omitted expected fields",
  );

  const mutation = await rpc("set_friend_visibility", ownerToken, {
    p_friendship_id: fixture.friendshipId,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.friend.id,
    p_target_kind: "event",
    p_target_id: fixture.eventId,
    p_visibility_level: "BUSY_ONLY",
    p_expected_revision: null,
    p_operation_id: crypto.randomUUID(),
    p_target_value: null,
  });
  assert(mutation.status === 200, "owner event BUSY_ONLY update failed");

  const preview = await rpc("preview_friend_schedule", ownerToken, previewArgs);
  assert(preview.status === 200, "BUSY_ONLY friend preview failed");
  const busyRows = items(preview.value).filter((item) =>
    item.visibility_level === "BUSY_ONLY"
  );
  const previewEvent = busyRows.find((item) =>
    String(item.start_at).startsWith("2031-05-01T01:00:00") &&
    String(item.end_at).startsWith("2031-05-01T02:00:00")
  );
  assert(
    previewEvent?.visibility_level === "BUSY_ONLY" &&
      previewEvent.title === "予定あり" && previewEvent.location === null &&
      previewEvent.description === null,
    "preview did not redact event to BUSY_ONLY",
  );
  assertNoCanaries(preview.text, "BUSY_ONLY preview");

  const direct = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    direct.status === 200 && Array.isArray(direct.value),
    "BUSY_ONLY direct projection failed",
  );
  const directRows = (direct.value as Record<string, unknown>[])
    .filter((row) => row.event_id === fixture.eventId);
  assert(
    directRows.length === 1 && directRows[0].visibility_level === "BUSY_ONLY" &&
      directRows[0].title === "予定あり" && directRows[0].location === null &&
      directRows[0].description === null,
    "direct projection did not redact event to BUSY_ONLY",
  );
  assertNoCanaries(direct.text, "BUSY_ONLY direct projection");
  console.log(
    "busy_event_api=full-controls,busy-only-preview,direct-redaction; bearer_and_canary_values=omitted",
  );
});
