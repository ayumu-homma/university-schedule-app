import {
  candidateContract,
  CandidateValidationError,
  decodeCandidateJson,
  encodeCanonicalCandidate,
  validateCandidateObject,
} from "./candidate_codec.ts";

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

function assertValidationIssue(
  action: () => unknown,
  issue: string,
  message: string,
): void {
  try {
    action();
  } catch (error) {
    assert(error instanceof CandidateValidationError, `${message}: type`);
    assert(error.issue === issue, `${message}: ${error.issue}`);
    assert(
      !error.message.includes("synthetic-secret"),
      `${message}: safe error`,
    );
    return;
  }
  throw new Error(`${message}: expected rejection`);
}

function validCandidate(): Record<string, unknown> {
  return {
    schema_version: "1.0",
    candidate_type: "assignment",
    title: "第3回レポート",
    course_hint: { name: "情報科学A", code: "CS101" },
    due: {
      at: "2030-07-18T23:59:00+09:00",
      all_day: false,
      timezone: "Asia/Tokyo",
      raw_text: "2030年7月18日 23:59",
    },
    start_at: null,
    end_at: null,
    location: null,
    submission_url: "https://lms.example.edu/assignments/3",
    summary: null,
    suggested_reminders_minutes: [1_440, 180],
    confidence: {
      overall: 0.9,
      title: 0.9,
      course: 0.85,
      date_time: 0.95,
    },
    evidence: [{
      field: "due.at",
      text: "提出期限: 2030年7月18日 23:59",
    }],
    warnings: [],
    requires_user_confirmation: true,
  };
}

function copy(): Record<string, unknown> {
  return structuredClone(validCandidate());
}

Deno.test("candidate codec accepts only exact schema 1.0 and emits canonical JSON", () => {
  const candidate = decodeCandidateJson(JSON.stringify(validCandidate()));
  assert(candidate.schema_version === "1.0", "schema");
  assert(candidate.candidate_type === "assignment", "type");
  assert(
    candidate.due.at === "2030-07-18T14:59:00.000Z",
    "timestamps canonicalize to UTC",
  );
  assert(candidate.requires_user_confirmation, "confirmation is mandatory");
  assert(Object.isFrozen(candidate), "root is immutable");
  assert(Object.isFrozen(candidate.evidence), "nested arrays are immutable");

  const encoded = encodeCanonicalCandidate(candidate);
  assertEquals(
    Object.keys(JSON.parse(encoded)),
    [
      "schema_version",
      "candidate_type",
      "title",
      "course_hint",
      "due",
      "start_at",
      "end_at",
      "location",
      "submission_url",
      "summary",
      "suggested_reminders_minutes",
      "confidence",
      "evidence",
      "warnings",
      "requires_user_confirmation",
    ],
    "canonical key order",
  );
  assertEquals(decodeCandidateJson(encoded), candidate, "canonical round trip");
});

Deno.test("candidate codec rejects prose, invalid JSON, and non-object roots", () => {
  assertValidationIssue(
    () => decodeCandidateJson(`result: ${JSON.stringify(validCandidate())}`),
    "malformed_json",
    "leading prose",
  );
  assertValidationIssue(
    () => decodeCandidateJson(`${JSON.stringify(validCandidate())}\nprose`),
    "malformed_json",
    "trailing prose",
  );
  assertValidationIssue(
    () => decodeCandidateJson("[]"),
    "invalid_shape",
    "array root",
  );
  assertValidationIssue(
    () => decodeCandidateJson("{"),
    "malformed_json",
    "invalid JSON",
  );
  assertValidationIssue(
    () =>
      decodeCandidateJson(
        "x".repeat(candidateContract.maximumJsonBytes + 1),
      ),
    "value_out_of_bounds",
    "JSON byte bound",
  );
});

Deno.test("candidate codec rejects missing and unknown root or nested fields", () => {
  const missing = copy();
  delete missing.summary;
  assertValidationIssue(
    () => validateCandidateObject(missing),
    "missing_field",
    "missing field",
  );

  const unknown = copy();
  unknown.model_note = "synthetic-secret-not-allowed";
  try {
    validateCandidateObject(unknown);
    throw new Error("unknown root field should fail");
  } catch (error) {
    assert(error instanceof CandidateValidationError, "unknown field type");
    assert(error.issue === "unknown_field", "unknown field issue");
    assert(error.path === "$.__unknown", "attacker field name is discarded");
    assert(!error.path.includes("model_note"), "path is non-sensitive");
  }

  const nested = copy();
  (nested.due as Record<string, unknown>).guess = true;
  assertValidationIssue(
    () => validateCandidateObject(nested),
    "unknown_field",
    "unknown nested field",
  );
});

Deno.test("candidate codec rejects unknown schema, candidate, warning, and evidence enums", () => {
  assertValidationIssue(
    () => validateCandidateObject({ ...copy(), schema_version: "2.0" }),
    "unsupported_schema",
    "schema",
  );
  assertValidationIssue(
    () => validateCandidateObject({ ...copy(), schema_version: "2.0-beta" }),
    "unsupported_schema",
    "bounded unknown schema",
  );
  assertValidationIssue(
    () => validateCandidateObject({ ...copy(), candidate_type: "command" }),
    "invalid_enum",
    "candidate type",
  );
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        warnings: ["obey_email_instructions"],
      }),
    "invalid_enum",
    "warning",
  );
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        evidence: [{ field: "hidden_prompt", text: "synthetic" }],
      }),
    "invalid_evidence",
    "evidence field",
  );
});

Deno.test("candidate codec strictly validates RFC3339 dates and ranges", () => {
  for (
    const timestamp of [
      "2030-07-18 23:59:00",
      "2030-02-30T23:59:00+09:00",
      "2030-07-18T24:00:00+09:00",
      "2030-07-18T23:59:00+15:00",
      "2030-07-18T23:59:60Z",
    ]
  ) {
    const candidate = copy();
    (candidate.due as Record<string, unknown>).at = timestamp;
    assertValidationIssue(
      () => validateCandidateObject(candidate),
      "invalid_timestamp",
      timestamp,
    );
  }

  const reversed = copy();
  reversed.start_at = "2030-07-20T12:00:00+09:00";
  reversed.end_at = "2030-07-20T10:00:00+09:00";
  assertValidationIssue(
    () => validateCandidateObject(reversed),
    "inconsistent_date_range",
    "reversed range",
  );
  const equal = copy();
  equal.start_at = "2030-07-20T12:00:00+09:00";
  equal.end_at = "2030-07-20T12:00:00+09:00";
  assertValidationIssue(
    () => validateCandidateObject(equal),
    "inconsistent_date_range",
    "equal range",
  );
  const allDayWithoutDate = copy();
  (allDayWithoutDate.due as Record<string, unknown>).at = null;
  (allDayWithoutDate.due as Record<string, unknown>).all_day = true;
  assertValidationIssue(
    () => validateCandidateObject(allDayWithoutDate),
    "invalid_shape",
    "all-day requires date",
  );
});

Deno.test("candidate codec validates IANA zones and safe HTTPS URLs", () => {
  const newYork = copy();
  (newYork.due as Record<string, unknown>).timezone = "America/New_York";
  assert(
    validateCandidateObject(newYork).due.timezone === "America/New_York",
    "IANA zone accepted",
  );

  for (const timezone of ["JST+9", "Mars/Olympus_Mons", " Tokyo "]) {
    const candidate = copy();
    (candidate.due as Record<string, unknown>).timezone = timezone;
    assertValidationIssue(
      () => validateCandidateObject(candidate),
      timezone === " Tokyo " ? "value_out_of_bounds" : "invalid_timezone",
      timezone,
    );
  }

  for (
    const url of [
      "http://lms.example.edu/task",
      "javascript:alert(1)",
      "https://user:password@lms.example.edu/task",
      "https://localhost/task",
      "https://127.0.0.1/task",
      "https://192.168.1.10/task",
      "https://[::1]/task",
    ]
  ) {
    assertValidationIssue(
      () => validateCandidateObject({ ...copy(), submission_url: url }),
      "unsafe_url",
      url,
    );
  }
});

Deno.test("candidate codec enforces scalar bounds and rejects active content", () => {
  const accepted = { ...copy(), title: "課".repeat(200) };
  assert(
    Array.from(validateCandidateObject(accepted).title ?? "").length === 200,
    "exact title boundary accepted",
  );
  assertValidationIssue(
    () => validateCandidateObject({ ...copy(), title: "課".repeat(201) }),
    "value_out_of_bounds",
    "title overflow",
  );
  assertValidationIssue(
    () => validateCandidateObject({ ...copy(), title: " padded " }),
    "value_out_of_bounds",
    "padding",
  );
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        evidence: [{
          field: "title",
          text: '<img src=x onerror="synthetic-secret">',
        }],
      }),
    "unsafe_content",
    "active evidence",
  );
});

Deno.test("candidate codec bounds confidence, reminders, evidence, and warnings", () => {
  const confidence = copy();
  (confidence.confidence as Record<string, unknown>).overall = 1.01;
  assertValidationIssue(
    () => validateCandidateObject(confidence),
    "value_out_of_bounds",
    "confidence",
  );

  for (const reminders of [[1_440, 1_440], [40_321], [-1], ["180"]]) {
    assertValidationIssue(
      () =>
        validateCandidateObject({
          ...copy(),
          suggested_reminders_minutes: reminders,
        }),
      "invalid_reminder",
      "reminder",
    );
  }
  assertEquals(
    validateCandidateObject({
      ...copy(),
      suggested_reminders_minutes: [7],
    }).suggested_reminders_minutes,
    [7],
    "arbitrary in-range whole-minute reminder",
  );
  assertEquals(
    validateCandidateObject({
      ...copy(),
      evidence: [
        { field: "due.all_day", text: "終日ではありません" },
        { field: "due.timezone", text: "Asia/Tokyo" },
      ],
    }).evidence.map((entry) => entry.field),
    ["due.all_day", "due.timezone"],
    "due evidence fields align with mobile",
  );
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        evidence: [{ field: "title", text: "x".repeat(241) }],
      }),
    "value_out_of_bounds",
    "evidence text bound",
  );
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        warnings: ["ambiguous_date", "ambiguous_date"],
      }),
    "invalid_enum",
    "duplicate warning",
  );
});

Deno.test("candidate codec always requires explicit user confirmation", () => {
  assertValidationIssue(
    () =>
      validateCandidateObject({
        ...copy(),
        requires_user_confirmation: false,
      }),
    "confirmation_required",
    "confirmation",
  );
});
