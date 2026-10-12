export const emailProviders = Object.freeze(["gmail"] as const);
export type EmailProvider = (typeof emailProviders)[number];

/** Gmail scope approved for this read-only import boundary. */
export const gmailReadOnlyScope =
  "https://www.googleapis.com/auth/gmail.readonly" as const;

export const emailConnectionStatuses = Object.freeze(
  [
    "disconnected",
    "connecting",
    "connected",
    "reauth_required",
    "rate_limited",
    "failed",
    "disconnecting",
  ] as const,
);
export type EmailConnectionStatus = (typeof emailConnectionStatuses)[number];

export const emailErrorCategories = Object.freeze(
  [
    "authorization_revoked",
    "cursor_expired",
    "rate_limited",
    "timeout",
    "network_unavailable",
    "provider_unavailable",
    "configuration_missing",
    "malformed_content",
    "oversized_content",
    "unsafe_content",
    "invalid_extraction",
    "unsupported_schema",
    "unsafe_url",
    "validation_failed",
    "internal_error",
  ] as const,
);
export type EmailErrorCategory = (typeof emailErrorCategories)[number];

export const providerMessageFailureCategories = Object.freeze(
  ["malformed_content", "oversized_content", "unsafe_content"] as const,
);
export type ProviderMessageFailureCategory =
  (typeof providerMessageFailureCategories)[number];

export interface EndpointConnectionState {
  readonly provider: EmailProvider;
  readonly status: EmailConnectionStatus;
  /** General error details are populated only for the `failed` state. */
  readonly errorCategory: EmailErrorCategory | null;
  readonly retryAfterSeconds: number | null;
  readonly connectedAt: string | null;
}

/**
 * Stable mobile response contract. Candidate JSON is populated only after the
 * Phase 5C validator accepts the exact 1.0 schema; this interface does not make
 * unvalidated extractor output safe.
 */
export interface EndpointFetchItem {
  readonly providerMessageId: string;
  readonly providerThreadId: string | null;
  readonly receivedAt: string;
  readonly sanitizedContentHash: string;
  readonly evidenceExcerpts: readonly string[];
  /** Exactly one of candidate and errorCategory is populated. */
  readonly candidate: Readonly<Record<string, unknown>> | null;
  readonly errorCategory: EmailErrorCategory | null;
}

export type EndpointSuppressionReason = "dismissed" | "deduplicated";

/**
 * Minimal committed acknowledgement for an incoming provider message that
 * must remove a stale local failed review without presenting new content.
 */
export interface EndpointSuppressionAck {
  readonly providerMessageIdHash: string;
  readonly reason: EndpointSuppressionReason;
}

export interface EndpointFetchPage {
  readonly items: readonly EndpointFetchItem[];
  readonly suppressions: readonly EndpointSuppressionAck[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
}

export type EndpointRetryOutcome = "persisted" | "suppressed";

/** PKCE verifier and OAuth state are deliberately absent from this shape. */
export interface EndpointOAuthChallenge {
  readonly authorizationUri: string;
  readonly codeChallenge: string;
  readonly expiresAt: string;
}

/** Opaque result of an authenticated, correlation-bound OAuth callback check. */
export interface EndpointAuthorizationResolution {
  readonly effectiveConnectionId: string;
}

export type EmailReconciliationAction =
  | "confirmation"
  | "dismissal"
  | "update";
export type EmailReconciliationOutcome =
  | "confirmed"
  | "dismissed"
  | "accepted"
  | "rejected";

/** Safe acknowledgement only; provider identifiers and payloads never echo. */
export interface EndpointReconciliationResult {
  readonly connectionId: string;
  readonly idempotencyKey: string;
  readonly action: EmailReconciliationAction;
  readonly outcome: EmailReconciliationOutcome;
  readonly entityType: "assignment" | "exam" | "event" | null;
  readonly entityId: string | null;
  readonly replayed: boolean;
}

export type EmailImportEndpointResponse =
  | {
    readonly connection: EndpointConnectionState;
    readonly page: EndpointFetchPage;
    /** Present only for the targeted retry action. */
    readonly retryOutcome?: EndpointRetryOutcome;
    readonly oauth?: never;
  }
  | {
    readonly connection: EndpointConnectionState;
    readonly page: null;
    readonly oauth?: EndpointOAuthChallenge;
    readonly authorization?: never;
    readonly reconciliation?: never;
  }
  | {
    readonly connection: EndpointConnectionState;
    readonly page: null;
    readonly oauth?: never;
    readonly authorization: EndpointAuthorizationResolution;
    readonly reconciliation?: never;
  }
  | {
    readonly connection: EndpointConnectionState;
    readonly page: null;
    readonly oauth?: never;
    readonly authorization?: never;
    readonly reconciliation: EndpointReconciliationResult;
  };

/**
 * Provider input is untrusted and must never be persisted as-is. Provider
 * adapters map their SDK response into this deliberately small transport type.
 */
export interface ProviderEmailMessage {
  readonly providerMessageId: string;
  readonly providerThreadId: string | null;
  readonly receivedAt: string;
  readonly subject: string;
  readonly sender: string;
  readonly body: string;
  readonly bodyKind: "html" | "text";
  /**
   * A provider adapter may preserve a message's safe envelope while marking a
   * terminal content-decode failure. This lets the cursor advance without
   * persisting or returning any untrusted body bytes.
   */
  readonly failureCategory?: ProviderMessageFailureCategory;
}

export interface ProviderFetchRequest {
  /** Opaque value: the core forwards it without decoding or rewriting it. */
  readonly cursor: string | null;
  /** Present only for an initial or cursor-recovery bounded lookback. */
  readonly receivedAfter: string | null;
  readonly limit: number;
}

export interface ProviderFetchPage {
  readonly messages: readonly ProviderEmailMessage[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
}

export interface EmailProviderConnector {
  readonly provider: EmailProvider;
  fetchPage(request: ProviderFetchRequest): Promise<ProviderFetchPage>;
  /** Targeted retry never reads or advances the incremental page cursor. */
  fetchMessage?(providerMessageId: string): Promise<ProviderEmailMessage>;
}

/**
 * Provider diagnostics stay on the adapter side. Only this allow-listed error
 * reaches orchestration, persistence, or an endpoint response.
 */
export class SafeEmailError extends Error {
  readonly category: EmailErrorCategory;
  readonly retryAfterMs: number | null;

  constructor(
    category: EmailErrorCategory,
    options: { readonly retryAfterMs?: number | null } = {},
  ) {
    const safeCategory = (emailErrorCategories as readonly string[]).includes(
        category,
      )
      ? category
      : "internal_error";
    const retryAfterMs = options.retryAfterMs;
    const safeRetryAfterMs = typeof retryAfterMs === "number" &&
        Number.isFinite(retryAfterMs) && retryAfterMs >= 0
      ? Math.floor(retryAfterMs)
      : null;
    super(`Email import failed: ${safeCategory}.`);
    this.name = "SafeEmailError";
    this.category = safeCategory;
    this.retryAfterMs = safeRetryAfterMs;
  }
}

export interface SanitizedEmailInput {
  readonly subject: string;
  readonly sender: string;
  readonly body: string;
  readonly receivedAt: string;
}

export interface SafeEvidenceExcerpt {
  readonly field: "subject" | "body";
  readonly text: string;
}

/**
 * The only source shape returned for database persistence. It cannot carry a
 * raw/sanitized full body, sender, subject, provider diagnostic, or token.
 */
interface SafePersistedEmailSourceBase {
  readonly provider_message_id: string;
  readonly received_at: string;
  readonly sanitized_content_hash: string;
  readonly evidence_metadata: readonly SafeEvidenceExcerpt[];
}

export type SafeSuccessfulEmailSource = SafePersistedEmailSourceBase & {
  readonly provider_thread_id: string;
  readonly processing_state: "pending" | "processed";
  readonly error_category: null;
};

export type SafeFailedEmailSource = SafePersistedEmailSourceBase & {
  readonly provider_thread_id: string | null;
  readonly processing_state: "failed";
  readonly error_category: EmailErrorCategory;
};

export type SafePersistedEmailSource =
  | SafeSuccessfulEmailSource
  | SafeFailedEmailSource;
