import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(scriptDirectory, "..");
const sourcePath = path.join(webRoot, "historical_events.csv");
const solarDataPath = path.join(
  webRoot,
  "app/features/temporal/generated/solar-temporal-data.json",
);
const outputPath = path.join(webRoot, "data/history.sqlite");
const temporaryPath = `${outputPath}.tmp-${process.pid}`;
const harmonicDepth = 6;
const binCount = 8 ** harmonicDepth;
const monthNames = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

const [sourceBytes, solarDataBytes] = await Promise.all([
  readFile(sourcePath),
  readFile(solarDataPath),
]);
const rows = parseCsv(sourceBytes.toString("utf8"));
const solarData = JSON.parse(solarDataBytes.toString("utf8"));
const series = validateSolarSeries(solarData);
const events = rows.map(normalizeHistoricalEvent);

await mkdir(path.dirname(outputPath), { recursive: true });
await rm(temporaryPath, { force: true });

const database = new DatabaseSync(temporaryPath);
try {
  database.exec(`
    PRAGMA journal_mode = OFF;
    PRAGMA synchronous = OFF;
    PRAGMA foreign_keys = ON;

    CREATE TABLE metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) STRICT;

    CREATE TABLE historical_events (
      id INTEGER PRIMARY KEY,
      source_serial TEXT NOT NULL,
      title TEXT NOT NULL,
      day INTEGER,
      month INTEGER,
      year INTEGER NOT NULL,
      date_precision TEXT NOT NULL CHECK (date_precision IN ('day', 'month', 'year')),
      display_date TEXT NOT NULL,
      representative_epoch_seconds INTEGER NOT NULL,
      interval_start_epoch_seconds INTEGER NOT NULL,
      interval_end_epoch_seconds INTEGER NOT NULL,
      country TEXT NOT NULL,
      event_type TEXT NOT NULL,
      place_name TEXT NOT NULL,
      impact TEXT NOT NULL,
      affected_population TEXT NOT NULL,
      responsible_party TEXT NOT NULL,
      outcome TEXT NOT NULL
    ) STRICT;

    CREATE TABLE event_saros_locations (
      event_id INTEGER NOT NULL REFERENCES historical_events(id) ON DELETE CASCADE,
      saros INTEGER NOT NULL,
      octal_address TEXT NOT NULL CHECK (
        length(octal_address) = 6 AND octal_address NOT GLOB '*[^0-7]*'
      ),
      phase REAL NOT NULL CHECK (phase >= 0.0 AND phase < 1.0),
      previous_eclipse_epoch_seconds INTEGER NOT NULL,
      next_eclipse_epoch_seconds INTEGER NOT NULL,
      PRIMARY KEY (event_id, saros)
    ) WITHOUT ROWID, STRICT;

    CREATE VIRTUAL TABLE historical_events_fts USING fts5(
      title,
      country,
      event_type,
      place_name,
      impact,
      affected_population,
      responsible_party,
      content='historical_events',
      content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );

    CREATE INDEX historical_events_epoch_idx
      ON historical_events(representative_epoch_seconds DESC, id DESC);
    CREATE INDEX historical_events_country_idx
      ON historical_events(country, representative_epoch_seconds DESC);
    CREATE INDEX historical_events_type_idx
      ON historical_events(event_type, representative_epoch_seconds DESC);
    CREATE INDEX historical_events_outcome_idx
      ON historical_events(outcome, representative_epoch_seconds DESC);
    CREATE INDEX event_saros_locations_address_idx
      ON event_saros_locations(octal_address, event_id, saros);
    CREATE INDEX event_saros_locations_saros_idx
      ON event_saros_locations(saros, octal_address, event_id);
    CREATE INDEX event_saros_locations_phase_idx
      ON event_saros_locations(phase, event_id, saros);
  `);

  const insertMetadata = database.prepare("INSERT INTO metadata (key, value) VALUES (?, ?)");
  const insertEvent = database.prepare(`
    INSERT INTO historical_events (
      id, source_serial, title, day, month, year, date_precision, display_date,
      representative_epoch_seconds, interval_start_epoch_seconds,
      interval_end_epoch_seconds, country, event_type, place_name, impact,
      affected_population, responsible_party, outcome
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const insertLocation = database.prepare(`
    INSERT INTO event_saros_locations (
      event_id, saros, octal_address, phase, previous_eclipse_epoch_seconds,
      next_eclipse_epoch_seconds
    ) VALUES (?, ?, ?, ?, ?, ?)
  `);

  database.exec("BEGIN IMMEDIATE");
  try {
    insertMetadata.run("schema_version", "2");
    insertMetadata.run("source_sha256", createHash("sha256").update(sourceBytes).digest("hex"));
    insertMetadata.run("solar_source_sha256", String(solarData.sourceSha256));
    insertMetadata.run("harmonic_depth", String(harmonicDepth));
    insertMetadata.run("date_policy", "UTC midpoint of the source date precision");

    let locationCount = 0;
    for (const event of events) {
      insertEvent.run(
        event.id,
        event.sourceSerial,
        event.title,
        event.day,
        event.month,
        event.year,
        event.datePrecision,
        event.displayDate,
        event.representativeEpochSeconds,
        event.intervalStartEpochSeconds,
        event.intervalEndEpochSeconds,
        event.country,
        event.eventType,
        event.placeName,
        event.impact,
        event.affectedPopulation,
        event.responsibleParty,
        event.outcome,
      );

      for (const [saros, eclipses] of series) {
        const interval = activeInterval(eclipses, event.representativeEpochSeconds);
        if (interval === undefined) continue;
        const phase = phaseValue(
          interval.previous,
          interval.next,
          event.representativeEpochSeconds,
        );
        insertLocation.run(
          event.id,
          saros,
          radixAddress(phase, 8, harmonicDepth),
          phase,
          interval.previous,
          interval.next,
        );
        locationCount += 1;
      }
    }

    database.exec("INSERT INTO historical_events_fts(historical_events_fts) VALUES('rebuild')");
    insertMetadata.run("event_count", String(events.length));
    insertMetadata.run("location_count", String(locationCount));
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }

  database.exec("PRAGMA optimize");
  const integrity = database.prepare("PRAGMA integrity_check").get();
  if (integrity?.integrity_check !== "ok") {
    throw new Error(
      `Generated history database failed integrity check: ${JSON.stringify(integrity)}`,
    );
  }
} finally {
  database.close();
}

await rename(temporaryPath, outputPath);
process.stdout.write(
  `Generated ${events.length} historical events with normalized Saros phases and canonical 8^${harmonicDepth} addresses in ${path.relative(webRoot, outputPath)}.\n`,
);

function parseCsv(source) {
  const records = [];
  let record = [];
  let field = "";
  let quoted = false;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (quoted) {
      if (character === '"' && source[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
      continue;
    }

    if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      record.push(field);
      field = "";
    } else if (character === "\n") {
      record.push(field.replace(/\r$/, ""));
      if (record.some((value) => value.length > 0)) records.push(record);
      record = [];
      field = "";
    } else {
      field += character;
    }
  }
  if (quoted) throw new Error("Historical CSV ends inside a quoted field.");
  if (field.length > 0 || record.length > 0) {
    record.push(field.replace(/\r$/, ""));
    records.push(record);
  }

  const [header, ...data] = records;
  if (header === undefined) throw new Error("Historical CSV is empty.");
  const normalizedHeader = header.map((value, index) =>
    (index === 0 ? value.replace(/^\uFEFF/, "") : value).trim(),
  );
  return data.map((values, index) => {
    if (values.length !== normalizedHeader.length) {
      throw new Error(
        `Historical CSV row ${index + 2} has ${values.length} columns; expected ${normalizedHeader.length}.`,
      );
    }
    return Object.fromEntries(normalizedHeader.map((key, column) => [key, values[column] ?? ""]));
  });
}

function normalizeHistoricalEvent(row, index) {
  const parsedYear = parseHistoricalYear(required(row, "Year", index));
  const rawMonth = clean(row["Month"]);
  const rawDay = clean(row["Date"]);
  const dateParts = resolveDateParts(rawMonth, rawDay, index);
  const { month, day, endDay } = dateParts;
  const datePrecision = day !== null ? "day" : month !== null ? "month" : "year";
  const bounds = dateBounds(parsedYear, month, day, endDay, datePrecision);
  const representativeEpochSeconds = Math.floor(
    (bounds.startEpochSeconds + bounds.endEpochSeconds) / 2,
  );

  return {
    id: index + 1,
    sourceSerial: required(row, "Sl. No", index),
    title: required(row, "Name of Incident", index),
    day,
    month,
    year: parsedYear,
    datePrecision,
    displayDate: displayHistoricalDate(parsedYear, month, day, endDay),
    representativeEpochSeconds,
    intervalStartEpochSeconds: bounds.startEpochSeconds,
    intervalEndEpochSeconds: bounds.endEpochSeconds,
    country: required(row, "Country", index),
    eventType: required(row, "Type of Event", index),
    placeName: required(row, "Place Name", index),
    impact: required(row, "Impact", index),
    affectedPopulation: required(row, "Affected Population", index),
    responsibleParty: required(row, "Important Person/Group Responsible", index),
    outcome: required(row, "Outcome", index),
  };
}

function required(row, key, index) {
  const value = clean(row[key]);
  if (value.length === 0) throw new Error(`Historical CSV row ${index + 2} has no ${key}.`);
  return value;
}

function clean(value) {
  return String(value ?? "")
    .trim()
    .replace(/\s+/g, " ");
}

function isKnown(value) {
  return value.length > 0 && value.toLowerCase() !== "unknown";
}

function parseHistoricalYear(value) {
  const match = /^(\d+)\s*(BC|BCE)?$/i.exec(value);
  if (match === null) throw new Error(`Unsupported historical year ${JSON.stringify(value)}.`);
  const magnitude = Number.parseInt(match[1] ?? "", 10);
  return match[2] === undefined ? magnitude : 1 - magnitude;
}

function monthNumber(value, index) {
  const monthIndex = monthNames.findIndex((month) => month.toLowerCase() === value.toLowerCase());
  if (monthIndex < 0)
    throw new Error(`Historical CSV row ${index + 2} has invalid month ${value}.`);
  return monthIndex + 1;
}

function resolveDateParts(rawMonth, rawDay, index) {
  let month = isKnown(rawMonth) ? monthNumber(rawMonth, index) : null;
  if (month === null && isKnown(rawDay)) {
    const monthFromDate = monthNames.findIndex(
      (candidate) => candidate.toLowerCase() === rawDay.toLowerCase(),
    );
    if (monthFromDate >= 0) month = monthFromDate + 1;
  }

  if (month === null || !isKnown(rawDay)) return { month, day: null, endDay: null };
  const values = [...rawDay.matchAll(/\d+/g)].map((match) => Number.parseInt(match[0], 10));
  const plausibleDays = values.filter((value) => value >= 1 && value <= 31);
  if (plausibleDays.length === 0) return { month, day: null, endDay: null };
  const day = plausibleDays[0] ?? null;
  const endDay = plausibleDays.at(-1) ?? day;
  if (day === null || endDay === null || endDay < day) {
    throw new Error(`Historical CSV row ${index + 2} has invalid day range ${rawDay}.`);
  }
  return { month, day, endDay };
}

function dateBounds(year, month, day, endDay, precision) {
  const start = utcDate(year, precision === "year" ? 1 : month, precision === "day" ? day : 1);
  let end;
  if (precision === "day") {
    end = utcDate(year, month, endDay);
    end.setUTCDate(end.getUTCDate() + 1);
  } else if (precision === "month") {
    end = utcDate(year, month + 1, 1);
  } else {
    end = utcDate(year + 1, 1, 1);
  }
  if (
    precision === "day" &&
    (start.getUTCFullYear() !== year ||
      start.getUTCMonth() + 1 !== month ||
      start.getUTCDate() !== day)
  ) {
    throw new Error(`Invalid historical date ${displayHistoricalDate(year, month, day, endDay)}.`);
  }
  return {
    startEpochSeconds: Math.floor(start.getTime() / 1_000),
    endEpochSeconds: Math.floor(end.getTime() / 1_000),
  };
}

function utcDate(year, rawMonth, day) {
  let month = rawMonth;
  let normalizedYear = year;
  while (month > 12) {
    month -= 12;
    normalizedYear += 1;
  }
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(normalizedYear, month - 1, day);
  return date;
}

function displayHistoricalDate(year, month, day, endDay) {
  const displayYear = year <= 0 ? `${1 - year} BC` : String(year);
  const parts = [];
  if (day !== null)
    parts.push(endDay !== null && endDay !== day ? `${day}–${endDay}` : String(day));
  if (month !== null) parts.push(monthNames[month - 1]);
  parts.push(displayYear);
  return parts.join(" ");
}

function validateSolarSeries(value) {
  if (!Array.isArray(value?.series)) throw new Error("Solar temporal data has no series array.");
  return value.series.map((entry) => {
    if (!Array.isArray(entry) || !Number.isInteger(entry[0]) || !Array.isArray(entry[1])) {
      throw new Error("Solar temporal data contains an invalid series.");
    }
    return [
      entry[0],
      entry[1].map((eclipse) => {
        if (!Array.isArray(eclipse) || !Number.isFinite(eclipse[0])) {
          throw new Error(`Saros ${entry[0]} has an invalid eclipse.`);
        }
        return eclipse[0];
      }),
    ];
  });
}

function activeInterval(eclipses, instant) {
  if (eclipses.length < 2 || !(eclipses[0] < instant && eclipses.at(-1) > instant)) {
    return undefined;
  }
  let low = 0;
  let high = eclipses.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if ((eclipses[middle] ?? Number.POSITIVE_INFINITY) <= instant) low = middle + 1;
    else high = middle;
  }
  const previous = eclipses[low - 1];
  const next = eclipses[low];
  return previous === undefined || next === undefined ? undefined : { previous, next };
}

function phaseValue(previous, next, instant) {
  return Math.max(0, Math.min((instant - previous) / (next - previous), 1 - Number.EPSILON));
}

function radixAddress(phase, radix, depth) {
  const addressBinCount = radix === 8 && depth === harmonicDepth ? binCount : radix ** depth;
  const binIndex = Math.min(Math.floor(phase * addressBinCount), addressBinCount - 1);
  return binIndex.toString(radix).toUpperCase().padStart(depth, "0");
}
