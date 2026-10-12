import {
  decodeDocumentCandidateBatchJson,
  DocumentCandidateValidationError,
  validateDocumentCandidateBatch,
} from "./candidate_codec.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assignment(overrides: Record<string, unknown> = {}) {
  return {
    candidate_id: "candidate:assignment:1",
    type: "assignment",
    title: "第8回レポート",
    course_hint: { name: "情報科学", code: "CS-201" },
    due_at: "2026-08-20T14:59:00Z",
    all_day: false,
    start_at: null,
    end_at: null,
    location: null,
    submission_url: "https://lms.example.edu/tasks/8",
    notes: null,
    confidence: { overall: 0.9, course: 0.8, date_time: 0.95 },
    evidence: [{ page_number: 3, section: "課題", excerpt: "8月20日締切" }],
    warnings: [],
    requires_user_confirmation: true,
    ...overrides,
  };
}

function batch(candidates: readonly unknown[] = [assignment()]) {
  return {
    schema_version: "1.0",
    source_id: "22222222-2222-4222-8222-222222222222",
    content_hash: "a".repeat(64),
    timezone: "Asia/Tokyo",
    candidates,
  };
}

function assertIssue(
  action: () => unknown,
  issue: string,
  message: string,
): void {
  try {
    action();
  } catch (error) {
    assert(
      error instanceof DocumentCandidateValidationError,
      `${message}: type`,
    );
    assert(error.issue === issue, `${message}: ${error.issue}`);
    return;
  }
  throw new Error(`${message}: expected failure`);
}

Deno.test("document codec accepts and canonicalizes exact schema 1.0", () => {
  const decoded = validateDocumentCandidateBatch(batch());
  assert(decoded.schema_version === "1.0", "schema");
  assert(decoded.timezone === "Asia/Tokyo", "timezone");
  assert(decoded.candidates.length === 1, "candidate count");
  assert(
    decoded.candidates[0].due_at === "2026-08-20T14:59:00.000Z",
    "canonical UTC timestamp",
  );
  assert(decoded.candidates[0].requires_user_confirmation, "confirmation");
});

Deno.test("document codec accepts an explicit zero-candidate result", () => {
  assert(
    validateDocumentCandidateBatch(batch([])).candidates.length === 0,
    "empty",
  );
});

Deno.test("document codec rejects prose around JSON", () => {
  assertIssue(
    () =>
      decodeDocumentCandidateBatchJson(`result: ${JSON.stringify(batch())}`),
    "malformed_json",
    "prose",
  );
});

Deno.test("document codec rejects missing and unknown fields", () => {
  const missing = { ...batch() } as Record<string, unknown>;
  delete missing.timezone;
  assertIssue(
    () => validateDocumentCandidateBatch(missing),
    "missing_field",
    "missing",
  );
  assertIssue(
    () =>
      validateDocumentCandidateBatch({ ...batch(), filename: "secret.pdf" }),
    "unknown_field",
    "unknown",
  );
});

Deno.test("document codec rejects unsupported schema and timezone", () => {
  assertIssue(
    () => validateDocumentCandidateBatch({ ...batch(), schema_version: "2.0" }),
    "unsupported_schema",
    "schema",
  );
  assertIssue(
    () => validateDocumentCandidateBatch({ ...batch(), timezone: "UTC" }),
    "invalid_timezone",
    "timezone",
  );
});

Deno.test("document codec rejects more than twenty candidates", () => {
  const candidates = Array.from(
    { length: 21 },
    (_, index) => assignment({ candidate_id: `candidate:${index}` }),
  );
  assertIssue(
    () => validateDocumentCandidateBatch(batch(candidates)),
    "value_out_of_bounds",
    "candidate limit",
  );
});

Deno.test("document codec rejects duplicate candidate IDs", () => {
  assertIssue(
    () => validateDocumentCandidateBatch(batch([assignment(), assignment()])),
    "duplicate_candidate",
    "duplicate id",
  );
});

Deno.test("document codec rejects unsupported Event candidates", () => {
  assertIssue(
    () =>
      validateDocumentCandidateBatch(batch([assignment({ type: "event" })])),
    "invalid_enum",
    "event",
  );
});

Deno.test("document codec requires explicit user confirmation", () => {
  assertIssue(
    () =>
      validateDocumentCandidateBatch(
        batch([assignment({ requires_user_confirmation: false })]),
      ),
    "confirmation_required",
    "confirmation",
  );
});

Deno.test("document codec rejects unsafe markup and script URLs", () => {
  assertIssue(
    () =>
      validateDocumentCandidateBatch(
        batch([assignment({ title: "<script>alert(1)</script>" })]),
      ),
    "unsafe_content",
    "markup",
  );
  assertIssue(
    () =>
      validateDocumentCandidateBatch(
        batch([assignment({ submission_url: "javascript:alert(1)" })]),
      ),
    "unsafe_url",
    "script url",
  );
});

Deno.test("document codec rejects private and credentialed URLs", () => {
  for (
    const value of [
      "https://127.0.0.1/task",
      "https://user:pass@example.edu/task",
      "https://portal.local/task",
    ]
  ) {
    assertIssue(
      () =>
        validateDocumentCandidateBatch(
          batch([assignment({ submission_url: value })]),
        ),
      "unsafe_url",
      value,
    );
  }
});

Deno.test("document codec enforces assignment and exam temporal consistency", () => {
  assertIssue(
    () =>
      validateDocumentCandidateBatch(
        batch([assignment({ due_at: null, warnings: [] })]),
      ),
    "inconsistent_candidate",
    "missing assignment date",
  );
  const exam = assignment({
    candidate_id: "candidate:exam:1",
    type: "exam",
    due_at: null,
    start_at: "2026-08-27T01:35:00Z",
    end_at: "2026-08-27T01:00:00Z",
  });
  assertIssue(
    () => validateDocumentCandidateBatch(batch([exam])),
    "inconsistent_candidate",
    "exam range",
  );
});

Deno.test("document codec permits ambiguous dates only with an allowed warning", () => {
  const decoded = validateDocumentCandidateBatch(batch([
    assignment({
      due_at: null,
      warnings: ["missing_year", "ambiguous_course"],
    }),
  ]));
  assert(decoded.candidates[0].due_at === null, "date remains unknown");
  assert(decoded.candidates[0].warnings.includes("missing_year"), "warning");
});

Deno.test("document codec requires bounded non-empty evidence", () => {
  assertIssue(
    () => validateDocumentCandidateBatch(batch([assignment({ evidence: [] })])),
    "invalid_evidence",
    "empty evidence",
  );
  assertIssue(
    () =>
      validateDocumentCandidateBatch(
        batch([assignment({
          evidence: [{ page_number: 0, section: null, excerpt: "bad" }],
        })]),
      ),
    "invalid_evidence",
    "page",
  );
});
