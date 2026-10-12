import {
  type ProviderEmailMessage,
  SafeEmailError,
  type SafeEvidenceExcerpt,
  type SafeFailedEmailSource,
  type SafeSuccessfulEmailSource,
  type SanitizedEmailInput,
} from "./types.ts";

export const sanitizerLimits = Object.freeze({
  rawSubjectBytes: 4_096,
  rawSenderBytes: 2_048,
  rawBodyBytes: 262_144,
  sanitizedSubjectCharacters: 512,
  sanitizedSenderCharacters: 320,
  sanitizedBodyCharacters: 20_000,
  evidenceExcerptCharacters: 160,
  evidenceExcerptCount: 3,
});

const encoder = new TextEncoder();

function characterLength(value: string): number {
  return Array.from(value).length;
}

function boundedSlice(value: string, maximum: number): string {
  return Array.from(value).slice(0, maximum).join("");
}

function hasMalformedUtf16(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return true;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
}

function assertRawBound(value: string, maximumBytes: number): void {
  if (hasMalformedUtf16(value)) {
    throw new SafeEmailError("malformed_content");
  }
  if (encoder.encode(value).byteLength > maximumBytes) {
    throw new SafeEmailError("oversized_content");
  }
}

function decodeHtmlEntities(value: string): string {
  const named: Readonly<Record<string, string>> = {
    amp: "&",
    apos: "'",
    gt: ">",
    hellip: "…",
    lt: "<",
    nbsp: " ",
    quot: '"',
  };
  return value.replace(
    /&(#(?:x[0-9a-f]{1,6}|[0-9]{1,7})|[a-z]{2,10});/gi,
    (match, rawEntity: string) => {
      if (!rawEntity.startsWith("#")) {
        return named[rawEntity.toLowerCase()] ?? match;
      }
      const hexadecimal = rawEntity[1]?.toLowerCase() === "x";
      const digits = rawEntity.slice(hexadecimal ? 2 : 1);
      const codePoint = Number.parseInt(digits, hexadecimal ? 16 : 10);
      if (
        !Number.isInteger(codePoint) || codePoint < 0 || codePoint > 0x10ffff ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff)
      ) {
        return "�";
      }
      return String.fromCodePoint(codePoint);
    },
  );
}

const activeMarkup =
  /<(?:script|iframe|object|embed|svg|form|template)\b|\bon[a-z]{2,32}\s*=|(?:javascript|vbscript)\s*:|data\s*:\s*text\/html|\bexpression\s*\(|<style\b[^>]*>[\s\S]*?\burl\s*\(/i;

function rejectActiveMarkup(value: string): string {
  const decoded = decodeHtmlEntities(value);
  if (activeMarkup.test(decoded)) {
    throw new SafeEmailError("unsafe_content");
  }
  return decoded;
}

function stripHtml(value: string): string {
  return value
    // Quoted history containers are intentionally dropped before generic tags.
    .replace(
      /<(?:div|section)\b[^>]{0,2048}(?:class|id)\s*=\s*["'][^"']*(?:gmail_quote|yahoo_quoted)[^"']*["'][^>]*>[\s\S]*$/gi,
      " ",
    )
    .replace(/<blockquote\b[^>]*>[\s\S]*$/gi, " ")
    // Active elements, embedded documents, forms, styles, and tracking pixels.
    .replace(
      /<(script|style|iframe|object|embed|svg|canvas|form|template)\b[^>]*>[\s\S]*?<\/\1\s*>/gi,
      " ",
    )
    .replace(
      /<(?:script|style|iframe|object|embed|svg|canvas|form|template)\b[\s\S]*$/gi,
      " ",
    )
    .replace(/<!--[^]*?-->/g, " ")
    .replace(
      /<(?:img|picture|source|track|link|meta|base|input)\b[^>]*\/?\s*>/gi,
      " ",
    )
    .replace(/<(?:br|hr)\b[^>]*\/?\s*>/gi, "\n")
    .replace(/<\/(?:p|div|section|article|li|tr|h[1-6])\s*>/gi, "\n")
    .replace(/<[^>]*>/g, " ");
}

function earliestMarker(value: string, patterns: readonly RegExp[]): number {
  let result = -1;
  for (const pattern of patterns) {
    const match = pattern.exec(value);
    if (match && (result === -1 || match.index < result)) result = match.index;
  }
  return result;
}

function stripQuotedHistory(value: string): string {
  const marker = earliestMarker(value, [
    /^\s*-{2,}\s*(?:original message|forwarded message)\s*-{2,}\s*$/im,
    /^\s*(?:from|差出人|送信者)\s*:\s*.+$/im,
    /^\s*on\s.{1,500}\swrote\s*:\s*$/im,
    /^\s*.+(?:さん|様)は書きました\s*:\s*$/im,
  ]);
  return marker < 0 ? value : value.slice(0, marker);
}

function stripSignature(value: string): string {
  const marker = earliestMarker(value, [
    /^\s*--\s*$/m,
    /^\s*sent from my\b.*$/im,
    /^\s*(?:iphone|ipad|android)から送信\s*$/im,
  ]);
  return marker < 0 ? value : value.slice(0, marker);
}

function normalizeWhitespace(value: string): string {
  let withoutUnsafeControls = "";
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    withoutUnsafeControls +=
      codePoint <= 0x08 || (codePoint >= 0x0b && codePoint <= 0x0c) ||
        (codePoint >= 0x0e && codePoint <= 0x1f) || codePoint === 0x7f
        ? " "
        : character;
  }
  return withoutUnsafeControls
    .normalize("NFKC")
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/[\t\u0020\u00a0]+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function sanitizePart(value: string): string {
  // Provider content-type declarations are not trusted. Strip markup from all
  // fields so HTML hidden in a nominally plain-text or entity-encoded message
  // is inert as well. Decode before stripping to prevent encoded markup from
  // being reintroduced after the HTML pass.
  const withoutMarkup = stripHtml(rejectActiveMarkup(value));
  return normalizeWhitespace(
    stripSignature(stripQuotedHistory(withoutMarkup)),
  );
}

function assertSanitizedBound(value: string, maximumCharacters: number): void {
  if (characterLength(value) > maximumCharacters) {
    throw new SafeEmailError("oversized_content");
  }
}

function isSafeProviderThreadId(value: string | null): value is string {
  return value !== null && value.length > 0 &&
    Array.from(value).length <= 1_024 &&
    Array.from(value).every((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      return codePoint > 0x1f && codePoint !== 0x7f;
    });
}

export function sanitizeProviderMessage(
  message: ProviderEmailMessage,
): SanitizedEmailInput {
  assertRawBound(message.subject, sanitizerLimits.rawSubjectBytes);
  assertRawBound(message.sender, sanitizerLimits.rawSenderBytes);
  assertRawBound(message.body, sanitizerLimits.rawBodyBytes);

  const subject = sanitizePart(message.subject);
  const sender = sanitizePart(message.sender);
  const body = sanitizePart(message.body);

  assertSanitizedBound(subject, sanitizerLimits.sanitizedSubjectCharacters);
  assertSanitizedBound(sender, sanitizerLimits.sanitizedSenderCharacters);
  assertSanitizedBound(body, sanitizerLimits.sanitizedBodyCharacters);

  return { subject, sender, body, receivedAt: message.receivedAt };
}

export function createEvidenceExcerpts(
  input: SanitizedEmailInput,
): readonly SafeEvidenceExcerpt[] {
  const excerpts: SafeEvidenceExcerpt[] = [];
  if (input.subject.length > 0) {
    excerpts.push({
      field: "subject",
      text: boundedSlice(
        input.subject,
        sanitizerLimits.evidenceExcerptCharacters,
      ),
    });
  }
  for (const paragraph of input.body.split(/\n+/)) {
    if (excerpts.length >= sanitizerLimits.evidenceExcerptCount) break;
    const text = paragraph.trim();
    if (text.length === 0) continue;
    excerpts.push({
      field: "body",
      text: boundedSlice(text, sanitizerLimits.evidenceExcerptCharacters),
    });
  }
  return excerpts;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function safeSourceFromSanitized(
  message: ProviderEmailMessage,
  input: SanitizedEmailInput,
): Promise<SafeSuccessfulEmailSource> {
  const providerThreadId = message.providerThreadId;
  if (!isSafeProviderThreadId(providerThreadId)) {
    throw new SafeEmailError("malformed_content");
  }
  const sanitizedContentHash = await sha256Hex(
    `email-source:v1\u0000${input.subject}\u0000${input.sender}\u0000${input.body}`,
  );
  return {
    provider_message_id: message.providerMessageId,
    provider_thread_id: providerThreadId,
    received_at: input.receivedAt,
    sanitized_content_hash: sanitizedContentHash,
    evidence_metadata: createEvidenceExcerpts(input),
    processing_state: "pending",
    error_category: null,
  };
}

export async function safeFailedSource(
  message: ProviderEmailMessage,
  error: SafeEmailError,
): Promise<SafeFailedEmailSource> {
  const failureHash = await sha256Hex(
    `email-source-failure:v1\u0000${message.providerMessageId}\u0000${error.category}`,
  );
  const threadId = message.providerThreadId;
  // A failed Gmail envelope can lack a usable thread id. Return a stable,
  // irreversible surrogate so dismissal identity remains complete without
  // exposing or inventing raw provider metadata. A later successful retry
  // replaces this surrogate with the real provider thread id.
  const safeThreadId = isSafeProviderThreadId(threadId)
    ? threadId
    : `failed:${await sha256Hex(
      `email-source-failed-thread:v1\u0000${message.providerMessageId}`,
    )}`;
  return {
    provider_message_id: message.providerMessageId,
    provider_thread_id: safeThreadId,
    received_at: message.receivedAt,
    sanitized_content_hash: failureHash,
    evidence_metadata: [],
    processing_state: "failed",
    error_category: error.category,
  };
}
