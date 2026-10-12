import {
  type EmailErrorCategory,
  type EmailProviderConnector,
  type EndpointConnectionState,
  type EndpointFetchItem,
  type ProviderEmailMessage,
  type ProviderFetchPage,
  type ProviderFetchRequest,
  providerMessageFailureCategories,
  SafeEmailError,
  type SafePersistedEmailSource,
} from "./types.ts";
import {
  isStrictRfc3339Timestamp,
  validateCandidateObject,
} from "./candidate_codec.ts";
import type { EmailTaskExtractor } from "./extraction.ts";
import {
  safeFailedSource,
  safeSourceFromSanitized,
  sanitizeProviderMessage,
} from "./sanitizer.ts";

export const ingestionBounds = Object.freeze({
  defaultLookbackDays: 14,
  maximumLookbackDays: 30,
  defaultPageSize: 50,
  maximumPageSize: 100,
  defaultMaximumPages: 10,
  maximumPages: 20,
  defaultMaximumMessages: 500,
  maximumMessages: 1_000,
  maximumCursorCharacters: 4_096,
  maximumRetryAfterSeconds: 86_400,
});

export interface RetryPolicy {
  readonly maximumAttempts: number;
  readonly baseDelayMs: number;
  readonly maximumDelayMs: number;
}

export const defaultRetryPolicy: RetryPolicy = Object.freeze({
  maximumAttempts: 3,
  baseDelayMs: 250,
  maximumDelayMs: 10_000,
});

export interface EmailIngestionDependencies {
  readonly now: () => Date;
  readonly sleep: (delayMs: number) => Promise<void>;
  /** Returns deterministic additive jitter in [0, exponentialDelay]. */
  readonly jitter: (attempt: number, exponentialDelayMs: number) => number;
}

const defaultDependencies: EmailIngestionDependencies = {
  now: () => new Date(),
  sleep: (delayMs) => new Promise((resolve) => setTimeout(resolve, delayMs)),
  jitter: (_attempt, exponentialDelayMs) =>
    Math.floor(Math.random() * (exponentialDelayMs + 1)),
};

export interface EmailIngestionOptions {
  readonly cursor?: string | null;
  readonly firstSyncLookbackDays?: number;
  readonly pageSize?: number;
  readonly maximumPages?: number;
  readonly maximumMessages?: number;
  readonly retryPolicy?: RetryPolicy;
  readonly extraction?: EmailExtractionOptions;
}

export interface EmailExtractionOptions {
  readonly extractor: EmailTaskExtractor;
  readonly timezone: string;
}

export interface EmailMessageProcessingResult {
  readonly source: SafePersistedEmailSource;
  readonly item: EndpointFetchItem | null;
}

export interface SafeSyncEvent {
  readonly kind: "cursor_recovery" | "retry";
  readonly category: EmailErrorCategory;
  readonly attempt: number | null;
  readonly delayMs: number | null;
}

export interface EmailIngestionResult {
  readonly connection: EndpointConnectionState;
  readonly sources: readonly SafePersistedEmailSource[];
  readonly items: readonly EndpointFetchItem[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly recoveredFromCursorExpiry: boolean;
  readonly fetchedPages: number;
  readonly events: readonly SafeSyncEvent[];
}

function boundedInteger(
  value: number | undefined,
  defaultValue: number,
  minimum: number,
  maximum: number,
): number {
  if (value === undefined) return defaultValue;
  if (!Number.isFinite(value)) return defaultValue;
  return Math.min(maximum, Math.max(minimum, Math.floor(value)));
}

function validateCursor(cursor: string | null): void {
  if (
    cursor !== null &&
    (cursor.length === 0 ||
      Array.from(cursor).length > ingestionBounds.maximumCursorCharacters)
  ) {
    throw new SafeEmailError("validation_failed");
  }
}

function validateProviderIdentifier(value: string | null): void {
  if (value === null) return;
  const hasControlCharacter = Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f || codePoint === 0x7f;
  });
  if (
    value.length === 0 || Array.from(value).length > 1_024 ||
    hasControlCharacter
  ) {
    throw new SafeEmailError("malformed_content");
  }
}

function validateMessageEnvelope(message: ProviderEmailMessage): void {
  if (typeof message.providerMessageId !== "string") {
    throw new SafeEmailError("malformed_content");
  }
  validateProviderIdentifier(message.providerMessageId);
  if (
    typeof message.receivedAt !== "string" ||
    !isStrictRfc3339Timestamp(message.receivedAt)
  ) {
    throw new SafeEmailError("malformed_content");
  }
  if (message.bodyKind !== "html" && message.bodyKind !== "text") {
    throw new SafeEmailError("malformed_content");
  }
  if (
    message.failureCategory !== undefined &&
    !providerMessageFailureCategories.includes(message.failureCategory)
  ) {
    throw new SafeEmailError("malformed_content");
  }
}

function validatePage(
  page: ProviderFetchPage,
  request: ProviderFetchRequest,
): void {
  if (!Array.isArray(page.messages) || page.messages.length > request.limit) {
    throw new SafeEmailError("provider_unavailable");
  }
  for (const message of page.messages) validateMessageEnvelope(message);
  validateCursor(page.nextCursor);
  if (
    page.hasMore &&
    (page.nextCursor === null || page.nextCursor === request.cursor)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
}

function normalizeSafeError(error: unknown): SafeEmailError {
  return error instanceof SafeEmailError
    ? error
    : new SafeEmailError("provider_unavailable");
}

function retryable(category: EmailErrorCategory): boolean {
  return category === "rate_limited" || category === "timeout" ||
    category === "network_unavailable" || category === "provider_unavailable";
}

function safeJitter(
  dependencies: EmailIngestionDependencies,
  attempt: number,
  exponentialDelayMs: number,
): number {
  const raw = dependencies.jitter(attempt, exponentialDelayMs);
  if (!Number.isFinite(raw)) return 0;
  return Math.min(exponentialDelayMs, Math.max(0, Math.floor(raw)));
}

async function fetchWithRetry(
  connector: EmailProviderConnector,
  request: ProviderFetchRequest,
  policy: RetryPolicy,
  dependencies: EmailIngestionDependencies,
  events: SafeSyncEvent[],
): Promise<ProviderFetchPage> {
  for (let attempt = 1; attempt <= policy.maximumAttempts; attempt += 1) {
    try {
      const page = await connector.fetchPage(request);
      validatePage(page, request);
      return page;
    } catch (rawError) {
      const error = normalizeSafeError(rawError);
      if (!retryable(error.category) || attempt >= policy.maximumAttempts) {
        throw error;
      }
      const exponentialDelayMs = Math.min(
        policy.maximumDelayMs,
        policy.baseDelayMs * 2 ** (attempt - 1),
      );
      const boundedBackoffMs = Math.min(
        policy.maximumDelayMs,
        exponentialDelayMs +
          safeJitter(dependencies, attempt, exponentialDelayMs),
      );
      const delayMs = Math.max(
        boundedBackoffMs,
        error.retryAfterMs ?? 0,
      );

      // A provider hint beyond the bounded in-process delay becomes a
      // scheduled retry state. Retrying earlier would violate Retry-After.
      if (delayMs > policy.maximumDelayMs) throw error;
      events.push({
        kind: "retry",
        category: error.category,
        attempt,
        delayMs,
      });
      await dependencies.sleep(delayMs);
    }
  }
  throw new SafeEmailError("internal_error");
}

function failedConnection(
  connector: EmailProviderConnector,
  error: SafeEmailError,
): EndpointConnectionState {
  if (error.category === "authorization_revoked") {
    return {
      provider: connector.provider,
      status: "reauth_required",
      errorCategory: null,
      retryAfterSeconds: null,
      connectedAt: null,
    };
  }
  if (error.category === "rate_limited") {
    return {
      provider: connector.provider,
      status: "rate_limited",
      errorCategory: null,
      retryAfterSeconds: error.retryAfterMs === null ? null : Math.min(
        ingestionBounds.maximumRetryAfterSeconds,
        Math.max(0, Math.ceil(error.retryAfterMs / 1_000)),
      ),
      connectedAt: null,
    };
  }
  return {
    provider: connector.provider,
    status: "failed",
    errorCategory: error.category,
    retryAfterSeconds: null,
    connectedAt: null,
  };
}

function successfulConnection(
  connector: EmailProviderConnector,
): EndpointConnectionState {
  return {
    provider: connector.provider,
    status: "connected",
    errorCategory: null,
    retryAfterSeconds: null,
    // The orchestration core does not guess the original OAuth connection
    // timestamp. The trusted repository fills this from email_connections.
    connectedAt: null,
  };
}

function endpointItem(
  source: SafePersistedEmailSource,
  candidate: Readonly<Record<string, unknown>> | null,
  errorCategory: EmailErrorCategory | null,
): EndpointFetchItem {
  if ((candidate === null) === (errorCategory === null)) {
    throw new SafeEmailError("internal_error");
  }
  return Object.freeze({
    providerMessageId: source.provider_message_id,
    providerThreadId: source.provider_thread_id,
    receivedAt: source.received_at,
    sanitizedContentHash: source.sanitized_content_hash,
    evidenceExcerpts: Object.freeze(
      source.evidence_metadata.map((entry) => entry.text),
    ),
    candidate,
    errorCategory,
  });
}

/**
 * Processes one already-fetched provider message without reading or mutating a
 * page cursor. Production uses this same boundary for incremental pages and
 * targeted failed-candidate retries.
 */
export async function processProviderEmailMessage(
  message: ProviderEmailMessage,
  extraction: EmailExtractionOptions | undefined,
): Promise<EmailMessageProcessingResult> {
  validateMessageEnvelope(message);
  try {
    if (message.failureCategory !== undefined) {
      throw new SafeEmailError(message.failureCategory);
    }
    if (message.providerThreadId === null) {
      throw new SafeEmailError("malformed_content");
    }
    validateProviderIdentifier(message.providerThreadId);
    const sanitized = sanitizeProviderMessage(message);
    const safeSource = await safeSourceFromSanitized(message, sanitized);
    if (extraction === undefined) {
      return Object.freeze({ source: safeSource, item: null });
    }
    const extractedCandidate = validateCandidateObject(
      await extraction.extractor.extract({
        receivedAt: sanitized.receivedAt,
        timezone: extraction.timezone,
        sanitizedSubject: sanitized.subject,
        sanitizedContent: sanitized.body,
        sanitizedSenderLabel: sanitized.sender.length === 0
          ? null
          : sanitized.sender,
      }),
    );
    // The model output is untrusted even after schema validation. Bind the
    // persisted proposal to the owner timezone resolved by the trusted store,
    // including Exam/Event candidates whose due timestamp is null.
    const candidate = validateCandidateObject({
      ...extractedCandidate,
      due: {
        ...extractedCandidate.due,
        timezone: extraction.timezone,
      },
    });
    const processedSource = Object.freeze({
      ...safeSource,
      processing_state: "processed" as const,
    });
    return Object.freeze({
      source: processedSource,
      item: endpointItem(processedSource, candidate, null),
    });
  } catch (rawError) {
    const error = rawError instanceof SafeEmailError
      ? rawError
      : new SafeEmailError("internal_error");
    const source = await safeFailedSource(message, error);
    return Object.freeze({
      source,
      item: extraction === undefined
        ? null
        : endpointItem(source, null, error.category),
    });
  }
}

function failureResult(
  connector: EmailProviderConnector,
  error: SafeEmailError,
  sources: readonly SafePersistedEmailSource[],
  items: readonly EndpointFetchItem[],
  cursor: string | null,
  recovered: boolean,
  fetchedPages: number,
  events: readonly SafeSyncEvent[],
): EmailIngestionResult {
  return {
    connection: failedConnection(connector, error),
    sources,
    items,
    nextCursor: cursor,
    hasMore: false,
    recoveredFromCursorExpiry: recovered,
    fetchedPages,
    events,
  };
}

export async function runIncrementalEmailIngestion(
  connector: EmailProviderConnector,
  options: EmailIngestionOptions = {},
  dependencies: Partial<EmailIngestionDependencies> = {},
): Promise<EmailIngestionResult> {
  const runtime = { ...defaultDependencies, ...dependencies };
  const now = runtime.now();
  if (!Number.isFinite(now.getTime())) {
    throw new SafeEmailError("internal_error");
  }

  const lookbackDays = boundedInteger(
    options.firstSyncLookbackDays,
    ingestionBounds.defaultLookbackDays,
    1,
    ingestionBounds.maximumLookbackDays,
  );
  const pageSize = boundedInteger(
    options.pageSize,
    ingestionBounds.defaultPageSize,
    1,
    ingestionBounds.maximumPageSize,
  );
  const maximumPages = boundedInteger(
    options.maximumPages,
    ingestionBounds.defaultMaximumPages,
    1,
    ingestionBounds.maximumPages,
  );
  const maximumMessages = boundedInteger(
    options.maximumMessages,
    ingestionBounds.defaultMaximumMessages,
    1,
    ingestionBounds.maximumMessages,
  );
  const configuredPolicy = options.retryPolicy ?? defaultRetryPolicy;
  const retryPolicy: RetryPolicy = {
    maximumAttempts: boundedInteger(
      configuredPolicy.maximumAttempts,
      defaultRetryPolicy.maximumAttempts,
      1,
      5,
    ),
    baseDelayMs: boundedInteger(
      configuredPolicy.baseDelayMs,
      defaultRetryPolicy.baseDelayMs,
      1,
      5_000,
    ),
    maximumDelayMs: boundedInteger(
      configuredPolicy.maximumDelayMs,
      defaultRetryPolicy.maximumDelayMs,
      1,
      60_000,
    ),
  };

  let cursor = options.cursor ?? null;
  validateCursor(cursor);
  let lookbackBoundary = cursor === null
    ? new Date(now.getTime() - lookbackDays * 86_400_000).toISOString()
    : null;
  let receivedAfter = lookbackBoundary;
  let recovered = false;
  let fetchedPages = 0;
  let hasMore = false;
  const sources: SafePersistedEmailSource[] = [];
  const items: EndpointFetchItem[] = [];
  const seenMessageIds = new Set<string>();
  const events: SafeSyncEvent[] = [];

  while (fetchedPages < maximumPages && sources.length < maximumMessages) {
    const request: ProviderFetchRequest = {
      cursor,
      receivedAfter,
      limit: Math.min(pageSize, maximumMessages - sources.length),
    };
    let page: ProviderFetchPage;
    try {
      page = await fetchWithRetry(
        connector,
        request,
        retryPolicy,
        runtime,
        events,
      );
    } catch (rawError) {
      const error = normalizeSafeError(rawError);
      if (
        error.category === "cursor_expired" && cursor !== null && !recovered
      ) {
        recovered = true;
        cursor = null;
        lookbackBoundary = new Date(
          now.getTime() - lookbackDays * 86_400_000,
        ).toISOString();
        receivedAfter = lookbackBoundary;
        events.push({
          kind: "cursor_recovery",
          category: "cursor_expired",
          attempt: null,
          delayMs: null,
        });
        continue;
      }
      return failureResult(
        connector,
        error,
        sources,
        items,
        cursor,
        recovered,
        fetchedPages,
        events,
      );
    }

    fetchedPages += 1;
    for (const message of page.messages) {
      if (seenMessageIds.has(message.providerMessageId)) continue;
      seenMessageIds.add(message.providerMessageId);

      if (
        lookbackBoundary !== null &&
        Date.parse(message.receivedAt) < Date.parse(lookbackBoundary)
      ) {
        continue;
      }

      const processed = await processProviderEmailMessage(
        message,
        options.extraction,
      );
      sources.push(processed.source);
      if (processed.item !== null) items.push(processed.item);
      if (sources.length >= maximumMessages) break;
    }

    cursor = page.nextCursor;
    hasMore = page.hasMore;
    receivedAfter = null;
    if (!hasMore) break;
  }

  return {
    connection: successfulConnection(connector),
    sources,
    items,
    nextCursor: cursor,
    hasMore,
    recoveredFromCursorExpiry: recovered,
    fetchedPages,
    events,
  };
}
