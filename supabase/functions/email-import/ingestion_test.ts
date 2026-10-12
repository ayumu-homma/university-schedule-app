import { ingestionBounds, runIncrementalEmailIngestion } from "./ingestion.ts";
import { FakeEmailConnector } from "./test_support/fake_email_connector.ts";
import { type ProviderEmailMessage, SafeEmailError } from "./types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

const fixedNow = new Date("2030-02-01T00:00:00.000Z");

function message(
  id: string,
  overrides: Partial<ProviderEmailMessage> = {},
): ProviderEmailMessage {
  return {
    providerMessageId: id,
    providerThreadId: `thread-${id}`,
    receivedAt: "2030-01-20T12:00:00.000Z",
    subject: "情報数学 課題",
    sender: "course@example.invalid",
    body: "提出期限: 2030年2月3日 17:00",
    bodyKind: "text",
    ...overrides,
  };
}

function runtime(sleeps: number[] = []) {
  return {
    now: () => fixedNow,
    sleep: (delayMs: number) => {
      sleeps.push(delayMs);
      return Promise.resolve();
    },
    jitter: (_attempt: number, _delayMs: number) => 0,
  };
}

Deno.test("first sync clamps lookback and excludes older provider results", async () => {
  const connector = new FakeEmailConnector([{
    messages: [
      message("recent"),
      message("too-old", { receivedAt: "2029-01-01T00:00:00.000Z" }),
    ],
    nextCursor: "opaque-next",
    hasMore: false,
  }]);

  const result = await runIncrementalEmailIngestion(
    connector,
    { firstSyncLookbackDays: 365 },
    runtime(),
  );
  assertEquals(
    connector.requests[0]?.receivedAfter,
    new Date(
      fixedNow.getTime() - ingestionBounds.maximumLookbackDays * 86_400_000,
    ).toISOString(),
    "lookback is capped",
  );
  assertEquals(
    result.sources.map((source) => source.provider_message_id),
    ["recent"],
    "old results are ignored defensively",
  );
  assert(result.connection.status === "connected", "sync succeeds");
});

Deno.test("incremental sync forwards an opaque cursor without interpretation", async () => {
  const opaqueCursor = "opaque+/==:do.not.decode.v1";
  const connector = new FakeEmailConnector([{
    messages: [message("incremental")],
    nextCursor: "next+/opaque==",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { cursor: opaqueCursor },
    runtime(),
  );

  assert(connector.requests[0]?.cursor === opaqueCursor, "cursor is unchanged");
  assert(
    connector.requests[0]?.receivedAfter === null,
    "incremental fetch has no lookback query",
  );
  assert(result.nextCursor === "next+/opaque==", "next cursor stays opaque");
});

Deno.test("incremental pages advance the cursor and deduplicate a repeated fixture", async () => {
  const repeated = message("same-provider-message");
  const connector = new FakeEmailConnector([
    {
      messages: [repeated],
      nextCursor: "opaque-page-two",
      hasMore: true,
    },
    {
      messages: [repeated],
      nextCursor: "opaque-final",
      hasMore: false,
    },
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {},
    runtime(),
  );

  assertEquals(connector.requests.length, 2, "both pages fetched");
  assert(
    connector.requests[1]?.cursor === "opaque-page-two",
    "cursor advances to the next page exactly",
  );
  assert(result.nextCursor === "opaque-final", "final cursor is returned");
  assertEquals(result.sources.length, 1, "repeated source is emitted once");
});

Deno.test("expired cursor recovers once through a bounded lookback", async () => {
  const connector = new FakeEmailConnector([
    new SafeEmailError("cursor_expired"),
    {
      messages: [message("recovered")],
      nextCursor: "recovered-cursor",
      hasMore: false,
    },
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { cursor: "expired-opaque", firstSyncLookbackDays: 7 },
    runtime(),
  );

  assertEquals(connector.requests.length, 2, "one recovery request");
  assert(connector.requests[0]?.cursor === "expired-opaque", "original cursor");
  assert(connector.requests[1]?.cursor === null, "recovery resets cursor");
  assert(
    connector.requests[1]?.receivedAfter === "2030-01-25T00:00:00.000Z",
    "recovery uses bounded lookback",
  );
  assert(result.recoveredFromCursorExpiry, "recovery is explicit");
  assertEquals(result.events, [{
    kind: "cursor_recovery",
    category: "cursor_expired",
    attempt: null,
    delayMs: null,
  }], "safe recovery event");
  assert(result.connection.status === "connected", "recovery completes");
});

Deno.test("rate-limit retry honors Retry-After with injected deterministic delay", async () => {
  const sleeps: number[] = [];
  const connector = new FakeEmailConnector([
    new SafeEmailError("rate_limited", { retryAfterMs: 1_500 }),
    { messages: [], nextCursor: "after-rate-limit", hasMore: false },
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {
      retryPolicy: {
        maximumAttempts: 3,
        baseDelayMs: 100,
        maximumDelayMs: 2_000,
      },
    },
    runtime(sleeps),
  );

  assertEquals(sleeps, [1_500], "Retry-After wins over backoff");
  assertEquals(result.events, [{
    kind: "retry",
    category: "rate_limited",
    attempt: 1,
    delayMs: 1_500,
  }], "retry transition is safe and deterministic");
  assert(result.connection.status === "connected", "retry succeeds");
});

Deno.test("retry jitter is injected, deterministic, and bounded", async () => {
  const sleeps: number[] = [];
  const connector = new FakeEmailConnector([
    new SafeEmailError("network_unavailable"),
    { messages: [], nextCursor: "after-jitter", hasMore: false },
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {
      retryPolicy: {
        maximumAttempts: 2,
        baseDelayMs: 100,
        maximumDelayMs: 1_000,
      },
    },
    {
      ...runtime(sleeps),
      jitter: (_attempt, _delayMs) => 25,
    },
  );

  assertEquals(sleeps, [125], "injected jitter is added to backoff");
  assert(result.connection.status === "connected", "retry succeeds");
});

Deno.test("long Retry-After stops bounded in-process retry", async () => {
  const sleeps: number[] = [];
  const connector = new FakeEmailConnector([
    new SafeEmailError("rate_limited", { retryAfterMs: 120_000 }),
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {
      retryPolicy: {
        maximumAttempts: 3,
        baseDelayMs: 100,
        maximumDelayMs: 10_000,
      },
    },
    runtime(sleeps),
  );

  assertEquals(connector.requests.length, 1, "does not retry before hint");
  assertEquals(sleeps, [], "no long in-process sleep");
  assert(
    result.connection.status === "rate_limited",
    "explicit throttle state",
  );
  assert(result.connection.retryAfterSeconds === 120, "safe retry hint");
  assert(
    result.connection.errorCategory === null,
    "matches mobile state model",
  );
});

Deno.test("provider Retry-After is capped to the mobile contract", async () => {
  const connector = new FakeEmailConnector([
    new SafeEmailError("rate_limited", { retryAfterMs: 172_800_000 }),
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {
      retryPolicy: {
        maximumAttempts: 1,
        baseDelayMs: 100,
        maximumDelayMs: 1_000,
      },
    },
    runtime([]),
  );

  assert(result.connection.status === "rate_limited", "rate limit state");
  assert(
    result.connection.retryAfterSeconds ===
      ingestionBounds.maximumRetryAfterSeconds,
    "retry hint is capped to one day",
  );
});

Deno.test("timeouts use bounded attempts and end in a safe failed state", async () => {
  const sleeps: number[] = [];
  const connector = new FakeEmailConnector([
    new SafeEmailError("timeout"),
    new SafeEmailError("timeout"),
    new SafeEmailError("timeout"),
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {
      retryPolicy: {
        maximumAttempts: 3,
        baseDelayMs: 100,
        maximumDelayMs: 1_000,
      },
    },
    runtime(sleeps),
  );

  assertEquals(connector.requests.length, 3, "attempt count is bounded");
  assertEquals(sleeps, [100, 200], "exponential backoff");
  assert(result.connection.status === "failed", "timeout failure state");
  assert(result.connection.errorCategory === "timeout", "safe category only");
});

Deno.test("OAuth revocation never retries and requires reauthorization", async () => {
  const connector = new FakeEmailConnector([
    new SafeEmailError("authorization_revoked"),
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    {},
    runtime(),
  );

  assertEquals(connector.requests.length, 1, "revocation is not retryable");
  assert(
    result.connection.status === "reauth_required",
    "explicit reauth state",
  );
  assert(result.connection.errorCategory === null, "no provider diagnostic");
});

Deno.test("oversized content yields a metadata-only failed source", async () => {
  const rawSecret = "never-persist-this-oversized-body";
  const connector = new FakeEmailConnector([{
    messages: [message("oversized", {
      body: rawSecret.repeat(20_000),
    })],
    nextCursor: "after-oversized",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(connector, {}, runtime());
  const source = result.sources[0];

  assert(source?.processing_state === "failed", "source records failure");
  assert(source.error_category === "oversized_content", "safe reason code");
  assert(
    source.evidence_metadata.length === 0,
    "no oversized evidence retained",
  );
  assert(!JSON.stringify(source).includes(rawSecret), "body is not persisted");
});

Deno.test("malformed content yields an allow-listed failed source", async () => {
  const connector = new FakeEmailConnector([{
    messages: [message("malformed", { body: "bad\ud800encoding" })],
    nextCursor: "after-malformed",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(connector, {}, runtime());
  const source = result.sources[0];

  assert(source?.processing_state === "failed", "source records failure");
  assert(source.error_category === "malformed_content", "safe reason code");
  assert(
    source.evidence_metadata.length === 0,
    "no malformed evidence retained",
  );
});

Deno.test("missing provider thread ID cannot produce a successful source", async () => {
  const connector = new FakeEmailConnector([{
    messages: [message("missing-thread", { providerThreadId: null })],
    nextCursor: "after-missing-thread",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(connector, {}, runtime());
  const source = result.sources[0];

  assert(source?.processing_state === "failed", "source is not successful");
  assert(source.error_category === "malformed_content", "safe reason code");
  assert(
    /^failed:[0-9a-f]{64}$/.test(source.provider_thread_id ?? ""),
    "invalid thread is replaced by an irreversible stable surrogate",
  );
});

Deno.test("invalid provider calendar timestamps never enter source metadata", async () => {
  for (
    const receivedAt of [
      "2030-02-30T12:00:00Z",
      "2030-07-01T24:00:00Z",
      "2030-07-01T12:00:00+15:00",
    ]
  ) {
    const connector = new FakeEmailConnector([{
      messages: [message("invalid-received", { receivedAt })],
      nextCursor: "after-invalid-received",
      hasMore: false,
    }]);
    const result = await runIncrementalEmailIngestion(connector, {}, runtime());
    assert(result.connection.status === "failed", `${receivedAt}: failed`);
    assert(
      result.connection.errorCategory === "malformed_content",
      `${receivedAt}: safe category`,
    );
    assert(result.sources.length === 0, `${receivedAt}: no invalid source`);
  }
});

Deno.test("page and message budgets stop an unbounded provider stream", async () => {
  const connector = new FakeEmailConnector([
    {
      messages: [message("one")],
      nextCursor: "page-2",
      hasMore: true,
    },
    {
      messages: [message("two")],
      nextCursor: "page-3",
      hasMore: true,
    },
  ]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { maximumPages: 1, maximumMessages: 999_999 },
    runtime(),
  );

  assertEquals(connector.requests.length, 1, "page budget is enforced");
  assert(result.sources.length === 1, "one page is processed");
  assert(result.hasMore, "continuation is preserved for a later job");
});
