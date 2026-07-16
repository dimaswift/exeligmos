import type { CSSProperties, ReactNode } from "react";
import { Form } from "react-router";

import {
  canonicalCatalog,
  canonicalCatalogSha256,
  canonicalConformance,
  canonicalConformanceSha256,
} from "@exeligmos/domain-catalog";
import { createOctalGlyph, splitSemanticGlyphStyle, type GlyphModel } from "@exeligmos/glyph-core";
import {
  canonicalTemporalEngine,
  type ClockReading,
  type RarityDescriptor,
} from "@exeligmos/temporal-core";
import { GlyphRenderer } from "@exeligmos/ui";

import type { Route } from "./+types/engine-lab";
import { runCanonicalConformance } from "~/features/engine-lab/conformance";
import { parseEngineLabQuery } from "~/features/engine-lab/query";
import styles from "./engine-lab.module.css";

const presentationDepths = range(
  canonicalCatalog.harmonics.presentationDepth.minimum,
  canonicalCatalog.harmonics.presentationDepth.maximum,
);
const calculationDepths = range(
  canonicalCatalog.harmonics.calculationDepth.minimum,
  canonicalCatalog.harmonics.calculationDepth.maximum,
);
const rarityFixtureIds = canonicalCatalog.rarities.families.flatMap((family) =>
  family.order === 0
    ? [family.id]
    : [
        family.id,
        ...canonicalCatalog.rarities.digits
          .filter((digit) => digit.digit > 0)
          .map((digit) => `${family.id}-${digit.digit}`),
      ],
);
const malformedAddresses = [
  { label: "Empty", value: "" },
  { label: "No octal digits", value: "not-an-address" },
  { label: "Mixed input", value: "12a67" },
  { label: "Overlong input", value: "abc123456701xyz" },
] as const;

export const meta: Route.MetaFunction = () => [
  { title: "Engine lab · Exeligmos" },
  {
    name: "description",
    content: "Deterministic temporal and octal glyph engine inspection surface.",
  },
];

export function loader({ request }: Route.LoaderArgs) {
  return parseEngineLabQuery(request.url);
}

export default function EngineLab({ loaderData }: Route.ComponentProps) {
  const classification = canonicalTemporalEngine.classifyRarity({
    octalAddress: loaderData.address,
    harmonicDepth: loaderData.depth,
  });
  const descriptor = canonicalTemporalEngine.rarityDescriptor({
    rarityId: classification.rarityId,
    harmonicDepth: loaderData.depth,
  });
  const selectedGlyph = createOctalGlyph({
    value: loaderData.address,
    depth: loaderData.depth,
    rarityId: descriptor.rarityId,
  });
  const clock = readClock(loaderData);
  const conformance = runCanonicalConformance();
  const conformanceFailures = conformance.filter((result) => !result.passed);
  const operationCounts = countOperations(conformance);

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div>
          <p className="eyebrow">Deterministic engine surface</p>
          <h1>Temporal + glyph lab</h1>
          <p className={styles.lede}>
            Inspect the exact catalog-driven calculations and fill geometry used by every desktop
            data surface. Inputs live in the URL, so a state can be copied and reproduced without a
            backend or wall clock.
          </p>
        </div>
        <dl className={styles.diagnostics}>
          <div>
            <dt>Catalog</dt>
            <dd>{canonicalCatalog.catalogVersion}</dd>
          </div>
          <div>
            <dt>Geometry</dt>
            <dd>{canonicalCatalog.glyph.geometryVersion}</dd>
          </div>
          <div>
            <dt>Vectors</dt>
            <dd className={conformanceFailures.length === 0 ? styles.pass : styles.fail}>
              {conformance.length - conformanceFailures.length}/{conformance.length}
            </dd>
          </div>
        </dl>
      </header>

      <section aria-labelledby="engine-inputs" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Query state</p>
            <h2 id="engine-inputs">Interactive inspection</h2>
          </div>
          <span className={styles.status}>SSR deterministic</span>
        </div>

        <Form className={styles.controls} method="get" preventScrollReset>
          <label className={styles.addressControl}>
            <span>Octal address</span>
            <input
              autoComplete="off"
              defaultValue={loaderData.address}
              inputMode="text"
              name="address"
              spellCheck={false}
            />
          </label>
          <label>
            <span>Glyph depth</span>
            <select defaultValue={loaderData.depth} name="depth">
              {presentationDepths.map((depth) => (
                <option key={depth} value={depth}>
                  {depth}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>Interval start</span>
            <input defaultValue={loaderData.previous} name="previous" type="text" />
          </label>
          <label>
            <span>Interval end</span>
            <input defaultValue={loaderData.next} name="next" type="text" />
          </label>
          <label>
            <span>Instant</span>
            <input defaultValue={loaderData.instant} name="instant" type="text" />
          </label>
          <label>
            <span>Clock depth</span>
            <select defaultValue={loaderData.clockDepth} name="clockDepth">
              {calculationDepths.map((depth) => (
                <option key={depth} value={depth}>
                  {depth}
                </option>
              ))}
            </select>
          </label>
          <button type="submit">Recalculate</button>
        </Form>

        {loaderData.warnings.length > 0 ? (
          <div className={styles.warning} role="status">
            {loaderData.warnings.join(" ")}
          </div>
        ) : null}

        <div className={styles.selection}>
          <div className={styles.selectedGlyph}>
            <GlyphRenderer
              accessibilityLabel={`${descriptor.title} · Octal glyph`}
              model={selectedGlyph}
              size="100%"
            />
          </div>
          <div className={styles.selectionData}>
            <div className={styles.selectionTitle}>
              <div>
                <p className="eyebrow">Selected projection</p>
                <h3>{descriptor.title}</h3>
              </div>
              <span
                className={styles.rarityBadge}
                style={semanticStyle(descriptor.semanticColorToken)}
              >
                {descriptor.rarityId}
              </span>
            </div>
            <MetricGrid
              items={[
                ["Raw input", displayEmpty(loaderData.address)],
                ["Glyph address", selectedGlyph.normalizedValue],
                ["Rarity pattern", descriptor.patternLabel],
                ["Rarity order", String(descriptor.order)],
                ["Glyph depth", String(selectedGlyph.depth)],
                ["View box", selectedGlyph.viewBox.join(" ")],
              ]}
            />
          </div>
          <div className={styles.clockData}>
            <p className="eyebrow">Interval clock</p>
            {clock.reading === null ? (
              <div className={styles.problem} role="alert">
                {clock.error}
              </div>
            ) : (
              <MetricGrid
                items={[
                  ["Clock address", clock.reading.octalAddress],
                  ["Bin", `${clock.reading.binIndex}/${clock.reading.binCount - 1}`],
                  ["Phase", formatDecimal(clock.reading.phase)],
                  ["Bin progress", formatPercent(clock.reading.progressWithinBin)],
                  ["Next flip", formatDecimal(clock.reading.nextFlipEpochSeconds)],
                  ["Until flip", `${formatDecimal(clock.reading.timeUntilNextFlip)} s`],
                ]}
              />
            )}
          </div>
        </div>
      </section>

      <section aria-labelledby="time-units" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Single source of truth</p>
            <h2 id="time-units">Temporal unit catalog</h2>
          </div>
          <span className={styles.status}>{canonicalCatalog.time.basePeriod.title}</span>
        </div>
        <div className={styles.tableScroll}>
          <table>
            <thead>
              <tr>
                <th scope="col">Unit</th>
                <th scope="col">Pattern</th>
                <th scope="col">Exponent</th>
                <th scope="col">Seconds</th>
                <th scope="col">Human scale</th>
                <th scope="col">Roles</th>
              </tr>
            </thead>
            <tbody>
              {canonicalCatalog.time.units.map((unit) => {
                const duration = canonicalTemporalEngine.pulseDuration(unit.id);
                return (
                  <tr key={unit.id}>
                    <th scope="row">
                      <span
                        aria-hidden="true"
                        className={styles.swatch}
                        style={semanticStyle(unit.semanticColorToken)}
                      />
                      {unit.title}
                    </th>
                    <td>
                      <code>{unit.pattern}</code>
                    </td>
                    <td>{unit.exponent}</td>
                    <td>
                      <code>{formatDecimal(duration.seconds, 9)}</code>
                    </td>
                    <td>{formatDuration(duration.seconds)}</td>
                    <td>{enabledRoles(unit.roles).join(" · ")}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <FixtureSection
        description="Stable frames across every supported presentation depth. The asymmetric value makes socket order visible."
        id="depth-fixtures"
        title="Depth 3–8"
      >
        <div className={styles.fixtureGrid}>
          {presentationDepths.map((depth) => {
            const model = createOctalGlyph({
              value: "70123456",
              depth,
              rarityId: "common",
            });
            return (
              <GlyphCard
                key={depth}
                label={`Depth ${depth}`}
                model={model}
                note={`${model.normalizedValue} · ${model.viewBox[2]}×${model.viewBox[3]}`}
              />
            );
          })}
        </div>
      </FixtureSection>

      <FixtureSection
        description="Every arm template rendered at the query-selected depth; use the control above to inspect transforms and core insets from depth three through eight. Digit zero intentionally has no arm polygon."
        id="digit-fixtures"
        title={`Arm digits 0–7 · depth ${loaderData.depth}`}
      >
        <div className={styles.fixtureGrid}>
          {canonicalCatalog.rarities.digits.map((digit) => {
            const model = createOctalGlyph({
              value: String(digit.digit).repeat(loaderData.depth),
              depth: loaderData.depth,
              style: splitSemanticGlyphStyle(
                digit.semanticColorToken,
                digit.semanticColorToken,
                loaderData.depth,
              ),
            });
            return (
              <GlyphCard
                key={digit.digit}
                label={digit.digit === 0 ? "Digit 0 · empty arm" : `Digit ${digit.digit}`}
                model={model}
                note={digit.prefix || "Zero"}
              />
            );
          })}
        </div>
      </FixtureSection>

      <FixtureSection
        description="Family headers and every repeated-digit subrarity. Identity, labels, glyph addresses, and colors all come from the catalog-backed temporal engine."
        id="rarity-fixtures"
        title="Rarity matrix"
      >
        <div className={`${styles.fixtureGrid} ${styles.compactGrid}`}>
          {rarityFixtureIds.map((rarityId) => {
            const rarity = canonicalTemporalEngine.rarityDescriptor({
              rarityId,
              harmonicDepth: 7,
            });
            return <RarityCard descriptor={rarity} key={rarityId} />;
          })}
        </div>
      </FixtureSection>

      <FixtureSection
        description="Legacy input names resolve to canonical rarity identity before geometry and paint are selected."
        id="alias-fixtures"
        title="Rarity aliases"
      >
        <div className={`${styles.fixtureGrid} ${styles.compactGrid}`}>
          {canonicalCatalog.rarities.aliases.map((alias) => {
            const descriptor = canonicalTemporalEngine.rarityDescriptor({
              rarityId: alias.alias,
              harmonicDepth: 7,
            });
            const model = createOctalGlyph({
              value: descriptor.glyphAddress,
              depth: 7,
              rarityId: alias.alias,
            });
            return (
              <GlyphCard
                compact
                key={alias.alias}
                label={alias.alias}
                model={model}
                note={`→ ${descriptor.rarityId}`}
              />
            );
          })}
        </div>
      </FixtureSection>

      <FixtureSection
        description="Filtering, truncation, and padding remain total for user-controlled strings. These cards use an explicit common rarity paint."
        id="malformed-fixtures"
        title="Malformed address handling"
      >
        <div className={styles.fixtureGrid}>
          {malformedAddresses.map((fixture) => {
            const model = createOctalGlyph({
              value: fixture.value,
              depth: 7,
              rarityId: "common",
            });
            return (
              <GlyphCard
                key={fixture.label}
                label={fixture.label}
                model={model}
                note={`${displayEmpty(fixture.value)} → ${model.normalizedValue}`}
              />
            );
          })}
          <GlyphCard
            label="Split semantic paint"
            model={createOctalGlyph({
              value: "1234567",
              depth: 7,
              style: splitSemanticGlyphStyle("color.digit.1", "color.digit.6", 3),
            })}
            note="first 3 digit indices · remaining 4"
          />
        </div>
      </FixtureSection>

      <section aria-labelledby="conformance-vectors" className={styles.panel}>
        <div className={styles.sectionHeading}>
          <div>
            <p className="eyebrow">Generated executable contract</p>
            <h2 id="conformance-vectors">Canonical conformance</h2>
          </div>
          <span
            className={conformanceFailures.length === 0 ? styles.passStatus : styles.failStatus}
          >
            {conformanceFailures.length === 0
              ? `${conformance.length}/${conformance.length} passing`
              : `${conformanceFailures.length} failing`}
          </span>
        </div>
        <p className={styles.sectionDescription}>
          Every source-generated vector executes through production temporal, glyph, and event
          functions using the catalog&apos;s exact integer and scaled floating-point comparison
          rules.
        </p>
        <div className={styles.operationGrid}>
          {operationCounts.map(([operation, count]) => (
            <div key={operation}>
              <code>{operation}</code>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
        <details className={styles.vectorDetails}>
          <summary>Inspect all {conformance.length} vector results</summary>
          <div className={styles.tableScroll}>
            <table>
              <thead>
                <tr>
                  <th scope="col">Vector</th>
                  <th scope="col">Operation</th>
                  <th scope="col">Status</th>
                  <th scope="col">Expected subset</th>
                  <th scope="col">Actual result</th>
                </tr>
              </thead>
              <tbody>
                {conformance.map((result) => (
                  <tr key={result.id}>
                    <th scope="row">
                      <code>{result.id}</code>
                    </th>
                    <td>{result.operation}</td>
                    <td className={result.passed ? styles.pass : styles.fail}>
                      {result.passed ? "Pass" : "Fail"}
                    </td>
                    <td>
                      <code>{JSON.stringify(result.expected)}</code>
                    </td>
                    <td>
                      <code>{JSON.stringify(result.actual)}</code>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
        <div className={styles.hashes}>
          <div>
            <span>Catalog SHA-256</span>
            <code>{canonicalCatalogSha256}</code>
          </div>
          <div>
            <span>Conformance SHA-256</span>
            <code>{canonicalConformanceSha256}</code>
          </div>
          <div>
            <span>Schema</span>
            <code>
              catalog {canonicalCatalog.schemaVersion} · vectors{" "}
              {canonicalConformance.schemaVersion}
            </code>
          </div>
        </div>
      </section>
    </div>
  );
}

function FixtureSection({
  children,
  description,
  id,
  title,
}: {
  readonly children: ReactNode;
  readonly description: string;
  readonly id: string;
  readonly title: string;
}) {
  return (
    <section aria-labelledby={id} className={styles.panel}>
      <div className={styles.sectionHeading}>
        <div>
          <p className="eyebrow">Visual fixtures</p>
          <h2 id={id}>{title}</h2>
        </div>
      </div>
      <p className={styles.sectionDescription}>{description}</p>
      {children}
    </section>
  );
}

function GlyphCard({
  compact = false,
  label,
  model,
  note,
}: {
  readonly compact?: boolean;
  readonly label: string;
  readonly model: GlyphModel;
  readonly note: string;
}) {
  return (
    <article className={`${styles.glyphCard} ${compact ? styles.glyphCardCompact : ""}`}>
      <div className={styles.glyphStage}>
        <GlyphRenderer accessibilityLabel={`${label} · Octal glyph`} model={model} size="100%" />
      </div>
      <h3>{label}</h3>
      <code>{note}</code>
    </article>
  );
}

function RarityCard({ descriptor }: { readonly descriptor: RarityDescriptor }) {
  const model = createOctalGlyph({
    value: descriptor.glyphAddress,
    depth: 7,
    rarityId: descriptor.rarityId,
  });
  return (
    <article
      className={`${styles.glyphCard} ${styles.glyphCardCompact}`}
      style={semanticStyle(descriptor.semanticColorToken)}
    >
      <div className={styles.glyphStage}>
        <GlyphRenderer
          accessibilityLabel={`${descriptor.title} · Octal glyph`}
          model={model}
          size="100%"
        />
      </div>
      <h3>{descriptor.title}</h3>
      <code>{descriptor.patternLabel}</code>
      <span className={styles.cardMeta}>rank {descriptor.rank}</span>
    </article>
  );
}

function MetricGrid({
  items,
}: {
  readonly items: ReadonlyArray<readonly [label: string, value: string]>;
}) {
  return (
    <dl className={styles.metrics}>
      {items.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function readClock(input: {
  readonly previous: string;
  readonly next: string;
  readonly instant: string;
  readonly clockDepth: number;
}): { readonly reading: ClockReading | null; readonly error: string | null } {
  try {
    return {
      reading: canonicalTemporalEngine.clockReading({
        previousEpochSeconds: finiteNumber(input.previous, "Interval start"),
        nextEpochSeconds: finiteNumber(input.next, "Interval end"),
        instantEpochSeconds: finiteNumber(input.instant, "Instant"),
        harmonicDepth: input.clockDepth,
      }),
      error: null,
    };
  } catch (error: unknown) {
    return {
      reading: null,
      error: error instanceof Error ? error.message : "The interval is invalid.",
    };
  }
}

function finiteNumber(raw: string, label: string): number {
  if (raw.trim() === "") {
    throw new RangeError(`${label} must be a finite number.`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new RangeError(`${label} must be a finite number.`);
  }
  return value;
}

function countOperations(
  results: ReturnType<typeof runCanonicalConformance>,
): ReadonlyArray<readonly [string, number]> {
  const counts = new Map<string, number>();
  for (const result of results) {
    counts.set(result.operation, (counts.get(result.operation) ?? 0) + 1);
  }
  return [...counts.entries()];
}

function semanticStyle(token: string): CSSProperties {
  const fallback = canonicalCatalog.semanticTokens.colors.find(
    (candidate) => candidate.id === token,
  )?.fallbackSrgb;
  return { "--fixture-color": fallback ?? "#ffffff" } as CSSProperties;
}

function enabledRoles(roles: Readonly<Record<string, boolean>>): string[] {
  return Object.entries(roles)
    .filter(([, enabled]) => enabled)
    .map(([role]) => role);
}

function formatDuration(seconds: number): string {
  if (seconds >= 86_400) {
    return `${formatDecimal(seconds / 86_400, 3)} days`;
  }
  if (seconds >= 3_600) {
    return `${formatDecimal(seconds / 3_600, 3)} hours`;
  }
  if (seconds >= 60) {
    return `${formatDecimal(seconds / 60, 3)} minutes`;
  }
  return `${formatDecimal(seconds, 3)} seconds`;
}

function formatDecimal(value: number, maximumFractionDigits = 6): string {
  return value
    .toFixed(maximumFractionDigits)
    .replace(/\.0+$/, "")
    .replace(/(\.\d*?)0+$/, "$1");
}

function formatPercent(value: number): string {
  return `${formatDecimal(value * 100, 3)}%`;
}

function displayEmpty(value: string): string {
  return value === "" ? "∅" : value;
}

function range(minimum: number, maximum: number): number[] {
  return Array.from({ length: maximum - minimum + 1 }, (_, index) => minimum + index);
}
