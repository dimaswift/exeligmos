import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

import Ajv2020 from "ajv/dist/2020.js";

const paths = {
  catalog: new URL("catalog.json", new URL("../", import.meta.url)),
  catalogSchema: new URL("catalog.schema.json", new URL("../", import.meta.url)),
  vectors: new URL("conformance/v1.json", new URL("../", import.meta.url)),
  vectorsSchema: new URL("conformance/vectors.schema.json", new URL("../", import.meta.url)),
  package: new URL("package.json", new URL("../", import.meta.url))
};

const [catalogText, catalogSchemaText, vectorsText, vectorsSchemaText, packageText] = await Promise.all([
  readFile(paths.catalog, "utf8"),
  readFile(paths.catalogSchema, "utf8"),
  readFile(paths.vectors, "utf8"),
  readFile(paths.vectorsSchema, "utf8"),
  readFile(paths.package, "utf8")
]);

const catalog = parseJson(catalogText, "catalog.json");
const catalogSchema = parseJson(catalogSchemaText, "catalog.schema.json");
const vectors = parseJson(vectorsText, "conformance/v1.json");
const vectorsSchema = parseJson(vectorsSchemaText, "conformance/vectors.schema.json");
const packageJson = parseJson(packageText, "package.json");

const ajv = new Ajv2020({ allErrors: true, strict: true });
validateSchemaInstance(ajv, catalogSchema, catalog, "catalog.json");
validateSchemaInstance(ajv, vectorsSchema, vectors, "conformance/v1.json");

validateCatalogInvariants();
runConformanceVectors();

const fingerprint = createHash("sha256").update(catalogText).digest("hex");
const operationCounts = Object.entries(
  vectors.vectors.reduce((counts, vector) => {
    counts[vector.operation] = (counts[vector.operation] ?? 0) + 1;
    return counts;
  }, {})
)
  .sort(([left], [right]) => left.localeCompare(right))
  .map(([operation, count]) => `${operation}=${count}`)
  .join(", ");

console.log(`Validated ${vectors.vectors.length} conformance vectors against catalog ${catalog.catalogVersion}.`);
console.log(`Operations: ${operationCounts}`);
console.log(`Catalog SHA-256: ${fingerprint}`);

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function validateSchemaInstance(validator, schema, instance, label) {
  let validate;
  try {
    validate = validator.compile(schema);
  } catch (error) {
    throw new Error(`Could not compile the JSON Schema for ${label}: ${error.message}`);
  }

  if (!validate(instance)) {
    const details = validate.errors
      .map((error) => `${error.instancePath || "/"} ${error.message}`)
      .join("\n");
    throw new Error(`${label} does not match its JSON Schema:\n${details}`);
  }
}

function validateCatalogInvariants() {
  assert(catalog.catalogVersion === packageJson.version, "package.json version must match catalogVersion");
  assert(catalog.catalogVersion === vectors.catalogVersion, "conformance catalogVersion must match catalogVersion");

  const radixDigits = [...catalog.radix.digits];
  assert(radixDigits.length === catalog.radix.value, "radix.digits length must equal radix.value");
  assert(
    radixDigits.every((digit, index) => digit === String(index)),
    "radix.digits must be the ordered digits from zero through radix - 1"
  );

  const calculationDepth = catalog.harmonics.calculationDepth;
  const presentationDepth = catalog.harmonics.presentationDepth;
  assertRange(calculationDepth, "harmonics.calculationDepth");
  assertRange(presentationDepth, "harmonics.presentationDepth");
  assert(
    presentationDepth.minimum >= calculationDepth.minimum && presentationDepth.maximum <= calculationDepth.maximum,
    "presentation depths must be a subset of calculation depths"
  );
  assert(
    within(presentationDepth.default, presentationDepth) && within(presentationDepth.canonical, presentationDepth),
    "default and canonical presentation depths must be supported"
  );

  const colorTokenIds = uniqueBy(catalog.semanticTokens.colors, "id", "semantic color token");
  const requireToken = (token, context) => {
    assert(colorTokenIds.has(token), `${context} references missing semantic token ${token}`);
  };

  assertNearlyEqual(
    catalog.time.basePeriod.days * 24 * 60 * 60,
    catalog.time.basePeriod.seconds,
    1e-12,
    "time.basePeriod seconds"
  );

  const unitIds = uniqueBy(catalog.time.units, "id", "time unit");
  const unitById = new Map(catalog.time.units.map((unit) => [unit.id, unit]));
  for (const unit of catalog.time.units) {
    requireToken(unit.semanticColorToken, `time unit ${unit.id}`);
    assert(unit.pattern.length === catalog.time.pulse.glyphDepth, `${unit.id} pattern must match pulse glyph depth`);
  }
  for (const [orderName, ids] of Object.entries(catalog.time.unitOrders)) {
    assert(new Set(ids).size === ids.length, `time.unitOrders.${orderName} contains duplicates`);
    for (const id of ids) {
      assert(unitIds.has(id), `time.unitOrders.${orderName} references missing unit ${id}`);
      if (orderName !== "durationFormatting") {
        assert(unitById.get(id).roles[orderName], `${id} is in ${orderName} order but does not declare that role`);
      }
    }
  }
  for (const role of ["glyph", "ruler", "reference"]) {
    const expected = catalog.time.units.filter((unit) => unit.roles[role]).map((unit) => unit.id);
    assertDeepEqual(catalog.time.unitOrders[role], expected, `time.unitOrders.${role}`);
  }

  const familyIds = uniqueBy(catalog.rarities.families, "id", "rarity family");
  const digitIds = uniqueBy(catalog.rarities.digits, "digit", "rarity digit");
  assertDeepEqual([...familyIds], ["common", "rare", "epic", "legendary", "mythic"], "rarity family order");
  assertDeepEqual([...digitIds], [0, 1, 2, 3, 4, 5, 6, 7], "rarity digit order");
  for (const family of catalog.rarities.families) {
    requireToken(family.semanticColorToken, `rarity family ${family.id}`);
  }
  for (const digit of catalog.rarities.digits) {
    requireToken(digit.semanticColorToken, `rarity digit ${digit.digit}`);
  }
  uniqueBy(catalog.rarities.aliases, "alias", "rarity alias");
  for (const alias of catalog.rarities.aliases) {
    parseRarityId(alias.target);
  }
  uniqueBy(catalog.rarities.colorOverrides, "rarityId", "rarity color override");
  for (const override of catalog.rarities.colorOverrides) {
    parseRarityId(override.rarityId);
    requireToken(override.semanticColorToken, `rarity override ${override.rarityId}`);
  }

  assertRange(catalog.glyph.supportedDepth, "glyph.supportedDepth");
  assert(
    catalog.glyph.supportedDepth.minimum === presentationDepth.minimum &&
      catalog.glyph.supportedDepth.maximum === presentationDepth.maximum,
    "glyph supported depth must match presentation depth"
  );
  const armDigits = uniqueBy(catalog.glyph.arms, "digit", "glyph arm");
  assertDeepEqual([...armDigits], [0, 1, 2, 3, 4, 5, 6, 7], "glyph arm digit order");
  assert(
    catalog.glyph.coreHole.legacyExactDepth === 7 && catalog.glyph.coreHole.legacyExactPoints.length === 8,
    "legacy seven-depth core hole must retain its eight exact points"
  );

  requireToken(catalog.events.unknownDisplay.semanticColorToken, "events.unknownDisplay");
  const eventNamespaceIds = uniqueBy(catalog.events.namespaces, "id", "event namespace");
  const sortedNamespaces = [...catalog.events.namespaces].sort((left, right) => left.minimum - right.minimum);
  assert(sortedNamespaces[0].minimum === catalog.events.typeRange.minimum, "event namespaces must start at type minimum");
  assert(
    sortedNamespaces.at(-1).maximum === catalog.events.typeRange.maximum,
    "event namespaces must end at type maximum"
  );
  sortedNamespaces.forEach((namespace, index) => {
    assertRange(namespace, `event namespace ${namespace.id}`);
    if (index > 0) {
      assert(
        namespace.minimum === sortedNamespaces[index - 1].maximum + 1,
        `event namespace ${namespace.id} must be contiguous and non-overlapping`
      );
    }
    if (namespace.registration === "catalog-block-allocation-required") {
      assert(Number.isInteger(namespace.blockSize), `event namespace ${namespace.id} must declare blockSize`);
      assert(
        (namespace.maximum - namespace.minimum + 1) % namespace.blockSize === 0,
        `event namespace ${namespace.id} range must divide into complete blocks`
      );
    }
  });

  const eventTypes = uniqueBy(catalog.events.entries, "type", "event type");
  uniqueBy(catalog.events.entries, "key", "event key");
  for (const entry of catalog.events.entries) {
    const namespace = eventNamespace(entry.type);
    assert(namespace?.id === entry.namespace, `event type ${entry.type} has the wrong namespace`);
    assert(eventNamespaceIds.has(entry.namespace), `event type ${entry.type} references a missing namespace`);
    requireToken(entry.semanticColorToken, `event type ${entry.type}`);
  }
  assert(eventTypes.has(0), "event type 0 must remain the generic event");
  assert(catalog.events.unknownTypePolicy === "preserve-and-render-generic", "unknown event types must be preserved");

  const producerNamespace = catalog.events.namespaces.find(
    (namespace) => namespace.registration === "catalog-block-allocation-required"
  );
  const allocations = [...catalog.events.producerAllocations].sort((left, right) => left.minimum - right.minimum);
  uniqueBy(allocations, "namespace", "producer allocation namespace");
  allocations.forEach((allocation, index) => {
    assert(
      allocation.minimum >= producerNamespace.minimum && allocation.maximum <= producerNamespace.maximum,
      `producer allocation ${allocation.namespace} is outside the producer range`
    );
    assert(
      allocation.minimum % producerNamespace.blockSize === producerNamespace.minimum % producerNamespace.blockSize,
      `producer allocation ${allocation.namespace} does not begin on a block boundary`
    );
    assert(
      allocation.maximum - allocation.minimum + 1 === producerNamespace.blockSize,
      `producer allocation ${allocation.namespace} must occupy exactly one block`
    );
    if (index > 0) {
      assert(
        allocation.minimum > allocations[index - 1].maximum,
        `producer allocation ${allocation.namespace} overlaps ${allocations[index - 1].namespace}`
      );
    }
  });

  assertDeepEqual(
    catalog.events.providerMetadata.required,
    ["namespace", "name", "version"],
    "provider event metadata required fields"
  );
}

function runConformanceVectors() {
  uniqueBy(vectors.vectors, "id", "conformance vector");
  const operations = {
    clampPresentationDepth: ({ value }) => ({ value: clampPresentationDepth(value) }),
    canonicalOctalAddress: ({ value, storedDepth, outputDepth }) => ({
      value: canonicalOctalAddress(value, storedDepth, outputDepth)
    }),
    rarityOctalAddress: ({ value, storedDepth, rarityId, outputDepth }) => ({
      value: rarityOctalAddress(value, storedDepth, rarityId, outputDepth)
    }),
    normalizeGlyphOctal: ({ value, depth }) => ({ value: normalizeGlyphOctal(value, depth) }),
    classifyRarity,
    rarityDescriptor,
    pulseDuration,
    clockReading,
    glyphSocketDigitIndices,
    glyphFrameBounds,
    eventTypeResolution
  };

  for (const vector of vectors.vectors) {
    const operation = operations[vector.operation];
    assert(operation, `vector ${vector.id} uses unsupported operation ${vector.operation}`);
    let actual;
    try {
      actual = operation(vector.input);
    } catch (error) {
      throw new Error(`Conformance vector ${vector.id} threw: ${error.message}`);
    }
    assertExpectedSubset(actual, vector.expected, vector.id, vectors.floatTolerance);
  }
}

function clampPresentationDepth(value) {
  return clamp(value, catalog.harmonics.presentationDepth.minimum, catalog.harmonics.presentationDepth.maximum);
}

function canonicalOctalAddress(value, storedDepth, rawOutputDepth = catalog.harmonics.presentationDepth.canonical) {
  const depth = clampPresentationDepth(storedDepth);
  const outputDepth = clamp(
    rawOutputDepth,
    catalog.harmonics.presentationDepth.minimum,
    catalog.harmonics.presentationDepth.canonical
  );
  const digits = retainRadixDigits(value);
  if (digits.length >= outputDepth) {
    return digits.slice(0, outputDepth);
  }
  return digits.padEnd(Math.min(depth, outputDepth), "0").padEnd(outputDepth, "0");
}

function rarityOctalAddress(value, storedDepth, rarityId, rawOutputDepth = catalog.harmonics.presentationDepth.canonical) {
  const rarity = parseRarityId(rarityId);
  const depth = clampPresentationDepth(storedDepth);
  const outputDepth = clamp(
    rawOutputDepth,
    catalog.harmonics.presentationDepth.minimum,
    catalog.harmonics.presentationDepth.canonical
  );
  const digits = retainRadixDigits(value);
  if (digits.length >= outputDepth) {
    return digits.slice(0, outputDepth);
  }
  const pad = rarity.repeatedDigit > 0 ? String(rarity.repeatedDigit) : "0";
  return digits.padEnd(Math.min(depth, outputDepth), pad).padEnd(outputDepth, pad);
}

function normalizeGlyphOctal(value, rawDepth) {
  const depth = clampPresentationDepth(rawDepth);
  const digits = retainRadixDigits(value);
  return digits.slice(-depth).padStart(depth, "0");
}

function classifyRarity({ octalAddress, harmonicDepth }) {
  const depth = clampPresentationDepth(harmonicDepth);
  const filtered = retainRadixDigits(octalAddress).slice(0, depth);
  let padded = filtered.padStart(depth, "0");
  let numeric = Number.parseInt(padded, catalog.radix.value) || 0;

  if (numeric === 0) {
    const rarity = parseRarityId(catalog.rarities.classification.allZeroRarity);
    return {
      rarityId: rarity.id,
      order: rarity.family.order,
      repeatedDigit: rarity.repeatedDigit
    };
  }

  if (padded.endsWith("0")) {
    numeric -= 1;
    padded = numeric.toString(catalog.radix.value).padStart(depth, "0");
  }

  const last = padded.at(-1);
  if (last === "0") {
    return { rarityId: "common", order: 0, repeatedDigit: 0 };
  }
  let suffixLength = 0;
  for (let index = padded.length - 1; index >= 0 && padded[index] === last; index -= 1) {
    suffixLength += 1;
  }
  const wildcardPrefixCount = depth - suffixLength;
  if (wildcardPrefixCount > catalog.rarities.classification.maximumRecognizedWildcardPrefixCount) {
    return { rarityId: "common", order: 0, repeatedDigit: 0 };
  }

  const order = wildcardPrefixCount <= 0 ? 6 : 6 - wildcardPrefixCount;
  const repeatedDigit = Number(last);
  const family = familyForOrder(order);
  return {
    rarityId: `${family.id}-${repeatedDigit}`,
    order,
    repeatedDigit
  };
}

function rarityDescriptor({ rarityId, harmonicDepth }) {
  const rarity = parseRarityId(rarityId);
  const depth = clampPresentationDepth(harmonicDepth);
  const family = rarity.family;
  if (family.id === "common") {
    return {
      family: family.id,
      order: 0,
      repeatedDigit: 0,
      rank: 0,
      title: family.title,
      patternLabel: family.title,
      glyphAddress: "0".repeat(depth),
      binStride: null,
      subeventOffset: null
    };
  }

  const suffixLength = Math.max(depth - family.wildcardPrefixCount, 0);
  const title = rarity.repeatedDigit > 0
    ? `${digitDefinition(rarity.repeatedDigit).prefix} ${family.title}`
    : family.title;
  const patternLabel = rarity.repeatedDigit > 0
    ? "X".repeat(Math.min(family.wildcardPrefixCount, depth)) + String(rarity.repeatedDigit).repeat(suffixLength)
    : family.title;
  const glyphDigit = rarity.repeatedDigit > 0 ? rarity.repeatedDigit : catalog.rarities.headerGlyphDigit;
  const glyphAddress =
    "0".repeat(Math.min(family.wildcardPrefixCount, depth)) + String(glyphDigit).repeat(suffixLength);
  const binStride = suffixLength > 0 ? catalog.radix.value ** suffixLength : null;
  const subeventOffset = binStride === null
    ? null
    : rarity.repeatedDigit > 0
      ? rarity.repeatedDigit * ((Math.max(binStride, 1) - 1) / (catalog.radix.value - 1))
      : 0;

  return {
    family: family.id,
    order: family.order,
    repeatedDigit: rarity.repeatedDigit,
    rank: family.order * catalog.radix.value + rarity.repeatedDigit,
    title,
    patternLabel,
    glyphAddress,
    binStride,
    subeventOffset
  };
}

function pulseDuration({ unitId }) {
  const unit = catalog.time.units.find((candidate) => candidate.id === unitId);
  assert(unit, `unknown time unit ${unitId}`);
  return {
    seconds: catalog.time.basePeriod.seconds / catalog.radix.value ** unit.exponent
  };
}

function clockReading({ previousEpochSeconds, nextEpochSeconds, instantEpochSeconds, harmonicDepth }) {
  assert(
    within(harmonicDepth, catalog.harmonics.calculationDepth),
    `harmonic depth ${harmonicDepth} is outside the calculation range`
  );
  const total = nextEpochSeconds - previousEpochSeconds;
  assert(total > 0, "clock interval must have positive duration");
  const rawPhase = (instantEpochSeconds - previousEpochSeconds) / total;
  const phase = Math.min(Math.max(rawPhase, 0), 1 - Number.EPSILON);
  const binCount = catalog.radix.value ** harmonicDepth;
  const scaled = phase * binCount;
  const binIndex = Math.min(Math.floor(scaled), binCount - 1);
  const progressWithinBin = Math.min(Math.max(scaled - binIndex, 0), 1);
  const nextBinIndex = Math.min(binIndex + 1, binCount);
  const nextFlipEpochSeconds = previousEpochSeconds + (nextBinIndex / binCount) * total;
  return {
    phase,
    binCount,
    binIndex,
    octalAddress: binIndex.toString(catalog.radix.value).padStart(harmonicDepth, "0"),
    progressWithinBin,
    nextFlipEpochSeconds,
    timeUntilNextFlip: nextFlipEpochSeconds - instantEpochSeconds
  };
}

function glyphSocketDigitIndices({ depth: rawDepth }) {
  const depth = clampPresentationDepth(rawDepth);
  return {
    indices: Array.from({ length: depth }, (_, socketIndex) => (socketIndex === 0 ? 0 : depth - socketIndex))
  };
}

function glyphFrameBounds({ depth: rawDepth }) {
  const depth = clampPresentationDepth(rawDepth);
  const { socketWidth, coreRadius, gridSize, paddingCells } = catalog.glyph.constants;
  const baseStart = [-socketWidth / 2, -coreRadius];
  const baseEnd = [socketWidth / 2, -coreRadius];
  const rotationStep = 360 / depth;
  const sockets = Array.from({ length: depth }, (_, index) => ({
    start: rotate(baseStart, index * rotationStep),
    end: rotate(baseEnd, index * rotationStep)
  }));
  const points = sockets.flatMap((socket) => [socket.start, socket.end]);
  if (depth === catalog.glyph.coreHole.legacyExactDepth) {
    points.push(...catalog.glyph.coreHole.legacyExactPoints);
  }
  for (let socketIndex = 0; socketIndex < depth; socketIndex += 1) {
    for (const arm of catalog.glyph.arms) {
      points.push(...armToWorldPoints(arm.points, socketIndex, sockets));
    }
  }
  const minX = Math.min(...points.map(([x]) => x));
  const maxX = Math.max(...points.map(([x]) => x));
  const minY = Math.min(...points.map(([, y]) => y));
  const maxY = Math.max(...points.map(([, y]) => y));
  const padding = gridSize * paddingCells;
  const halfWidth = Math.max(
    gridSize,
    Math.ceil(Math.max(Math.abs(minX), Math.abs(maxX)) / gridSize) * gridSize + padding
  );
  const halfHeight = Math.max(
    gridSize,
    Math.ceil(Math.max(Math.abs(minY), Math.abs(maxY)) / gridSize) * gridSize + padding
  );
  return {
    width: halfWidth * 2,
    height: halfHeight * 2,
    aspectRatio: halfWidth / halfHeight
  };
}

function eventTypeResolution({ type }) {
  assert(Number.isInteger(type) && within(type, catalog.events.typeRange), `event type ${type} is outside the wire range`);
  const namespace = eventNamespace(type);
  const entry = catalog.events.entries.find((candidate) => candidate.type === type);
  const requiresProviderMetadata = namespace.registration === "provider-metadata-required";
  return {
    namespace: namespace.id,
    known: Boolean(entry),
    key: entry?.key ?? null,
    label: entry?.label ?? catalog.events.unknownDisplay.labelTemplate.replace("{type}", String(type)),
    semanticColorToken: entry?.semanticColorToken ?? catalog.events.unknownDisplay.semanticColorToken,
    requiresProviderMetadata
  };
}

function parseRarityId(rawId) {
  const alias = catalog.rarities.aliases.find((candidate) => candidate.alias === rawId);
  const id = alias?.target ?? rawId;
  const match = /^(common|rare|epic|legendary|mythic)(?:-([1-7]))?$/.exec(id);
  assert(match, `unknown rarity ${rawId}`);
  const family = catalog.rarities.families.find((candidate) => candidate.id === match[1]);
  const repeatedDigit = match[2] === undefined ? 0 : Number(match[2]);
  assert(!(family.id === "common" && repeatedDigit > 0), "common rarity cannot have a repeated digit");
  return { id, family, repeatedDigit };
}

function familyForOrder(order) {
  const family = catalog.rarities.families.find((candidate) => candidate.order === order);
  assert(family, `no rarity family is registered for order ${order}`);
  return family;
}

function digitDefinition(digit) {
  const definition = catalog.rarities.digits.find((candidate) => candidate.digit === digit);
  assert(definition, `no rarity digit definition for ${digit}`);
  return definition;
}

function eventNamespace(type) {
  return catalog.events.namespaces.find((namespace) => type >= namespace.minimum && type <= namespace.maximum);
}

function retainRadixDigits(value) {
  const supported = new Set(catalog.radix.digits);
  return [...String(value)].filter((character) => supported.has(character)).join("");
}

function rotate([x, y], degrees) {
  const radians = (degrees * Math.PI) / 180;
  const cosine = Math.cos(radians);
  const sine = Math.sin(radians);
  return [x * cosine - y * sine, x * sine + y * cosine];
}

function armToWorldPoints(points, socketIndex, sockets) {
  if (points.length < 2) {
    return points;
  }
  const socket = sockets[socketIndex];
  const center = [(socket.start[0] + socket.end[0]) / 2, (socket.start[1] + socket.end[1]) / 2];
  const dx = socket.end[0] - socket.start[0];
  const dy = socket.end[1] - socket.start[1];
  const length = Math.max(Math.hypot(dx, dy), 0.001);
  const tangent = [dx / length, dy / length];
  let outward = [tangent[1], -tangent[0]];
  if (outward[0] * center[0] + outward[1] * center[1] < 0) {
    outward = [-outward[0], -outward[1]];
  }
  const aligned = points.map((point) => [...point]);
  aligned[0] = [-length / 2, 0];
  aligned[aligned.length - 1] = [length / 2, 0];
  return aligned.map(([x, y]) => [
    center[0] + tangent[0] * x + outward[0] * y,
    center[1] + tangent[1] * x + outward[1] * y
  ]);
}

function assertExpectedSubset(actual, expected, vectorId, tolerance, path = "expected") {
  if (expected === null || typeof expected !== "object") {
    if (typeof expected === "number" && typeof actual === "number" && !Number.isInteger(expected)) {
      assertNearlyEqual(actual, expected, tolerance, `${vectorId} ${path}`);
      return;
    }
    assert(Object.is(actual, expected), `${vectorId} ${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    return;
  }
  if (Array.isArray(expected)) {
    assert(Array.isArray(actual), `${vectorId} ${path}: expected an array`);
    assert(actual.length === expected.length, `${vectorId} ${path}: array length differs`);
    expected.forEach((value, index) => assertExpectedSubset(actual[index], value, vectorId, tolerance, `${path}[${index}]`));
    return;
  }
  assert(actual !== null && typeof actual === "object", `${vectorId} ${path}: expected an object`);
  for (const [key, value] of Object.entries(expected)) {
    assert(Object.hasOwn(actual, key), `${vectorId} ${path}: actual result is missing ${key}`);
    assertExpectedSubset(actual[key], value, vectorId, tolerance, `${path}.${key}`);
  }
}

function uniqueBy(items, key, label) {
  const seen = new Set();
  for (const item of items) {
    const value = item[key];
    assert(!seen.has(value), `duplicate ${label} ${String(value)}`);
    seen.add(value);
  }
  return seen;
}

function assertRange(range, label) {
  assert(Number.isInteger(range.minimum) && Number.isInteger(range.maximum), `${label} must use integer bounds`);
  assert(range.minimum <= range.maximum, `${label} minimum must not exceed maximum`);
}

function within(value, range) {
  return value >= range.minimum && value <= range.maximum;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function assertNearlyEqual(actual, expected, tolerance, label) {
  const scaledTolerance = tolerance * Math.max(1, Math.abs(expected));
  assert(
    Number.isFinite(actual) && Math.abs(actual - expected) <= scaledTolerance,
    `${label}: expected ${expected} ± ${scaledTolerance}, got ${actual}`
  );
}

function assertDeepEqual(actual, expected, label) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
  );
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}
