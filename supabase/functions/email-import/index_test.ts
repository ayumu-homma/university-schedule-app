import {
  createProductionDependencies,
  type EmailImportEndpointDependencies,
  handleRequest,
  productionReadiness,
} from "./index.ts";
import type { EmailTaskExtractor } from "./extraction.ts";
import type {
  GoogleOAuthClient,
  OAuthStartResult,
  PersistedAuthorizationResolution,
  PersistedConnection,
  PersistedReconciliation,
  ProductionConfiguration,
  ProductionRuntime,
  SafeAuditEvent,
  StoredCredentials,
  TrustedEmailStore,
} from "./production.ts";
import {
  OAuthCompletionFailure,
  parseProductionConfiguration,
  providerMessageIdentifierHash,
} from "./production.ts";
import {
  type EmailProviderConnector,
  gmailReadOnlyScope,
  SafeEmailError,
} from "./types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const ownerUserId = "a5111111-1111-4111-8111-111111111111";
const connectionId = "e5111111-1111-4111-8111-111111111111";
const secondConnectionId = "e5222222-2222-4222-8222-222222222222";
const correlationId = "c5111111-1111-4111-8111-111111111111";
const safeCursor = "safe-cursor";
const completeConfiguration: Readonly<Record<string, string>> = {
  EMAIL_IMPORT_ENABLED: "true",
  EMAIL_IMPORT_MODEL_ENABLED: "true",
  SUPABASE_URL: "https://project.example.invalid/",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-secret-marker",
  GMAIL_OAUTH_CLIENT_ID: "gmail-client-id-marker",
  GMAIL_OAUTH_CLIENT_SECRET: "gmail-client-secret-marker",
  GMAIL_OAUTH_REDIRECT_URI:
    "https://project.example.invalid/functions/v1/email-import",
  EMAIL_IMPORT_APP_REDIRECT_URI: "unischedule://email-import-callback",
  EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY:
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY_VERSION: "1",
  EMAIL_IMPORT_ACCOUNT_HASH_KEY: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
  EMAIL_IMPORT_MODEL_ID: "safe-model-id",
  OPENAI_API_KEY: "model-api-secret-marker",
};

function reader(values: Readonly<Record<string, string>>) {
  return (name: string): string | undefined => values[name];
}

function candidate(): Readonly<Record<string, unknown>> {
  return {
    schema_version: "1.0",
    candidate_type: "assignment",
    title: "レポート",
    course_hint: { name: "情報", code: null },
    due: {
      at: "2026-07-30T14:00:00.000Z",
      all_day: false,
      timezone: "Asia/Tokyo",
      raw_text: "7月30日23時",
    },
    start_at: null,
    end_at: null,
    location: null,
    submission_url: null,
    summary: null,
    suggested_reminders_minutes: [60],
    confidence: { overall: 0.9, title: 0.9, course: 0.8, date_time: 0.9 },
    evidence: [{ field: "title", text: "レポート" }],
    warnings: [],
    requires_user_confirmation: true,
  };
}

function storedCredentials(id = connectionId): StoredCredentials {
  return {
    connectionId: id,
    providerAccountHash: "1".repeat(64),
    connectionState: "connected",
    syncCursor: null,
    connectedAt: "2026-07-22T00:00:00.000Z",
    encryptedOauthBundle: new Uint8Array([1, ...new Uint8Array(29)]),
    encryptionKeyVersion: 1,
    credentialVersion: 1,
    expiresAt: "2026-07-22T01:00:00.000Z",
  };
}

function persisted(
  status: PersistedConnection["connectionState"],
): PersistedConnection {
  return {
    connectionId,
    connectionState: status,
    syncCursor: safeCursor,
    connectedAt: status === "connected" ? "2026-07-22T00:00:00.000Z" : null,
    lastSyncedAt: "2026-07-22T00:10:00.000Z",
  };
}

class StubStore implements TrustedEmailStore {
  credentials: StoredCredentials | null = storedCredentials();
  ownedConnectionIds: readonly string[] = [connectionId];
  credentialRequests: string[] = [];
  credentialReadsAtDelete = 0;
  listFailure: SafeEmailError | null = null;
  persistedInput: Parameters<TrustedEmailStore["persistSyncPage"]>[0] | null =
    null;
  syncReplayOverride:
    | Awaited<ReturnType<TrustedEmailStore["getSyncReplay"]>>
    | undefined = undefined;
  confirmationInput:
    | Parameters<TrustedEmailStore["reconcileConfirmation"]>[0]
    | null = null;
  dismissalInput:
    | Parameters<TrustedEmailStore["reconcileDismissal"]>[0]
    | null = null;
  updateInput: Parameters<TrustedEmailStore["reconcileUpdate"]>[0] | null =
    null;
  reconciliationOverride: PersistedReconciliation | null = null;
  failureInput: Parameters<TrustedEmailStore["recordFailure"]>[0] | null = null;
  authorizationInput:
    | Parameters<TrustedEmailStore["checkAuthorization"]>[0]
    | null = null;
  authorizationOverride: PersistedAuthorizationResolution | null = {
    requestedConnectionId: connectionId,
    effectiveConnectionId: connectionId,
    connectionState: "connected",
    errorCategory: null,
    retryAfterAt: null,
    connectedAt: "2026-07-22T00:00:00.000Z",
  };
  disconnectInput:
    | Parameters<TrustedEmailStore["finalizeDisconnect"]>[0]
    | null = null;
  deletedOwner: string | null = null;
  retryReplayOverride: Awaited<
    ReturnType<TrustedEmailStore["getRetryReplay"]>
  > = null;
  retryReplayInput:
    | Parameters<TrustedEmailStore["getRetryReplay"]>[0]
    | null = null;
  retryAssertionInput:
    | Parameters<TrustedEmailStore["assertRetryCandidate"]>[0]
    | null = null;
  retryAssertionError: SafeEmailError | null = null;
  retryPersistedInput:
    | Parameters<TrustedEmailStore["persistRetryCandidate"]>[0]
    | null = null;
  retryPersistedOverride:
    | Awaited<
      ReturnType<TrustedEmailStore["persistRetryCandidate"]>
    >
    | null = null;

  beginOauth(): Promise<void> {
    return Promise.resolve();
  }
  takeOauth(): Promise<null> {
    return Promise.resolve(null);
  }
  completeOauth(): Promise<PersistedConnection> {
    return Promise.resolve(persisted("connected"));
  }
  checkAuthorization(
    input: Parameters<TrustedEmailStore["checkAuthorization"]>[0],
  ): Promise<PersistedAuthorizationResolution | null> {
    this.authorizationInput = input;
    return Promise.resolve(this.authorizationOverride);
  }
  getCredentials(
    owner: string,
    requestedConnection: string,
  ): Promise<StoredCredentials | null> {
    assert(owner === ownerUserId, "owner is bound from auth");
    this.credentialRequests.push(requestedConnection);
    return Promise.resolve(
      this.credentials === null
        ? null
        : { ...this.credentials, connectionId: requestedConnection },
    );
  }
  rotateCredentials(): Promise<number> {
    return Promise.resolve(2);
  }
  persistSyncPage(
    input: Parameters<TrustedEmailStore["persistSyncPage"]>[0],
  ) {
    this.persistedInput = input;
    return this.getSyncReplay({
      ownerUserId: input.ownerUserId,
      connectionId: input.connectionId,
      expectedCursor: input.expectedCursor,
    }).then((page) => ({
      connection: persisted("connected"),
      page: page!,
    }));
  }
  getSyncReplay(
    input: Parameters<TrustedEmailStore["getSyncReplay"]>[0],
  ) {
    if (this.syncReplayOverride !== undefined) {
      return Promise.resolve(this.syncReplayOverride);
    }
    const page = this.persistedInput;
    if (page === null || page.expectedCursor !== input.expectedCursor) {
      return Promise.resolve(null);
    }
    return Promise.resolve({
      items: page.sources.map((source) => {
        const candidateRow = page.candidates.find((candidate) =>
          candidate.provider_message_id === source.provider_message_id
        )!;
        return {
          providerMessageId: source.provider_message_id as string,
          providerThreadId: source.provider_thread_id as string,
          receivedAt: source.received_at as string,
          sanitizedContentHash: source.sanitized_content_hash as string,
          evidenceExcerpts: source.evidence_metadata as readonly string[],
          candidate: candidateRow.validated_payload as
            | Readonly<
              Record<string, unknown>
            >
            | null,
          errorCategory: candidateRow.error_category as null,
        };
      }),
      suppressions: [],
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
      connectedAt: "2026-07-22T00:00:00.000Z",
    });
  }
  getOwnerTimezone(): Promise<string | null> {
    return Promise.resolve("Asia/Tokyo");
  }
  getRetryReplay(
    input: Parameters<TrustedEmailStore["getRetryReplay"]>[0],
  ) {
    this.retryReplayInput = input;
    return Promise.resolve(this.retryReplayOverride);
  }
  assertRetryCandidate(
    input: Parameters<TrustedEmailStore["assertRetryCandidate"]>[0],
  ): Promise<void> {
    this.retryAssertionInput = input;
    return this.retryAssertionError === null
      ? Promise.resolve()
      : Promise.reject(this.retryAssertionError);
  }
  persistRetryCandidate(
    input: Parameters<TrustedEmailStore["persistRetryCandidate"]>[0],
  ) {
    this.retryPersistedInput = input;
    if (this.retryPersistedOverride !== null) {
      return Promise.resolve(this.retryPersistedOverride);
    }
    const source = input.sources[0]!;
    const candidateRow = input.candidates[0]!;
    return Promise.resolve({
      connection: persisted("connected"),
      retryOutcome: "persisted" as const,
      item: {
        providerMessageId: source.provider_message_id as string,
        providerThreadId: source.provider_thread_id as string,
        receivedAt: source.received_at as string,
        sanitizedContentHash: source.sanitized_content_hash as string,
        evidenceExcerpts: source.evidence_metadata as readonly string[],
        candidate: candidateRow.validated_payload as
          | Readonly<
            Record<string, unknown>
          >
          | null,
        errorCategory: candidateRow.error_category as null,
      },
      suppression: null,
    });
  }
  reconcileConfirmation(
    input: Parameters<TrustedEmailStore["reconcileConfirmation"]>[0],
  ) {
    this.confirmationInput = input;
    return Promise.resolve(
      this.reconciliationOverride ?? {
        connectionId,
        connectionState: "connected" as const,
        action: "confirmation" as const,
        outcome: "confirmed" as const,
        entityType: input.entityType,
        entityId: input.entityId,
        replayed: false,
      },
    );
  }
  reconcileDismissal(
    input: Parameters<TrustedEmailStore["reconcileDismissal"]>[0],
  ) {
    this.dismissalInput = input;
    return Promise.resolve(
      this.reconciliationOverride ?? {
        connectionId,
        connectionState: "connected" as const,
        action: "dismissal" as const,
        outcome: "dismissed" as const,
        entityType: null,
        entityId: null,
        replayed: false,
      },
    );
  }
  reconcileUpdate(
    input: Parameters<TrustedEmailStore["reconcileUpdate"]>[0],
  ) {
    this.updateInput = input;
    return Promise.resolve(
      this.reconciliationOverride ?? {
        connectionId,
        connectionState: "connected" as const,
        action: "update" as const,
        outcome: input.resolution,
        entityType: input.entityType,
        entityId: input.entityId,
        replayed: false,
      },
    );
  }
  finalizeDisconnect(
    input: Parameters<TrustedEmailStore["finalizeDisconnect"]>[0],
  ): Promise<PersistedConnection> {
    this.disconnectInput = input;
    return Promise.resolve(persisted("disconnected"));
  }
  listOwnedConnectionIds(owner: string): Promise<readonly string[]> {
    assert(owner === ownerUserId, "deletion listing is owner bound");
    if (this.listFailure !== null) return Promise.reject(this.listFailure);
    return Promise.resolve(this.ownedConnectionIds);
  }
  deleteAccountData(
    input: Parameters<TrustedEmailStore["deleteAccountData"]>[0],
  ): Promise<Readonly<Record<string, number>>> {
    this.deletedOwner = input.ownerUserId;
    this.credentialReadsAtDelete = this.credentialRequests.length;
    return Promise.resolve({
      deleted_connections: 1,
      deleted_sources: 1,
      deleted_candidates: 1,
      deleted_updates: 0,
    });
  }
  recordFailure(
    input: Parameters<TrustedEmailStore["recordFailure"]>[0],
  ): Promise<PersistedConnection | null> {
    this.failureInput = input;
    return Promise.resolve(persisted(input.connectionState));
  }
}

class StubGoogle implements GoogleOAuthClient {
  revokedToken: string | null = null;
  revokedTokens: string[] = [];
  revokeResult = true;
  revokeResults: boolean[] = [];
  exchangeCode(): never {
    throw new Error("not used by endpoint stub");
  }
  refreshToken(): never {
    throw new Error("not used by endpoint stub");
  }
  revoke(token: string): Promise<boolean> {
    this.revokedToken = token;
    this.revokedTokens.push(token);
    return Promise.resolve(this.revokeResults.shift() ?? this.revokeResult);
  }
  profile(): never {
    throw new Error("not used by endpoint stub");
  }
}

function successfulConnector(): EmailProviderConnector {
  return {
    provider: "gmail",
    fetchPage: () =>
      Promise.resolve({
        messages: [{
          providerMessageId: "message-1",
          providerThreadId: "thread-1",
          receivedAt: "2026-07-22T00:05:00.000Z",
          subject: "レポート",
          sender: "大学事務",
          body: "7月30日23時までに提出してください。",
          bodyKind: "text",
        }],
        nextCursor: safeCursor,
        hasMore: false,
      }),
  };
}

function makeDependencies(configuration: ProductionConfiguration): {
  readonly dependencies: EmailImportEndpointDependencies;
  readonly audits: SafeAuditEvent[];
  readonly store: StubStore;
  readonly google: StubGoogle;
  readonly oauthCalls: string[];
} {
  const audits: SafeAuditEvent[] = [];
  const store = new StubStore();
  const google = new StubGoogle();
  const oauthCalls: string[] = [];
  const runtime: ProductionRuntime = {
    fetch: () => Promise.reject(new Error("unexpected network")),
    now: () => new Date("2026-07-22T00:10:00.000Z"),
    randomBytes: (length) => new Uint8Array(length).fill(7),
    randomUuid: () => correlationId,
    audit: (event) => audits.push(event),
    sleep: () => Promise.resolve(),
    jitter: () => 0,
  };
  const extractor: EmailTaskExtractor = {
    extract: () => Promise.resolve(candidate()),
  };
  const challenge: OAuthStartResult = {
    connectionId,
    authorizationUri:
      "https://accounts.google.com/o/oauth2/v2/auth?scope=gmail.readonly&state=safe-state",
    codeChallenge: "safe-code-challenge",
    expiresAt: "2026-07-22T00:20:00.000Z",
  };
  return {
    audits,
    store,
    google,
    oauthCalls,
    dependencies: {
      configuration,
      runtime,
      authenticator: {
        authenticate: () => Promise.resolve({ ownerUserId }),
      },
      store,
      oauth: {
        start: (owner, requested, correlation) => {
          oauthCalls.push(`start:${owner}:${requested}:${correlation}`);
          return Promise.resolve(challenge);
        },
        complete: (state, code) => {
          oauthCalls.push(`complete:${state}:${code}`);
          return Promise.resolve({
            connection: persisted("connected"),
            requestedConnectionId: connectionId,
            correlationId,
          });
        },
        fail: (state, category) => {
          oauthCalls.push(`fail:${state}:${category}`);
          return Promise.resolve({
            requestedConnectionId: connectionId,
            correlationId,
          });
        },
      },
      google,
      extractor,
      createCredentials: ({ record }) => ({
        connection: record,
        accessToken: () => Promise.resolve("access-token-secret-marker"),
        revocationToken: () =>
          Promise.resolve(
            record.connectionId === connectionId
              ? "refresh-token-secret-marker"
              : `refresh-token-secret-marker-${record.connectionId}`,
          ),
      }),
      createConnector: () => successfulConnector(),
    },
  };
}

function endpointRequest(body: Readonly<Record<string, unknown>>): Request {
  return new Request(
    "https://project.example.invalid/functions/v1/email-import",
    {
      method: "POST",
      headers: {
        authorization: "Bearer caller-jwt-marker",
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
}

Deno.test("production requires exact flags, keys, redirect and model config", () => {
  assert(gmailReadOnlyScope.endsWith("/gmail.readonly"), "readonly scope");
  assert(!productionReadiness(reader({})).enabled, "disabled by default");
  assert(
    !productionReadiness(reader({
      ...completeConfiguration,
      EMAIL_IMPORT_ENABLED: "TRUE",
    })).enabled,
    "feature flag is exact",
  );
  assert(
    !productionReadiness(reader({
      ...completeConfiguration,
      EMAIL_IMPORT_MODEL_ENABLED: "false",
    })).configured,
    "production extractor is explicit",
  );
  assert(
    !productionReadiness(reader({
      EMAIL_IMPORT_ENABLED: "true",
      EMAIL_IMPORT_CONNECTOR: "fake",
    })).configured,
    "a fake selector cannot configure production",
  );
  assert(
    productionReadiness(reader(completeConfiguration)).configured,
    "complete trusted configuration",
  );
  assert(
    parseProductionConfiguration(reader(completeConfiguration)).appRedirectUri
      .toString() === "unischedule://email-import-callback",
    "exact mobile callback is configured",
  );
  for (
    const unsafeRedirect of [
      "universityschedule://oauth/email-import",
      "unischedule://email-import-callback?next=https://attacker.invalid",
      "unischedule://email-import-callback/path",
    ]
  ) {
    let rejected = false;
    try {
      parseProductionConfiguration(reader({
        ...completeConfiguration,
        EMAIL_IMPORT_APP_REDIRECT_URI: unsafeRedirect,
      }));
    } catch (error) {
      rejected = error instanceof SafeEmailError &&
        error.category === "configuration_missing";
    }
    assert(rejected, "non-contract app redirect is rejected");
  }
});

Deno.test("disabled and invalid configuration fail closed before auth or body read", async () => {
  const secretMarker = "raw-request-secret-marker";
  const disabled = await handleRequest(
    endpointRequest({ action: "fetch_delta", body: secretMarker }),
    reader({}),
  );
  assert(disabled.status === 404, "disabled endpoint is hidden");
  assert(!(await disabled.text()).includes(secretMarker), "body is not echoed");

  const invalid = await handleRequest(
    endpointRequest({ action: "fetch_delta" }),
    reader({
      ...completeConfiguration,
      EMAIL_IMPORT_TOKEN_ENCRYPTION_KEY: "bad",
    }),
  );
  assert(invalid.status === 503, "invalid cryptographic config is closed");
  const text = await invalid.text();
  for (const secret of Object.values(completeConfiguration)) {
    assert(!text.includes(secret), "config secret does not cross boundary");
  }
});

Deno.test("HTTP boundary authenticates POST and rejects owner injection", async () => {
  const readEnvironment = (_name: string): string | undefined => {
    throw new Error("environment must not be read");
  };
  assert(
    (await handleRequest(
      new Request("https://example.invalid/"),
      readEnvironment,
    ))
      .status === 405,
    "non-callback GET is rejected before env access",
  );
  assert(
    (await handleRequest(
      new Request("https://example.invalid/", {
        method: "OPTIONS",
      }),
      readEnvironment,
    )).status === 204,
    "preflight",
  );

  const response = await handleRequest(
    endpointRequest({
      action: "connect",
      connectionId,
      ownerUserId: "attacker-owner",
    }),
    reader(completeConfiguration),
    (configuration) => makeDependencies(configuration).dependencies,
  );
  assert(response.status === 400, "client owner field is rejected");
});

Deno.test("OAuth start returns only safe URI/challenge and server-bound owner", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({ action: "connect", connectionId }),
    reader(completeConfiguration),
    (configuration) => (fixture = makeDependencies(configuration)).dependencies,
  );
  const text = await response.text();
  assert(response.status === 200, "start succeeds");
  assert(text.includes('"status":"connecting"'), "connecting state");
  assert(text.includes("safe-code-challenge"), "challenge returned");
  assert(text.includes("accounts.google.com"), "allowlisted auth origin");
  assert(!text.includes("verifier"), "PKCE verifier is absent");
  assert(!text.includes("token-secret"), "token is absent");
  assert(
    fixture!.oauthCalls[0] ===
      `start:${ownerUserId}:${connectionId}:${correlationId}`,
    "owner comes only from authenticator",
  );
});

Deno.test("authorization check is owner/request/correlation-bound and returns only an effective UUID", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({
      action: "check_authorization",
      connectionId,
      callbackCorrelationId: correlationId,
    }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.authorizationOverride = {
        requestedConnectionId: connectionId,
        effectiveConnectionId: secondConnectionId,
        connectionState: "connected",
        errorCategory: null,
        retryAfterAt: null,
        connectedAt: "2026-07-22T00:00:00.000Z",
      };
      return fixture.dependencies;
    },
  );
  const text = await response.text();
  assert(response.status === 200, "correlated check succeeds");
  assert(text.includes(secondConnectionId), "effective UUID is returned");
  assert(
    fixture!.store.authorizationInput?.ownerUserId === ownerUserId &&
      fixture!.store.authorizationInput?.requestedConnectionId ===
        connectionId &&
      fixture!.store.authorizationInput?.callbackCorrelationId ===
        correlationId,
    "all receipt keys are bound at the trusted store",
  );
  for (
    const forbidden of [
      "providerAccountHash",
      "provider_account_hash",
      "emailAddress",
      "token",
      "gmail-client-secret-marker",
    ]
  ) {
    assert(!text.includes(forbidden), `${forbidden} is absent`);
  }

  for (
    const body of [
      { action: "check_authorization", connectionId },
      {
        action: "check_authorization",
        connectionId,
        callbackCorrelationId: correlationId,
        ownerUserId,
      },
    ]
  ) {
    const rejected = await handleRequest(
      endpointRequest(body),
      reader(completeConfiguration),
      (configuration) => makeDependencies(configuration).dependencies,
    );
    assert(rejected.status === 400, "missing or client owner data is rejected");
  }

  const missing = await handleRequest(
    endpointRequest({
      action: "check_authorization",
      connectionId,
      callbackCorrelationId: correlationId,
    }),
    reader(completeConfiguration),
    (configuration) => {
      const missingFixture = makeDependencies(configuration);
      missingFixture.store.authorizationOverride = null;
      return missingFixture.dependencies;
    },
  );
  assert(missing.status === 400, "missing receipt fails closed");
});

Deno.test("fetch persists only exact validated 1:1 safe page and returns no secrets", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
    reader(completeConfiguration),
    (configuration) => (fixture = makeDependencies(configuration)).dependencies,
  );
  const text = await response.text();
  assert(response.status === 200, "fetch succeeds");
  assert(text.includes('"nextCursor":"safe-cursor"'), "cursor returned");
  assert(
    text.includes('"requires_user_confirmation":true'),
    "validated candidate",
  );
  for (
    const secret of [
      "access-token-secret-marker",
      "refresh-token-secret-marker",
      "service-role-secret-marker",
      "gmail-client-secret-marker",
      "model-api-secret-marker",
    ]
  ) {
    assert(!text.includes(secret), "secret is absent from response");
    assert(
      !JSON.stringify(fixture!.audits).includes(secret),
      "secret is absent from audit",
    );
  }
  const persistedInput = fixture!.store.persistedInput!;
  assert(persistedInput.ownerUserId === ownerUserId, "server owner persisted");
  assert(persistedInput.sources.length === 1, "one safe source");
  assert(persistedInput.candidates.length === 1, "one candidate");
  assert(
    Object.keys(persistedInput.sources[0]).sort().join(",") ===
      "error_category,evidence_metadata,processing_state,provider_message_id,provider_thread_id,received_at,sanitized_content_hash",
    "exact RPC source keys",
  );
  assert(
    Object.keys(persistedInput.candidates[0]).sort().join(",") ===
      "error_category,provider_message_id,validated_payload",
    "exact RPC candidate keys",
  );
});

Deno.test("fetch requires an explicit cursor and replays the exact requested page", async () => {
  const missingCursor = await handleRequest(
    endpointRequest({ action: "fetch_delta", connectionId }),
    reader(completeConfiguration),
    (configuration) => makeDependencies(configuration).dependencies,
  );
  assert(missingCursor.status === 400, "an omitted cursor is ambiguous");

  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.credentials = {
        ...storedCredentials(),
        syncCursor: safeCursor,
      };
      fixture.store.persistedInput = {
        ownerUserId,
        connectionId,
        expectedCursor: null,
        nextCursor: safeCursor,
        sources: [{
          provider_message_id: "message-replayed",
          provider_thread_id: "thread-replayed",
          received_at: "2026-07-22T00:05:00.000Z",
          sanitized_content_hash: "a".repeat(64),
          evidence_metadata: ["レポート"],
          processing_state: "processed",
          error_category: null,
        }],
        candidates: [{
          provider_message_id: "message-replayed",
          validated_payload: candidate(),
          error_category: null,
        }],
        hasMore: false,
        syncedAt: "2026-07-22T00:10:00.000Z",
        correlationId,
      };
      return {
        ...fixture.dependencies,
        createConnector: () => {
          throw new Error("replay must not contact Gmail");
        },
      };
    },
  );
  const payload = await response.json() as Record<string, unknown>;
  assert(response.status === 200, "stale response is safely replayed");
  assert(
    JSON.stringify(payload).includes("message-replayed"),
    "the receipt for the requested cursor is returned",
  );
  assert(
    fixture!.store.credentialRequests.length === 1,
    "only the credential cursor is read before replay",
  );
});

Deno.test("every successful sync page requires a non-null advanced cursor", async () => {
  for (
    const cursorCase of [
      { current: null, next: null, hasMessage: true },
      { current: safeCursor, next: null, hasMessage: true },
      { current: safeCursor, next: safeCursor, hasMessage: true },
      { current: null, next: null, hasMessage: false },
      { current: safeCursor, next: safeCursor, hasMessage: false },
    ] as const
  ) {
    let fixture: ReturnType<typeof makeDependencies> | null = null;
    const response = await handleRequest(
      endpointRequest({
        action: "fetch_delta",
        connectionId,
        cursor: cursorCase.current,
      }),
      reader(completeConfiguration),
      (configuration) => {
        fixture = makeDependencies(configuration);
        fixture.store.credentials = {
          ...storedCredentials(),
          syncCursor: cursorCase.current,
        };
        return {
          ...fixture.dependencies,
          createConnector: () => ({
            provider: "gmail" as const,
            fetchPage: () =>
              Promise.resolve({
                messages: cursorCase.hasMessage
                  ? [{
                    providerMessageId: "message-without-advance",
                    providerThreadId: "thread-without-advance",
                    receivedAt: "2026-07-22T00:05:00.000Z",
                    subject: "レポート",
                    sender: "大学事務",
                    body: "7月30日23時までに提出してください。",
                    bodyKind: "text" as const,
                  }]
                  : [],
                nextCursor: cursorCase.next,
                hasMore: false,
              }),
          }),
        };
      },
    );
    assert(response.status === 503, "ambiguous replay key fails closed");
    assert(
      fixture!.store.persistedInput === null,
      "a non-advancing cursor cannot create a receipt or source",
    );
  }
});

Deno.test("normal sync returns and replays committed suppression acknowledgements", async () => {
  const suppression = {
    providerMessageIdHash: await providerMessageIdentifierHash(
      "1".repeat(64),
      "message-1",
    ),
    reason: "dismissed" as const,
  };
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const first = await handleRequest(
    endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.syncReplayOverride = {
        items: [],
        suppressions: [suppression],
        nextCursor: safeCursor,
        hasMore: false,
        connectedAt: "2026-07-22T00:00:00.000Z",
      };
      return fixture.dependencies;
    },
  );
  const firstText = await first.text();
  const firstPayload = JSON.parse(firstText) as {
    readonly page: {
      readonly items: readonly unknown[];
      readonly suppressions: readonly Record<string, unknown>[];
      readonly nextCursor: unknown;
    };
  };
  assert(first.status === 200, "suppressed page commits");
  assert(
    firstPayload.page.items.length === 0 &&
      firstPayload.page.suppressions.length === 1 &&
      firstPayload.page.suppressions[0].providerMessageIdHash ===
        suppression.providerMessageIdHash &&
      firstPayload.page.suppressions[0].reason === suppression.reason &&
      firstPayload.page.nextCursor === safeCursor,
    "normal sync returns only the minimal committed suppression ack",
  );
  assert(
    !firstText.includes("レポート"),
    "suppressed candidate is never returned",
  );
  assert(
    !firstText.includes("message-1"),
    "normal suppression acknowledgement is hash-only",
  );
  assert(
    fixture!.store.persistedInput !== null,
    "the suppression is derived by atomic trusted persistence",
  );

  fixture!.store.credentials = {
    ...storedCredentials(),
    syncCursor: safeCursor,
  };
  const replay = await handleRequest(
    endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
    reader(completeConfiguration),
    () => ({
      ...fixture!.dependencies,
      createConnector: () => {
        throw new Error("sync replay must not contact Gmail");
      },
    }),
  );
  const replayPayload = await replay.json() as {
    readonly page: {
      readonly items: readonly unknown[];
      readonly suppressions: readonly Record<string, unknown>[];
    };
  };
  assert(
    replay.status === 200 && replayPayload.page.items.length === 0 &&
      JSON.stringify(replayPayload.page.suppressions) ===
        JSON.stringify([suppression]),
    "lost normal response replays the exact suppression ack",
  );
});

Deno.test("atomic persistence must partition every input into one item or hash-only suppression", async () => {
  const messageHash = await providerMessageIdentifierHash(
    "1".repeat(64),
    "message-1",
  );
  const committedItem = {
    providerMessageId: "message-1",
    providerThreadId: "thread-1",
    receivedAt: "2026-07-22T00:05:00.000Z",
    sanitizedContentHash: "a".repeat(64),
    evidenceExcerpts: ["レポート"],
    candidate: candidate(),
    errorCategory: null,
  } as const;
  for (
    const invalidPage of [
      { items: [], suppressions: [] },
      {
        items: [committedItem],
        suppressions: [{
          providerMessageIdHash: messageHash,
          reason: "deduplicated" as const,
        }],
      },
      {
        items: [],
        suppressions: [
          { providerMessageIdHash: messageHash, reason: "dismissed" as const },
          {
            providerMessageIdHash: messageHash,
            reason: "deduplicated" as const,
          },
        ],
      },
    ]
  ) {
    let fixture: ReturnType<typeof makeDependencies> | null = null;
    const response = await handleRequest(
      endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
      reader(completeConfiguration),
      (configuration) => {
        fixture = makeDependencies(configuration);
        fixture.store.syncReplayOverride = {
          ...invalidPage,
          nextCursor: safeCursor,
          hasMore: false,
          connectedAt: "2026-07-22T00:00:00.000Z",
        };
        return fixture.dependencies;
      },
    );
    assert(response.status === 503, "invalid committed partition fails closed");
    assert(
      fixture!.store.persistedInput !== null,
      "omitted, invented, or overlapping acknowledgements are never returned",
    );
  }
});

Deno.test("retry candidate replays before provider work and accepts only exact camelCase", async () => {
  const retryBody = {
    action: "retry_candidate",
    connectionId,
    providerMessageId: "message-retry-1",
    expectedSanitizedContentHash: "a".repeat(64),
    retryIdempotencyKey: "b".repeat(64),
  } as const;
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  let connectorCalls = 0;
  const response = await handleRequest(
    endpointRequest(retryBody),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.retryReplayOverride = {
        retryOutcome: "persisted",
        item: {
          providerMessageId: retryBody.providerMessageId,
          providerThreadId: `failed:${"c".repeat(64)}`,
          receivedAt: "2026-07-22T00:05:00.000Z",
          sanitizedContentHash: retryBody.expectedSanitizedContentHash,
          evidenceExcerpts: [],
          candidate: null,
          errorCategory: "timeout",
        },
        suppression: null,
        connectedAt: "2026-07-22T00:00:00.000Z",
      };
      return {
        ...fixture.dependencies,
        createConnector: () => {
          connectorCalls += 1;
          return successfulConnector();
        },
      };
    },
  );
  const payload = await response.json() as {
    readonly retryOutcome: string;
    readonly page: {
      readonly items: readonly Record<string, unknown>[];
      readonly suppressions: readonly Record<string, unknown>[];
      readonly nextCursor: unknown;
      readonly hasMore: unknown;
    };
  };
  assert(response.status === 200, "retry receipt is replayed");
  assert(payload.retryOutcome === "persisted", "replay outcome is explicit");
  assert(payload.page.items.length === 1, "retry page has exactly one item");
  assert(
    payload.page.suppressions.length === 0,
    "persisted replay is not suppressed",
  );
  assert(
    payload.page.items[0].candidate === null &&
      payload.page.items[0].errorCategory === "timeout",
    "failed retry replay preserves the safe XOR item",
  );
  assert(
    payload.page.nextCursor === null && payload.page.hasMore === false,
    "targeted retry never advances the sync cursor",
  );
  assert(connectorCalls === 0, "replay performs no provider work");
  assert(
    fixture!.store.credentialRequests.length === 0 &&
      fixture!.store.retryAssertionInput === null,
    "replay happens before credentials and mutable-state assertions",
  );
  assert(
    fixture!.store.retryReplayInput?.retryIdempotencyKey ===
      retryBody.retryIdempotencyKey,
    "the exact retry key scopes replay",
  );

  const snakeCase = await handleRequest(
    endpointRequest({
      action: "retry_candidate",
      connection_id: connectionId,
      provider_message_id: retryBody.providerMessageId,
      expected_sanitized_content_hash: retryBody.expectedSanitizedContentHash,
      retry_idempotency_key: retryBody.retryIdempotencyKey,
    }),
    reader(completeConfiguration),
    (configuration) => makeDependencies(configuration).dependencies,
  );
  assert(snakeCase.status === 400, "snake_case retry input is rejected");
});

Deno.test("retry candidate fetches exactly one message and never overwrites a page receipt", async () => {
  const retryBody = {
    action: "retry_candidate",
    connectionId,
    providerMessageId: "message-retry-2",
    expectedSanitizedContentHash: "d".repeat(64),
    retryIdempotencyKey: "e".repeat(64),
  } as const;
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const fetchedIds: string[] = [];
  const response = await handleRequest(
    endpointRequest(retryBody),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      return {
        ...fixture.dependencies,
        createConnector: () => ({
          provider: "gmail" as const,
          fetchPage: () => {
            throw new Error("targeted retry must not fetch a page");
          },
          fetchMessage: (providerMessageId: string) => {
            fetchedIds.push(providerMessageId);
            return Promise.resolve({
              providerMessageId,
              providerThreadId: "thread-retry-2",
              receivedAt: "2026-07-22T00:05:00.000Z",
              subject: "レポート",
              sender: "大学事務",
              body: "7月30日23時までに提出してください。",
              bodyKind: "text" as const,
            });
          },
        }),
      };
    },
  );
  const payload = await response.json() as {
    readonly retryOutcome: string;
    readonly page: {
      readonly items: readonly Record<string, unknown>[];
      readonly suppressions: readonly Record<string, unknown>[];
      readonly nextCursor: unknown;
      readonly hasMore: unknown;
    };
  };
  assert(response.status === 200, "recoverable candidate retries");
  assert(payload.retryOutcome === "persisted", "commit outcome is explicit");
  assert(
    fetchedIds.length === 1 && fetchedIds[0] === retryBody.providerMessageId,
    "only the requested provider message is fetched",
  );
  assert(
    payload.page.items.length === 1 &&
      payload.page.items[0].candidate !== null &&
      payload.page.items[0].errorCategory === null,
    "successful retry returns one safe success item",
  );
  assert(payload.page.suppressions.length === 0, "committed item is disjoint");
  assert(
    payload.page.nextCursor === null && payload.page.hasMore === false,
    "retry response is a non-paginating singleton",
  );
  assert(
    fixture!.store.retryAssertionInput?.expectedSanitizedContentHash ===
      retryBody.expectedSanitizedContentHash,
    "retry validates the expected failed revision",
  );
  assert(
    fixture!.store.retryPersistedInput?.retryIdempotencyKey ===
        retryBody.retryIdempotencyKey && fixture!.store.persistedInput === null,
    "retry uses its private receipt without replacing a sync-page receipt",
  );
});

Deno.test("retry suppression returns and replays an explicit empty trusted acknowledgement", async () => {
  const retryBody = {
    action: "retry_candidate",
    connectionId,
    providerMessageId: "message-retry-suppressed",
    expectedSanitizedContentHash: "7".repeat(64),
    retryIdempotencyKey: "8".repeat(64),
  } as const;
  const providerMessageIdHash = await providerMessageIdentifierHash(
    "1".repeat(64),
    retryBody.providerMessageId,
  );
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  let connectorCalls = 0;
  const first = await handleRequest(
    endpointRequest(retryBody),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.retryPersistedOverride = {
        connection: persisted("connected"),
        retryOutcome: "suppressed",
        item: null,
        suppression: {
          providerMessageIdHash,
          reason: "dismissed",
        },
      };
      return {
        ...fixture.dependencies,
        createConnector: () => {
          connectorCalls += 1;
          return {
            provider: "gmail" as const,
            fetchPage: () => {
              throw new Error("targeted retry must not fetch a page");
            },
            fetchMessage: (providerMessageId: string) =>
              Promise.resolve({
                providerMessageId,
                providerThreadId: "thread-dismissed-semantic-match",
                receivedAt: "2026-07-22T00:05:00.000Z",
                subject: "レポート",
                sender: "大学事務",
                body: "7月30日23時までに提出してください。",
                bodyKind: "text" as const,
              }),
          };
        },
      };
    },
  );
  const firstText = await first.text();
  const firstPayload = JSON.parse(firstText) as {
    readonly retryOutcome: string;
    readonly page: {
      readonly items: readonly unknown[];
      readonly suppressions: readonly Record<string, unknown>[];
      readonly nextCursor: unknown;
      readonly hasMore: unknown;
    };
  };
  assert(first.status === 200, "trusted suppression is acknowledged");
  assert(
    firstPayload.retryOutcome === "suppressed" &&
      firstPayload.page.items.length === 0 &&
      firstPayload.page.suppressions.length === 1 &&
      firstPayload.page.suppressions[0].providerMessageIdHash ===
        providerMessageIdHash &&
      firstPayload.page.suppressions[0].reason === "dismissed" &&
      firstPayload.page.nextCursor === null &&
      firstPayload.page.hasMore === false,
    "suppression returns no invented candidate or failure",
  );
  assert(!firstText.includes("レポート"), "uncommitted retry input is absent");
  assert(
    !firstText.includes(retryBody.providerMessageId),
    "retry suppression acknowledgement is hash-only",
  );
  assert(
    fixture!.store.retryPersistedInput?.retryIdempotencyKey ===
        retryBody.retryIdempotencyKey && connectorCalls === 1,
    "the first attempt reaches only targeted persistence once",
  );
  assert(
    fixture!.audits.at(-1)?.state === "suppressed" &&
      fixture!.audits.at(-1)?.category === null,
    "only the safe suppression outcome is audited",
  );

  fixture!.store.retryReplayOverride = {
    retryOutcome: "suppressed",
    item: null,
    suppression: {
      providerMessageIdHash,
      reason: "dismissed",
    },
    connectedAt: "2026-07-22T00:00:00.000Z",
  };
  const replay = await handleRequest(
    endpointRequest(retryBody),
    reader(completeConfiguration),
    () => fixture!.dependencies,
  );
  const replayPayload = await replay.json() as {
    readonly retryOutcome: string;
    readonly page: {
      readonly items: readonly unknown[];
      readonly suppressions: readonly Record<string, unknown>[];
    };
  };
  assert(
    replay.status === 200 && replayPayload.retryOutcome === "suppressed" &&
      replayPayload.page.items.length === 0 &&
      replayPayload.page.suppressions.length === 1,
    "lost suppressed response replays exactly",
  );
  assert(connectorCalls === 1, "suppressed replay performs no provider work");
});

Deno.test("targeted suppression hash must bind to the requested provider identity", async () => {
  const retryBody = {
    action: "retry_candidate",
    connectionId,
    providerMessageId: "message-retry-hash-mismatch",
    expectedSanitizedContentHash: "9".repeat(64),
    retryIdempotencyKey: "a".repeat(64),
  } as const;
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  let connectorCalls = 0;
  const response = await handleRequest(
    endpointRequest(retryBody),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.retryReplayOverride = {
        retryOutcome: "suppressed",
        item: null,
        suppression: {
          providerMessageIdHash: "f".repeat(64),
          reason: "dismissed",
        },
        connectedAt: "2026-07-22T00:00:00.000Z",
      };
      return {
        ...fixture.dependencies,
        createConnector: () => {
          connectorCalls += 1;
          return successfulConnector();
        },
      };
    },
  );
  assert(response.status === 503, "mismatched suppression hash fails closed");
  assert(
    fixture!.audits.every((event) => event.state !== "suppressed"),
    "mismatched hash is never acknowledged or audited as suppression",
  );
  assert(
    connectorCalls === 0 && fixture!.store.credentialRequests.length === 1 &&
      fixture!.store.retryPersistedInput === null,
    "replay binding reads only owner-bound account metadata and does no provider work",
  );
});

Deno.test("permanent or changed failures are rejected before credentials and Gmail", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  let connectorCalls = 0;
  const response = await handleRequest(
    endpointRequest({
      action: "retry_candidate",
      connectionId,
      providerMessageId: "message-permanent",
      expectedSanitizedContentHash: "f".repeat(64),
      retryIdempotencyKey: "1".repeat(64),
    }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.retryAssertionError = new SafeEmailError(
        "validation_failed",
      );
      return {
        ...fixture.dependencies,
        createConnector: () => {
          connectorCalls += 1;
          return successfulConnector();
        },
      };
    },
  );
  assert(response.status === 400, "non-retryable state fails closed");
  assert(
    connectorCalls === 0 && fixture!.store.credentialRequests.length === 0,
    "state/hash rejection happens before any secret or provider access",
  );
  assert(fixture!.store.retryPersistedInput === null, "no receipt is written");
});

Deno.test("review reconciliation is strict, owner-bound, and returns only safe acknowledgements", async () => {
  const identity = {
    connectionId,
    provider: "gmail",
    providerAccountHash: "a".repeat(64),
    providerMessageIdHash: "b".repeat(64),
    providerThreadIdHash: "c".repeat(64),
    sanitizedContentHash: "d".repeat(64),
  } as const;
  const entityId = "e5333333-3333-4333-8333-333333333333";

  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const confirmation = await handleRequest(
    endpointRequest({
      action: "reconcile_confirmation",
      ...identity,
      reviewedPayload: candidate(),
      entityType: "assignment",
      entityId,
      idempotencyKey: "email-confirmation-safe-key",
    }),
    reader(completeConfiguration),
    (configuration) => (fixture = makeDependencies(configuration)).dependencies,
  );
  const confirmationText = await confirmation.text();
  assert(confirmation.status === 200, "confirmation reconciles");
  assert(
    confirmationText.includes('"outcome":"confirmed"'),
    "safe confirmation outcome",
  );
  const confirmationAcknowledgement = JSON.parse(confirmationText)
    .reconciliation as Record<string, unknown>;
  assert(
    Object.keys(confirmationAcknowledgement).sort().join(",") ===
      "action,connectionId,entityId,entityType,idempotencyKey,outcome,replayed",
    "confirmation acknowledgement has exact safe keys",
  );
  assert(
    confirmationAcknowledgement.connectionId === connectionId &&
      confirmationAcknowledgement.idempotencyKey ===
        "email-confirmation-safe-key",
    "confirmation acknowledgement is request-correlated",
  );
  assert(
    fixture!.store.confirmationInput?.ownerUserId === ownerUserId &&
      fixture!.store.confirmationInput?.entityId === entityId,
    "authenticated owner and reviewed entity reach only the trusted store",
  );

  fixture = null;
  const dismissal = await handleRequest(
    endpointRequest({
      action: "reconcile_dismissal",
      ...identity,
      idempotencyKey: "email-dismissal-safe-key",
    }),
    reader(completeConfiguration),
    (configuration) => (fixture = makeDependencies(configuration)).dependencies,
  );
  const dismissalText = await dismissal.text();
  assert(dismissal.status === 200, "dismissal reconciles");
  assert(dismissalText.includes('"entityType":null'), "no entity is invented");
  const dismissalAcknowledgement = JSON.parse(dismissalText)
    .reconciliation as Record<string, unknown>;
  assert(
    dismissalAcknowledgement.connectionId === connectionId &&
      dismissalAcknowledgement.idempotencyKey === "email-dismissal-safe-key",
    "dismissal acknowledgement is request-correlated",
  );
  assert(
    fixture!.store.dismissalInput?.providerMessageIdHash === "b".repeat(64),
    "only the account-domain-separated hash is forwarded",
  );

  fixture = null;
  const update = await handleRequest(
    endpointRequest({
      action: "reconcile_update",
      ...identity,
      resolution: "accepted",
      entityType: "assignment",
      entityId,
      idempotencyKey: "email-update-safe-key",
    }),
    reader(completeConfiguration),
    (configuration) => (fixture = makeDependencies(configuration)).dependencies,
  );
  const updateText = await update.text();
  assert(update.status === 200, "accepted update reconciles");
  assert(updateText.includes('"outcome":"accepted"'), "explicit resolution");
  const updateAcknowledgement = JSON.parse(updateText)
    .reconciliation as Record<string, unknown>;
  assert(
    updateAcknowledgement.connectionId === connectionId &&
      updateAcknowledgement.idempotencyKey === "email-update-safe-key",
    "update acknowledgement is request-correlated",
  );
  assert(
    fixture!.store.updateInput?.resolution === "accepted",
    "resolution is passed exactly once",
  );
  const audits = JSON.stringify(fixture!.audits);

  for (const text of [confirmationText, dismissalText, updateText]) {
    assert(!text.includes("レポート"), "review payload is never echoed");
    assert(!text.includes("b".repeat(64)), "provider hash is never echoed");
    assert(!text.includes("service-role-secret-marker"), "secret is absent");
  }
  assert(!audits.includes("b".repeat(64)), "provider hash is never logged");
  assert(!audits.includes("レポート"), "review payload is never logged");
  assert(
    audits.includes("reconcile_update") && audits.includes("accepted"),
    "only the safe action and outcome are audited",
  );

  const rejected = await handleRequest(
    endpointRequest({
      action: "reconcile_confirmation",
      ...identity,
      reviewedPayload: { ...candidate(), candidate_type: "event" },
      entityType: "assignment",
      entityId,
      idempotencyKey: "email-invalid-safe-key",
    }),
    reader(completeConfiguration),
    (configuration) => makeDependencies(configuration).dependencies,
  );
  assert(rejected.status === 400, "candidate/entity mismatch fails closed");
});

Deno.test("reconciliation rejects acknowledgements that do not match the request", async () => {
  const identity = {
    connectionId,
    provider: "gmail",
    providerAccountHash: "a".repeat(64),
    providerMessageIdHash: "b".repeat(64),
    providerThreadIdHash: "c".repeat(64),
    sanitizedContentHash: "d".repeat(64),
    idempotencyKey: "email-ack-correlation-key",
  } as const;
  const entityId = "e5333333-3333-4333-8333-333333333333";
  const otherEntityId = "e5444444-4444-4444-8444-444444444444";
  const confirmationBody = {
    action: "reconcile_confirmation",
    ...identity,
    reviewedPayload: candidate(),
    entityType: "assignment",
    entityId,
  } as const;
  const acceptedUpdateBody = {
    action: "reconcile_update",
    ...identity,
    resolution: "accepted",
    entityType: "assignment",
    entityId,
  } as const;
  const confirmationResult: PersistedReconciliation = {
    connectionId,
    connectionState: "connected",
    action: "confirmation",
    outcome: "confirmed",
    entityType: "assignment",
    entityId,
    replayed: false,
  };
  const cases: readonly {
    readonly name: string;
    readonly body: Readonly<Record<string, unknown>>;
    readonly result: PersistedReconciliation;
  }[] = [
    {
      name: "connection",
      body: confirmationBody,
      result: { ...confirmationResult, connectionId: secondConnectionId },
    },
    {
      name: "action",
      body: confirmationBody,
      result: {
        ...confirmationResult,
        action: "update",
        outcome: "accepted",
      },
    },
    {
      name: "outcome",
      body: acceptedUpdateBody,
      result: {
        ...confirmationResult,
        action: "update",
        outcome: "rejected",
      },
    },
    {
      name: "entity type",
      body: confirmationBody,
      result: { ...confirmationResult, entityType: "event" },
    },
    {
      name: "entity id",
      body: confirmationBody,
      result: { ...confirmationResult, entityId: otherEntityId },
    },
  ];

  for (const testCase of cases) {
    let fixture: ReturnType<typeof makeDependencies> | null = null;
    const response = await handleRequest(
      endpointRequest(testCase.body),
      reader(completeConfiguration),
      (configuration) => {
        fixture = makeDependencies(configuration);
        fixture.store.reconciliationOverride = testCase.result;
        return fixture.dependencies;
      },
    );
    assert(
      response.status === 503,
      `${testCase.name} mismatch fails closed`,
    );
    assert(
      !JSON.stringify(fixture!.audits).includes("reconcile_"),
      `${testCase.name} mismatch is not audited as reconciled`,
    );
  }
});

Deno.test("rate-limit and reauth errors persist only safe state", async () => {
  for (
    const error of [
      new SafeEmailError("rate_limited", { retryAfterMs: 120_000 }),
      new SafeEmailError("authorization_revoked"),
    ]
  ) {
    let fixture: ReturnType<typeof makeDependencies> | null = null;
    const response = await handleRequest(
      endpointRequest({ action: "fetch_delta", connectionId, cursor: null }),
      reader(completeConfiguration),
      (configuration) => {
        fixture = makeDependencies(configuration);
        return {
          ...fixture.dependencies,
          createConnector: () => ({
            provider: "gmail",
            fetchPage: () => Promise.reject(error),
          }),
        };
      },
    );
    assert(
      response.status === (error.category === "rate_limited" ? 429 : 401),
      "safe HTTP status",
    );
    assert(
      fixture!.store.failureInput?.ownerUserId === ownerUserId,
      "failure owner is server bound",
    );
    assert(
      fixture!.store.failureInput?.operation === "fetch",
      "sync failure uses accepted fetch operation",
    );
    assert(
      JSON.stringify(fixture!.store.failureInput).includes(error.category),
      "only category/state persisted",
    );
  }
});

Deno.test("disconnect finalizes token destruction even when Google revoke fails", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({
      action: "disconnect",
      connectionId,
      deleteDerivedData: true,
    }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.google.revokeResult = false;
      return fixture.dependencies;
    },
  );
  const text = await response.text();
  assert(response.status === 200, "disconnect succeeds locally");
  assert(text.includes('"status":"disconnected"'), "disconnected state");
  assert(
    fixture!.google.revokedToken === "refresh-token-secret-marker",
    "refresh token was attempted",
  );
  assert(
    fixture!.store.disconnectInput?.revocationAttempted,
    "attempt audited",
  );
  assert(
    !fixture!.store.disconnectInput?.revocationSucceeded,
    "failure audited",
  );
  assert(
    fixture!.store.disconnectInput?.deleteDerivedData,
    "derived deletion forwarded",
  );
  assert(
    !text.includes("refresh-token-secret-marker"),
    "token is never returned",
  );
});

Deno.test("delete_account_data revokes every owned token before owner-bound deletion", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({ action: "delete_account_data" }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.ownedConnectionIds = [connectionId, secondConnectionId];
      fixture.google.revokeResults = [true, false];
      return fixture.dependencies;
    },
  );
  const text = await response.text();
  assert(response.status === 200, "deletion succeeds");
  assert(
    fixture!.store.deletedOwner === ownerUserId,
    "authenticated owner only",
  );
  assert(
    fixture!.store.disconnectInput === null,
    "not conflated with disconnect",
  );
  assert(
    fixture!.google.revokedTokens.length === 2,
    "every owned credential gets a revoke attempt",
  );
  assert(
    fixture!.store.credentialReadsAtDelete === 2,
    "all revoke attempts precede final token destruction",
  );
  const audits = JSON.stringify(fixture!.audits);
  assert(audits.includes("revocation_succeeded"), "success is audited safely");
  assert(audits.includes("revocation_failed"), "failure is audited safely");
  for (const secret of fixture!.google.revokedTokens) {
    assert(!text.includes(secret), "revocation token is not returned");
    assert(!audits.includes(secret), "revocation token is not logged");
  }
});

Deno.test("delete_account_data fails closed before deletion when revoke enumeration fails", async () => {
  let fixture: ReturnType<typeof makeDependencies> | null = null;
  const response = await handleRequest(
    endpointRequest({ action: "delete_account_data" }),
    reader(completeConfiguration),
    (configuration) => {
      fixture = makeDependencies(configuration);
      fixture.store.listFailure = new SafeEmailError("provider_unavailable");
      return fixture.dependencies;
    },
  );
  const text = await response.text();
  assert(response.status === 503, "lookup failure is fail closed");
  assert(fixture!.store.deletedOwner === null, "delete RPC is not called");
  assert(
    fixture!.google.revokedTokens.length === 0,
    "no incomplete revoke set",
  );
  assert(
    JSON.stringify(fixture!.audits).includes("revocation_lookup_failed"),
    "safe lookup failure is audited",
  );
  assert(!text.includes("service-role-secret-marker"), "no secret response");
});

Deno.test("OAuth callback redirects only to configured app URI without callback data", async () => {
  for (
    const query of [
      "state=state-secret-marker-abcdefghijklmnopqrstuvwxyz&code=code-secret-marker",
      "state=state-secret-marker-abcdefghijklmnopqrstuvwxyz&error=access_denied",
    ]
  ) {
    let fixture: ReturnType<typeof makeDependencies> | null = null;
    const response = await handleRequest(
      new Request(
        `https://project.example.invalid/functions/v1/email-import?${query}`,
      ),
      reader(completeConfiguration),
      (configuration) =>
        (fixture = makeDependencies(configuration)).dependencies,
    );
    const location = response.headers.get("location") ?? "";
    assert(response.status === 303, "callback redirects");
    assert(
      location.startsWith("unischedule://email-import-callback"),
      "allowlisted URI",
    );
    assert(!location.includes("code-secret-marker"), "code not redirected");
    assert(!location.includes("state-secret-marker"), "state not redirected");
    assert(!location.includes("@"), "address not redirected");
    assert(
      location.includes(`connection_id=${connectionId}`) &&
        location.includes(`correlation_id=${correlationId}`),
      "only the requested connection and server correlation UUIDs return",
    );
    assert(fixture!.oauthCalls.length === 1, "callback boundary invoked once");
  }
});

Deno.test("OAuth exchange failure redirects with its exact attempt correlation", async () => {
  const response = await handleRequest(
    new Request(
      "https://project.example.invalid/functions/v1/email-import?state=state-secret-marker-abcdefghijklmnopqrstuvwxyz&code=code-secret-marker",
    ),
    reader(completeConfiguration),
    (configuration) => {
      const fixture = makeDependencies(configuration);
      return {
        ...fixture.dependencies,
        oauth: {
          ...fixture.dependencies.oauth,
          complete: () =>
            Promise.reject(
              new OAuthCompletionFailure(
                "provider_unavailable",
                connectionId,
                correlationId,
              ),
            ),
        },
      };
    },
  );
  const location = response.headers.get("location") ?? "";
  assert(response.status === 303, "failure redirects");
  assert(
    location.includes("email_import=failed") &&
      location.includes("category=provider_unavailable") &&
      location.includes(`connection_id=${connectionId}`) &&
      location.includes(`correlation_id=${correlationId}`),
    "safe failure redirect retains the exact attempt binding",
  );
  assert(!location.includes("state-secret-marker"), "state not redirected");
  assert(!location.includes("code-secret-marker"), "code not redirected");
});

Deno.test("production dependency graph has no fake production selector", () => {
  const dependencies = createProductionDependencies(
    // The factory is inspected only; it performs no network/provider call.
    parseProductionConfiguration(reader(completeConfiguration)),
  );
  assert(
    dependencies.createConnector.name !== "fake",
    "no fake connector factory",
  );
});
