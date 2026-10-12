type Principal = { id: string; email: string; password: string };
type Fixture = {
  anon_key: string;
  group_id: string;
  users: { owner: Principal; member: Principal };
};
type RpcResponse = {
  status: number;
  code?: string;
  body: unknown;
  text: string;
};

const fixturePath = Deno.env.get("P150_FIXTURE_PATH");
if (!fixturePath) throw new Error("P150 fixture path unavailable");
const fixture = JSON.parse(await Deno.readTextFile(fixturePath)) as Fixture;
const apiUrl = "http://gateway:8000/rest/v1/rpc";

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
  const response = await fetch(`${apiUrl}/${name}`, {
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

Deno.test("P150 group availability refuses either side of a blocked member pair", async () => {
  const ownerToken = await accessToken(fixture.users.owner);
  const memberToken = await accessToken(fixture.users.member);
  const directions = [
    {
      viewer: fixture.users.owner,
      peer: fixture.users.member,
      token: ownerToken,
    },
    {
      viewer: fixture.users.member,
      peer: fixture.users.owner,
      token: memberToken,
    },
  ];

  for (const { viewer, peer, token } of directions) {
    const memberIds = [viewer.id, peer.id];
    const denied = await rpc("find_group_availability", {
      p_group_id: fixture.group_id,
      p_member_ids: memberIds,
      p_range_start: "2026-10-14T00:00:00Z",
      p_range_end: "2026-10-15T00:00:00Z",
      p_minimum_duration_minutes: 30,
    }, token);
    assert(
      denied.status === 403 && denied.code === "42501",
      "blocked pair availability search did not preserve the 403/42501 denial contract",
    );
    assert(
      !denied.text.includes(fixture.users.owner.id) &&
        !denied.text.includes(fixture.users.member.id) &&
        !denied.text.includes("P150 private schedule canary"),
      "denied availability response disclosed a member or schedule canary",
    );

    const validation = await rpc("validate_group_availability", {
      p_group_id: fixture.group_id,
      p_member_ids: memberIds,
      p_generation: "synthetic-stale-generation",
    }, token);
    const payload = validation.body as
      | { valid?: unknown; generation?: unknown }
      | null;
    assert(
      validation.status === 200 && payload?.valid === false &&
        payload.generation === null,
      "blocked pair availability validation did not fail closed",
    );
    assert(
      !validation.text.includes(fixture.users.owner.id) &&
        !validation.text.includes(fixture.users.member.id),
      "availability validation response disclosed a member identifier",
    );
  }

  console.log(
    "P150 both viewers: find_group_availability=2x403/42501; validate_group_availability=2x200/valid_false; no member identifiers or schedule canaries",
  );
});
