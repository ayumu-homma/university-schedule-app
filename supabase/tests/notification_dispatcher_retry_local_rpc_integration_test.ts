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

Deno.test("dispatcher retry response reaches the isolated finish RPC", async () => {
  const jwtSecret = Deno.env.get("PGRST_JWT_SECRET");
  assert(jwtSecret, "isolated PostgREST signing input is unavailable");
  const serviceRoleKey = await localServiceRoleJwt(jwtSecret);
  const order: string[] = [];
  let providerCalls = 0;
  let finishOutcome: unknown;
  let finishRetrySeconds: unknown;
  let providerPayload: Record<string, unknown> | undefined;

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
            project_id: "synthetic-p91-project",
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
        if (rpcName === "finish_notification_delivery") {
          const args = JSON.parse(String(init?.body)) as Record<
            string,
            unknown
          >;
          finishOutcome = args.p_outcome;
          finishRetrySeconds = args.p_retry_seconds;
        }
        // This isolated stack exposes PostgREST directly without Kong.
        parsedUrl.pathname = parsedUrl.pathname.replace(
          /^\/rest\/v1(?=\/)/,
          "",
        );
        return await globalThis.fetch(parsedUrl, init);
      }
      if (requestUrl.startsWith("https://fcm.googleapis.com/v1/projects/")) {
        providerCalls++;
        order.push("provider");
        assert(
          new Headers(init?.headers).get("authorization") ===
            "Bearer synthetic-provider-bearer",
          "provider credential mismatch",
        );
        providerPayload = JSON.parse(String(init?.body)) as Record<
          string,
          unknown
        >;
        return new Response(
          JSON.stringify({
            error: { status: "UNAVAILABLE", message: "synthetic failure" },
          }),
          { status: 503, headers: { "content-type": "application/json" } },
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
  const responseBody = await response.json() as {
    processed?: number;
    unconfirmed?: number;
  };

  assert(response.status === 200, `dispatcher status=${response.status}`);
  assert(
    responseBody.processed === 1,
    "dispatcher did not confirm the retry finish",
  );
  assert(
    responseBody.unconfirmed === undefined,
    "retry finish was reported unconfirmed",
  );
  assert(providerCalls === 1, "fake provider was not called exactly once");
  assert(
    order.join(",") ===
      "rpc:claim_notification_outbox,provider,rpc:finish_notification_delivery",
    "claim, provider, and finish order differed",
  );
  assert(finishOutcome === "retry", "503 was not finished as retry");
  assert(
    finishRetrySeconds === 30,
    "503 retry delay differed from provider contract",
  );
  const message = providerPayload?.message as
    | Record<string, unknown>
    | undefined;
  assert(
    message?.token === "synthetic-fcm-token-p91",
    "synthetic job token mismatch",
  );
  const data = message?.data as Record<string, unknown> | undefined;
  assert(
    typeof data?.inbox_id === "string" && !("group_id" in data) &&
      !("title" in data),
    "provider payload did not remain opaque",
  );
});
