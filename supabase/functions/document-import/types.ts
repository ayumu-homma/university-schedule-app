export const documentMediaTypes = Object.freeze(
  ["application/pdf", "image/png", "image/jpeg", "text/plain"] as const,
);
export type DocumentMediaType = (typeof documentMediaTypes)[number];

export const documentCandidateTypes = Object.freeze(
  ["assignment", "exam"] as const,
);
export type DocumentCandidateType = (typeof documentCandidateTypes)[number];

export const documentCandidateWarnings = Object.freeze(
  [
    "missing_year",
    "missing_date",
    "missing_time",
    "ambiguous_course",
    "duplicate_mention",
    "relative_date",
    "low_confidence",
  ] as const,
);
export type DocumentCandidateWarning =
  (typeof documentCandidateWarnings)[number];

export const documentImportErrorCategories = Object.freeze(
  [
    "configuration_missing",
    "unsupported_type",
    "oversized_file",
    "oversized_document",
    "corrupt_document",
    "encrypted_document",
    "spoofed_media_type",
    "unsafe_content",
    "invalid_extraction",
    "rate_limited",
    "timeout",
    "network_unavailable",
    "provider_unavailable",
    "cancelled",
    "internal_error",
  ] as const,
);
export type DocumentImportErrorCategory =
  (typeof documentImportErrorCategories)[number];

export const retryableDocumentErrors = new Set<DocumentImportErrorCategory>([
  "rate_limited",
  "timeout",
  "network_unavailable",
  "provider_unavailable",
  "cancelled",
  "internal_error",
]);

export type DocumentEndpointErrorCode =
  | DocumentImportErrorCategory
  | "unauthorized"
  | "source_not_found"
  | "method_not_allowed";

export class SafeDocumentError extends Error {
  readonly category: DocumentEndpointErrorCode;
  readonly retryAfterMs: number | null;

  constructor(
    category: DocumentEndpointErrorCode,
    options: { readonly retryAfterMs?: number | null } = {},
  ) {
    const safeCategory = [
        ...documentImportErrorCategories,
        "unauthorized",
        "source_not_found",
        "method_not_allowed",
      ].includes(category)
      ? category
      : "internal_error";
    const retryAfterMs = options.retryAfterMs;
    const safeRetryAfter = typeof retryAfterMs === "number" &&
        Number.isFinite(retryAfterMs) && retryAfterMs >= 0
      ? Math.floor(retryAfterMs)
      : null;
    super(`Document import failed: ${safeCategory}.`);
    this.name = "SafeDocumentError";
    this.category = safeCategory;
    this.retryAfterMs = safeRetryAfter;
  }
}

export interface DocumentCourseHintV1 {
  readonly name: string | null;
  readonly code: string | null;
}

export interface DocumentCandidateConfidenceV1 {
  readonly overall: number;
  readonly course: number;
  readonly date_time: number;
}

export interface DocumentCandidateEvidenceV1 {
  readonly page_number: number | null;
  readonly section: string | null;
  readonly excerpt: string;
}

export interface DocumentScheduleCandidateV1 {
  readonly candidate_id: string;
  readonly type: DocumentCandidateType;
  readonly title: string;
  readonly course_hint: DocumentCourseHintV1;
  readonly due_at: string | null;
  readonly all_day: boolean;
  readonly start_at: string | null;
  readonly end_at: string | null;
  readonly location: string | null;
  readonly submission_url: string | null;
  readonly notes: string | null;
  readonly confidence: DocumentCandidateConfidenceV1;
  readonly evidence: readonly DocumentCandidateEvidenceV1[];
  readonly warnings: readonly DocumentCandidateWarning[];
  readonly requires_user_confirmation: true;
}

/** Exact schema 1.0 wire shape mirrored from packages/shared_domain. */
export interface ScheduleCandidateBatchV1 {
  readonly schema_version: "1.0";
  readonly source_id: string;
  readonly content_hash: string;
  readonly timezone: "Asia/Tokyo";
  readonly candidates: readonly DocumentScheduleCandidateV1[];
}

export interface PersistedDocumentSource {
  readonly id: string;
  readonly owner_user_id: string;
  readonly storage_path: string;
  readonly media_type: DocumentMediaType;
  readonly byte_size: number;
  readonly content_hash: string;
  readonly processing_state: string;
  readonly error_category: string | null;
  readonly processing_attempt_count: number;
  readonly retry_after_at: string | null;
  readonly retention_expires_at: string;
  readonly created_at: string;
  readonly updated_at: string;
  readonly deleted_at: string | null;
  readonly version: number;
}

export interface AuthenticatedDocumentCaller {
  readonly ownerUserId: string;
  /** Forwarded only to the caller-scoped Supabase Auth/REST/Storage boundary. */
  readonly authorization: string;
}

export interface DocumentProcessingClaim {
  readonly sourceId: string;
  readonly processingState: "processing" | "processed";
  readonly attemptCount: number;
  readonly version: number;
  readonly replayed: boolean;
}

export interface DocumentCandidateReplacement {
  readonly sourceId: string;
  readonly processingState: "processed";
  readonly candidateCount: number;
  readonly version: number;
  readonly replayed: boolean;
}

export interface StoredDocumentInput {
  readonly source: PersistedDocumentSource;
  readonly bytes: Uint8Array;
}

export interface SanitizedDocumentInput {
  readonly sourceId: string;
  readonly contentHash: string;
  readonly mediaType: DocumentMediaType;
  readonly bytes: Uint8Array;
  readonly byteLength: number;
  readonly pageCount: number;
  readonly sanitizedText: string;
  readonly uploadedAt: string;
  readonly timezone: "Asia/Tokyo";
}

export interface DocumentAuthenticator {
  authenticate(request: Request): Promise<AuthenticatedDocumentCaller>;
}

export interface DocumentSourceStore {
  loadOwnedSource(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
    expectedVersion: number,
  ): Promise<StoredDocumentInput>;
}

export interface DocumentProcessingStore {
  beginProcessing(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
  ): Promise<DocumentProcessingClaim>;

  loadProcessedBatch(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
  ): Promise<ScheduleCandidateBatchV1>;

  failProcessing(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
    expectedVersion: number,
    category: DocumentImportErrorCategory,
    retryAfterSeconds: number | null,
  ): Promise<void>;
}

export interface DocumentCandidateStore {
  replaceCandidates(
    caller: AuthenticatedDocumentCaller,
    batch: ScheduleCandidateBatchV1,
    expectedVersion: number,
  ): Promise<DocumentCandidateReplacement>;
}

export interface DocumentScheduleExtractor {
  /** Every adapter result is treated as untrusted and validated again. */
  extract(input: SanitizedDocumentInput): Promise<unknown>;
}
