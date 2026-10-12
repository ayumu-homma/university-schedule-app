import {
  type DocumentImportEndpointDependencies,
  handleDocumentImportRequest,
} from "./index.ts";
import {
  DeterministicDocumentScheduleExtractor,
  GuardedDocumentScheduleExtractor,
} from "./extraction.ts";
import { type DocumentProductionConfiguration } from "./production.ts";
import {
  syntheticOwnerId,
  syntheticSourceId,
  syntheticStoredDocument,
} from "./test_support/synthetic_document_fixtures.ts";
import {
  type DocumentCandidateReplacement,
  type DocumentImportErrorCategory,
  type DocumentProcessingClaim,
  SafeDocumentError,
  type ScheduleCandidateBatchV1,
} from "./types.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const syntheticOpenAiProjectKey = "sk-" + "proj-" +
  "synthetic_project_fixture_".repeat(2) + "value";

const enabledEnvironment: Readonly<Record<string, string>> = Object.freeze({
  APP_ENV: "local",
  APP_SUPABASE_PROJECT_REF: "local",
  DOCUMENT_IMPORT_ENABLED: "true",
  DOCUMENT_IMPORT_MODEL_ENABLED: "true",
  DOCUMENT_IMPORT_FAKE_ENABLED: "false",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_ANON_KEY: "synthetic-anon-key",
  OPENAI_API_KEY: syntheticOpenAiProjectKey,
  DOCUMENT_IMPORT_MODEL_ID: "synthetic-model",
  DOCUMENT_IMPORT_PROVIDER: "openai_responses",
  DOCUMENT_IMPORT_TIMEOUT_MS: "1000",
});

const readEnabledEnvironment = (name: string) => enabledEnvironment[name];

function request(
  body: unknown,
  options: { readonly authorization?: string } = {},
) {
  return new Request("https://edge.example/document-import", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: options.authorization ?? "Bearer synthetic.jwt.value",
    },
    body: JSON.stringify(body),
  });
}

function endpointConfiguration(
  timeoutMs = 1_000,
): DocumentProductionConfiguration {
  return {
    appEnvironment: "local",
    supabaseProjectRef: "local",
    supabaseUrl: new URL("http://127.0.0.1:54321/"),
    supabaseAnonKey: "synthetic-anon-key",
    openAiApiKey: syntheticOpenAiProjectKey,
    modelId: "synthetic-model",
    requestTimeoutMs: timeoutMs,
    providerMaximumAttempts: 2,
    providerRetryBaseDelayMs: 0,
  };
}

async function dependencies(options: {
  readonly timeoutMs?: number;
  readonly extractor?: DocumentImportEndpointDependencies["extractor"];
  readonly authenticate?:
    DocumentImportEndpointDependencies["authenticator"]["authenticate"];
  readonly storedOwnerId?: string;
  readonly claim?: DocumentProcessingClaim;
  readonly replacement?: DocumentCandidateReplacement;
  readonly replayedBatch?: ScheduleCandidateBatchV1;
  readonly onBegin?: (sourceId: string) => void;
  readonly onSourceLoad?: (expectedVersion: number) => void;
  readonly onPersist?: (
    batch: ScheduleCandidateBatchV1,
    expectedVersion: number,
  ) => void;
  readonly onFail?: (
    category: DocumentImportErrorCategory,
    retryAfterSeconds: number | null,
    expectedVersion: number,
  ) => void;
} = {}): Promise<DocumentImportEndpointDependencies> {
  const claim: DocumentProcessingClaim = options.claim ?? {
    sourceId: syntheticSourceId,
    processingState: "processing",
    attemptCount: 1,
    version: 2,
    replayed: false,
  };
  const stored = await syntheticStoredDocument({
    ownerUserId: options.storedOwnerId ?? syntheticOwnerId,
    processingState: "processing",
    processingAttemptCount: 1,
    version: claim.version,
  });
  const replayedBatch = options.replayedBatch ?? {
    schema_version: "1.0",
    source_id: syntheticSourceId,
    content_hash: stored.source.content_hash,
    timezone: "Asia/Tokyo",
    candidates: [],
  };
  return {
    configuration: endpointConfiguration(options.timeoutMs),
    runtime: { fetch, now: () => new Date("2026-08-10T00:00:00Z") },
    authenticator: {
      authenticate: options.authenticate ?? (() =>
        Promise.resolve({
          ownerUserId: syntheticOwnerId,
          authorization: "Bearer synthetic.jwt.value",
        })),
    },
    processingStore: {
      beginProcessing: (_caller, sourceId) => {
        options.onBegin?.(sourceId);
        return Promise.resolve(claim);
      },
      loadProcessedBatch: () => Promise.resolve(replayedBatch),
      failProcessing: (
        _caller,
        _sourceId,
        expectedVersion,
        category,
        retryAfterSeconds,
      ) => {
        options.onFail?.(category, retryAfterSeconds, expectedVersion);
        return Promise.resolve();
      },
    },
    sourceStore: {
      loadOwnedSource: (_caller, _sourceId, expectedVersion) => {
        options.onSourceLoad?.(expectedVersion);
        return Promise.resolve(stored);
      },
    },
    candidateStore: {
      replaceCandidates: (_caller, batch, expectedVersion) => {
        options.onPersist?.(batch, expectedVersion);
        return Promise.resolve(
          options.replacement ?? {
            sourceId: batch.source_id,
            processingState: "processed",
            candidateCount: batch.candidates.length,
            version: expectedVersion + 1,
            replayed: false,
          },
        );
      },
    },
    extractor: options.extractor ?? new GuardedDocumentScheduleExtractor(
      new DeterministicDocumentScheduleExtractor(),
    ),
  };
}

async function responseJson(
  response: Response,
): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

Deno.test("document import is hidden when feature flag is disabled", async () => {
  let factoryCalled = false;
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    () => undefined,
    () => {
      factoryCalled = true;
      throw new Error("must not compose");
    },
  );
  assert(response.status === 404, "hidden");
  assert(!factoryCalled, "no production composition");
  assert(response.headers.get("cache-control") === "no-store", "no store");
});

Deno.test("enabled import fails closed when server configuration is absent", async () => {
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    (name) => name === "DOCUMENT_IMPORT_ENABLED" ? "true" : undefined,
  );
  assert(response.status === 503, "configuration status");
  const body = await responseJson(response);
  assert(
    JSON.stringify(body).includes("configuration_missing"),
    "safe category",
  );
  assert(
    !JSON.stringify(body).includes("OPENAI_API_KEY"),
    "secret name absent",
  );
});

Deno.test("authenticated exact source request returns and persists strict batch", async () => {
  const persisted: { value?: ScheduleCandidateBatchV1; version?: number } = {};
  const order: string[] = [];
  const deps = await dependencies({
    onBegin: () => order.push("begin"),
    onSourceLoad: () => order.push("storage"),
    onPersist: (batch, version) => {
      order.push("replace");
      persisted.value = batch;
      persisted.version = version;
    },
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 200, "success");
  const body = await responseJson(
    response,
  ) as unknown as ScheduleCandidateBatchV1;
  assert(body.schema_version === "1.0", "schema");
  assert(body.source_id === syntheticSourceId, "source");
  assert(body.candidates.length === 3, "three candidates");
  assert(persisted.value?.content_hash === body.content_hash, "persisted hash");
  assert(persisted.value?.candidates.length === 3, "persisted candidates");
  assert(persisted.version === 2, "claim version forwarded");
  assert(order.join(",") === "begin,storage,replace", "claimed first");
});

Deno.test("replace candidate-count mismatch fails closed and records a bounded failure", async () => {
  const failures: Array<{
    readonly category: DocumentImportErrorCategory;
    readonly retryAfterSeconds: number | null;
    readonly version: number;
  }> = [];
  const deps = await dependencies({
    replacement: {
      sourceId: syntheticSourceId,
      processingState: "processed",
      candidateCount: 2,
      version: 3,
      replayed: false,
    },
    onFail: (category, retryAfterSeconds, version) => {
      failures.push({ category, retryAfterSeconds, version });
    },
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  const body = await responseJson(response);
  assert(response.status === 422, "closed response");
  assert(
    JSON.stringify(body).includes("invalid_extraction"),
    "bounded category",
  );
  assert(failures.length === 1, "failure recorded once");
  assert(failures[0].category === "invalid_extraction", "failure category");
  assert(failures[0].retryAfterSeconds === null, "not retryable");
  assert(failures[0].version === 2, "claim version retained");
});

Deno.test("replace replay returns persisted candidates instead of the raced extraction", async () => {
  const prepared = await syntheticStoredDocument();
  const replayedBatch: ScheduleCandidateBatchV1 = {
    schema_version: "1.0",
    source_id: syntheticSourceId,
    content_hash: prepared.source.content_hash,
    timezone: "Asia/Tokyo",
    candidates: [],
  };
  const deps = await dependencies({
    replayedBatch,
    replacement: {
      sourceId: syntheticSourceId,
      processingState: "processed",
      candidateCount: 3,
      version: 3,
      replayed: true,
    },
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  const body = await responseJson(
    response,
  ) as unknown as ScheduleCandidateBatchV1;
  assert(response.status === 200, "replayed replacement success");
  assert(body.candidates.length === 0, "persisted batch returned");
  assert(
    body.content_hash === replayedBatch.content_hash,
    "persisted identity",
  );
});

Deno.test("processed replay loads persisted candidates without Storage or model work", async () => {
  const prepared = await syntheticStoredDocument();
  const replayedBatch: ScheduleCandidateBatchV1 = {
    schema_version: "1.0",
    source_id: syntheticSourceId,
    content_hash: prepared.source.content_hash,
    timezone: "Asia/Tokyo",
    candidates: [],
  };
  let sourceLoaded = false;
  let extracted = false;
  let persisted = false;
  const deps = await dependencies({
    claim: {
      sourceId: syntheticSourceId,
      processingState: "processed",
      attemptCount: 1,
      version: 3,
      replayed: true,
    },
    replayedBatch,
    onSourceLoad: () => sourceLoaded = true,
    extractor: {
      extract: () => {
        extracted = true;
        return Promise.resolve({});
      },
    },
    onPersist: () => persisted = true,
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 200, "replay success");
  const body = await responseJson(
    response,
  ) as unknown as ScheduleCandidateBatchV1;
  assert(body.content_hash === replayedBatch.content_hash, "persisted batch");
  assert(!sourceLoaded && !extracted && !persisted, "provider short-circuit");
});

Deno.test("request accepts exact source_id only and no path or URL", async () => {
  const deps = await dependencies();
  for (
    const body of [
      { source_id: syntheticSourceId, storage_path: "owner/private.pdf" },
      { source_id: syntheticSourceId, url: "https://example.test/private.pdf" },
      { sourceId: syntheticSourceId },
    ]
  ) {
    const response = await handleDocumentImportRequest(
      request(body),
      readEnabledEnvironment,
      () => deps,
    );
    assert(response.status === 404, `rejected ${JSON.stringify(body)}`);
    const json = JSON.stringify(await responseJson(response));
    assert(!json.includes("private.pdf"), "path not echoed");
    assert(!json.includes("example.test"), "URL not echoed");
  }
});

Deno.test("chunked request body is bounded before JSON parsing", async () => {
  const deps = await dependencies();
  const response = await handleDocumentImportRequest(
    new Request("https://edge.example/document-import", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer synthetic.jwt.value",
      },
      body: new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(4_097));
          controller.close();
        },
      }),
    }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 422, "bounded");
  const body = await responseJson(response) as {
    error: { category: string };
  };
  assert(body.error.category === "oversized_document", "safe category");
});

Deno.test("authentication failure is a redacted 401", async () => {
  const deps = await dependencies({
    authenticate: () => Promise.reject(new SafeDocumentError("unauthorized")),
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 401, "unauthorized");
  assert(
    JSON.stringify(await responseJson(response)).includes("unauthorized"),
    "category",
  );
});

Deno.test("owner mismatch is rejected before extraction or persistence", async () => {
  let extracted = false;
  let persisted = false;
  const deps = await dependencies({
    storedOwnerId: "33333333-3333-4333-8333-333333333333",
    extractor: {
      extract: () => {
        extracted = true;
        return Promise.resolve({});
      },
    },
    onPersist: () => persisted = true,
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 404, "not found");
  assert(!extracted && !persisted, "no downstream work");
});

Deno.test("timeout is bounded, retryable, and never persists", async () => {
  let persisted = false;
  const failures: Array<{
    category: DocumentImportErrorCategory;
    retryAfterSeconds: number | null;
    version: number;
  }> = [];
  const deps = await dependencies({
    timeoutMs: 5,
    extractor: { extract: () => new Promise(() => {}) },
    onPersist: () => persisted = true,
    onFail: (category, retryAfterSeconds, version) =>
      failures.push({
        category,
        retryAfterSeconds,
        version,
      }),
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 504, "timeout");
  const body = await responseJson(response) as {
    error: { category: string; retryable: boolean };
  };
  assert(
    body.error.category === "timeout" && body.error.retryable,
    "retryable",
  );
  assert(!persisted, "not persisted");
  assert(failures.length === 1, "failure persisted");
  assert(failures[0].category === "timeout", "bounded category");
  assert(failures[0].retryAfterSeconds === null, "no invented delay");
  assert(failures[0].version === 2, "failure CAS version");
});

Deno.test("safe retry republishes identical IDs without duplicate mutation", async () => {
  const guarded = new GuardedDocumentScheduleExtractor(
    new DeterministicDocumentScheduleExtractor(),
  );
  let attempts = 0;
  const extractor = {
    extract: async (input: Parameters<typeof guarded.extract>[0]) => {
      attempts += 1;
      if (attempts === 1) {
        throw new SafeDocumentError("rate_limited", { retryAfterMs: 2_000 });
      }
      return await guarded.extract(input);
    },
  };
  const persisted: ScheduleCandidateBatchV1[] = [];
  const failures: Array<{
    category: DocumentImportErrorCategory;
    retryAfterSeconds: number | null;
  }> = [];
  const deps = await dependencies({
    extractor,
    onPersist: (batch) => persisted.push(batch),
    onFail: (category, retryAfterSeconds) =>
      failures.push({
        category,
        retryAfterSeconds,
      }),
  });
  const first = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(first.status === 429, "first rate limited");
  const firstBody = await responseJson(first) as {
    error: { retry_after_seconds: number; retryable: boolean };
  };
  assert(firstBody.error.retryable, "retry allowed");
  assert(firstBody.error.retry_after_seconds === 2, "retry hint");
  const second = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(second.status === 200, "retry succeeds");
  const replay = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(replay.status === 200, "replay succeeds");
  assert(persisted.length === 2, "only successful RPC attempts");
  assert(
    failures.length === 1 && failures[0].category === "rate_limited" &&
      failures[0].retryAfterSeconds === 2,
    "transient failure recorded",
  );
  assert(
    JSON.stringify(persisted[0].candidates.map((item) => item.candidate_id)) ===
      JSON.stringify(persisted[1].candidates.map((item) => item.candidate_id)),
    "stable replay IDs",
  );
});

Deno.test("provider diagnostics, raw content, and filenames never enter error JSON", async () => {
  const failures: DocumentImportErrorCategory[] = [];
  const deps = await dependencies({
    extractor: {
      extract: () =>
        Promise.reject(
          new Error(
            "private-syllabus.pdf raw body provider stack synthetic-server-secret",
          ),
        ),
    },
    onFail: (category) => failures.push(category),
  });
  const response = await handleDocumentImportRequest(
    request({ source_id: syntheticSourceId }),
    readEnabledEnvironment,
    () => deps,
  );
  assert(response.status === 503, "internal error");
  const body = JSON.stringify(await responseJson(response));
  assert(body.includes("internal_error"), "safe category");
  for (
    const secret of [
      "private-syllabus",
      "raw body",
      "provider stack",
      "synthetic-server-secret",
    ]
  ) {
    assert(!body.includes(secret), `redacted ${secret}`);
  }
  assert(
    failures.length === 1 && failures[0] === "internal_error",
    "unknown failure persisted as bounded category",
  );
});

Deno.test("method and CORS surface remain closed", async () => {
  const get = await handleDocumentImportRequest(
    new Request("https://edge.example/document-import", { method: "GET" }),
  );
  assert(get.status === 405, "GET rejected");
  const options = await handleDocumentImportRequest(
    new Request("https://edge.example/document-import", { method: "OPTIONS" }),
  );
  assert(options.status === 204, "preflight");
  assert(
    options.headers.get("access-control-allow-methods") === "POST, OPTIONS",
    "closed methods",
  );
});
