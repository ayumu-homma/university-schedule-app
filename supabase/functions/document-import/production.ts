import {
  documentCandidateContract,
  validateDocumentCandidateBatch,
} from "./candidate_codec.ts";
import {
  type DocumentJsonModelClient,
  type DocumentJsonModelRequest,
} from "./extraction.ts";
import { documentInputLimits } from "./document_validation.ts";
import {
  type AuthenticatedDocumentCaller,
  type DocumentAuthenticator,
  type DocumentCandidateReplacement,
  type DocumentCandidateStore,
  documentImportErrorCategories,
  type DocumentImportErrorCategory,
  type DocumentMediaType,
  documentMediaTypes,
  type DocumentProcessingClaim,
  type DocumentProcessingStore,
  type DocumentSourceStore,
  type PersistedDocumentSource,
  retryableDocumentErrors,
  SafeDocumentError,
  type ScheduleCandidateBatchV1,
  type StoredDocumentInput,
} from "./types.ts";

const encoder = new TextEncoder();
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sha256Pattern = /^[a-f0-9]{64}$/;
const maximumJsonResponseBytes = 1024 * 1024;
const maximumProviderRetryDelayMs = 2_000;
const maximumOpenAiApiKeyCharacters = 512;
const minimumOpenAiApiKeyPayloadCharacters = 20;
const providerNeutralSourceId = "provider-neutral";
const providerNeutralContentHash = "0".repeat(64);
const jwtLikePattern =
  /^[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}$/;
const documentSourceStates = new Set([
  "pending_upload",
  "uploaded",
  "processing",
  "processed",
  "failed",
  "deleted",
]);
const documentSourceErrorCategories: ReadonlySet<string> = new Set(
  documentImportErrorCategories,
);
const sourceFields = new Set([
  "id",
  "owner_user_id",
  "storage_path",
  "media_type",
  "byte_size",
  "content_hash",
  "processing_state",
  "error_category",
  "processing_attempt_count",
  "retry_after_at",
  "retention_expires_at",
  "created_at",
  "updated_at",
  "deleted_at",
  "version",
]);
const processingClaimFields = new Set([
  "source_id",
  "processing_state",
  "attempt_count",
  "version",
  "replayed",
]);
const candidateReplacementFields = new Set([
  "source_id",
  "processing_state",
  "candidate_count",
  "version",
  "replayed",
]);
const processedSourceFields = new Set([
  "id",
  "owner_user_id",
  "content_hash",
  "processing_state",
  "retention_expires_at",
  "deleted_at",
]);
const persistedCandidateFields = new Set(["validated_payload"]);

function hasControlCharacter(value: string): boolean {
  return Array.from(value).some((character) =>
    (character.codePointAt(0) ?? 0) < 0x20
  );
}

function isPrintableAscii(value: string): boolean {
  return Array.from(value).every((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint >= 0x21 && codePoint <= 0x7e;
  });
}

export interface DocumentProductionRuntime {
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly sleep?: (delayMs: number) => Promise<void>;
  readonly recordProviderEvent?: (event: DocumentProviderEvent) => void;
}

export interface DocumentProviderEvent {
  readonly event: "document_import_provider";
  readonly environment: "local" | "staging" | "production";
  readonly model: string;
  readonly attempt: number;
  readonly outcome: "success" | "retry" | "failure";
  readonly httpStatus: number | null;
  readonly errorCategory: DocumentImportErrorCategory | null;
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly totalTokens: number | null;
}

export const defaultDocumentProductionRuntime: DocumentProductionRuntime =
  Object.freeze({
    fetch: globalThis.fetch.bind(globalThis),
    now: () => new Date(),
    sleep: (delayMs: number): Promise<void> =>
      new Promise<void>((resolve) => {
        setTimeout(resolve, delayMs);
      }),
    recordProviderEvent: (event: DocumentProviderEvent): void => {
      // This event is deliberately allowlisted: no user/source identifier,
      // document material, provider response body, credential, or request URL.
      console.info(JSON.stringify(event));
    },
  });

export interface DocumentProductionConfiguration {
  readonly appEnvironment: "local" | "staging" | "production";
  readonly supabaseProjectRef: string;
  readonly supabaseUrl: URL;
  readonly supabaseAnonKey: string;
  readonly openAiApiKey: string;
  readonly modelId: string;
  readonly requestTimeoutMs: number;
  readonly providerMaximumAttempts: number;
  readonly providerRetryBaseDelayMs: number;
}

function requiredEnvironment(
  readEnvironment: (name: string) => string | undefined,
  name: string,
  maximumCharacters: number,
): string {
  const value = readEnvironment(name);
  if (
    value === undefined || value.length === 0 || value !== value.trim() ||
    Array.from(value).length > maximumCharacters || hasControlCharacter(value)
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  return value;
}

function requiredSupabaseUrl(
  value: string,
  appEnvironment: DocumentProductionConfiguration["appEnvironment"],
  projectRef: string,
): URL {
  let parsed: URL;
  try {
    parsed = new URL(value.endsWith("/") ? value : `${value}/`);
  } catch {
    throw new SafeDocumentError("configuration_missing");
  }
  if (
    parsed.username.length > 0 || parsed.password.length > 0 ||
    parsed.search.length > 0 || parsed.hash.length > 0 ||
    parsed.pathname !== "/"
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  const localLoopbackGateway = parsed.protocol === "http:" &&
    (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost") &&
    parsed.port === "54321";
  const localContainerGateway = parsed.protocol === "http:" &&
    parsed.hostname === "kong" && parsed.port === "8000";
  if (
    appEnvironment === "local" &&
    !localLoopbackGateway && !localContainerGateway
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  if (
    appEnvironment !== "local" &&
    (parsed.protocol !== "https:" ||
      parsed.port.length > 0 ||
      parsed.hostname !== `${projectRef}.supabase.co`)
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  return parsed;
}

function requiredAppEnvironment(
  readEnvironment: (name: string) => string | undefined,
): DocumentProductionConfiguration["appEnvironment"] {
  const value = requiredEnvironment(readEnvironment, "APP_ENV", 16);
  if (value !== "local" && value !== "staging" && value !== "production") {
    throw new SafeDocumentError("configuration_missing");
  }
  return value;
}

function requiredProjectRef(
  readEnvironment: (name: string) => string | undefined,
  appEnvironment: DocumentProductionConfiguration["appEnvironment"],
): string {
  const value = requiredEnvironment(
    readEnvironment,
    "APP_SUPABASE_PROJECT_REF",
    64,
  );
  if (
    (appEnvironment === "local" && value !== "local") ||
    (appEnvironment !== "local" && !/^[a-z0-9]{20}$/.test(value))
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  return value;
}

function optionalBoundedInteger(
  readEnvironment: (name: string) => string | undefined,
  name: string,
  defaultValue: number,
  minimum: number,
  maximum: number,
): number {
  const source = readEnvironment(name);
  if (
    source !== undefined &&
    (source.length === 0 || source !== source.trim() ||
      hasControlCharacter(source))
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  const parsed = source === undefined ? defaultValue : Number(source);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new SafeDocumentError("configuration_missing");
  }
  return parsed;
}

function legacySupabaseJwtRole(value: string): string | null {
  const segments = value.split(".");
  if (segments.length !== 3) return null;
  try {
    const payload = segments[1].replaceAll("-", "+").replaceAll("_", "/");
    const padded = payload.padEnd(Math.ceil(payload.length / 4) * 4, "=");
    const decoded = JSON.parse(atob(padded));
    return isRecord(decoded) && typeof decoded.role === "string"
      ? decoded.role
      : null;
  } catch {
    return null;
  }
}

function looksLikeServerSideSupabaseKey(value: string): boolean {
  if (value.toLowerCase().startsWith("sb_secret_")) return true;
  return legacySupabaseJwtRole(value) === "service_role";
}

function isAllowedSupabaseClientKey(value: string): boolean {
  return /^sb_publishable_[A-Za-z0-9_-]+$/.test(value) ||
    legacySupabaseJwtRole(value) === "anon";
}

function isOpenAiSecretKey(value: string): boolean {
  if (
    !isPrintableAscii(value) ||
    Array.from(value).length > maximumOpenAiApiKeyCharacters
  ) {
    return false;
  }
  if (value.startsWith("sk-proj-")) {
    const payload = value.slice("sk-proj-".length);
    return payload.length >= minimumOpenAiApiKeyPayloadCharacters &&
      /^[A-Za-z0-9_-]+$/.test(payload);
  }
  if (value.startsWith("sk-")) {
    const payload = value.slice("sk-".length);
    return payload.length >= minimumOpenAiApiKeyPayloadCharacters &&
      /^[A-Za-z0-9]+$/.test(payload);
  }
  return false;
}

function looksLikeCredential(value: string): boolean {
  const lower = value.toLowerCase();
  return lower.startsWith("sk-") || lower.startsWith("sb_secret_") ||
    lower.startsWith("sb_publishable_") || jwtLikePattern.test(value);
}

function requiredOpenAiApiKey(
  readEnvironment: (name: string) => string | undefined,
  supabaseClientKeys: readonly string[],
): string {
  const value = requiredEnvironment(
    readEnvironment,
    "OPENAI_API_KEY",
    maximumOpenAiApiKeyCharacters,
  );
  if (
    !isOpenAiSecretKey(value) ||
    value.toLowerCase().startsWith("sb_secret_") ||
    value.toLowerCase().startsWith("sb_publishable_") ||
    legacySupabaseJwtRole(value) === "service_role" ||
    legacySupabaseJwtRole(value) === "anon" ||
    supabaseClientKeys.some((clientKey) => clientKey === value)
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  return value;
}

export function parseDocumentProductionConfiguration(
  readEnvironment: (name: string) => string | undefined,
): DocumentProductionConfiguration {
  const appEnvironment = requiredAppEnvironment(readEnvironment);
  const projectRef = requiredProjectRef(readEnvironment, appEnvironment);
  if (
    readEnvironment("DOCUMENT_IMPORT_MODEL_ENABLED") !== "true" ||
    readEnvironment("DOCUMENT_IMPORT_PROVIDER") !== "openai_responses" ||
    readEnvironment("DOCUMENT_IMPORT_FAKE_ENABLED") !== "false"
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  const parsedTimeout = optionalBoundedInteger(
    readEnvironment,
    "DOCUMENT_IMPORT_TIMEOUT_MS",
    25_000,
    1_000,
    60_000,
  );
  const maximumAttempts = optionalBoundedInteger(
    readEnvironment,
    "DOCUMENT_IMPORT_PROVIDER_MAX_ATTEMPTS",
    2,
    1,
    2,
  );
  const retryBaseDelayMs = optionalBoundedInteger(
    readEnvironment,
    "DOCUMENT_IMPORT_RETRY_BASE_MS",
    250,
    0,
    maximumProviderRetryDelayMs,
  );
  const modelId = requiredEnvironment(
    readEnvironment,
    "DOCUMENT_IMPORT_MODEL_ID",
    200,
  );
  if (
    !/^[A-Za-z0-9._:-]+$/.test(modelId) || looksLikeCredential(modelId)
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  const supabaseAnonKey = requiredEnvironment(
    readEnvironment,
    "SUPABASE_ANON_KEY",
    16_384,
  );
  if (
    looksLikeServerSideSupabaseKey(supabaseAnonKey) ||
    (appEnvironment !== "local" && !isAllowedSupabaseClientKey(supabaseAnonKey))
  ) {
    throw new SafeDocumentError("configuration_missing");
  }
  const openAiApiKey = requiredOpenAiApiKey(
    readEnvironment,
    [supabaseAnonKey],
  );
  if (modelId === openAiApiKey || modelId === supabaseAnonKey) {
    throw new SafeDocumentError("configuration_missing");
  }
  return Object.freeze({
    appEnvironment,
    supabaseProjectRef: projectRef,
    supabaseUrl: requiredSupabaseUrl(
      requiredEnvironment(readEnvironment, "SUPABASE_URL", 2_048),
      appEnvironment,
      projectRef,
    ),
    supabaseAnonKey,
    openAiApiKey,
    modelId,
    requestTimeoutMs: parsedTimeout,
    providerMaximumAttempts: maximumAttempts,
    providerRetryBaseDelayMs: retryBaseDelayMs,
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactFields(
  value: Record<string, unknown>,
  expected: ReadonlySet<string>,
): boolean {
  const keys = Object.keys(value);
  return keys.length === expected.size &&
    keys.every((key) => expected.has(key));
}

async function boundedJson(
  response: Response,
  maximumBytes = maximumJsonResponseBytes,
): Promise<unknown> {
  const bytes = await readBoundedBytes(
    response,
    maximumBytes,
    "provider_unavailable",
  );
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new SafeDocumentError("provider_unavailable");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new SafeDocumentError("provider_unavailable");
  }
}

async function readBoundedBytes(
  response: Response,
  maximumBytes: number,
  overflowCategory: "oversized_file" | "provider_unavailable" =
    "oversized_file",
): Promise<Uint8Array> {
  const declared = response.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isInteger(length) || length < 0 || length > maximumBytes) {
      await response.body?.cancel();
      throw new SafeDocumentError(overflowCategory);
    }
  }
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new SafeDocumentError(overflowCategory);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function bearerAuthorization(request: Request): string {
  const value = request.headers.get("authorization");
  if (
    value === null || value.length > 8_192 ||
    !/^Bearer [A-Za-z0-9._~-]+$/.test(value)
  ) {
    throw new SafeDocumentError("unauthorized");
  }
  return value;
}

export class SupabaseDocumentAuthenticator implements DocumentAuthenticator {
  readonly #configuration: DocumentProductionConfiguration;
  readonly #runtime: DocumentProductionRuntime;

  constructor(
    configuration: DocumentProductionConfiguration,
    runtime: DocumentProductionRuntime = defaultDocumentProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async authenticate(request: Request): Promise<AuthenticatedDocumentCaller> {
    const authorization = bearerAuthorization(request);
    const endpoint = new URL("auth/v1/user", this.#configuration.supabaseUrl);
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "GET",
        headers: {
          authorization,
          apikey: this.#configuration.supabaseAnonKey,
          accept: "application/json",
        },
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch {
      throw new SafeDocumentError("unauthorized");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SafeDocumentError("unauthorized");
    }
    const body = await boundedJson(response, 64 * 1024);
    if (
      !isRecord(body) || typeof body.id !== "string" ||
      !uuidPattern.test(body.id)
    ) {
      throw new SafeDocumentError("unauthorized");
    }
    return Object.freeze({ ownerUserId: body.id, authorization });
  }
}

function requiredString(
  value: unknown,
  maximumCharacters: number,
): string {
  if (
    typeof value !== "string" || value.length === 0 || value !== value.trim() ||
    Array.from(value).length > maximumCharacters || hasControlCharacter(value)
  ) {
    throw new SafeDocumentError("provider_unavailable");
  }
  return value;
}

function persistedSource(value: unknown): PersistedDocumentSource {
  if (!isRecord(value) || !hasExactFields(value, sourceFields)) {
    throw new SafeDocumentError("provider_unavailable");
  }
  const id = requiredString(value.id, 64);
  const owner = requiredString(value.owner_user_id, 64);
  const storagePath = requiredString(value.storage_path, 512);
  const mediaType = requiredString(value.media_type, 64);
  const contentHash = requiredString(value.content_hash, 64);
  const state = requiredString(value.processing_state, 64);
  const retentionExpiresAt = requiredString(value.retention_expires_at, 64);
  const createdAt = requiredString(value.created_at, 64);
  const updatedAt = requiredString(value.updated_at, 64);
  const errorCategory = value.error_category === null
    ? null
    : requiredString(value.error_category, 64);
  const retryAfterAt = value.retry_after_at === null
    ? null
    : requiredString(value.retry_after_at, 64);
  const deletedAt = value.deleted_at === null
    ? null
    : requiredString(value.deleted_at, 64);
  if (
    !uuidPattern.test(id) || !uuidPattern.test(owner) ||
    !documentMediaTypes.includes(mediaType as DocumentMediaType) ||
    !sha256Pattern.test(contentHash) || !documentSourceStates.has(state) ||
    typeof value.byte_size !== "number" || !Number.isInteger(value.byte_size) ||
    value.byte_size < 1 ||
    value.byte_size > documentInputLimits.maximumFileBytes ||
    (errorCategory !== null &&
      !documentSourceErrorCategories.has(errorCategory)) ||
    typeof value.processing_attempt_count !== "number" ||
    !Number.isInteger(value.processing_attempt_count) ||
    value.processing_attempt_count < 0 || value.processing_attempt_count > 5 ||
    typeof value.version !== "number" || !Number.isInteger(value.version) ||
    value.version < 1 || !Number.isFinite(Date.parse(createdAt)) ||
    !Number.isFinite(Date.parse(updatedAt)) ||
    !Number.isFinite(Date.parse(retentionExpiresAt)) ||
    (retryAfterAt !== null && !Number.isFinite(Date.parse(retryAfterAt))) ||
    (deletedAt !== null && !Number.isFinite(Date.parse(deletedAt))) ||
    ((state === "failed") !== (errorCategory !== null)) ||
    (retryAfterAt !== null && state !== "failed") ||
    Date.parse(retentionExpiresAt) <= Date.parse(createdAt) ||
    ((state === "deleted") !== (deletedAt !== null))
  ) {
    throw new SafeDocumentError("provider_unavailable");
  }
  return Object.freeze({
    id,
    owner_user_id: owner,
    storage_path: storagePath,
    media_type: mediaType as DocumentMediaType,
    byte_size: value.byte_size,
    content_hash: contentHash,
    processing_state: state,
    error_category: errorCategory,
    processing_attempt_count: value.processing_attempt_count,
    retry_after_at: retryAfterAt,
    retention_expires_at: retentionExpiresAt,
    created_at: createdAt,
    updated_at: updatedAt,
    deleted_at: deletedAt,
    version: value.version,
  });
}

function extensionFor(mediaType: DocumentMediaType): string {
  switch (mediaType) {
    case "application/pdf":
      return "pdf";
    case "image/png":
      return "png";
    case "image/jpeg":
      return "jpg";
    case "text/plain":
      return "txt";
  }
}

function expectedStoragePath(source: PersistedDocumentSource): string {
  return `${source.owner_user_id}/${source.id}/source.${
    extensionFor(source.media_type)
  }`;
}

function authenticatedHeaders(
  caller: AuthenticatedDocumentCaller,
  configuration: DocumentProductionConfiguration,
): Readonly<Record<string, string>> {
  return {
    authorization: caller.authorization,
    apikey: configuration.supabaseAnonKey,
    accept: "application/json",
  };
}

async function safePostgrestRpcError(
  response: Response,
): Promise<SafeDocumentError> {
  if (response.status === 401) {
    await response.body?.cancel();
    return new SafeDocumentError("unauthorized");
  }
  if (response.status === 429) {
    await response.body?.cancel();
    return new SafeDocumentError("rate_limited", { retryAfterMs: 5_000 });
  }

  let message: unknown;
  try {
    const body = await boundedJson(response, 32 * 1024);
    message = isRecord(body) ? body.message : null;
  } catch {
    message = null;
  }
  switch (message) {
    case "authentication_required":
      return new SafeDocumentError("unauthorized");
    case "document_source_forbidden":
    case "document_source_not_found":
    case "document_object_not_found":
    case "document_upload_incomplete":
      return new SafeDocumentError("source_not_found");
    case "document_processing_in_progress":
      return new SafeDocumentError("rate_limited", {
        retryAfterMs: 10_000,
      });
    case "document_retry_delayed":
      return new SafeDocumentError("rate_limited", { retryAfterMs: 5_000 });
    case "document_processing_version_conflict":
      return new SafeDocumentError("rate_limited", { retryAfterMs: 1_000 });
    case "document_attempt_limit":
    case "invalid_document_failure":
    case "invalid_document_retry":
    case "invalid_candidate_batch":
    case "too_many_candidates":
    case "document_processing_not_claimed":
      return new SafeDocumentError("invalid_extraction");
  }
  if (response.status === 403) {
    return new SafeDocumentError("unauthorized");
  }
  if (response.status === 404) {
    return new SafeDocumentError("configuration_missing");
  }
  if (response.status === 408 || response.status === 504) {
    return new SafeDocumentError("timeout");
  }
  if (response.status === 409) {
    return new SafeDocumentError("rate_limited", { retryAfterMs: 1_000 });
  }
  if (response.status === 422) {
    return new SafeDocumentError("invalid_extraction");
  }
  return new SafeDocumentError("provider_unavailable");
}

function processingClaim(
  value: unknown,
  expectedSourceId: string,
): DocumentProcessingClaim {
  if (!isRecord(value) || !hasExactFields(value, processingClaimFields)) {
    throw new SafeDocumentError("provider_unavailable");
  }
  const sourceId = requiredString(value.source_id, 64);
  const state = requiredString(value.processing_state, 32);
  if (
    sourceId !== expectedSourceId || !uuidPattern.test(sourceId) ||
    (state !== "processing" && state !== "processed") ||
    typeof value.attempt_count !== "number" ||
    !Number.isInteger(value.attempt_count) || value.attempt_count < 1 ||
    value.attempt_count > 5 || typeof value.version !== "number" ||
    !Number.isInteger(value.version) || value.version < 1 ||
    typeof value.replayed !== "boolean" ||
    (value.replayed !== (state === "processed"))
  ) {
    throw new SafeDocumentError("provider_unavailable");
  }
  return Object.freeze({
    sourceId,
    processingState: state,
    attemptCount: value.attempt_count,
    version: value.version,
    replayed: value.replayed,
  });
}

function candidateReplacement(
  value: unknown,
  batch: ScheduleCandidateBatchV1,
): DocumentCandidateReplacement {
  if (!isRecord(value) || !hasExactFields(value, candidateReplacementFields)) {
    throw new SafeDocumentError("invalid_extraction");
  }
  if (
    typeof value.source_id !== "string" ||
    value.source_id !== batch.source_id || !uuidPattern.test(value.source_id) ||
    value.processing_state !== "processed" ||
    typeof value.candidate_count !== "number" ||
    !Number.isInteger(value.candidate_count) ||
    value.candidate_count !== batch.candidates.length ||
    typeof value.version !== "number" || !Number.isInteger(value.version) ||
    value.version < 1 || typeof value.replayed !== "boolean"
  ) {
    throw new SafeDocumentError("invalid_extraction");
  }
  return Object.freeze({
    sourceId: value.source_id,
    processingState: value.processing_state,
    candidateCount: value.candidate_count,
    version: value.version,
    replayed: value.replayed,
  });
}

function assertExpectedVersion(value: number): void {
  if (!Number.isInteger(value) || value < 1) {
    throw new SafeDocumentError("internal_error");
  }
}

export class SupabasePrivateDocumentRepository
  implements
    DocumentSourceStore,
    DocumentCandidateStore,
    DocumentProcessingStore {
  readonly #configuration: DocumentProductionConfiguration;
  readonly #runtime: DocumentProductionRuntime;

  constructor(
    configuration: DocumentProductionConfiguration,
    runtime: DocumentProductionRuntime = defaultDocumentProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async beginProcessing(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
  ): Promise<DocumentProcessingClaim> {
    if (!uuidPattern.test(sourceId)) {
      throw new SafeDocumentError("source_not_found");
    }
    const endpoint = new URL(
      "rest/v1/rpc/begin_document_processing",
      this.#configuration.supabaseUrl,
    );
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "POST",
        headers: {
          ...authenticatedHeaders(caller, this.#configuration),
          "content-type": "application/json",
        },
        body: JSON.stringify({ p_source_id: sourceId }),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (!response.ok) throw await safePostgrestRpcError(response);
    return processingClaim(await boundedJson(response, 16 * 1024), sourceId);
  }

  async loadProcessedBatch(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
  ): Promise<ScheduleCandidateBatchV1> {
    if (!uuidPattern.test(sourceId)) {
      throw new SafeDocumentError("source_not_found");
    }
    const sourceUrl = new URL(
      "rest/v1/document_sources",
      this.#configuration.supabaseUrl,
    );
    sourceUrl.searchParams.set("id", `eq.${sourceId}`);
    sourceUrl.searchParams.set("processing_state", "eq.processed");
    sourceUrl.searchParams.set("deleted_at", "is.null");
    sourceUrl.searchParams.set("select", [...processedSourceFields].join(","));
    sourceUrl.searchParams.set("limit", "1");
    let response: Response;
    try {
      response = await this.#runtime.fetch(sourceUrl, {
        method: "GET",
        headers: authenticatedHeaders(caller, this.#configuration),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new SafeDocumentError("unauthorized");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SafeDocumentError("provider_unavailable");
    }
    const sources = await boundedJson(response, 32 * 1024);
    if (!Array.isArray(sources) || sources.length === 0) {
      throw new SafeDocumentError("source_not_found");
    }
    if (sources.length !== 1) {
      throw new SafeDocumentError("provider_unavailable");
    }
    const rawSource = sources[0];
    if (
      !isRecord(rawSource) || !hasExactFields(rawSource, processedSourceFields)
    ) {
      throw new SafeDocumentError("provider_unavailable");
    }
    const owner = requiredString(rawSource.owner_user_id, 64);
    const contentHash = requiredString(rawSource.content_hash, 64);
    const retentionExpiresAt = requiredString(
      rawSource.retention_expires_at,
      64,
    );
    if (
      rawSource.id !== sourceId || owner !== caller.ownerUserId ||
      rawSource.processing_state !== "processed" ||
      rawSource.deleted_at !== null || !sha256Pattern.test(contentHash) ||
      !Number.isFinite(Date.parse(retentionExpiresAt)) ||
      Date.parse(retentionExpiresAt) <= this.#runtime.now().getTime()
    ) {
      throw new SafeDocumentError("source_not_found");
    }

    const candidatesUrl = new URL(
      "rest/v1/document_candidates",
      this.#configuration.supabaseUrl,
    );
    candidatesUrl.searchParams.set("source_id", `eq.${sourceId}`);
    candidatesUrl.searchParams.set("deleted_at", "is.null");
    candidatesUrl.searchParams.set(
      "select",
      [...persistedCandidateFields].join(","),
    );
    candidatesUrl.searchParams.set("order", "candidate_key.asc");
    candidatesUrl.searchParams.set("limit", "21");
    try {
      response = await this.#runtime.fetch(candidatesUrl, {
        method: "GET",
        headers: authenticatedHeaders(caller, this.#configuration),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new SafeDocumentError("unauthorized");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SafeDocumentError("provider_unavailable");
    }
    const rows = await boundedJson(response, 512 * 1024);
    if (!Array.isArray(rows) || rows.length > 20) {
      throw new SafeDocumentError("invalid_extraction");
    }
    const candidates = rows.map((row) => {
      if (!isRecord(row) || !hasExactFields(row, persistedCandidateFields)) {
        throw new SafeDocumentError("invalid_extraction");
      }
      return row.validated_payload;
    });
    return validateDocumentCandidateBatch({
      schema_version: "1.0",
      source_id: sourceId,
      content_hash: contentHash,
      timezone: "Asia/Tokyo",
      candidates,
    });
  }

  async loadOwnedSource(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
    expectedVersion: number,
  ): Promise<StoredDocumentInput> {
    assertExpectedVersion(expectedVersion);
    if (!uuidPattern.test(sourceId)) {
      throw new SafeDocumentError("source_not_found");
    }
    const lookup = new URL(
      "rest/v1/document_sources",
      this.#configuration.supabaseUrl,
    );
    lookup.searchParams.set("id", `eq.${sourceId}`);
    lookup.searchParams.set("deleted_at", "is.null");
    lookup.searchParams.set("select", [...sourceFields].join(","));
    lookup.searchParams.set("limit", "1");
    let response: Response;
    try {
      response = await this.#runtime.fetch(lookup, {
        method: "GET",
        headers: authenticatedHeaders(caller, this.#configuration),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new SafeDocumentError("unauthorized");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SafeDocumentError("provider_unavailable");
    }
    const body = await boundedJson(response, 64 * 1024);
    if (!Array.isArray(body) || body.length === 0) {
      throw new SafeDocumentError("source_not_found");
    }
    if (body.length !== 1) throw new SafeDocumentError("provider_unavailable");
    const source = persistedSource(body[0]);
    if (
      source.owner_user_id !== caller.ownerUserId || source.id !== sourceId ||
      source.deleted_at !== null ||
      source.storage_path !== expectedStoragePath(source)
    ) {
      throw new SafeDocumentError("source_not_found");
    }
    if (
      source.processing_state !== "processing" ||
      source.version !== expectedVersion
    ) {
      throw new SafeDocumentError("rate_limited", { retryAfterMs: 5_000 });
    }
    if (
      source.error_category !== null || source.retry_after_at !== null ||
      Date.parse(source.retention_expires_at) <= this.#runtime.now().getTime()
    ) {
      throw new SafeDocumentError("source_not_found");
    }

    const encodedPath = source.storage_path.split("/").map(encodeURIComponent)
      .join("/");
    const objectUrl = new URL(
      `storage/v1/object/authenticated/schedule-documents/${encodedPath}`,
      this.#configuration.supabaseUrl,
    );
    try {
      response = await this.#runtime.fetch(objectUrl, {
        method: "GET",
        headers: authenticatedHeaders(caller, this.#configuration),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (response.status === 401 || response.status === 403) {
      await response.body?.cancel();
      throw new SafeDocumentError("source_not_found");
    }
    if (response.status === 404) {
      await response.body?.cancel();
      throw new SafeDocumentError("source_not_found");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new SafeDocumentError("provider_unavailable");
    }
    const bytes = await readBoundedBytes(
      response,
      source.byte_size,
    );
    return Object.freeze({ source, bytes });
  }

  async failProcessing(
    caller: AuthenticatedDocumentCaller,
    sourceId: string,
    expectedVersion: number,
    category: DocumentImportErrorCategory,
    retryAfterSeconds: number | null,
  ): Promise<void> {
    assertExpectedVersion(expectedVersion);
    if (
      !uuidPattern.test(sourceId) ||
      !documentImportErrorCategories.includes(category) ||
      (retryAfterSeconds !== null &&
        !retryableDocumentErrors.has(category)) ||
      (retryAfterSeconds !== null &&
        (!Number.isInteger(retryAfterSeconds) || retryAfterSeconds < 0 ||
          retryAfterSeconds > 86_400))
    ) {
      throw new SafeDocumentError("internal_error");
    }
    const endpoint = new URL(
      "rest/v1/rpc/fail_document_processing",
      this.#configuration.supabaseUrl,
    );
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "POST",
        headers: {
          ...authenticatedHeaders(caller, this.#configuration),
          "content-type": "application/json",
          prefer: "return=minimal",
        },
        body: JSON.stringify({
          p_source_id: sourceId,
          p_expected_version: expectedVersion,
          p_error_category: category,
          p_retry_after_seconds: retryAfterSeconds,
        }),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (!response.ok) throw await safePostgrestRpcError(response);
    await response.body?.cancel();
  }

  async replaceCandidates(
    caller: AuthenticatedDocumentCaller,
    batch: ScheduleCandidateBatchV1,
    expectedVersion: number,
  ): Promise<DocumentCandidateReplacement> {
    assertExpectedVersion(expectedVersion);
    const endpoint = new URL(
      "rest/v1/rpc/replace_document_candidates",
      this.#configuration.supabaseUrl,
    );
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "POST",
        headers: {
          ...authenticatedHeaders(caller, this.#configuration),
          "content-type": "application/json",
        },
        body: JSON.stringify({
          p_source_id: batch.source_id,
          p_content_hash: batch.content_hash,
          p_expected_version: expectedVersion,
          p_batch: batch,
        }),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new SafeDocumentError("timeout");
      }
      throw new SafeDocumentError("network_unavailable");
    }
    if (!response.ok) throw await safePostgrestRpcError(response);
    let value: unknown;
    try {
      value = await boundedJson(response, 16 * 1024);
    } catch {
      throw new SafeDocumentError("invalid_extraction");
    }
    return candidateReplacement(value, batch);
  }
}

const nullableStringSchema = (maximum: number) => ({
  anyOf: [
    { type: "string", minLength: 1, maxLength: maximum },
    { type: "null" },
  ],
});

export const documentCandidateBatchJsonSchema = Object.freeze({
  type: "object",
  additionalProperties: false,
  required: [
    "schema_version",
    "source_id",
    "content_hash",
    "timezone",
    "candidates",
  ],
  properties: {
    schema_version: { const: "1.0" },
    source_id: { const: providerNeutralSourceId },
    content_hash: { const: providerNeutralContentHash },
    timezone: { const: "Asia/Tokyo" },
    candidates: {
      type: "array",
      maxItems: documentCandidateContract.maximumCandidates,
      items: {
        type: "object",
        additionalProperties: false,
        required: [
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
        ],
        properties: {
          candidate_id: { type: "string", minLength: 1, maxLength: 128 },
          type: { enum: ["assignment", "exam"] },
          title: {
            type: "string",
            minLength: 1,
            maxLength: documentCandidateContract.maximumTitleCharacters,
          },
          course_hint: {
            type: "object",
            additionalProperties: false,
            required: ["name", "code"],
            properties: {
              name: nullableStringSchema(
                documentCandidateContract.maximumCourseCharacters,
              ),
              code: nullableStringSchema(
                documentCandidateContract.maximumCourseCodeCharacters,
              ),
            },
          },
          due_at: nullableStringSchema(64),
          all_day: { type: "boolean" },
          start_at: nullableStringSchema(64),
          end_at: nullableStringSchema(64),
          location: nullableStringSchema(
            documentCandidateContract.maximumLocationCharacters,
          ),
          submission_url: nullableStringSchema(2_048),
          notes: nullableStringSchema(
            documentCandidateContract.maximumNotesCharacters,
          ),
          confidence: {
            type: "object",
            additionalProperties: false,
            required: ["overall", "course", "date_time"],
            properties: {
              overall: { type: "number", minimum: 0, maximum: 1 },
              course: { type: "number", minimum: 0, maximum: 1 },
              date_time: { type: "number", minimum: 0, maximum: 1 },
            },
          },
          evidence: {
            type: "array",
            minItems: 1,
            maxItems: documentCandidateContract.maximumEvidenceItems,
            items: {
              type: "object",
              additionalProperties: false,
              required: ["page_number", "section", "excerpt"],
              properties: {
                page_number: {
                  anyOf: [
                    { type: "integer", minimum: 1, maximum: 500 },
                    { type: "null" },
                  ],
                },
                section: nullableStringSchema(
                  documentCandidateContract.maximumEvidenceSectionCharacters,
                ),
                excerpt: {
                  type: "string",
                  minLength: 1,
                  maxLength:
                    documentCandidateContract.maximumEvidenceExcerptCharacters,
                },
              },
            },
          },
          warnings: {
            type: "array",
            maxItems: 7,
            items: {
              enum: [
                "missing_year",
                "missing_date",
                "missing_time",
                "ambiguous_course",
                "duplicate_mention",
                "relative_date",
                "low_confidence",
              ],
            },
          },
          requires_user_confirmation: { const: true },
        },
      },
    },
  },
});

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(
      ...bytes.subarray(offset, offset + chunkSize),
    );
  }
  return btoa(binary);
}

function providerRetryAfterMs(response: Response, now: Date): number | null {
  let retryAfterMs: number | null = null;
  const retryAfter = response.headers.get("retry-after");
  if (retryAfter !== null) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds >= 0) {
      retryAfterMs = Math.min(86_400_000, Math.floor(seconds * 1_000));
    } else {
      const date = Date.parse(retryAfter);
      if (Number.isFinite(date)) {
        retryAfterMs = Math.min(86_400_000, Math.max(0, date - now.getTime()));
      }
    }
  }
  return retryAfterMs;
}

function safeProviderError(response: Response, now: Date): SafeDocumentError {
  const retryAfterMs = providerRetryAfterMs(response, now);
  if (response.status === 401 || response.status === 403) {
    return new SafeDocumentError("configuration_missing");
  }
  if (response.status === 408 || response.status === 504) {
    return new SafeDocumentError("timeout");
  }
  if (response.status === 429) {
    return new SafeDocumentError("rate_limited", { retryAfterMs });
  }
  if (response.status >= 500) {
    return new SafeDocumentError("provider_unavailable");
  }
  return new SafeDocumentError("invalid_extraction");
}

const transientProviderErrors: ReadonlySet<DocumentImportErrorCategory> =
  new Set([
    "network_unavailable",
    "timeout",
    "rate_limited",
    "provider_unavailable",
  ]);

function providerErrorCategory(
  error: SafeDocumentError,
): DocumentImportErrorCategory {
  return documentSourceErrorCategories.has(error.category)
    ? error.category as DocumentImportErrorCategory
    : "internal_error";
}

function safeTokenCount(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) &&
      value >= 0 &&
      value <= 100_000_000
    ? value
    : null;
}

function providerTokenUsage(value: unknown): {
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly totalTokens: number | null;
} {
  const usage = isRecord(value) && isRecord(value.usage) ? value.usage : null;
  return Object.freeze({
    inputTokens: usage === null ? null : safeTokenCount(usage.input_tokens),
    outputTokens: usage === null ? null : safeTokenCount(usage.output_tokens),
    totalTokens: usage === null ? null : safeTokenCount(usage.total_tokens),
  });
}

function recordProviderEvent(
  runtime: DocumentProductionRuntime,
  configuration: DocumentProductionConfiguration,
  event: Omit<
    DocumentProviderEvent,
    "event" | "environment" | "model"
  >,
): void {
  try {
    runtime.recordProviderEvent?.(Object.freeze({
      event: "document_import_provider",
      environment: configuration.appEnvironment,
      model: configuration.modelId,
      ...event,
    }));
  } catch {
    // Observability is best-effort and must not change the extraction result.
  }
}

async function providerRetryDelay(
  runtime: DocumentProductionRuntime,
  response: Response | null,
  retryBudgetMs: number,
  fallbackDelayMs: number,
): Promise<boolean> {
  const requested = response === null
    ? null
    : providerRetryAfterMs(response, runtime.now());
  if (requested !== null && requested > retryBudgetMs) return false;
  const delayMs = requested ?? Math.min(fallbackDelayMs, retryBudgetMs);
  const sleep = runtime.sleep ??
    ((milliseconds: number) =>
      new Promise<void>((resolve) => {
        setTimeout(resolve, milliseconds);
      }));
  await sleep(delayMs);
  return true;
}

function modelOutputText(value: unknown): string {
  if (!isRecord(value)) throw new SafeDocumentError("invalid_extraction");
  if (
    Object.hasOwn(value, "status") && value.status !== "completed"
  ) {
    throw new SafeDocumentError("invalid_extraction");
  }
  if (typeof value.output_text === "string") {
    if (
      encoder.encode(value.output_text).byteLength >
        documentCandidateContract.maximumJsonBytes
    ) {
      throw new SafeDocumentError("invalid_extraction");
    }
    return value.output_text;
  }
  if (!Array.isArray(value.output)) {
    throw new SafeDocumentError("invalid_extraction");
  }
  for (const output of value.output) {
    if (!isRecord(output) || !Array.isArray(output.content)) continue;
    for (const content of output.content) {
      if (
        isRecord(content) && content.type === "output_text" &&
        typeof content.text === "string" &&
        encoder.encode(content.text).byteLength <=
          documentCandidateContract.maximumJsonBytes
      ) {
        return content.text;
      }
    }
  }
  throw new SafeDocumentError("invalid_extraction");
}

function bindTrustedDocumentIdentity(
  outputText: string,
  request: DocumentJsonModelRequest,
): string {
  let decoded: unknown;
  try {
    decoded = JSON.parse(outputText);
  } catch {
    throw new SafeDocumentError("invalid_extraction");
  }
  if (!isRecord(decoded)) {
    throw new SafeDocumentError("invalid_extraction");
  }
  const bound = JSON.stringify({
    ...decoded,
    source_id: request.input.sourceId,
    content_hash: request.input.contentHash,
  });
  if (
    encoder.encode(bound).byteLength >
      documentCandidateContract.maximumJsonBytes
  ) {
    throw new SafeDocumentError("invalid_extraction");
  }
  return bound;
}

function providerContent(
  request: DocumentJsonModelRequest,
): readonly unknown[] {
  const input = request.input;
  let material: Readonly<Record<string, unknown>>;
  if (input.mediaType === "text/plain") {
    const sanitizedTextBytes = encoder.encode(input.sanitizedText).byteLength;
    if (
      input.sanitizedText.length === 0 ||
      Array.from(input.sanitizedText).length >
        documentInputLimits.maximumTextCharacters ||
      sanitizedTextBytes > documentInputLimits.maximumFileBytes
    ) {
      throw new SafeDocumentError(
        input.sanitizedText.length === 0
          ? "unsafe_content"
          : "oversized_document",
      );
    }
    material = { type: "input_text", text: input.sanitizedText };
  } else {
    const dataUrl = `data:${input.mediaType};base64,${
      bytesToBase64(input.bytes)
    }`;
    material = input.mediaType === "image/png" ||
        input.mediaType === "image/jpeg"
      ? { type: "input_image", image_url: dataUrl, detail: "high" }
      : {
        type: "input_file",
        filename: "source.pdf",
        file_data: dataUrl,
      };
  }
  return Object.freeze([
    material,
    {
      type: "input_text",
      text: JSON.stringify({
        schema_version: "1.0",
        timezone: input.timezone,
        page_count: input.pageCount,
        task:
          "Extract schedule proposals from the attached inert class document.",
      }),
    },
  ]);
}

export class OpenAIDocumentJsonModelClient implements DocumentJsonModelClient {
  readonly isConfigured = true;
  readonly guaranteesJsonOnlyWithoutTools = true;
  readonly #configuration: DocumentProductionConfiguration;
  readonly #runtime: DocumentProductionRuntime;

  constructor(
    configuration: DocumentProductionConfiguration,
    runtime: DocumentProductionRuntime = defaultDocumentProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async generateJsonOnly(request: DocumentJsonModelRequest): Promise<string> {
    if (request.schemaVersion !== "1.0") {
      throw new SafeDocumentError("invalid_extraction");
    }
    const maximumAttempts = this.#configuration.providerMaximumAttempts;
    const retryBudgetMs = maximumAttempts === 1 ? 0 : Math.min(
      this.#configuration.providerRetryBaseDelayMs,
      Math.floor(this.#configuration.requestTimeoutMs / 4),
    );
    const perAttemptTimeoutMs = Math.max(
      250,
      Math.floor(
        (this.#configuration.requestTimeoutMs - retryBudgetMs) /
          maximumAttempts,
      ),
    );
    for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
      let response: Response;
      try {
        response = await this.#runtime.fetch(
          "https://api.openai.com/v1/responses",
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${this.#configuration.openAiApiKey}`,
              "content-type": "application/json",
              accept: "application/json",
            },
            body: JSON.stringify({
              model: this.#configuration.modelId,
              instructions: request.systemInstruction,
              input: [{ role: "user", content: providerContent(request) }],
              text: {
                format: {
                  type: "json_schema",
                  name: "schedule_candidate_batch_v1",
                  strict: true,
                  schema: documentCandidateBatchJsonSchema,
                },
              },
              max_output_tokens: 16_000,
              store: false,
            }),
            redirect: "error",
            signal: AbortSignal.timeout(perAttemptTimeoutMs),
          },
        );
      } catch (error) {
        const safe = error instanceof DOMException &&
            error.name === "TimeoutError"
          ? new SafeDocumentError("timeout")
          : new SafeDocumentError("network_unavailable");
        const category = providerErrorCategory(safe);
        if (
          attempt < maximumAttempts && retryBudgetMs >= 0 &&
          await providerRetryDelay(
            this.#runtime,
            null,
            retryBudgetMs,
            this.#configuration.providerRetryBaseDelayMs,
          )
        ) {
          recordProviderEvent(this.#runtime, this.#configuration, {
            attempt,
            outcome: "retry",
            httpStatus: null,
            errorCategory: category,
            inputTokens: null,
            outputTokens: null,
            totalTokens: null,
          });
          continue;
        }
        recordProviderEvent(this.#runtime, this.#configuration, {
          attempt,
          outcome: "failure",
          httpStatus: null,
          errorCategory: category,
          inputTokens: null,
          outputTokens: null,
          totalTokens: null,
        });
        throw safe;
      }
      if (!response.ok) {
        const safe = safeProviderError(response, this.#runtime.now());
        const category = providerErrorCategory(safe);
        await response.body?.cancel();
        if (
          attempt < maximumAttempts &&
          transientProviderErrors.has(category) &&
          await providerRetryDelay(
            this.#runtime,
            response,
            retryBudgetMs,
            this.#configuration.providerRetryBaseDelayMs,
          )
        ) {
          recordProviderEvent(this.#runtime, this.#configuration, {
            attempt,
            outcome: "retry",
            httpStatus: response.status,
            errorCategory: category,
            inputTokens: null,
            outputTokens: null,
            totalTokens: null,
          });
          continue;
        }
        recordProviderEvent(this.#runtime, this.#configuration, {
          attempt,
          outcome: "failure",
          httpStatus: response.status,
          errorCategory: category,
          inputTokens: null,
          outputTokens: null,
          totalTokens: null,
        });
        throw safe;
      }
      let usage: ReturnType<typeof providerTokenUsage> = {
        inputTokens: null,
        outputTokens: null,
        totalTokens: null,
      };
      try {
        const payload = await boundedJson(response);
        usage = providerTokenUsage(payload);
        const output = bindTrustedDocumentIdentity(
          modelOutputText(payload),
          request,
        );
        recordProviderEvent(this.#runtime, this.#configuration, {
          attempt,
          outcome: "success",
          httpStatus: response.status,
          errorCategory: null,
          ...usage,
        });
        return output;
      } catch (error) {
        const safe = error instanceof SafeDocumentError
          ? error
          : new SafeDocumentError("internal_error");
        recordProviderEvent(this.#runtime, this.#configuration, {
          attempt,
          outcome: "failure",
          httpStatus: response.status,
          errorCategory: providerErrorCategory(safe),
          ...usage,
        });
        throw safe;
      }
    }
    throw new SafeDocumentError("internal_error");
  }
}
