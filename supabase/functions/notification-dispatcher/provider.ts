type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
};

type Claim = {
  inbox_id: string;
  token: string;
  notification_type: string;
};

export function fcmMessage(claim: Claim) {
  const copy = genericCopy(claim.notification_type);
  return {
    message: {
      token: claim.token,
      notification: { title: copy.title, body: copy.body },
      data: { inbox_id: claim.inbox_id },
      android: { priority: "high" },
      apns: { headers: { "apns-priority": "10" } },
    },
  };
}

function genericCopy(type: string): { title: string; body: string } {
  switch (type) {
    case "group_invitation":
      return { title: "グループへの招待", body: "新しい招待があります" };
    case "group_event_created":
      return { title: "グループ予定", body: "予定が追加されました" };
    case "group_event_updated":
      return { title: "グループ予定", body: "予定が更新されました" };
    case "group_comment":
      return { title: "グループ予定", body: "新しいコメントがあります" };
    default:
      return { title: "通知", body: "新しいお知らせがあります" };
  }
}

export function classifyProviderResponse(status: number, body: string): {
  outcome: "sent" | "retry" | "permanent" | "invalid_token";
  retrySeconds?: number;
  error?: string;
} {
  if (status >= 200 && status < 300) return { outcome: "sent" };
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(body) as Record<string, unknown>;
  } catch { /* opaque provider response */ }
  const message = typeof parsed.error === "object" && parsed.error !== null
    ? parsed.error as Record<string, unknown>
    : {};
  const details = Array.isArray(message.details) ? message.details : [];
  const isUnregistered = message.status === "NOT_FOUND" ||
    details.some((detail) =>
      typeof detail === "object" && detail !== null &&
      (detail as Record<string, unknown>).errorCode === "UNREGISTERED"
    );
  if (isUnregistered) {
    return { outcome: "invalid_token", error: "fcm_unregistered" };
  }
  if (status === 429 || status >= 500 || status === 408) {
    return {
      outcome: "retry",
      retrySeconds: status === 429 ? 60 : 30,
      error: `fcm_http_${status}`,
    };
  }
  // Bad requests, invalid credentials and permission errors are operator
  // failures. They must not loop through the provider queue indefinitely.
  return { outcome: "permanent", error: `fcm_http_${status}` };
}

export async function getAccessToken(
  serviceAccount: ServiceAccount,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${payload}`;
  const pem = serviceAccount.private_key.replace(/\\n/g, "\n");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const assertion = `${unsigned}.${base64UrlBytes(new Uint8Array(signature))}`;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    signal: AbortSignal.timeout(12_000),
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) throw new Error("provider_auth_unavailable");
  const body = await response.json() as { access_token?: string };
  if (!body.access_token) throw new Error("provider_auth_unavailable");
  return body.access_token;
}

function pemBytes(pem: string): ArrayBuffer {
  const contents = pem.replace(
    /-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
    "",
  );
  const decoded = atob(contents);
  const buffer = new ArrayBuffer(decoded.length);
  const bytes = new Uint8Array(buffer);
  for (let index = 0; index < decoded.length; index++) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return buffer;
}

function base64Url(value: string): string {
  return base64UrlBytes(new TextEncoder().encode(value));
}

function base64UrlBytes(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
