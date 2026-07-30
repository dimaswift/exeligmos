export const referenceKinds = ["user", "record", "event"] as const;
export type ReferenceKind = (typeof referenceKinds)[number];

export interface EntityReference {
  readonly kind: ReferenceKind;
  readonly id: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isReferenceKind(value: string): value is ReferenceKind {
  return referenceKinds.some((kind) => kind === value);
}

export function referenceInspectorHref(reference: EntityReference): string {
  if (reference.kind === "record") {
    if (!/^[A-Za-z0-9_-]{5}$/.test(reference.id)) {
      throw new TypeError("Record reference id must be a five-character public ID.");
    }
    return `/r/${reference.id}`;
  }
  if (!isEntityId(reference.id)) {
    throw new TypeError("Reference entity id must be a UUID.");
  }
  return `/references/${reference.kind}/${reference.id}`;
}

export function isEntityId(value: string): boolean {
  return UUID_PATTERN.test(value);
}
