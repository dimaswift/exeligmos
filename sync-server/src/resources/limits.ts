import { HttpProblem } from "../http/problem.js";

/** Records can contain media descriptions and encrypted bodies, so their pages are
 * deliberately much smaller than lightweight event and owner-resource pages. */
export const RECORD_PAGE_DEFAULT_LIMIT = 10;
export const RECORD_PAGE_MAX_LIMIT = 25;

/** Maximum UTF-8 bytes in the compact JSON representation accepted by the API. */
export const PUBLIC_RECORD_PAYLOAD_MAX_BYTES = 256 * 1_024;
export const RESOURCE_METADATA_MAX_BYTES = 32 * 1_024;

/** Raw AES-GCM ciphertext bytes, including the 16-byte authentication tag. */
export const PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES = 512 * 1_024;
export const PRIVATE_RECORD_CIPHERTEXT_BASE64_MAX_LENGTH =
  4 * Math.ceil(PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES / 3);

export function parseRecordPageLimit(value: unknown): number {
  if (value === undefined) {
    return RECORD_PAGE_DEFAULT_LIMIT;
  }
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > RECORD_PAGE_MAX_LIMIT) {
    throw new HttpProblem({
      status: 400,
      code: "invalid_request",
      title: "Bad Request",
      type: "urn:exeligmos:problem:invalid-request",
      detail: `limit must be an integer between 1 and ${RECORD_PAGE_MAX_LIMIT}.`,
    });
  }
  return parsed;
}

export function assertSerializedJsonSize(
  value: unknown,
  maximumBytes: number,
  fieldPath: string,
): void {
  const serialized = postgresJsonbCompactJson(value);
  const actualBytes = Buffer.byteLength(serialized, "utf8");
  if (actualBytes <= maximumBytes) {
    return;
  }

  const normalizedCode = `${fieldPath.replaceAll(/[^A-Za-z0-9]+/g, "_")}_too_large`
    .replaceAll(/^_+|_+$/g, "")
    .toLowerCase();
  throw new HttpProblem({
    status: 422,
    code: normalizedCode,
    title: "Unprocessable Content",
    type: `urn:exeligmos:problem:${normalizedCode.replaceAll("_", "-")}`,
    detail: `${fieldPath} must serialize to at most ${maximumBytes} UTF-8 bytes.`,
    extensions: {
      errors: [
        {
          path: `/${fieldPath.replaceAll(".", "/")}`,
          code: normalizedCode,
          message: `${fieldPath} exceeds the ${maximumBytes}-byte limit.`,
        },
      ],
      maximumBytes,
      actualBytes,
    },
  });
}

/**
 * Compact JSON matching PostgreSQL JSONB scalar rendering. PostgreSQL expands
 * exponent-form numbers, so plain JSON.stringify byte counts can otherwise
 * pass here and then fail the database constraint for the same document.
 */
export function postgresJsonbCompactJson(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (typeof value === "string") {
    assertPostgresText(value);
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      return "null";
    }
    return expandScientificNumber(JSON.stringify(value));
  }
  if (Array.isArray(value)) {
    return `[${Array.from(value, (item) => postgresJsonbCompactJson(item ?? null)).join(",")}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, child]) => child !== undefined)
      .map(([key, child]) => {
        assertPostgresText(key);
        return `${JSON.stringify(key)}:${postgresJsonbCompactJson(child)}`;
      });
    return `{${entries.join(",")}}`;
  }
  throw new HttpProblem({
    status: 400,
    code: "invalid_request",
    title: "Bad Request",
    type: "urn:exeligmos:problem:invalid-request",
    detail: "The request contains a value that cannot be represented as JSON.",
  });
}

function assertPostgresText(value: string): void {
  let previousWasHighSurrogate = false;
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit === 0) {
      throw invalidPostgresJson();
    }
    const isHighSurrogate = codeUnit >= 0xd800 && codeUnit <= 0xdbff;
    const isLowSurrogate = codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
    if (previousWasHighSurrogate !== isLowSurrogate) {
      throw invalidPostgresJson();
    }
    previousWasHighSurrogate = isHighSurrogate;
  }
  if (previousWasHighSurrogate) {
    throw invalidPostgresJson();
  }
}

function invalidPostgresJson(): HttpProblem {
  return new HttpProblem({
    status: 422,
    code: "invalid_json",
    title: "Unprocessable Content",
    type: "urn:exeligmos:problem:invalid-json",
    detail: "JSON strings and object keys must contain PostgreSQL-compatible Unicode text.",
  });
}

function expandScientificNumber(serialized: string): string {
  const match = /^(-?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$/.exec(serialized);
  if (match === null) {
    return serialized;
  }

  const sign = match[1] ?? "";
  const integer = match[2] as string;
  const fraction = match[3] ?? "";
  const exponent = Number(match[4]);
  const digits = integer + fraction;
  const decimalIndex = integer.length + exponent;
  if (decimalIndex <= 0) {
    return `${sign}0.${"0".repeat(-decimalIndex)}${digits}`;
  }
  if (decimalIndex >= digits.length) {
    return `${sign}${digits}${"0".repeat(decimalIndex - digits.length)}`;
  }
  return `${sign}${digits.slice(0, decimalIndex)}.${digits.slice(decimalIndex)}`;
}
