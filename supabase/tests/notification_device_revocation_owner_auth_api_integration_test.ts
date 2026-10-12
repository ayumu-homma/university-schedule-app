type JsonObject = Record<string, unknown>;
type Principal = {
  id: string;
  email: string;
  password: string;
  accessToken?: string;
};

const authUrl = "http://auth:9999";
const restUrl = "http://rest:3000";
const jwtSecret = Deno.env.get("PGRST_JWT_SECRET");
const jwtIssuer = Deno.env.get("GOTRUE_JWT_ISSUER");
if (!jwtSecret || !jwtIssuer) {
  throw new Error("P127 isolated Auth test configuration missing");
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

async function requestJson(
  origin: string,
  path: string,
  init: RequestInit,
): Promise<{ status: number; value: unknown }> {
  if (origin !== authUrl && origin !== restUrl) {
    throw new Error("P127 blocked unexpected request origin");
  }
  const response = await fetch(`${origin}${path}`, {
    ...init,
    signal: AbortSignal.timeout(10_000),
  });
  const text = await response.text();
  let value: unknown;
  try {
    value = text ? JSON.parse(text) : null;
  } catch {
    throw new Error(
      `P127 expected JSON from local API (HTTP ${response.status})`,
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

Deno.test("P127 only the bound user can revoke a notification installation", async () => {
  const adminToken = await signedRoleToken("service_role");
  const anonKey = await signedRoleToken("anon");
  const suffix = crypto.randomUUID();
  const principals: Principal[] = ["owner", "other"].map((name) => ({
    id: "",
    email: `p127-${suffix}-${name}@example.invalid`,
    password: `P127 synthetic ${crypto.randomUUID()}!`,
  }));
  const installationId = crypto.randomUUID();
  const deviceToken = `p127-synthetic-device-token-${crypto.randomUUID()}`;
  let completed = false;

  try {
    for (const principal of principals) {
      const created = await requestJson(authUrl, "/admin/users", {
        method: "POST",
        headers: {
          apikey: adminToken,
          authorization: `Bearer ${adminToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          email: principal.email,
          password: principal.password,
          email_confirm: true,
          user_metadata: { display_name: "P127 synthetic" },
        }),
      });
      requireCondition(
        created.status === 200 || created.status === 201,
        "P127 synthetic user creation failed",
      );
      const user = created.value as JsonObject;
      requireCondition(typeof user.id === "string", "P127 user ID missing");
      principal.id = user.id;

      const login = await requestJson(authUrl, "/token?grant_type=password", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          email: principal.email,
          password: principal.password,
        }),
      });
      requireCondition(
        login.status === 200,
        "P127 GoTrue password session failed",
      );
      const session = login.value as JsonObject;
      requireCondition(
        typeof session.access_token === "string",
        "P127 access token missing",
      );
      principal.accessToken = session.access_token;
    }

    const owner = principals[0];
    const other = principals[1];
    const ownerHeaders = {
      apikey: anonKey,
      authorization: `Bearer ${owner.accessToken}`,
      "content-type": "application/json",
    };
    const register = await requestJson(
      restUrl,
      "/rpc/register_notification_device",
      {
        method: "POST",
        headers: ownerHeaders,
        body: JSON.stringify({
          p_installation_id: installationId,
          p_client_generation: 1,
          p_platform: "android",
          p_token: deviceToken,
          p_app_version: "p127",
          p_device_id: "synthetic-p127",
        }),
      },
    );
    requireCondition(
      register.status === 200,
      "P127 owner registration API failed",
    );
    const registration = register.value as JsonObject[];
    requireCondition(
      Array.isArray(registration) && registration.length === 1 &&
        registration[0].binding_generation === 1 &&
        registration[0].accepted === true,
      "P127 owner registration contract failed",
    );

    const otherRevoke = await requestJson(
      restUrl,
      "/rpc/revoke_notification_device",
      {
        method: "POST",
        headers: {
          apikey: anonKey,
          authorization: `Bearer ${other.accessToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          p_installation_id: installationId,
          p_client_generation: 1,
          p_binding_generation: 1,
        }),
      },
    );
    requireCondition(
      otherRevoke.status === 200 && otherRevoke.value === false,
      "P127 unrelated Auth user was able to revoke the installation",
    );

    const ownerRevoke = await requestJson(
      restUrl,
      "/rpc/revoke_notification_device",
      {
        method: "POST",
        headers: ownerHeaders,
        body: JSON.stringify({
          p_installation_id: installationId,
          p_client_generation: 1,
          p_binding_generation: 1,
        }),
      },
    );
    requireCondition(
      ownerRevoke.status === 200 && ownerRevoke.value === true,
      "P127 bound owner could not revoke their installation",
    );
    completed = true;
  } finally {
    for (const principal of principals) {
      if (!principal.id) continue;
      const remove = await requestJson(
        authUrl,
        `/admin/users/${principal.id}`,
        {
          method: "DELETE",
          headers: {
            apikey: adminToken,
            authorization: `Bearer ${adminToken}`,
          },
        },
      );
      requireCondition(
        remove.status === 200 || remove.status === 204 || remove.status === 404,
        "P127 synthetic Auth cleanup failed",
      );
    }
    for (const principal of principals) {
      if (principal.id) console.log(`P127_USER_ID=${principal.id}`);
    }
    console.log(`P127_INSTALLATION_ID=${installationId}`);
    if (completed) {
      console.log(
        "P127 Auth/API: unrelated GoTrue user received false; bound owner revoke returned true; credential/token values omitted.",
      );
    }
  }
});
