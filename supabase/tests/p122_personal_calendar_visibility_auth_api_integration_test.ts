type JsonObject = Record<string, unknown>;

const authUrl = "http://auth:9999";
const restUrl = "http://rest:3000";
const jwtSecret = Deno.env.get("PGRST_JWT_SECRET");
const jwtIssuer = Deno.env.get("GOTRUE_JWT_ISSUER");
const ownerEmail = Deno.env.get("P129_OWNER_EMAIL");
const ownerPassword = Deno.env.get("P129_OWNER_PASSWORD");
const ownerId = Deno.env.get("P129_OWNER_ID");
const outsiderEmail = Deno.env.get("P129_OUTSIDER_EMAIL");
const outsiderPassword = Deno.env.get("P129_OUTSIDER_PASSWORD");
const outsiderId = Deno.env.get("P129_OUTSIDER_ID");
const personalCalendarId = Deno.env.get("P129_PERSONAL_CALENDAR_ID");
const groupCalendarId = Deno.env.get("P129_GROUP_CALENDAR_ID");
if (
  !jwtSecret || !jwtIssuer || !ownerEmail || !ownerPassword || !ownerId ||
  !outsiderEmail || !outsiderPassword || !outsiderId ||
  !personalCalendarId || !groupCalendarId
) {
  throw new Error("P129 integration configuration missing");
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function roleToken(role: "anon"): Promise<string> {
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

async function request(
  origin: string,
  path: string,
  init: RequestInit,
): Promise<{ status: number; value: unknown; code?: string }> {
  if (origin !== authUrl && origin !== restUrl) {
    throw new Error("P129 blocked unexpected API origin");
  }
  const response = await fetch(`${origin}${path}`, {
    ...init,
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.text();
  let value: unknown = null;
  if (body) {
    try {
      value = JSON.parse(body);
    } catch {
      throw new Error(
        `P129 non-JSON response from local API (HTTP ${response.status})`,
      );
    }
  }
  const code = value && typeof value === "object" && "code" in value
    ? String((value as JsonObject).code)
    : undefined;
  return { status: response.status, value, code };
}

function requireCondition(
  condition: unknown,
  failure: string,
): asserts condition {
  if (!condition) throw new Error(failure);
}

async function login(
  email: string,
  password: string,
): Promise<{ accessToken: string; userId: string }> {
  const result = await request(authUrl, "/token?grant_type=password", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  requireCondition(
    result.status === 200,
    "P129 GoTrue password session failed",
  );
  const session = result.value as JsonObject;
  requireCondition(
    typeof session.access_token === "string",
    "P129 GoTrue session token missing",
  );
  const user = session.user as JsonObject | undefined;
  requireCondition(typeof user?.id === "string", "P129 GoTrue user ID missing");
  return { accessToken: session.access_token, userId: user.id };
}

Deno.test("P129 personal calendar visibility RPC accepts explicit NULL only for its owner", async () => {
  const anonKey = await roleToken("anon");
  let completed = false;

  try {
    const ownerSession = await login(ownerEmail, ownerPassword);
    const outsiderSession = await login(outsiderEmail, outsiderPassword);
    requireCondition(
      ownerSession.userId === ownerId && outsiderSession.userId === outsiderId,
      "P129 GoTrue sessions did not match their seeded principals",
    );
    const ownerToken = ownerSession.accessToken;
    const outsiderToken = outsiderSession.accessToken;
    const ownerHeaders = {
      apikey: anonKey,
      authorization: `Bearer ${ownerToken}`,
      "content-type": "application/json",
    };

    async function readCalendar(calendarId: string): Promise<unknown> {
      const result = await request(
        restUrl,
        `/calendars?select=id,default_visibility&id=eq.${calendarId}`,
        { headers: ownerHeaders },
      );
      requireCondition(
        result.status === 200,
        "P129 owner calendar read failed",
      );
      const rows = result.value as JsonObject[];
      requireCondition(
        Array.isArray(rows) && rows.length === 1,
        "P129 calendar row missing",
      );
      return rows[0].default_visibility;
    }

    async function setVisibility(
      calendarId: string,
      visibility: "BUSY_ONLY" | "FULL" | null,
      token = ownerToken,
    ) {
      return await request(
        restUrl,
        "/rpc/set_personal_calendar_default_visibility",
        {
          method: "POST",
          headers: {
            apikey: anonKey,
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            p_calendar_id: calendarId,
            p_visibility: visibility,
          }),
        },
      );
    }

    const inherit = await setVisibility(personalCalendarId, null);
    requireCondition(
      inherit.status === 204,
      `P129 explicit NULL RPC returned HTTP ${inherit.status}`,
    );
    requireCondition(
      await readCalendar(personalCalendarId) === null,
      "P129 explicit NULL did not persist",
    );

    const concrete = await setVisibility(personalCalendarId, "BUSY_ONLY");
    requireCondition(
      concrete.status === 204,
      `P129 concrete RPC returned HTTP ${concrete.status}`,
    );
    requireCondition(
      await readCalendar(personalCalendarId) === "BUSY_ONLY",
      "P129 concrete visibility did not persist",
    );

    const outsiderAttempt = await setVisibility(
      personalCalendarId,
      "FULL",
      outsiderToken,
    );
    requireCondition(
      outsiderAttempt.status === 403 && outsiderAttempt.code === "42501",
      "P129 unrelated authenticated user was not denied",
    );
    requireCondition(
      await readCalendar(personalCalendarId) === "BUSY_ONLY",
      "P129 denied outsider changed the personal calendar",
    );

    const groupAttempt = await setVisibility(groupCalendarId, null);
    requireCondition(
      groupAttempt.status === 403 && groupAttempt.code === "42501",
      "P129 personal-calendar RPC did not reject a group calendar",
    );
    requireCondition(
      await readCalendar(groupCalendarId) === "TITLE_ONLY",
      "P129 rejected group calendar was changed",
    );
    completed = true;
  } finally {
    if (completed) {
      console.log(
        "P129 Auth/API: owner NULL/value updates persisted; outsider and group-calendar updates denied with no side effect; credentials omitted. The isolated outer runner owns exact SQL/Auth fixture cleanup.",
      );
    }
  }
});
