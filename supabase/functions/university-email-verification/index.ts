// Trusted university-email verification adapter.
//
// The mobile client first creates an opaque verification request through the
// authenticated request_university_email_verification RPC. This function then
// owns the only boundary where a full email address or one-time code exists.
// PostgreSQL receives only HMAC-SHA256 fingerprints produced with a dedicated
// Edge secret; neither the service-role key nor the HMAC secret belongs in a
// mobile build.

type JsonRecord = Record<string, unknown>;

type VerificationEnvironment = {
  supabaseUrl: string;
  publicApiKey: string;
  serviceRoleKey: string;
  hmacSecret: string;
  emailWebhookUrl: string;
  emailWebhookToken: string;
};

type VerificationRequestRow = {
  request_id: string;
  domain_rule_id: string;
  status: string;
};

type UniversityDomainRow = {
  id: string;
  domain: string;
  kind: string;
  match_subdomains: boolean;
  verification_enabled: boolean;
};

class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const jsonHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
  "x-content-type-options": "nosniff",
};

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const otpPattern = /^\d{6}$/;
const domainPattern =
  /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

function jsonResponse(status: number, body: JsonRecord): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  });
}

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new HttpError(503, "Verification service is not configured.");
  }
  return value;
}

function loadEnvironment(): VerificationEnvironment {
  const hmacSecret = requiredEnvironment(
    "UNIVERSITY_VERIFICATION_HMAC_SECRET",
  );
  if (new TextEncoder().encode(hmacSecret).length < 32) {
    throw new HttpError(503, "Verification service is not configured.");
  }

  const supabaseUrl = requiredEnvironment("SUPABASE_URL").replace(/\/$/, "");
  const emailWebhookUrl = requiredEnvironment(
    "UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_URL",
  );
  const parsedWebhook = safeUrl(emailWebhookUrl);
  const isLoopback = parsedWebhook.hostname === "127.0.0.1" ||
    parsedWebhook.hostname === "localhost" ||
    parsedWebhook.hostname === "host.docker.internal";
  if (parsedWebhook.protocol !== "https:" && !isLoopback) {
    throw new HttpError(503, "Verification service is not configured.");
  }
  if (parsedWebhook.username || parsedWebhook.password || parsedWebhook.hash) {
    throw new HttpError(503, "Verification service is not configured.");
  }

  return {
    supabaseUrl,
    publicApiKey: Deno.env.get("SUPABASE_PUBLISHABLE_KEY")?.trim() ||
      requiredEnvironment("SUPABASE_ANON_KEY"),
    serviceRoleKey: requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
    hmacSecret,
    emailWebhookUrl: parsedWebhook.toString(),
    emailWebhookToken: requiredEnvironment(
      "UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_TOKEN",
    ),
  };
}

function safeUrl(value: string): URL {
  try {
    return new URL(value);
  } catch {
    throw new HttpError(503, "Verification service is not configured.");
  }
}

function asRecord(value: unknown): JsonRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "Invalid request.");
  }
  return value as JsonRecord;
}

function serviceRecord(value: unknown): JsonRecord {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }
  return value as JsonRecord;
}

function requiredString(
  body: JsonRecord,
  key: string,
  maximumLength: number,
): string {
  const value = body[key];
  if (typeof value !== "string") {
    throw new HttpError(400, "Invalid request.");
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maximumLength) {
    throw new HttpError(400, "Invalid request.");
  }
  return trimmed;
}

async function parseRequestBody(request: Request): Promise<JsonRecord> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > 16_384) {
    throw new HttpError(413, "Request is too large.");
  }
  try {
    return asRecord(await request.json());
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "Invalid request.");
  }
}

function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    throw new HttpError(401, "Authentication required.");
  }
  const token = authorization.slice(7).trim();
  if (!token || token.length > 8192) {
    throw new HttpError(401, "Authentication required.");
  }
  return token;
}

async function authenticatedUserId(
  request: Request,
  environment: VerificationEnvironment,
): Promise<string> {
  const token = bearerToken(request);
  const response = await fetch(`${environment.supabaseUrl}/auth/v1/user`, {
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
    headers: {
      apikey: environment.publicApiKey,
      authorization: `Bearer ${token}`,
    },
  });
  if (!response.ok) {
    throw new HttpError(401, "Authentication required.");
  }
  const user = asRecord(await response.json());
  const id = user.id;
  if (typeof id !== "string" || !uuidPattern.test(id)) {
    throw new HttpError(401, "Authentication required.");
  }
  return id;
}

async function serviceRpc(
  environment: VerificationEnvironment,
  name: string,
  body: JsonRecord,
): Promise<unknown> {
  const response = await fetch(
    `${environment.supabaseUrl}/rest/v1/rpc/${encodeURIComponent(name)}`,
    {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
      headers: {
        apikey: environment.serviceRoleKey,
        authorization: `Bearer ${environment.serviceRoleKey}`,
        "content-type": "application/json",
        prefer: "return=representation",
      },
      body: JSON.stringify(body),
    },
  );
  if (!response.ok) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }
  if (response.status === 204) return null;
  return await response.json();
}

async function serviceRows<T>(
  environment: VerificationEnvironment,
  table: string,
  filters: Record<string, string>,
  select: string,
): Promise<T[]> {
  const url = new URL(`${environment.supabaseUrl}/rest/v1/${table}`);
  url.searchParams.set("select", select);
  url.searchParams.set("limit", "1");
  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, `eq.${value}`);
  }
  const response = await fetch(url, {
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
    headers: {
      apikey: environment.serviceRoleKey,
      authorization: `Bearer ${environment.serviceRoleKey}`,
      accept: "application/json",
    },
  });
  if (!response.ok) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }
  const rows = await response.json();
  if (!Array.isArray(rows)) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }
  return rows as T[];
}

function normalizeEmail(raw: string): { email: string; domain: string } {
  const email = raw.normalize("NFKC").trim().toLowerCase();
  if (
    email.length > 254 ||
    email.includes("\r") ||
    email.includes("\n") ||
    /\s/.test(email)
  ) {
    throw new HttpError(400, "Enter a valid university email address.");
  }
  const at = email.lastIndexOf("@");
  if (at <= 0 || at !== email.indexOf("@") || at === email.length - 1) {
    throw new HttpError(400, "Enter a valid university email address.");
  }
  const domain = email.slice(at + 1);
  if (!domainPattern.test(domain)) {
    throw new HttpError(400, "Enter a valid university email address.");
  }
  return { email, domain };
}

function domainMatches(
  rule: UniversityDomainRow,
  actualDomain: string,
): boolean {
  const configured = rule.domain.trim().toLowerCase();
  return actualDomain === configured ||
    (rule.match_subdomains && actualDomain.endsWith(`.${configured}`));
}

function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  const visible = local.length <= 1 ? local : local.slice(0, 1);
  return `${visible}***@${domain}`;
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(message),
  );
  return [...new Uint8Array(signature)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function createOtp(): string {
  const range = 1_000_000;
  const upperExclusive = Math.floor(2 ** 32 / range) * range;
  const random = new Uint32Array(1);
  do {
    crypto.getRandomValues(random);
  } while (random[0] >= upperExclusive);
  return (random[0] % range).toString().padStart(6, "0");
}

async function verificationContext(
  environment: VerificationEnvironment,
  requestId: string,
  userId: string,
): Promise<{
  request: VerificationRequestRow;
  domain: UniversityDomainRow;
}> {
  const requests = await serviceRows<VerificationRequestRow>(
    environment,
    "university_email_verifications",
    { request_id: requestId, user_id: userId },
    "request_id,domain_rule_id,status",
  );
  const verificationRequest = requests[0];
  if (!verificationRequest || verificationRequest.status !== "pending") {
    throw new HttpError(409, "Verification request is unavailable.");
  }

  const rules = await serviceRows<UniversityDomainRow>(
    environment,
    "university_domains",
    { id: verificationRequest.domain_rule_id },
    "id,domain,kind,match_subdomains,verification_enabled",
  );
  const domain = rules[0];
  if (
    !domain ||
    domain.kind !== "student_email" ||
    !domain.verification_enabled
  ) {
    throw new HttpError(409, "Verification request is unavailable.");
  }
  return { request: verificationRequest, domain };
}

async function deliverCode(
  environment: VerificationEnvironment,
  email: string,
  code: string,
  expiresAt: string,
): Promise<void> {
  const response = await fetch(environment.emailWebhookUrl, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
    headers: {
      authorization: `Bearer ${environment.emailWebhookToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      kind: "university_email_verification",
      to: email,
      locale: "ja-JP",
      variables: {
        code,
        expiresAt,
        expiresInMinutes: 10,
      },
    }),
  });
  if (!response.ok) {
    throw new HttpError(502, "Verification email delivery failed.");
  }
}

async function invalidateAfterDeliveryFailure(
  environment: VerificationEnvironment,
  requestId: string,
  userId: string,
): Promise<void> {
  try {
    await serviceRpc(environment, "invalidate_university_email_verification", {
      p_request_id: requestId,
      p_user_id: userId,
      p_reason: "delivery_failed",
    });
  } catch {
    // Keep the original delivery failure generic. The short-lived challenge
    // still expires and cannot be read through a client role.
  }
}

async function issueVerification(
  body: JsonRecord,
  userId: string,
  environment: VerificationEnvironment,
): Promise<Response> {
  const requestId = requiredString(body, "requestId", 36);
  if (!uuidPattern.test(requestId)) {
    throw new HttpError(400, "Invalid request.");
  }
  const normalized = normalizeEmail(requiredString(body, "email", 254));
  const context = await verificationContext(environment, requestId, userId);
  if (!domainMatches(context.domain, normalized.domain)) {
    throw new HttpError(400, "Email domain is not eligible for verification.");
  }

  const code = createOtp();
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();
  const emailHmac = await hmacHex(
    environment.hmacSecret,
    `university-email:v1\u0000${normalized.email}`,
  );
  const challengeHmac = await hmacHex(
    environment.hmacSecret,
    `university-code:v1\u0000${requestId}\u0000${code}`,
  );

  const issued = await serviceRpc(
    environment,
    "issue_university_email_verification_challenge",
    {
      p_request_id: requestId,
      p_user_id: userId,
      p_email_hmac: emailHmac,
      p_challenge_hmac: challengeHmac,
      p_expires_at: expiresAt,
    },
  );
  const issuedRows = Array.isArray(issued) ? issued : [];
  const issuedRow = serviceRecord(issuedRows[0]);
  if (
    typeof issuedRow.challenge_id !== "string" ||
    typeof issuedRow.expires_at !== "string"
  ) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }

  try {
    await deliverCode(environment, normalized.email, code, expiresAt);
  } catch {
    await invalidateAfterDeliveryFailure(environment, requestId, userId);
    throw new HttpError(503, "Verification email is temporarily unavailable.");
  }

  return jsonResponse(202, {
    status: "sent",
    requestId,
    maskedEmail: maskEmail(normalized.email),
    expiresAt: issuedRow.expires_at,
  });
}

async function completeVerification(
  body: JsonRecord,
  userId: string,
  environment: VerificationEnvironment,
): Promise<Response> {
  const requestId = requiredString(body, "requestId", 36);
  const code = requiredString(body, "code", 6);
  if (!uuidPattern.test(requestId) || !otpPattern.test(code)) {
    throw new HttpError(400, "Invalid verification code.");
  }
  const challengeHmac = await hmacHex(
    environment.hmacSecret,
    `university-code:v1\u0000${requestId}\u0000${code}`,
  );
  const completed = await serviceRpc(
    environment,
    "complete_university_email_verification",
    {
      p_request_id: requestId,
      p_user_id: userId,
      p_challenge_hmac: challengeHmac,
    },
  );
  const rows = Array.isArray(completed) ? completed : [];
  const result = serviceRecord(rows[0]);
  const status = result.result;
  if (
    typeof status !== "string" ||
    !["verified", "invalid_code", "expired", "locked", "invalid_request"]
      .includes(status)
  ) {
    throw new HttpError(
      502,
      "Verification service is temporarily unavailable.",
    );
  }

  // Trusted verification outcomes are application states rather than transport
  // failures. Keeping them 200 lets the Flutter functions client receive the
  // remaining-attempt count without treating the safe response as an exception.
  return jsonResponse(200, {
    status,
    attemptsRemaining: typeof result.attempts_remaining === "number"
      ? result.attempts_remaining
      : null,
    verifiedAt: typeof result.verified_at === "string"
      ? result.verified_at
      : null,
  });
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "access-control-allow-headers":
          "authorization, apikey, content-type, x-client-info",
        "access-control-allow-methods": "POST, OPTIONS",
        "access-control-max-age": "600",
      },
    });
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed." });
  }

  try {
    const environment = loadEnvironment();
    const userId = await authenticatedUserId(request, environment);
    const body = await parseRequestBody(request);
    const action = requiredString(body, "action", 16);
    switch (action) {
      case "issue":
        return await issueVerification(body, userId, environment);
      case "complete":
        return await completeVerification(body, userId, environment);
      default:
        throw new HttpError(400, "Invalid request.");
    }
  } catch (error) {
    if (error instanceof HttpError) {
      return jsonResponse(error.status, { error: error.message });
    }
    return jsonResponse(500, { error: "Verification service failed safely." });
  }
}

// Pure helpers are exposed as one explicitly test-only object. They do not
// expose configuration or weaken the deployed HTTP boundary.
export const verificationTestUtils = {
  normalizeEmail,
  domainMatches,
  maskEmail,
  hmacHex,
  createOtp,
};

if (import.meta.main) {
  Deno.serve(handleRequest);
}
