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
const authUrl = "http://p84-share01-20260928-v15-auth:9999";
const restUrl = "http://p84-share01-20260928-v15-rest:3000";
const titleCanary = "P103 TITLE_ONLY API title canary";
const locationCanary = "P103 TITLE_ONLY API location canary";
const descriptionCanary = "P103 TITLE_ONLY API description canary";
const range = {
  p_range_start: "2031-06-02T00:00:00Z",
  p_range_end: "2031-06-03T00:00:00Z",
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

async function rpc(
  name: string,
  token: string,
  body: Record<string, unknown>,
) {
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

function scheduleItems(value: unknown): Record<string, unknown>[] {
  const items = (value as { rows?: { items?: unknown } } | null)?.rows?.items;
  assert(Array.isArray(items), "friend preview returned invalid rows.items");
  return items as Record<string, unknown>[];
}

function assertNoCanaries(text: string, scope: string): void {
  assert(
    !text.includes(locationCanary) && !text.includes(descriptionCanary),
    `${scope} contained a private event canary`,
  );
}

Deno.test("GoTrue friend receives event TITLE_ONLY over relationship FULL", async () => {
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
  const beforeEvent = scheduleItems(beforePreview.value).find((item) =>
    item.title === titleCanary
  );
  assert(
    beforeEvent?.visibility_level === "FULL" &&
      beforeEvent.location === locationCanary &&
      beforeEvent.description === descriptionCanary &&
      String(beforeEvent.start_at).startsWith("2031-06-02T01:00:00") &&
      String(beforeEvent.end_at).startsWith("2031-06-02T02:00:00") &&
      beforeEvent.kind === "normal",
    "FULL preview control omitted expected fields",
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
  const directBefore = (beforeDirect.value as Record<string, unknown>[]).find(
    (row) => row.event_id === fixture.eventId,
  );
  assert(
    directBefore?.visibility_level === "FULL" &&
      directBefore.location === locationCanary &&
      directBefore.description === descriptionCanary &&
      String(directBefore.start_at).startsWith("2031-06-02T01:00:00") &&
      String(directBefore.end_at).startsWith("2031-06-02T02:00:00") &&
      directBefore.kind === "normal",
    "FULL direct control omitted expected fields",
  );

  const mutation = await rpc("set_friend_visibility", ownerToken, {
    p_friendship_id: fixture.friendshipId,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.friend.id,
    p_target_kind: "event",
    p_target_id: fixture.eventId,
    p_visibility_level: "TITLE_ONLY",
    p_expected_revision: null,
    p_operation_id: crypto.randomUUID(),
    p_target_value: null,
  });
  assert(mutation.status === 200, "owner event TITLE_ONLY update failed");

  const afterPreview = await rpc(
    "preview_friend_schedule",
    ownerToken,
    previewArgs,
  );
  assert(afterPreview.status === 200, "TITLE_ONLY preview failed");
  const previewEvent = scheduleItems(afterPreview.value).find((item) =>
    item.title === titleCanary
  );
  assert(
    previewEvent?.visibility_level === "TITLE_ONLY" &&
      previewEvent.location === null && previewEvent.description === null &&
      String(previewEvent.start_at).startsWith("2031-06-02T01:00:00") &&
      String(previewEvent.end_at).startsWith("2031-06-02T02:00:00") &&
      previewEvent.kind === "normal" && !Object.hasOwn(previewEvent, "url"),
    "preview did not preserve title while removing private fields",
  );
  assertNoCanaries(afterPreview.text, "TITLE_ONLY preview");

  const afterDirect = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    afterDirect.status === 200 && Array.isArray(afterDirect.value),
    "TITLE_ONLY direct projection failed",
  );
  const directEvent = (afterDirect.value as Record<string, unknown>[]).find(
    (row) => row.event_id === fixture.eventId,
  );
  assert(
    directEvent?.visibility_level === "TITLE_ONLY" &&
      directEvent.title === titleCanary && directEvent.location === null &&
      directEvent.description === null &&
      String(directEvent.start_at).startsWith("2031-06-02T01:00:00") &&
      String(directEvent.end_at).startsWith("2031-06-02T02:00:00") &&
      directEvent.kind === "normal" && !Object.hasOwn(directEvent, "url"),
    "direct projection did not apply TITLE_ONLY fields",
  );
  assertNoCanaries(afterDirect.text, "TITLE_ONLY direct projection");
  console.log(
    "title_only_api=full-controls,owner-mutation,friend-preview,direct-redaction; bearer_and_private_canaries=omitted",
  );
});
