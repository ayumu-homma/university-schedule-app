import { type EmailErrorCategory, SafeEmailError } from "./types.ts";

export const candidateContract = Object.freeze({
  schemaVersion: "1.0",
  maximumJsonBytes: 65_536,
  maximumTitleCharacters: 200,
  maximumCourseNameCharacters: 160,
  maximumCourseCodeCharacters: 64,
  maximumRawDateTextCharacters: 240,
  maximumLocationCharacters: 200,
  maximumSubmissionUrlCharacters: 2_048,
  maximumSummaryCharacters: 1_000,
  maximumEvidenceItems: 8,
  maximumEvidenceFieldCharacters: 64,
  maximumEvidenceTextCharacters: 240,
  maximumWarningItems: 16,
  maximumWarningCharacters: 64,
  maximumReminderItems: 8,
  minimumReminderMinutes: 0,
  maximumReminderMinutes: 40_320,
});

export const candidateTypes = Object.freeze(
  [
    "assignment",
    "exam",
    "event",
    "announcement",
    "unknown",
  ] as const,
);
export type EmailCandidateType = (typeof candidateTypes)[number];

export const allowedEvidenceFields = Object.freeze(
  [
    "candidate_type",
    "title",
    "course_hint.name",
    "course_hint.code",
    "due.at",
    "due.all_day",
    "due.timezone",
    "due.raw_text",
    "start_at",
    "end_at",
    "location",
    "submission_url",
    "summary",
  ] as const,
);
const allowedEvidenceFieldSet = new Set<string>(allowedEvidenceFields);

export const allowedCandidateWarnings = Object.freeze(
  [
    "ambiguous_date",
    "ambiguous_year",
    "ambiguous_time",
    "ambiguous_course",
    "missing_title",
    "missing_date_time",
    "relative_date",
    "low_confidence",
    "untrusted_instruction_ignored",
  ] as const,
);
const allowedCandidateWarningSet = new Set<string>(allowedCandidateWarnings);

const rootFields = new Set([
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
]);
const courseFields = new Set(["name", "code"]);
const dueFields = new Set(["at", "all_day", "timezone", "raw_text"]);
const confidenceFields = new Set([
  "overall",
  "title",
  "course",
  "date_time",
]);
const evidenceFields = new Set(["field", "text"]);

export type CandidateValidationIssue =
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
  | "invalid_reminder"
  | "invalid_evidence"
  | "confirmation_required"
  | "inconsistent_date_range";

const issueCategory: Readonly<
  Record<CandidateValidationIssue, EmailErrorCategory>
> = {
  malformed_json: "invalid_extraction",
  invalid_shape: "invalid_extraction",
  missing_field: "invalid_extraction",
  unknown_field: "invalid_extraction",
  invalid_type: "invalid_extraction",
  unsupported_schema: "unsupported_schema",
  invalid_enum: "invalid_extraction",
  value_out_of_bounds: "validation_failed",
  invalid_timestamp: "validation_failed",
  invalid_timezone: "validation_failed",
  unsafe_url: "unsafe_url",
  unsafe_content: "unsafe_content",
  invalid_reminder: "validation_failed",
  invalid_evidence: "validation_failed",
  confirmation_required: "validation_failed",
  inconsistent_date_range: "validation_failed",
};

export class CandidateValidationError extends SafeEmailError {
  readonly issue: CandidateValidationIssue;
  readonly path: string;

  constructor(issue: CandidateValidationIssue, path: string) {
    super(issueCategory[issue]);
    this.name = "CandidateValidationError";
    this.issue = issue;
    this.path = path;
  }
}

export interface CandidateCourseHintV1 {
  readonly name: string | null;
  readonly code: string | null;
}

export interface CandidateDueV1 {
  readonly at: string | null;
  readonly all_day: boolean;
  readonly timezone: string | null;
  readonly raw_text: string | null;
}

export interface CandidateConfidenceV1 {
  readonly overall: number;
  readonly title: number;
  readonly course: number;
  readonly date_time: number;
}

export interface CandidateEvidenceV1 {
  readonly field: string;
  readonly text: string;
}

/** Exact normalized JSON contract that may cross the trusted boundary. */
export interface EmailCandidatePayloadV1
  extends Readonly<Record<string, unknown>> {
  readonly schema_version: "1.0";
  readonly candidate_type: EmailCandidateType;
  readonly title: string | null;
  readonly course_hint: CandidateCourseHintV1;
  readonly due: CandidateDueV1;
  readonly start_at: string | null;
  readonly end_at: string | null;
  readonly location: string | null;
  readonly submission_url: string | null;
  readonly summary: string | null;
  readonly suggested_reminders_minutes: readonly number[];
  readonly confidence: CandidateConfidenceV1;
  readonly evidence: readonly CandidateEvidenceV1[];
  readonly warnings: readonly string[];
  readonly requires_user_confirmation: true;
}

const encoder = new TextEncoder();
const rfc3339 =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:Z|([+-])(\d{2}):(\d{2}))$/;
const unsafeText =
  /<\s*\/?\s*[a-z][^>]*>|\bon(?:load|error|click|mouseover)\s*=|javascript\s*:/i;

function fail(issue: CandidateValidationIssue, path: string): never {
  throw new CandidateValidationError(issue, path);
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
    if (!expected.has(field)) fail("unknown_field", `${path}.__unknown`);
  }
}

function hasControlCharacter(value: string): boolean {
  return Array.from(value).some((character) =>
    (character.codePointAt(0) ?? 0) < 0x20
  );
}

function requiredString(
  value: unknown,
  path: string,
  maximumCharacters: number,
  rejectUnsafeText = true,
): string {
  if (typeof value !== "string") fail("invalid_type", path);
  if (
    value.length === 0 || value.trim() !== value ||
    Array.from(value).length > maximumCharacters || hasControlCharacter(value)
  ) {
    fail("value_out_of_bounds", path);
  }
  if (rejectUnsafeText && unsafeText.test(value)) fail("unsafe_content", path);
  return value;
}

function nullableString(
  value: unknown,
  path: string,
  maximumCharacters: number,
  rejectUnsafeText = true,
): string | null {
  if (value === null) return null;
  return requiredString(value, path, maximumCharacters, rejectUnsafeText);
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

function strictTimestampMilliseconds(value: string): number | null {
  const match = rfc3339.exec(value);
  if (match === null) return null;
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
    return null;
  }
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

export function isStrictRfc3339Timestamp(value: string): boolean {
  return strictTimestampMilliseconds(value) !== null;
}

function canonicalTimestamp(value: unknown, path: string): string | null {
  if (value === null) return null;
  if (typeof value !== "string") fail("invalid_timestamp", path);
  const milliseconds = strictTimestampMilliseconds(value);
  if (milliseconds === null) fail("invalid_timestamp", path);
  return new Date(milliseconds).toISOString();
}

export function isValidIanaTimezone(value: string): boolean {
  if (
    value !== "UTC" && value !== "Etc/UTC" && value !== "Etc/GMT" &&
    !/^[A-Za-z0-9._+-]+(?:\/[A-Za-z0-9._+-]+)+$/.test(value)
  ) {
    return false;
  }
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(0);
    return true;
  } catch {
    return false;
  }
}

function validateHttpsUrl(value: string): void {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    fail("unsafe_url", "$.submission_url");
  }
  const host = parsed.hostname.toLowerCase();
  if (
    parsed.protocol !== "https:" || host.length === 0 ||
    parsed.username.length > 0 || parsed.password.length > 0 ||
    host === "localhost" || host.endsWith(".local") || host.includes(":") ||
    isLoopbackOrPrivateIpv4(host)
  ) {
    fail("unsafe_url", "$.submission_url");
  }
}

function isLoopbackOrPrivateIpv4(host: string): boolean {
  const parts = host.split(".");
  if (parts.length !== 4) return false;
  const octets = parts.map((part) =>
    /^\d{1,3}$/.test(part) ? Number(part) : Number.NaN
  );
  if (octets.some((octet) => !Number.isInteger(octet) || octet > 255)) {
    return false;
  }
  const [first, second] = octets;
  return first === 0 || first === 10 || first === 127 ||
    (first === 169 && second === 254) ||
    (first === 172 && second! >= 16 && second! <= 31) ||
    (first === 192 && second === 168);
}

function decodeReminders(value: unknown): readonly number[] {
  if (!Array.isArray(value)) {
    fail("invalid_type", "$.suggested_reminders_minutes");
  }
  if (value.length > candidateContract.maximumReminderItems) {
    fail("value_out_of_bounds", "$.suggested_reminders_minutes");
  }
  const result: number[] = [];
  for (const reminder of value) {
    if (
      typeof reminder !== "number" || !Number.isInteger(reminder) ||
      reminder < candidateContract.minimumReminderMinutes ||
      reminder > candidateContract.maximumReminderMinutes ||
      result.includes(reminder)
    ) {
      fail("invalid_reminder", "$.suggested_reminders_minutes");
    }
    result.push(reminder);
  }
  return result;
}

function decodeEvidence(value: unknown): readonly CandidateEvidenceV1[] {
  if (!Array.isArray(value)) fail("invalid_type", "$.evidence");
  if (value.length > candidateContract.maximumEvidenceItems) {
    fail("value_out_of_bounds", "$.evidence");
  }
  return value.map((item, index) => {
    const path = `$.evidence[${index}]`;
    const record = requiredRecord(item, path);
    expectExactFields(record, evidenceFields, path);
    const field = requiredString(
      record.field,
      `${path}.field`,
      candidateContract.maximumEvidenceFieldCharacters,
    );
    if (!allowedEvidenceFieldSet.has(field)) {
      fail("invalid_evidence", `${path}.field`);
    }
    return {
      field,
      text: requiredString(
        record.text,
        `${path}.text`,
        candidateContract.maximumEvidenceTextCharacters,
      ),
    };
  });
}

function decodeWarnings(value: unknown): readonly string[] {
  if (!Array.isArray(value)) fail("invalid_type", "$.warnings");
  if (value.length > candidateContract.maximumWarningItems) {
    fail("value_out_of_bounds", "$.warnings");
  }
  const result: string[] = [];
  for (let index = 0; index < value.length; index += 1) {
    const warning = requiredString(
      value[index],
      `$.warnings[${index}]`,
      candidateContract.maximumWarningCharacters,
    );
    if (!allowedCandidateWarningSet.has(warning) || result.includes(warning)) {
      fail("invalid_enum", `$.warnings[${index}]`);
    }
    result.push(warning);
  }
  return result;
}

function freezeCandidate(
  candidate: EmailCandidatePayloadV1,
): EmailCandidatePayloadV1 {
  Object.freeze(candidate.course_hint);
  Object.freeze(candidate.due);
  Object.freeze(candidate.confidence);
  for (const evidence of candidate.evidence) Object.freeze(evidence);
  Object.freeze(candidate.evidence);
  Object.freeze(candidate.warnings);
  Object.freeze(candidate.suggested_reminders_minutes);
  return Object.freeze(candidate);
}

export function validateCandidateObject(
  value: unknown,
): EmailCandidatePayloadV1 {
  if (!isRecord(value)) fail("invalid_shape", "$");
  let encoded: string;
  try {
    encoded = JSON.stringify(value);
  } catch {
    fail("invalid_type", "$");
  }
  if (encoder.encode(encoded).byteLength > candidateContract.maximumJsonBytes) {
    fail("value_out_of_bounds", "$json");
  }
  expectExactFields(value, rootFields, "$");

  const schemaVersion = requiredString(
    value.schema_version,
    "$.schema_version",
    16,
  );
  if (schemaVersion !== candidateContract.schemaVersion) {
    fail("unsupported_schema", "$.schema_version");
  }

  const candidateType = requiredString(
    value.candidate_type,
    "$.candidate_type",
    32,
  );
  if (!(candidateTypes as readonly string[]).includes(candidateType)) {
    fail("invalid_enum", "$.candidate_type");
  }

  const course = requiredRecord(value.course_hint, "$.course_hint");
  expectExactFields(course, courseFields, "$.course_hint");
  const due = requiredRecord(value.due, "$.due");
  expectExactFields(due, dueFields, "$.due");
  const confidence = requiredRecord(value.confidence, "$.confidence");
  expectExactFields(confidence, confidenceFields, "$.confidence");

  const dueTimezone = nullableString(due.timezone, "$.due.timezone", 64);
  if (dueTimezone !== null && !isValidIanaTimezone(dueTimezone)) {
    fail("invalid_timezone", "$.due.timezone");
  }
  const dueAt = canonicalTimestamp(due.at, "$.due.at");
  const dueAllDay = requiredBoolean(due.all_day, "$.due.all_day");
  if (dueAllDay && dueAt === null) fail("invalid_shape", "$.due.all_day");

  const startAt = canonicalTimestamp(value.start_at, "$.start_at");
  const endAt = canonicalTimestamp(value.end_at, "$.end_at");
  if (
    (startAt === null && endAt !== null) ||
    (startAt !== null && endAt !== null &&
      Date.parse(endAt) <= Date.parse(startAt))
  ) {
    fail("inconsistent_date_range", "$.end_at");
  }

  const submissionUrl = nullableString(
    value.submission_url,
    "$.submission_url",
    candidateContract.maximumSubmissionUrlCharacters,
    false,
  );
  if (submissionUrl !== null) validateHttpsUrl(submissionUrl);

  const requiresConfirmation = requiredBoolean(
    value.requires_user_confirmation,
    "$.requires_user_confirmation",
  );
  if (!requiresConfirmation) {
    fail("confirmation_required", "$.requires_user_confirmation");
  }

  return freezeCandidate({
    schema_version: "1.0",
    candidate_type: candidateType as EmailCandidateType,
    title: nullableString(
      value.title,
      "$.title",
      candidateContract.maximumTitleCharacters,
    ),
    course_hint: {
      name: nullableString(
        course.name,
        "$.course_hint.name",
        candidateContract.maximumCourseNameCharacters,
      ),
      code: nullableString(
        course.code,
        "$.course_hint.code",
        candidateContract.maximumCourseCodeCharacters,
      ),
    },
    due: {
      at: dueAt,
      all_day: dueAllDay,
      timezone: dueTimezone,
      raw_text: nullableString(
        due.raw_text,
        "$.due.raw_text",
        candidateContract.maximumRawDateTextCharacters,
      ),
    },
    start_at: startAt,
    end_at: endAt,
    location: nullableString(
      value.location,
      "$.location",
      candidateContract.maximumLocationCharacters,
    ),
    submission_url: submissionUrl,
    summary: nullableString(
      value.summary,
      "$.summary",
      candidateContract.maximumSummaryCharacters,
    ),
    suggested_reminders_minutes: decodeReminders(
      value.suggested_reminders_minutes,
    ),
    confidence: {
      overall: requiredConfidence(
        confidence.overall,
        "$.confidence.overall",
      ),
      title: requiredConfidence(confidence.title, "$.confidence.title"),
      course: requiredConfidence(confidence.course, "$.confidence.course"),
      date_time: requiredConfidence(
        confidence.date_time,
        "$.confidence.date_time",
      ),
    },
    evidence: decodeEvidence(value.evidence),
    warnings: decodeWarnings(value.warnings),
    requires_user_confirmation: true,
  });
}

export function decodeCandidateJson(source: string): EmailCandidatePayloadV1 {
  if (encoder.encode(source).byteLength > candidateContract.maximumJsonBytes) {
    fail("value_out_of_bounds", "$json");
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(source);
  } catch {
    fail("malformed_json", "$json");
  }
  return validateCandidateObject(decoded);
}

export function encodeCanonicalCandidate(
  candidate: unknown,
): string {
  return JSON.stringify(validateCandidateObject(candidate));
}
