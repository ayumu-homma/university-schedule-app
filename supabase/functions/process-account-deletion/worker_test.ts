import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { runAccountDeletionWorker } from "./worker.ts";

const prepared = {
  operation_id: "operation-id",
  user_id: "user-id",
  phase: "object_cleanup" as const,
  objects: [{ bucket_id: "private-documents", name: "user-id/source.pdf" }],
};

Deno.test("requested deletion completes every irreversible phase in order", async () => {
  const stepsTaken: string[] = [];
  const phase = await runAccountDeletionWorker("requested", {
    revokeProviderData: async () => void stepsTaken.push("provider"),
    prepareDatabase: async () => {
      stepsTaken.push("database");
      return prepared;
    },
    removeStorage: async (objects) => {
      assertEquals(objects, prepared.objects);
      stepsTaken.push("storage");
    },
    confirmStorageRemoved: async () => void stepsTaken.push("storage-confirmed"),
    deleteAuthIdentity: async () => void stepsTaken.push("auth"),
    finish: async () => void stepsTaken.push("complete"),
  });

  assertEquals(phase, "complete");
  assertEquals(stepsTaken, [
    "provider",
    "database",
    "storage",
    "storage-confirmed",
    "auth",
    "complete",
  ]);
});

Deno.test("Storage failure never advances to Auth deletion or completion", async () => {
  const stepsTaken: string[] = [];
  await assertRejects(
    () => runAccountDeletionWorker("object_cleanup", {
      revokeProviderData: async () => void stepsTaken.push("provider"),
      prepareDatabase: async () => {
        stepsTaken.push("database");
        return prepared;
      },
      removeStorage: async () => {
        stepsTaken.push("storage");
        throw new Error("storage_cleanup_failed");
      },
      confirmStorageRemoved: async () => void stepsTaken.push("storage-confirmed"),
      deleteAuthIdentity: async () => void stepsTaken.push("auth"),
      finish: async () => void stepsTaken.push("complete"),
    }),
    Error,
    "storage_cleanup_failed",
  );
  assertEquals(stepsTaken, ["database", "storage"]);
});

Deno.test("auth_delete retry skips completed provider and Storage phases", async () => {
  const stepsTaken: string[] = [];
  const authDeletePhase = { ...prepared, phase: "auth_delete" as const };
  await runAccountDeletionWorker("auth_delete", {
    revokeProviderData: async () => void stepsTaken.push("provider"),
    prepareDatabase: async () => {
      stepsTaken.push("database");
      return authDeletePhase;
    },
    removeStorage: async () => void stepsTaken.push("storage"),
    confirmStorageRemoved: async () => void stepsTaken.push("storage-confirmed"),
    deleteAuthIdentity: async () => void stepsTaken.push("auth"),
    finish: async () => void stepsTaken.push("complete"),
  });
  assertEquals(stepsTaken, ["database", "auth", "complete"]);
});

Deno.test("complete deletion is an idempotent no-op", async () => {
  let called = false;
  const phase = await runAccountDeletionWorker("complete", {
    revokeProviderData: async () => void (called = true),
    prepareDatabase: async () => {
      called = true;
      return prepared;
    },
    removeStorage: async () => void (called = true),
    confirmStorageRemoved: async () => void (called = true),
    deleteAuthIdentity: async () => void (called = true),
    finish: async () => void (called = true),
  });
  assertEquals(phase, "complete");
  assertEquals(called, false);
});
