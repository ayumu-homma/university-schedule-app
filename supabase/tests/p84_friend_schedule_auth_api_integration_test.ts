interface UserFixture {
  id: string;
  email: string;
  password: string;
}

interface Fixture {
  users: { owner: UserFixture; friend: UserFixture; outsider: UserFixture };
  anonKey: string;
  friendshipId: string;
  incarnation: string;
  calendarId: string;
  eventId: string;
}

interface Session {
  access_token?: unknown;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const fixture = JSON.parse(
  await Deno.readTextFile("/scratch/fixtures.json"),
) as Fixture;
const authUrl = "http://p84-share01-20260928-v12-auth:9999";
const restUrl = "http://p84-share01-20260928-v12-rest:3000";

async function signIn(user: UserFixture): Promise<string> {
  const response = await fetch(`${authUrl}/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: user.email, password: user.password }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as Session;
  assert(
    response.ok && typeof body.access_token === "string",
    `GoTrue sign-in failed: HTTP ${response.status}`,
  );
  return body.access_token;
}

async function rpc(
  name: string,
  accessToken: string,
  body: Record<string, unknown>,
): Promise<{ status: number; text: string; value: unknown; code?: string }> {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: fixture.anonKey,
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  let value: unknown = null;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error(`${name} returned non-JSON HTTP ${response.status}`);
  }
  const rawCode = (value as { code?: unknown } | null)?.code;
  const code = typeof rawCode === "string" && /^[A-Z0-9]{5,12}$/.test(rawCode)
    ? rawCode
    : undefined;
  return { status: response.status, text, value, code };
}

function items(value: unknown): Record<string, unknown>[] {
  const rows = (value as { rows?: { items?: unknown } } | null)?.rows?.items;
  assert(
    Array.isArray(rows),
    "friend schedule returned an invalid rows.items shape",
  );
  return rows as Record<string, unknown>[];
}

Deno.test("GoTrue friend session sees only the effective BUSY_ONLY schedule projection", async () => {
  const ownerToken = await signIn(fixture.users.owner);
  const friendToken = await signIn(fixture.users.friend);
  const outsiderToken = await signIn(fixture.users.outsider);
  const range = {
    p_range_start: "2030-11-10T00:00:00Z",
    p_range_end: "2030-11-11T00:00:00Z",
  };

  const fullControl = await rpc("get_friend_schedule", friendToken, {
    p_owner_user_id: fixture.users.owner.id,
    p_term_id: null,
    ...range,
  });
  assert(
    fullControl.status === 200,
    `accepted friend FULL control failed: HTTP ${fullControl.status}; code=${
      fullControl.code ?? "none"
    }`,
  );
  assert(
    items(fullControl.value).some((row) =>
      row.title === "P84 friend API canary title"
    ),
    "FULL positive control omitted its fixture event",
  );

  const setting = await rpc("set_friend_visibility", ownerToken, {
    p_friendship_id: fixture.friendshipId,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.users.friend.id,
    p_target_kind: "default",
    p_target_id: null,
    p_visibility_level: "BUSY_ONLY",
    p_expected_revision: null,
    p_operation_id: crypto.randomUUID(),
    p_target_value: null,
  });
  assert(
    setting.status === 200,
    "owner visibility update did not return HTTP 200",
  );

  const friendSchedule = await rpc("get_friend_schedule", friendToken, {
    p_owner_user_id: fixture.users.owner.id,
    p_term_id: null,
    ...range,
  });
  assert(
    friendSchedule.status === 200,
    "friend schedule did not return HTTP 200",
  );
  const friendRows = items(friendSchedule.value);
  assert(
    friendRows.length === 1,
    "BUSY_ONLY schedule did not return exactly one row",
  );
  assert(
    friendRows[0].visibility_level === "BUSY_ONLY" &&
      friendRows[0].title === "予定あり" &&
      friendRows[0].location === null &&
      friendRows[0].description === null,
    "BUSY_ONLY schedule projection exposed unexpected fields",
  );
  assert(
    !friendSchedule.text.includes("P84 friend API canary"),
    "friend schedule response contained a sensitive canary",
  );

  const direct = await rpc("get_visible_events", friendToken, {
    viewer_id: fixture.users.friend.id,
    range_start: range.p_range_start,
    range_end: range.p_range_end,
  });
  assert(
    direct.status === 200 && Array.isArray(direct.value),
    "direct event projection did not return an array with HTTP 200",
  );
  const directRows = direct.value as Record<string, unknown>[];
  const projected = directRows.filter((row) =>
    row.event_id === fixture.eventId
  );
  assert(
    projected.length === 1,
    "direct projection omitted the synthetic event",
  );
  assert(
    projected[0].visibility_level === "BUSY_ONLY" &&
      projected[0].title === "予定あり" &&
      projected[0].location === null &&
      projected[0].description === null,
    "direct projection exposed unexpected fields",
  );
  assert(
    !directRows.some((row) =>
      JSON.stringify(row).includes("P84 friend API canary")
    ),
    "direct projection contained a sensitive canary",
  );

  const outsiderSchedule = await rpc("get_friend_schedule", outsiderToken, {
    p_owner_user_id: fixture.users.owner.id,
    p_term_id: null,
    ...range,
  });
  assert(
    outsiderSchedule.status === 200,
    "unrelated authenticated schedule request did not return HTTP 200",
  );
  assert(
    items(outsiderSchedule.value).length === 0,
    "unrelated authenticated viewer received friend schedule rows",
  );

  console.log(
    "friend_api=full-control,busy-only-redaction,direct-projection,outsider-empty; bearer_values=omitted",
  );
});
