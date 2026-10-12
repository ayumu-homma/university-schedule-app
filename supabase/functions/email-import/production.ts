import {
  candidateContract,
  isStrictRfc3339Timestamp,
  isValidIanaTimezone,
  validateCandidateObject,
} from "./candidate_codec.ts";
import {
  type EmailJsonModelClient,
  type EmailJsonModelRequest,
} from "./extraction.ts";
import {
  type EmailConnectionStatus,
  emailErrorCategories,
  type EmailErrorCategory,
  type EmailProviderConnector,
  type EndpointFetchItem,
  type EndpointRetryOutcome,
  type EndpointSuppressionAck,
  gmailReadOnlyScope,
  type ProviderEmailMessage,
  type ProviderFetchPage,
  type ProviderFetchRequest,
  SafeEmailError,
  type SafePersistedEmailSource,
} from "./types.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const sha256Pattern = /^[0-9a-f]{64}$/;
const maximumJsonResponseBytes = 1_048_576;

export type SafeAuditAction =
  | "authenticate"
  | "oauth_start"
  | "oauth_callback"
  | "token_refresh"
  | "sync"
  | "retry_candidate"
  | "reconcile_confirmation"
  | "reconcile_dismissal"
  | "reconcile_update"
  | "disconnect"
  | "delete_account_data";

/** The only loggable production event. It cannot carry provider/user data. */
export interface SafeAuditEvent {
  readonly correlationId: string;
  readonly action: SafeAuditAction;
  readonly state: string;
  readonly category: EmailErrorCategory | null;
}

export interface ProductionRuntime {
  readonly fetch: (
    input: RequestInfo | URL,
    init?: RequestInit,
  ) => Promise<Response>;
  readonly now: () => Date;
  readonly randomBytes: (length: number) => Uint8Array;
  readonly randomUuid: () => string;
  readonly audit: (event: SafeAuditEvent) => void;
  readonly sleep: (delayMs: number) => Promise<void>;
  readonly jitter: (attempt: number, exponentialDelayMs: number) => number;
}

function secureRandomBytes(length: number): Uint8Array {
  const result = new Uint8Array(length);
  crypto.getRandomValues(result);
  return result;
}

export const defaultProductionRuntime: ProductionRuntime = Object.freeze({
  fetch: (input: RequestInfo | URL, init?: RequestInit) => fetch(input, init),
  now: () => new Date(),
  randomBytes: secureRandomBytes,
  randomUuid: () => crypto.randomUUID(),
  audit: (event: SafeAuditEvent) => console.info(JSON.stringify(event)),
  sleep: (delayMs: number) =>
    new Promise<void>((resolve) => setTimeout(resolve, delayMs)),
  jitter: (_attempt: number, exponentialDelayMs: number) =>
    Math.floor(Math.random() * (exponentialDelayMs + 1)),
});

export interface ProductionConfiguration {
  readonly supabaseUrl: URL;
  readonly serviceRoleKey: string;
  readonly gmailClientId: string;
  readonly gmailClientSecret: string;
  readonly gmailRedirectUri: URL;
  readonly appRedirectUri: URL;
  readonly tokenEncryptionKey: Uint8Array;
  readonly tokenEncryptionKeyVersion: number;
  readonly accountHashKey: Uint8Array;
  readonly modelId: string;
  readonly openAiApiKey: string;
  readonly timezone: string;
  readonly requestTimeoutMs: number;
}

function decodeBase64Secret(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new SafeEmailError("configuration_missing");
  }
}

function requiredEnvironment(
  readEnvironment: (name: string) => string | undefined,
  name: string,
): string {
  const value = readEnvironment(name);
  if (
    value === undefined || value.trim().length === 0 || value !== value.trim()
  ) {
    throw new SafeEmailError("configuration_missing");
  }
  return value;
}

function requiredHttpsUrl(value: string): URL {
  try {
    const result = new URL(value);
    if (
      result.protocol !== "https:" || result.username.length > 0 ||
      result.password.length > 0 || result.hash.length > 0
    ) {
      throw new Error("unsafe URL");
    }
    return result;
  } catch {
    throw new SafeEmailError("configuration_missing");
  }
}

function requiredSupabaseUrl(value: string): URL {
  let result: URL;
  try {
    result = new URL(value);
  } catch {
    throw new SafeEmailError("configuration_missing");
  }
  if (result.protocol === "https:") return requiredHttpsUrl(value);
  if (
    result.protocol === "http:" &&
    ["api-gw", "kong"].includes(result.hostname) &&
    result.port === "8000" && result.username.length === 0 &&
    result.password.length === 0 && result.pathname === "/" &&
    result.search.length === 0 && result.hash.length === 0
  ) return result;
  throw new SafeEmailError("configuration_missing");
}

function requiredAppRedirect(value: string): URL {
  try {
    const result = new URL(value);
    if (
      value !== "unischedule://email-import-callback" ||
      result.protocol !== "unischedule:" ||
      result.hostname !== "email-import-callback" ||
      result.username.length > 0 || result.password.length > 0 ||
      result.port.length > 0 || result.pathname.length > 0 ||
      result.search.length > 0 || result.hash.length > 0
    ) {
      throw new Error("unsafe redirect");
    }
    return result;
  } catch {
    throw new SafeEmailError("configuration_missing");
  }
}

export function parseProductionConfiguration(
  readEnvironment: (name: string) => string | undefined,
): ProductionConfiguration {
  const encryptionKey = decodeBase64Secret(
    requiredEnvironment(readEnvironment, "EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY"),
  );
  const accountHashKey = decodeBase64Secret(
    requiredEnvironment(readEnvironment, "EMAIL_IMPORT_ACCOUNT_HASH_KEY"),
  );
  const keyVersion = Number(
    requiredEnvironment(
      readEnvironment,
      "EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY_VERSION",
    ),
  );
  if (
    encryptionKey.length !== 32 || accountHashKey.length < 32 ||
    !Number.isInteger(keyVersion) || keyVersion < 1
  ) {
    throw new SafeEmailError("configuration_missing");
  }
  const timezone = readEnvironment("EMAIL_IMPORT_DEFAULT_TIMEZONE")?.trim() ||
    "Asia/Tokyo";
  if (!isValidIanaTimezone(timezone)) {
    throw new SafeEmailError("configuration_missing");
  }
  return Object.freeze({
    supabaseUrl: requiredSupabaseUrl(
      requiredEnvironment(readEnvironment, "SUPABASE_URL"),
    ),
    serviceRoleKey: requiredEnvironment(
      readEnvironment,
      "SUPABASE_SERVICE_ROLE_KEY",
    ),
    gmailClientId: requiredEnvironment(
      readEnvironment,
      "GMAIL_OAUTH_CLIENT_ID",
    ),
    gmailClientSecret: requiredEnvironment(
      readEnvironment,
      "GMAIL_OAUTH_CLIENT_SECRET",
    ),
    gmailRedirectUri: requiredHttpsUrl(
      requiredEnvironment(readEnvironment, "GMAIL_OAUTH_REDIRECT_URI"),
    ),
    appRedirectUri: requiredAppRedirect(
      requiredEnvironment(readEnvironment, "EMAIL_IMPORT_APP_REDIRECT_URI"),
    ),
    tokenEncryptionKey: encryptionKey,
    tokenEncryptionKeyVersion: keyVersion,
    accountHashKey,
    modelId: requiredEnvironment(readEnvironment, "EMAIL_IMPORT_MODEL_ID"),
    openAiApiKey: requiredEnvironment(readEnvironment, "OPENAI_API_KEY"),
    timezone,
    requestTimeoutMs: 10_000,
  });
}

export function isUuid(value: string): boolean {
  return uuidPattern.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredString(
  value: unknown,
  maximumCharacters: number,
): string {
  if (
    typeof value !== "string" || value.length === 0 || value.trim() !== value ||
    Array.from(value).length > maximumCharacters ||
    Array.from(value).some((character) => {
      const code = character.codePointAt(0) ?? 0;
      return code < 0x20 || code === 0x7f;
    })
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return value;
}

function optionalString(
  value: unknown,
  maximumCharacters: number,
): string | null {
  return value === null || value === undefined
    ? null
    : requiredString(value, maximumCharacters);
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/g,
    "",
  );
}

function hexEncode(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

function byteaParameter(bytes: Uint8Array): string {
  return `\\x${hexEncode(bytes)}`;
}

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
}

export async function sha256Hex(value: string): Promise<string> {
  return hexEncode(await sha256(value));
}

export async function providerMessageIdentifierHash(
  providerAccountHash: string,
  providerMessageId: string,
): Promise<string> {
  if (
    !sha256Pattern.test(providerAccountHash) ||
    providerMessageId.length < 1 ||
    Array.from(providerMessageId).length > 1_024 ||
    providerMessageId.trim() !== providerMessageId ||
    /\s/.test(providerMessageId) ||
    Array.from(providerMessageId).some((character) => {
      const code = character.codePointAt(0) ?? 0;
      return code < 0x20 || code === 0x7f;
    })
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return await sha256Hex(
    `university-schedule-email-import-v1\u0000message\u0000gmail\u0000${providerAccountHash}\u0000${providerMessageId}`,
  );
}

export async function keyedAccountHash(
  address: string,
  secret: Uint8Array,
): Promise<string> {
  const canonical = address.trim().toLowerCase();
  if (
    canonical.length === 0 || canonical.length > 320 ||
    !canonical.includes("@") || Array.from(canonical).some((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      return codePoint < 0x20 || codePoint === 0x7f;
    })
  ) {
    throw new SafeEmailError("malformed_content");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`gmail-account:v1\u0000${canonical}`),
  );
  return hexEncode(new Uint8Array(digest));
}

export class AesGcmVault {
  readonly #rawKey: Uint8Array;
  readonly #randomBytes: (length: number) => Uint8Array;

  constructor(
    rawKey: Uint8Array,
    randomBytes: (length: number) => Uint8Array,
  ) {
    if (rawKey.length !== 32) throw new SafeEmailError("configuration_missing");
    this.#rawKey = rawKey.slice();
    this.#randomBytes = randomBytes;
  }

  async seal(
    value: Readonly<Record<string, unknown>>,
    aad: string,
  ): Promise<Uint8Array> {
    const nonce = Uint8Array.from(this.#randomBytes(12));
    if (nonce.length !== 12) throw new SafeEmailError("internal_error");
    const key = await crypto.subtle.importKey(
      "raw",
      Uint8Array.from(this.#rawKey),
      "AES-GCM",
      false,
      ["encrypt"],
    );
    const plaintext = encoder.encode(JSON.stringify(value));
    if (plaintext.length > 32_768) {
      throw new SafeEmailError("oversized_content");
    }
    const ciphertext = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: nonce, additionalData: encoder.encode(aad) },
        key,
        plaintext,
      ),
    );
    const sealed = new Uint8Array(1 + nonce.length + ciphertext.length);
    sealed[0] = 1;
    sealed.set(nonce, 1);
    sealed.set(ciphertext, 13);
    return sealed;
  }

  async open(
    sealed: Uint8Array,
    aad: string,
  ): Promise<Record<string, unknown>> {
    if (sealed.length < 30 || sealed.length > 65_536 || sealed[0] !== 1) {
      throw new SafeEmailError("authorization_revoked");
    }
    try {
      const key = await crypto.subtle.importKey(
        "raw",
        Uint8Array.from(this.#rawKey),
        "AES-GCM",
        false,
        ["decrypt"],
      );
      const plaintext = await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: Uint8Array.from(sealed.slice(1, 13)),
          additionalData: encoder.encode(aad),
        },
        key,
        Uint8Array.from(sealed.slice(13)),
      );
      const decoded: unknown = JSON.parse(decoder.decode(plaintext));
      if (!isRecord(decoded)) throw new Error("invalid vault payload");
      return decoded;
    } catch (error) {
      if (error instanceof SafeEmailError) throw error;
      throw new SafeEmailError("authorization_revoked");
    }
  }
}

function bytesFromBase64(value: unknown): Uint8Array {
  const text = requiredString(value, 100_000);
  try {
    const binary = atob(text);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new SafeEmailError("provider_unavailable");
  }
}

async function boundedJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (encoder.encode(text).length > maximumJsonResponseBytes) {
    throw new SafeEmailError("provider_unavailable");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new SafeEmailError("provider_unavailable");
  }
}

async function boundedProviderMessageJson(
  response: Response,
): Promise<unknown> {
  const text = await response.text();
  if (encoder.encode(text).length > maximumJsonResponseBytes) {
    throw new SafeEmailError("oversized_content");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new SafeEmailError("malformed_content");
  }
}

export interface AuthenticatedCaller {
  readonly ownerUserId: string;
}

export interface JwtAuthenticator {
  authenticate(request: Request): Promise<AuthenticatedCaller>;
}

export class SupabaseJwtAuthenticator implements JwtAuthenticator {
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;

  constructor(
    configuration: ProductionConfiguration,
    runtime: ProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async authenticate(request: Request): Promise<AuthenticatedCaller> {
    const authorization = request.headers.get("authorization");
    if (
      authorization === null ||
      !/^Bearer [A-Za-z0-9._~-]+$/.test(authorization) ||
      authorization.length > 8_192
    ) {
      throw new SafeEmailError("authorization_revoked");
    }
    const endpoint = new URL("auth/v1/user", this.#configuration.supabaseUrl);
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "GET",
        headers: {
          authorization,
          apikey: this.#configuration.serviceRoleKey,
          accept: "application/json",
        },
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch {
      throw new SafeEmailError("authorization_revoked");
    }
    if (!response.ok) throw new SafeEmailError("authorization_revoked");
    const body = await boundedJson(response);
    if (!isRecord(body) || typeof body.id !== "string" || !isUuid(body.id)) {
      throw new SafeEmailError("authorization_revoked");
    }
    return Object.freeze({ ownerUserId: body.id });
  }
}

export interface OAuthStateRecord {
  readonly ownerUserId: string;
  readonly connectionId: string;
  readonly encryptedPkceVerifier: Uint8Array;
  readonly encryptionKeyVersion: number;
  readonly expiresAt: string;
  readonly correlationId: string;
}

export interface StoredCredentials {
  readonly connectionId: string;
  readonly providerAccountHash: string;
  readonly connectionState: EmailConnectionStatus;
  readonly syncCursor: string | null;
  readonly connectedAt: string | null;
  readonly encryptedOauthBundle: Uint8Array;
  readonly encryptionKeyVersion: number;
  readonly credentialVersion: number;
  readonly expiresAt: string | null;
}

export interface PersistedConnection {
  readonly connectionId: string;
  readonly connectionState: EmailConnectionStatus;
  readonly syncCursor: string | null;
  readonly connectedAt: string | null;
  readonly lastSyncedAt?: string | null;
  readonly credentialVersion?: number;
}

export interface PersistedSyncReplay {
  readonly items: readonly EndpointFetchItem[];
  readonly suppressions: readonly EndpointSuppressionAck[];
  readonly nextCursor: string | null;
  readonly hasMore: boolean;
  readonly connectedAt: string | null;
}

export interface PersistedSyncPageResult {
  readonly connection: PersistedConnection;
  readonly page: PersistedSyncReplay;
}

export interface PersistedRetryReplay {
  readonly retryOutcome: EndpointRetryOutcome;
  readonly item: EndpointFetchItem | null;
  readonly suppression: EndpointSuppressionAck | null;
  readonly connectedAt: string | null;
}

export interface PersistedRetryResult {
  readonly connection: PersistedConnection;
  readonly retryOutcome: EndpointRetryOutcome;
  readonly item: EndpointFetchItem | null;
  readonly suppression: EndpointSuppressionAck | null;
}

export interface PersistedAuthorizationResolution {
  readonly requestedConnectionId: string;
  readonly effectiveConnectionId: string;
  readonly connectionState: EmailConnectionStatus;
  readonly errorCategory: EmailErrorCategory | null;
  readonly retryAfterAt: string | null;
  readonly connectedAt: string | null;
}

export interface PersistedReconciliation {
  readonly connectionId: string;
  readonly connectionState: EmailConnectionStatus;
  readonly action: "confirmation" | "dismissal" | "update";
  readonly outcome: "confirmed" | "dismissed" | "accepted" | "rejected";
  readonly entityType: "assignment" | "exam" | "event" | null;
  readonly entityId: string | null;
  readonly replayed: boolean;
}

export interface ReconciliationIdentity {
  readonly ownerUserId: string;
  readonly connectionId: string;
  readonly provider: "gmail";
  readonly providerAccountHash: string;
  readonly providerMessageIdHash: string;
  readonly providerThreadIdHash: string;
  readonly sanitizedContentHash: string;
  readonly idempotencyKey: string;
  readonly reconciledAt: string;
  readonly correlationId: string;
}

export interface TrustedEmailStore {
  beginOauth(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly stateHash: string;
    readonly encryptedPkceVerifier: Uint8Array;
    readonly encryptionKeyVersion: number;
    readonly expiresAt: string;
    readonly correlationId: string;
  }): Promise<void>;
  takeOauth(
    stateHash: string,
    consumedAt: string,
  ): Promise<OAuthStateRecord | null>;
  completeOauth(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly providerAccountHash: string;
    readonly authorizedScopes: readonly string[];
    readonly encryptedOauthBundle: Uint8Array;
    readonly encryptionKeyVersion: number;
    readonly expiresAt: string;
    readonly initialSyncCursor: string | null;
    readonly connectedAt: string;
    readonly correlationId: string;
  }): Promise<PersistedConnection>;
  checkAuthorization(input: {
    readonly ownerUserId: string;
    readonly requestedConnectionId: string;
    readonly callbackCorrelationId: string;
  }): Promise<PersistedAuthorizationResolution | null>;
  getCredentials(
    ownerUserId: string,
    connectionId: string,
  ): Promise<StoredCredentials | null>;
  rotateCredentials(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly expectedCredentialVersion: number;
    readonly encryptedOauthBundle: Uint8Array;
    readonly encryptionKeyVersion: number;
    readonly expiresAt: string;
    readonly rotatedAt: string;
    readonly correlationId: string;
  }): Promise<number>;
  persistSyncPage(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly expectedCursor: string | null;
    readonly nextCursor: string | null;
    readonly sources: readonly Readonly<Record<string, unknown>>[];
    readonly candidates: readonly Readonly<Record<string, unknown>>[];
    readonly hasMore: boolean;
    readonly syncedAt: string;
    readonly correlationId: string;
  }): Promise<PersistedSyncPageResult>;
  getSyncReplay(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly expectedCursor: string | null;
  }): Promise<PersistedSyncReplay | null>;
  getOwnerTimezone(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
  }): Promise<string | null>;
  getRetryReplay(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly providerMessageId: string;
    readonly expectedSanitizedContentHash: string;
    readonly retryIdempotencyKey: string;
  }): Promise<PersistedRetryReplay | null>;
  assertRetryCandidate(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly providerMessageId: string;
    readonly expectedSanitizedContentHash: string;
  }): Promise<void>;
  persistRetryCandidate(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly sources: readonly Readonly<Record<string, unknown>>[];
    readonly candidates: readonly Readonly<Record<string, unknown>>[];
    readonly expectedSanitizedContentHash: string;
    readonly retryIdempotencyKey: string;
    readonly retriedAt: string;
    readonly correlationId: string;
  }): Promise<PersistedRetryResult>;
  reconcileConfirmation(
    input: ReconciliationIdentity & {
      readonly reviewedPayload: Readonly<Record<string, unknown>>;
      readonly entityType: "assignment" | "exam" | "event";
      readonly entityId: string;
    },
  ): Promise<PersistedReconciliation>;
  reconcileDismissal(
    input: ReconciliationIdentity,
  ): Promise<PersistedReconciliation>;
  reconcileUpdate(
    input: ReconciliationIdentity & {
      readonly resolution: "accepted" | "rejected";
      readonly entityType: "assignment" | "exam" | "event";
      readonly entityId: string;
    },
  ): Promise<PersistedReconciliation>;
  finalizeDisconnect(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly deleteDerivedData: boolean;
    readonly revocationAttempted: boolean;
    readonly revocationSucceeded: boolean;
    readonly disconnectedAt: string;
    readonly correlationId: string;
  }): Promise<PersistedConnection>;
  listOwnedConnectionIds(ownerUserId: string): Promise<readonly string[]>;
  deleteAccountData(input: {
    readonly ownerUserId: string;
    readonly deletedAt: string;
    readonly correlationId: string;
  }): Promise<Readonly<Record<string, number>>>;
  recordFailure(input: {
    readonly ownerUserId: string;
    readonly connectionId: string;
    readonly operation: "connect" | "oauth_callback" | "refresh" | "fetch";
    readonly connectionState: EmailConnectionStatus;
    readonly errorCategory: EmailErrorCategory;
    readonly retryAfterAt: string | null;
    readonly occurredAt: string;
    readonly correlationId: string;
  }): Promise<PersistedConnection | null>;
}

function connectionStatus(value: unknown): EmailConnectionStatus {
  const status = requiredString(value, 32);
  if (
    ![
      "disconnected",
      "connecting",
      "connected",
      "reauth_required",
      "rate_limited",
      "failed",
      "disconnecting",
    ].includes(status)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return status as EmailConnectionStatus;
}

function positiveInteger(value: unknown): number {
  if (
    typeof value !== "number" || !Number.isSafeInteger(value) || value < 1
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return value;
}

function persistedConnection(value: unknown): PersistedConnection {
  if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
  const connectionId = requiredString(value.connection_id, 64);
  if (!isUuid(connectionId)) throw new SafeEmailError("provider_unavailable");
  return Object.freeze({
    connectionId,
    connectionState: connectionStatus(value.connection_state),
    syncCursor: optionalString(value.sync_cursor, 4_096),
    connectedAt: optionalString(value.connected_at, 64),
    lastSyncedAt: optionalString(value.last_synced_at, 64),
    credentialVersion: value.credential_version === undefined
      ? undefined
      : positiveInteger(value.credential_version),
  });
}

function persistedFetchItem(value: unknown): EndpointFetchItem {
  if (
    !isRecord(value) || Object.keys(value).length !== 7 ||
    ![
      "providerMessageId",
      "providerThreadId",
      "receivedAt",
      "sanitizedContentHash",
      "evidenceExcerpts",
      "candidate",
      "errorCategory",
    ].every((key) => Object.hasOwn(value, key))
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  const providerMessageId = requiredString(value.providerMessageId, 1_024);
  const providerThreadId = optionalString(value.providerThreadId, 1_024);
  const receivedAt = requiredString(value.receivedAt, 64);
  const sanitizedContentHash = requiredString(
    value.sanitizedContentHash,
    64,
  );
  const errorCategory = optionalString(value.errorCategory, 64);
  if (
    /\s/.test(providerMessageId) ||
    (providerThreadId !== null && /\s/.test(providerThreadId)) ||
    !isStrictRfc3339Timestamp(receivedAt) ||
    !sha256Pattern.test(sanitizedContentHash) ||
    (errorCategory !== null && !emailErrorCategories.includes(
      errorCategory as EmailErrorCategory,
    )) ||
    !Array.isArray(value.evidenceExcerpts) ||
    value.evidenceExcerpts.length > 8 ||
    value.evidenceExcerpts.some((entry) =>
      typeof entry !== "string" || entry.length < 1 || entry.length > 512 ||
      entry.trim() !== entry || Array.from(entry).some((character) => {
        const code = character.codePointAt(0) ?? 0;
        return code <= 0x08 || code === 0x0b || code === 0x0c ||
          (code >= 0x0e && code <= 0x1f) || code === 0x7f;
      })
    )
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  let candidate: Readonly<Record<string, unknown>> | null = null;
  if (value.candidate !== null) {
    candidate = validateCandidateObject(value.candidate);
  }
  if (
    (candidate === null) === (errorCategory === null) ||
    (candidate !== null && providerThreadId === null) ||
    (errorCategory !== null && value.evidenceExcerpts.length !== 0)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    providerMessageId,
    providerThreadId,
    receivedAt,
    sanitizedContentHash,
    evidenceExcerpts: Object.freeze([...(value.evidenceExcerpts as string[])]),
    candidate,
    errorCategory: errorCategory as EmailErrorCategory | null,
  });
}

function persistedSuppressionAck(value: unknown): EndpointSuppressionAck {
  if (
    !isRecord(value) || Object.keys(value).length !== 2 ||
    !Object.hasOwn(value, "providerMessageIdHash") ||
    !Object.hasOwn(value, "reason")
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  if (
    typeof value.providerMessageIdHash !== "string" ||
    !sha256Pattern.test(value.providerMessageIdHash) ||
    (value.reason !== "dismissed" && value.reason !== "deduplicated")
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    providerMessageIdHash: value.providerMessageIdHash,
    reason: value.reason,
  });
}

function persistedSyncReplay(value: unknown): PersistedSyncReplay {
  if (
    !isRecord(value) || Object.keys(value).length !== 5 ||
    !["items", "suppressions", "next_cursor", "has_more", "connected_at"].every(
      (key) => Object.hasOwn(value, key),
    ) || !Array.isArray(value.items) || !Array.isArray(value.suppressions) ||
    value.items.length + value.suppressions.length > 100 ||
    typeof value.has_more !== "boolean"
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  const nextCursor = optionalString(value.next_cursor, 4_096);
  if (value.has_more && nextCursor === null) {
    throw new SafeEmailError("provider_unavailable");
  }
  const items = value.items.map(persistedFetchItem);
  const suppressions = value.suppressions.map(persistedSuppressionAck);
  const itemIds = new Set(items.map((item) => item.providerMessageId));
  const suppressionIds = new Set(
    suppressions.map((ack) => ack.providerMessageIdHash),
  );
  if (
    itemIds.size !== items.length ||
    suppressionIds.size !== suppressions.length
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    items: Object.freeze(items),
    suppressions: Object.freeze(suppressions),
    nextCursor,
    hasMore: value.has_more,
    connectedAt: optionalString(value.connected_at, 64),
  });
}

function persistedRetryReplay(value: unknown): PersistedRetryReplay {
  if (
    !isRecord(value) || Object.keys(value).length !== 4 ||
    !Object.hasOwn(value, "retry_outcome") ||
    !Object.hasOwn(value, "item") ||
    !Object.hasOwn(value, "suppression") ||
    !Object.hasOwn(value, "connected_at") ||
    (value.retry_outcome !== "persisted" &&
      value.retry_outcome !== "suppressed") ||
    (value.retry_outcome === "persisted") !== (value.item !== null) ||
    (value.retry_outcome === "suppressed") !== (value.suppression !== null)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    retryOutcome: value.retry_outcome,
    item: value.item === null ? null : persistedFetchItem(value.item),
    suppression: value.suppression === null
      ? null
      : persistedSuppressionAck(value.suppression),
    connectedAt: optionalString(value.connected_at, 64),
  });
}

function persistedRetryResult(value: unknown): PersistedRetryResult {
  if (
    !isRecord(value) || Object.keys(value).length !== 4 ||
    !Object.hasOwn(value, "connection") ||
    !Object.hasOwn(value, "retry_outcome") ||
    !Object.hasOwn(value, "item") ||
    !Object.hasOwn(value, "suppression") ||
    (value.retry_outcome !== "persisted" &&
      value.retry_outcome !== "suppressed") ||
    (value.retry_outcome === "persisted") !== (value.item !== null) ||
    (value.retry_outcome === "suppressed") !== (value.suppression !== null)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    connection: persistedConnection(value.connection),
    retryOutcome: value.retry_outcome,
    item: value.item === null ? null : persistedFetchItem(value.item),
    suppression: value.suppression === null
      ? null
      : persistedSuppressionAck(value.suppression),
  });
}

function persistedSyncPageResult(value: unknown): PersistedSyncPageResult {
  if (
    !isRecord(value) || Object.keys(value).length !== 2 ||
    !Object.hasOwn(value, "connection") || !Object.hasOwn(value, "page")
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    connection: persistedConnection(value.connection),
    page: persistedSyncReplay(value.page),
  });
}

function persistedAuthorizationResolution(
  value: unknown,
): PersistedAuthorizationResolution {
  if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
  const requestedConnectionId = requiredString(
    value.requested_connection_id,
    64,
  );
  const effectiveConnectionId = requiredString(
    value.effective_connection_id,
    64,
  );
  const state = connectionStatus(value.connection_state);
  const errorCategory = optionalString(value.last_error_category, 64);
  const retryAfterAt = optionalString(value.retry_after_at, 64);
  if (
    !isUuid(requestedConnectionId) || !isUuid(effectiveConnectionId) ||
    (state === "failed") !== (errorCategory !== null) ||
    (errorCategory !== null && !emailErrorCategories.includes(
      errorCategory as EmailErrorCategory,
    )) ||
    (state === "rate_limited") !== (retryAfterAt !== null)
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    requestedConnectionId,
    effectiveConnectionId,
    connectionState: state,
    errorCategory: errorCategory as EmailErrorCategory | null,
    retryAfterAt,
    connectedAt: optionalString(value.connected_at, 64),
  });
}

function persistedReconciliation(value: unknown): PersistedReconciliation {
  if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
  const connectionId = requiredString(value.connection_id, 64);
  const action = requiredString(value.action, 32);
  const outcome = requiredString(value.outcome, 32);
  const entityType = optionalString(value.entity_type, 32);
  const entityId = optionalString(value.entity_id, 64);
  if (
    !isUuid(connectionId) ||
    !["confirmation", "dismissal", "update"].includes(action) ||
    !["confirmed", "dismissed", "accepted", "rejected"].includes(outcome) ||
    (entityType !== null &&
      !["assignment", "exam", "event"].includes(entityType)) ||
    (entityId !== null && !isUuid(entityId)) ||
    typeof value.replayed !== "boolean" ||
    (action === "confirmation" && outcome !== "confirmed") ||
    (action === "dismissal" && outcome !== "dismissed") ||
    (action === "update" && outcome !== "accepted" &&
      outcome !== "rejected") ||
    (action === "dismissal" && (entityType !== null || entityId !== null)) ||
    (action !== "dismissal" && (entityType === null || entityId === null))
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  return Object.freeze({
    connectionId,
    connectionState: connectionStatus(value.connection_state),
    action: action as PersistedReconciliation["action"],
    outcome: outcome as PersistedReconciliation["outcome"],
    entityType: entityType as PersistedReconciliation["entityType"],
    entityId,
    replayed: value.replayed,
  });
}

export class PostgrestTrustedEmailStore implements TrustedEmailStore {
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;

  constructor(
    configuration: ProductionConfiguration,
    runtime: ProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async #rpc(
    name: string,
    parameters: Readonly<Record<string, unknown>>,
  ): Promise<unknown> {
    const endpoint = new URL(
      `rest/v1/rpc/${name}`,
      this.#configuration.supabaseUrl,
    );
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.#configuration.serviceRoleKey}`,
          apikey: this.#configuration.serviceRoleKey,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify(parameters),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch {
      throw new SafeEmailError("provider_unavailable");
    }
    if (!response.ok) throw new SafeEmailError("provider_unavailable");
    return boundedJson(response);
  }

  async listOwnedConnectionIds(
    ownerUserId: string,
  ): Promise<readonly string[]> {
    if (!isUuid(ownerUserId)) throw new SafeEmailError("provider_unavailable");
    const connectionIds: string[] = [];
    const seen = new Set<string>();
    let afterConnectionId: string | null = null;
    for (;;) {
      const endpoint = new URL(
        "rest/v1/email_connections",
        this.#configuration.supabaseUrl,
      );
      endpoint.searchParams.set("select", "id");
      endpoint.searchParams.set("owner_user_id", `eq.${ownerUserId}`);
      endpoint.searchParams.set("provider", "eq.gmail");
      endpoint.searchParams.set("order", "id.asc");
      endpoint.searchParams.set("limit", "100");
      if (afterConnectionId !== null) {
        endpoint.searchParams.set("id", `gt.${afterConnectionId}`);
      }
      let response: Response;
      try {
        response = await this.#runtime.fetch(endpoint, {
          method: "GET",
          headers: {
            authorization: `Bearer ${this.#configuration.serviceRoleKey}`,
            apikey: this.#configuration.serviceRoleKey,
            accept: "application/json",
          },
          signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
        });
      } catch {
        throw new SafeEmailError("provider_unavailable");
      }
      if (!response.ok) throw new SafeEmailError("provider_unavailable");
      const value = await boundedJson(response);
      if (!Array.isArray(value) || value.length > 100) {
        throw new SafeEmailError("provider_unavailable");
      }
      for (const row of value) {
        if (
          !isRecord(row) || Object.keys(row).length !== 1 ||
          !Object.hasOwn(row, "id")
        ) {
          throw new SafeEmailError("provider_unavailable");
        }
        const id = requiredString(row.id, 64);
        if (!isUuid(id) || seen.has(id)) {
          throw new SafeEmailError("provider_unavailable");
        }
        seen.add(id);
        connectionIds.push(id);
      }
      if (value.length < 100) break;
      afterConnectionId = connectionIds.at(-1) ?? null;
      if (afterConnectionId === null) {
        throw new SafeEmailError("provider_unavailable");
      }
    }
    return Object.freeze(connectionIds);
  }

  async beginOauth(
    input: Parameters<TrustedEmailStore["beginOauth"]>[0],
  ): Promise<void> {
    await this.#rpc("email_import_begin_oauth", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_state_hash: input.stateHash,
      p_encrypted_pkce_verifier: byteaParameter(input.encryptedPkceVerifier),
      p_encryption_key_version: input.encryptionKeyVersion,
      p_expires_at: input.expiresAt,
      p_correlation_id: input.correlationId,
    });
  }

  async takeOauth(
    stateHash: string,
    consumedAt: string,
  ): Promise<OAuthStateRecord | null> {
    const value = await this.#rpc("email_import_take_oauth", {
      p_state_hash: stateHash,
      p_consumed_at: consumedAt,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    const ownerUserId = requiredString(value.owner_user_id, 64);
    const connectionId = requiredString(value.connection_id, 64);
    const correlationId = requiredString(value.correlation_id, 64);
    if (
      !isUuid(ownerUserId) || !isUuid(connectionId) || !isUuid(correlationId)
    ) {
      throw new SafeEmailError("provider_unavailable");
    }
    return Object.freeze({
      ownerUserId,
      connectionId,
      encryptedPkceVerifier: bytesFromBase64(
        value.encrypted_pkce_verifier_base64,
      ),
      encryptionKeyVersion: positiveInteger(value.encryption_key_version),
      expiresAt: requiredString(value.expires_at, 64),
      correlationId,
    });
  }

  async completeOauth(
    input: Parameters<TrustedEmailStore["completeOauth"]>[0],
  ): Promise<PersistedConnection> {
    return persistedConnection(
      await this.#rpc("email_import_complete_oauth", {
        p_owner_user_id: input.ownerUserId,
        p_connection_id: input.connectionId,
        p_provider_account_hash: input.providerAccountHash,
        p_authorized_scopes: input.authorizedScopes,
        p_encrypted_oauth_bundle: byteaParameter(input.encryptedOauthBundle),
        p_encryption_key_version: input.encryptionKeyVersion,
        p_expires_at: input.expiresAt,
        p_initial_sync_cursor: input.initialSyncCursor,
        p_connected_at: input.connectedAt,
        p_correlation_id: input.correlationId,
      }),
    );
  }

  async checkAuthorization(
    input: Parameters<TrustedEmailStore["checkAuthorization"]>[0],
  ): Promise<PersistedAuthorizationResolution | null> {
    const value = await this.#rpc("email_import_check_authorization", {
      p_owner_user_id: input.ownerUserId,
      p_requested_connection_id: input.requestedConnectionId,
      p_correlation_id: input.callbackCorrelationId,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    return persistedAuthorizationResolution(value);
  }

  async getCredentials(
    ownerUserId: string,
    connectionId: string,
  ): Promise<StoredCredentials | null> {
    const value = await this.#rpc("email_import_get_credentials", {
      p_owner_user_id: ownerUserId,
      p_connection_id: connectionId,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    const returnedConnectionId = requiredString(value.connection_id, 64);
    const accountHash = requiredString(value.provider_account_hash, 64);
    if (
      returnedConnectionId !== connectionId || !sha256Pattern.test(accountHash)
    ) {
      throw new SafeEmailError("provider_unavailable");
    }
    if (value.provider !== "gmail") {
      throw new SafeEmailError("provider_unavailable");
    }
    return Object.freeze({
      connectionId,
      providerAccountHash: accountHash,
      connectionState: connectionStatus(value.connection_state),
      syncCursor: optionalString(value.sync_cursor, 4_096),
      connectedAt: optionalString(value.connected_at, 64),
      encryptedOauthBundle: bytesFromBase64(
        value.encrypted_oauth_bundle_base64,
      ),
      encryptionKeyVersion: positiveInteger(value.encryption_key_version),
      credentialVersion: positiveInteger(value.credential_version),
      expiresAt: optionalString(value.expires_at, 64),
    });
  }

  async rotateCredentials(
    input: Parameters<TrustedEmailStore["rotateCredentials"]>[0],
  ): Promise<number> {
    const value = await this.#rpc("email_import_rotate_credentials", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_expected_credential_version: input.expectedCredentialVersion,
      p_encrypted_oauth_bundle: byteaParameter(input.encryptedOauthBundle),
      p_encryption_key_version: input.encryptionKeyVersion,
      p_expires_at: input.expiresAt,
      p_rotated_at: input.rotatedAt,
      p_correlation_id: input.correlationId,
    });
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    return positiveInteger(value.credential_version);
  }

  async persistSyncPage(
    input: Parameters<TrustedEmailStore["persistSyncPage"]>[0],
  ): Promise<PersistedSyncPageResult> {
    return persistedSyncPageResult(
      await this.#rpc(
        "email_import_persist_sync_page",
        {
          p_owner_user_id: input.ownerUserId,
          p_connection_id: input.connectionId,
          p_expected_cursor: input.expectedCursor,
          p_next_cursor: input.nextCursor,
          p_sources: input.sources,
          p_candidates: input.candidates,
          p_has_more: input.hasMore,
          p_synced_at: input.syncedAt,
          p_correlation_id: input.correlationId,
        },
      ),
    );
  }

  async getSyncReplay(
    input: Parameters<TrustedEmailStore["getSyncReplay"]>[0],
  ): Promise<PersistedSyncReplay | null> {
    const value = await this.#rpc("email_import_get_sync_replay", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_expected_cursor: input.expectedCursor,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    return persistedSyncReplay(value);
  }

  async getOwnerTimezone(
    input: Parameters<TrustedEmailStore["getOwnerTimezone"]>[0],
  ): Promise<string | null> {
    const value = await this.#rpc("email_import_get_owner_timezone", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
    });
    if (value === null) return null;
    if (
      typeof value !== "string" || value.length > 64 ||
      !isValidIanaTimezone(value)
    ) {
      throw new SafeEmailError("provider_unavailable");
    }
    return value;
  }

  async getRetryReplay(
    input: Parameters<TrustedEmailStore["getRetryReplay"]>[0],
  ): Promise<PersistedRetryReplay | null> {
    const value = await this.#rpc("email_import_get_retry_replay", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_provider_message_id: input.providerMessageId,
      p_expected_content_hash: input.expectedSanitizedContentHash,
      p_idempotency_key: input.retryIdempotencyKey,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    const replay = persistedRetryReplay(value);
    if (
      replay.item !== null &&
      replay.item.providerMessageId !== input.providerMessageId
    ) {
      throw new SafeEmailError("provider_unavailable");
    }
    return replay;
  }

  async assertRetryCandidate(
    input: Parameters<TrustedEmailStore["assertRetryCandidate"]>[0],
  ): Promise<void> {
    const value = await this.#rpc("email_import_assert_retry_candidate", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_provider_message_id: input.providerMessageId,
      p_expected_content_hash: input.expectedSanitizedContentHash,
    });
    if (value !== true) throw new SafeEmailError("provider_unavailable");
  }

  async persistRetryCandidate(
    input: Parameters<TrustedEmailStore["persistRetryCandidate"]>[0],
  ): Promise<PersistedRetryResult> {
    const result = persistedRetryResult(
      await this.#rpc("email_import_persist_retry_candidate", {
        p_owner_user_id: input.ownerUserId,
        p_connection_id: input.connectionId,
        p_sources: input.sources,
        p_candidates: input.candidates,
        p_expected_content_hash: input.expectedSanitizedContentHash,
        p_idempotency_key: input.retryIdempotencyKey,
        p_retried_at: input.retriedAt,
        p_correlation_id: input.correlationId,
      }),
    );
    const requestedMessageId = input.sources[0]?.provider_message_id;
    if (
      typeof requestedMessageId !== "string" ||
      (result.item !== null &&
        result.item.providerMessageId !== requestedMessageId)
    ) {
      throw new SafeEmailError("provider_unavailable");
    }
    return result;
  }

  async reconcileConfirmation(
    input: Parameters<TrustedEmailStore["reconcileConfirmation"]>[0],
  ): Promise<PersistedReconciliation> {
    return persistedReconciliation(
      await this.#rpc("email_import_reconcile_confirmation", {
        p_owner_user_id: input.ownerUserId,
        p_connection_id: input.connectionId,
        p_provider: input.provider,
        p_provider_account_hash: input.providerAccountHash,
        p_provider_message_id_hash: input.providerMessageIdHash,
        p_provider_thread_id_hash: input.providerThreadIdHash,
        p_sanitized_content_hash: input.sanitizedContentHash,
        p_reviewed_payload: input.reviewedPayload,
        p_entity_type: input.entityType,
        p_entity_id: input.entityId,
        p_idempotency_key: input.idempotencyKey,
        p_reconciled_at: input.reconciledAt,
        p_correlation_id: input.correlationId,
      }),
    );
  }

  async reconcileDismissal(
    input: Parameters<TrustedEmailStore["reconcileDismissal"]>[0],
  ): Promise<PersistedReconciliation> {
    return persistedReconciliation(
      await this.#rpc("email_import_reconcile_dismissal", {
        p_owner_user_id: input.ownerUserId,
        p_connection_id: input.connectionId,
        p_provider: input.provider,
        p_provider_account_hash: input.providerAccountHash,
        p_provider_message_id_hash: input.providerMessageIdHash,
        p_provider_thread_id_hash: input.providerThreadIdHash,
        p_sanitized_content_hash: input.sanitizedContentHash,
        p_idempotency_key: input.idempotencyKey,
        p_reconciled_at: input.reconciledAt,
        p_correlation_id: input.correlationId,
      }),
    );
  }

  async reconcileUpdate(
    input: Parameters<TrustedEmailStore["reconcileUpdate"]>[0],
  ): Promise<PersistedReconciliation> {
    return persistedReconciliation(
      await this.#rpc("email_import_reconcile_update", {
        p_owner_user_id: input.ownerUserId,
        p_connection_id: input.connectionId,
        p_provider: input.provider,
        p_provider_account_hash: input.providerAccountHash,
        p_provider_message_id_hash: input.providerMessageIdHash,
        p_provider_thread_id_hash: input.providerThreadIdHash,
        p_sanitized_content_hash: input.sanitizedContentHash,
        p_resolution: input.resolution,
        p_entity_type: input.entityType,
        p_entity_id: input.entityId,
        p_idempotency_key: input.idempotencyKey,
        p_reconciled_at: input.reconciledAt,
        p_correlation_id: input.correlationId,
      }),
    );
  }

  async finalizeDisconnect(
    input: Parameters<TrustedEmailStore["finalizeDisconnect"]>[0],
  ): Promise<PersistedConnection> {
    return persistedConnection(
      await this.#rpc(
        "email_import_finalize_disconnect",
        {
          p_owner_user_id: input.ownerUserId,
          p_connection_id: input.connectionId,
          p_delete_derived_data: input.deleteDerivedData,
          p_revocation_attempted: input.revocationAttempted,
          p_revocation_succeeded: input.revocationSucceeded,
          p_disconnected_at: input.disconnectedAt,
          p_correlation_id: input.correlationId,
        },
      ),
    );
  }

  async deleteAccountData(
    input: Parameters<TrustedEmailStore["deleteAccountData"]>[0],
  ): Promise<Readonly<Record<string, number>>> {
    const value = await this.#rpc("email_import_delete_account_data", {
      p_owner_user_id: input.ownerUserId,
      p_deleted_at: input.deletedAt,
      p_correlation_id: input.correlationId,
    });
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    const result: Record<string, number> = {};
    for (
      const key of [
        "deleted_connections",
        "deleted_sources",
        "deleted_candidates",
        "deleted_updates",
      ]
    ) {
      const count = value[key];
      if (
        typeof count !== "number" || !Number.isSafeInteger(count) || count < 0
      ) {
        throw new SafeEmailError("provider_unavailable");
      }
      result[key] = count;
    }
    return Object.freeze(result);
  }

  async recordFailure(
    input: Parameters<TrustedEmailStore["recordFailure"]>[0],
  ): Promise<PersistedConnection | null> {
    const value = await this.#rpc("email_import_record_failure", {
      p_owner_user_id: input.ownerUserId,
      p_connection_id: input.connectionId,
      p_operation: input.operation,
      p_connection_state: input.connectionState,
      p_error_category: input.errorCategory,
      p_retry_after_at: input.retryAfterAt,
      p_occurred_at: input.occurredAt,
      p_correlation_id: input.correlationId,
    });
    if (
      value === null || (isRecord(value) && Object.keys(value).length === 0)
    ) return null;
    return persistedConnection(value);
  }
}

export interface OAuthTokenBundle {
  readonly accessToken: string;
  readonly refreshToken: string | null;
  readonly expiresAt: string;
  readonly scopes: readonly string[];
  readonly tokenType: "Bearer";
}

export interface GoogleProfile {
  /** Raw only for the immediate keyed-hash call; never persist or audit it. */
  readonly address: string;
  readonly historyId: string;
}

export interface GoogleOAuthClient {
  exchangeCode(code: string, codeVerifier: string): Promise<OAuthTokenBundle>;
  refreshToken(refreshToken: string): Promise<OAuthTokenBundle>;
  revoke(token: string): Promise<boolean>;
  profile(accessToken: string): Promise<GoogleProfile>;
}

function retryAfterMs(response: Response, now: Date): number | null {
  const value = response.headers.get("retry-after")?.trim();
  if (value === undefined || value === null || value.length === 0) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.min(86_400_000, Math.floor(seconds * 1_000));
  }
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp)
    ? Math.min(86_400_000, Math.max(0, timestamp - now.getTime()))
    : null;
}

function providerStatusError(response: Response, now: Date): SafeEmailError {
  if (response.status === 401 || response.status === 403) {
    return new SafeEmailError("authorization_revoked");
  }
  if (response.status === 404) return new SafeEmailError("cursor_expired");
  if (response.status === 408 || response.status === 504) {
    return new SafeEmailError("timeout");
  }
  if (response.status === 429) {
    return new SafeEmailError("rate_limited", {
      retryAfterMs: retryAfterMs(response, now),
    });
  }
  return new SafeEmailError("provider_unavailable");
}

function providerNetworkError(error: unknown): SafeEmailError {
  if (
    error instanceof DOMException &&
    (error.name === "TimeoutError" || error.name === "AbortError")
  ) {
    return new SafeEmailError("timeout");
  }
  return error instanceof SafeEmailError
    ? error
    : new SafeEmailError("network_unavailable");
}

function exactReadonlyScopes(
  raw: string | readonly string[],
): readonly string[] {
  const scopes = typeof raw === "string"
    ? raw.split(/\s+/).filter((scope) => scope.length > 0)
    : [...raw];
  if (scopes.length !== 1 || scopes[0] !== gmailReadOnlyScope) {
    throw new SafeEmailError("authorization_revoked");
  }
  return Object.freeze([gmailReadOnlyScope]);
}

function decodeTokenResponse(
  value: unknown,
  now: Date,
  fallbackRefreshToken: string | null,
  fallbackScopes: readonly string[] | null,
): OAuthTokenBundle {
  if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
  const accessToken = requiredString(value.access_token, 16_384);
  const refreshToken = value.refresh_token === undefined
    ? fallbackRefreshToken
    : requiredString(value.refresh_token, 16_384);
  const expiresIn = value.expires_in;
  if (
    typeof expiresIn !== "number" || !Number.isFinite(expiresIn) ||
    expiresIn < 1 || expiresIn > 604_800
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  const tokenType = requiredString(value.token_type, 32);
  if (tokenType.toLowerCase() !== "bearer") {
    throw new SafeEmailError("authorization_revoked");
  }
  const scopes = value.scope === undefined
    ? (fallbackScopes === null
      ? (() => {
        throw new SafeEmailError("authorization_revoked");
      })()
      : exactReadonlyScopes(fallbackScopes))
    : exactReadonlyScopes(requiredString(value.scope, 2_048));
  return Object.freeze({
    accessToken,
    refreshToken,
    expiresAt: new Date(now.getTime() + Math.floor(expiresIn * 1_000))
      .toISOString(),
    scopes,
    tokenType: "Bearer",
  });
}

export class GoogleApiClient implements GoogleOAuthClient {
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;

  constructor(
    configuration: ProductionConfiguration,
    runtime: ProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async #request(
    input: URL,
    init: RequestInit,
    acceptStatuses: readonly number[] = [],
  ): Promise<Response> {
    let response: Response;
    try {
      response = await this.#runtime.fetch(input, {
        ...init,
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      throw providerNetworkError(error);
    }
    if (!response.ok && !acceptStatuses.includes(response.status)) {
      throw providerStatusError(response, this.#runtime.now());
    }
    return response;
  }

  async #token(parameters: URLSearchParams): Promise<OAuthTokenBundle> {
    const endpoint = new URL("https://oauth2.googleapis.com/token");
    const response = await this.#request(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
      },
      body: parameters,
    }, [400]);
    const body = await boundedJson(response);
    if (!response.ok) {
      const providerCode = isRecord(body) && typeof body.error === "string"
        ? body.error
        : null;
      throw new SafeEmailError(
        providerCode === "invalid_grant"
          ? "authorization_revoked"
          : "provider_unavailable",
      );
    }
    return decodeTokenResponse(body, this.#runtime.now(), null, null);
  }

  exchangeCode(code: string, codeVerifier: string): Promise<OAuthTokenBundle> {
    return this.#token(
      new URLSearchParams({
        client_id: this.#configuration.gmailClientId,
        client_secret: this.#configuration.gmailClientSecret,
        code,
        code_verifier: codeVerifier,
        grant_type: "authorization_code",
        redirect_uri: this.#configuration.gmailRedirectUri.toString(),
      }),
    );
  }

  async refreshToken(refreshToken: string): Promise<OAuthTokenBundle> {
    const endpoint = new URL("https://oauth2.googleapis.com/token");
    const parameters = new URLSearchParams({
      client_id: this.#configuration.gmailClientId,
      client_secret: this.#configuration.gmailClientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });
    const response = await this.#request(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        accept: "application/json",
      },
      body: parameters,
    }, [400]);
    const body = await boundedJson(response);
    if (!response.ok) {
      const providerCode = isRecord(body) && typeof body.error === "string"
        ? body.error
        : null;
      throw new SafeEmailError(
        providerCode === "invalid_grant"
          ? "authorization_revoked"
          : "provider_unavailable",
      );
    }
    return decodeTokenResponse(
      body,
      this.#runtime.now(),
      refreshToken,
      [gmailReadOnlyScope],
    );
  }

  async revoke(token: string): Promise<boolean> {
    const endpoint = new URL("https://oauth2.googleapis.com/revoke");
    try {
      const response = await this.#request(endpoint, {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          accept: "application/json",
        },
        // Keep credentials out of URLs, access logs and intermediary traces.
        body: new URLSearchParams({ token }),
      }, [400]);
      // Google returns 400 for already-invalid tokens; server destruction must
      // still proceed and the token is no longer usable either way.
      return response.ok || response.status === 400;
    } catch {
      return false;
    }
  }

  async profile(accessToken: string): Promise<GoogleProfile> {
    const response = await this.#request(
      new URL("https://gmail.googleapis.com/gmail/v1/users/me/profile"),
      {
        method: "GET",
        headers: {
          authorization: `Bearer ${accessToken}`,
          accept: "application/json",
        },
      },
    );
    const body = await boundedJson(response);
    if (!isRecord(body)) throw new SafeEmailError("provider_unavailable");
    return Object.freeze({
      address: requiredString(body.emailAddress, 320),
      historyId: numericIdentifier(body.historyId),
    });
  }
}

function numericIdentifier(value: unknown): string {
  const result = requiredString(value, 128);
  if (!/^[1-9][0-9]*$/.test(result)) {
    throw new SafeEmailError("provider_unavailable");
  }
  return result;
}

function pkceAad(
  ownerUserId: string,
  connectionId: string,
  stateHash: string,
): string {
  return `email-import-pkce:v1\u0000${ownerUserId}\u0000${connectionId}\u0000${stateHash}`;
}

function oauthAad(ownerUserId: string, providerAccountHash: string): string {
  return `email-import-oauth:v1\u0000${ownerUserId}\u0000gmail\u0000${providerAccountHash}`;
}

function parsePkceVerifier(value: Readonly<Record<string, unknown>>): string {
  if (
    Object.keys(value).length !== 1 || typeof value.codeVerifier !== "string"
  ) {
    throw new SafeEmailError("authorization_revoked");
  }
  const verifier = value.codeVerifier;
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) {
    throw new SafeEmailError("authorization_revoked");
  }
  return verifier;
}

function parseTokenBundle(
  value: Readonly<Record<string, unknown>>,
): OAuthTokenBundle {
  const expected = new Set([
    "accessToken",
    "refreshToken",
    "expiresAt",
    "scopes",
    "tokenType",
  ]);
  if (
    Object.keys(value).some((key) => !expected.has(key)) ||
    Object.keys(value).length !== expected.size
  ) {
    throw new SafeEmailError("authorization_revoked");
  }
  const accessToken = requiredString(value.accessToken, 16_384);
  const refreshToken = value.refreshToken === null
    ? null
    : requiredString(value.refreshToken, 16_384);
  const expiresAt = requiredString(value.expiresAt, 64);
  if (!Number.isFinite(Date.parse(expiresAt))) {
    throw new SafeEmailError("authorization_revoked");
  }
  if (!Array.isArray(value.scopes)) {
    throw new SafeEmailError("authorization_revoked");
  }
  return Object.freeze({
    accessToken,
    refreshToken,
    expiresAt,
    scopes: exactReadonlyScopes(
      value.scopes.map((scope) => requiredString(scope, 2_048)),
    ),
    tokenType: value.tokenType === "Bearer" ? "Bearer" : (() => {
      throw new SafeEmailError("authorization_revoked");
    })(),
  });
}

export interface OAuthStartResult {
  readonly connectionId: string;
  readonly authorizationUri: string;
  readonly codeChallenge: string;
  readonly expiresAt: string;
}

export interface OAuthCompletionResult {
  readonly connection: PersistedConnection;
  readonly requestedConnectionId: string;
  readonly correlationId: string;
}

export interface OAuthFailureResult {
  readonly requestedConnectionId: string;
  readonly correlationId: string;
}

/**
 * Safe callback failure that retains only the opaque OAuth-attempt binding.
 * The endpoint uses these UUIDs to return the same authenticated correlation
 * after a provider exchange/profile failure; no OAuth or account data crosses
 * this boundary.
 */
export class OAuthCompletionFailure extends SafeEmailError {
  readonly requestedConnectionId: string;
  readonly correlationId: string;

  constructor(
    category: EmailErrorCategory,
    requestedConnectionId: string,
    correlationId: string,
    retryAfterMs: number | null = null,
  ) {
    super(category, { retryAfterMs });
    this.name = "OAuthCompletionFailure";
    this.requestedConnectionId = requestedConnectionId;
    this.correlationId = correlationId;
  }
}

export class GmailOAuthCoordinator {
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;
  readonly #store: TrustedEmailStore;
  readonly #vault: AesGcmVault;
  readonly #google: GoogleOAuthClient;

  constructor(input: {
    readonly configuration: ProductionConfiguration;
    readonly runtime: ProductionRuntime;
    readonly store: TrustedEmailStore;
    readonly vault: AesGcmVault;
    readonly google: GoogleOAuthClient;
  }) {
    this.#configuration = input.configuration;
    this.#runtime = input.runtime;
    this.#store = input.store;
    this.#vault = input.vault;
    this.#google = input.google;
  }

  async start(
    ownerUserId: string,
    requestedConnectionId: string | null,
    correlationId: string,
  ): Promise<OAuthStartResult> {
    const connectionId = requestedConnectionId ?? this.#runtime.randomUuid();
    if (
      !isUuid(ownerUserId) || !isUuid(connectionId) || !isUuid(correlationId)
    ) {
      throw new SafeEmailError("validation_failed");
    }
    const state = base64UrlEncode(this.#runtime.randomBytes(32));
    const codeVerifier = base64UrlEncode(this.#runtime.randomBytes(48));
    if (state.length < 32 || !/^[A-Za-z0-9_-]+$/.test(state)) {
      throw new SafeEmailError("internal_error");
    }
    if (!/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier)) {
      throw new SafeEmailError("internal_error");
    }
    const stateHash = await sha256Hex(state);
    const codeChallenge = base64UrlEncode(await sha256(codeVerifier));
    const expiresAt = new Date(this.#runtime.now().getTime() + 10 * 60_000)
      .toISOString();
    const encryptedVerifier = await this.#vault.seal(
      { codeVerifier },
      pkceAad(ownerUserId, connectionId, stateHash),
    );
    await this.#store.beginOauth({
      ownerUserId,
      connectionId,
      stateHash,
      encryptedPkceVerifier: encryptedVerifier,
      encryptionKeyVersion: this.#configuration.tokenEncryptionKeyVersion,
      expiresAt,
      correlationId,
    });
    const authorization = new URL(
      "https://accounts.google.com/o/oauth2/v2/auth",
    );
    authorization.searchParams.set(
      "client_id",
      this.#configuration.gmailClientId,
    );
    authorization.searchParams.set(
      "redirect_uri",
      this.#configuration.gmailRedirectUri.toString(),
    );
    authorization.searchParams.set("response_type", "code");
    authorization.searchParams.set("scope", gmailReadOnlyScope);
    authorization.searchParams.set("state", state);
    authorization.searchParams.set("code_challenge", codeChallenge);
    authorization.searchParams.set("code_challenge_method", "S256");
    authorization.searchParams.set("access_type", "offline");
    authorization.searchParams.set("prompt", "consent");
    authorization.searchParams.set("include_granted_scopes", "false");
    return Object.freeze({
      connectionId,
      authorizationUri: authorization.toString(),
      codeChallenge,
      expiresAt,
    });
  }

  async complete(
    state: string,
    code: string,
  ): Promise<OAuthCompletionResult> {
    if (
      !/^[A-Za-z0-9_-]{32,256}$/.test(state) ||
      !/^[A-Za-z0-9._~+/=-]{1,4096}$/.test(code)
    ) {
      throw new SafeEmailError("validation_failed");
    }
    const stateHash = await sha256Hex(state);
    const consumedAt = this.#runtime.now().toISOString();
    const oauthState = await this.#store.takeOauth(stateHash, consumedAt);
    if (oauthState === null) throw new SafeEmailError("authorization_revoked");
    try {
      if (
        Date.parse(oauthState.expiresAt) < Date.parse(consumedAt) ||
        oauthState.encryptionKeyVersion !==
          this.#configuration.tokenEncryptionKeyVersion
      ) {
        throw new SafeEmailError("authorization_revoked");
      }
      const verifierPayload = await this.#vault.open(
        oauthState.encryptedPkceVerifier,
        pkceAad(oauthState.ownerUserId, oauthState.connectionId, stateHash),
      );
      const verifier = parsePkceVerifier(verifierPayload);
      const tokens = await this.#google.exchangeCode(code, verifier);
      if (tokens.refreshToken === null) {
        throw new SafeEmailError("authorization_revoked");
      }
      const profile = await this.#google.profile(tokens.accessToken);
      const accountHash = await keyedAccountHash(
        profile.address,
        this.#configuration.accountHashKey,
      );
      const encryptedTokens = await this.#vault.seal(
        { ...tokens },
        oauthAad(oauthState.ownerUserId, accountHash),
      );
      const connectedAt = this.#runtime.now().toISOString();
      const completed = await this.#store.completeOauth({
        ownerUserId: oauthState.ownerUserId,
        connectionId: oauthState.connectionId,
        providerAccountHash: accountHash,
        authorizedScopes: [gmailReadOnlyScope],
        encryptedOauthBundle: encryptedTokens,
        encryptionKeyVersion: this.#configuration.tokenEncryptionKeyVersion,
        expiresAt: tokens.expiresAt,
        initialSyncCursor: null,
        connectedAt,
        correlationId: oauthState.correlationId,
      });
      this.#runtime.audit({
        correlationId: oauthState.correlationId,
        action: "oauth_callback",
        state: "connected",
        category: null,
      });
      return Object.freeze({
        connection: completed,
        requestedConnectionId: oauthState.connectionId,
        correlationId: oauthState.correlationId,
      });
    } catch (rawError) {
      const error = rawError instanceof SafeEmailError
        ? rawError
        : new SafeEmailError("internal_error");
      await this.#store.recordFailure({
        ownerUserId: oauthState.ownerUserId,
        connectionId: oauthState.connectionId,
        operation: "oauth_callback",
        connectionState: "failed",
        errorCategory: error.category,
        retryAfterAt: null,
        occurredAt: this.#runtime.now().toISOString(),
        correlationId: oauthState.correlationId,
      }).catch(() => null);
      this.#runtime.audit({
        correlationId: oauthState.correlationId,
        action: "oauth_callback",
        state: "failed",
        category: error.category,
      });
      throw new OAuthCompletionFailure(
        error.category,
        oauthState.connectionId,
        oauthState.correlationId,
        error.retryAfterMs,
      );
    }
  }

  async fail(
    state: string,
    category: EmailErrorCategory,
  ): Promise<OAuthFailureResult> {
    if (!/^[A-Za-z0-9_-]{32,256}$/.test(state)) {
      throw new SafeEmailError("validation_failed");
    }
    const oauthState = await this.#store.takeOauth(
      await sha256Hex(state),
      this.#runtime.now().toISOString(),
    );
    if (oauthState === null) throw new SafeEmailError("authorization_revoked");
    await this.#store.recordFailure({
      ownerUserId: oauthState.ownerUserId,
      connectionId: oauthState.connectionId,
      operation: "oauth_callback",
      connectionState: "failed",
      errorCategory: category,
      retryAfterAt: null,
      occurredAt: this.#runtime.now().toISOString(),
      correlationId: oauthState.correlationId,
    }).catch(() => null);
    this.#runtime.audit({
      correlationId: oauthState.correlationId,
      action: "oauth_callback",
      state: "failed",
      category,
    });
    return Object.freeze({
      requestedConnectionId: oauthState.connectionId,
      correlationId: oauthState.correlationId,
    });
  }
}

export interface CredentialAccess {
  readonly connection: StoredCredentials;
  accessToken(forceRefresh?: boolean): Promise<string>;
  revocationToken(): Promise<string>;
}

export class TrustedCredentialManager implements CredentialAccess {
  readonly #ownerUserId: string;
  readonly #correlationId: string;
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;
  readonly #store: TrustedEmailStore;
  readonly #vault: AesGcmVault;
  readonly #google: GoogleOAuthClient;
  #record: StoredCredentials;
  #bundle: OAuthTokenBundle | null = null;

  constructor(input: {
    readonly ownerUserId: string;
    readonly correlationId: string;
    readonly configuration: ProductionConfiguration;
    readonly runtime: ProductionRuntime;
    readonly store: TrustedEmailStore;
    readonly vault: AesGcmVault;
    readonly google: GoogleOAuthClient;
    readonly record: StoredCredentials;
  }) {
    this.#ownerUserId = input.ownerUserId;
    this.#correlationId = input.correlationId;
    this.#configuration = input.configuration;
    this.#runtime = input.runtime;
    this.#store = input.store;
    this.#vault = input.vault;
    this.#google = input.google;
    this.#record = input.record;
  }

  get connection(): StoredCredentials {
    return this.#record;
  }

  async #loadBundle(): Promise<OAuthTokenBundle> {
    if (this.#bundle !== null) return this.#bundle;
    if (
      this.#record.encryptionKeyVersion !==
        this.#configuration.tokenEncryptionKeyVersion
    ) {
      throw new SafeEmailError("authorization_revoked");
    }
    this.#bundle = parseTokenBundle(
      await this.#vault.open(
        this.#record.encryptedOauthBundle,
        oauthAad(this.#ownerUserId, this.#record.providerAccountHash),
      ),
    );
    return this.#bundle;
  }

  async accessToken(forceRefresh = false): Promise<string> {
    let bundle = await this.#loadBundle();
    const expiresSoon = Date.parse(bundle.expiresAt) <=
      this.#runtime.now().getTime() + 60_000;
    if (!forceRefresh && !expiresSoon) return bundle.accessToken;
    if (bundle.refreshToken === null) {
      throw new SafeEmailError("authorization_revoked");
    }
    const refreshed = await this.#google.refreshToken(bundle.refreshToken);
    bundle = Object.freeze({
      ...refreshed,
      refreshToken: refreshed.refreshToken ?? bundle.refreshToken,
    });
    const encrypted = await this.#vault.seal(
      { ...bundle },
      oauthAad(this.#ownerUserId, this.#record.providerAccountHash),
    );
    const version = await this.#store.rotateCredentials({
      ownerUserId: this.#ownerUserId,
      connectionId: this.#record.connectionId,
      expectedCredentialVersion: this.#record.credentialVersion,
      encryptedOauthBundle: encrypted,
      encryptionKeyVersion: this.#configuration.tokenEncryptionKeyVersion,
      expiresAt: bundle.expiresAt,
      rotatedAt: this.#runtime.now().toISOString(),
      correlationId: this.#correlationId,
    });
    this.#record = Object.freeze({
      ...this.#record,
      encryptedOauthBundle: encrypted,
      encryptionKeyVersion: this.#configuration.tokenEncryptionKeyVersion,
      credentialVersion: version,
      expiresAt: bundle.expiresAt,
    });
    this.#bundle = bundle;
    this.#runtime.audit({
      correlationId: this.#correlationId,
      action: "token_refresh",
      state: "rotated",
      category: null,
    });
    return bundle.accessToken;
  }

  async revocationToken(): Promise<string> {
    const bundle = await this.#loadBundle();
    return bundle.refreshToken ?? bundle.accessToken;
  }
}

interface GmailCursor {
  readonly version: 1;
  readonly mode: "initial" | "history";
  /**
   * Application-level generation, independent of Gmail's history high-water.
   * Gmail may return the same historyId for an empty poll; advancing this
   * opaque field still gives the caller a distinct replay key.
   */
  readonly pollGeneration?: number;
  readonly afterEpochSeconds?: number;
  readonly highWaterHistoryId?: string;
  readonly startHistoryId?: string;
  readonly pageToken?: string;
  readonly pendingMessageIds?: readonly string[];
  readonly finalHistoryId?: string;
}

function base64UrlDecode(
  value: string,
  maximumCharacters = 4_096,
  failureCategory: EmailErrorCategory = "cursor_expired",
): Uint8Array {
  if (
    !/^[A-Za-z0-9_-]+={0,2}$/.test(value) || value.length > maximumCharacters
  ) {
    throw new SafeEmailError(failureCategory);
  }
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  try {
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw new SafeEmailError(failureCategory);
  }
}

function encodeGmailCursor(cursor: GmailCursor): string {
  const result = base64UrlEncode(encoder.encode(JSON.stringify(cursor)));
  if (result.length > 4_096) throw new SafeEmailError("provider_unavailable");
  return result;
}

const maximumGmailPollGeneration = 0xffff_ffff;

function nextGmailPollGeneration(cursor: GmailCursor | null): number {
  const current = cursor?.pollGeneration ?? 0;
  return current === maximumGmailPollGeneration ? 0 : current + 1;
}

function providerOpaque(value: unknown, maximum = 1_024): string {
  const result = requiredString(value, maximum);
  if (/\s/.test(result)) throw new SafeEmailError("provider_unavailable");
  return result;
}

function decodeGmailCursor(value: string): GmailCursor {
  let raw: unknown;
  try {
    raw = JSON.parse(decoder.decode(base64UrlDecode(value)));
  } catch (error) {
    if (error instanceof SafeEmailError) throw error;
    throw new SafeEmailError("cursor_expired");
  }
  if (!isRecord(raw) || raw.version !== 1) {
    throw new SafeEmailError("cursor_expired");
  }
  const allowed = new Set([
    "version",
    "mode",
    "pollGeneration",
    "afterEpochSeconds",
    "highWaterHistoryId",
    "startHistoryId",
    "pageToken",
    "pendingMessageIds",
    "finalHistoryId",
  ]);
  if (Object.keys(raw).some((key) => !allowed.has(key))) {
    throw new SafeEmailError("cursor_expired");
  }
  const pollGeneration = raw.pollGeneration === undefined
    ? 0
    : raw.pollGeneration;
  if (
    typeof pollGeneration !== "number" ||
    !Number.isSafeInteger(pollGeneration) || pollGeneration < 0 ||
    pollGeneration > maximumGmailPollGeneration
  ) {
    throw new SafeEmailError("cursor_expired");
  }
  const pageToken = raw.pageToken === undefined
    ? undefined
    : providerOpaque(raw.pageToken, 2_048);
  const pendingMessageIds = raw.pendingMessageIds === undefined
    ? undefined
    : (() => {
      if (
        !Array.isArray(raw.pendingMessageIds) ||
        raw.pendingMessageIds.length > 100
      ) {
        throw new SafeEmailError("cursor_expired");
      }
      return raw.pendingMessageIds.map((id) => providerOpaque(id));
    })();
  if (raw.mode === "initial") {
    if (
      typeof raw.afterEpochSeconds !== "number" ||
      !Number.isSafeInteger(raw.afterEpochSeconds) || raw.afterEpochSeconds < 0
    ) {
      throw new SafeEmailError("cursor_expired");
    }
    return Object.freeze({
      version: 1,
      mode: "initial",
      pollGeneration,
      afterEpochSeconds: raw.afterEpochSeconds,
      highWaterHistoryId: numericIdentifier(raw.highWaterHistoryId),
      pageToken,
      pendingMessageIds,
    });
  }
  if (raw.mode === "history") {
    return Object.freeze({
      version: 1,
      mode: "history",
      pollGeneration,
      startHistoryId: numericIdentifier(raw.startHistoryId),
      pageToken,
      pendingMessageIds,
      finalHistoryId: raw.finalHistoryId === undefined
        ? undefined
        : numericIdentifier(raw.finalHistoryId),
    });
  }
  throw new SafeEmailError("cursor_expired");
}

function gmailHeader(
  payload: Readonly<Record<string, unknown>>,
  name: string,
): string {
  const headers = payload.headers;
  if (!Array.isArray(headers)) return "";
  for (const header of headers) {
    if (
      isRecord(header) && typeof header.name === "string" &&
      header.name.toLowerCase() === name.toLowerCase() &&
      typeof header.value === "string"
    ) {
      return header.value;
    }
  }
  return "";
}

function decodedGmailBody(value: unknown): string {
  if (value === undefined || value === null || value === "") return "";
  if (typeof value !== "string" || value.trim() !== value) {
    throw new SafeEmailError("malformed_content");
  }
  if (value.length > 360_000) throw new SafeEmailError("oversized_content");
  const encoded = value;
  const bytes = base64UrlDecode(encoded, 360_000, "malformed_content");
  if (bytes.length > 262_144) throw new SafeEmailError("oversized_content");
  try {
    return decoder.decode(bytes);
  } catch {
    throw new SafeEmailError("malformed_content");
  }
}

function gmailPartText(
  part: Readonly<Record<string, unknown>>,
  preferredMime: "text/plain" | "text/html",
  depth = 0,
  budget: { remaining: number } = { remaining: 512 },
): string {
  if (depth > 32 || budget.remaining <= 0) {
    throw new SafeEmailError("oversized_content");
  }
  budget.remaining -= 1;
  const mimeType = typeof part.mimeType === "string"
    ? part.mimeType.toLowerCase()
    : "";
  if (mimeType === preferredMime && isRecord(part.body)) {
    const data = decodedGmailBody(part.body.data);
    if (data.length > 0) return data;
  }
  if (Array.isArray(part.parts)) {
    for (const child of part.parts) {
      if (!isRecord(child)) continue;
      const result = gmailPartText(child, preferredMime, depth + 1, budget);
      if (result.length > 0) return result;
    }
  }
  return "";
}

function senderLabel(value: string): string {
  return value
    .replace(/<[^>]{1,320}>/g, " ")
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, " ")
    .replace(/["']/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function decodeGmailMessage(value: unknown): ProviderEmailMessage {
  if (!isRecord(value) || !isRecord(value.payload)) {
    throw new SafeEmailError("malformed_content");
  }
  let providerMessageId: string;
  try {
    providerMessageId = providerOpaque(value.id);
  } catch {
    throw new SafeEmailError("malformed_content");
  }
  let providerThreadId: string;
  try {
    providerThreadId = providerOpaque(value.threadId);
  } catch {
    throw new SafeEmailError("malformed_content");
  }
  if (
    typeof value.internalDate !== "string" || value.internalDate.length === 0 ||
    value.internalDate.length > 32 ||
    value.internalDate.trim() !== value.internalDate
  ) {
    throw new SafeEmailError("malformed_content");
  }
  const internalDate = value.internalDate;
  if (!/^[0-9]{1,17}$/.test(internalDate)) {
    throw new SafeEmailError("malformed_content");
  }
  const receivedMilliseconds = Number(internalDate);
  const receivedDate = new Date(receivedMilliseconds);
  if (
    !Number.isSafeInteger(receivedMilliseconds) ||
    !Number.isFinite(receivedDate.getTime())
  ) {
    throw new SafeEmailError("malformed_content");
  }
  const text = gmailPartText(value.payload, "text/plain");
  const html = text.length === 0
    ? gmailPartText(value.payload, "text/html")
    : "";
  const body = text.length > 0 ? text : html;
  if (body.length === 0) throw new SafeEmailError("malformed_content");
  return Object.freeze({
    providerMessageId,
    providerThreadId,
    receivedAt: receivedDate.toISOString(),
    subject: gmailHeader(value.payload, "subject"),
    sender: senderLabel(gmailHeader(value.payload, "from")),
    body,
    bodyKind: text.length > 0 ? "text" : "html",
  });
}

function failedGmailMessage(
  requestedId: string,
  value: unknown,
  category: "malformed_content" | "oversized_content" | "unsafe_content",
  fallbackReceivedAt: Date,
): ProviderEmailMessage {
  let providerThreadId: string | null = null;
  let receivedAt = fallbackReceivedAt.toISOString();
  let responseMatchesRequest = false;
  if (isRecord(value)) {
    try {
      responseMatchesRequest = providerOpaque(value.id) === requestedId;
    } catch {
      responseMatchesRequest = false;
    }
  }
  if (responseMatchesRequest && isRecord(value)) {
    try {
      providerThreadId = providerOpaque(value.threadId);
    } catch {
      providerThreadId = null;
    }
    if (
      typeof value.internalDate === "string" &&
      /^[0-9]{1,17}$/.test(value.internalDate)
    ) {
      const milliseconds = Number(value.internalDate);
      const candidate = new Date(milliseconds);
      if (
        Number.isSafeInteger(milliseconds) &&
        Number.isFinite(candidate.getTime())
      ) {
        receivedAt = candidate.toISOString();
      }
    }
  }
  return Object.freeze({
    providerMessageId: requestedId,
    providerThreadId,
    receivedAt,
    subject: "",
    sender: "",
    body: "",
    bodyKind: "text" as const,
    failureCategory: category,
  });
}

function uniqueMessageIds(values: readonly unknown[]): readonly string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const id = isRecord(value) && isRecord(value.message)
      ? providerOpaque(value.message.id)
      : isRecord(value)
      ? providerOpaque(value.id)
      : (() => {
        throw new SafeEmailError("provider_unavailable");
      })();
    if (!seen.has(id)) {
      seen.add(id);
      result.push(id);
    }
  }
  return result;
}

export class GmailReadonlyConnector implements EmailProviderConnector {
  readonly provider = "gmail" as const;
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;
  readonly #credentials: CredentialAccess;

  constructor(input: {
    readonly configuration: ProductionConfiguration;
    readonly runtime: ProductionRuntime;
    readonly credentials: CredentialAccess;
  }) {
    this.#configuration = input.configuration;
    this.#runtime = input.runtime;
    this.#credentials = input.credentials;
  }

  async #authorizedJson(
    endpoint: URL,
    missingMessageIsMalformed = false,
  ): Promise<unknown> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const token = await this.#credentials.accessToken(attempt === 1);
      let response: Response;
      try {
        response = await this.#runtime.fetch(endpoint, {
          method: "GET",
          headers: {
            authorization: `Bearer ${token}`,
            accept: "application/json",
          },
          signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
        });
      } catch (error) {
        throw providerNetworkError(error);
      }
      if (response.status === 401 && attempt === 0) continue;
      if (!response.ok) {
        if (
          missingMessageIsMalformed &&
          (response.status === 404 || response.status === 410)
        ) {
          throw new SafeEmailError("malformed_content");
        }
        throw providerStatusError(response, this.#runtime.now());
      }
      return missingMessageIsMalformed
        ? boundedProviderMessageJson(response)
        : boundedJson(response);
    }
    throw new SafeEmailError("authorization_revoked");
  }

  async #messages(
    ids: readonly string[],
  ): Promise<readonly ProviderEmailMessage[]> {
    const result: ProviderEmailMessage[] = [];
    for (const id of ids) {
      result.push(await this.fetchMessage(id));
    }
    return result;
  }

  async fetchMessage(providerMessageId: string): Promise<ProviderEmailMessage> {
    const requestedId = providerOpaque(providerMessageId);
    const endpoint = new URL(
      `https://gmail.googleapis.com/gmail/v1/users/me/messages/${
        encodeURIComponent(requestedId)
      }`,
    );
    endpoint.searchParams.set("format", "full");
    let value: unknown;
    try {
      value = await this.#authorizedJson(endpoint, true);
    } catch (rawError) {
      if (
        rawError instanceof SafeEmailError &&
        (rawError.category === "malformed_content" ||
          rawError.category === "oversized_content" ||
          rawError.category === "unsafe_content")
      ) {
        return failedGmailMessage(
          requestedId,
          value,
          rawError.category,
          this.#runtime.now(),
        );
      }
      throw rawError;
    }
    try {
      const decoded = decodeGmailMessage(value);
      if (decoded.providerMessageId !== requestedId) {
        throw new SafeEmailError("malformed_content");
      }
      return decoded;
    } catch (rawError) {
      const category = rawError instanceof SafeEmailError &&
          (rawError.category === "malformed_content" ||
            rawError.category === "oversized_content" ||
            rawError.category === "unsafe_content")
        ? rawError.category
        : "malformed_content";
      return failedGmailMessage(
        requestedId,
        value,
        category,
        this.#runtime.now(),
      );
    }
  }

  async #profileHistoryId(): Promise<string> {
    const value = await this.#authorizedJson(
      new URL("https://gmail.googleapis.com/gmail/v1/users/me/profile"),
    );
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    return numericIdentifier(value.historyId);
  }

  async #initialPage(
    request: ProviderFetchRequest,
    cursor: GmailCursor | null,
  ): Promise<ProviderFetchPage> {
    const pollGeneration = nextGmailPollGeneration(cursor);
    const afterEpochSeconds = cursor?.afterEpochSeconds ?? (() => {
      if (request.receivedAfter === null) {
        throw new SafeEmailError("cursor_expired");
      }
      const milliseconds = Date.parse(request.receivedAfter);
      if (!Number.isFinite(milliseconds)) {
        throw new SafeEmailError("validation_failed");
      }
      return Math.floor(milliseconds / 1_000);
    })();
    const highWaterHistoryId = cursor?.highWaterHistoryId ??
      await this.#profileHistoryId();
    const endpoint = new URL(
      "https://gmail.googleapis.com/gmail/v1/users/me/messages",
    );
    endpoint.searchParams.set("maxResults", String(request.limit));
    endpoint.searchParams.set("q", `after:${afterEpochSeconds}`);
    if (cursor?.pageToken !== undefined) {
      endpoint.searchParams.set("pageToken", cursor.pageToken);
    }
    const value = await this.#authorizedJson(endpoint);
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    const listed = value.messages === undefined ? [] : (() => {
      if (!Array.isArray(value.messages)) {
        throw new SafeEmailError("provider_unavailable");
      }
      return uniqueMessageIds(value.messages);
    })();
    if (listed.length > request.limit) {
      throw new SafeEmailError("provider_unavailable");
    }
    const nextPageToken = value.nextPageToken === undefined
      ? null
      : providerOpaque(value.nextPageToken, 2_048);
    return {
      messages: await this.#messages(listed),
      nextCursor: nextPageToken === null
        ? encodeGmailCursor({
          version: 1,
          mode: "history",
          pollGeneration,
          startHistoryId: highWaterHistoryId,
        })
        : encodeGmailCursor({
          version: 1,
          mode: "initial",
          pollGeneration,
          afterEpochSeconds,
          highWaterHistoryId,
          pageToken: nextPageToken,
        }),
      hasMore: nextPageToken !== null,
    };
  }

  async #historyPage(
    request: ProviderFetchRequest,
    cursor: GmailCursor,
  ): Promise<ProviderFetchPage> {
    const pollGeneration = nextGmailPollGeneration(cursor);
    const pending = [...(cursor.pendingMessageIds ?? [])];
    if (pending.length > 0) {
      const selected = pending.splice(0, request.limit);
      const hasMore = pending.length > 0 || cursor.pageToken !== undefined;
      const finalId = cursor.finalHistoryId ?? cursor.startHistoryId!;
      return {
        messages: await this.#messages(selected),
        nextCursor: encodeGmailCursor(
          hasMore
            ? {
              version: 1,
              mode: "history",
              pollGeneration,
              startHistoryId: cursor.startHistoryId,
              pageToken: cursor.pageToken,
              pendingMessageIds: pending.length === 0 ? undefined : pending,
              finalHistoryId: finalId,
            }
            : {
              version: 1,
              mode: "history",
              pollGeneration,
              startHistoryId: finalId,
            },
        ),
        hasMore,
      };
    }

    const endpoint = new URL(
      "https://gmail.googleapis.com/gmail/v1/users/me/history",
    );
    endpoint.searchParams.set("startHistoryId", cursor.startHistoryId!);
    endpoint.searchParams.set("historyTypes", "messageAdded");
    endpoint.searchParams.set("maxResults", String(request.limit));
    if (cursor.pageToken !== undefined) {
      endpoint.searchParams.set("pageToken", cursor.pageToken);
    }
    const value = await this.#authorizedJson(endpoint);
    if (!isRecord(value)) throw new SafeEmailError("provider_unavailable");
    const currentHistoryId = numericIdentifier(value.historyId);
    const added: unknown[] = [];
    if (value.history !== undefined) {
      if (!Array.isArray(value.history)) {
        throw new SafeEmailError("provider_unavailable");
      }
      for (const history of value.history) {
        if (!isRecord(history) || history.messagesAdded === undefined) continue;
        if (!Array.isArray(history.messagesAdded)) {
          throw new SafeEmailError("provider_unavailable");
        }
        added.push(...history.messagesAdded);
      }
    }
    const ids = uniqueMessageIds(added);
    if (ids.length > 100) throw new SafeEmailError("provider_unavailable");
    const selected = ids.slice(0, request.limit);
    const remaining = ids.slice(request.limit);
    const nextPageToken = value.nextPageToken === undefined
      ? undefined
      : providerOpaque(value.nextPageToken, 2_048);
    const hasMore = remaining.length > 0 || nextPageToken !== undefined;
    return {
      messages: await this.#messages(selected),
      nextCursor: encodeGmailCursor(
        hasMore
          ? {
            version: 1,
            mode: "history",
            pollGeneration,
            startHistoryId: cursor.startHistoryId,
            pageToken: nextPageToken,
            pendingMessageIds: remaining.length === 0 ? undefined : remaining,
            finalHistoryId: currentHistoryId,
          }
          : {
            version: 1,
            mode: "history",
            pollGeneration,
            startHistoryId: currentHistoryId,
          },
      ),
      hasMore,
    };
  }

  fetchPage(request: ProviderFetchRequest): Promise<ProviderFetchPage> {
    if (request.cursor === null) return this.#initialPage(request, null);
    const cursor = decodeGmailCursor(request.cursor);
    return cursor.mode === "initial"
      ? this.#initialPage(request, cursor)
      : this.#historyPage(request, cursor);
  }
}

const nullableBoundedStringSchema = (maximum: number) => ({
  anyOf: [
    { type: "string", minLength: 1, maxLength: maximum },
    { type: "null" },
  ],
});

/** Closed, strict schema sent to the production JSON-only model endpoint. */
export const candidateJsonSchema = Object.freeze({
  type: "object",
  additionalProperties: false,
  required: [
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
  properties: {
    schema_version: { const: "1.0" },
    candidate_type: {
      enum: ["assignment", "exam", "event", "announcement", "unknown"],
    },
    title: nullableBoundedStringSchema(
      candidateContract.maximumTitleCharacters,
    ),
    course_hint: {
      type: "object",
      additionalProperties: false,
      required: ["name", "code"],
      properties: {
        name: nullableBoundedStringSchema(
          candidateContract.maximumCourseNameCharacters,
        ),
        code: nullableBoundedStringSchema(
          candidateContract.maximumCourseCodeCharacters,
        ),
      },
    },
    due: {
      type: "object",
      additionalProperties: false,
      required: ["at", "all_day", "timezone", "raw_text"],
      properties: {
        at: nullableBoundedStringSchema(64),
        all_day: { type: "boolean" },
        timezone: nullableBoundedStringSchema(64),
        raw_text: nullableBoundedStringSchema(
          candidateContract.maximumRawDateTextCharacters,
        ),
      },
    },
    start_at: nullableBoundedStringSchema(64),
    end_at: nullableBoundedStringSchema(64),
    location: nullableBoundedStringSchema(
      candidateContract.maximumLocationCharacters,
    ),
    submission_url: nullableBoundedStringSchema(
      candidateContract.maximumSubmissionUrlCharacters,
    ),
    summary: nullableBoundedStringSchema(
      candidateContract.maximumSummaryCharacters,
    ),
    suggested_reminders_minutes: {
      type: "array",
      maxItems: candidateContract.maximumReminderItems,
      uniqueItems: true,
      items: {
        type: "integer",
        minimum: candidateContract.minimumReminderMinutes,
        maximum: candidateContract.maximumReminderMinutes,
      },
    },
    confidence: {
      type: "object",
      additionalProperties: false,
      required: ["overall", "title", "course", "date_time"],
      properties: {
        overall: { type: "number", minimum: 0, maximum: 1 },
        title: { type: "number", minimum: 0, maximum: 1 },
        course: { type: "number", minimum: 0, maximum: 1 },
        date_time: { type: "number", minimum: 0, maximum: 1 },
      },
    },
    evidence: {
      type: "array",
      maxItems: candidateContract.maximumEvidenceItems,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["field", "text"],
        properties: {
          field: {
            enum: [
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
            ],
          },
          text: {
            type: "string",
            minLength: 1,
            maxLength: candidateContract.maximumEvidenceTextCharacters,
          },
        },
      },
    },
    warnings: {
      type: "array",
      maxItems: candidateContract.maximumWarningItems,
      uniqueItems: true,
      items: {
        enum: [
          "ambiguous_date",
          "ambiguous_year",
          "ambiguous_time",
          "ambiguous_course",
          "missing_title",
          "missing_date_time",
          "relative_date",
          "low_confidence",
          "untrusted_instruction_ignored",
        ],
      },
    },
    requires_user_confirmation: { const: true },
  },
});

function modelOutputText(value: unknown): string {
  if (!isRecord(value)) throw new SafeEmailError("invalid_extraction");
  if (typeof value.output_text === "string") {
    return requiredString(
      value.output_text,
      candidateContract.maximumJsonBytes,
    );
  }
  if (!Array.isArray(value.output)) {
    throw new SafeEmailError("invalid_extraction");
  }
  for (const output of value.output) {
    if (!isRecord(output) || !Array.isArray(output.content)) continue;
    for (const content of output.content) {
      if (
        isRecord(content) && content.type === "output_text" &&
        typeof content.text === "string"
      ) {
        return requiredString(
          content.text,
          candidateContract.maximumJsonBytes,
        );
      }
    }
  }
  throw new SafeEmailError("invalid_extraction");
}

export class OpenAIJsonModelClient implements EmailJsonModelClient {
  readonly isConfigured = true;
  readonly guaranteesJsonOnlyWithoutTools = true;
  readonly #configuration: ProductionConfiguration;
  readonly #runtime: ProductionRuntime;

  constructor(
    configuration: ProductionConfiguration,
    runtime: ProductionRuntime,
  ) {
    this.#configuration = configuration;
    this.#runtime = runtime;
  }

  async generateJsonOnly(request: EmailJsonModelRequest): Promise<string> {
    if (request.schemaVersion !== "1.0") {
      throw new SafeEmailError("unsupported_schema");
    }
    const endpoint = new URL("https://api.openai.com/v1/responses");
    const modelInput = JSON.stringify({
      received_at: request.input.receivedAt,
      timezone: request.input.timezone,
      subject: request.input.sanitizedSubject,
      content: request.input.sanitizedContent,
      sender_label: request.input.sanitizedSenderLabel,
    });
    let response: Response;
    try {
      response = await this.#runtime.fetch(endpoint, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.#configuration.openAiApiKey}`,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          model: this.#configuration.modelId,
          instructions: request.systemInstruction,
          input: [{
            role: "user",
            content: [{ type: "input_text", text: modelInput }],
          }],
          text: {
            format: {
              type: "json_schema",
              name: "email_candidate_v1",
              strict: true,
              schema: candidateJsonSchema,
            },
          },
          store: false,
        }),
        signal: AbortSignal.timeout(this.#configuration.requestTimeoutMs),
      });
    } catch (error) {
      throw providerNetworkError(error);
    }
    if (!response.ok) {
      const safe = providerStatusError(response, this.#runtime.now());
      throw new SafeEmailError(
        safe.category === "authorization_revoked"
          ? "configuration_missing"
          : safe.category,
        { retryAfterMs: safe.retryAfterMs },
      );
    }
    return modelOutputText(await boundedJson(response));
  }
}

export function safeSourceRpcRows(
  sources: readonly SafePersistedEmailSource[],
  candidates: readonly {
    readonly providerMessageId: string;
    readonly candidate: Readonly<Record<string, unknown>> | null;
    readonly errorCategory: EmailErrorCategory | null;
  }[],
): {
  readonly sources: readonly Readonly<Record<string, unknown>>[];
  readonly candidates: readonly Readonly<Record<string, unknown>>[];
} {
  const candidatesByMessage = new Map(
    candidates.map((item) => [item.providerMessageId, item]),
  );
  if (
    sources.length > 100 || sources.length !== candidates.length ||
    candidatesByMessage.size !== candidates.length ||
    new Set(sources.map((source) => source.provider_message_id)).size !==
      sources.length
  ) {
    throw new SafeEmailError("internal_error");
  }
  const safeSources: Readonly<Record<string, unknown>>[] = [];
  const safeCandidates: Readonly<Record<string, unknown>>[] = [];
  for (const source of sources) {
    const item = candidatesByMessage.get(source.provider_message_id);
    if (item === undefined) throw new SafeEmailError("internal_error");
    const failed = source.processing_state === "failed";
    if (
      (source.processing_state !== "processed" && !failed) ||
      failed !== (item.candidate === null) ||
      failed !== (item.errorCategory !== null) ||
      source.error_category !== item.errorCategory ||
      source.provider_thread_id === null ||
      (failed && source.evidence_metadata.length !== 0)
    ) {
      throw new SafeEmailError("internal_error");
    }
    safeSources.push(Object.freeze({
      provider_message_id: source.provider_message_id,
      provider_thread_id: source.provider_thread_id,
      received_at: source.received_at,
      sanitized_content_hash: source.sanitized_content_hash,
      evidence_metadata: source.evidence_metadata.map((entry) => entry.text),
      processing_state: source.processing_state,
      error_category: source.error_category,
    }));
    safeCandidates.push(Object.freeze({
      provider_message_id: source.provider_message_id,
      validated_payload: item.candidate,
      error_category: item.errorCategory,
    }));
  }
  if (safeSources.length !== safeCandidates.length) {
    throw new SafeEmailError("internal_error");
  }
  return Object.freeze({
    sources: Object.freeze(safeSources),
    candidates: Object.freeze(safeCandidates),
  });
}

export function safeAppRedirect(
  configured: URL,
  outcome: "connected" | "failed",
  correlationId: string,
  category: EmailErrorCategory | null,
  requestedConnectionId: string | null = null,
): string {
  const redirect = new URL(configured.toString());
  redirect.searchParams.set("email_import", outcome);
  redirect.searchParams.set("correlation_id", correlationId);
  if (requestedConnectionId !== null) {
    redirect.searchParams.set("connection_id", requestedConnectionId);
  }
  if (outcome === "failed" && category !== null) {
    redirect.searchParams.set("category", category);
  }
  return redirect.toString();
}
