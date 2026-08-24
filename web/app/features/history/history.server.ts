import path from "node:path";
import process from "node:process";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";

export const HISTORY_HARMONIC_DEPTH = 6;
export const HISTORY_PAGE_SIZE = 30;
export const HISTORY_DEFAULT_RADIX = 8;
export const HISTORY_MINIMUM_RADIX = 2;
export const HISTORY_MAXIMUM_RADIX = 36;
export const HISTORY_MAXIMUM_ADDRESS_DEPTH = 10;

export interface HistoryQuery {
  readonly searchInput: string;
  readonly text: string;
  readonly radix: number;
  readonly address: string;
  readonly saros?: number;
  readonly country: string;
  readonly eventType: string;
  readonly outcome: string;
  readonly page: number;
  readonly warnings: readonly string[];
}

export interface HistorySarosLocation {
  readonly saros: number;
  readonly address: string;
  readonly radix: number;
}

export interface HistoricalEventResult {
  readonly id: number;
  readonly title: string;
  readonly displayDate: string;
  readonly datePrecision: "day" | "month" | "year";
  readonly year: number;
  readonly country: string;
  readonly eventType: string;
  readonly placeName: string;
  readonly impact: string;
  readonly affectedPopulation: string;
  readonly responsibleParty: string;
  readonly outcome: string;
  readonly activeSarosCount: number;
  readonly locations: readonly HistorySarosLocation[];
}

export interface HistorySearchResult {
  readonly query: HistoryQuery;
  readonly events: readonly HistoricalEventResult[];
  readonly total: number;
  readonly pageCount: number;
  readonly facets: {
    readonly countries: readonly string[];
    readonly eventTypes: readonly string[];
    readonly outcomes: readonly string[];
  };
  readonly metadata: {
    readonly eventCount: number;
    readonly locationCount: number;
    readonly sourceSha256: string;
  };
}

interface EventRow {
  readonly id: number;
  readonly title: string;
  readonly display_date: string;
  readonly date_precision: "day" | "month" | "year";
  readonly year: number;
  readonly country: string;
  readonly event_type: string;
  readonly place_name: string;
  readonly impact: string;
  readonly affected_population: string;
  readonly responsible_party: string;
  readonly outcome: string;
  readonly active_saros_count: number;
}

interface LocationRow {
  readonly event_id: number;
  readonly saros: number;
  readonly phase: number;
}

let database: DatabaseSync | undefined;

export function parseHistoryQuery(url: string): HistoryQuery {
  const params = new URL(url).searchParams;
  const warnings: string[] = [];
  const rawSearch = (params.get("q") ?? "").trim().slice(0, 160);
  const rawAddress = (params.get("address") ?? "").trim();
  const radix =
    optionalInteger(
      params.get("radix"),
      HISTORY_MINIMUM_RADIX,
      HISTORY_MAXIMUM_RADIX,
      "Base",
      warnings,
    ) ?? HISTORY_DEFAULT_RADIX;
  const compactSearch = compactAddress(rawSearch);
  const searchIsAddress =
    compactSearch.length === HISTORY_HARMONIC_DEPTH &&
    isValidAddress(compactSearch, radix) &&
    (rawAddress.length === 0 || compactAddress(rawAddress) === compactSearch);
  const address = normalizedAddress(searchIsAddress ? compactSearch : rawAddress, radix, warnings);
  const saros = optionalInteger(params.get("saros"), 1, 180, "Saros", warnings);
  const rawPage = optionalInteger(params.get("page"), 1, 100_000, "Page", warnings);

  return {
    searchInput: searchIsAddress ? "" : rawSearch,
    text: searchIsAddress ? "" : rawSearch,
    radix,
    address,
    ...(saros === undefined ? {} : { saros }),
    country: (params.get("country") ?? "").trim().slice(0, 100),
    eventType: (params.get("type") ?? "").trim().slice(0, 100),
    outcome: (params.get("outcome") ?? "").trim().slice(0, 100),
    page: rawPage ?? 1,
    warnings,
  };
}

export function searchHistory(query: HistoryQuery): HistorySearchResult {
  const db = historyDatabase();
  const conditions: string[] = [];
  const values: SQLInputValue[] = [];

  if (query.text.length > 0) {
    const fts = fullTextQuery(query.text);
    if (fts.length > 0) {
      conditions.push(
        "e.id IN (SELECT rowid FROM historical_events_fts WHERE historical_events_fts MATCH ?)",
      );
      values.push(fts);
    }
  }
  if (query.country.length > 0) {
    conditions.push("e.country = ?");
    values.push(query.country);
  }
  if (query.eventType.length > 0) {
    conditions.push("e.event_type = ?");
    values.push(query.eventType);
  }
  if (query.outcome.length > 0) {
    conditions.push("e.outcome = ?");
    values.push(query.outcome);
  }

  const locationFilter = locationConditions(query);
  if (locationFilter.sql.length > 0) {
    conditions.push(
      `EXISTS (SELECT 1 FROM event_saros_locations matched WHERE matched.event_id = e.id AND ${locationFilter.sql.join(" AND ")})`,
    );
    values.push(...locationFilter.values);
  }

  const where = conditions.length === 0 ? "" : `WHERE ${conditions.join(" AND ")}`;
  const countRow = db
    .prepare(`SELECT count(*) AS total FROM historical_events e ${where}`)
    .get(...values) as { total: number };
  const total = Number(countRow.total);
  const pageCount = Math.max(1, Math.ceil(total / HISTORY_PAGE_SIZE));
  const page = Math.min(query.page, pageCount);
  const offset = (page - 1) * HISTORY_PAGE_SIZE;
  const rows = db
    .prepare(
      `
      SELECT
        e.*,
        (SELECT count(*) FROM event_saros_locations all_locations WHERE all_locations.event_id = e.id)
          AS active_saros_count
      FROM historical_events e
      ${where}
      ORDER BY e.representative_epoch_seconds DESC, e.id DESC
      LIMIT ? OFFSET ?
    `,
    )
    .all(...values, HISTORY_PAGE_SIZE, offset) as unknown as EventRow[];

  const locations = locationsForEvents(
    db,
    rows.map((row) => row.id),
    query,
  );
  const metadataRows = db.prepare("SELECT key, value FROM metadata").all() as unknown as Array<{
    key: string;
    value: string;
  }>;
  const metadata = Object.fromEntries(metadataRows.map((row) => [row.key, row.value]));

  return {
    query: { ...query, page },
    total,
    pageCount,
    events: rows.map((row) => ({
      id: row.id,
      title: row.title,
      displayDate: row.display_date,
      datePrecision: row.date_precision,
      year: row.year,
      country: row.country,
      eventType: row.event_type,
      placeName: row.place_name,
      impact: row.impact,
      affectedPopulation: row.affected_population,
      responsibleParty: row.responsible_party,
      outcome: row.outcome,
      activeSarosCount: Number(row.active_saros_count),
      locations: locations.get(row.id) ?? [],
    })),
    facets: {
      countries: facetValues(db, "country"),
      eventTypes: facetValues(db, "event_type"),
      outcomes: facetValues(db, "outcome"),
    },
    metadata: {
      eventCount: Number(metadata.event_count ?? 0),
      locationCount: Number(metadata.location_count ?? 0),
      sourceSha256: metadata.source_sha256 ?? "",
    },
  };
}

function historyDatabase(): DatabaseSync {
  database ??= new DatabaseSync(
    process.env.HISTORY_DATABASE_PATH ?? path.resolve(process.cwd(), "data/history.sqlite"),
    { readOnly: true },
  );
  return database;
}

function locationsForEvents(
  db: DatabaseSync,
  eventIDs: readonly number[],
  query: HistoryQuery,
): Map<number, HistorySarosLocation[]> {
  const byEvent = new Map<number, HistorySarosLocation[]>();
  if (eventIDs.length === 0) return byEvent;
  const filter = locationConditions(query);
  const placeholders = eventIDs.map(() => "?").join(", ");
  const suffix = filter.sql.length === 0 ? "" : ` AND ${filter.sql.join(" AND ")}`;
  const rows = db
    .prepare(
      `
      SELECT event_id, saros, phase
      FROM event_saros_locations matched
      WHERE event_id IN (${placeholders})${suffix}
      ORDER BY event_id, saros
    `,
    )
    .all(...eventIDs, ...filter.values) as unknown as LocationRow[];
  for (const row of rows) {
    const locations = byEvent.get(row.event_id) ?? [];
    locations.push({
      saros: row.saros,
      address: addressForPhase(row.phase, query.radix, presentationDepth(query)),
      radix: query.radix,
    });
    byEvent.set(row.event_id, locations);
  }
  return byEvent;
}

function locationConditions(query: HistoryQuery): { sql: string[]; values: SQLInputValue[] } {
  const sql: string[] = [];
  const values: SQLInputValue[] = [];
  if (query.address.length > 0) {
    const denominator = query.radix ** query.address.length;
    const binIndex = Number.parseInt(query.address, query.radix);
    sql.push("matched.phase >= ? AND matched.phase < ?");
    values.push(binIndex / denominator, (binIndex + 1) / denominator);
  }
  if (query.saros !== undefined) {
    sql.push("matched.saros = ?");
    values.push(query.saros);
  }
  return { sql, values };
}

function facetValues(db: DatabaseSync, column: "country" | "event_type" | "outcome"): string[] {
  const rows = db
    .prepare(`SELECT DISTINCT ${column} AS value FROM historical_events ORDER BY ${column}`)
    .all() as unknown as Array<{ value: string }>;
  return rows.map((row) => row.value);
}

function normalizedAddress(value: string, radix: number, warnings: string[]): string {
  const compact = compactAddress(value);
  if (compact.length === 0) return "";
  if (compact.length > HISTORY_MAXIMUM_ADDRESS_DEPTH) {
    warnings.push(`Address must contain at most ${HISTORY_MAXIMUM_ADDRESS_DEPTH} digits.`);
    return "";
  }
  if (!isValidAddress(compact, radix)) {
    warnings.push(`Address contains a digit that is not valid in base ${radix}.`);
    return "";
  }
  return compact;
}

function compactAddress(value: string): string {
  return value.replace(/[\s-]/g, "").toUpperCase();
}

function isValidAddress(value: string, radix: number): boolean {
  if (!/^[0-9A-Z]+$/.test(value)) return false;
  return [...value].every((digit) => Number.parseInt(digit, 36) < radix);
}

function presentationDepth(query: HistoryQuery): number {
  return Math.max(HISTORY_HARMONIC_DEPTH, query.address.length);
}

function addressForPhase(phase: number, radix: number, depth: number): string {
  const binCount = radix ** depth;
  const binIndex = Math.min(Math.floor(phase * binCount), binCount - 1);
  return binIndex.toString(radix).toUpperCase().padStart(depth, "0");
}

function optionalInteger(
  value: string | null,
  minimum: number,
  maximum: number,
  label: string,
  warnings: string[],
): number | undefined {
  if (value === null || value.trim().length === 0) return undefined;
  if (!/^\d+$/.test(value.trim())) {
    warnings.push(`${label} must be a whole number.`);
    return undefined;
  }
  const parsed = Number.parseInt(value, 10);
  if (parsed < minimum || parsed > maximum) {
    warnings.push(`${label} must be between ${minimum} and ${maximum}.`);
    return undefined;
  }
  return parsed;
}

function fullTextQuery(value: string): string {
  const words = value.match(/[\p{L}\p{N}]+/gu) ?? [];
  return words
    .slice(0, 12)
    .map((word) => `"${word.replaceAll('"', '""')}"*`)
    .join(" AND ");
}
