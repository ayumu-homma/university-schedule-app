import { handleRequest, verificationTestUtils } from "./index.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrows(action: () => unknown, message: string): void {
  try {
    action();
  } catch {
    return;
  }
  throw new Error(message);
}

Deno.test("normalizes a valid address without exposing it in the mask", () => {
  const normalized = verificationTestUtils.normalizeEmail(
    "  Student@ST.KANAZAWA-IT.AC.JP  ",
  );
  assert(
    normalized.email === "student@st.kanazawa-it.ac.jp",
    "email should be normalized",
  );
  assert(
    verificationTestUtils.maskEmail(normalized.email) ===
      "s***@st.kanazawa-it.ac.jp",
    "mask should retain only one local-part character",
  );
});

Deno.test("rejects malformed addresses and exact-domain suffix attacks", () => {
  assertThrows(
    () => verificationTestUtils.normalizeEmail("two@@example.edu"),
    "multiple-at address must fail",
  );
  const exactRule = {
    id: "rule",
    domain: "st.kanazawa-it.ac.jp",
    kind: "student_email",
    match_subdomains: false,
    verification_enabled: true,
  };
  assert(
    verificationTestUtils.domainMatches(
      exactRule,
      "st.kanazawa-it.ac.jp",
    ),
    "exact domain should match",
  );
  assert(
    !verificationTestUtils.domainMatches(
      exactRule,
      "st.kanazawa-it.ac.jp.attacker.example",
    ),
    "suffix attack must fail",
  );
  assert(
    !verificationTestUtils.domainMatches(
      exactRule,
      "mail.st.kanazawa-it.ac.jp",
    ),
    "subdomain must fail for exact rules",
  );
});

Deno.test("generates bounded OTPs and context-separated HMAC values", async () => {
  for (let index = 0; index < 100; index += 1) {
    assert(/^\d{6}$/.test(verificationTestUtils.createOtp()), "OTP shape");
  }
  const secret = "test-only-secret-that-is-longer-than-thirty-two-bytes";
  const emailHmac = await verificationTestUtils.hmacHex(
    secret,
    "university-email:v1\u0000student@example.edu",
  );
  const codeHmac = await verificationTestUtils.hmacHex(
    secret,
    "university-code:v1\u0000request\u0000123456",
  );
  assert(/^[0-9a-f]{64}$/.test(emailHmac), "HMAC should be SHA-256 hex");
  assert(emailHmac !== codeHmac, "HMAC contexts must remain distinct");
  assert(!emailHmac.includes("student"), "HMAC must not expose its input");
});

Deno.test("issue flow sends raw values only to the trusted webhook", async () => {
  const environment = {
    SUPABASE_URL: "https://project.example",
    SUPABASE_ANON_KEY: "publishable-test-key",
    SUPABASE_SERVICE_ROLE_KEY: "service-test-key",
    UNIVERSITY_VERIFICATION_HMAC_SECRET:
      "test-only-hmac-secret-with-at-least-thirty-two-bytes",
    UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_URL:
      "https://mailer.example/transactional",
    UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_TOKEN: "webhook-test-token",
  };
  const previousEnvironment = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(environment)) {
    previousEnvironment.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }

  const originalFetch = globalThis.fetch;
  const serviceBodies: string[] = [];
  let webhookBody = "";
  globalThis.fetch = async (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    if (url.endsWith("/auth/v1/user")) {
      return Response.json({ id: "11111111-1111-4111-8111-111111111111" });
    }
    if (url.includes("/rest/v1/university_email_verifications?")) {
      return Response.json([
        {
          request_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          domain_rule_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          status: "pending",
        },
      ]);
    }
    if (url.includes("/rest/v1/university_domains?")) {
      return Response.json([
        {
          id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          domain: "st.kanazawa-it.ac.jp",
          kind: "student_email",
          match_subdomains: false,
          verification_enabled: true,
        },
      ]);
    }
    if (
      url.endsWith(
        "/rest/v1/rpc/issue_university_email_verification_challenge",
      )
    ) {
      serviceBodies.push(String(init?.body ?? ""));
      return Response.json([
        {
          challenge_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          expires_at: "2030-01-01T00:10:00.000Z",
        },
      ]);
    }
    if (url === environment.UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_URL) {
      webhookBody = String(init?.body ?? "");
      return new Response(null, { status: 202 });
    }
    throw new Error(`unexpected mocked URL: ${url}`);
  };

  try {
    const response = await handleRequest(
      new Request(
        "https://project.example/functions/v1/university-email-verification",
        {
          method: "POST",
          headers: {
            authorization: "Bearer user-test-token",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            action: "issue",
            requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            email: "Student@st.kanazawa-it.ac.jp",
          }),
        },
      ),
    );
    assert(response.status === 202, "issue should be accepted");
    const responseBody = await response.text();
    assert(
      responseBody.includes("s***@st.kanazawa-it.ac.jp"),
      "response should contain only a masked address",
    );
    assert(!responseBody.includes("student@"), "response must hide full email");

    assert(serviceBodies.length === 1, "one trusted issue RPC expected");
    const serviceBody = serviceBodies[0];
    assert(
      !serviceBody.toLowerCase().includes("student@"),
      "database request must not contain the raw email",
    );
    const parsedServiceBody = JSON.parse(serviceBody) as Record<
      string,
      unknown
    >;
    assert(
      typeof parsedServiceBody.p_email_hmac === "string" &&
        /^[0-9a-f]{64}$/.test(parsedServiceBody.p_email_hmac),
      "database receives an email HMAC",
    );
    assert(
      typeof parsedServiceBody.p_challenge_hmac === "string" &&
        /^[0-9a-f]{64}$/.test(parsedServiceBody.p_challenge_hmac),
      "database receives a code HMAC",
    );

    const parsedWebhook = JSON.parse(webhookBody) as {
      to?: string;
      variables?: { code?: string };
    };
    assert(
      parsedWebhook.to === "student@st.kanazawa-it.ac.jp",
      "trusted mailer receives normalized address",
    );
    assert(
      typeof parsedWebhook.variables?.code === "string" &&
        /^\d{6}$/.test(parsedWebhook.variables.code),
      "trusted mailer receives a bounded OTP",
    );
    assert(
      !serviceBody.includes(parsedWebhook.variables?.code ?? "impossible"),
      "database request must not contain the raw OTP",
    );
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, previous] of previousEnvironment) {
      if (previous === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, previous);
      }
    }
  }
});

Deno.test("HTTP boundary rejects unsupported methods without configuration", async () => {
  const response = await handleRequest(
    new Request("http://127.0.0.1/functions/v1/university-email-verification"),
  );
  assert(response.status === 405, "GET must be rejected");
  assert(
    response.headers.get("cache-control") === "no-store",
    "sensitive responses must not be cached",
  );
});
