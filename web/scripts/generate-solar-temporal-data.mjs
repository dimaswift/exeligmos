import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "../..");
const solarDirectory = path.join(repositoryRoot, "SarosHarmonicJournal/Resources/SolarData");
const geometryDirectory = path.join(repositoryRoot, "SarosHarmonicJournal/Resources/SolarGeoData");
const outputPath = path.join(
  scriptDirectory,
  "../app/features/temporal/generated/solar-temporal-data.json",
);
const eclipseTimeBytes = 8;
const eclipseInfoBytes = 10;
const sarosSeriesCount = 180;
const sarosIndexBytesPerSeries = 194;
const maximumEclipsesPerSeries = 96;
const checkOnly = parseArguments(process.argv.slice(2));

class BitReader {
  constructor(data, bitOffset, bitLimit = data.length * 8) {
    this.data = data;
    this.bitOffset = bitOffset;
    this.bitLimit = bitLimit;
  }

  readUnsigned(bits) {
    if (!Number.isSafeInteger(bits) || bits < 0 || bits > 53) {
      throw new RangeError("Bit width exceeds safe integer precision.");
    }
    if (this.bitOffset + bits > this.bitLimit) {
      throw new RangeError("Read past geometry record boundary.");
    }
    let value = 0;
    let remaining = bits;
    while (remaining > 0) {
      const byteIndex = this.bitOffset >> 3;
      if (byteIndex >= this.data.length) throw new RangeError("Read past geometry data.");
      const bitInByte = this.bitOffset & 7;
      const available = 8 - bitInByte;
      const take = Math.min(available, remaining);
      const shift = available - take;
      const mask = 2 ** take - 1;
      const chunk = ((this.data[byteIndex] ?? 0) >> shift) & mask;
      value = value * 2 ** take + chunk;
      this.bitOffset += take;
      remaining -= take;
    }
    return value;
  }

  readSigned(bits) {
    const unsigned = this.readUnsigned(bits);
    const top = 2 ** (bits - 1);
    return unsigned >= top ? unsigned - 2 ** bits : unsigned;
  }
}

const [times, info, sarosIndex] = await Promise.all([
  readFile(path.join(solarDirectory, "eclipse_times.db")),
  readFile(path.join(solarDirectory, "eclipse_info.db")),
  readFile(path.join(solarDirectory, "saros.db")),
]);
const eclipseCount = validateCanonicalDatabases(times, info, sarosIndex);

const sourceHash = createHash("sha256");
sourceHash.update(times);
sourceHash.update(info);
sourceHash.update(sarosIndex);

const series = [];
const indexedEclipses = new Set();
for (let saros = 1; saros <= sarosSeriesCount; saros += 1) {
  const geometry = await readGeometrySeries(saros, sourceHash);
  const offset = (saros - 1) * sarosIndexBytesPerSeries;
  const count = sarosIndex[offset];
  if (count === undefined) {
    throw new RangeError(`Saros ${saros} index slot is missing.`);
  }
  if (count > maximumEclipsesPerSeries) {
    throw new RangeError(`Saros ${saros} declares impossible eclipse count ${count}.`);
  }
  if (count === 0) continue;

  const eclipses = [];
  let previousEpochSeconds = Number.NEGATIVE_INFINITY;
  for (let position = 0; position < count; position += 1) {
    const globalIndex = sarosIndex.readUInt16LE(offset + 2 + position * 2);
    if (globalIndex >= eclipseCount) {
      throw new RangeError(
        `Saros ${saros} references eclipse index ${globalIndex}, but only ${eclipseCount} exist.`,
      );
    }
    if (indexedEclipses.has(globalIndex)) {
      throw new RangeError(
        `Eclipse index ${globalIndex} is referenced by more than one Saros slot.`,
      );
    }
    indexedEclipses.add(globalIndex);
    const infoOffset = globalIndex * 10;
    const epochSeconds = Number(times.readBigInt64LE(globalIndex * 8));
    if (epochSeconds <= previousEpochSeconds) {
      throw new RangeError(`Saros ${saros} eclipse timestamps are not strictly increasing.`);
    }
    previousEpochSeconds = epochSeconds;
    if (info[infoOffset + 6] !== saros || info[infoOffset + 7] !== position) {
      throw new RangeError(
        `Saros ${saros} position ${position} disagrees with eclipse_info.db index ${globalIndex}.`,
      );
    }
    const metrics = geometry.get(epochSeconds);
    eclipses.push([
      epochSeconds,
      info[infoOffset + 8] ?? 255,
      (info[infoOffset + 7] ?? position) + 1,
      metrics?.magnitude ?? null,
      metrics?.gamma ?? null,
    ]);
  }
  const seriesEpochs = new Set(eclipses.map((eclipse) => eclipse[0]));
  for (const epochSeconds of geometry.keys()) {
    if (!seriesEpochs.has(epochSeconds)) {
      throw new RangeError(
        `Saros ${saros} geometry timestamp ${epochSeconds} is absent from the canonical index.`,
      );
    }
  }
  series.push([saros, eclipses]);
}
if (indexedEclipses.size !== eclipseCount) {
  throw new RangeError(
    `saros.db indexes ${indexedEclipses.size} of ${eclipseCount} canonical eclipses.`,
  );
}

const output = {
  schemaVersion: 1,
  sourceSha256: sourceHash.digest("hex"),
  series,
};
const serializedOutput = `${JSON.stringify(output)}\n`;

if (checkOnly) {
  await assertGeneratedOutputCurrent(serializedOutput);
} else {
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, serializedOutput);
  process.stdout.write(
    `Generated ${series.length} Saros series (${series.reduce((sum, entry) => sum + entry[1].length, 0)} eclipses, ${output.sourceSha256.slice(0, 12)}).\n`,
  );
}

async function readGeometrySeries(saros, hash) {
  const filePath = path.join(geometryDirectory, `${saros}.bin`);
  let data;
  try {
    data = await readFile(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return new Map();
    throw error;
  }
  hash.update(data);
  if (data.length < 8) {
    throw new RangeError(`Saros ${saros} geometry file is shorter than its minimum header.`);
  }

  const recordCount = data[0] ?? 0;
  const headerSize = 4 + 4 * (recordCount + 1);
  if (data.length < headerSize) {
    throw new RangeError(`Saros ${saros} geometry header exceeds the file length.`);
  }
  const offsets = Array.from({ length: recordCount + 1 }, (_, index) =>
    data.readUInt32LE(4 + index * 4),
  );
  const payloadBitCount = (data.length - headerSize) * 8;
  if (offsets[0] !== 0) {
    throw new RangeError(`Saros ${saros} geometry payload must start at bit zero.`);
  }
  const finalOffset = offsets.at(-1) ?? 0;
  if (finalOffset > payloadBitCount || payloadBitCount - finalOffset >= 8) {
    throw new RangeError(`Saros ${saros} geometry payload length disagrees with its offset table.`);
  }

  const records = new Map();
  for (let index = 0; index < recordCount; index += 1) {
    const startOffset = offsets[index];
    const endOffset = offsets[index + 1];
    if (startOffset === undefined || endOffset === undefined || endOffset <= startOffset) {
      throw new RangeError(`Saros ${saros} geometry record offsets are not strictly increasing.`);
    }
    const recordStart = headerSize * 8 + startOffset;
    const recordEnd = headerSize * 8 + endOffset;
    const reader = new BitReader(data, recordStart, recordEnd);
    const { epochSeconds, magnitude, gamma } = decodeGeometryRecord(reader);
    if (reader.bitOffset !== recordEnd) {
      throw new RangeError(`Saros ${saros} geometry record ${index} has trailing bits.`);
    }
    if (records.has(epochSeconds)) {
      throw new RangeError(`Saros ${saros} geometry repeats timestamp ${epochSeconds}.`);
    }
    records.set(epochSeconds, { magnitude, gamma });
  }
  return records;
}

function decodeGeometryRecord(reader) {
  reader.readUnsigned(5);
  const epochSeconds = reader.readSigned(35);
  readCoordinate(reader);
  readCoordinate(reader);
  reader.readUnsigned(7);
  const magnitude = reader.readUnsigned(14) / 10_000;
  const gammaSign = reader.readUnsigned(1);
  const gammaMagnitude = reader.readUnsigned(14);
  const gamma = (gammaMagnitude / 10_000) * (gammaSign === 1 ? -1 : 1);
  if (reader.readUnsigned(1) === 1) reader.readUnsigned(10);
  if (reader.readUnsigned(1) === 1) reader.readUnsigned(11);
  const polygonCount = reader.readUnsigned(5);
  for (let polygon = 0; polygon < polygonCount; polygon += 1) {
    const pointCount = reader.readUnsigned(13);
    for (let point = 0; point < pointCount; point += 1) {
      readCoordinate(reader);
      readCoordinate(reader);
    }
  }
  return { epochSeconds, magnitude, gamma };
}

function readCoordinate(reader) {
  const sign = reader.readUnsigned(1);
  const magnitude = reader.readUnsigned(28);
  return (magnitude / 1_000_000) * (sign === 1 ? -1 : 1);
}

function validateCanonicalDatabases(times, info, sarosIndex) {
  if (times.length === 0 || times.length % eclipseTimeBytes !== 0) {
    throw new RangeError(
      "eclipse_times.db must contain a non-empty sequence of 8-byte timestamps.",
    );
  }
  const eclipseCount = times.length / eclipseTimeBytes;
  if (info.length !== eclipseCount * eclipseInfoBytes) {
    throw new RangeError(
      `eclipse_info.db must contain exactly ${eclipseCount} ten-byte records; found ${info.length} bytes.`,
    );
  }
  const expectedSarosBytes = sarosSeriesCount * sarosIndexBytesPerSeries;
  if (sarosIndex.length !== expectedSarosBytes) {
    throw new RangeError(
      `saros.db must contain exactly ${expectedSarosBytes} bytes; found ${sarosIndex.length}.`,
    );
  }
  return eclipseCount;
}

async function assertGeneratedOutputCurrent(expected) {
  let current;
  try {
    current = await readFile(outputPath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error(
        `Generated solar data is missing at ${outputPath}. Run npm run solar:generate.`,
        { cause: error },
      );
    }
    throw error;
  }
  if (current !== expected) {
    throw new Error(
      "Generated solar data is stale. Run npm run solar:generate and commit the result.",
    );
  }
  process.stdout.write(
    `Solar data is current (${series.length} series, ${output.sourceSha256.slice(0, 12)}).\n`,
  );
}

function parseArguments(arguments_) {
  if (arguments_.length === 0) return false;
  if (arguments_.length === 1 && arguments_[0] === "--check") return true;
  throw new Error("Usage: node scripts/generate-solar-temporal-data.mjs [--check]");
}
