import { createNotificationDispatcherHandler } from "./index.ts";

const SERVICE_ROLE_KEY = "synthetic-service-role-test-value";
const ACCESS_TOKEN = "synthetic-provider-access-token";
const CLAIM: Record<string, unknown> = {
  outbox_id: "00000000-0000-4000-8000-000000000001",
  delivery_id: "00000000-0000-4000-8000-000000000002",
  lease_id: "00000000-0000-4000-8000-000000000003",
  inbox_id: "00000000-0000-4000-8000-000000000004",
  recipient_user_id: "00000000-0000-4000-8000-000000000005",
  installation_id: "00000000-0000-4000-8000-000000000006",
  binding_generation: 7,
  token: "synthetic-device-token-never-logged",
  notification_type: "group_comment",
};
const SECOND_CLAIM: Record<string, unknown> = {
  ...CLAIM,
  outbox_id: "00000000-0000-4000-8000-000000000011",
  delivery_id: "00000000-0000-4000-8000-000000000012",
  lease_id: "00000000-0000-4000-8000-000000000013",
  inbox_id: "00000000-0000-4000-8000-000000000014",
  installation_id: "00000000-0000-4000-8000-000000000016",
  token: "synthetic-second-device-token-never-logged",
};

type FinishedResult = {
  outcome: unknown;
  retrySeconds: unknown;
  error: unknown;
};

type HarnessOptions = {
  env?: Record<string, string | undefined>;
  claimData?: unknown;
  claimStatus?: number;
  accessTokenFails?: boolean;
  providerStatus?: number;
  providerBody?: string;
  providerFetchFails?: boolean;
  finishStatus?: number;
  finishReturnsFalse?: boolean;
  finishThrows?: boolean;
  finishFailedOutboxIds?: string[];
};

function claimsFor(options: HarnessOptions): Record<string, unknown>[] {
  if (options.claimData === undefined) return [CLAIM];
  return Array.isArray(options.claimData)
    ? options.claimData as Record<string, unknown>[]
    : [];
}

function createHarness(options: HarnessOptions = {}) {
  const env = new Map<string, string>([
    ["SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE_KEY],
    ["NOTIFICATION_DISPATCH_ENABLED", "true"],
    ["SUPABASE_URL", "https://supabase.example.test"],
    [
      "FIREBASE_SERVICE_ACCOUNT_JSON",
      JSON.stringify({
        project_id: "synthetic-project",
        client_email: "dispatcher@example.test",
        private_key: "synthetic-key-not-used-by-test",
      }),
    ],
  ]);
  for (const [name, value] of Object.entries(options.env ?? {})) {
    if (value === undefined) env.delete(name);
    else env.set(name, value);
  }

  const events: string[] = [];
  const calls = {
    claim: 0,
    finish: 0,
    accessToken: 0,
    provider: 0,
    unexpectedNetwork: 0,
  };
  const finishedResults: FinishedResult[] = [];

  const fakeFetch: typeof fetch = async (input, init) => {
    const inputUrl = input instanceof Request ? input.url : String(input);
    const requestMethod = init?.method ??
      (input instanceof Request ? input.method : "GET");
    const requestHeaders = new Headers(
      input instanceof Request ? input.headers : undefined,
    );
    if (init?.headers) {
      new Headers(init.headers).forEach((value, key) =>
        requestHeaders.set(key, value)
      );
    }
    let url: URL;
    try {
      url = new URL(inputUrl);
    } catch {
      calls.unexpectedNetwork++;
      throw new Error("unexpected-network-call");
    }

    if (
      url.origin === "https://supabase.example.test" &&
      url.pathname === "/rest/v1/rpc/claim_notification_outbox"
    ) {
      if (
        requestMethod !== "POST" ||
        requestHeaders.get("authorization") !== `Bearer ${SERVICE_ROLE_KEY}` ||
        requestHeaders.get("apikey") !== SERVICE_ROLE_KEY
      ) {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-claim-request");
      }
      let requestBody: Record<string, unknown>;
      try {
        requestBody = JSON.parse(
          typeof init?.body === "string" ? init.body : "",
        ) as Record<string, unknown>;
      } catch {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-claim-request");
      }
      if (requestBody.p_limit !== 20 || requestBody.p_lease_seconds !== 60) {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-claim-arguments");
      }
      calls.claim++;
      events.push("claim");
      if (options.claimStatus && options.claimStatus >= 400) {
        return Response.json({ message: "synthetic-claim-failure" }, {
          status: options.claimStatus,
        });
      }
      const data = options.claimData === undefined
        ? [CLAIM]
        : options.claimData;
      return Response.json(data);
    }

    if (
      url.origin === "https://supabase.example.test" &&
      url.pathname === "/rest/v1/rpc/finish_notification_delivery"
    ) {
      if (
        requestMethod !== "POST" ||
        requestHeaders.get("authorization") !== `Bearer ${SERVICE_ROLE_KEY}` ||
        requestHeaders.get("apikey") !== SERVICE_ROLE_KEY
      ) {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-finish-request");
      }
      calls.finish++;
      const body = typeof init?.body === "string" ? init.body : "";
      let requestBody: Record<string, unknown> = {};
      try {
        requestBody = JSON.parse(body) as Record<string, unknown>;
      } catch {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-finish-request");
      }
      const claimed = claimsFor(options).find((candidate) =>
        candidate.outbox_id === requestBody.p_outbox_id
      );
      if (
        !claimed ||
        requestBody.p_delivery_id !== claimed.delivery_id ||
        requestBody.p_lease_id !== claimed.lease_id ||
        requestBody.p_installation_id !== claimed.installation_id ||
        requestBody.p_binding_generation !== claimed.binding_generation
      ) {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-finish-arguments");
      }
      const outcome = requestBody.p_outcome;
      events.push(
        typeof outcome === "string" ? `finish:${outcome}` : "finish:unknown",
      );
      finishedResults.push({
        outcome,
        retrySeconds: requestBody.p_retry_seconds,
        error: requestBody.p_error,
      });
      if (options.finishThrows) {
        throw new TypeError("synthetic-finish-network-failure");
      }
      if (options.finishStatus && options.finishStatus >= 400) {
        return Response.json({ message: "synthetic-finish-failure" }, {
          status: options.finishStatus,
        });
      }
      return Response.json(
        options.finishReturnsFalse ||
          options.finishFailedOutboxIds?.includes(
            String(requestBody.p_outbox_id),
          )
          ? false
          : true,
      );
    }

    if (
      url.origin === "https://fcm.googleapis.com" &&
      url.pathname === "/v1/projects/synthetic-project/messages:send"
    ) {
      const providerBody = typeof init?.body === "string" ? init.body : "";
      let parsedProviderBody: Record<string, unknown>;
      try {
        parsedProviderBody = JSON.parse(providerBody) as Record<
          string,
          unknown
        >;
      } catch {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-provider-request");
      }
      const message = parsedProviderBody.message as
        | Record<string, unknown>
        | undefined;
      const providerToken = requestHeaders.get("authorization");
      const claimed = claimsFor(options).find((candidate) =>
        candidate.token === message?.token &&
        candidate.inbox_id ===
          (message?.data as Record<string, unknown> | undefined)?.inbox_id
      );
      if (
        requestMethod !== "POST" ||
        providerToken !== `Bearer ${ACCESS_TOKEN}` ||
        !claimed
      ) {
        calls.unexpectedNetwork++;
        throw new Error("unexpected-provider-request");
      }
      calls.provider++;
      events.push("provider:send");
      if (options.providerFetchFails) {
        throw new TypeError("synthetic-network-failure");
      }
      const status = options.providerStatus ?? 200;
      return new Response(options.providerBody ?? "{}", {
        status,
        headers: { "content-type": "application/json" },
      });
    }

    calls.unexpectedNetwork++;
    throw new Error("unexpected-network-call");
  };

  const handler = createNotificationDispatcherHandler({
    getEnv: (name) => env.get(name),
    fetch: fakeFetch,
    getAccessToken: async () => {
      calls.accessToken++;
      events.push("provider:authorize");
      if (options.accessTokenFails) {
        throw new Error("synthetic-provider-auth-failure");
      }
      return ACCESS_TOKEN;
    },
  });

  return { handler, env, events, calls, finishedResults };
}

function authorizedRequest(
  method = "POST",
  authorization = `Bearer ${SERVICE_ROLE_KEY}`,
) {
  return new Request("https://dispatcher.example.test/", {
    method,
    headers: authorization ? { authorization } : {},
  });
}

async function jsonBody(response: Response): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error("assertion_failed");
  }
}

Deno.test("method and bearer gates reject without claim, provider, finish, or network calls", async () => {
  const cases = [
    {
      request: authorizedRequest("GET"),
      status: 405,
      code: "method_not_allowed",
    },
    {
      request: authorizedRequest("POST", ""),
      status: 401,
      code: "unauthorized",
    },
    {
      request: authorizedRequest("POST", "Bearer synthetic-wrong-value"),
      status: 401,
      code: "unauthorized",
    },
  ];

  for (const item of cases) {
    const harness = createHarness();
    const response = await harness.handler(item.request);
    assertEquals(response.status, item.status);
    assertEquals((await jsonBody(response)).error, item.code);
    assertEquals(harness.calls, {
      claim: 0,
      finish: 0,
      accessToken: 0,
      provider: 0,
      unexpectedNetwork: 0,
    });
  }
});

Deno.test("disabled and incomplete or invalid configuration stop before claim and provider work", async () => {
  const cases = [
    {
      env: { NOTIFICATION_DISPATCH_ENABLED: undefined },
      status: 202,
      code: "dispatcher_disabled",
    },
    {
      env: { NOTIFICATION_DISPATCH_ENABLED: "false" },
      status: 202,
      code: "dispatcher_disabled",
    },
    {
      env: { SUPABASE_URL: undefined },
      status: 503,
      code: "dispatcher_configuration_missing",
    },
    {
      env: { FIREBASE_SERVICE_ACCOUNT_JSON: undefined },
      status: 503,
      code: "dispatcher_configuration_missing",
    },
    {
      env: { FIREBASE_SERVICE_ACCOUNT_JSON: "{" },
      status: 503,
      code: "dispatcher_configuration_invalid",
    },
    {
      env: {
        FIREBASE_SERVICE_ACCOUNT_JSON: JSON.stringify({
          project_id: "synthetic-project",
          client_email: "dispatcher@example.test",
        }),
      },
      status: 503,
      code: "dispatcher_configuration_invalid",
    },
  ];

  for (const item of cases) {
    const harness = createHarness({ env: item.env });
    const response = await harness.handler(authorizedRequest());
    assertEquals(response.status, item.status);
    const body = await jsonBody(response);
    assertEquals(body.error ?? body.reason, item.code);
    assertEquals(harness.calls.claim, 0);
    assertEquals(harness.calls.provider, 0);
    assertEquals(harness.calls.finish, 0);
    assertEquals(harness.calls.accessToken, 0);
    assertEquals(harness.calls.unexpectedNetwork, 0);
  }
});

Deno.test("empty claim returns zero processed without requesting a provider token or sending", async () => {
  const harness = createHarness({ claimData: [] });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 200);
  assertEquals(await jsonBody(response), { processed: 0 });
  assertEquals(harness.events, ["claim"]);
  assertEquals(harness.calls.claim, 1);
  assertEquals(harness.calls.accessToken, 0);
  assertEquals(harness.calls.provider, 0);
  assertEquals(harness.calls.finish, 0);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("claim failure returns a sanitized server error and causes no provider or finish call", async () => {
  const harness = createHarness({ claimStatus: 500 });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 503);
  assertEquals((await jsonBody(response)).error, "claim_failed");
  assertEquals(harness.events, ["claim"]);
  assertEquals(harness.calls.claim, 1);
  assertEquals(harness.calls.accessToken, 0);
  assertEquals(harness.calls.provider, 0);
  assertEquals(harness.calls.finish, 0);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("claimed job sends once and finishes only after claim and provider success", async () => {
  const harness = createHarness({ providerStatus: 200 });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 200);
  assertEquals(await jsonBody(response), { processed: 1 });
  assertEquals(harness.events, [
    "claim",
    "provider:authorize",
    "provider:send",
    "finish:sent",
  ]);
  assertEquals(harness.calls.claim, 1);
  assertEquals(harness.calls.accessToken, 1);
  assertEquals(harness.calls.provider, 1);
  assertEquals(harness.calls.finish, 1);
  assertEquals(harness.finishedResults, [{
    outcome: "sent",
    retrySeconds: null,
    error: null,
  }]);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("retryable provider response and network error finish as retry with bounded delays", async () => {
  const cases = [
    {
      options: { providerStatus: 503 },
      retrySeconds: 30,
      error: "fcm_http_503",
    },
    {
      options: { providerFetchFails: true },
      retrySeconds: 60,
      error: "provider_timeout_or_network",
    },
  ];

  for (const item of cases) {
    const harness = createHarness(item.options);
    const response = await harness.handler(authorizedRequest());

    assertEquals(response.status, 200);
    assertEquals(await jsonBody(response), { processed: 1 });
    assertEquals(harness.events, [
      "claim",
      "provider:authorize",
      "provider:send",
      "finish:retry",
    ]);
    assertEquals(harness.finishedResults, [{
      outcome: "retry",
      retrySeconds: item.retrySeconds,
      error: item.error,
    }]);
    assertEquals(harness.calls.claim, 1);
    assertEquals(harness.calls.provider, 1);
    assertEquals(harness.calls.finish, 1);
    assertEquals(harness.calls.unexpectedNetwork, 0);
  }
});

Deno.test("unregistered provider token is finished as invalid_token without retry delay", async () => {
  const harness = createHarness({
    providerStatus: 404,
    providerBody: '{"error":{"status":"NOT_FOUND"}}',
  });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 200);
  assertEquals(await jsonBody(response), { processed: 1 });
  assertEquals(harness.events, [
    "claim",
    "provider:authorize",
    "provider:send",
    "finish:invalid_token",
  ]);
  assertEquals(harness.finishedResults, [{
    outcome: "invalid_token",
    retrySeconds: null,
    error: "fcm_unregistered",
  }]);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("provider authorization failure retries each claim without attempting provider send", async () => {
  const harness = createHarness({ accessTokenFails: true });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 503);
  assertEquals(await jsonBody(response), {
    processed: 1,
    provider: "unavailable",
  });
  assertEquals(harness.events, ["claim", "provider:authorize", "finish:retry"]);
  assertEquals(harness.finishedResults, [{
    outcome: "retry",
    retrySeconds: 120,
    error: "provider_auth_unavailable",
  }]);
  assertEquals(harness.calls.provider, 0);
  assertEquals(harness.calls.finish, 1);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("P66 finish RPC failures and stale leases are not counted as processed", async () => {
  for (
    const options of [
      { finishStatus: 500 },
      { finishReturnsFalse: true },
      { finishThrows: true },
    ]
  ) {
    const harness = createHarness(options);
    const response = await harness.handler(authorizedRequest());

    assertEquals(response.status, 200);
    assertEquals(await jsonBody(response), { processed: 0, unconfirmed: 1 });
    assertEquals(harness.calls.claim, 1);
    assertEquals(harness.calls.provider, 1);
    assertEquals(harness.calls.finish, 1);
    assertEquals(harness.events, [
      "claim",
      "provider:authorize",
      "provider:send",
      "finish:sent",
    ]);
    assertEquals(harness.calls.unexpectedNetwork, 0);
  }
});

Deno.test("P66 provider failure with unconfirmed retry finish is not counted processed", async () => {
  const harness = createHarness({
    providerStatus: 503,
    finishReturnsFalse: true,
  });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 200);
  assertEquals(await jsonBody(response), { processed: 0, unconfirmed: 1 });
  assertEquals(harness.finishedResults, [{
    outcome: "retry",
    retrySeconds: 30,
    error: "fcm_http_503",
  }]);
  assertEquals(harness.calls.provider, 1);
  assertEquals(harness.calls.finish, 1);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});

Deno.test("P66 batch reports only jobs with confirmed finish results as processed", async () => {
  const harness = createHarness({
    claimData: [CLAIM, SECOND_CLAIM],
    finishFailedOutboxIds: [String(SECOND_CLAIM.outbox_id)],
  });
  const response = await harness.handler(authorizedRequest());

  assertEquals(response.status, 200);
  assertEquals(await jsonBody(response), { processed: 1, unconfirmed: 1 });
  assertEquals(harness.calls.claim, 1);
  assertEquals(harness.calls.provider, 2);
  assertEquals(harness.calls.finish, 2);
  assertEquals(harness.calls.unexpectedNetwork, 0);
});
