type Principal = { id: string; token: string };
type Fixture = {
  anon_key: string;
  owner: Principal;
  friend: Principal;
  incarnation: string;
  block_operation_id: string;
  set_visibility_operation_id: string;
  set_reverse_visibility_operation_id: string;
  friendship_id: string;
  owner_calendar_id: string;
  friend_calendar_id: string;
  owner_event_id: string;
  friend_event_id: string;
  cleanup_prefix: string;
};

type RpcResult = {
  status: number;
  body: unknown;
  text: string;
  code?: string;
};

const fixturePath = Deno.env.get("P134_FIXTURE_PATH");
if (!fixturePath) throw new Error("P134 private fixture path is missing");
const fixture = JSON.parse(await Deno.readTextFile(fixturePath)) as Fixture;
const apiUrl = "http://gateway:8000/rest/v1";
const range = {
  p_range_start: "2030-10-01T00:00:00Z",
  p_range_end: "2030-10-04T00:00:00Z",
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function rpc(
  name: string,
  args: Record<string, unknown>,
  token: string,
): Promise<RpcResult> {
  const response = await fetch(`${apiUrl}/rpc/${name}`, {
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
  const body = JSON.parse(text) as unknown;
  const rawCode = (body as { code?: unknown } | null)?.code;
  return {
    status: response.status,
    body,
    text,
    code: typeof rawCode === "string" ? rawCode : undefined,
  };
}

function items(result: RpcResult): Array<Record<string, unknown>> {
  const payload = result.body as {
    rows?: { items?: unknown };
    allowed?: unknown;
  } | null;
  assert(
    payload && Array.isArray(payload.rows?.items),
    "schedule rows shape changed",
  );
  return payload.rows.items as Array<Record<string, unknown>>;
}

Deno.test("P134 current get_friend_schedule denies either direction after block", async () => {
  const grant = await rpc("set_friend_visibility", {
    p_friendship_id: fixture.friendship_id,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.friend.id,
    p_target_kind: "default",
    p_target_id: null,
    p_visibility_level: "FULL",
    p_expected_revision: null,
    p_operation_id: fixture.set_visibility_operation_id,
    p_target_value: null,
  }, fixture.owner.token);
  assert(
    grant.status === 200,
    "owner could not establish the FULL positive control",
  );
  const reverseGrant = await rpc("set_friend_visibility", {
    p_friendship_id: fixture.friendship_id,
    p_incarnation: fixture.incarnation,
    p_friend_user_id: fixture.owner.id,
    p_target_kind: "default",
    p_target_id: null,
    p_visibility_level: "FULL",
    p_expected_revision: null,
    p_operation_id: fixture.set_reverse_visibility_operation_id,
    p_target_value: null,
  }, fixture.friend.token);
  assert(
    reverseGrant.status === 200,
    "friend could not establish the reverse FULL positive control",
  );

  const full = await rpc("get_friend_schedule", {
    p_owner_user_id: fixture.owner.id,
    p_term_id: null,
    ...range,
  }, fixture.friend.token);
  assert(
    full.status === 200,
    "accepted friend baseline did not return HTTP 200",
  );
  assert(
    (full.body as { allowed?: unknown }).allowed === true,
    "accepted friendship was denied before a block existed",
  );
  assert(
    items(full).some((row) => row.title === "P134 owner block canary"),
    "friend FULL baseline omitted owner fixture canary",
  );

  const reverse = await rpc("get_friend_schedule", {
    p_owner_user_id: fixture.friend.id,
    p_term_id: null,
    ...range,
  }, fixture.owner.token);
  assert(reverse.status === 200, "reverse accepted-friend baseline failed");
  assert(
    (reverse.body as { allowed?: unknown }).allowed === true &&
      items(reverse).some((row) => row.title === "P134 friend block canary"),
    "reverse baseline did not expose the friend’s own FULL fixture to its friend",
  );

  const blocked = await rpc("block_user", {
    p_user_id: fixture.friend.id,
    p_operation_id: fixture.block_operation_id,
  }, fixture.owner.token);
  assert(
    blocked.status === 200 &&
      (blocked.body as { blocked?: unknown }).blocked === true,
    "owner block action did not return the current block contract",
  );

  const blockedFriendView = await rpc("get_friend_schedule", {
    p_owner_user_id: fixture.owner.id,
    p_term_id: null,
    ...range,
  }, fixture.friend.token);
  assert(
    blockedFriendView.status === 200 &&
      (blockedFriendView.body as { allowed?: unknown }).allowed === false &&
      items(blockedFriendView).length === 0,
    "viewer was not denied the blocker’s schedule after the block",
  );
  assert(
    !blockedFriendView.text.includes("P134 owner block canary"),
    "blocked friend response contained the owner canary",
  );

  const blockedOwnerView = await rpc("get_friend_schedule", {
    p_owner_user_id: fixture.friend.id,
    p_term_id: null,
    ...range,
  }, fixture.owner.token);
  assert(
    blockedOwnerView.status === 200 &&
      (blockedOwnerView.body as { allowed?: unknown }).allowed === false &&
      items(blockedOwnerView).length === 0,
    "blocker was not denied the blocked user’s schedule after the block",
  );
  assert(
    !blockedOwnerView.text.includes("P134 friend block canary"),
    "blocker response contained the friend canary",
  );

  console.log(
    "accepted_friend_controls=2x200/allowed;owner_block_user=200/blocked;blocked_get_friend_schedule=2x200/allowed_false/empty;canaries=absent",
  );
});
