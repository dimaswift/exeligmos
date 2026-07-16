import { randomUUID } from "node:crypto";

import { Ajv2020, type ValidateFunction } from "ajv/dist/2020.js";
import * as formatsModule from "ajv-formats";
import type { FormatsPlugin } from "ajv-formats";
import Mustache from "mustache";
import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  assertSerializedJsonSize,
  PUBLIC_RECORD_PAYLOAD_MAX_BYTES,
  RESOURCE_METADATA_MAX_BYTES,
} from "./limits.js";
import {
  cursorSignature,
  databaseErrorCode,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type JsonObject,
  mergeJsonObject,
  type MutationResponse,
  optionalDate,
  parsePageLimit,
  requireMatchingEtag,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";

export type TemplateEngine = "mustache";

export interface CreateTemplateInput {
  readonly id?: string;
  readonly name: string;
  readonly description?: string;
  readonly engine: TemplateEngine;
  readonly body: JsonObject;
  readonly variableSchema: JsonObject;
  readonly metadata?: JsonObject;
}

export interface UpdateTemplateInput {
  readonly name?: string;
  readonly description?: string | null;
  readonly engine?: TemplateEngine;
  readonly body?: JsonObject;
  readonly variableSchema?: JsonObject;
  readonly metadata?: JsonObject;
}

export interface TemplateResource {
  readonly id: string;
  readonly userId: string;
  readonly name: string;
  readonly description?: string;
  readonly engine: TemplateEngine;
  readonly body: JsonObject;
  readonly variableSchema: JsonObject;
  readonly metadata: JsonObject;
  readonly version: number;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly retiredAt?: string;
}

export interface TemplatePage {
  readonly data: readonly TemplateResource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface TemplateListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly updatedAfter?: string;
}

interface TemplateRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly name: string;
  readonly description: string | null;
  readonly engine: TemplateEngine;
  readonly body: JsonObject;
  readonly variable_schema: JsonObject;
  readonly metadata: JsonObject;
  readonly version: number;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly retired_at: Date | string | null;
  readonly deleted_at: Date | string | null;
}

interface TemplateCursor {
  readonly v: 1;
  readonly kind: "templates";
  readonly signature: string;
  readonly name: string;
  readonly id: string;
}

interface TemplateDefinition {
  readonly name: string;
  readonly description: string | null;
  readonly engine: TemplateEngine;
  readonly body: JsonObject;
  readonly variableSchema: JsonObject;
  readonly metadata: JsonObject;
}

const addFormats = formatsModule.default as unknown as FormatsPlugin;

export class TemplateService {
  constructor(private readonly database: Database) {}

  async list(principal: Principal, query: TemplateListQuery): Promise<TemplatePage> {
    const limit = parsePageLimit(query.limit);
    const updatedAfter = optionalDate(query.updatedAfter, "updatedAfter");
    const signature = cursorSignature({ userId: principal.userId, updatedAfter });
    const cursor = decodeTemplateCursor(query.cursor, signature);
    const values: unknown[] = [principal.userId];
    const where = ["t.user_id = $1", "t.deleted_at IS NULL", "t.retired_at IS NULL"];
    if (updatedAfter !== undefined) {
      values.push(updatedAfter);
      where.push(`t.updated_at >= $${values.length}::timestamptz`);
    }
    if (cursor !== undefined) {
      values.push(cursor.name, cursor.id);
      where.push(`(t.name, t.id) > ($${values.length - 1}::text, $${values.length}::uuid)`);
    }
    values.push(limit + 1);
    const result = await this.database.query<TemplateRow>(
      `${templateSelect("t.version")}
       WHERE ${where.join(" AND ")}
       ORDER BY t.name ASC, t.id ASC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(mapTemplateRow),
      hasMore,
      ...(hasMore && last !== undefined
        ? { nextCursor: encodeTemplateCursor(signature, last) }
        : {}),
    };
  }

  async get(userId: string, templateId: string, version?: unknown): Promise<TemplateResource> {
    assertUuid(templateId, "templateId");
    const parsedVersion = optionalVersion(version);
    const row = parsedVersion === undefined
      ? await loadActiveTemplateRow(this.database, userId, templateId)
      : await loadTemplateVersionRow(this.database, userId, templateId, parsedVersion);
    if (row === undefined) {
      throw templateNotFound();
    }
    return mapTemplateRow(row);
  }

  async create(
    principal: Principal,
    input: CreateTemplateInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<TemplateResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createTemplate",
        idempotencyKey,
        { input },
        async (queryable) => {
          const resource = await createTemplateInTransaction(
            queryable,
            principal,
            input,
            requestId,
          );
          return {
            status: 201,
            headers: {
              location: `/v1/templates/${resource.id}`,
              etag: templateEtag(resource.id, resource.revision),
            },
            body: resource,
          };
        },
      ),
    );
  }

  async createVersion(
    principal: Principal,
    templateId: string,
    input: UpdateTemplateInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<TemplateResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createTemplateVersion",
        idempotencyKey,
        { templateId, ifMatch, input },
        async (queryable) => {
          const resource = await createTemplateVersionInTransaction(
            queryable,
            principal,
            templateId,
            input,
            ifMatch,
            requestId,
          );
          return {
            status: 200,
            headers: { etag: templateEtag(resource.id, resource.revision) },
            body: resource,
          };
        },
      ),
    );
  }

  async retire(
    principal: Principal,
    templateId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteTemplate",
        idempotencyKey,
        { templateId, ifMatch },
        async (queryable) => {
          await retireTemplateInTransaction(
            queryable,
            principal,
            templateId,
            ifMatch,
            requestId,
          );
          return { status: 204, headers: {}, body: null };
        },
      ),
    );
  }

  private async translate<Result>(work: () => Promise<Result>): Promise<Result> {
    try {
      return await work();
    } catch (error) {
      if (databaseErrorCode(error) !== undefined) {
        translateDatabaseError(error);
      }
      throw error;
    }
  }
}

/** Transaction-scoped create used by both direct HTTP and atomic sync batches. */
export async function createTemplateInTransaction(
  queryable: Queryable,
  principal: Principal,
  input: CreateTemplateInput,
  requestId: string,
): Promise<TemplateResource> {
  const definition = validateTemplateDefinition(input);
  const id = input.id ?? randomUUID();
  if (input.id !== undefined) {
    assertUuid(input.id, "id");
  }
  await queryable.query(
    `INSERT INTO templates (
       id, user_id, name, description, engine, body, variable_schema, metadata
     ) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8::jsonb)`,
    [
      id,
      principal.userId,
      definition.name,
      definition.description,
      definition.engine,
      JSON.stringify(definition.body),
      JSON.stringify(definition.variableSchema),
      JSON.stringify(definition.metadata),
    ],
  );
  await queryable.query(
    `INSERT INTO template_versions (
       user_id, template_id, version, body, variable_schema
     ) VALUES ($1, $2, 1, $3::jsonb, $4::jsonb)`,
    [
      principal.userId,
      id,
      JSON.stringify(definition.body),
      JSON.stringify(definition.variableSchema),
    ],
  );
  await writeTemplateAudit(queryable, principal, "template.create", id, requestId);
  const row = await loadActiveTemplateRow(queryable, principal.userId, id);
  if (row === undefined) {
    throw new Error("Created template could not be reloaded");
  }
  return mapTemplateRow(row);
}

/** RFC 7396 patch semantics; every accepted patch creates a new immutable version. */
export async function createTemplateVersionInTransaction(
  queryable: Queryable,
  principal: Principal,
  templateId: string,
  input: UpdateTemplateInput,
  ifMatch: string,
  requestId: string,
): Promise<TemplateResource> {
  assertUuid(templateId, "templateId");
  if (Object.keys(input).length === 0) {
    throw invalidRequest("The template patch must contain at least one property.");
  }
  const current = await lockActiveTemplate(queryable, principal.userId, templateId);
  if (current === undefined) {
    throw templateNotFound();
  }
  requireMatchingEtag(ifMatch, templateEtag(templateId, Number(current.revision)));
  const metadata = input.metadata === undefined
    ? current.metadata
    : mergeJsonObject(current.metadata, input.metadata);
  const definition = validateTemplateDefinition({
    name: input.name ?? current.name,
    ...(input.description === undefined
      ? current.description === null ? {} : { description: current.description }
      : input.description === null ? {} : { description: input.description }),
    engine: input.engine ?? current.engine,
    body: input.body ?? current.body,
    variableSchema: input.variableSchema ?? current.variable_schema,
    metadata,
  });
  return updateLockedTemplate(queryable, principal, current, definition, requestId);
}

/** Full replacement semantics used by sync upserts of an existing template. */
export async function replaceTemplateInTransaction(
  queryable: Queryable,
  principal: Principal,
  templateId: string,
  input: CreateTemplateInput,
  ifMatch: string,
  requestId: string,
): Promise<TemplateResource> {
  assertUuid(templateId, "templateId");
  if (input.id !== undefined && input.id !== templateId) {
    throw invalidRequest("template.id must match the resource ID being replaced.");
  }
  const current = await lockActiveTemplate(queryable, principal.userId, templateId);
  if (current === undefined) {
    throw templateNotFound();
  }
  requireMatchingEtag(ifMatch, templateEtag(templateId, Number(current.revision)));
  return updateLockedTemplate(
    queryable,
    principal,
    current,
    validateTemplateDefinition(input),
    requestId,
  );
}

export async function retireTemplateInTransaction(
  queryable: Queryable,
  principal: Principal,
  templateId: string,
  ifMatch: string,
  requestId: string,
): Promise<void> {
  assertUuid(templateId, "templateId");
  const current = await lockActiveTemplate(queryable, principal.userId, templateId);
  if (current === undefined) {
    throw templateNotFound();
  }
  requireMatchingEtag(ifMatch, templateEtag(templateId, Number(current.revision)));
  await queryable.query(
    `UPDATE templates
     SET retired_at = clock_timestamp(),
         deleted_at = clock_timestamp(),
         updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [principal.userId, templateId],
  );
  await writeTemplateAudit(queryable, principal, "template.retire", templateId, requestId);
}

export async function loadActiveTemplateResource(
  queryable: Queryable,
  userId: string,
  templateId: string,
): Promise<TemplateResource | undefined> {
  const row = await loadActiveTemplateRow(queryable, userId, templateId);
  return row === undefined ? undefined : mapTemplateRow(row);
}

export async function loadActiveTemplateResources(
  queryable: Queryable,
  userId: string,
  templateIds: readonly string[],
): Promise<ReadonlyMap<string, TemplateResource>> {
  if (templateIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<TemplateRow>(
    `${templateSelect("t.version")}
     WHERE t.user_id = $1 AND t.id = ANY($2::uuid[])
       AND t.deleted_at IS NULL AND t.retired_at IS NULL`,
    [userId, templateIds],
  );
  return new Map(result.rows.map((row) => [row.id, mapTemplateRow(row)]));
}

export function validateTemplateDefinition(input: CreateTemplateInput): TemplateDefinition {
  const name = validateName(input.name);
  const description = validateDescription(input.description);
  if (input.engine !== "mustache") {
    throw unprocessable("engine must be mustache.", "invalid_template_engine");
  }
  const body = validateBody(input.body);
  const variableSchema = validateVariableSchema(input.variableSchema);
  const metadata = validateMetadata(input.metadata ?? {});
  return { name, description, engine: input.engine, body, variableSchema, metadata };
}

export function templateEtag(templateId: string, revision: number): string {
  return `"template-${templateId}-r${revision}"`;
}

export function mapTemplateRow(row: TemplateRow): TemplateResource {
  return {
    id: row.id,
    userId: row.user_id,
    name: row.name,
    ...(row.description === null ? {} : { description: row.description }),
    engine: row.engine,
    body: row.body,
    variableSchema: row.variable_schema,
    metadata: row.metadata,
    version: row.version,
    revision: Number(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
    ...(row.retired_at === null ? {} : { retiredAt: isoDate(row.retired_at) }),
  };
}

async function updateLockedTemplate(
  queryable: Queryable,
  principal: Principal,
  current: TemplateRow,
  definition: TemplateDefinition,
  requestId: string,
): Promise<TemplateResource> {
  const nextVersion = current.version + 1;
  if (!Number.isSafeInteger(nextVersion) || nextVersion > 2_147_483_647) {
    throw unprocessable("The template version cannot be incremented.", "template_version_limit");
  }
  await queryable.query(
    `UPDATE templates SET
       name = $3,
       description = $4,
       engine = $5,
       body = $6::jsonb,
       variable_schema = $7::jsonb,
       metadata = $8::jsonb,
       version = $9,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      principal.userId,
      current.id,
      definition.name,
      definition.description,
      definition.engine,
      JSON.stringify(definition.body),
      JSON.stringify(definition.variableSchema),
      JSON.stringify(definition.metadata),
      nextVersion,
    ],
  );
  await queryable.query(
    `INSERT INTO template_versions (
       user_id, template_id, version, body, variable_schema
     ) VALUES ($1, $2, $3, $4::jsonb, $5::jsonb)`,
    [
      principal.userId,
      current.id,
      nextVersion,
      JSON.stringify(definition.body),
      JSON.stringify(definition.variableSchema),
    ],
  );
  await writeTemplateAudit(
    queryable,
    principal,
    "template.version.create",
    current.id,
    requestId,
  );
  const row = await loadActiveTemplateRow(queryable, principal.userId, current.id);
  if (row === undefined) {
    throw new Error("Updated template could not be reloaded");
  }
  return mapTemplateRow(row);
}

async function loadActiveTemplateRow(
  queryable: Queryable,
  userId: string,
  templateId: string,
): Promise<TemplateRow | undefined> {
  const result = await queryable.query<TemplateRow>(
    `${templateSelect("t.version")}
     WHERE t.user_id = $1 AND t.id = $2
       AND t.deleted_at IS NULL AND t.retired_at IS NULL`,
    [userId, templateId],
  );
  return result.rows[0];
}

async function loadTemplateVersionRow(
  queryable: Queryable,
  userId: string,
  templateId: string,
  version: number,
): Promise<TemplateRow | undefined> {
  const result = await queryable.query<TemplateRow>(
    `${templateSelect("$3::integer")}
     WHERE t.user_id = $1 AND t.id = $2`,
    [userId, templateId, version],
  );
  return result.rows[0];
}

async function lockActiveTemplate(
  queryable: Queryable,
  userId: string,
  templateId: string,
): Promise<TemplateRow | undefined> {
  const result = await queryable.query<TemplateRow>(
    `${templateSelect("t.version")}
     WHERE t.user_id = $1 AND t.id = $2
       AND t.deleted_at IS NULL AND t.retired_at IS NULL
     FOR UPDATE OF t`,
    [userId, templateId],
  );
  return result.rows[0];
}

function templateSelect(versionExpression: string): string {
  return `SELECT
     t.id,
     t.user_id,
     t.name,
     t.description,
     t.engine,
     tv.body,
     tv.variable_schema,
     t.metadata,
     tv.version,
     t.revision,
     t.created_at,
     t.updated_at,
     t.retired_at,
     t.deleted_at
   FROM templates t
   JOIN template_versions tv
     ON tv.user_id = t.user_id
    AND tv.template_id = t.id
    AND tv.version = ${versionExpression}`;
}

async function writeTemplateAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  templateId: string,
  requestId: string,
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id, request_id
     ) VALUES ($1, $2, $3, $4, 'template', $5, $6)`,
    [principal.userId, principal.kind, principal.actorId, action, templateId, requestId],
  );
}

function encodeTemplateCursor(signature: string, row: TemplateRow): string {
  const cursor: TemplateCursor = {
    v: 1,
    kind: "templates",
    signature,
    name: row.name,
    id: row.id,
  };
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodeTemplateCursor(
  value: string | undefined,
  signature: string,
): TemplateCursor | undefined {
  if (value === undefined) {
    return undefined;
  }
  try {
    const decoded: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (!isTemplateCursor(decoded) || decoded.signature !== signature) {
      throw new Error("Invalid template cursor");
    }
    return decoded;
  } catch {
    throw invalidRequest(
      "The cursor is malformed or does not belong to this query.",
      "invalid_cursor",
    );
  }
}

function isTemplateCursor(value: unknown): value is TemplateCursor {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const cursor = value as Partial<TemplateCursor>;
  return (
    cursor.v === 1 &&
    cursor.kind === "templates" &&
    typeof cursor.signature === "string" &&
    typeof cursor.name === "string" &&
    codePointLength(cursor.name) >= 1 &&
    codePointLength(cursor.name) <= 120 &&
    typeof cursor.id === "string" &&
    isUuid(cursor.id)
  );
}

function validateName(value: unknown): string {
  if (
    typeof value !== "string" ||
    value !== value.trim() ||
    codePointLength(value) < 1 ||
    codePointLength(value) > 120
  ) {
    throw unprocessable(
      "name must be trimmed and contain 1 to 120 characters.",
      "invalid_template_name",
    );
  }
  assertSerializedJsonSize(value, 1_024, "name");
  return value;
}

function validateDescription(value: unknown): string | null {
  if (value === undefined) {
    return null;
  }
  if (typeof value !== "string" || codePointLength(value) > 2_000) {
    throw unprocessable(
      "description must contain at most 2000 characters.",
      "invalid_template_description",
    );
  }
  assertSerializedJsonSize(value, 16_384, "description");
  return value;
}

function validateBody(value: unknown): JsonObject {
  if (!isObject(value) || Object.keys(value).length === 0) {
    throw unprocessable("body must be a non-empty JSON object.", "invalid_template_body");
  }
  assertSerializedJsonSize(value, PUBLIC_RECORD_PAYLOAD_MAX_BYTES, "body");
  validateMustacheValue(value);
  return value;
}

function validateMustacheValue(value: unknown): void {
  if (Array.isArray(value)) {
    for (const child of value) {
      validateMustacheValue(child);
    }
    return;
  }
  if (isObject(value)) {
    for (const child of Object.values(value)) {
      validateMustacheValue(child);
    }
    return;
  }
  if (typeof value !== "string") {
    return;
  }
  try {
    const tokens = Mustache.parse(value);
    if (containsPartialToken(tokens)) {
      throw unprocessable(
        "Template partials are not supported because templates have no partial registry.",
        "template_partial_unsupported",
      );
    }
  } catch (error) {
    if (error instanceof HttpProblem) {
      throw error;
    }
    throw unprocessable("The template contains invalid Mustache syntax.", "invalid_template");
  }
}

function containsPartialToken(value: unknown): boolean {
  if (!Array.isArray(value)) {
    return false;
  }
  if (value[0] === ">") {
    return true;
  }
  return value.some((child) => containsPartialToken(child));
}

function validateVariableSchema(value: unknown): JsonObject {
  if (!isObject(value) || Object.keys(value).length === 0) {
    throw unprocessable(
      "variableSchema must be a non-empty JSON Schema object.",
      "invalid_template_schema",
    );
  }
  assertSerializedJsonSize(value, PUBLIC_RECORD_PAYLOAD_MAX_BYTES, "variableSchema");
  try {
    // A fresh Ajv instance prevents one user's `$id` from colliding with a
    // schema compiled for another tenant. Rendering is synchronous, so async
    // schemas are deliberately outside this API profile.
    const validator = createVariableSchemaAjv().compile(value);
    if ((validator as ValidateFunction<unknown> & { readonly $async?: boolean }).$async === true) {
      throw new Error("Async JSON Schemas are unsupported");
    }
  } catch {
    throw unprocessable(
      "variableSchema must be a valid JSON Schema 2020-12 document.",
      "invalid_template_schema",
    );
  }
  return value;
}

function createVariableSchemaAjv(): Ajv2020 {
  return addFormats(new Ajv2020({ allErrors: true, strict: true, validateFormats: true }));
}

function validateMetadata(value: unknown): JsonObject {
  if (!isObject(value)) {
    throw unprocessable("metadata must be a JSON object.", "invalid_metadata");
  }
  assertSerializedJsonSize(value, RESOURCE_METADATA_MAX_BYTES, "metadata");
  return value;
}

function optionalVersion(value: unknown): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 2_147_483_647) {
    throw invalidRequest("version must be a positive 32-bit integer.");
  }
  return parsed;
}

function templateNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "template_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:template-not-found",
    detail: "The requested template does not exist.",
  });
}

function assertUuid(value: string, name: string): void {
  if (!isUuid(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function isObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function codePointLength(value: string): number {
  return [...value].length;
}
