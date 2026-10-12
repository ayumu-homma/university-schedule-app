import { createNotificationDispatcherHandler } from "../functions/notification-dispatcher/index.ts";

const localRestUrl = "http://p84-share01-20260928-v12-rest:3000";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const value of bytes) binary += String.fromCharCode(value);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function localServiceRoleJwt(secret: string): Promise<string> {
  const header = base64Url(new TextEncoder().encode(
    JSON.stringify({ alg: "HS256", typ: "JWT" }),
  ));
  const now = Math.floor(Date.now() / 1000);
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

Deno.test("dispatcher handler uses current local RPCs and a fake provider", async () => {
  const jwtSecret = Deno.env.get("PGRST_JWT_SECRET");
  assert(jwtSecret, "isolated PostgREST signing input is unavailable");
  const serviceRoleKey = await localServiceRoleJwt(jwtSecret);
  const order: string[] = [];
  let providerPayload: Record<string, unknown> | undefined;
  let providerCalls = 0;
  let claimHttpStatus: number | undefined;
  let claimHttpCode: string | undefined;

  const dependencies = {
    getEnv(name: string): string | undefined {
      switch (name) {
        case "SUPABASE_SERVICE_ROLE_KEY":
          return serviceRoleKey;
        case "SUPABASE_URL":
          return localRestUrl;
        case "NOTIFICATION_DISPATCH_ENABLED":
          return "true";
        case "FIREBASE_SERVICE_ACCOUNT_JSON":
          return JSON.stringify({
            project_id: "synthetic-p84-project",
            client_email: "dispatcher@example.invalid",
            private_key: "synthetic-unused-private-key",
          });
        default:
          return undefined;
      }
    },
    async fetch(
      input: RequestInfo | URL,
      init?: RequestInit,
    ): Promise<Response> {
      const requestUrl = input instanceof Request ? input.url : String(input);
      if (requestUrl.startsWith(`${localRestUrl}/rest/v1/rpc/`)) {
        const parsedUrl = new URL(requestUrl);
        const rpcName = parsedUrl.pathname.split("/").at(-1);
        order.push(`rpc:${rpcName}`);
        const authorization = new Headers(init?.headers).get("authorization");
        assert(
          authorization === `Bearer ${serviceRoleKey}`,
          "local RPC authorization mismatch",
        );
        // The isolated stack exposes PostgREST directly without Kong. Adapt the
        // Supabase client's Kong prefix to PostgREST's direct /rpc route.
        parsedUrl.pathname = parsedUrl.pathname.replace(
          /^\/rest\/v1(?=\/)/,
          "",
        );
        const response = await globalThis.fetch(parsedUrl, init);
        if (rpcName === "claim_notification_outbox") {
          claimHttpStatus = response.status;
          const error = await response.clone().json().catch(() => undefined) as
            | { code?: unknown }
            | undefined;
          const candidate = typeof error?.code === "string" ? error.code : "";
          claimHttpCode = /^[A-Z0-9_]+$/.test(candidate)
            ? candidate
            : undefined;
        }
        return response;
      }
      if (requestUrl.startsWith("https://fcm.googleapis.com/v1/projects/")) {
        providerCalls++;
        order.push("provider");
        const authorization = new Headers(init?.headers).get("authorization");
        assert(
          authorization === "Bearer synthetic-provider-bearer",
          "provider credential mismatch",
        );
        providerPayload = JSON.parse(String(init?.body)) as Record<
          string,
          unknown
        >;
        return new Response(
          JSON.stringify({ name: "synthetic-provider-message" }),
          {
            status: 200,
            headers: { "x-fcm-message-id": "synthetic-provider-message" },
          },
        );
      }
      throw new Error(
        "unexpected outbound request blocked by integration fake",
      );
    },
    async getAccessToken(): Promise<string> {
      return "synthetic-provider-bearer";
    },
  };

  const handler = createNotificationDispatcherHandler(dependencies);
  const response = await handler(
    new Request("http://dispatcher.test/", {
      method: "POST",
      headers: { authorization: `Bearer ${serviceRoleKey}` },
    }),
  );
  const responseBody = await response.json() as { processed?: number };

  assert(
    response.status === 200,
    `dispatcher status=${response.status}; claim_http=${
      claimHttpStatus ?? "none"
    }; claim_code=${claimHttpCode ?? "none"}`,
  );
  assert(
    responseBody.processed === 1,
    "dispatcher did not confirm one finished delivery",
  );
  assert(providerCalls === 1, "fake provider was not called exactly once");
  assert(
    order.join(",") ===
      "rpc:claim_notification_outbox,provider,rpc:finish_notification_delivery",
    "claim, provider, and finish order differed",
  );
  const message = providerPayload?.message as
    | Record<string, unknown>
    | undefined;
  assert(
    message?.token === "synthetic-fcm-token-p90",
    "dispatcher payload did not use the synthetic token",
  );
  const data = message?.data as Record<string, unknown> | undefined;
  assert(
    typeof data?.inbox_id === "string",
    "dispatcher payload omitted the opaque inbox id",
  );
  assert(
    !("group_id" in (data ?? {})) && !("title" in (data ?? {})),
    "dispatcher payload included private schedule context",
  );
});
