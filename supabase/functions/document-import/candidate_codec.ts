import {
  type DocumentCandidateEvidenceV1,
  documentCandidateTypes,
  type DocumentCandidateWarning,
  documentCandidateWarnings,
  type DocumentScheduleCandidateV1,
  SafeDocumentError,
  type ScheduleCandidateBatchV1,
} from "./types.ts";

export const documentCandidateContract = Object.freeze({
  schemaVersion: "1.0" as const,
  timezone: "Asia/Tokyo" as const,
  maximumJsonBytes: 256 * 1024,
  maximumCandidates: 20,
  maximumTitleCharacters: 200,
  maximumCourseCharacters: 160,
  maximumCourseCodeCharacters: 64,
  maximumLocationCharacters: 200,
  maximumNotesCharacters: 1_000,
  maximumEvidenceItems: 8,
  maximumEvidenceExcerptCharacters: 500,
  maximumEvidenceSectionCharacters: 120,
});

export type DocumentCandidateValidationIssue =
  | "malformed_json"
  | "invalid_shape"
  | "missing_field"
  | "unknown_field"
  | "invalid_type"
  | "unsupported_schema"
  | "invalid_enum"
  | "value_out_of_bounds"
  | "invalid_timestamp"
  | "invalid_timezone"
  | "unsafe_url"
  | "unsafe_content"
  | "invalid_evidence"
  | "confirmation_required"
  | "duplicate_candidate"
  | "inconsistent_candidate";

export class DocumentCandidateValidationError extends SafeDocumentError {
  readonly issue: DocumentCandidateValidationIssue;
  readonly path: string;

  constructor(issue: DocumentCandidateValidationIssue, path: string) {
    super(
      issue === "unsafe_content" || issue === "unsafe_url"
        ? "unsafe_content"
        : "invalid_extraction",
    );
    this.name = "DocumentCandidateValidationError";
    this.issue = issue;
    this.path = path;
  }
}

const encoder = new TextEncoder();
const safeIdentifier = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const sha256Pattern = /^[a-f0-9]{64}$/;
const rfc3339 =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:Z|([+-])(\d{2}):(\d{2}))$/;
const unsafeText =
  /<\s*\/?\s*(?:script|iframe|object|embed|style|svg|html)[^>]*>|\bon(?:load|error|click|mouseover)\s*=|javascript\s*:/i;
const numericHost = /^(?:\d+|0x[0-9a-f]+)(?:\.(?:\d+|0x[0-9a-f]+))*$/i;

const batchFields = new Set([
  "schema_version",
  "source_id",
  "content_hash",
  "timezone",
  "candidates",
]);
const candidateFields = new Set([
  "candidate_id",
  "type",
  "title",
  "course_hint",
  "due_at",
  "all_day",
  "start_at",
  "end_at",
  "location",
  "submission_url",
  "notes",
  "confidence",
  "evidence",
  "warnings",
  "requires_user_confirmation",
]);
const courseFields = new Set(["name", "code"]);
const confidenceFields = new Set(["overall", "course", "date_time"]);
const evidenceFields = new Set(["page_number", "section", "excerpt"]);

function fail(issue: DocumentCandidateValidationIssue, path: string): never {
  throw new DocumentCandidateValidationError(issue, path);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredRecord(
  value: unknown,
  path: string,
): Record<string, unknown> {
  if (!isRecord(value)) fail("invalid_type", path);
  return value;
}

function expectExactFields(
  value: Record<string, unknown>,
  expected: ReadonlySet<string>,
  path: string,
): void {
  for (const field of expected) {
    if (!Object.hasOwn(value, field)) fail("missing_field", `${path}.${field}`);
  }
  for (const field of Object.keys(value)) {
    if (!expected.has(field)) fail("unknown_field", `${path}.<unknown>`);
  }
}

function hasDisallowedControl(value: string): boolean {
  return Array.from(value).some((character) => {
    const rune = character.codePointAt(0) ?? 0;
    return rune < 0x20 && rune !== 0x0a;
  });
}

function requiredString(
  value: unknown,
  path: string,
  maximumCharacters: number,
  rejectUnsafe = true,
): string {
  if (typeof value !== "string") fail("invalid_type", path);
  if (
    value.length === 0 || value.trim() !== value ||
    Array.from(value).length > maximumCharacters ||
    hasDisallowedControl(value)
  ) {
    fail("value_out_of_bounds", path);
  }
  if (rejectUnsafe && unsafeText.test(value)) fail("unsafe_content", path);
  return value;
}

function nullableString(
  value: unknown,
  path: string,
  maximumCharacters: number,
  rejectUnsafe = true,
): string | null {
  if (value === null) return null;
  return requiredString(value, path, maximumCharacters, rejectUnsafe);
}

function requiredBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") fail("invalid_type", path);
  return value;
}

function requiredConfidence(value: unknown, path: string): number {
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < 0 ||
    value > 1
  ) {
    fail("value_out_of_bounds", path);
  }
  return value;
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) {
    const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    return leap ? 29 : 28;
  }
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

function canonicalTimestamp(value: unknown, path: string): string | null {
  if (value === null) return null;
  if (typeof value !== "string") fail("invalid_timestamp", path);
  const match = rfc3339.exec(value);
  if (match === null) fail("invalid_timestamp", path);
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = Number(match[9] ?? 0);
  const offsetMinute = Number(match[10] ?? 0);
  if (
    month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month) ||
    hour > 23 || minute > 59 || second > 59 || offsetHour > 14 ||
    offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0)
  ) {
    fail("invalid_timestamp", path);
  }
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) fail("invalid_timestamp", path);
  return new Date(milliseconds).toISOString();
}

function validateHttpsUrl(value: string, path: string): void {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    fail("unsafe_url", path);
  }
  const host = parsed.hostname.toLowerCase();
  if (
    parsed.protocol !== "https:" || host.length === 0 ||
    parsed.username.length > 0 || parsed.password.length > 0 ||
    host === "localhost" || host.endsWith(".localhost") ||
    host.endsWith(".local") || host.includes(":") ||
    isPrivateIpv4(host) || numericHost.test(host)
  ) {
    fail("unsafe_url", path);
  }
}

function isPrivateIpv4(host: string): boolean {
  const parts = host.split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) =>
    /^\d{1,3}$/.test(part) ? Number(part) : Number.NaN
  );
  if (
    octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)
  ) {
    return false;
  }
  const [first, second] = octets;
  return first === 0 || first === 10 || first === 127 ||
    (first === 169 && second === 254) ||
    (first === 172 && second! >= 16 && second! <= 31) ||
    (first === 192 && second === 168);
}

function decodeEvidence(
  value: unknown,
  path: string,
): readonly DocumentCandidateEvidenceV1[] {
  if (!Array.isArray(value)) fail("invalid_type", path);
  if (
    value.length === 0 ||
    value.length > documentCandidateContract.maximumEvidenceItems
  ) {
    fail("invalid_evidence", path);
  }
  return Object.freeze(value.map((item, index) => {
    const itemPath = `${path}[${index}]`;
    const record = requiredRecord(item, itemPath);
    expectExactFields(record, evidenceFields, itemPath);
    const pageNumber = record.page_number;
    if (
      pageNumber !== null &&
      (typeof pageNumber !== "number" || !Number.isInteger(pageNumber) ||
        pageNumber < 1 || pageNumber > 500)
    ) {
      fail("invalid_evidence", `${itemPath}.page_number`);
    }
    return Object.freeze({
      page_number: pageNumber as number | null,
      section: nullableString(
        record.section,
        `${itemPath}.section`,
        documentCandidateContract.maximumEvidenceSectionCharacters,
      ),
      excerpt: requiredString(
        record.excerpt,
        `${itemPath}.excerpt`,
        documentCandidateContract.maximumEvidenceExcerptCharacters,
      ),
    });
  }));
}

function decodeWarnings(
  value: unknown,
  path: string,
): readonly DocumentCandidateWarning[] {
  if (!Array.isArray(value)) fail("invalid_type", path);
  if (value.length > documentCandidateWarnings.length) {
    fail("value_out_of_bounds", path);
  }
  const result: DocumentCandidateWarning[] = [];
  for (let index = 0; index < value.length; index += 1) {
    const warning = requiredString(value[index], `${path}[${index}]`, 32);
    if (
      !documentCandidateWarnings.includes(
        warning as DocumentCandidateWarning,
      ) ||
      result.includes(warning as DocumentCandidateWarning)
    ) {
      fail("invalid_enum", `${path}[${index}]`);
    }
    result.push(warning as DocumentCandidateWarning);
  }
  return Object.freeze(result);
}

function decodeCandidate(
  value: unknown,
  path: string,
): DocumentScheduleCandidateV1 {
  const record = requiredRecord(value, path);
  expectExactFields(record, candidateFields, path);
  const candidateId = requiredString(
    record.candidate_id,
    `${path}.candidate_id`,
    128,
  );
  if (!safeIdentifier.test(candidateId)) {
    fail("value_out_of_bounds", `${path}.candidate_id`);
  }
  const type = requiredString(record.type, `${path}.type`, 32);
  if (!documentCandidateTypes.includes(type as "assignment" | "exam")) {
    fail("invalid_enum", `${path}.type`);
  }
  const course = requiredRecord(record.course_hint, `${path}.course_hint`);
  expectExactFields(course, courseFields, `${path}.course_hint`);
  const dueAt = canonicalTimestamp(record.due_at, `${path}.due_at`);
  const allDay = requiredBoolean(record.all_day, `${path}.all_day`);
  const startAt = canonicalTimestamp(record.start_at, `${path}.start_at`);
  const endAt = canonicalTimestamp(record.end_at, `${path}.end_at`);
  const submissionUrl = nullableString(
    record.submission_url,
    `${path}.submission_url`,
    2_048,
    false,
  );
  if (submissionUrl !== null) {
    validateHttpsUrl(submissionUrl, `${path}.submission_url`);
  }
  const confidenceRecord = requiredRecord(
    record.confidence,
    `${path}.confidence`,
  );
  expectExactFields(confidenceRecord, confidenceFields, `${path}.confidence`);
  const evidence = decodeEvidence(record.evidence, `${path}.evidence`);
  const warnings = decodeWarnings(record.warnings, `${path}.warnings`);
  if (record.requires_user_confirmation !== true) {
    fail("confirmation_required", `${path}.requires_user_confirmation`);
  }
  const missingDate = warnings.includes("missing_date") ||
    warnings.includes("missing_year");
  if (allDay && dueAt === null) {
    fail("inconsistent_candidate", `${path}.all_day`);
  }
  if (
    endAt !== null &&
    (startAt === null || Date.parse(endAt) <= Date.parse(startAt))
  ) {
    fail("inconsistent_candidate", `${path}.end_at`);
  }
  if (type === "assignment") {
    if (
      startAt !== null || endAt !== null || (dueAt === null && !missingDate)
    ) {
      fail("inconsistent_candidate", path);
    }
  } else if (dueAt !== null || allDay || (startAt === null && !missingDate)) {
    fail("inconsistent_candidate", path);
  }

  return Object.freeze({
    candidate_id: candidateId,
    type: type as "assignment" | "exam",
    title: requiredString(
      record.title,
      `${path}.title`,
      documentCandidateContract.maximumTitleCharacters,
    ),
    course_hint: Object.freeze({
      name: nullableString(
        course.name,
        `${path}.course_hint.name`,
        documentCandidateContract.maximumCourseCharacters,
      ),
      code: nullableString(
        course.code,
        `${path}.course_hint.code`,
        documentCandidateContract.maximumCourseCodeCharacters,
      ),
    }),
    due_at: dueAt,
    all_day: allDay,
    start_at: startAt,
    end_at: endAt,
    location: nullableString(
      record.location,
      `${path}.location`,
      documentCandidateContract.maximumLocationCharacters,
    ),
    submission_url: submissionUrl,
    notes: nullableString(
      record.notes,
      `${path}.notes`,
      documentCandidateContract.maximumNotesCharacters,
    ),
    confidence: Object.freeze({
      overall: requiredConfidence(
        confidenceRecord.overall,
        `${path}.confidence.overall`,
      ),
      course: requiredConfidence(
        confidenceRecord.course,
        `${path}.confidence.course`,
      ),
      date_time: requiredConfidence(
        confidenceRecord.date_time,
        `${path}.confidence.date_time`,
      ),
    }),
    evidence,
    warnings,
    requires_user_confirmation: true,
  });
}

export function validateDocumentCandidateBatch(
  value: unknown,
): ScheduleCandidateBatchV1 {
  const record = requiredRecord(value, "$.");
  let encoded: string;
  try {
    encoded = JSON.stringify(record);
  } catch {
    fail("invalid_shape", "$json");
  }
  if (
    encoder.encode(encoded).byteLength >
      documentCandidateContract.maximumJsonBytes
  ) {
    fail("value_out_of_bounds", "$json");
  }
  expectExactFields(record, batchFields, "$");
  if (record.schema_version !== documentCandidateContract.schemaVersion) {
    fail("unsupported_schema", "$.schema_version");
  }
  const sourceId = requiredString(record.source_id, "$.source_id", 128);
  if (!safeIdentifier.test(sourceId)) {
    fail("value_out_of_bounds", "$.source_id");
  }
  const contentHash = requiredString(record.content_hash, "$.content_hash", 64);
  if (!sha256Pattern.test(contentHash)) {
    fail("value_out_of_bounds", "$.content_hash");
  }
  if (record.timezone !== documentCandidateContract.timezone) {
    fail("invalid_timezone", "$.timezone");
  }
  if (!Array.isArray(record.candidates)) fail("invalid_type", "$.candidates");
  if (record.candidates.length > documentCandidateContract.maximumCandidates) {
    fail("value_out_of_bounds", "$.candidates");
  }
  const ids = new Set<string>();
  const candidates = record.candidates.map((item, index) => {
    const candidate = decodeCandidate(item, `$.candidates[${index}]`);
    if (ids.has(candidate.candidate_id)) {
      fail("duplicate_candidate", `$.candidates[${index}].candidate_id`);
    }
    ids.add(candidate.candidate_id);
    return candidate;
  });
  return Object.freeze({
    schema_version: "1.0",
    source_id: sourceId,
    content_hash: contentHash,
    timezone: "Asia/Tokyo",
    candidates: Object.freeze(candidates),
  });
}

export function decodeDocumentCandidateBatchJson(
  source: string,
): ScheduleCandidateBatchV1 {
  if (
    typeof source !== "string" ||
    encoder.encode(source).byteLength >
      documentCandidateContract.maximumJsonBytes
  ) {
    fail("value_out_of_bounds", "$json");
  }
  let value: unknown;
  try {
    value = JSON.parse(source);
  } catch {
    fail("malformed_json", "$json");
  }
  return validateDocumentCandidateBatch(value);
}
