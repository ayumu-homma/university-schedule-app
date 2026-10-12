import { sha256Bytes } from "../document_validation.ts";
import {
  type DocumentMediaType,
  type PersistedDocumentSource,
  type StoredDocumentInput,
} from "../types.ts";

export const syntheticOwnerId = "11111111-1111-4111-8111-111111111111";
export const syntheticSourceId = "22222222-2222-4222-8222-222222222222";

export function syntheticPdf(options: {
  readonly pages?: number;
  readonly marker?: string;
  readonly encrypted?: boolean;
  readonly corrupt?: boolean;
} = {}): Uint8Array {
  const pages = options.pages ?? 18;
  const pageObjects = Array.from(
    { length: pages },
    (_, index) => `${index + 1} 0 obj << /Type /Page /Parent 99 0 R >> endobj`,
  ).join("\n");
  const encryption = options.encrypted ? "/Encrypt 77 0 R" : "";
  const marker = options.marker ?? "synthetic class schedule";
  const eof = options.corrupt ? "" : "\n%%EOF";
  return new TextEncoder().encode(
    `%PDF-1.4\n${pageObjects}\n${encryption}\nBT (${marker}) Tj ET${eof}`,
  );
}

export function syntheticPng(): Uint8Array {
  const bytes = new Uint8Array(41);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  bytes.set([0x00, 0x00, 0x00, 0x0d], 8);
  bytes.set([0x49, 0x48, 0x44, 0x52], 12);
  bytes.set([0x00, 0x00, 0x00, 0x20], 16);
  bytes.set([0x00, 0x00, 0x00, 0x20], 20);
  bytes.set([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82], 33);
  return bytes;
}

export function syntheticJpeg(): Uint8Array {
  return new Uint8Array([
    0xff,
    0xd8,
    0xff,
    0xc0,
    0x00,
    0x0b,
    0x08,
    0x00,
    0x20,
    0x00,
    0x20,
    0x01,
    0x01,
    0x11,
    0x00,
    0xff,
    0xd9,
  ]);
}

export function syntheticText(marker = "synthetic class schedule"): Uint8Array {
  return new TextEncoder().encode(marker);
}

function extensionFor(mediaType: DocumentMediaType): string {
  switch (mediaType) {
    case "application/pdf":
      return "pdf";
    case "image/png":
      return "png";
    case "image/jpeg":
      return "jpg";
    case "text/plain":
      return "txt";
  }
}

export async function syntheticStoredDocument(options: {
  readonly bytes?: Uint8Array;
  readonly mediaType?: DocumentMediaType;
  readonly ownerUserId?: string;
  readonly sourceId?: string;
  readonly contentHash?: string;
  readonly byteSize?: number;
  readonly storagePath?: string;
  readonly deletedAt?: string | null;
  readonly processingState?: string;
  readonly errorCategory?: string | null;
  readonly processingAttemptCount?: number;
  readonly retryAfterAt?: string | null;
  readonly retentionExpiresAt?: string;
  readonly version?: number;
} = {}): Promise<StoredDocumentInput> {
  const bytes = options.bytes ?? syntheticPdf();
  const mediaType = options.mediaType ?? "application/pdf";
  const owner = options.ownerUserId ?? syntheticOwnerId;
  const sourceId = options.sourceId ?? syntheticSourceId;
  const contentHash = options.contentHash ?? await sha256Bytes(bytes);
  const source: PersistedDocumentSource = Object.freeze({
    id: sourceId,
    owner_user_id: owner,
    storage_path: options.storagePath ??
      `${owner}/${sourceId}/source.${extensionFor(mediaType)}`,
    media_type: mediaType,
    byte_size: options.byteSize ?? bytes.byteLength,
    content_hash: contentHash,
    processing_state: options.processingState ?? "uploaded",
    error_category: options.errorCategory ?? null,
    processing_attempt_count: options.processingAttemptCount ?? 0,
    retry_after_at: options.retryAfterAt ?? null,
    retention_expires_at: options.retentionExpiresAt ??
      "2026-09-09T00:00:00.000Z",
    created_at: "2026-08-10T00:00:00.000Z",
    updated_at: "2026-08-10T00:00:00.000Z",
    deleted_at: options.deletedAt ?? null,
    version: options.version ?? 1,
  });
  return Object.freeze({ source, bytes });
}
