import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  runAccountDeletionWorker,
  type AccountDeletionPhase,
  type DeletionStorageObject,
  type PreparedAccountDeletion,
} from "./worker.ts";

type WorkerContext = { user_id: string; phase: AccountDeletionPhase };

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
}

function errorResponse(error: unknown): Response {
  const code = error instanceof Error && /^[a-z_]{1,48}$/.test(error.message)
    ? error.message
    : "deletion_processing_failed";
  return json(500, { error: code });
}

async function recordFailure(
  service: SupabaseClient,
  operationId: string,
  code: string,
): Promise<void> {
  await service.rpc("record_account_deletion_failure", {
    p_operation_id: operationId,
    p_error_code: code,
  });
}

async function removeManifest(
  service: SupabaseClient,
  objects: DeletionStorageObject[],
): Promise<void> {
  const buckets = new Map<string, Set<string>>();
  for (const object of objects) {
    if (
      !object || typeof object.bucket_id !== "string" ||
      typeof object.name !== "string" || object.name.length === 0
    ) throw new Error("invalid_storage_manifest");
    const names = buckets.get(object.bucket_id) ?? new Set<string>();
    names.add(object.name);
    buckets.set(object.bucket_id, names);
  }
  for (const [bucket, nameSet] of buckets) {
    const names = [...nameSet];
    for (let offset = 0; offset < names.length; offset += 100) {
      const { error } = await service.storage.from(bucket).remove(
        names.slice(offset, offset + 100),
      );
      if (error) throw new Error("storage_cleanup_failed");
    }
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

  let operationId = "";
  let service: SupabaseClient | null = null;
  try {
    const authorization = request.headers.get("authorization") ?? "";
    const match = /^Bearer\s+(.+)$/i.exec(authorization);
    if (!match) return json(401, { error: "authentication_required" });
    const token = match[1];
    const body = await request.json();
    operationId = typeof body?.operation_id === "string" ? body.operation_id : "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(operationId)) {
      return json(400, { error: "invalid_operation_id" });
    }

    const url = env("SUPABASE_URL");
    const anonKey = env("SUPABASE_ANON_KEY");
    const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
    const caller = createClient(url, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: callerData, error: callerError } = await caller.auth.getUser(token);
    if (callerError || !callerData.user) return json(401, { error: "authentication_required" });

    const workerService = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    service = workerService;
    const { data: contextRows, error: contextError } = await workerService.rpc(
      "get_account_deletion_worker_context",
      { p_operation_id: operationId },
    );
    if (contextError) throw new Error("operation_lookup_failed");
    const context = (contextRows as WorkerContext[] | null)?.[0];
    if (!context || context.user_id !== callerData.user.id) {
      return json(404, { error: "operation_unavailable" });
    }
    if (!(["requested", "object_cleanup", "auth_delete", "complete"] as string[])
      .includes(context.phase)) throw new Error("unexpected_deletion_phase");

    await runAccountDeletionWorker(context.phase, {
      revokeProviderData: async () => {
        const response = await fetch(`${url}/functions/v1/email-import`, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${token}`,
            "apikey": anonKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ action: "delete_account_data" }),
        });
        if (!response.ok) throw new Error("provider_cleanup_failed");
      },
      prepareDatabase: async () => {
        const { data, error } = await workerService.rpc(
          "prepare_account_deletion_database",
          { p_operation_id: operationId },
        );
        if (error) throw new Error("database_cleanup_failed");
        const prepared = data as PreparedAccountDeletion;
        if (!prepared || prepared.user_id !== callerData.user.id) {
          throw new Error("operation_unavailable");
        }
        return prepared;
      },
      removeStorage: async (objects) => {
        try {
          await removeManifest(workerService, objects);
        } catch {
          throw new Error("storage_cleanup_failed");
        }
      },
      confirmStorageRemoved: async () => {
        const { error } = await workerService.rpc("mark_account_deletion_objects_removed", {
          p_operation_id: operationId,
        });
        if (error) throw new Error("storage_confirmation_failed");
      },
      deleteAuthIdentity: async () => {
        const { error: deleteError } = await workerService.auth.admin.deleteUser(
          callerData.user.id,
        );
        if (!deleteError) return;
        const { data: lookup, error: lookupError } = await workerService.auth.admin
          .getUserById(callerData.user.id);
        if (lookupError || lookup.user) throw new Error("auth_cleanup_failed");
      },
      finish: async () => {
        const { error } = await workerService.rpc("finish_account_deletion", {
          p_operation_id: operationId,
        });
        if (error) throw new Error("completion_record_failed");
      },
    });
    return json(200, { phase: "complete" });
  } catch (error) {
    if (service && operationId) {
      const code = error instanceof Error && /^[a-z_]{1,48}$/.test(error.message)
        ? error.message
        : "deletion_processing_failed";
      await recordFailure(service, operationId, code);
    }
    return errorResponse(error);
  }
});
