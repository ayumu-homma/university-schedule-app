const authUrl = "http://p84-share01-20260928-v15-auth:9999";
const restUrl = "http://p84-share01-20260928-v15-rest:3000";

type CreatedUser = { id: string; email: string; password: string };
type JsonRecord = Record<string, unknown>;

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function serviceRoleToken(): Promise<string> {
  const secret = Deno.env.get("PGRST_JWT_SECRET");
  assert(secret, "isolated signing input unavailable");
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(
    new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" })),
  );
  const payload = base64Url(new TextEncoder().encode(JSON.stringify({
    iss: "supabase",
    role: "service_role",
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

async function createUser(role: "owner" | "outsider", adminToken: string) {
  const suffix = crypto.randomUUID();
  const user: CreatedUser = {
    id: "",
    email: `p84-p107-${role}-${suffix}@example.invalid`,
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
      user_metadata: { display_name: `P84 synthetic ${role}` },
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as JsonRecord;
  assert(
    response.ok && typeof body.id === "string",
    `synthetic ${role} fixture creation failed: HTTP ${response.status}`,
  );
  user.id = body.id;
  return user;
}

async function signIn(user: CreatedUser): Promise<string> {
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

async function rpc(
  name: string,
  args: JsonRecord,
  token?: string,
): Promise<{ status: number; code?: string; body?: unknown }> {
  const headers = new Headers({ "content-type": "application/json" });
  if (token) headers.set("authorization", `Bearer ${token}`);
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => undefined) as
    | JsonRecord
    | undefined;
  const code = typeof body?.code === "string" && /^[A-Z0-9_]+$/.test(body.code)
    ? body.code
    : undefined;
  return { status: response.status, code, body };
}

Deno.test("current-head group availability rejects authenticated nonmembers", async () => {
  const adminToken = await serviceRoleToken();
  const users: CreatedUser[] = [];
  let groupId: string | undefined;
  let failure: unknown;

  try {
    users.push(await createUser("owner", adminToken));
    users.push(await createUser("outsider", adminToken));
    const [owner, outsider] = users;
    const ownerToken = await signIn(owner);
    const outsiderToken = await signIn(outsider);

    const createdGroup = await rpc("create_group", {
      p_name: `P84 P107 synthetic ${crypto.randomUUID()}`,
      p_type: "other",
      p_event_create_policy: "owner",
      p_operation_id: crypto.randomUUID(),
    }, ownerToken);
    const groupRow = (createdGroup.body as JsonRecord[] | undefined)?.[0];
    assert(
      createdGroup.status === 200 && typeof groupRow?.group_id === "string",
      `synthetic owner group setup failed: HTTP ${createdGroup.status}`,
    );
    groupId = groupRow.group_id;

    const sharedArgs = {
      p_group_id: groupId,
      p_member_ids: [owner.id],
      p_range_start: "2030-10-03T00:00:00Z",
      p_range_end: "2030-10-04T00:00:00Z",
      p_minimum_duration_minutes: 30,
    };
    const ownerControl = await rpc(
      "find_group_availability",
      sharedArgs,
      ownerToken,
    );
    assert(
      ownerControl.status === 200 &&
        typeof (ownerControl.body as JsonRecord | undefined)?.query_id ===
          "string",
      `owner positive control failed: HTTP ${ownerControl.status}`,
    );

    const outsiderMemberRequest = await rpc(
      "find_group_availability",
      sharedArgs,
      outsiderToken,
    );
    assert(
      outsiderMemberRequest.status === 403 &&
        outsiderMemberRequest.code === "42501",
      `authenticated nonmember denial differed: HTTP ${outsiderMemberRequest.status}; SQLSTATE=${
        outsiderMemberRequest.code ?? "none"
      }`,
    );

    const outsiderSelfRequest = await rpc(
      "find_group_availability",
      { ...sharedArgs, p_member_ids: [outsider.id] },
      outsiderToken,
    );
    assert(
      outsiderSelfRequest.status === 403 && outsiderSelfRequest.code ===
          "42501",
      `nonmember self-selection denial differed: HTTP ${outsiderSelfRequest.status}; SQLSTATE=${
        outsiderSelfRequest.code ?? "none"
      }`,
    );

    const anonymousRequest = await rpc(
      "find_group_availability",
      sharedArgs,
    );
    assert(
      anonymousRequest.status === 401 && anonymousRequest.code === "42501",
      `anonymous denial differed: HTTP ${anonymousRequest.status}; SQLSTATE=${
        anonymousRequest.code ?? "none"
      }`,
    );
  } catch (error) {
    failure = error;
  } finally {
    if (groupId) {
      try {
        const response = await fetch(
          `${restUrl}/groups?id=eq.${encodeURIComponent(groupId)}&select=id`,
          {
            method: "DELETE",
            headers: {
              authorization: `Bearer ${adminToken}`,
              apikey: adminToken,
              prefer: "return=representation",
            },
            signal: AbortSignal.timeout(10_000),
          },
        );
        const deleted = await response.json().catch(() => undefined) as
          | unknown[]
          | undefined;
        assert(
          response.ok && Array.isArray(deleted) && deleted.length === 1,
          `synthetic group cleanup failed: HTTP ${response.status}`,
        );
      } catch {
        failure = new Error("synthetic group cleanup was not confirmed");
      }
    }
    for (const user of users) {
      if (!user.id) continue;
      try {
        const response = await fetch(`${authUrl}/admin/users/${user.id}`, {
          method: "DELETE",
          headers: {
            authorization: `Bearer ${adminToken}`,
            apikey: adminToken,
          },
          signal: AbortSignal.timeout(10_000),
        });
        assert(
          response.ok,
          `synthetic Auth cleanup failed: HTTP ${response.status}`,
        );
      } catch {
        failure = new Error("synthetic Auth cleanup was not confirmed");
      }
    }
  }

  if (failure) throw failure;
  console.log(
    "owner_positive=200; authenticated_nonmember=403/42501; nonmember_self=403/42501; anonymous=401/42501; synthetic_cleanup=committed",
  );
});
