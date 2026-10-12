interface TestUser {
  id: string;
  email: string;
  password: string;
}

interface Fixture {
  owner: TestUser;
  friend: TestUser;
  outsider: TestUser;
  anonKey: string;
  ownerId: string;
  termId: string;
}

const fixture = JSON.parse(
  await Deno.readTextFile("/scratch/fixtures.json"),
) as Fixture;
const authUrl = "http://p84-share01-20260928-v15-auth:9999";
const restUrl = "http://p84-share01-20260928-v15-rest:3000";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function signIn(user: TestUser): Promise<string> {
  const response = await fetch(`${authUrl}/token?grant_type=password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: user.email, password: user.password }),
    signal: AbortSignal.timeout(10_000),
  });
  const body = await response.json().catch(() => ({})) as {
    access_token?: unknown;
  };
  assert(
    response.ok && typeof body.access_token === "string",
    `synthetic GoTrue sign-in failed: HTTP ${response.status}`,
  );
  return body.access_token;
}

async function listTerms(token: string, ownerId: string) {
  const response = await fetch(`${restUrl}/rpc/list_friend_terms`, {
    method: "POST",
    headers: {
      apikey: fixture.anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ p_owner_user_id: ownerId }),
    signal: AbortSignal.timeout(10_000),
  });
  const value = await response.json().catch(() => null);
  return { status: response.status, value };
}

Deno.test("GoTrue friend terms are limited to accepted sharing relationships", async () => {
  const ownerToken = await signIn(fixture.owner);
  const friendToken = await signIn(fixture.friend);
  const outsiderToken = await signIn(fixture.outsider);

  const ownerRows = await listTerms(ownerToken, fixture.ownerId);
  assert(
    ownerRows.status === 200 && Array.isArray(ownerRows.value),
    "owner term positive control failed",
  );
  const ownerTerm = (ownerRows.value as Record<string, unknown>[]).find(
    (row) => row.term_id === fixture.termId,
  );
  assert(ownerTerm, "owner did not receive its own term");

  const friendRows = await listTerms(friendToken, fixture.ownerId);
  assert(
    friendRows.status === 200 && Array.isArray(friendRows.value),
    "accepted friend term lookup failed",
  );
  const friendTerm = (friendRows.value as Record<string, unknown>[]).find(
    (row) => row.term_id === fixture.termId,
  );
  assert(
    friendTerm?.name === "P106 synthetic shared term" &&
      friendTerm.academic_year === 2026 &&
      Object.keys(friendTerm).sort().join(",") ===
        "academic_year,end_date,name,start_date,term_id",
    "friend projection did not match the minimal term contract",
  );

  const outsiderRows = await listTerms(outsiderToken, fixture.ownerId);
  assert(
    outsiderRows.status === 200 && Array.isArray(outsiderRows.value) &&
      outsiderRows.value.length === 0,
    "unrelated authenticated user received a term or an unexpected response",
  );
  console.log(
    "friend_terms_api=owner-positive,accepted-friend-one-term,unrelated-user-empty; credentials_and_tokens=omitted",
  );
});
