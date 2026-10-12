type JsonObject = Record<string, unknown>;

const authUrl = "http://auth:9999";
const restUrl = "http://rest:3000";
const jwtSecret = Deno.env.get("PGRST_JWT_SECRET");
const jwtIssuer = Deno.env.get("GOTRUE_JWT_ISSUER");
if (!jwtSecret || !jwtIssuer) {
  throw new Error("P126 isolated Auth test configuration missing");
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function signedRoleToken(role: "anon" | "service_role"): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(
    new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" })),
  );
  const payload = base64Url(new TextEncoder().encode(JSON.stringify({
    iss: jwtIssuer,
    role,
    aud: "authenticated",
    iat: now,
    exp: now + 3600,
  })));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(jwtSecret),
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

async function jsonRequest(
  origin: string,
  path: string,
  init: RequestInit,
): Promise<{ status: number; value: unknown }> {
  if (origin !== authUrl && origin !== restUrl) {
    throw new Error("P126 blocked unexpected request origin");
  }
  const response = await fetch(`${origin}${path}`, {
    ...init,
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.text();
  let value: unknown;
  try {
    value = body ? JSON.parse(body) : null;
  } catch {
    throw new Error(
      `P126 expected JSON from local API (HTTP ${response.status})`,
    );
  }
  return { status: response.status, value };
}

function requireCondition(
  condition: unknown,
  failure: string,
): asserts condition {
  if (!condition) throw new Error(failure);
}

Deno.test("P126 notification device registration uses a GoTrue user session", async () => {
  const adminToken = await signedRoleToken("service_role");
  const anonKey = await signedRoleToken("anon");
  const suffix = crypto.randomUUID();
  const email = `p126-${suffix}@example.invalid`;
  const password = `P126 synthetic ${crypto.randomUUID()}!`;
  const installationId = crypto.randomUUID();
  const token1 = `p126-synthetic-device-token-one-${crypto.randomUUID()}`;
  const token2 = `p126-synthetic-device-token-two-${crypto.randomUUID()}`;
  let userId: string | undefined;
  let completed = false;

  try {
    const create = await jsonRequest(authUrl, "/admin/users", {
      method: "POST",
      headers: {
        apikey: adminToken,
        authorization: `Bearer ${adminToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        email,
        password,
        email_confirm: true,
        user_metadata: { display_name: "P126 synthetic" },
      }),
    });
    requireCondition(
      create.status === 200 || create.status === 201,
      "P126 synthetic user creation failed",
    );
    const created = create.value as JsonObject;
    requireCondition(typeof created.id === "string", "P126 user ID missing");
    userId = created.id;
    console.log(`P126_USER_ID=${userId}`);
    console.log(`P126_INSTALLATION_ID=${installationId}`);

    const login = await jsonRequest(authUrl, "/token?grant_type=password", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    requireCondition(
      login.status === 200,
      "P126 GoTrue password session failed",
    );
    const session = login.value as JsonObject;
    requireCondition(
      typeof session.access_token === "string",
      "P126 access token missing",
    );
    const userToken = session.access_token;

    async function rpc(name: string, args: JsonObject): Promise<unknown> {
      const result = await jsonRequest(restUrl, `/rpc/${name}`, {
        method: "POST",
        headers: {
          apikey: anonKey,
          authorization: `Bearer ${userToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(args),
      });
      requireCondition(
        result.status === 200,
        `P126 ${name} API returned HTTP ${result.status}`,
      );
      return result.value;
    }

    const first = await rpc("register_notification_device", {
      p_installation_id: installationId,
      p_client_generation: 1,
      p_platform: "android",
      p_token: token1,
      p_app_version: "p126",
      p_device_id: "synthetic-p126",
    }) as JsonObject[];
    requireCondition(
      Array.isArray(first) && first.length === 1 &&
        first[0].binding_generation === 1 && first[0].accepted === true,
      "P126 initial registration contract failed",
    );

    const stale = await rpc("register_notification_device", {
      p_installation_id: installationId,
      p_client_generation: 1,
      p_platform: "android",
      p_token: token2,
      p_app_version: "p126",
      p_device_id: "synthetic-p126",
    }) as JsonObject[];
    requireCondition(
      Array.isArray(stale) && stale.length === 1 &&
        stale[0].binding_generation === 1 && stale[0].accepted === false,
      "P126 stale generation registration was not rejected",
    );

    const rotated = await rpc("register_notification_device", {
      p_installation_id: installationId,
      p_client_generation: 2,
      p_platform: "android",
      p_token: token2,
      p_app_version: "p126",
      p_device_id: "synthetic-p126",
    }) as JsonObject[];
    requireCondition(
      Array.isArray(rotated) && rotated.length === 1 &&
        rotated[0].binding_generation === 2 && rotated[0].accepted === true,
      "P126 newer generation rotation failed",
    );

    const staleRevoke = await rpc("revoke_notification_device", {
      p_installation_id: installationId,
      p_client_generation: 1,
      p_binding_generation: 1,
    });
    requireCondition(
      staleRevoke === false,
      "P126 stale revoke was not rejected",
    );

    const currentRevoke = await rpc("revoke_notification_device", {
      p_installation_id: installationId,
      p_client_generation: 2,
      p_binding_generation: 2,
    });
    requireCondition(
      currentRevoke === true,
      "P126 matching revoke did not succeed",
    );
    completed = true;
  } finally {
    if (userId) {
      const remove = await jsonRequest(authUrl, `/admin/users/${userId}`, {
        method: "DELETE",
        headers: {
          apikey: adminToken,
          authorization: `Bearer ${adminToken}`,
        },
      });
      requireCondition(
        remove.status === 200 || remove.status === 204 || remove.status === 404,
        "P126 synthetic Auth cleanup failed",
      );
    }
    if (completed) {
      console.log(
        "P126 Auth/API: GoTrue session registration, stale-generation rejection, rotation and matching revoke passed; credential/token values omitted.",
      );
    }
  }
});
