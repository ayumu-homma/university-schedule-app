import {
  type EmailTaskExtractor,
  ModelEmailTaskExtractor,
} from "./extraction.ts";
import { validateCandidateObject } from "./candidate_codec.ts";
import {
  type EmailIngestionResult,
  processProviderEmailMessage,
  runIncrementalEmailIngestion,
} from "./ingestion.ts";
import {
  AesGcmVault,
  type CredentialAccess,
  defaultProductionRuntime,
  GmailOAuthCoordinator,
  GmailReadonlyConnector,
  GoogleApiClient,
  type GoogleOAuthClient,
  isUuid,
  type JwtAuthenticator,
  OAuthCompletionFailure,
  type OAuthCompletionResult,
  type OAuthFailureResult,
  type OAuthStartResult,
  OpenAIJsonModelClient,
  parseProductionConfiguration,
  type PersistedAuthorizationResolution,
  type PersistedConnection,
  type PersistedReconciliation,
  PostgrestTrustedEmailStore,
  type ProductionConfiguration,
  type ProductionRuntime,
  providerMessageIdentifierHash,
  safeAppRedirect,
  safeSourceRpcRows,
  type StoredCredentials,
  SupabaseJwtAuthenticator,
  TrustedCredentialManager,
  type TrustedEmailStore,
} from "./production.ts";
import {
  type EmailConnectionStatus,
  type EmailErrorCategory,
  type EmailImportEndpointResponse,
  type EmailProviderConnector,
  type EndpointConnectionState,
  SafeEmailError,
} from "./types.ts";

const requiredProductionConfiguration = [
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "GMAIL_OAUTH_CLIENT_ID",
  "GMAIL_OAUTH_CLIENT_SECRET",
  "GMAIL_OAUTH_REDIRECT_URI",
  "EMAIL_IMPORT_APP_REDIRECT_URI",
  "EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY",
  "EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY_VERSION",
  "EMAIL_IMPORT_ACCOUNT_HASH_KEY",
  "EMAIL_IMPORT_MODEL_ID",
  "OPENAI_API_KEY",
] as const;

export type EmailImportAction =
  | "connect"
  | "check_authorization"
  | "fetch_delta"
  | "retry_candidate"
  | "reconcile_confirmation"
  | "reconcile_dismissal"
  | "reconcile_update"
  | "disconnect"
  | "delete_account_data";

export interface EmailImportRequestBody {
  readonly action: EmailImportAction;
  readonly connectionId?: string;
  readonly callbackCorrelationId?: string;
  readonly cursor?: string | null;
  readonly providerMessageId?: string;
  readonly expectedSanitizedContentHash?: string;
  readonly retryIdempotencyKey?: string;
  readonly deleteDerivedData?: boolean;
  readonly provider?: "gmail";
  readonly providerAccountHash?: string;
  readonly providerMessageIdHash?: string;
  readonly providerThreadIdHash?: string;
  readonly sanitizedContentHash?: string;
  readonly reviewedPayload?: Readonly<Record<string, unknown>>;
  readonly resolution?: "accepted" | "rejected";
  readonly entityType?: "assignment" | "exam" | "event";
  readonly entityId?: string;
  readonly idempotencyKey?: string;
}

export interface ProductionReadiness {
  readonly enabled: boolean;
  readonly configured: boolean;
}

export interface OAuthEndpointBoundary {
  start(
    ownerUserId: string,
    requestedConnectionId: string | null,
    correlationId: string,
  ): Promise<OAuthStartResult>;
  complete(state: string, code: string): Promise<OAuthCompletionResult>;
  fail(
    state: string,
    category: EmailErrorCategory,
  ): Promise<OAuthFailureResult>;
}

export interface EmailImportEndpointDependencies {
  readonly configuration: ProductionConfiguration;
  readonly runtime: ProductionRuntime;
  readonly authenticator: JwtAuthenticator;
  readonly store: TrustedEmailStore;
  readonly oauth: OAuthEndpointBoundary;
  readonly google: GoogleOAuthClient;
  readonly extractor: EmailTaskExtractor;
  createCredentials(input: {
    readonly ownerUserId: string;
    readonly correlationId: string;
    readonly record: StoredCredentials;
  }): CredentialAccess;
  createConnector(credentials: CredentialAccess): EmailProviderConnector;
}

export type EndpointDependencyFactory = (
  configuration: ProductionConfiguration,
) => EmailImportEndpointDependencies;

function disconnectedState(): EndpointConnectionState {
  return {
    provider: "gmail",
    status: "disconnected",
    errorCategory: null,
    retryAfterSeconds: null,
    connectedAt: null,
  };
}

function failedConfigurationState(): EndpointConnectionState {
  return {
    provider: "gmail",
    status: "failed",
    errorCategory: "configuration_missing",
    retryAfterSeconds: null,
    connectedAt: null,
  };
}

function connectionState(
  status: EmailConnectionStatus,
  options: {
    readonly category?: EmailErrorCategory | null;
    readonly retryAfterSeconds?: number | null;
    readonly connectedAt?: string | null;
  } = {},
): EndpointConnectionState {
  return {
    provider: "gmail",
    status,
    errorCategory: status === "failed"
      ? options.category ?? "internal_error"
      : null,
    retryAfterSeconds: status === "rate_limited"
      ? options.retryAfterSeconds ?? null
      : null,
    connectedAt: options.connectedAt ?? null,
  };
}

function stateFromPersisted(
  value: PersistedConnection,
): EndpointConnectionState {
  return connectionState(value.connectionState, {
    connectedAt: value.connectedAt,
  });
}

function stateFromAuthorization(
  value: PersistedAuthorizationResolution,
  now: Date,
): EndpointConnectionState {
  let retryAfterSeconds: number | null = null;
  if (value.retryAfterAt !== null) {
    const retryAt = Date.parse(value.retryAfterAt);
    if (!Number.isFinite(retryAt)) {
      throw new SafeEmailError("provider_unavailable");
    }
    retryAfterSeconds = Math.min(
      86_400,
      Math.max(0, Math.ceil((retryAt - now.getTime()) / 1_000)),
    );
  }
  return connectionState(value.connectionState, {
    category: value.errorCategory,
    retryAfterSeconds,
    connectedAt: value.connectedAt,
  });
}

function jsonResponse(
  status: number,
  body: EmailImportEndpointResponse | { readonly error: string },
): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function endpointError(error: SafeEmailError): {
  readonly status: number;
  readonly connection: EndpointConnectionState;
} {
  if (error.category === "authorization_revoked") {
    return {
      status: 401,
      connection: connectionState("reauth_required"),
    };
  }
  if (error.category === "rate_limited") {
    return {
      status: 429,
      connection: connectionState("rate_limited", {
        retryAfterSeconds: error.retryAfterMs === null
          ? null
          : Math.min(86_400, Math.ceil(error.retryAfterMs / 1_000)),
      }),
    };
  }
  const badRequest = error.category === "validation_failed" ||
    error.category === "malformed_content" ||
    error.category === "oversized_content" ||
    error.category === "unsafe_content";
  return {
    status: badRequest ? 400 : 503,
    connection: connectionState("failed", { category: error.category }),
  };
}

export function productionReadiness(
  readEnvironment: (name: string) => string | undefined,
): ProductionReadiness {
  const enabled = readEnvironment("EMAIL_IMPORT_ENABLED") === "true";
  return {
    enabled,
    configured: enabled &&
      readEnvironment("EMAIL_IMPORT_MODEL_ENABLED") === "true" &&
      requiredProductionConfiguration.every((name) => {
        const value = readEnvironment(name);
        return typeof value === "string" && value.trim().length > 0 &&
          value === value.trim();
      }),
  };
}

export function createProductionDependencies(
  configuration: ProductionConfiguration,
  runtime: ProductionRuntime = defaultProductionRuntime,
): EmailImportEndpointDependencies {
  const store = new PostgrestTrustedEmailStore(configuration, runtime);
  const vault = new AesGcmVault(
    configuration.tokenEncryptionKey,
    runtime.randomBytes,
  );
  const google = new GoogleApiClient(configuration, runtime);
  const oauth = new GmailOAuthCoordinator({
    configuration,
    runtime,
    store,
    vault,
    google,
  });
  const modelClient = new OpenAIJsonModelClient(configuration, runtime);
  return Object.freeze({
    configuration,
    runtime,
    authenticator: new SupabaseJwtAuthenticator(configuration, runtime),
    store,
    oauth,
    google,
    extractor: new ModelEmailTaskExtractor({
      enabled: true,
      client: modelClient,
    }),
    createCredentials: (
      { ownerUserId, correlationId, record }: {
        readonly ownerUserId: string;
        readonly correlationId: string;
        readonly record: StoredCredentials;
      },
    ) =>
      new TrustedCredentialManager({
        ownerUserId,
        correlationId,
        configuration,
        runtime,
        store,
        vault,
        google,
        record,
      }),
    createConnector: (credentials: CredentialAccess) =>
      new GmailReadonlyConnector({ configuration, runtime, credentials }),
  });
}

function exactKeys(
  value: Record<string, unknown>,
  expected: ReadonlySet<string>,
): void {
  const keys = Object.keys(value);
  if (
    keys.some((key) => !expected.has(key)) ||
    [...expected].some((key) => !Object.hasOwn(value, key))
  ) {
    throw new SafeEmailError("validation_failed");
  }
}

const sha256HashPattern = /^[0-9a-f]{64}$/;
const reconciliationIdentityKeys = [
  "action",
  "connectionId",
  "provider",
  "providerAccountHash",
  "providerMessageIdHash",
  "providerThreadIdHash",
  "sanitizedContentHash",
  "idempotencyKey",
] as const;

function validateReconciliationIdentity(
  body: Record<string, unknown>,
): void {
  if (
    typeof body.connectionId !== "string" || !isUuid(body.connectionId) ||
    body.provider !== "gmail" ||
    typeof body.providerAccountHash !== "string" ||
    !sha256HashPattern.test(body.providerAccountHash) ||
    typeof body.providerMessageIdHash !== "string" ||
    !sha256HashPattern.test(body.providerMessageIdHash) ||
    typeof body.providerThreadIdHash !== "string" ||
    !sha256HashPattern.test(body.providerThreadIdHash) ||
    typeof body.sanitizedContentHash !== "string" ||
    !sha256HashPattern.test(body.sanitizedContentHash) ||
    typeof body.idempotencyKey !== "string" ||
    body.idempotencyKey.length < 1 || body.idempotencyKey.length > 200 ||
    body.idempotencyKey !== body.idempotencyKey.trim() ||
    [...body.idempotencyKey].some((character) => {
      const code = character.charCodeAt(0);
      return code < 32 || code === 127;
    })
  ) {
    throw new SafeEmailError("validation_failed");
  }
}

function emailEntityType(
  value: unknown,
): "assignment" | "exam" | "event" {
  if (
    value !== "assignment" && value !== "exam" && value !== "event"
  ) {
    throw new SafeEmailError("validation_failed");
  }
  return value;
}

async function requestBody(request: Request): Promise<EmailImportRequestBody> {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > 98_304) {
    throw new SafeEmailError("oversized_content");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).length > 98_304) {
    throw new SafeEmailError("oversized_content");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new SafeEmailError("malformed_content");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new SafeEmailError("validation_failed");
  }
  const body = value as Record<string, unknown>;
  if (typeof body.action !== "string") {
    throw new SafeEmailError("validation_failed");
  }
  switch (body.action) {
    case "connect": {
      const expected = body.connectionId === undefined
        ? new Set(["action"])
        : new Set(["action", "connectionId"]);
      exactKeys(body, expected);
      if (
        body.connectionId !== undefined &&
        (typeof body.connectionId !== "string" || !isUuid(body.connectionId))
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "connect",
        connectionId: body.connectionId as string | undefined,
      };
    }
    case "fetch_delta": {
      exactKeys(body, new Set(["action", "connectionId", "cursor"]));
      if (typeof body.connectionId !== "string" || !isUuid(body.connectionId)) {
        throw new SafeEmailError("validation_failed");
      }
      if (
        body.cursor !== null &&
        (typeof body.cursor !== "string" || body.cursor.length === 0 ||
          body.cursor.length > 4_096)
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "fetch_delta",
        connectionId: body.connectionId,
        cursor: body.cursor as string | null,
      };
    }
    case "retry_candidate": {
      exactKeys(
        body,
        new Set([
          "action",
          "connectionId",
          "providerMessageId",
          "expectedSanitizedContentHash",
          "retryIdempotencyKey",
        ]),
      );
      if (
        typeof body.connectionId !== "string" || !isUuid(body.connectionId) ||
        typeof body.providerMessageId !== "string" ||
        body.providerMessageId.length < 1 ||
        Array.from(body.providerMessageId).length > 1_024 ||
        body.providerMessageId.trim() !== body.providerMessageId ||
        /\s/.test(body.providerMessageId) ||
        Array.from(body.providerMessageId).some((character) => {
          const code = character.codePointAt(0) ?? 0;
          return code < 0x20 || code === 0x7f;
        }) ||
        typeof body.expectedSanitizedContentHash !== "string" ||
        !sha256HashPattern.test(body.expectedSanitizedContentHash) ||
        typeof body.retryIdempotencyKey !== "string" ||
        !sha256HashPattern.test(body.retryIdempotencyKey)
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "retry_candidate",
        connectionId: body.connectionId,
        providerMessageId: body.providerMessageId,
        expectedSanitizedContentHash: body.expectedSanitizedContentHash,
        retryIdempotencyKey: body.retryIdempotencyKey,
      };
    }
    case "check_authorization": {
      exactKeys(
        body,
        new Set(["action", "connectionId", "callbackCorrelationId"]),
      );
      if (
        typeof body.connectionId !== "string" || !isUuid(body.connectionId) ||
        typeof body.callbackCorrelationId !== "string" ||
        !isUuid(body.callbackCorrelationId)
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "check_authorization",
        connectionId: body.connectionId,
        callbackCorrelationId: body.callbackCorrelationId,
      };
    }
    case "reconcile_confirmation": {
      exactKeys(
        body,
        new Set([
          ...reconciliationIdentityKeys,
          "reviewedPayload",
          "entityType",
          "entityId",
        ]),
      );
      validateReconciliationIdentity(body);
      const entityType = emailEntityType(body.entityType);
      if (typeof body.entityId !== "string" || !isUuid(body.entityId)) {
        throw new SafeEmailError("validation_failed");
      }
      let reviewedPayload: Readonly<Record<string, unknown>>;
      try {
        reviewedPayload = validateCandidateObject(body.reviewedPayload);
      } catch {
        throw new SafeEmailError("validation_failed");
      }
      if (reviewedPayload.candidate_type !== entityType) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "reconcile_confirmation",
        connectionId: body.connectionId as string,
        provider: "gmail",
        providerAccountHash: body.providerAccountHash as string,
        providerMessageIdHash: body.providerMessageIdHash as string,
        providerThreadIdHash: body.providerThreadIdHash as string,
        sanitizedContentHash: body.sanitizedContentHash as string,
        reviewedPayload,
        entityType,
        entityId: body.entityId,
        idempotencyKey: body.idempotencyKey as string,
      };
    }
    case "reconcile_dismissal":
      exactKeys(body, new Set(reconciliationIdentityKeys));
      validateReconciliationIdentity(body);
      return {
        action: "reconcile_dismissal",
        connectionId: body.connectionId as string,
        provider: "gmail",
        providerAccountHash: body.providerAccountHash as string,
        providerMessageIdHash: body.providerMessageIdHash as string,
        providerThreadIdHash: body.providerThreadIdHash as string,
        sanitizedContentHash: body.sanitizedContentHash as string,
        idempotencyKey: body.idempotencyKey as string,
      };
    case "reconcile_update": {
      exactKeys(
        body,
        new Set([
          ...reconciliationIdentityKeys,
          "resolution",
          "entityType",
          "entityId",
        ]),
      );
      validateReconciliationIdentity(body);
      const entityType = emailEntityType(body.entityType);
      if (
        (body.resolution !== "accepted" && body.resolution !== "rejected") ||
        typeof body.entityId !== "string" || !isUuid(body.entityId)
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "reconcile_update",
        connectionId: body.connectionId as string,
        provider: "gmail",
        providerAccountHash: body.providerAccountHash as string,
        providerMessageIdHash: body.providerMessageIdHash as string,
        providerThreadIdHash: body.providerThreadIdHash as string,
        sanitizedContentHash: body.sanitizedContentHash as string,
        resolution: body.resolution,
        entityType,
        entityId: body.entityId,
        idempotencyKey: body.idempotencyKey as string,
      };
    }
    case "disconnect":
      exactKeys(
        body,
        new Set([
          "action",
          "connectionId",
          "deleteDerivedData",
        ]),
      );
      if (
        typeof body.connectionId !== "string" || !isUuid(body.connectionId) ||
        typeof body.deleteDerivedData !== "boolean"
      ) {
        throw new SafeEmailError("validation_failed");
      }
      return {
        action: "disconnect",
        connectionId: body.connectionId,
        deleteDerivedData: body.deleteDerivedData,
      };
    case "delete_account_data":
      exactKeys(body, new Set(["action"]));
      return { action: "delete_account_data" };
    default:
      throw new SafeEmailError("validation_failed");
  }
}

function statusForResult(result: EmailIngestionResult): number {
  return result.connection.status === "rate_limited"
    ? 429
    : result.connection.status === "reauth_required"
    ? 401
    : 503;
}

function failureCategory(result: EmailIngestionResult): EmailErrorCategory {
  if (result.connection.status === "rate_limited") return "rate_limited";
  if (result.connection.status === "reauth_required") {
    return "authorization_revoked";
  }
  return result.connection.errorCategory ?? "internal_error";
}

async function assertSuppressionPageDisjoint(
  page: {
    readonly items: readonly { readonly providerMessageId: string }[];
    readonly suppressions: readonly {
      readonly providerMessageIdHash: string;
    }[];
  },
  providerAccountHash: string,
): Promise<void> {
  const itemHashes = new Set(
    await Promise.all(
      page.items.map((item) =>
        providerMessageIdentifierHash(
          providerAccountHash,
          item.providerMessageId,
        )
      ),
    ),
  );
  const suppressionHashes = new Set(
    page.suppressions.map((suppression) => suppression.providerMessageIdHash),
  );
  if (
    itemHashes.size !== page.items.length ||
    suppressionHashes.size !== page.suppressions.length ||
    page.suppressions.some((suppression) =>
      itemHashes.has(suppression.providerMessageIdHash)
    )
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
}

async function assertCommittedPagePartition(
  page: {
    readonly items: readonly { readonly providerMessageId: string }[];
    readonly suppressions: readonly {
      readonly providerMessageIdHash: string;
    }[];
  },
  providerAccountHash: string,
  expectedProviderMessageIds: readonly string[],
): Promise<void> {
  await assertSuppressionPageDisjoint(page, providerAccountHash);
  const expectedHashes = new Set(
    await Promise.all(
      expectedProviderMessageIds.map((providerMessageId) =>
        providerMessageIdentifierHash(
          providerAccountHash,
          providerMessageId,
        )
      ),
    ),
  );
  const committedHashes = new Set([
    ...await Promise.all(
      page.items.map((item) =>
        providerMessageIdentifierHash(
          providerAccountHash,
          item.providerMessageId,
        )
      ),
    ),
    ...page.suppressions.map((suppression) =>
      suppression.providerMessageIdHash
    ),
  ]);
  if (
    expectedHashes.size !== expectedProviderMessageIds.length ||
    page.items.length + page.suppressions.length !==
      expectedProviderMessageIds.length ||
    committedHashes.size !== expectedHashes.size ||
    [...committedHashes].some((hash) => !expectedHashes.has(hash))
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
}

async function handleFetch(
  body: EmailImportRequestBody,
  ownerUserId: string,
  correlationId: string,
  dependencies: EmailImportEndpointDependencies,
): Promise<Response> {
  const connectionId = body.connectionId!;
  const record = await dependencies.store.getCredentials(
    ownerUserId,
    connectionId,
  );
  if (record === null) throw new SafeEmailError("authorization_revoked");
  if (body.cursor !== record.syncCursor) {
    const replay = await dependencies.store.getSyncReplay({
      ownerUserId,
      connectionId,
      expectedCursor: body.cursor ?? null,
    });
    if (replay === null) throw new SafeEmailError("cursor_expired");
    await assertSuppressionPageDisjoint(replay, record.providerAccountHash);
    return jsonResponse(200, {
      connection: connectionState("connected", {
        connectedAt: replay.connectedAt ?? record.connectedAt,
      }),
      page: {
        items: replay.items,
        suppressions: replay.suppressions,
        nextCursor: replay.nextCursor,
        hasMore: replay.hasMore,
      },
    });
  }
  const credentials = dependencies.createCredentials({
    ownerUserId,
    correlationId,
    record,
  });
  const ownerTimezone = await dependencies.store.getOwnerTimezone({
    ownerUserId,
    connectionId,
  }) ?? dependencies.configuration.timezone;
  const result = await runIncrementalEmailIngestion(
    dependencies.createConnector(credentials),
    {
      cursor: record.syncCursor,
      maximumMessages: 100,
      extraction: {
        extractor: dependencies.extractor,
        timezone: ownerTimezone,
      },
    },
    {
      now: dependencies.runtime.now,
      sleep: dependencies.runtime.sleep,
      jitter: dependencies.runtime.jitter,
    },
  );
  if (result.connection.status !== "connected") {
    const category = failureCategory(result);
    const retryAfterAt = result.connection.retryAfterSeconds === null
      ? null
      : new Date(
        dependencies.runtime.now().getTime() +
          result.connection.retryAfterSeconds * 1_000,
      ).toISOString();
    await dependencies.store.recordFailure({
      ownerUserId,
      connectionId,
      operation: "fetch",
      connectionState: result.connection.status,
      errorCategory: category,
      retryAfterAt,
      occurredAt: dependencies.runtime.now().toISOString(),
      correlationId,
    }).catch(() => null);
    dependencies.runtime.audit({
      correlationId,
      action: "sync",
      state: result.connection.status,
      category,
    });
    return jsonResponse(statusForResult(result), {
      connection: {
        ...result.connection,
        connectedAt: record.connectedAt,
      },
      page: null,
    });
  }
  // A cursor is also the normal-sync replay key. Gmail can leave its own
  // history high-water unchanged on an empty poll, but the connector advances
  // an opaque application generation so every committed response has a unique
  // predecessor key. Fail closed for any connector that violates that rule.
  if (
    result.nextCursor === null || result.nextCursor === record.syncCursor
  ) {
    throw new SafeEmailError("provider_unavailable");
  }

  const rpcRows = safeSourceRpcRows(
    result.sources,
    result.items.map((item) => ({
      providerMessageId: item.providerMessageId,
      candidate: item.candidate,
      errorCategory: item.errorCategory,
    })),
  );
  const persisted = await dependencies.store.persistSyncPage({
    ownerUserId,
    connectionId,
    expectedCursor: record.syncCursor,
    nextCursor: result.nextCursor,
    sources: rpcRows.sources,
    candidates: rpcRows.candidates,
    hasMore: result.hasMore,
    syncedAt: dependencies.runtime.now().toISOString(),
    correlationId,
  });
  const committedPage = persisted.page;
  await assertCommittedPagePartition(
    committedPage,
    record.providerAccountHash,
    result.sources.map((source) => source.provider_message_id),
  );
  dependencies.runtime.audit({
    correlationId,
    action: "sync",
    state: "connected",
    category: null,
  });
  return jsonResponse(200, {
    connection: connectionState("connected", {
      connectedAt: persisted.connection.connectedAt ?? record.connectedAt,
    }),
    page: {
      items: committedPage.items,
      suppressions: committedPage.suppressions,
      nextCursor: committedPage.nextCursor,
      hasMore: committedPage.hasMore,
    },
  });
}

async function handleRetryCandidate(
  body: EmailImportRequestBody,
  ownerUserId: string,
  correlationId: string,
  dependencies: EmailImportEndpointDependencies,
): Promise<Response> {
  const connectionId = body.connectionId!;
  const providerMessageId = body.providerMessageId!;
  const expectedSanitizedContentHash = body.expectedSanitizedContentHash!;
  const retryIdempotencyKey = body.retryIdempotencyKey!;
  const replay = await dependencies.store.getRetryReplay({
    ownerUserId,
    connectionId,
    providerMessageId,
    expectedSanitizedContentHash,
    retryIdempotencyKey,
  });
  if (replay !== null) {
    if (replay.suppression !== null) {
      const replayRecord = await dependencies.store.getCredentials(
        ownerUserId,
        connectionId,
      );
      if (replayRecord === null) {
        throw new SafeEmailError("authorization_revoked");
      }
      if (
        replay.suppression.providerMessageIdHash !==
          await providerMessageIdentifierHash(
            replayRecord.providerAccountHash,
            providerMessageId,
          )
      ) {
        throw new SafeEmailError("provider_unavailable");
      }
    }
    return jsonResponse(200, {
      connection: connectionState("connected", {
        connectedAt: replay.connectedAt,
      }),
      page: {
        items: replay.item === null ? [] : [replay.item],
        suppressions: replay.suppression === null ? [] : [replay.suppression],
        nextCursor: null,
        hasMore: false,
      },
      retryOutcome: replay.retryOutcome,
    });
  }
  await dependencies.store.assertRetryCandidate({
    ownerUserId,
    connectionId,
    providerMessageId,
    expectedSanitizedContentHash,
  });
  const record = await dependencies.store.getCredentials(
    ownerUserId,
    connectionId,
  );
  if (record === null) throw new SafeEmailError("authorization_revoked");
  const credentials = dependencies.createCredentials({
    ownerUserId,
    correlationId,
    record,
  });
  const connector = dependencies.createConnector(credentials);
  if (connector.fetchMessage === undefined) {
    throw new SafeEmailError("provider_unavailable");
  }
  const ownerTimezone = await dependencies.store.getOwnerTimezone({
    ownerUserId,
    connectionId,
  }) ?? dependencies.configuration.timezone;
  const processed = await processProviderEmailMessage(
    await connector.fetchMessage(providerMessageId),
    { extractor: dependencies.extractor, timezone: ownerTimezone },
  );
  if (processed.item === null) throw new SafeEmailError("internal_error");
  const rpcRows = safeSourceRpcRows(
    [processed.source],
    [{
      providerMessageId: processed.item.providerMessageId,
      candidate: processed.item.candidate,
      errorCategory: processed.item.errorCategory,
    }],
  );
  const persisted = await dependencies.store.persistRetryCandidate({
    ownerUserId,
    connectionId,
    sources: rpcRows.sources,
    candidates: rpcRows.candidates,
    expectedSanitizedContentHash,
    retryIdempotencyKey,
    retriedAt: dependencies.runtime.now().toISOString(),
    correlationId,
  });
  await assertSuppressionPageDisjoint(
    {
      items: persisted.item === null ? [] : [persisted.item],
      suppressions: persisted.suppression === null
        ? []
        : [persisted.suppression],
    },
    record.providerAccountHash,
  );
  if (
    persisted.suppression !== null &&
    persisted.suppression.providerMessageIdHash !==
      await providerMessageIdentifierHash(
        record.providerAccountHash,
        providerMessageId,
      )
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
  dependencies.runtime.audit({
    correlationId,
    action: "retry_candidate",
    state: persisted.retryOutcome === "suppressed"
      ? "suppressed"
      : persisted.item!.errorCategory === null
      ? "succeeded"
      : "failed",
    category: persisted.item?.errorCategory ?? null,
  });
  return jsonResponse(200, {
    connection: connectionState("connected", {
      connectedAt: persisted.connection.connectedAt ?? record.connectedAt,
    }),
    page: {
      items: persisted.item === null ? [] : [persisted.item],
      suppressions: persisted.suppression === null
        ? []
        : [persisted.suppression],
      nextCursor: null,
      hasMore: false,
    },
    retryOutcome: persisted.retryOutcome,
  });
}

function reconciliationResponse(
  result: PersistedReconciliation,
  request: {
    readonly connectionId: string;
    readonly idempotencyKey: string;
  },
): Response {
  return jsonResponse(200, {
    connection: connectionState(result.connectionState),
    page: null,
    reconciliation: {
      connectionId: request.connectionId,
      idempotencyKey: request.idempotencyKey,
      action: result.action,
      outcome: result.outcome,
      entityType: result.entityType,
      entityId: result.entityId,
      replayed: result.replayed,
    },
  });
}

function assertReconciliationAcknowledgement(
  body: EmailImportRequestBody,
  result: PersistedReconciliation,
): void {
  const expectedAction = body.action === "reconcile_confirmation"
    ? "confirmation"
    : body.action === "reconcile_dismissal"
    ? "dismissal"
    : "update";
  const expectedOutcome = body.action === "reconcile_confirmation"
    ? "confirmed"
    : body.action === "reconcile_dismissal"
    ? "dismissed"
    : body.resolution;
  const expectedEntityType = body.action === "reconcile_dismissal"
    ? null
    : body.entityType;
  const expectedEntityId = body.action === "reconcile_dismissal"
    ? null
    : body.entityId;
  if (
    result.connectionId !== body.connectionId ||
    result.action !== expectedAction ||
    result.outcome !== expectedOutcome ||
    result.entityType !== expectedEntityType ||
    result.entityId !== expectedEntityId
  ) {
    throw new SafeEmailError("provider_unavailable");
  }
}

async function handleReconciliation(
  body: EmailImportRequestBody,
  ownerUserId: string,
  correlationId: string,
  dependencies: EmailImportEndpointDependencies,
): Promise<Response> {
  const common = {
    ownerUserId,
    connectionId: body.connectionId!,
    provider: body.provider!,
    providerAccountHash: body.providerAccountHash!,
    providerMessageIdHash: body.providerMessageIdHash!,
    providerThreadIdHash: body.providerThreadIdHash!,
    sanitizedContentHash: body.sanitizedContentHash!,
    idempotencyKey: body.idempotencyKey!,
    reconciledAt: dependencies.runtime.now().toISOString(),
    correlationId,
  } as const;
  const result = body.action === "reconcile_confirmation"
    ? await dependencies.store.reconcileConfirmation({
      ...common,
      reviewedPayload: body.reviewedPayload!,
      entityType: body.entityType!,
      entityId: body.entityId!,
    })
    : body.action === "reconcile_dismissal"
    ? await dependencies.store.reconcileDismissal(common)
    : await dependencies.store.reconcileUpdate({
      ...common,
      resolution: body.resolution!,
      entityType: body.entityType!,
      entityId: body.entityId!,
    });
  assertReconciliationAcknowledgement(body, result);
  dependencies.runtime.audit({
    correlationId,
    action: result.action === "confirmation"
      ? "reconcile_confirmation"
      : result.action === "dismissal"
      ? "reconcile_dismissal"
      : "reconcile_update",
    state: result.outcome,
    category: null,
  });
  return reconciliationResponse(result, {
    connectionId: body.connectionId!,
    idempotencyKey: body.idempotencyKey!,
  });
}

async function handleDisconnect(
  body: EmailImportRequestBody,
  ownerUserId: string,
  correlationId: string,
  dependencies: EmailImportEndpointDependencies,
): Promise<Response> {
  const connectionId = body.connectionId!;
  const record = await dependencies.store.getCredentials(
    ownerUserId,
    connectionId,
  );
  let attempted = record !== null;
  let revoked = false;
  if (record !== null) {
    try {
      const credentials = dependencies.createCredentials({
        ownerUserId,
        correlationId,
        record,
      });
      revoked = await dependencies.google.revoke(
        await credentials.revocationToken(),
      );
    } catch {
      attempted = true;
      revoked = false;
    }
  }
  const persisted = await dependencies.store.finalizeDisconnect({
    ownerUserId,
    connectionId,
    deleteDerivedData: body.deleteDerivedData!,
    revocationAttempted: attempted,
    revocationSucceeded: revoked,
    disconnectedAt: dependencies.runtime.now().toISOString(),
    correlationId,
  });
  dependencies.runtime.audit({
    correlationId,
    action: "disconnect",
    state: "disconnected",
    category: attempted && !revoked ? "provider_unavailable" : null,
  });
  return jsonResponse(200, {
    connection: stateFromPersisted(persisted),
    page: null,
  });
}

async function revokeOwnedConnectionsBeforeAccountDeletion(
  ownerUserId: string,
  correlationId: string,
  dependencies: EmailImportEndpointDependencies,
): Promise<void> {
  let connectionIds: readonly string[];
  try {
    connectionIds = await dependencies.store.listOwnedConnectionIds(
      ownerUserId,
    );
  } catch (rawError) {
    dependencies.runtime.audit({
      correlationId,
      action: "delete_account_data",
      state: "revocation_lookup_failed",
      category: "provider_unavailable",
    });
    throw rawError instanceof SafeEmailError
      ? rawError
      : new SafeEmailError("provider_unavailable");
  }
  for (const connectionId of connectionIds) {
    let state = "revocation_not_required";
    let category: EmailErrorCategory | null = null;
    try {
      const record = await dependencies.store.getCredentials(
        ownerUserId,
        connectionId,
      );
      if (record !== null) {
        const credentials = dependencies.createCredentials({
          ownerUserId,
          correlationId,
          record,
        });
        const revoked = await dependencies.google.revoke(
          await credentials.revocationToken(),
        );
        state = revoked ? "revocation_succeeded" : "revocation_failed";
        category = revoked ? null : "provider_unavailable";
      }
    } catch (rawError) {
      state = "revocation_failed";
      category = rawError instanceof SafeEmailError
        ? rawError.category
        : "provider_unavailable";
    }
    dependencies.runtime.audit({
      correlationId,
      action: "delete_account_data",
      state,
      category,
    });
  }
}

async function handleCallback(
  request: Request,
  dependencies: EmailImportEndpointDependencies,
): Promise<Response> {
  const incoming = new URL(request.url);
  const configured = dependencies.configuration.gmailRedirectUri;
  if (
    incoming.origin !== configured.origin ||
    incoming.pathname !== configured.pathname
  ) {
    return jsonResponse(405, { error: "Method not allowed." });
  }
  let correlationId = dependencies.runtime.randomUuid();
  let category: EmailErrorCategory | null = null;
  let outcome: "connected" | "failed" = "failed";
  let requestedConnectionId: string | null = null;
  try {
    const state = incoming.searchParams.get("state");
    if (state === null) throw new SafeEmailError("validation_failed");
    const providerError = incoming.searchParams.get("error");
    if (providerError !== null) {
      category = providerError === "access_denied"
        ? "authorization_revoked"
        : "provider_unavailable";
      const failed = await dependencies.oauth.fail(state, category);
      correlationId = failed.correlationId;
      requestedConnectionId = failed.requestedConnectionId;
    } else {
      const code = incoming.searchParams.get("code");
      if (code === null) throw new SafeEmailError("validation_failed");
      const completed = await dependencies.oauth.complete(state, code);
      correlationId = completed.correlationId;
      requestedConnectionId = completed.requestedConnectionId;
      outcome = "connected";
    }
  } catch (rawError) {
    if (rawError instanceof OAuthCompletionFailure) {
      correlationId = rawError.correlationId;
      requestedConnectionId = rawError.requestedConnectionId;
    }
    const error = rawError instanceof SafeEmailError
      ? rawError
      : new SafeEmailError("internal_error");
    category = error.category;
  }
  return new Response(null, {
    status: 303,
    headers: {
      location: safeAppRedirect(
        dependencies.configuration.appRedirectUri,
        outcome,
        correlationId,
        category,
        requestedConnectionId,
      ),
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

export async function handleRequest(
  request: Request,
  readEnvironment: (name: string) => string | undefined = (name) =>
    Deno.env.get(name),
  dependencyFactory: EndpointDependencyFactory = createProductionDependencies,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "access-control-allow-headers":
          "authorization, apikey, content-type, x-client-info",
        "access-control-allow-methods": "GET, POST, OPTIONS",
        "access-control-max-age": "600",
      },
    });
  }
  if (request.method !== "POST" && request.method !== "GET") {
    return jsonResponse(405, { error: "Method not allowed." });
  }
  if (
    request.method === "GET" &&
    !new URL(request.url).searchParams.has("state")
  ) {
    return jsonResponse(405, { error: "Method not allowed." });
  }

  const readiness = productionReadiness(readEnvironment);
  if (!readiness.enabled) {
    return jsonResponse(404, { connection: disconnectedState(), page: null });
  }
  if (!readiness.configured) {
    return jsonResponse(503, {
      connection: failedConfigurationState(),
      page: null,
    });
  }

  let dependencies: EmailImportEndpointDependencies;
  try {
    dependencies = dependencyFactory(
      parseProductionConfiguration(readEnvironment),
    );
  } catch {
    return jsonResponse(503, {
      connection: failedConfigurationState(),
      page: null,
    });
  }

  if (request.method === "GET") {
    return handleCallback(request, dependencies);
  }

  const correlationId = dependencies.runtime.randomUuid();
  try {
    if (!isUuid(correlationId)) throw new SafeEmailError("internal_error");
    const caller = await dependencies.authenticator.authenticate(request);
    dependencies.runtime.audit({
      correlationId,
      action: "authenticate",
      state: "authenticated",
      category: null,
    });
    const body = await requestBody(request);
    switch (body.action) {
      case "connect": {
        const started = await dependencies.oauth.start(
          caller.ownerUserId,
          body.connectionId ?? null,
          correlationId,
        );
        dependencies.runtime.audit({
          correlationId,
          action: "oauth_start",
          state: "connecting",
          category: null,
        });
        return jsonResponse(200, {
          connection: connectionState("connecting"),
          page: null,
          oauth: {
            authorizationUri: started.authorizationUri,
            codeChallenge: started.codeChallenge,
            expiresAt: started.expiresAt,
          },
        });
      }
      case "fetch_delta":
        return await handleFetch(
          body,
          caller.ownerUserId,
          correlationId,
          dependencies,
        );
      case "retry_candidate":
        return await handleRetryCandidate(
          body,
          caller.ownerUserId,
          correlationId,
          dependencies,
        );
      case "check_authorization": {
        const resolution = await dependencies.store.checkAuthorization({
          ownerUserId: caller.ownerUserId,
          requestedConnectionId: body.connectionId!,
          callbackCorrelationId: body.callbackCorrelationId!,
        });
        if (
          resolution === null ||
          resolution.requestedConnectionId !== body.connectionId
        ) {
          throw new SafeEmailError("validation_failed");
        }
        return jsonResponse(200, {
          connection: stateFromAuthorization(
            resolution,
            dependencies.runtime.now(),
          ),
          page: null,
          authorization: {
            effectiveConnectionId: resolution.effectiveConnectionId,
          },
        });
      }
      case "reconcile_confirmation":
      case "reconcile_dismissal":
      case "reconcile_update":
        return await handleReconciliation(
          body,
          caller.ownerUserId,
          correlationId,
          dependencies,
        );
      case "disconnect":
        return await handleDisconnect(
          body,
          caller.ownerUserId,
          correlationId,
          dependencies,
        );
      case "delete_account_data":
        await revokeOwnedConnectionsBeforeAccountDeletion(
          caller.ownerUserId,
          correlationId,
          dependencies,
        );
        await dependencies.store.deleteAccountData({
          ownerUserId: caller.ownerUserId,
          deletedAt: dependencies.runtime.now().toISOString(),
          correlationId,
        });
        dependencies.runtime.audit({
          correlationId,
          action: "delete_account_data",
          state: "deleted",
          category: null,
        });
        return jsonResponse(200, {
          connection: disconnectedState(),
          page: null,
        });
    }
  } catch (rawError) {
    const error = rawError instanceof SafeEmailError
      ? rawError
      : new SafeEmailError("internal_error");
    const failure = endpointError(error);
    return jsonResponse(failure.status, {
      connection: failure.connection,
      page: null,
    });
  }
}

if (import.meta.main) {
  Deno.serve((request) => handleRequest(request));
}
