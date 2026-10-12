import {
  createEvidenceExcerpts,
  safeSourceFromSanitized,
  sanitizeProviderMessage,
  sanitizerLimits,
} from "./sanitizer.ts";
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

function assertSafeError(
  action: () => unknown,
  category: string,
  message: string,
): void {
  try {
    action();
  } catch (error) {
    assert(error instanceof SafeEmailError, `${message}: safe error expected`);
    assert(error.category === category, `${message}: category mismatch`);
    return;
  }
  throw new Error(`${message}: expected an error`);
}

function fixture(
  overrides: Partial<ProviderEmailMessage> = {},
): ProviderEmailMessage {
  return {
    providerMessageId: "message-synthetic-001",
    providerThreadId: "thread-synthetic-001",
    receivedAt: "2030-04-05T06:07:08.000Z",
    subject: "  情報数学   レポート  ",
    sender: "  授業担当   <course@example.invalid>  ",
    body: "提出期限は4月10日です。",
    bodyKind: "text",
    ...overrides,
  };
}

Deno.test("sanitizer rejects active HTML and strips benign tracking/history/signatures", () => {
  assertSafeError(
    () =>
      sanitizeProviderMessage(fixture({
        bodyKind: "html",
        body:
          "<p>期限: 4月10日</p><script>fetch('https://attacker.invalid')</script>",
      })),
    "unsafe_content",
    "active element",
  );
  assertSafeError(
    () =>
      sanitizeProviderMessage(fixture({
        body: "&lt;script&gt;encoded-active-content&lt;/script&gt;安全な本文",
      })),
    "unsafe_content",
    "encoded active element",
  );
  const input = sanitizeProviderMessage(fixture({
    bodyKind: "html",
    body: `
      <h1>課題のお知らせ</h1>
      <p>期限: 4月10日 17:00</p>
      <img width="1" height="1" src="https://tracker.invalid/open.gif">
      <div class="gmail_quote">以前の本文 secret-history</div>
    `,
  }));

  assert(input.body.includes("課題のお知らせ"), "useful text remains");
  assert(input.body.includes("期限: 4月10日 17:00"), "deadline remains");
  for (
    const forbidden of [
      "fetch(",
      "attacker.invalid",
      "tracker.invalid",
      "secret-history",
      "iframe",
    ]
  ) {
    assert(!input.body.includes(forbidden), `removed ${forbidden}`);
  }

  const plain = sanitizeProviderMessage(fixture({
    body: "  課題   本文\r\n\r\n\r\n期限: 明日  \n-- \n署名の個人情報",
  }));
  assertEquals(plain.body, "課題 本文\n\n期限: 明日", "plain text cleanup");
});

Deno.test("sanitizer performs no URL, image, or other external fetch", () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (): Promise<Response> => {
    calls += 1;
    return Promise.reject(new Error("network access is forbidden"));
  };
  try {
    const input = sanitizeProviderMessage(fixture({
      bodyKind: "html",
      body:
        '<a href="https://example.invalid/task">課題ページ</a><img src="https://example.invalid/pixel">',
    }));
    assert(
      input.body === "課題ページ",
      "anchor text remains without URL fetch",
    );
    assert(calls === 0, "sanitization must not call fetch");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("sanitizer rejects byte, character, and malformed UTF-16 overflow", () => {
  assertSafeError(
    () => sanitizeProviderMessage(fixture({ body: "あ".repeat(90_000) })),
    "oversized_content",
    "raw byte limit",
  );
  assertSafeError(
    () =>
      sanitizeProviderMessage(fixture({
        body: "a".repeat(sanitizerLimits.sanitizedBodyCharacters + 1),
      })),
    "oversized_content",
    "sanitized character limit",
  );
  assertSafeError(
    () => sanitizeProviderMessage(fixture({ body: "bad\ud800encoding" })),
    "malformed_content",
    "malformed UTF-16",
  );
});

Deno.test("safe persisted source contains only bounded metadata and excerpts", async () => {
  const rawMarker = "RAW-BODY-MUST-NOT-PERSIST";
  const senderMarker = "private-sender@example.invalid";
  const message = fixture({
    subject: "人工知能 課題3",
    sender: senderMarker,
    body:
      `${rawMarker}\n提出期限: 4月10日\n提出先: https://lms.example.invalid/task`,
  });
  const sanitized = sanitizeProviderMessage(message);
  const source = await safeSourceFromSanitized(message, sanitized);
  const serialized = JSON.stringify(source);

  assertEquals(
    Object.keys(source).sort(),
    [
      "error_category",
      "evidence_metadata",
      "processing_state",
      "provider_message_id",
      "provider_thread_id",
      "received_at",
      "sanitized_content_hash",
    ],
    "persisted key allow-list",
  );
  assert(
    /^[0-9a-f]{64}$/.test(source.sanitized_content_hash),
    "content hash shape",
  );
  assert(!serialized.includes(senderMarker), "sender is not persisted");
  assert(!("body" in source), "body property is impossible on safe shape");
  assert(
    !("subject" in source),
    "subject property is impossible on safe shape",
  );
  assert(
    source.evidence_metadata.length <= sanitizerLimits.evidenceExcerptCount,
    "evidence count is bounded",
  );
  assert(
    source.evidence_metadata.every((excerpt) =>
      Array.from(excerpt.text).length <=
        sanitizerLimits.evidenceExcerptCharacters
    ),
    "each evidence excerpt is bounded",
  );

  const excerpts = createEvidenceExcerpts(sanitized);
  assert(excerpts[0]?.field === "subject", "subject evidence is explicit");
});
