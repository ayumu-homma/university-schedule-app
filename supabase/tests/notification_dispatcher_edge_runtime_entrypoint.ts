import { createNotificationDispatcherHandler } from "../functions/notification-dispatcher/index.ts";

const localRestUrl = Deno.env.get("P125_INTERNAL_REST_URL");
const expectedProviderToken = Deno.env.get("P125_FAKE_PROVIDER_TOKEN");
if (!localRestUrl || !expectedProviderToken) {
  throw new Error("P125 isolated test configuration missing");
}

const sequence: string[] = [];
let fakeProviderCalls = 0;
let payloadContractValid = false;

const handler = createNotificationDispatcherHandler({
  async getAccessToken(): Promise<string> {
    return "p125-synthetic-provider-bearer";
  },
  async fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    const requestUrl = input instanceof Request ? input.url : String(input);
    const parsed = new URL(requestUrl);
    const expectedOrigin = new URL(localRestUrl).origin;

    if (
      parsed.origin === expectedOrigin &&
      parsed.pathname === "/rest/v1/rpc/claim_notification_outbox" &&
      init?.method === "POST"
    ) {
      sequence.push("claim");
      parsed.pathname = "/rpc/claim_notification_outbox";
      return await globalThis.fetch(parsed, init);
    }
    if (
      parsed.origin === expectedOrigin &&
      parsed.pathname === "/rest/v1/rpc/finish_notification_delivery" &&
      init?.method === "POST"
    ) {
      sequence.push("finish");
      parsed.pathname = "/rpc/finish_notification_delivery";
      return await globalThis.fetch(parsed, init);
    }
    if (
      requestUrl ===
        "https://fcm.googleapis.com/v1/projects/p125-synthetic-project/messages:send" &&
      init?.method === "POST" &&
      new Headers(init.headers).get("authorization") ===
        "Bearer p125-synthetic-provider-bearer"
    ) {
      sequence.push("provider");
      fakeProviderCalls++;
      const body = JSON.parse(String(init.body)) as {
        message?: { token?: unknown; data?: Record<string, unknown> };
      };
      const data = body.message?.data;
      payloadContractValid = body.message?.token === expectedProviderToken &&
        typeof data?.inbox_id === "string" &&
        Object.keys(data).length === 1;
      if (!payloadContractValid) {
        throw new Error("P125 fake provider payload contract failed");
      }
      return new Response(JSON.stringify({ name: "p125-synthetic-message" }), {
        status: 200,
        headers: { "x-fcm-message-id": "p125-synthetic-message" },
      });
    }
    throw new Error("P125 blocked an unexpected network request");
  },
});

Deno.serve(async (request) => {
  const response = await handler(request);
  const headers = new Headers(response.headers);
  headers.set("x-p125-sequence", sequence.join(","));
  headers.set("x-p125-provider-calls", String(fakeProviderCalls));
  headers.set("x-p125-payload-contract", String(payloadContractValid));
  return new Response(response.body, { status: response.status, headers });
});
