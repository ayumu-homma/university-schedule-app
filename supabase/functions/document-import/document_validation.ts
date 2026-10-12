import {
  type DocumentMediaType,
  documentMediaTypes,
  type PersistedDocumentSource,
  SafeDocumentError,
  type SanitizedDocumentInput,
  type StoredDocumentInput,
} from "./types.ts";

export const documentInputLimits = Object.freeze({
  maximumFileBytes: 10 * 1024 * 1024,
  maximumPages: 80,
  maximumTextCharacters: 200_000,
  maximumImagePixels: 40_000_000,
});

const utf8Decoder = new TextDecoder("utf-8", { fatal: true });
const latinDecoder = new TextDecoder("latin1");
const encoder = new TextEncoder();
const sha256Pattern = /^[a-f0-9]{64}$/;

export async function sha256Bytes(bytes: Uint8Array): Promise<string> {
  const digestInput = new Uint8Array(new ArrayBuffer(bytes.byteLength));
  digestInput.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", digestInput.buffer);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function startsWith(bytes: Uint8Array, signature: readonly number[]): boolean {
  return signature.every((byte, index) => bytes[index] === byte);
}

function endsWith(bytes: Uint8Array, signature: readonly number[]): boolean {
  if (bytes.length < signature.length) return false;
  const offset = bytes.length - signature.length;
  return signature.every((byte, index) => bytes[offset + index] === byte);
}

function detectedBinaryMediaType(bytes: Uint8Array): DocumentMediaType | null {
  if (
    bytes.length >= 8 &&
    startsWith(bytes, [0x25, 0x50, 0x44, 0x46, 0x2d])
  ) {
    return "application/pdf";
  }
  if (
    bytes.length >= 8 &&
    startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  ) {
    return "image/png";
  }
  if (bytes.length >= 4 && startsWith(bytes, [0xff, 0xd8, 0xff])) {
    return "image/jpeg";
  }
  return null;
}

function hasKnownNonTextSignature(bytes: Uint8Array): boolean {
  const signatures: readonly (readonly number[])[] = [
    [0x50, 0x4b, 0x03, 0x04], // ZIP / OOXML
    [0x50, 0x4b, 0x05, 0x06],
    [0x50, 0x4b, 0x07, 0x08],
    [0x1f, 0x8b], // gzip
    [0x7f, 0x45, 0x4c, 0x46], // ELF
    [0x4d, 0x5a], // PE executable
    [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1], // OLE compound
    [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07], // RAR
    [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], // 7-Zip
    [0x47, 0x49, 0x46, 0x38], // GIF
    [0x42, 0x4d], // BMP
    [0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66], // SQLite
  ];
  if (signatures.some((signature) => startsWith(bytes, signature))) {
    return true;
  }
  return bytes.length >= 12 &&
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes.subarray(8), [0x57, 0x45, 0x42, 0x50]);
}

function decodeEntities(value: string): string {
  const named: Readonly<Record<string, string>> = {
    amp: "&",
    lt: "<",
    gt: ">",
    quot: '"',
    apos: "'",
    nbsp: " ",
  };
  return value.replace(
    /&(?:#(\d+)|#x([0-9a-f]+)|([a-z]+));/gi,
    (match, decimal: string, hexadecimal: string, name: string) => {
      let codePoint: number | null = null;
      if (decimal !== undefined) codePoint = Number(decimal);
      if (hexadecimal !== undefined) {
        codePoint = Number.parseInt(hexadecimal, 16);
      }
      if (
        codePoint !== null && Number.isInteger(codePoint) && codePoint > 0 &&
        codePoint <= 0x10ffff && !(codePoint >= 0xd800 && codePoint <= 0xdfff)
      ) {
        return String.fromCodePoint(codePoint);
      }
      return named[name?.toLowerCase()] ?? match;
    },
  );
}

/** Removes executable/active markup while preserving inert visible text. */
export function sanitizeDocumentText(value: string): string {
  let sanitized = value.split("\u0000").join("");
  sanitized = sanitized.replace(
    /<\s*(script|style|iframe|object|embed|svg)\b[^>]*>[\s\S]*?<\s*\/\s*\1\s*>/gi,
    " ",
  );
  sanitized = sanitized.replace(
    /<\s*\/?\s*(?:script|style|iframe|object|embed|svg)\b[^>]*>/gi,
    " ",
  );
  sanitized = sanitized.replace(/<!--[\s\S]*?-->/g, " ");
  sanitized = sanitized.replace(/<[^>]{0,4096}>/g, " ");
  sanitized = decodeEntities(sanitized);
  sanitized = sanitized.replace(/javascript\s*:/gi, "");
  sanitized = sanitized.replace(/\r\n?/g, "\n");
  sanitized = sanitized.replace(/[\t\f\v ]+/g, " ");
  sanitized = sanitized.replace(/ *\n */g, "\n");
  sanitized = sanitized.replace(/\n{3,}/g, "\n\n");
  return sanitized.trim();
}

function assertTextBound(value: string): void {
  if (Array.from(value).length > documentInputLimits.maximumTextCharacters) {
    throw new SafeDocumentError("oversized_document");
  }
}

function validatePlainText(bytes: Uint8Array): {
  readonly pageCount: number;
  readonly text: string;
} {
  if (hasKnownNonTextSignature(bytes)) {
    throw new SafeDocumentError("spoofed_media_type");
  }
  let raw: string;
  try {
    raw = utf8Decoder.decode(bytes);
  } catch {
    throw new SafeDocumentError("corrupt_document");
  }
  if (
    Array.from(raw).some((character) => {
      const rune = character.codePointAt(0) ?? 0;
      return rune === 0 ||
        (rune < 0x20 && ![0x09, 0x0a, 0x0c, 0x0d].includes(rune));
    })
  ) {
    throw new SafeDocumentError("spoofed_media_type");
  }
  assertTextBound(raw);
  const text = sanitizeDocumentText(raw);
  if (text.length === 0) throw new SafeDocumentError("unsafe_content");
  assertTextBound(text);
  return { pageCount: 1, text };
}

function unescapePdfLiteral(value: string): string {
  return value
    .replace(/\\([nrtbf()\\])/g, (_match, escaped: string) => {
      const replacements: Readonly<Record<string, string>> = {
        n: "\n",
        r: "\r",
        t: "\t",
        b: " ",
        f: " ",
        "(": "(",
        ")": ")",
        "\\": "\\",
      };
      return replacements[escaped] ?? escaped;
    })
    .replace(/\\[0-7]{1,3}/g, " ");
}

function validatePdf(bytes: Uint8Array): {
  readonly pageCount: number;
  readonly text: string;
} {
  if (bytes.length < 32) throw new SafeDocumentError("corrupt_document");
  const raw = latinDecoder.decode(bytes);
  if (!/^%PDF-1\.[0-9]/.test(raw.slice(0, 16))) {
    throw new SafeDocumentError("corrupt_document");
  }
  if (/\/Encrypt\b|\/Filter\s*\/Standard\b/.test(raw)) {
    throw new SafeDocumentError("encrypted_document");
  }
  const eofIndex = raw.lastIndexOf("%%EOF");
  if (eofIndex < raw.length - 2_048 || eofIndex < 0) {
    throw new SafeDocumentError("corrupt_document");
  }
  const pages = raw.match(/\/Type\s*\/Page\b/g)?.length ?? 0;
  if (pages < 1) throw new SafeDocumentError("corrupt_document");
  if (pages > documentInputLimits.maximumPages) {
    throw new SafeDocumentError("oversized_document");
  }
  const extracted: string[] = [];
  for (const match of raw.matchAll(/\(((?:\\.|[^()\\])*)\)\s*Tj\b/g)) {
    extracted.push(unescapePdfLiteral(match[1]));
    if (
      extracted.reduce((sum, part) => sum + Array.from(part).length, 0) >
        documentInputLimits.maximumTextCharacters
    ) {
      throw new SafeDocumentError("oversized_document");
    }
  }
  const visible = sanitizeDocumentText(extracted.join("\n"));
  assertTextBound(visible);
  return {
    pageCount: pages,
    text: visible.length === 0 ? `[PDF document: ${pages} page(s)]` : visible,
  };
}

function uint32(bytes: Uint8Array, offset: number): number {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    .getUint32(offset, false);
}

function validatePng(bytes: Uint8Array): {
  readonly pageCount: number;
  readonly text: string;
} {
  if (
    bytes.length < 33 ||
    String.fromCharCode(...bytes.slice(12, 16)) !== "IHDR" ||
    !endsWith(bytes, [0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
  ) {
    throw new SafeDocumentError("corrupt_document");
  }
  const width = uint32(bytes, 16);
  const height = uint32(bytes, 20);
  if (
    width < 1 || height < 1 ||
    width * height > documentInputLimits.maximumImagePixels
  ) {
    throw new SafeDocumentError("oversized_document");
  }
  return { pageCount: 1, text: "[PNG image supplied as inert document data]" };
}

const jpegStartOfFrameMarkers = new Set([
  0xc0,
  0xc1,
  0xc2,
  0xc3,
  0xc5,
  0xc6,
  0xc7,
  0xc9,
  0xca,
  0xcb,
  0xcd,
  0xce,
  0xcf,
]);

function validateJpeg(bytes: Uint8Array): {
  readonly pageCount: number;
  readonly text: string;
} {
  if (bytes.length < 12 || !endsWith(bytes, [0xff, 0xd9])) {
    throw new SafeDocumentError("corrupt_document");
  }
  let offset = 2;
  let dimensions: { readonly width: number; readonly height: number } | null =
    null;
  while (offset + 3 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset];
    offset += 1;
    if (marker === undefined || marker === 0xd9) break;
    if (
      marker === 0x00 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)
    ) {
      continue;
    }
    if (offset + 1 >= bytes.length) {
      throw new SafeDocumentError("corrupt_document");
    }
    const segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2 || offset + segmentLength > bytes.length) {
      throw new SafeDocumentError("corrupt_document");
    }
    if (jpegStartOfFrameMarkers.has(marker)) {
      if (segmentLength < 7) throw new SafeDocumentError("corrupt_document");
      dimensions = {
        height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        width: (bytes[offset + 5] << 8) | bytes[offset + 6],
      };
    }
    if (marker === 0xda) break;
    offset += segmentLength;
  }
  if (
    dimensions === null || dimensions.width < 1 || dimensions.height < 1 ||
    dimensions.width * dimensions.height >
      documentInputLimits.maximumImagePixels
  ) {
    throw new SafeDocumentError(
      dimensions === null ? "corrupt_document" : "oversized_document",
    );
  }
  return { pageCount: 1, text: "[JPEG image supplied as inert document data]" };
}

function validateBytesForMedia(
  mediaType: DocumentMediaType,
  bytes: Uint8Array,
): { readonly pageCount: number; readonly text: string } {
  const detected = detectedBinaryMediaType(bytes);
  if (mediaType === "text/plain") {
    if (detected !== null) throw new SafeDocumentError("spoofed_media_type");
    return validatePlainText(bytes);
  }
  if (detected !== mediaType) throw new SafeDocumentError("spoofed_media_type");
  switch (mediaType) {
    case "application/pdf":
      return validatePdf(bytes);
    case "image/png":
      return validatePng(bytes);
    case "image/jpeg":
      return validateJpeg(bytes);
  }
}

function assertSourceMetadata(source: PersistedDocumentSource): void {
  if (!documentMediaTypes.includes(source.media_type)) {
    throw new SafeDocumentError("unsupported_type");
  }
  if (
    !Number.isInteger(source.byte_size) || source.byte_size < 1 ||
    source.byte_size > documentInputLimits.maximumFileBytes
  ) {
    throw new SafeDocumentError("oversized_file");
  }
  if (!sha256Pattern.test(source.content_hash)) {
    throw new SafeDocumentError("corrupt_document");
  }
  if (source.deleted_at !== null) {
    throw new SafeDocumentError("source_not_found");
  }
  if (!Number.isFinite(Date.parse(source.created_at))) {
    throw new SafeDocumentError("corrupt_document");
  }
}

export async function validateStoredDocument(
  stored: StoredDocumentInput,
): Promise<SanitizedDocumentInput> {
  const { source, bytes } = stored;
  assertSourceMetadata(source);
  if (
    bytes.byteLength !== source.byte_size || bytes.byteLength < 1 ||
    bytes.byteLength > documentInputLimits.maximumFileBytes
  ) {
    throw new SafeDocumentError(
      bytes.byteLength > documentInputLimits.maximumFileBytes
        ? "oversized_file"
        : "corrupt_document",
    );
  }
  const contentHash = await sha256Bytes(bytes);
  if (contentHash !== source.content_hash) {
    throw new SafeDocumentError("corrupt_document");
  }
  const validated = validateBytesForMedia(source.media_type, bytes);
  if (
    encoder.encode(validated.text).byteLength >
      documentInputLimits.maximumFileBytes
  ) {
    throw new SafeDocumentError("oversized_document");
  }
  return Object.freeze({
    sourceId: source.id,
    contentHash,
    mediaType: source.media_type,
    bytes,
    byteLength: bytes.byteLength,
    pageCount: validated.pageCount,
    sanitizedText: validated.text,
    uploadedAt: source.created_at,
    timezone: "Asia/Tokyo",
  });
}
