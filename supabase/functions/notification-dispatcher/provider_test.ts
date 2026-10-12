import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { classifyProviderResponse, fcmMessage } from "./provider.ts";

Deno.test("FCM payload contains a generic copy and opaque inbox identity only", () => {
  const payload = fcmMessage({
    inbox_id: "inbox-opaque-id",
    token: "provider-token-test-only",
    notification_type: "group_comment",
  });
  const encoded = JSON.stringify(payload);
  assertEquals(payload.message.data, { inbox_id: "inbox-opaque-id" });
  assertEquals(payload.message.notification.body, "新しいコメントがあります");
  assertNotEquals(encoded.includes("group name"), true);
  assertNotEquals(encoded.includes("comment body"), true);
});

Deno.test("FCM success, invalid token, retryable and permanent responses classify", () => {
  assertEquals(classifyProviderResponse(200, "{}").outcome, "sent");
  assertEquals(
    classifyProviderResponse(404, '{"error":{"status":"NOT_FOUND"}}').outcome,
    "invalid_token",
  );
  assertEquals(classifyProviderResponse(429, "{}").outcome, "retry");
  assertEquals(classifyProviderResponse(503, "{}").outcome, "retry");
  assertEquals(classifyProviderResponse(400, "{}").outcome, "permanent");
  assertEquals(classifyProviderResponse(401, "{}").outcome, "permanent");
});
