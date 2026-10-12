import type { EmailTaskExtractor } from "./extraction.ts";
import { runIncrementalEmailIngestion } from "./ingestion.ts";
import { FakeEmailConnector } from "./test_support/fake_email_connector.ts";
import { RuleBasedEmailTaskExtractor } from "./test_support/rule_based_email_task_extractor.ts";
import type { ProviderEmailMessage } from "./types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function providerMessage(
  overrides: Partial<ProviderEmailMessage> = {},
): ProviderEmailMessage {
  return {
    providerMessageId: "synthetic-message-pipeline",
    providerThreadId: "synthetic-thread-pipeline",
    receivedAt: "2030-07-01T00:00:00.000Z",
    subject: "【情報科学A】第3回レポート",
    sender: "合成大学 <course@example.invalid>",
    bodyKind: "html",
    body: [
      "<p>課題名: 第3回レポート</p>",
      '<img src="https://tracker.invalid/pixel">',
      "<p>提出期限: 2030年7月18日 23:59</p>",
      "<p>科目名: 情報科学A</p>",
      "<p>FULL-TRANSIENT-BODY-MARKER-MUST-NOT-PERSIST</p>",
    ].join(""),
    ...overrides,
  };
}

function runtime() {
  return {
    now: () => new Date("2030-07-02T00:00:00.000Z"),
    sleep: (_delayMs: number) => Promise.resolve(),
    jitter: (_attempt: number, _delayMs: number) => 0,
  };
}

Deno.test("pipeline converts transient sanitized input into one safe validated fetch item", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (): Promise<Response> => {
    fetchCalls += 1;
    return Promise.reject(new Error("network forbidden"));
  };
  try {
    const connector = new FakeEmailConnector([{
      messages: [providerMessage()],
      nextCursor: "opaque-after-candidate",
      hasMore: false,
    }]);
    const result = await runIncrementalEmailIngestion(
      connector,
      {
        extraction: {
          extractor: new RuleBasedEmailTaskExtractor(),
          timezone: "Asia/Tokyo",
        },
      },
      runtime(),
    );

    assert(result.connection.status === "connected", "sync succeeds");
    assert(result.sources.length === 1, "one source");
    assert(result.items.length === 1, "one item");
    assert(result.sources[0]?.processing_state === "processed", "processed");
    const item = result.items[0]!;
    assert(item.providerThreadId === "synthetic-thread-pipeline", "thread ID");
    assert(item.candidate !== null, "candidate is present");
    assert(item.candidate.schema_version === "1.0", "validated schema");
    assert(item.candidate.candidate_type === "assignment", "candidate type");
    const candidateDue = item.candidate.due;
    assert(
      typeof candidateDue === "object" &&
        candidateDue !== null &&
        "timezone" in candidateDue &&
        candidateDue.timezone === "Asia/Tokyo",
      "trusted timezone",
    );
    assert(
      item.candidate.requires_user_confirmation === true,
      "confirmation remains required",
    );
    assert(item.errorCategory === null, "successful item has no error");

    const serialized = JSON.stringify(result);
    for (
      const forbidden of [
        "tracker.invalid",
        "FULL-TRANSIENT-BODY-MARKER-MUST-NOT-PERSIST",
        "course@example.invalid",
      ]
    ) {
      assert(!serialized.includes(forbidden), `${forbidden} is transient`);
    }
    assert(!("body" in item), "fetch item has no body property");
    assert(!("subject" in item), "fetch item has no subject property");
    assert(!("sender" in item), "fetch item has no sender property");
    assert(fetchCalls === 0, "pipeline performs no fetch or URL operation");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

class ScriptedExtractor implements EmailTaskExtractor {
  constructor(readonly result: unknown, readonly failure?: unknown) {}

  calls = 0;

  extract(): Promise<unknown> {
    this.calls += 1;
    return this.failure === undefined
      ? Promise.resolve(this.result)
      : Promise.reject(this.failure);
  }
}

Deno.test("pipeline revalidates every extractor result before emitting an item", async () => {
  const extractor = new ScriptedExtractor({
    schema_version: "1.0",
    candidate_type: "assignment",
    raw_body: "synthetic-secret-should-be-rejected",
  });
  const connector = new FakeEmailConnector([{
    messages: [providerMessage({ bodyKind: "text", body: "課題名: 合成課題" })],
    nextCursor: "after-invalid-extraction",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { extraction: { extractor, timezone: "Asia/Tokyo" } },
    runtime(),
  );

  assert(extractor.calls === 1, "extractor called once");
  assert(result.items.length === 1, "failed item crosses safe boundary");
  assert(result.items[0]?.candidate === null, "no invalid candidate crosses");
  assert(
    result.items[0]?.errorCategory === "invalid_extraction",
    "safe endpoint reason",
  );
  assert(result.sources[0]?.processing_state === "failed", "failed state");
  assert(
    result.sources[0]?.error_category === "invalid_extraction",
    "allow-listed error",
  );
  assert(
    !JSON.stringify(result).includes("synthetic-secret"),
    "invalid output is discarded",
  );
});

Deno.test("pipeline maps extractor exceptions to metadata-only internal failure", async () => {
  const extractor = new ScriptedExtractor(
    null,
    new Error("synthetic-secret-provider-diagnostic"),
  );
  const connector = new FakeEmailConnector([{
    messages: [providerMessage({ bodyKind: "text", body: "課題名: 合成課題" })],
    nextCursor: "after-extractor-failure",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { extraction: { extractor, timezone: "Asia/Tokyo" } },
    runtime(),
  );

  assert(result.items.length === 1, "safe failed item is returned");
  assert(result.items[0]?.candidate === null, "failed item has no candidate");
  assert(result.items[0]?.errorCategory === "internal_error", "endpoint error");
  assert(result.sources[0]?.processing_state === "failed", "failed state");
  assert(result.sources[0]?.error_category === "internal_error", "safe error");
  assert(!JSON.stringify(result).includes("synthetic-secret"), "no diagnostic");
});

Deno.test("sanitizer overflow fails before extraction is invoked", async () => {
  const extractor = new ScriptedExtractor(null);
  const connector = new FakeEmailConnector([{
    messages: [providerMessage({
      bodyKind: "text",
      body: "x".repeat(262_145),
    })],
    nextCursor: "after-overflow",
    hasMore: false,
  }]);
  const result = await runIncrementalEmailIngestion(
    connector,
    { extraction: { extractor, timezone: "Asia/Tokyo" } },
    runtime(),
  );

  assert(extractor.calls === 0, "extractor not called");
  assert(result.items.length === 1, "failed item returned");
  assert(
    result.items[0]?.errorCategory === "oversized_content",
    "endpoint error",
  );
  assert(
    result.sources[0]?.error_category === "oversized_content",
    "safe oversized state",
  );
  assert(result.sources[0]?.evidence_metadata.length === 0, "no evidence");
});
