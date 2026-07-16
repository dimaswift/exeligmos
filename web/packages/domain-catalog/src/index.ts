export { canonicalCatalog, canonicalCatalogSha256 } from "./catalog.generated.js";
export { canonicalConformance, canonicalConformanceSha256 } from "./conformance.generated.js";

import { canonicalCatalog } from "./catalog.generated.js";

export type DomainCatalog = typeof canonicalCatalog;
export type TemporalUnit = DomainCatalog["time"]["units"][number];
export type TemporalUnitId = TemporalUnit["id"];
export type RarityFamily = DomainCatalog["rarities"]["families"][number];
export type RarityFamilyId = RarityFamily["id"];
export type SemanticColor = DomainCatalog["semanticTokens"]["colors"][number];
export type SemanticColorId = SemanticColor["id"];
export type EventNamespace = DomainCatalog["events"]["namespaces"][number];
export type EventNamespaceId = EventNamespace["id"];

export interface EventTypeResolution {
  readonly type: number;
  readonly namespace: EventNamespaceId;
  readonly known: boolean;
  readonly key: string | null;
  readonly label: string;
  readonly semanticColorToken: SemanticColorId;
  readonly requiresProviderMetadata: boolean;
}

export const temporalUnitsById = new Map<TemporalUnitId, TemporalUnit>(
  canonicalCatalog.time.units.map((unit) => [unit.id, unit]),
);

export const rarityFamiliesById = new Map<RarityFamilyId, RarityFamily>(
  canonicalCatalog.rarities.families.map((family) => [family.id, family]),
);

export const semanticColorsById = new Map<SemanticColorId, SemanticColor>(
  canonicalCatalog.semanticTokens.colors.map((color) => [color.id, color]),
);

/** Resolves stable numeric event identity without assigning meaning to unknown values. */
export function resolveEventType(
  type: number,
  catalog: DomainCatalog = canonicalCatalog,
): EventTypeResolution {
  if (
    !Number.isInteger(type) ||
    type < catalog.events.typeRange.minimum ||
    type > catalog.events.typeRange.maximum
  ) {
    throw new RangeError(
      `Event type must be an integer from ${catalog.events.typeRange.minimum} to ${catalog.events.typeRange.maximum}.`,
    );
  }

  const namespace = catalog.events.namespaces.find(
    (candidate) => type >= candidate.minimum && type <= candidate.maximum,
  );
  if (namespace === undefined) {
    throw new Error(`The canonical catalog has no namespace for event type ${type}.`);
  }
  const entry = catalog.events.entries.find((candidate) => candidate.type === type);
  const semanticColorToken =
    entry?.semanticColorToken ?? catalog.events.unknownDisplay.semanticColorToken;

  return {
    type,
    namespace: namespace.id,
    known: entry !== undefined,
    key: entry?.key ?? null,
    label:
      entry?.label ?? catalog.events.unknownDisplay.labelTemplate.replace("{type}", String(type)),
    semanticColorToken,
    requiresProviderMetadata: namespace.registration === "provider-metadata-required",
  };
}
