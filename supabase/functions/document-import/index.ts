import {
  GuardedDocumentScheduleExtractor,
  ModelDocumentScheduleExtractor,
} from "./extraction.ts";
import { validateDocumentCandidateBatch } from "./candidate_codec.ts";
import { validateStoredDocument } from "./document_validation.ts";
import {
  defaultDocumentProductionRuntime,
  type DocumentProductionConfiguration,
  type DocumentProductionRuntime,
  OpenAIDocumentJsonModelClient,
  parseDocumentProductionConfiguration,
  SupabaseDocumentAuthenticator,
  SupabasePrivateDocumentRepository,
} from "./production.ts";
import {
  type DocumentAuthenticator,
  type DocumentCandidateReplacement,
  type DocumentCandidateStore,
  type DocumentEndpointErrorCode,
  documentImportErrorCategories,
  type DocumentImportErrorCategory,
  type DocumentProcessingStore,
  type DocumentScheduleExtractor,
  type DocumentSourceStore,
  retryableDocumentErrors,
  SafeDocumentError,
  type ScheduleCandidateBatchV1,
} from "./types.ts";

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const maximumRequestBytes = 4_096;
const requestFields = new Set(["source_id"]);
const requiredProductionConfiguration = [
  "APP_ENV",
  "APP_SUPABASE_PROJECT_REF",
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "OPENAI_API_KEY",
  "DOCUMENT_IMPORT_MODEL_ID",
  "DOCUMENT_IMPORT_PROVIDER",
] as const;

export interface DocumentImportReadiness {
  readonly enabled: boolean;
  readonly configured: boolean;
}

export interface DocumentImportEndpointDependencies {
  readonly configuration: DocumentProductionConfiguration;
  readonly runtime: DocumentProductionRuntime;
  readonly authenticator: DocumentAuthenticator;
  readonly processingStore: DocumentProcessingStore;
  readonly sourceStore: DocumentSourceStore;
  readonly candidateStore: DocumentCandidateStore;
  readonly extractor: DocumentScheduleExtractor;
}

export type DocumentImportDependencyFactory = (
  configuration: DocumentProductionConfiguration,
) => DocumentImportEndpointDependencies;

export function documentImportReadiness(
  readEnvironment: (name: string) => string | undefined,
): DocumentImportReadiness {
  const enabled = readEnvironment("DOCUMENT_IMPORT_ENABLED") === "true";
  return Object.freeze({
    enabled,
    configured: enabled &&
      readEnvironment("DOCUMENT_IMPORT_MODEL_ENABLED") === "true" &&
      readEnvironment("DOCUMENT_IMPORT_FAKE_ENABLED") === "false" &&
      requiredProductionConfiguration.every((name) => {
        const value = readEnvironment(name);
        return typeof value === "string" && value.length > 0 &&
          value === value.trim();
      }),
  });
}

export function createDocumentProductionDependencies(
  configuration: DocumentProductionConfiguration,
  runtime: DocumentProductionRuntime = defaultDocumentProductionRuntime,
): DocumentImportEndpointDependencies {
  const repository = new SupabasePrivateDocumentRepository(
    configuration,
    runtime,
  );
  const model = new OpenAIDocumentJsonModelClient(configuration, runtime);
  return Object.freeze({
    configuration,
    runtime,
    authenticator: new SupabaseDocumentAuthenticator(configuration, runtime),
    processingStore: repository,
    sourceStore: repository,
    candidateStore: repository,
    extractor: new GuardedDocumentScheduleExtractor(
      new ModelDocumentScheduleExtractor({ enabled: true, client: model }),
    ),
  });
}

function responseHeaders(): HeadersInit {
  return {
    "cache-control": "no-store",
    "content-type": "application/json; charset=utf-8",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
  };
}

function batchResponse(batch: ScheduleCandidateBatchV1): Response {
  return Response.json(batch, { status: 200, headers: responseHeaders() });
}

function statusForError(category: DocumentEndpointErrorCode): number {
  switch (category) {
    case "unauthorized":
      return 401;
    case "source_not_found":
      return 404;
    case "method_not_allowed":
      return 405;
    case "rate_limited":
      return 429;
    case "timeout":
      return 504;
    case "configuration_missing":
    case "network_unavailable":
    case "provider_unavailable":
    case "internal_error":
      return 503;
    case "unsupported_type":
    case "oversized_file":
    case "oversized_document":
    case "corrupt_document":
    case "encrypted_document":
    case "spoofed_media_type":
    case "unsafe_content":
    case "invalid_extraction":
    case "cancelled":
      return 422;
  }
}

function errorResponse(
  error: SafeDocumentError,
  overrideStatus?: number,
): Response {
  const retryable = retryableDocumentErrors.has(
    error.category as Parameters<typeof retryableDocumentErrors.has>[0],
  );
  const retryAfterSeconds = error.retryAfterMs === null
    ? null
    : Math.min(86_400, Math.ceil(error.retryAfterMs / 1_000));
  return Response.json(
    {
      error: {
        category: error.category,
        retryable,
        retry_after_seconds: retryAfterSeconds,
      },
    },
    {
      status: overrideStatus ?? statusForError(error.category),
      headers: responseHeaders(),
    },
  );
}

async function requestBody(
  request: Request,
): Promise<{ readonly source_id: string }> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]
    .trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new SafeDocumentError("invalid_extraction");
  }
  const declaredLength = request.headers.get("content-length");
  if (
    declaredLength !== null &&
    (!/^\d+$/.test(declaredLength) ||
      Number(declaredLength) > maximumRequestBytes)
  ) {
    throw new SafeDocumentError("oversized_document");
  }
  if (request.body === null) {
    throw new SafeDocumentError("invalid_extraction");
  }
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumRequestBytes) {
        await reader.cancel();
        throw new SafeDocumentError("oversized_document");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new SafeDocumentError("invalid_extraction");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new SafeDocumentError("invalid_extraction");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new SafeDocumentError("invalid_extraction");
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record);
  if (
    keys.length !== requestFields.size ||
    keys.some((key) => !requestFields.has(key)) ||
    typeof record.source_id !== "string" || !uuidPattern.test(record.source_id)
  ) {
    throw new SafeDocumentError("source_not_found");
  }
  return Object.freeze({ source_id: record.source_id });
}

async function withTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
): Promise<T> {
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const expired = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(
      () => reject(new SafeDocumentError("timeout")),
      timeoutMs,
    );
  });
  try {
    return await Promise.race([operation, expired]);
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
  }
}

function safeError(value: unknown): SafeDocumentError {
  return value instanceof SafeDocumentError
    ? value
    : new SafeDocumentError("internal_error");
}

function persistedFailureCategory(
  error: SafeDocumentError,
): DocumentImportErrorCategory {
  if (error.category === "source_not_found") {
    return "corrupt_document";
  }
  return documentImportErrorCategories.includes(
      error.category as DocumentImportErrorCategory,
    )
    ? error.category as DocumentImportErrorCategory
    : "internal_error";
}

function persistedRetryAfterSeconds(
  error: SafeDocumentError,
  category: DocumentImportErrorCategory,
): number | null {
  if (!retryableDocumentErrors.has(category) || error.retryAfterMs === null) {
    return null;
  }
  return Math.min(86_400, Math.ceil(error.retryAfterMs / 1_000));
}

async function recordProcessingFailure(
  store: DocumentProcessingStore,
  caller: Awaited<ReturnType<DocumentAuthenticator["authenticate"]>>,
  sourceId: string,
  expectedVersion: number,
  error: SafeDocumentError,
): Promise<void> {
  const category = persistedFailureCategory(error);
  try {
    await store.failProcessing(
      caller,
      sourceId,
      expectedVersion,
      category,
      persistedRetryAfterSeconds(error, category),
    );
  } catch {
    // Preserve the original redacted failure. A stale claim is reclaimable by
    // begin_document_processing; never surface RPC/provider diagnostics here.
  }
}

function assertReplacementContract(
  replacement: DocumentCandidateReplacement,
  batch: ScheduleCandidateBatchV1,
): void {
  if (
    replacement.sourceId !== batch.source_id ||
    replacement.processingState !== "processed" ||
    !Number.isInteger(replacement.candidateCount) ||
    replacement.candidateCount !== batch.candidates.length ||
    !Number.isInteger(replacement.version) || replacement.version < 1 ||
    typeof replacement.replayed !== "boolean"
  ) {
    throw new SafeDocumentError("invalid_extraction");
  }
}

async function loadStrictProcessedBatch(
  store: DocumentProcessingStore,
  caller: Awaited<ReturnType<DocumentAuthenticator["authenticate"]>>,
  sourceId: string,
): Promise<ScheduleCandidateBatchV1> {
  const batch = validateDocumentCandidateBatch(
    await store.loadProcessedBatch(caller, sourceId),
  );
  if (batch.source_id !== sourceId || batch.timezone !== "Asia/Tokyo") {
    throw new SafeDocumentError("invalid_extraction");
  }
  return batch;
}

export async function handleDocumentImportRequest(
  request: Request,
  readEnvironment: (name: string) => string | undefined = (name) =>
    Deno.env.get(name),
  dependencyFactory: DocumentImportDependencyFactory =
    createDocumentProductionDependencies,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "access-control-allow-headers":
          "authorization, apikey, content-type, x-client-info",
        "access-control-allow-methods": "POST, OPTIONS",
        "access-control-max-age": "600",
      },
    });
  }
  if (request.method !== "POST") {
    return errorResponse(new SafeDocumentError("method_not_allowed"));
  }

  const readiness = documentImportReadiness(readEnvironment);
  if (!readiness.enabled) {
    return errorResponse(new SafeDocumentError("configuration_missing"), 404);
  }
  if (!readiness.configured) {
    return errorResponse(new SafeDocumentError("configuration_missing"));
  }

  let dependencies: DocumentImportEndpointDependencies;
  try {
    dependencies = dependencyFactory(
      parseDocumentProductionConfiguration(readEnvironment),
    );
  } catch {
    return errorResponse(new SafeDocumentError("configuration_missing"));
  }

  try {
    const caller = await dependencies.authenticator.authenticate(request);
    const body = await requestBody(request);
    const claim = await dependencies.processingStore.beginProcessing(
      caller,
      body.source_id,
    );
    if (
      claim.sourceId !== body.source_id || !Number.isInteger(claim.version) ||
      claim.version < 1 || !Number.isInteger(claim.attemptCount) ||
      claim.attemptCount < 1 || claim.attemptCount > 5 ||
      (claim.processingState !== "processing" &&
        claim.processingState !== "processed") ||
      claim.replayed !== (claim.processingState === "processed")
    ) {
      throw new SafeDocumentError("internal_error");
    }
    if (claim.replayed) {
      const replayed = await loadStrictProcessedBatch(
        dependencies.processingStore,
        caller,
        body.source_id,
      );
      return batchResponse(replayed);
    }
    try {
      const stored = await dependencies.sourceStore.loadOwnedSource(
        caller,
        body.source_id,
        claim.version,
      );
      if (
        stored.source.id !== body.source_id ||
        stored.source.owner_user_id !== caller.ownerUserId ||
        stored.source.processing_state !== "processing" ||
        stored.source.version !== claim.version
      ) {
        throw new SafeDocumentError("source_not_found");
      }
      const input = await validateStoredDocument(stored);
      const batch = await withTimeout(
        Promise.resolve(dependencies.extractor.extract(input)).then(
          validateDocumentCandidateBatch,
        ),
        dependencies.configuration.requestTimeoutMs,
      );
      if (
        batch.source_id !== input.sourceId ||
        batch.content_hash !== input.contentHash ||
        batch.timezone !== "Asia/Tokyo" || batch.candidates.length > 20
      ) {
        throw new SafeDocumentError("invalid_extraction");
      }
      const replacement = await dependencies.candidateStore.replaceCandidates(
        caller,
        batch,
        claim.version,
      );
      assertReplacementContract(replacement, batch);
      if (replacement.replayed) {
        return batchResponse(
          await loadStrictProcessedBatch(
            dependencies.processingStore,
            caller,
            body.source_id,
          ),
        );
      }
      return batchResponse(batch);
    } catch (rawError) {
      const error = safeError(rawError);
      await recordProcessingFailure(
        dependencies.processingStore,
        caller,
        body.source_id,
        claim.version,
        error,
      );
      throw error;
    }
  } catch (rawError) {
    return errorResponse(safeError(rawError));
  }
}

if (import.meta.main) {
  Deno.serve((request) => handleDocumentImportRequest(request));
}
