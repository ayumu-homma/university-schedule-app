import { createClient } from "npm:@supabase/supabase-js@2";
import {
  classifyProviderResponse,
  fcmMessage,
  getAccessToken,
} from "./provider.ts";

type Claim = {
  outbox_id: string;
  delivery_id: string;
  lease_id: string;
  inbox_id: string;
  recipient_user_id: string;
  installation_id: string;
  binding_generation: number;
  token: string;
  notification_type: string;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

type RpcClient = {
  rpc(name: string, args?: Record<string, unknown>): Promise<{
    data: unknown;
    error: unknown;
  }>;
};

type ServiceAccount = Parameters<typeof getAccessToken>[0];

type DispatcherDependencies = {
  getEnv: (name: string) => string | undefined;
  fetch: typeof fetch;
  getAccessToken: (serviceAccount: ServiceAccount) => Promise<string>;
};

/** The exported handler uses the same authorization and dispatch gates in production and tests. */
export function createNotificationDispatcherHandler(
  overrides: Partial<DispatcherDependencies> = {},
): (request: Request) => Promise<Response> {
  const dependencies: DispatcherDependencies = {
    getEnv: (name) => Deno.env.get(name),
    fetch,
    getAccessToken,
    ...overrides,
  };

  return async (request) => {
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    const serviceRoleKey = dependencies.getEnv("SUPABASE_SERVICE_ROLE_KEY");
    const authorization = request.headers.get("authorization") ?? "";
    if (
      !serviceRoleKey ||
      !constantTimeEqual(authorization, `Bearer ${serviceRoleKey}`)
    ) {
      return json({ error: "unauthorized" }, 401);
    }
    if (dependencies.getEnv("NOTIFICATION_DISPATCH_ENABLED") !== "true") {
      return json({ accepted: false, reason: "dispatcher_disabled" }, 202);
    }
    const serviceUrl = dependencies.getEnv("SUPABASE_URL");
    const serviceAccountJson = dependencies.getEnv(
      "FIREBASE_SERVICE_ACCOUNT_JSON",
    );
    if (!serviceUrl || !serviceAccountJson) {
      return json({ error: "dispatcher_configuration_missing" }, 503);
    }

    let serviceAccount: ServiceAccount;
    try {
      serviceAccount = JSON.parse(serviceAccountJson) as ServiceAccount;
    } catch {
      return json({ error: "dispatcher_configuration_invalid" }, 503);
    }
    const projectId = serviceAccount.project_id;
    if (
      !projectId || !serviceAccount.client_email || !serviceAccount.private_key
    ) {
      return json({ error: "dispatcher_configuration_invalid" }, 503);
    }

    const client = createClient(serviceUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { fetch: dependencies.fetch },
    }) as unknown as RpcClient;
    const { data, error } = await client.rpc("claim_notification_outbox", {
      p_limit: 20,
      p_lease_seconds: 60,
    });
    if (error) return json({ error: "claim_failed" }, 503);

    const claims = Array.isArray(data) ? data as Claim[] : [];
    if (claims.length === 0) return json({ processed: 0 });
    let accessToken: string;
    try {
      accessToken = await dependencies.getAccessToken(serviceAccount);
    } catch {
      const finished = await Promise.all(
        claims.map((claim) =>
          finish(client, claim, {
            outcome: "retry",
            retrySeconds: 120,
            error: "provider_auth_unavailable",
          })
        ),
      );
      const processed = finished.filter(Boolean).length;
      return json({
        processed,
        ...(processed < claims.length
          ? { unconfirmed: claims.length - processed }
          : {}),
        provider: "unavailable",
      }, 503);
    }

    const finished = await Promise.all(claims.map(async (claim) => {
      let response: Response;
      try {
        response = await dependencies.fetch(
          `https://fcm.googleapis.com/v1/projects/${
            encodeURIComponent(projectId)
          }/messages:send`,
          {
            method: "POST",
            signal: AbortSignal.timeout(12_000),
            headers: {
              authorization: `Bearer ${accessToken}`,
              "content-type": "application/json",
            },
            body: JSON.stringify(fcmMessage(claim)),
          },
        );
      } catch {
        // A timeout may happen after FCM accepted the message. Retry is at least
        // once; the same inbox id lets the client deduplicate that delivery.
        return await finish(client, claim, {
          outcome: "retry",
          retrySeconds: retryDelay(2),
          error: "provider_timeout_or_network",
        });
      }
      const responseBody = await response.text().catch(() => "");
      const result = classifyProviderResponse(response.status, responseBody);
      return await finish(client, claim, {
        ...result,
        providerMessageId: response.headers.get("x-fcm-message-id") ??
          undefined,
      });
    }));

    const processed = finished.filter(Boolean).length;
    return json({
      processed,
      ...(processed < claims.length
        ? { unconfirmed: claims.length - processed }
        : {}),
    });
  };
}

if (import.meta.main) {
  Deno.serve(createNotificationDispatcherHandler());
}

function retryDelay(attempt: number): number {
  return Math.min(3600, 15 * 2 ** Math.min(attempt, 7));
}

function constantTimeEqual(actual: string, expected: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(actual);
  const b = encoder.encode(expected);
  let diff = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index++) {
    diff |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return diff === 0;
}

async function finish(
  client: RpcClient,
  claim: Claim,
  result: {
    outcome: "sent" | "retry" | "permanent" | "invalid_token";
    retrySeconds?: number;
    error?: string;
    providerMessageId?: string;
  },
): Promise<boolean> {
  try {
    const { data, error } = await client.rpc("finish_notification_delivery", {
      p_outbox_id: claim.outbox_id,
      p_delivery_id: claim.delivery_id,
      p_lease_id: claim.lease_id,
      p_installation_id: claim.installation_id,
      p_binding_generation: claim.binding_generation,
      p_outcome: result.outcome,
      p_provider_message_id: result.providerMessageId ?? null,
      p_retry_seconds: result.retrySeconds ?? null,
      p_error: result.error ?? null,
    });
    return error === null && data === true;
  } catch {
    return false;
  }
}
