const authUrl = "http://p84-share01-20260928-v12-auth:9999";
const restUrl = "http://p84-share01-20260928-v12-rest:3000";
const scratchPath = "/scratch/auth-fixtures.json";
const groupId = "8c843100-8400-4200-8400-000000000001";
const eventId = "8e843100-8400-4200-8400-000000000001";

type UserFixture = { id: string; email: string; password: string };
type ErrorBody = { code?: unknown };

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function signIn(user: UserFixture): Promise<string> {
  const response = await fetch(`${authUrl}/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: user.email, password: user.password }),
  });
  const result = await response.json().catch(() => ({})) as {
    access_token?: unknown;
  };
  assert(
    response.ok && typeof result.access_token === "string",
    `GoTrue password session failed: HTTP ${response.status}`,
  );
  return result.access_token;
}

async function rpc(
  name: string,
  args: Record<string, unknown>,
  token?: string,
): Promise<{ status: number; body: unknown; code?: string }> {
  const headers = new Headers({ "content-type": "application/json" });
  if (token) headers.set("authorization", `Bearer ${token}`);
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  const body = await response.json().catch(() => undefined) as
    | ErrorBody
    | unknown;
  const candidate = (body as ErrorBody | undefined)?.code;
  return {
    status: response.status,
    body,
    code: typeof candidate === "string" && /^[A-Z0-9_]+$/.test(candidate)
      ? candidate
      : undefined,
  };
}

Deno.test("SHARE-01 group scope through GoTrue sessions and local REST", async () => {
  const users = JSON.parse(await Deno.readTextFile(scratchPath)) as {
    owner: UserFixture;
    member: UserFixture;
    outsider: UserFixture;
  };
  const ownerToken = await signIn(users.owner);
  const memberToken = await signIn(users.member);
  const outsiderToken = await signIn(users.outsider);

  const memberList = await rpc("list_group_events", {
    p_group_id: groupId,
  }, memberToken);
  assert(
    memberList.status === 200,
    "group member list request was not allowed",
  );
  assert(
    Array.isArray(memberList.body),
    "group member list response was not an array",
  );
  assert(
    memberList.body.length === 1,
    "group member did not see the fixture event",
  );
  assert(
    (memberList.body[0] as { event_id?: string }).event_id === eventId,
    "group member received a different event",
  );

  const ownerAvailability = await rpc("find_group_availability", {
    p_group_id: groupId,
    p_member_ids: [users.owner.id, users.member.id],
    p_range_start: "2030-10-03T00:00:00Z",
    p_range_end: "2030-10-04T00:00:00Z",
    p_minimum_duration_minutes: 30,
  }, ownerToken);
  assert(
    ownerAvailability.status === 200,
    "group member availability request was denied",
  );
  assert(
    typeof (ownerAvailability.body as { query_id?: unknown })?.query_id ===
      "string",
    "authorized availability response omitted query identity",
  );

  const outsiderList = await rpc("list_group_events", {
    p_group_id: groupId,
  }, outsiderToken);
  assert(
    outsiderList.status === 403 && outsiderList.code === "42501",
    "owner's nonmember friend was not denied group event listing",
  );

  const outsiderVisible = await rpc("get_visible_events", {
    viewer_id: users.outsider.id,
    range_start: "2030-10-03T00:00:00Z",
    range_end: "2030-10-04T00:00:00Z",
  }, outsiderToken);
  assert(
    outsiderVisible.status === 200,
    "authenticated group projection request failed",
  );
  assert(
    Array.isArray(outsiderVisible.body) && outsiderVisible.body.length === 0,
    "group event leaked to the owner's nonmember friend",
  );

  const outsiderSelectedMember = await rpc("find_group_availability", {
    p_group_id: groupId,
    p_member_ids: [users.owner.id],
    p_range_start: "2030-10-03T00:00:00Z",
    p_range_end: "2030-10-04T00:00:00Z",
    p_minimum_duration_minutes: 30,
  }, outsiderToken);
  assert(
    outsiderSelectedMember.status === 403 &&
      outsiderSelectedMember.code === "42501",
    "nonmember friend was not denied availability for valid group members",
  );

  const outsiderSelectedSelf = await rpc("find_group_availability", {
    p_group_id: groupId,
    p_member_ids: [users.outsider.id],
    p_range_start: "2030-10-03T00:00:00Z",
    p_range_end: "2030-10-04T00:00:00Z",
    p_minimum_duration_minutes: 30,
  }, outsiderToken);
  assert(
    outsiderSelectedSelf.status === 403 &&
      outsiderSelectedSelf.code === "42501",
    "nonmember friend was not denied availability when selecting their own ID",
  );

  const anonymousAvailability = await rpc("find_group_availability", {
    p_group_id: groupId,
    p_member_ids: [users.owner.id],
    p_range_start: "2030-10-03T00:00:00Z",
    p_range_end: "2030-10-04T00:00:00Z",
    p_minimum_duration_minutes: 30,
  });
  assert(
    anonymousAvailability.status === 401 &&
      anonymousAvailability.code === "42501",
    `anonymous availability denial differed: HTTP ${anonymousAvailability.status}; code=${
      anonymousAvailability.code ?? "none"
    }`,
  );

  console.log(
    "group_member_list=200/1; owner_availability=200; outsider_list=403/42501; outsider_visible_rows=0; outsider_availability=2x403/42501; anonymous_availability=401/42501",
  );
});
