import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

import type { LegacyStoreScan } from "./scanner.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface LegacyImportMapping {
  readonly schemaVersion: 1;
  readonly userId: string;
  /** Every legacy sourceDeviceID must be mapped explicitly. */
  readonly devices: Readonly<Record<string, string>>;
  /** Used only for legacy entries which contain no sourceDeviceID. */
  readonly unattributedDeviceId?: string;
}

export interface ResolvedLegacyImportMapping extends LegacyImportMapping {
  readonly mappingChecksum: string;
}

export class LegacyImportMappingError extends Error {
  constructor(readonly issues: readonly string[]) {
    super(`Legacy import mapping is invalid: ${issues.join("; ")}`);
    this.name = "LegacyImportMappingError";
  }
}

export async function loadLegacyImportMapping(
  filePath: string,
  scan: LegacyStoreScan,
): Promise<ResolvedLegacyImportMapping> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(filePath, "utf8"));
  } catch (error) {
    throw new LegacyImportMappingError([
      `${filePath} could not be read as JSON: ${error instanceof Error ? error.message : String(error)}`,
    ]);
  }
  return validateLegacyImportMapping(parsed, scan);
}

export function validateLegacyImportMapping(
  value: unknown,
  scan: LegacyStoreScan,
): ResolvedLegacyImportMapping {
  const issues: string[] = [];
  if (!isObject(value)) {
    throw new LegacyImportMappingError(["the mapping root must be an object"]);
  }
  const allowedKeys = new Set(["schemaVersion", "userId", "devices", "unattributedDeviceId"]);
  for (const key of Object.keys(value)) {
    if (!allowedKeys.has(key)) issues.push(`/${key} is not supported`);
  }
  if (value.schemaVersion !== 1) {
    issues.push("/schemaVersion must equal 1");
  }
  const userId = uuid(value.userId, "/userId", issues);
  const devices: Record<string, string> = {};
  if (!isObject(value.devices)) {
    issues.push("/devices must be an object mapping legacy IDs to v2 device UUIDs");
  } else {
    for (const [legacyId, deviceId] of Object.entries(value.devices)) {
      if (legacyId.trim().length === 0 || legacyId !== legacyId.trim() || legacyId.length > 256) {
        issues.push("/devices keys must be trimmed strings containing 1 to 256 characters");
        continue;
      }
      const normalized = uuid(deviceId, `/devices/${jsonPointerToken(legacyId)}`, issues);
      if (normalized !== undefined) devices[legacyId] = normalized;
    }
  }
  const expectedDeviceIds = new Set(scan.manifest.deviceIds);
  for (const legacyId of expectedDeviceIds) {
    if (devices[legacyId] === undefined) {
      issues.push(`/devices is missing legacy device ${JSON.stringify(legacyId)}`);
    }
  }
  for (const legacyId of Object.keys(devices)) {
    if (!expectedDeviceIds.has(legacyId)) {
      issues.push(`/devices contains unknown legacy device ${JSON.stringify(legacyId)}`);
    }
  }

  const hasUnattributedEntries = scan.entries.some((entry) => entry.sourceDeviceId === undefined);
  const unattributedDeviceId = value.unattributedDeviceId === undefined
    ? undefined
    : uuid(value.unattributedDeviceId, "/unattributedDeviceId", issues);
  if (hasUnattributedEntries && unattributedDeviceId === undefined) {
    issues.push("/unattributedDeviceId is required because at least one entry has no sourceDeviceID");
  }
  if (!hasUnattributedEntries && unattributedDeviceId !== undefined) {
    issues.push("/unattributedDeviceId must be omitted because every entry has a sourceDeviceID");
  }

  if (issues.length > 0 || userId === undefined) {
    throw new LegacyImportMappingError(issues);
  }
  const normalized: LegacyImportMapping = {
    schemaVersion: 1,
    userId,
    devices: Object.fromEntries(Object.entries(devices).sort(([left], [right]) => left.localeCompare(right, "en"))),
    ...(unattributedDeviceId === undefined ? {} : { unattributedDeviceId }),
  };
  return {
    ...normalized,
    mappingChecksum: createHash("sha256").update(canonicalJson(normalized)).digest("hex"),
  };
}

export function mappedDeviceId(
  mapping: LegacyImportMapping,
  legacyDeviceId: string | undefined,
): string {
  const deviceId = legacyDeviceId === undefined
    ? mapping.unattributedDeviceId
    : mapping.devices[legacyDeviceId];
  if (deviceId === undefined) {
    throw new LegacyImportMappingError([
      legacyDeviceId === undefined
        ? "an unattributed entry has no fallback device mapping"
        : `legacy device ${JSON.stringify(legacyDeviceId)} has no mapping`,
    ]);
  }
  return deviceId;
}

function uuid(value: unknown, pointer: string, issues: string[]): string | undefined {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    issues.push(`${pointer} must be a UUID`);
    return undefined;
  }
  return value.toLowerCase();
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (isObject(value)) {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function jsonPointerToken(value: string): string {
  return value.replaceAll("~", "~0").replaceAll("/", "~1");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
