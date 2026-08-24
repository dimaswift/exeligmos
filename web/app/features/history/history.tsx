import { createOctalGlyph } from "@fractonica/glyph-core";
import { GlyphRenderer } from "@fractonica/ui";
import { Form, Link } from "react-router";

import type { HistoricalEventResult, HistoryQuery, HistorySearchResult } from "./history.server";
import styles from "./history.module.css";

const historyHarmonicDepth = 6;

export function HistoryExplorer({ result }: { readonly result: HistorySearchResult }) {
  const { events, facets, metadata, query, total } = result;
  const hasAddress = query.address.length > 0;
  const hasOctalGlyph = query.radix === 8 && query.address.length === historyHarmonicDepth;

  return (
    <main className={styles.history}>
      <header className={styles.header}>
        <div>
          <p className="eyebrow">Temporal archive</p>
          <h1>History</h1>
          <p>
            Explore {metadata.eventCount.toLocaleString()} events through{" "}
            {metadata.locationCount.toLocaleString()} indexed Saros locations in any base from 2
            through 36.
          </p>
        </div>
        {!hasAddress ? null : (
          <div className={styles.queryGlyph}>
            {hasOctalGlyph ? (
              <GlyphRenderer
                model={createOctalGlyph({
                  value: query.address,
                  depth: historyHarmonicDepth,
                  rarityId: "common",
                })}
                size={86}
              />
            ) : (
              <strong className={styles.radixMark}>b{query.radix}</strong>
            )}
            <div>
              <span>
                Base {query.radix} · {query.address.length}-digit address
              </span>
              <code>{query.address}</code>
            </div>
          </div>
        )}
      </header>

      <Form className={styles.filters} key={formKey(query)} method="get">
        <label className={styles.searchField}>
          <span>Search event text or enter a 6-digit address</span>
          <input
            autoComplete="off"
            defaultValue={query.searchInput}
            name="q"
            placeholder="Battle of Panipat"
            type="search"
          />
        </label>
        <label>
          <span>Base</span>
          <input
            defaultValue={query.radix}
            inputMode="numeric"
            max="36"
            min="2"
            name="radix"
            type="number"
          />
        </label>
        <label>
          <span>Address · base {query.radix}</span>
          <input
            autoComplete="off"
            defaultValue={query.address}
            maxLength={10}
            name="address"
            placeholder={addressPlaceholder(query.radix)}
          />
        </label>
        <label>
          <span>Saros series</span>
          <input
            defaultValue={query.saros}
            inputMode="numeric"
            max="180"
            min="1"
            name="saros"
            placeholder="141"
            type="number"
          />
        </label>
        <SelectFilter
          label="Country"
          name="country"
          options={facets.countries}
          value={query.country}
        />
        <SelectFilter
          label="Event type"
          name="type"
          options={facets.eventTypes}
          value={query.eventType}
        />
        <SelectFilter
          label="Outcome"
          name="outcome"
          options={facets.outcomes}
          value={query.outcome}
        />
        <div className={styles.filterActions}>
          <button type="submit">Search history</button>
          <Link to="/history">Clear</Link>
        </div>
      </Form>

      {query.warnings.length === 0 ? null : (
        <ul className={styles.warnings}>
          {query.warnings.map((warning) => (
            <li key={warning}>{warning}</li>
          ))}
        </ul>
      )}

      <div className={styles.resultHeader}>
        <div>
          <strong>{total.toLocaleString()}</strong>
          <span>{total === 1 ? "event" : "events"}</span>
        </div>
        <p>
          Dates without a known day use the UTC midpoint of their source month or year and are
          marked as approximate.
        </p>
      </div>

      {events.length === 0 ? (
        <section className={styles.empty}>
          <h2>No history at this location</h2>
          <p>Try a shorter address, another base, remove a filter, or search the event text.</p>
        </section>
      ) : (
        <ol className={styles.results} start={(result.query.page - 1) * 30 + 1}>
          {events.map((event) => (
            <HistoryEventCard event={event} key={event.id} query={query} />
          ))}
        </ol>
      )}

      <Pagination page={result.query.page} pageCount={result.pageCount} query={query} />
    </main>
  );
}

function SelectFilter({
  label,
  name,
  options,
  value,
}: {
  readonly label: string;
  readonly name: string;
  readonly options: readonly string[];
  readonly value: string;
}) {
  return (
    <label>
      <span>{label}</span>
      <select defaultValue={value} name={name}>
        <option value="">All</option>
        {options.map((option) => (
          <option key={option}>{option}</option>
        ))}
      </select>
    </label>
  );
}

function HistoryEventCard({
  event,
  query,
}: {
  readonly event: HistoricalEventResult;
  readonly query: HistoryQuery;
}) {
  const filteredLocations = query.address.length > 0 || query.saros !== undefined;
  return (
    <li>
      <article className={styles.eventCard}>
        <header>
          <div className={styles.eventDate}>
            <time>{event.displayDate}</time>
            {event.datePrecision === "day" ? null : <span>approx. {event.datePrecision}</span>}
          </div>
          <Outcome outcome={event.outcome} />
        </header>
        <div className={styles.eventBody}>
          <div>
            <p className={styles.eventTaxonomy}>
              {event.country} · {event.eventType} · {event.placeName}
            </p>
            <h2>{event.title}</h2>
            <p className={styles.impact}>{event.impact}</p>
            <details className={styles.context}>
              <summary>Historical context</summary>
              <dl>
                <div>
                  <dt>Affected</dt>
                  <dd>{event.affectedPopulation}</dd>
                </div>
                <div>
                  <dt>Responsible</dt>
                  <dd>{event.responsibleParty}</dd>
                </div>
              </dl>
            </details>
          </div>
          <details className={styles.locations} open={filteredLocations}>
            <summary>
              {filteredLocations ? `${event.locations.length} matching` : event.activeSarosCount}{" "}
              active Saros {event.activeSarosCount === 1 ? "location" : "locations"}
            </summary>
            <div className={styles.locationGrid}>
              {event.locations.map((location) => (
                <Link
                  className={styles.location}
                  key={`${location.saros}-${location.address}`}
                  to={`/history?radix=${location.radix}&address=${location.address}`}
                >
                  <span>Saros {location.saros}</span>
                  <code>{location.address}</code>
                </Link>
              ))}
            </div>
          </details>
        </div>
      </article>
    </li>
  );
}

function Outcome({ outcome }: { readonly outcome: string }) {
  const kind = outcome.toLowerCase();
  return <span className={`${styles.outcome} ${styles[`outcome_${kind}`] ?? ""}`}>{outcome}</span>;
}

function Pagination({
  page,
  pageCount,
  query,
}: {
  readonly page: number;
  readonly pageCount: number;
  readonly query: HistoryQuery;
}) {
  if (pageCount <= 1) return null;
  return (
    <nav aria-label="History pages" className={styles.pagination}>
      {page > 1 ? <Link to={historyPageLink(query, page - 1)}>Previous</Link> : <span />}
      <span>
        Page {page.toLocaleString()} of {pageCount.toLocaleString()}
      </span>
      {page < pageCount ? <Link to={historyPageLink(query, page + 1)}>Next</Link> : <span />}
    </nav>
  );
}

function historyPageLink(query: HistoryQuery, page: number): string {
  const params = new URLSearchParams();
  if (query.text.length > 0) params.set("q", query.text);
  params.set("radix", String(query.radix));
  if (query.address.length > 0) params.set("address", query.address);
  if (query.saros !== undefined) params.set("saros", String(query.saros));
  if (query.country.length > 0) params.set("country", query.country);
  if (query.eventType.length > 0) params.set("type", query.eventType);
  if (query.outcome.length > 0) params.set("outcome", query.outcome);
  params.set("page", String(page));
  return `/history?${params.toString()}`;
}

function addressPlaceholder(radix: number): string {
  if (radix === 2) return "101010";
  if (radix === 8) return "774112";
  if (radix === 16) return "FC84A0";
  return radix > 16 ? "Z7Q2" : "123456";
}

function formKey(query: HistoryQuery): string {
  return [
    query.text,
    query.radix,
    query.address,
    query.saros ?? "",
    query.country,
    query.eventType,
    query.outcome,
  ].join("|");
}
