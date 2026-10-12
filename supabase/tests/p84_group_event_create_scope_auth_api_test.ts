type JsonRecord = Record<string, unknown>;
type UserFixture = { id: string; email: string; password: string };

const stack = "p84-share01-20260928-v15";
const authUrl = `http://${stack}-auth:9999`;
const restUrl = `http://${stack}-rest:3000`;
const titleCanary = "P110 denied group event canary";
const eventStart = "2032-05-01T01:00:00Z";
const eventEnd = "2032-05-01T02:00:00Z";

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

async function createUser(role: "owner" | "outsider", adminToken: string) {
  const user: UserFixture = {
    id: "",
    email: `p84-p110-${role}-${crypto.randomUUID()}@example.invalid`,
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
      user_metadata: { display_name: `P110 synthetic ${role}` },
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

async function rpc(
  name: string,
  args: JsonRecord,
  token: string,
): Promise<{ status: number; code?: string; body?: unknown }> {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => undefined);
  return {
    status: response.status,
    code: (body as JsonRecord | undefined)?.code as string | undefined,
    body,
  };
}

async function eventCount(
  groupId: string,
  serviceToken: string,
): Promise<number> {
  const response = await fetch(
    `${restUrl}/events?group_id=eq.${
      encodeURIComponent(groupId)
    }&kind=eq.group&select=id`,
    {
      headers: {
        authorization: `Bearer ${serviceToken}`,
        apikey: serviceToken,
      },
      signal: AbortSignal.timeout(10_000),
    },
  );
  const body = await response.json().catch(() => undefined);
  assert(
    response.status === 200 && Array.isArray(body),
    "event count inspection failed",
  );
  return body.length;
}

Deno.test("group event creation enforces current-head API scope", async () => {
  assert(
    Deno.env.get("P110_WRAPPER") === "1",
    "run through isolated P110 cleanup wrapper",
  );
  const serviceToken = await jwt("service_role");
  const anonToken = await jwt("anon");
  const owner = await createUser("owner", serviceToken);
  const outsider = await createUser("outsider", serviceToken);
  const ownerToken = await signIn(owner);
  const outsiderToken = await signIn(outsider);

  const group = await rpc("create_group", {
    p_name: `P84 P110 synthetic ${crypto.randomUUID()}`,
    p_type: "other",
    p_event_create_policy: "member",
    p_operation_id: crypto.randomUUID(),
  }, ownerToken);
  const groupRow = (group.body as JsonRecord[] | undefined)?.[0];
  assert(
    group.status === 200 && typeof groupRow?.group_id === "string",
    `synthetic owner group setup failed: HTTP ${group.status}`,
  );
  const groupId = groupRow.group_id;
  const args = {
    p_group_id: groupId,
    p_title: titleCanary,
    p_start_at: eventStart,
    p_end_at: eventEnd,
    p_location: "P110 private location canary",
    p_description: "P110 private description canary",
    p_operation_id: crypto.randomUUID(),
  };

  assert(
    await eventCount(groupId, serviceToken) === 0,
    "synthetic group unexpectedly had events",
  );
  const outsiderCreate = await rpc("create_group_event", args, outsiderToken);
  assert(
    outsiderCreate.status === 403 && outsiderCreate.code === "42501",
    `authenticated nonmember denial differed: HTTP ${outsiderCreate.status}; SQLSTATE=${
      outsiderCreate.code ?? "none"
    }`,
  );
  const afterOutsider = await eventCount(groupId, serviceToken);
  assert(afterOutsider === 0, "denied nonmember request persisted an event");

  const anonymousCreate = await rpc("create_group_event", args, anonToken);
  assert(
    anonymousCreate.status !== 200,
    `anonymous request unexpectedly succeeded: HTTP ${anonymousCreate.status}`,
  );
  const afterAnonymous = await eventCount(groupId, serviceToken);
  assert(afterAnonymous === 0, "anonymous request persisted an event");

  console.log(
    `create_group_event=authenticated_nonmember:${outsiderCreate.status}/${outsiderCreate.code}; anonymous:${anonymousCreate.status}; events=0-before-and-after`,
  );
});
