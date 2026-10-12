import {
  ModelEmailTaskExtractor,
  modelSystemInstruction,
} from "./extraction.ts";
import {
  AesGcmVault,
  GmailOAuthCoordinator,
  GmailReadonlyConnector,
  GoogleApiClient,
  keyedAccountHash,
  OAuthCompletionFailure,
  type OAuthTokenBundle,
  OpenAIJsonModelClient,
  parseProductionConfiguration,
  PostgrestTrustedEmailStore,
  type ProductionConfiguration,
  type ProductionRuntime,
  type SafeAuditEvent,
  type StoredCredentials,
  SupabaseJwtAuthenticator,
  TrustedCredentialManager,
  type TrustedEmailStore,
} from "./production.ts";
import { gmailReadOnlyScope, SafeEmailError } from "./types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const ownerUserId = "a5111111-1111-4111-8111-111111111111";
const connectionId = "e5111111-1111-4111-8111-111111111111";
const reconciliationEntityId = "e5333333-3333-4333-8333-333333333333";
const correlationId = "c5111111-1111-4111-8111-111111111111";
const accountHash = "a".repeat(64);
const environment: Readonly<Record<string, string>> = {
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
  OPENAI_API_KEY: "openai-api-secret-marker",
};

function configuration(): ProductionConfiguration {
  return parseProductionConfiguration((name) => environment[name]);
}

Deno.test("self-hosted Supabase HTTP is limited to its internal gateway", () => {
  const local = parseProductionConfiguration((name) =>
    ({
      ...environment,
      SUPABASE_URL: "http://api-gw:8000",
    })[name]
  );
  assert(
    local.supabaseUrl.href === "http://api-gw:8000/",
    "the fixed internal API gateway supports self-hosted HTTP",
  );

  for (
    const url of [
      "http://api.example.test:8000",
      "http://api-gw:8001",
      "http://user@api-gw:8000",
      "http://api-gw:8000/rest/v1",
    ]
  ) {
    let rejected = false;
    try {
      parseProductionConfiguration((name) =>
        ({
          ...environment,
          SUPABASE_URL: url,
        })[name]
      );
    } catch (error) {
      rejected = error instanceof SafeEmailError &&
        error.category === "configuration_missing";
    }
    assert(rejected, `unsafe Supabase URL is rejected: ${url}`);
  }
});

function runtime(
  fetchOverride: ProductionRuntime["fetch"] = () =>
    Promise.reject(new Error("unexpected network")),
): { readonly value: ProductionRuntime; readonly audits: SafeAuditEvent[] } {
  const audits: SafeAuditEvent[] = [];
  return {
    audits,
    value: {
      fetch: fetchOverride,
      now: () => new Date("2026-07-22T00:00:00.000Z"),
      randomBytes: (length) =>
        Uint8Array.from({ length }, (_, index) => (index + 1) % 256),
      randomUuid: () => correlationId,
      audit: (event) => audits.push(event),
      sleep: () => Promise.resolve(),
      jitter: () => 0,
    },
  };
}

function persisted(state: "connected" | "disconnected" = "connected") {
  return {
    connectionId,
    connectionState: state,
    syncCursor: null,
    connectedAt: state === "connected" ? "2026-07-22T00:00:00.000Z" : null,
  } as const;
}

class MemoryStore implements TrustedEmailStore {
  oauthState:
    | {
      readonly ownerUserId: string;
      readonly connectionId: string;
      readonly stateHash: string;
      readonly encryptedPkceVerifier: Uint8Array;
      readonly encryptionKeyVersion: number;
      readonly expiresAt: string;
      readonly correlationId: string;
    }
    | null = null;
  completed: Parameters<TrustedEmailStore["completeOauth"]>[0] | null = null;
  rotated: Parameters<TrustedEmailStore["rotateCredentials"]>[0] | null = null;
  failure: Parameters<TrustedEmailStore["recordFailure"]>[0] | null = null;

  beginOauth(
    input: Parameters<TrustedEmailStore["beginOauth"]>[0],
  ): Promise<void> {
    this.oauthState = input;
    return Promise.resolve();
  }
  takeOauth(stateHash: string): Promise<
    {
      readonly ownerUserId: string;
      readonly connectionId: string;
      readonly encryptedPkceVerifier: Uint8Array;
      readonly encryptionKeyVersion: number;
      readonly expiresAt: string;
      readonly correlationId: string;
    } | null
  > {
    const state = this.oauthState;
    this.oauthState = null;
    if (state === null || state.stateHash !== stateHash) {
      return Promise.resolve(null);
    }
    return Promise.resolve(state);
  }
  completeOauth(
    input: Parameters<TrustedEmailStore["completeOauth"]>[0],
  ) {
    this.completed = input;
    return Promise.resolve({
      ...persisted("connected"),
      credentialVersion: 1,
    });
  }
  checkAuthorization(): Promise<null> {
    return Promise.resolve(null);
  }
  getCredentials(): Promise<StoredCredentials | null> {
    return Promise.resolve(null);
  }
  rotateCredentials(
    input: Parameters<TrustedEmailStore["rotateCredentials"]>[0],
  ): Promise<number> {
    this.rotated = input;
    return Promise.resolve(input.expectedCredentialVersion + 1);
  }
  persistSyncPage() {
    return Promise.resolve({
      connection: persisted("connected"),
      page: {
        items: [],
        suppressions: [],
        nextCursor: null,
        hasMore: false,
        connectedAt: "2026-07-22T00:00:00.000Z",
      },
    });
  }
  getSyncReplay(): Promise<null> {
    return Promise.resolve(null);
  }
  getOwnerTimezone(): Promise<null> {
    return Promise.resolve(null);
  }
  getRetryReplay(): Promise<null> {
    return Promise.resolve(null);
  }
  assertRetryCandidate(): Promise<void> {
    return Promise.resolve();
  }
  persistRetryCandidate(): never {
    throw new Error("not used");
  }
  reconcileConfirmation(
    input: Parameters<TrustedEmailStore["reconcileConfirmation"]>[0],
  ) {
    return Promise.resolve({
      connectionId: input.connectionId,
      connectionState: "connected" as const,
      action: "confirmation" as const,
      outcome: "confirmed" as const,
      entityType: input.entityType,
      entityId: input.entityId,
      replayed: false,
    });
  }
  reconcileDismissal(
    input: Parameters<TrustedEmailStore["reconcileDismissal"]>[0],
  ) {
    return Promise.resolve({
      connectionId: input.connectionId,
      connectionState: "connected" as const,
      action: "dismissal" as const,
      outcome: "dismissed" as const,
      entityType: null,
      entityId: null,
      replayed: false,
    });
  }
  reconcileUpdate(
    input: Parameters<TrustedEmailStore["reconcileUpdate"]>[0],
  ) {
    return Promise.resolve({
      connectionId: input.connectionId,
      connectionState: "connected" as const,
      action: "update" as const,
      outcome: input.resolution,
      entityType: input.entityType,
      entityId: input.entityId,
      replayed: false,
    });
  }
  finalizeDisconnect() {
    return Promise.resolve(persisted("disconnected"));
  }
  listOwnedConnectionIds(): Promise<readonly string[]> {
    return Promise.resolve([]);
  }
  deleteAccountData(): Promise<Readonly<Record<string, number>>> {
    return Promise.resolve({
      deleted_connections: 0,
      deleted_sources: 0,
      deleted_candidates: 0,
      deleted_updates: 0,
    });
  }
  recordFailure(
    input: Parameters<TrustedEmailStore["recordFailure"]>[0],
  ) {
    this.failure = input;
    return Promise.resolve(null);
  }
}

class OAuthGoogleStub {
  verifier: string | null = null;
  code: string | null = null;
  readonly address = "private-address@example.invalid";
  exchangeFailure: SafeEmailError | null = null;

  exchangeCode(code: string, verifier: string) {
    this.code = code;
    this.verifier = verifier;
    if (this.exchangeFailure !== null) {
      return Promise.reject(this.exchangeFailure);
    }
    return Promise.resolve({
      accessToken: "access-token-secret-marker",
      refreshToken: "refresh-token-secret-marker",
      expiresAt: "2026-07-22T01:00:00.000Z",
      scopes: [gmailReadOnlyScope],
      tokenType: "Bearer" as const,
    });
  }
  refreshToken(): Promise<OAuthTokenBundle> {
    return Promise.reject(new Error("not used"));
  }
  revoke() {
    return Promise.resolve(true);
  }
  profile() {
    return Promise.resolve({ address: this.address, historyId: "12345" });
  }
}

function validCandidate() {
  return {
    schema_version: "1.0",
    candidate_type: "assignment",
    title: "課題",
    course_hint: { name: null, code: null },
    due: { at: null, all_day: false, timezone: null, raw_text: null },
    start_at: null,
    end_at: null,
    location: null,
    submission_url: null,
    summary: null,
    suggested_reminders_minutes: [],
    confidence: { overall: 0.5, title: 0.5, course: 0, date_time: 0 },
    evidence: [],
    warnings: ["missing_date_time"],
    requires_user_confirmation: true,
  };
}

Deno.test("AES-GCM vault authenticates AAD and never embeds plaintext", async () => {
  const key = new Uint8Array(32).fill(3);
  const vault = new AesGcmVault(
    key,
    (length) => new Uint8Array(length).fill(4),
  );
  const secret = "oauth-token-secret-marker";
  const sealed = await vault.seal({ secret }, "owner-bound-aad");
  assert(
    !new TextDecoder().decode(sealed).includes(secret),
    "ciphertext hides token",
  );
  assert(
    (await vault.open(sealed, "owner-bound-aad")).secret === secret,
    "round trip",
  );
  let rejected = false;
  try {
    await vault.open(sealed, "different-owner-aad");
  } catch (error) {
    rejected = error instanceof SafeEmailError &&
      error.category === "authorization_revoked";
  }
  assert(rejected, "wrong owner/AAD is rejected");
  const tampered = sealed.slice();
  tampered[tampered.length - 1] ^= 1;
  try {
    await vault.open(tampered, "owner-bound-aad");
    throw new Error("tamper accepted");
  } catch (error) {
    assert(error instanceof SafeEmailError, "tamper maps safely");
  }
});

Deno.test("provider profile address is keyed-hashed and never stored raw", async () => {
  const hash = await keyedAccountHash(
    " Private-Address@Example.Invalid ",
    new Uint8Array(32).fill(9),
  );
  assert(/^[0-9a-f]{64}$/.test(hash), "bounded hash");
  assert(!hash.includes("private-address"), "address absent");
  assert(
    hash === await keyedAccountHash(
      "private-address@example.invalid",
      new Uint8Array(32).fill(9),
    ),
    "canonical deterministic account binding",
  );
});

Deno.test("OAuth PKCE/state exchange stores only encrypted verifier and hashed address", async () => {
  const config = configuration();
  const safeRuntime = runtime();
  const store = new MemoryStore();
  const google = new OAuthGoogleStub();
  const vault = new AesGcmVault(
    config.tokenEncryptionKey,
    safeRuntime.value.randomBytes,
  );
  const oauth = new GmailOAuthCoordinator({
    configuration: config,
    runtime: safeRuntime.value,
    store,
    vault,
    google,
  });
  const started = await oauth.start(ownerUserId, connectionId, correlationId);
  const authorization = new URL(started.authorizationUri);
  const state = authorization.searchParams.get("state")!;
  assert(
    authorization.origin === "https://accounts.google.com",
    "fixed OAuth host",
  );
  assert(
    authorization.searchParams.get("scope") === gmailReadOnlyScope,
    "minimum scope",
  );
  assert(
    authorization.searchParams.get("code_challenge_method") === "S256",
    "PKCE S256",
  );
  assert(
    !started.authorizationUri.includes("verifier"),
    "verifier not returned",
  );
  assert(store.oauthState !== null, "state stored");
  const sealedText = new TextDecoder().decode(
    store.oauthState.encryptedPkceVerifier,
  );
  assert(
    !sealedText.includes(started.codeChallenge),
    "verifier/challenge not plaintext",
  );

  const completed = await oauth.complete(state, "safe-oauth-code");
  assert(completed.connection.connectionState === "connected", "connected");
  assert(
    google.verifier !== null && google.verifier.length >= 43,
    "verifier used server-side",
  );
  assert(store.completed !== null, "completion persisted");
  assert(
    store.completed.providerAccountHash.length === 64,
    "address hash persisted",
  );
  const persistedJson = JSON.stringify(store.completed);
  assert(!persistedJson.includes(google.address), "raw profile address absent");
  assert(
    !persistedJson.includes("access-token-secret-marker"),
    "raw token absent",
  );
  assert(store.completed.authorizedScopes.length === 1, "one scope");
  const audits = JSON.stringify(safeRuntime.audits);
  for (const secret of [google.address, "safe-oauth-code", google.verifier!]) {
    assert(!audits.includes(secret), "OAuth secret absent from audits");
  }
});

Deno.test("OAuth exchange failure consumes state and records only safe category", async () => {
  const config = configuration();
  const safeRuntime = runtime();
  const store = new MemoryStore();
  const google = new OAuthGoogleStub();
  google.exchangeFailure = new SafeEmailError("provider_unavailable");
  const oauth = new GmailOAuthCoordinator({
    configuration: config,
    runtime: safeRuntime.value,
    store,
    vault: new AesGcmVault(
      config.tokenEncryptionKey,
      safeRuntime.value.randomBytes,
    ),
    google,
  });
  const start = await oauth.start(ownerUserId, connectionId, correlationId);
  const state = new URL(start.authorizationUri).searchParams.get("state")!;
  try {
    await oauth.complete(state, "failed-code-secret-marker");
    throw new Error("exchange unexpectedly succeeded");
  } catch (error) {
    assert(error instanceof OAuthCompletionFailure, "attempt-bound safe error");
    assert(
      error.requestedConnectionId === connectionId &&
        error.correlationId === correlationId,
      "failure retains only exact callback UUIDs",
    );
  }
  assert(store.oauthState === null, "state is single-use");
  assert(
    store.failure?.errorCategory === "provider_unavailable",
    "safe category",
  );
  assert(
    store.failure?.connectionId === connectionId,
    "pending connection fails",
  );
  assert(
    store.failure?.operation === "oauth_callback",
    "callback operation recorded",
  );
  assert(
    store.failure?.connectionState === "failed",
    "pending state is failed",
  );
  const serialized = JSON.stringify({
    failure: store.failure,
    audits: safeRuntime.audits,
  });
  assert(!serialized.includes("failed-code-secret-marker"), "code absent");

  const denied = await oauth.start(ownerUserId, connectionId, correlationId);
  const deniedState = new URL(denied.authorizationUri).searchParams.get(
    "state",
  )!;
  const deniedResult = await oauth.fail(
    deniedState,
    "authorization_revoked",
  );
  assert(
    deniedResult.correlationId === correlationId &&
      deniedResult.requestedConnectionId === connectionId,
    "denial preserves only the requested connection and safe correlation",
  );
  assert(store.oauthState === null, "denied state is single-use");
  assert(
    store.failure?.connectionId === connectionId,
    "denial binds pending row",
  );
  assert(
    store.failure?.operation === "oauth_callback",
    "denial audit operation",
  );
  assert(
    store.failure?.connectionState === "failed",
    "denial fails pending row",
  );
});

Deno.test("Google OAuth exchange, refresh and revoke use fixed hosts and safe mappings", async () => {
  const calls: {
    readonly url: string;
    readonly body: string;
    readonly contentType: string | null;
  }[] = [];
  let revokeStatus = 200;
  const safeRuntime = runtime((input, init) => {
    const url = input.toString();
    const headers = new Headers(init?.headers);
    calls.push({
      url,
      body: String(init?.body ?? ""),
      contentType: headers.get("content-type"),
    });
    if (url.includes("/revoke")) {
      return Promise.resolve(new Response("", { status: revokeStatus }));
    }
    if (url.includes("/profile")) {
      return Promise.resolve(Response.json({
        emailAddress: "hidden@example.invalid",
        historyId: "123",
      }));
    }
    const parameters = new URLSearchParams(String(init?.body ?? ""));
    return Promise.resolve(Response.json({
      access_token: parameters.get("grant_type") === "refresh_token"
        ? "new-access-secret"
        : "first-access-secret",
      ...(parameters.get("grant_type") === "authorization_code"
        ? { refresh_token: "refresh-secret" }
        : {}),
      expires_in: 3600,
      token_type: "Bearer",
      scope: gmailReadOnlyScope,
    }));
  });
  const google = new GoogleApiClient(configuration(), safeRuntime.value);
  const exchanged = await google.exchangeCode(
    "oauth-code-secret",
    "pkce-verifier-secret",
  );
  assert(exchanged.refreshToken === "refresh-secret", "refresh token parsed");
  const refreshed = await google.refreshToken("refresh-secret");
  assert(refreshed.accessToken === "new-access-secret", "refresh succeeds");
  assert(await google.revoke("refresh-secret"), "revoke succeeds");
  revokeStatus = 500;
  assert(
    !await google.revoke("refresh-secret"),
    "revoke failure is safe boolean",
  );
  const profile = await google.profile("first-access-secret");
  assert(profile.historyId === "123", "profile history parsed");
  const revokeCalls = calls.filter((call) => call.url.includes("/revoke"));
  assert(revokeCalls.length === 2, "both revocations reached the fixed route");
  assert(
    revokeCalls.every((call) =>
      new URL(call.url).search === "" &&
      new URLSearchParams(call.body).get("token") === "refresh-secret" &&
      call.contentType === "application/x-www-form-urlencoded"
    ),
    "revocation tokens stay in form bodies and out of URLs",
  );
  assert(
    calls.every((call) =>
      new URL(call.url).hostname.endsWith("googleapis.com")
    ),
    "fixed Google hosts",
  );
  assert(
    JSON.stringify(safeRuntime.audits) === "[]",
    "provider bodies are never logged",
  );
});

Deno.test("Google rejects expanded scopes and maps invalid_grant to reauth", async () => {
  const expanded = runtime(() =>
    Promise.resolve(Response.json({
      access_token: "secret",
      refresh_token: "refresh",
      expires_in: 3600,
      token_type: "Bearer",
      scope: `${gmailReadOnlyScope} openid`,
    }))
  );
  try {
    await new GoogleApiClient(configuration(), expanded.value)
      .exchangeCode("code", "verifier");
    throw new Error("expanded scope accepted");
  } catch (error) {
    assert(
      error instanceof SafeEmailError &&
        error.category === "authorization_revoked",
      "scope expansion rejected",
    );
  }

  const revoked = runtime(() =>
    Promise.resolve(Response.json({ error: "invalid_grant" }, { status: 400 }))
  );
  try {
    await new GoogleApiClient(configuration(), revoked.value)
      .refreshToken("refresh-secret-marker");
    throw new Error("invalid grant accepted");
  } catch (error) {
    assert(
      error instanceof SafeEmailError &&
        error.category === "authorization_revoked",
      "invalid grant requires reauth",
    );
  }
});

Deno.test("trusted credential refresh rotates sealed bundle only through CAS RPC", async () => {
  const config = configuration();
  const safeRuntime = runtime();
  const vault = new AesGcmVault(
    config.tokenEncryptionKey,
    safeRuntime.value.randomBytes,
  );
  const encrypted = await vault.seal(
    {
      accessToken: "old-access-secret",
      refreshToken: "refresh-secret",
      expiresAt: "2026-07-22T00:00:10.000Z",
      scopes: [gmailReadOnlyScope],
      tokenType: "Bearer",
    },
    `email-import-oauth:v1\u0000${ownerUserId}\u0000gmail\u0000${accountHash}`,
  );
  const store = new MemoryStore();
  const google = new OAuthGoogleStub();
  google.refreshToken = () =>
    Promise.resolve({
      accessToken: "new-access-secret",
      refreshToken: "refresh-secret",
      expiresAt: "2026-07-22T01:00:00.000Z",
      scopes: [gmailReadOnlyScope],
      tokenType: "Bearer" as const,
    });
  const manager = new TrustedCredentialManager({
    ownerUserId,
    correlationId,
    configuration: config,
    runtime: safeRuntime.value,
    store,
    vault,
    google,
    record: {
      connectionId,
      providerAccountHash: accountHash,
      connectionState: "connected",
      syncCursor: null,
      connectedAt: "2026-07-22T00:00:00.000Z",
      encryptedOauthBundle: encrypted,
      encryptionKeyVersion: 1,
      credentialVersion: 7,
      expiresAt: "2026-07-22T00:00:10.000Z",
    },
  });
  assert(
    await manager.accessToken() === "new-access-secret",
    "refreshed access",
  );
  assert(
    store.rotated?.expectedCredentialVersion === 7,
    "CAS version enforced",
  );
  assert(store.rotated?.ownerUserId === ownerUserId, "owner-bound rotation");
  const serialized = JSON.stringify({
    rotation: store.rotated,
    audits: safeRuntime.audits,
  });
  assert(!serialized.includes("new-access-secret"), "new token remains sealed");
  assert(
    !serialized.includes("refresh-secret"),
    "refresh token remains sealed",
  );
});

Deno.test("Gmail connector uses bounded lookback/history and never fetches links or attachments", async () => {
  const calls: string[] = [];
  const credential: {
    readonly connection: StoredCredentials;
    accessToken(forceRefresh?: boolean): Promise<string>;
    revocationToken(): Promise<string>;
  } = {
    connection: {
      connectionId,
      providerAccountHash: accountHash,
      connectionState: "connected",
      syncCursor: null,
      connectedAt: null,
      encryptedOauthBundle: new Uint8Array(30),
      encryptionKeyVersion: 1,
      credentialVersion: 1,
      expiresAt: null,
    },
    accessToken: () => Promise.resolve("gmail-access-secret"),
    revocationToken: () => Promise.resolve("gmail-refresh-secret"),
  };
  const safeRuntime = runtime((input) => {
    const url = input.toString();
    calls.push(url);
    const parsed = new URL(url);
    if (parsed.pathname.endsWith("/profile")) {
      return Promise.resolve(
        Response.json({
          historyId: "100",
          emailAddress: "not-used@example.invalid",
        }),
      );
    }
    if (parsed.pathname.endsWith("/messages")) {
      assert(
        parsed.searchParams.get("maxResults") === "10",
        "bounded page size",
      );
      assert(
        parsed.searchParams.get("q")?.startsWith("after:"),
        "bounded lookback query",
      );
      return Promise.resolve(Response.json({ messages: [{ id: "m1" }] }));
    }
    if (parsed.pathname.endsWith("/messages/m1")) {
      return Promise.resolve(Response.json({
        id: "m1",
        threadId: "t1",
        internalDate: "1784678400000",
        payload: {
          mimeType: "text/html",
          headers: [
            { name: "Subject", value: "課題" },
            { name: "From", value: "Teacher <teacher@example.invalid>" },
          ],
          body: {
            data: btoa(
              "<p>Due tomorrow</p><img src='https://tracker.invalid/pixel'>",
            )
              .replace(/\+/g, "-").replace(/\//g, "_"),
          },
        },
      }));
    }
    if (parsed.pathname.endsWith("/history")) {
      assert(
        parsed.searchParams.get("startHistoryId") === "100",
        "history cursor",
      );
      // Gmail can return the same high-water for a successful empty poll.
      return Promise.resolve(Response.json({ historyId: "100" }));
    }
    return Promise.reject(new Error("unexpected URL"));
  });
  const connector = new GmailReadonlyConnector({
    configuration: configuration(),
    runtime: safeRuntime.value,
    credentials: credential,
  });
  const initial = await connector.fetchPage({
    cursor: null,
    receivedAfter: "2026-07-08T00:00:00.000Z",
    limit: 10,
  });
  assert(initial.messages.length === 1, "message decoded");
  assert(
    initial.messages[0].sender === "Teacher",
    "address removed from sender label",
  );
  assert(
    initial.nextCursor !== null && !initial.hasMore,
    "history high-water cursor",
  );
  const delta = await connector.fetchPage({
    cursor: initial.nextCursor,
    receivedAfter: null,
    limit: 10,
  });
  assert(
    delta.messages.length === 0 && delta.nextCursor !== null &&
      delta.nextCursor !== initial.nextCursor,
    "empty history advances its opaque replay key even at the same high-water",
  );
  assert(calls.length === 4, "only profile/list/message/history fetched");
  assert(
    calls.every((url) => new URL(url).hostname === "gmail.googleapis.com"),
    "no link/image fetch",
  );
  assert(
    !JSON.stringify(safeRuntime.audits).includes("gmail-access-secret"),
    "token not logged",
  );
});

Deno.test("Gmail isolates missing and malformed listed messages without wedging the page", async () => {
  const requestedIds = [
    "gone-404",
    "gone-410",
    "bad-body",
    "bad-id",
    "mismatched-id",
    "invalid-json",
    "oversized-json",
    "deep-parts",
    "good-message",
  ] as const;
  const calls: string[] = [];
  const gmailMessage = (
    id: string,
    body = "Due tomorrow",
  ): Record<string, unknown> => ({
    id,
    threadId: `thread-${id}`,
    internalDate: "1784678400000",
    payload: {
      mimeType: "text/plain",
      headers: [
        { name: "Subject", value: "課題" },
        { name: "From", value: "Teacher <teacher@example.invalid>" },
      ],
      body: {
        data: btoa(body).replace(/\+/g, "-").replace(/\//g, "_"),
      },
    },
  });
  const safeRuntime = runtime((input) => {
    const url = new URL(input.toString());
    calls.push(url.toString());
    if (url.pathname.endsWith("/profile")) {
      return Promise.resolve(Response.json({ historyId: "100" }));
    }
    if (url.pathname.endsWith("/messages")) {
      return Promise.resolve(Response.json({
        messages: requestedIds.map((id) => ({ id })),
      }));
    }
    const requestedId = decodeURIComponent(url.pathname.split("/").pop()!);
    if (requestedId === "gone-404") {
      return Promise.resolve(new Response("", { status: 404 }));
    }
    if (requestedId === "gone-410") {
      return Promise.resolve(new Response("", { status: 410 }));
    }
    if (requestedId === "bad-body") {
      const malformed = gmailMessage(requestedId);
      const payload = malformed.payload as Record<string, unknown>;
      payload.body = { data: "%%%not-base64url%%%" };
      return Promise.resolve(Response.json(malformed));
    }
    if (requestedId === "bad-id") {
      return Promise.resolve(Response.json({
        ...gmailMessage(requestedId),
        id: "invalid id",
      }));
    }
    if (requestedId === "mismatched-id") {
      return Promise.resolve(Response.json(gmailMessage("another-message")));
    }
    if (requestedId === "invalid-json") {
      return Promise.resolve(
        new Response("{not-json", {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );
    }
    if (requestedId === "oversized-json") {
      return Promise.resolve(
        new Response(
          JSON.stringify({ padding: "x".repeat(1_048_576) }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );
    }
    if (requestedId === "deep-parts") {
      const message = gmailMessage(requestedId);
      const originalPayload = message.payload as Record<string, unknown>;
      let nested: Record<string, unknown> = {
        mimeType: "text/plain",
        body: {
          data: btoa("Due tomorrow").replace(/\+/g, "-").replace(/\//g, "_"),
        },
      };
      for (let depth = 0; depth < 40; depth += 1) {
        nested = { mimeType: "multipart/mixed", parts: [nested] };
      }
      return Promise.resolve(Response.json({
        ...message,
        payload: {
          mimeType: "multipart/mixed",
          headers: originalPayload.headers,
          parts: [nested],
        },
      }));
    }
    if (requestedId === "good-message") {
      return Promise.resolve(Response.json(gmailMessage(requestedId)));
    }
    return Promise.reject(new Error("unexpected Gmail URL"));
  });
  const connector = new GmailReadonlyConnector({
    configuration: configuration(),
    runtime: safeRuntime.value,
    credentials: {
      connection: {
        connectionId,
        providerAccountHash: accountHash,
        connectionState: "connected",
        syncCursor: null,
        connectedAt: null,
        encryptedOauthBundle: new Uint8Array(30),
        encryptionKeyVersion: 1,
        credentialVersion: 1,
        expiresAt: null,
      },
      accessToken: () => Promise.resolve("gmail-access-secret"),
      revocationToken: () => Promise.resolve("gmail-refresh-secret"),
    },
  });
  const page = await connector.fetchPage({
    cursor: null,
    receivedAfter: "2026-07-08T00:00:00.000Z",
    limit: 10,
  });
  assert(
    page.messages.length === requestedIds.length,
    "page cardinality stays stable",
  );
  for (let index = 0; index < requestedIds.length - 1; index += 1) {
    const failed = page.messages[index];
    const expectedCategory = requestedIds[index] === "oversized-json" ||
        requestedIds[index] === "deep-parts"
      ? "oversized_content"
      : "malformed_content";
    assert(
      failed.providerMessageId === requestedIds[index],
      "failure is bound to the requested provider ID",
    );
    assert(
      failed.failureCategory === expectedCategory &&
        failed.body === "" && failed.subject === "" && failed.sender === "",
      "poison message becomes one metadata-only safe marker",
    );
  }
  for (const requestedId of ["bad-id", "mismatched-id"] as const) {
    const failed = page.messages[requestedIds.indexOf(requestedId)];
    assert(
      failed.providerThreadId === null &&
        failed.receivedAt === "2026-07-22T00:00:00.000Z",
      "an invalid or mismatched response cannot supply envelope metadata",
    );
  }
  const good = page.messages.at(-1)!;
  assert(
    good.providerMessageId === "good-message" &&
      good.failureCategory === undefined && good.body === "Due tomorrow",
    "the remaining message is still decoded",
  );
  assert(page.nextCursor !== null && page.hasMore === false, "page advances");
  assert(
    calls.length === requestedIds.length + 2 &&
      calls.every((url) => new URL(url).hostname === "gmail.googleapis.com"),
    "only profile, list, and the listed Gmail messages are fetched",
  );
  assert(
    !JSON.stringify(safeRuntime.audits).includes("gmail-access-secret"),
    "provider secrets are never audited",
  );
});

Deno.test("Gmail retries one 401 through trusted refresh then maps expired history", async () => {
  const forced: boolean[] = [];
  let requestCount = 0;
  const safeRuntime = runtime(() => {
    requestCount += 1;
    if (requestCount === 1) {
      return Promise.resolve(new Response("", { status: 401 }));
    }
    if (requestCount === 2) {
      return Promise.resolve(Response.json({ historyId: "100" }));
    }
    return Promise.resolve(new Response("", { status: 404 }));
  });
  const credentials = {
    connection: {} as StoredCredentials,
    accessToken: (force = false) => {
      forced.push(force);
      return Promise.resolve(force ? "refreshed" : "old");
    },
    revocationToken: () => Promise.resolve("refresh"),
  };
  const connector = new GmailReadonlyConnector({
    configuration: configuration(),
    runtime: safeRuntime.value,
    credentials,
  });
  try {
    await connector.fetchPage({
      cursor: null,
      receivedAfter: "2026-07-08T00:00:00.000Z",
      limit: 10,
    });
    throw new Error("404 accepted");
  } catch (error) {
    assert(
      error instanceof SafeEmailError && error.category === "cursor_expired",
      "expired provider cursor state",
    );
  }
  assert(forced[0] === false && forced[1] === true, "one forced refresh");
});

Deno.test("production model request is strict JSON-only with no tools/images/store", async () => {
  let outbound = "";
  const safeRuntime = runtime((_input, init) => {
    outbound = String(init?.body ?? "");
    return Promise.resolve(
      Response.json({ output_text: JSON.stringify(validCandidate()) }),
    );
  });
  const client = new OpenAIJsonModelClient(configuration(), safeRuntime.value);
  const extractor = new ModelEmailTaskExtractor({ enabled: true, client });
  const candidate = await extractor.extract({
    receivedAt: "2026-07-22T00:00:00.000Z",
    timezone: "Asia/Tokyo",
    sanitizedSubject: "課題",
    sanitizedContent: "明日までに提出",
    sanitizedSenderLabel: "Teacher",
  });
  assert(candidate.requires_user_confirmation, "strict output revalidated");
  const request = JSON.parse(outbound) as Record<string, unknown>;
  assert(!Object.hasOwn(request, "tools"), "no tools capability");
  assert(!outbound.includes("input_image"), "no image input");
  assert(!outbound.includes("http://"), "no link fetch instruction");
  assert(
    outbound.includes(modelSystemInstruction),
    "untrusted-data instruction",
  );
  assert(outbound.includes('"strict":true'), "strict JSON schema");
  assert(outbound.includes('"store":false'), "provider storage disabled");
  assert(
    !JSON.stringify(safeRuntime.audits).includes("明日までに提出"),
    "body not logged",
  );
});

Deno.test("JWT authenticator validates remotely and never trusts request owner", async () => {
  let capturedAuthorization = "";
  let capturedApiKey = "";
  const safeRuntime = runtime((_input, init) => {
    const headers = new Headers(init?.headers);
    capturedAuthorization = headers.get("authorization") ?? "";
    capturedApiKey = headers.get("apikey") ?? "";
    return Promise.resolve(Response.json({ id: ownerUserId }));
  });
  const authenticator = new SupabaseJwtAuthenticator(
    configuration(),
    safeRuntime.value,
  );
  const caller = await authenticator.authenticate(
    new Request(
      "https://project.example.invalid/functions/v1/email-import",
      {
        method: "POST",
        headers: { authorization: "Bearer caller-jwt-secret-marker" },
        body: JSON.stringify({ ownerUserId: "attacker" }),
      },
    ),
  );
  assert(caller.ownerUserId === ownerUserId, "auth server owns identity");
  assert(
    capturedAuthorization === "Bearer caller-jwt-secret-marker",
    "caller JWT validated",
  );
  assert(
    capturedApiKey === environment.SUPABASE_SERVICE_ROLE_KEY,
    "trusted API key",
  );
});

Deno.test("RPC adapter calls exactly the accepted service-role contracts", async () => {
  const calls: {
    readonly name: string;
    readonly body: Record<string, unknown>;
  }[] = [];
  const metadataCalls: {
    readonly url: URL;
    readonly init: RequestInit | undefined;
  }[] = [];
  const safeRuntime = runtime((input, init) => {
    const url = new URL(input.toString());
    if (init?.method === "GET") {
      metadataCalls.push({ url, init });
      return Promise.resolve(Response.json([{ id: connectionId }]));
    }
    const name = url.pathname.split("/").pop()!;
    const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
    calls.push({ name, body });
    const connection = {
      connection_id: connectionId,
      connection_state: name.includes("disconnect")
        ? "disconnected"
        : "connected",
      sync_cursor: null,
      connected_at: "2026-07-22T00:00:00.000Z",
      last_synced_at: "2026-07-22T00:00:00.000Z",
      credential_version: 2,
    };
    if (name === "email_import_take_oauth") {
      return Promise.resolve(Response.json({
        owner_user_id: ownerUserId,
        connection_id: connectionId,
        encrypted_pkce_verifier_base64: btoa(
          String.fromCharCode(...new Uint8Array(30)),
        ),
        encryption_key_version: 1,
        expires_at: "2026-07-22T00:10:00.000Z",
        correlation_id: correlationId,
      }));
    }
    if (name === "email_import_get_credentials") {
      return Promise.resolve(Response.json({
        ...connection,
        provider: "gmail",
        provider_account_hash: accountHash,
        encrypted_oauth_bundle_base64: btoa(
          String.fromCharCode(...new Uint8Array(30)),
        ),
        encryption_key_version: 1,
        expires_at: "2026-07-22T01:00:00.000Z",
      }));
    }
    if (name === "email_import_check_authorization") {
      return Promise.resolve(Response.json({
        requested_connection_id: connectionId,
        effective_connection_id: connectionId,
        connection_state: "connected",
        last_error_category: null,
        retry_after_at: null,
        connected_at: "2026-07-22T00:00:00.000Z",
      }));
    }
    if (name === "email_import_rotate_credentials") {
      return Promise.resolve(Response.json({ credential_version: 2 }));
    }
    if (name === "email_import_persist_sync_page") {
      return Promise.resolve(Response.json({
        connection,
        page: {
          items: [],
          suppressions: [],
          next_cursor: "cursor",
          has_more: false,
          connected_at: "2026-07-22T00:00:00.000Z",
        },
      }));
    }
    const failedItem = {
      providerMessageId: "message-retry",
      providerThreadId: `failed:${"f".repeat(64)}`,
      receivedAt: "2026-07-22T00:00:00.000Z",
      sanitizedContentHash: "5".repeat(64),
      evidenceExcerpts: [],
      candidate: null,
      errorCategory: "timeout",
    };
    if (name === "email_import_get_sync_replay") {
      return Promise.resolve(Response.json({
        items: [],
        suppressions: [],
        next_cursor: "cursor",
        has_more: false,
        connected_at: "2026-07-22T00:00:00.000Z",
      }));
    }
    if (name === "email_import_get_owner_timezone") {
      return Promise.resolve(Response.json("Asia/Tokyo"));
    }
    if (name === "email_import_get_retry_replay") {
      return Promise.resolve(Response.json({
        retry_outcome: "suppressed",
        item: null,
        suppression: {
          providerMessageIdHash: "7".repeat(64),
          reason: "dismissed",
        },
        connected_at: "2026-07-22T00:00:00.000Z",
      }));
    }
    if (name === "email_import_assert_retry_candidate") {
      return Promise.resolve(Response.json(true));
    }
    if (name === "email_import_persist_retry_candidate") {
      return Promise.resolve(Response.json({
        connection,
        retry_outcome: "persisted",
        item: failedItem,
        suppression: null,
      }));
    }
    if (name === "email_import_delete_account_data") {
      return Promise.resolve(Response.json({
        deleted_connections: 1,
        deleted_sources: 1,
        deleted_candidates: 1,
        deleted_updates: 1,
      }));
    }
    if (name === "email_import_begin_oauth") {
      return Promise.resolve(Response.json({
        connection_id: connectionId,
        expires_at: "2026-07-22T00:10:00.000Z",
      }));
    }
    if (name.startsWith("email_import_reconcile_")) {
      const action = name.endsWith("confirmation")
        ? "confirmation"
        : name.endsWith("dismissal")
        ? "dismissal"
        : "update";
      return Promise.resolve(Response.json({
        connection_id: connectionId,
        connection_state: "connected",
        action,
        outcome: action === "confirmation"
          ? "confirmed"
          : action === "dismissal"
          ? "dismissed"
          : body.p_resolution,
        entity_type: action === "dismissal" ? null : body.p_entity_type,
        entity_id: action === "dismissal" ? null : body.p_entity_id,
        replayed: false,
      }));
    }
    return Promise.resolve(Response.json(connection));
  });
  const store = new PostgrestTrustedEmailStore(
    configuration(),
    safeRuntime.value,
  );
  const encrypted = new Uint8Array(30).fill(1);
  await store.beginOauth({
    ownerUserId,
    connectionId,
    stateHash: "1".repeat(64),
    encryptedPkceVerifier: encrypted,
    encryptionKeyVersion: 1,
    expiresAt: "2026-07-22T00:10:00.000Z",
    correlationId,
  });
  await store.takeOauth("1".repeat(64), "2026-07-22T00:01:00.000Z");
  await store.completeOauth({
    ownerUserId,
    connectionId,
    providerAccountHash: accountHash,
    authorizedScopes: [gmailReadOnlyScope],
    encryptedOauthBundle: encrypted,
    encryptionKeyVersion: 1,
    expiresAt: "2026-07-22T01:00:00.000Z",
    initialSyncCursor: null,
    connectedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  await store.checkAuthorization({
    ownerUserId,
    requestedConnectionId: connectionId,
    callbackCorrelationId: correlationId,
  });
  await store.getCredentials(ownerUserId, connectionId);
  await store.rotateCredentials({
    ownerUserId,
    connectionId,
    expectedCredentialVersion: 1,
    encryptedOauthBundle: encrypted,
    encryptionKeyVersion: 1,
    expiresAt: "2026-07-22T01:00:00.000Z",
    rotatedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  await store.persistSyncPage({
    ownerUserId,
    connectionId,
    expectedCursor: null,
    nextCursor: "cursor",
    sources: [],
    candidates: [],
    hasMore: false,
    syncedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  await store.getSyncReplay({
    ownerUserId,
    connectionId,
    expectedCursor: null,
  });
  assert(
    await store.getOwnerTimezone({ ownerUserId, connectionId }) ===
      "Asia/Tokyo",
    "owner timezone is parsed",
  );
  await store.getRetryReplay({
    ownerUserId,
    connectionId,
    providerMessageId: "message-retry",
    expectedSanitizedContentHash: "5".repeat(64),
    retryIdempotencyKey: "6".repeat(64),
  });
  await store.assertRetryCandidate({
    ownerUserId,
    connectionId,
    providerMessageId: "message-retry",
    expectedSanitizedContentHash: "5".repeat(64),
  });
  await store.persistRetryCandidate({
    ownerUserId,
    connectionId,
    sources: [{ provider_message_id: "message-retry" }],
    candidates: [],
    expectedSanitizedContentHash: "5".repeat(64),
    retryIdempotencyKey: "6".repeat(64),
    retriedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  const reconciliationIdentity = {
    ownerUserId,
    connectionId,
    provider: "gmail" as const,
    providerAccountHash: accountHash,
    providerMessageIdHash: "2".repeat(64),
    providerThreadIdHash: "3".repeat(64),
    sanitizedContentHash: "4".repeat(64),
    idempotencyKey: "email-reconciliation-key",
    reconciledAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  };
  await store.reconcileConfirmation({
    ...reconciliationIdentity,
    reviewedPayload: validCandidate(),
    entityType: "assignment",
    entityId: reconciliationEntityId,
  });
  await store.reconcileDismissal({
    ...reconciliationIdentity,
    idempotencyKey: "email-dismissal-key",
  });
  await store.reconcileUpdate({
    ...reconciliationIdentity,
    idempotencyKey: "email-update-key",
    resolution: "rejected",
    entityType: "assignment",
    entityId: reconciliationEntityId,
  });
  await store.finalizeDisconnect({
    ownerUserId,
    connectionId,
    deleteDerivedData: true,
    revocationAttempted: true,
    revocationSucceeded: false,
    disconnectedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  const listed = await store.listOwnedConnectionIds(ownerUserId);
  assert(listed.length === 1 && listed[0] === connectionId, "safe ID listing");
  await store.deleteAccountData({
    ownerUserId,
    deletedAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  await store.recordFailure({
    ownerUserId,
    connectionId,
    operation: "fetch",
    connectionState: "rate_limited",
    errorCategory: "rate_limited",
    retryAfterAt: "2026-07-22T00:01:00.000Z",
    occurredAt: "2026-07-22T00:00:00.000Z",
    correlationId,
  });
  assert(calls.length === 18, "all eighteen RPC calls exercised");
  assert(
    calls.map((call) => call.name).join(",") === [
      "email_import_begin_oauth",
      "email_import_take_oauth",
      "email_import_complete_oauth",
      "email_import_check_authorization",
      "email_import_get_credentials",
      "email_import_rotate_credentials",
      "email_import_persist_sync_page",
      "email_import_get_sync_replay",
      "email_import_get_owner_timezone",
      "email_import_get_retry_replay",
      "email_import_assert_retry_candidate",
      "email_import_persist_retry_candidate",
      "email_import_reconcile_confirmation",
      "email_import_reconcile_dismissal",
      "email_import_reconcile_update",
      "email_import_finalize_disconnect",
      "email_import_delete_account_data",
      "email_import_record_failure",
    ].join(","),
    "exact RPC names",
  );
  assert(
    Object.keys(calls[6].body).sort().join(",") === [
      "p_candidates",
      "p_connection_id",
      "p_correlation_id",
      "p_expected_cursor",
      "p_has_more",
      "p_next_cursor",
      "p_owner_user_id",
      "p_sources",
      "p_synced_at",
    ].sort().join(","),
    "exact persist params",
  );
  assert(metadataCalls.length === 1, "one bounded metadata query");
  const metadata = metadataCalls[0];
  assert(
    metadata.url.pathname.endsWith("/rest/v1/email_connections"),
    "fixed table",
  );
  assert(metadata.url.searchParams.get("select") === "id", "only ID selected");
  assert(
    metadata.url.searchParams.get("owner_user_id") === `eq.${ownerUserId}`,
    "owner filter",
  );
  assert(
    metadata.url.searchParams.get("provider") === "eq.gmail",
    "Gmail filter",
  );
  assert(metadata.url.searchParams.get("limit") === "100", "bounded listing");
  assert(
    (metadata.init?.headers as Record<string, string>).authorization ===
      `Bearer ${environment.SUPABASE_SERVICE_ROLE_KEY}`,
    "service role only",
  );
  assert(
    calls[17].body.p_operation === "fetch",
    "exact failure operation parameter",
  );
  assert(
    Object.keys(calls[12].body).sort().join(",") === [
      "p_connection_id",
      "p_correlation_id",
      "p_entity_id",
      "p_entity_type",
      "p_idempotency_key",
      "p_owner_user_id",
      "p_provider",
      "p_provider_account_hash",
      "p_provider_message_id_hash",
      "p_provider_thread_id_hash",
      "p_reconciled_at",
      "p_reviewed_payload",
      "p_sanitized_content_hash",
    ].sort().join(","),
    "confirmation RPC receives only the strict reconciliation contract",
  );
  assert(
    Object.keys(calls[11].body).sort().join(",") === [
      "p_candidates",
      "p_connection_id",
      "p_correlation_id",
      "p_expected_content_hash",
      "p_idempotency_key",
      "p_owner_user_id",
      "p_retried_at",
      "p_sources",
    ].sort().join(","),
    "retry persistence receives only its exact private receipt contract",
  );
  assert(
    JSON.stringify(safeRuntime.audits) === "[]",
    "RPC payloads never logged",
  );
});

Deno.test("RPC adapter rejects duplicate or malformed suppression hashes", async () => {
  const failedItem = {
    providerMessageId: "message-overlap",
    providerThreadId: `failed:${"f".repeat(64)}`,
    receivedAt: "2026-07-22T00:00:00.000Z",
    sanitizedContentHash: "5".repeat(64),
    evidenceExcerpts: [],
    candidate: null,
    errorCategory: "timeout",
  };
  const connection = {
    connection_id: connectionId,
    connection_state: "connected",
    sync_cursor: "cursor",
    connected_at: "2026-07-22T00:00:00.000Z",
  };
  const overlappingRuntime = runtime(() =>
    Promise.resolve(Response.json({
      connection,
      page: {
        items: [failedItem],
        suppressions: [
          { providerMessageIdHash: "8".repeat(64), reason: "dismissed" },
          { providerMessageIdHash: "8".repeat(64), reason: "deduplicated" },
        ],
        next_cursor: "cursor-next",
        has_more: false,
        connected_at: "2026-07-22T00:00:00.000Z",
      },
    }))
  );
  const overlappingStore = new PostgrestTrustedEmailStore(
    configuration(),
    overlappingRuntime.value,
  );
  let overlapRejected = false;
  try {
    await overlappingStore.persistSyncPage({
      ownerUserId,
      connectionId,
      expectedCursor: "cursor",
      nextCursor: "cursor-next",
      sources: [],
      candidates: [],
      hasMore: false,
      syncedAt: "2026-07-22T00:00:00.000Z",
      correlationId,
    });
  } catch (error) {
    overlapRejected = error instanceof SafeEmailError &&
      error.category === "provider_unavailable";
  }
  assert(
    overlapRejected,
    "suppression hashes must be unique",
  );

  const mismatchedRuntime = runtime(() =>
    Promise.resolve(Response.json({
      retry_outcome: "suppressed",
      item: null,
      suppression: {
        providerMessageIdHash: "different-message",
        reason: "deduplicated",
      },
      connected_at: "2026-07-22T00:00:00.000Z",
    }))
  );
  const mismatchedStore = new PostgrestTrustedEmailStore(
    configuration(),
    mismatchedRuntime.value,
  );
  let mismatchRejected = false;
  try {
    await mismatchedStore.getRetryReplay({
      ownerUserId,
      connectionId,
      providerMessageId: "message-retry",
      expectedSanitizedContentHash: "5".repeat(64),
      retryIdempotencyKey: "6".repeat(64),
    });
  } catch (error) {
    mismatchRejected = error instanceof SafeEmailError &&
      error.category === "provider_unavailable";
  }
  assert(
    mismatchRejected,
    "retry suppression hashes must be exact lowercase hex",
  );
});
