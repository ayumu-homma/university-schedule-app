export type AccountDeletionPhase =
  | "requested"
  | "object_cleanup"
  | "auth_delete"
  | "complete";

export type DeletionStorageObject = { bucket_id: string; name: string };
export type PreparedAccountDeletion = {
  operation_id: string;
  phase: AccountDeletionPhase;
  user_id: string;
  objects: DeletionStorageObject[];
};

export type AccountDeletionWorkerSteps = {
  revokeProviderData(): Promise<void>;
  prepareDatabase(): Promise<PreparedAccountDeletion>;
  removeStorage(objects: DeletionStorageObject[]): Promise<void>;
  confirmStorageRemoved(): Promise<void>;
  deleteAuthIdentity(): Promise<void>;
  finish(): Promise<void>;
};

/// Runs the irreversible phases in order. Each step is injected so the same
/// sequence and failure gates can be tested without a live Auth or Storage API.
export async function runAccountDeletionWorker(
  phase: AccountDeletionPhase,
  steps: AccountDeletionWorkerSteps,
): Promise<AccountDeletionPhase> {
  if (phase === "complete") return "complete";
  if (phase === "requested") await steps.revokeProviderData();

  const prepared = await steps.prepareDatabase();
  if (prepared.phase === "object_cleanup") {
    if (!Array.isArray(prepared.objects)) throw new Error("invalid_storage_manifest");
    await steps.removeStorage(prepared.objects);
    await steps.confirmStorageRemoved();
  } else if (prepared.phase !== "auth_delete") {
    throw new Error("unexpected_deletion_phase");
  }

  await steps.deleteAuthIdentity();
  await steps.finish();
  return "complete";
}
