interface TestUser {
  id: string;
  email: string;
  password: string;
}

interface Fixture {
  owner: TestUser;
  friend: TestUser;
  anonKey: string;
  friendshipId: string;
  incarnation: string;
  calendarId: string;
  eventId: string;
  seedSql: string;
  cleanupSql: string;
}

interface TokenResponse {
  access_token?: unknown;
}

const fixture = JSON.parse(
  await Deno.readTextFile("/scratch/fixtures.json"),
) as Fixture;
const authUrl = "http://p84-share01-20260928-v13-auth:9999";
const restUrl = "http://p84-share01-20260928-v13-rest:3000";
const titleCanary = "P97 private API title canary";
const locationCanary = "P97 private API location canary";
const descriptionCanary = "P97 private API description canary";
const range = {
  p_range_start: "2031-05-01T00:00:00Z",
  p_range_end: "2031-05-02T00:00:00Z",
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function signIn(user: TestUser): Promise<string> {
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
): Promise<{ status: number; text: string; value: unknown }> {
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
  assert(
    Array.isArray(items),
    "preview_friend_schedule returned invalid rows.items",
  );
  return items as Record<string, unknown>[];
}

function assertNoCanaries(text: string, scope: string): void {
  assert(
    !text.includes(titleCanary) && !text.includes(locationCanary) &&
      !text.includes(descriptionCanary),
    `${scope} response contained a sensitive event canary`,
  );
}

Deno.test("GoTrue friend sees FULL positive control then event PRIVATE is omitted from both projections", async () => {
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
  assert(
    beforePreview.status === 200,
    "friend preview positive control failed",
  );
  const beforeItems = scheduleItems(beforePreview.value);
  const beforeEvent = beforeItems.find((item) => item.title === titleCanary);
  assert(beforeEvent, "FULL positive control omitted the event from preview");
  assert(
    beforeEvent.visibility_level === "FULL" &&
      beforeEvent.location === locationCanary &&
      beforeEvent.description === descriptionCanary,
    "FULL preview positive control did not contain expected event fields",
  );

  const beforeDirect = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    beforeDirect.status === 200 && Array.isArray(beforeDirect.value),
    "direct projection positive control did not return an array",
  );
  const directBefore = beforeDirect.value as Record<string, unknown>[];
  const directEvent = directBefore.find((item) =>
    item.event_id === fixture.eventId
  );
  assert(
    directEvent,
    "FULL positive control omitted the event from direct projection",
  );
  assert(
    directEvent.visibility_level === "FULL" &&
      directEvent.location === locationCanary &&
      directEvent.description === descriptionCanary,
    "FULL direct projection positive control did not contain expected fields",
  );

  const mutation = await rpc("set_friend_visibility", ownerToken, {
    p_friendship_id: fixture.friendshipId,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.friend.id,
    p_target_kind: "event",
    p_target_id: fixture.eventId,
    p_visibility_level: "PRIVATE",
    p_expected_revision: null,
    p_operation_id: crypto.randomUUID(),
    p_target_value: null,
  });
  assert(mutation.status === 200, "owner event PRIVATE update failed");

  const afterPreview = await rpc(
    "preview_friend_schedule",
    ownerToken,
    previewArgs,
  );
  assert(afterPreview.status === 200, "friend preview after PRIVATE failed");
  const afterItems = scheduleItems(afterPreview.value);
  assert(
    !afterItems.some((item) => item.title === titleCanary),
    "event-specific PRIVATE remained visible in friend preview",
  );
  assertNoCanaries(afterPreview.text, "friend preview");

  const afterDirect = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    afterDirect.status === 200 && Array.isArray(afterDirect.value),
    "direct projection after PRIVATE did not return an array",
  );
  const directAfter = afterDirect.value as Record<string, unknown>[];
  assert(
    !directAfter.some((item) => item.event_id === fixture.eventId),
    "event-specific PRIVATE remained visible in direct projection",
  );
  assertNoCanaries(afterDirect.text, "direct event projection");

  console.log(
    "private_event_api=full-positive-control,friend-preview-omitted,direct-projection-omitted; bearer_and_canary_values=omitted",
  );
});
