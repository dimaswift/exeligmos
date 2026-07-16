import type { QueryResultRow } from "pg";

import type { Queryable } from "../db/database.js";
import { unprocessable } from "./shared.js";

export type ReferenceTargetType = "user" | "record" | "event";
export type ReferenceSourceType = "record" | "event";

export interface ResourceReferenceInput {
  readonly relation?: string;
  readonly targetType: ReferenceTargetType;
  readonly targetUserId: string;
  readonly targetId: string;
}

export interface ResourceReference {
  readonly relation: string;
  readonly targetType: ReferenceTargetType;
  readonly targetUserId: string;
  readonly targetId: string;
}

export interface ResourceReferenceRow extends QueryResultRow {
  readonly references: readonly ResourceReference[];
}

interface ResolvedRecordTargetRow extends QueryResultRow {
  readonly user_id: string;
  readonly public_id: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RECORD_ID_PATTERN = /^[A-Za-z0-9_-]{5}$/;
const RELATION_PATTERN = /^[A-Za-z][A-Za-z0-9._:-]{0,63}$/;
const MAX_REFERENCES = 200;

/** SQL projection shared by owner and public record/event reads. */
export function referenceProjectionSql(sourceAlias: string, sourceType: ReferenceSourceType): string {
  const sourceColumn = sourceType === "record" ? "source_record_id" : "source_event_id";
  return `COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'relation', rr.relation,
        'targetType', rr.target_type,
        'targetUserId', rr.target_user_id,
        'targetId', CASE rr.target_type
          WHEN 'user' THEN rr.target_user_id::text
          WHEN 'record' THEN (
            SELECT target.public_id
            FROM records target
            WHERE target.id = rr.target_record_id
          )
          ELSE rr.target_event_id::text
        END
      ) ORDER BY rr.position
    )
    FROM resource_references rr
    WHERE rr.${sourceColumn} = ${sourceAlias}.id
  ), '[]'::jsonb) AS references`;
}

/**
 * Replaces the complete ordered relationship set for one source resource.
 * Targets are identifiers only; database triggers enforce active sources and
 * require every cross-user record/event target to be public.
 */
export async function replaceResourceReferences(
  queryable: Queryable,
  sourceUserId: string,
  sourceType: ReferenceSourceType,
  sourceId: string,
  inputs: readonly ResourceReferenceInput[],
): Promise<void> {
  const references = normalizeReferences(inputs);
  await assertActiveRecordTargets(queryable, references);
  const sourceColumn = sourceType === "record" ? "source_record_id" : "source_event_id";
  await queryable.query(
    `DELETE FROM resource_references
     WHERE source_user_id = $1 AND ${sourceColumn} = $2`,
    [sourceUserId, sourceId],
  );
  if (references.length === 0) {
    return;
  }

  await queryable.query(
    `INSERT INTO resource_references (
       source_user_id, source_type, source_record_id, source_event_id,
       position, relation, target_type, target_user_id, target_record_id,
       target_event_id
     )
     SELECT
       $1::uuid,
       $2::text,
       CASE WHEN $2 = 'record' THEN $3::uuid ELSE NULL END,
       CASE WHEN $2 = 'event' THEN $3::uuid ELSE NULL END,
       (item.ordinality - 1)::integer,
       item.value->>'relation',
       item.value->>'targetType',
       (item.value->>'targetUserId')::uuid,
       CASE WHEN item.value->>'targetType' = 'record'
         THEN target_record.id ELSE NULL END,
       CASE WHEN item.value->>'targetType' = 'event'
         THEN (item.value->>'targetId')::uuid ELSE NULL END
     FROM jsonb_array_elements($4::jsonb) WITH ORDINALITY AS item(value, ordinality)
     LEFT JOIN records target_record
       ON item.value->>'targetType' = 'record'
      AND target_record.user_id = (item.value->>'targetUserId')::uuid
      AND target_record.public_id = item.value->>'targetId'`,
    [sourceUserId, sourceType, sourceId, JSON.stringify(references)],
  );
}

async function assertActiveRecordTargets(
  queryable: Queryable,
  references: readonly ResourceReference[],
): Promise<void> {
  const indexedTargets = references
    .map((reference, index) => ({ reference, index }))
    .filter(({ reference }) => reference.targetType === "record");
  if (indexedTargets.length === 0) {
    return;
  }
  const result = await queryable.query<ResolvedRecordTargetRow>(
    `WITH requested AS (
       SELECT
         item.value->>'targetUserId' AS target_user_id,
         item.value->>'targetId' AS public_id
       FROM jsonb_array_elements($1::jsonb) AS item(value)
     )
     SELECT target.user_id, target.public_id
     FROM records AS target
     JOIN requested
       ON target.user_id = requested.target_user_id::uuid
      AND target.public_id = requested.public_id
     WHERE target.deleted_at IS NULL
     FOR SHARE OF target`,
    [JSON.stringify(indexedTargets.map(({ reference }) => reference))],
  );
  const active = new Set(
    result.rows.map((row) => `${row.user_id}:${row.public_id}`),
  );
  for (const { reference, index } of indexedTargets) {
    if (!active.has(`${reference.targetUserId}:${reference.targetId}`)) {
      throw unprocessable(
        `references[${index}].targetId does not name an active record owned by targetUserId.`,
        "invalid_references",
        `/references/${index}/targetId`,
      );
    }
  }
}

export function normalizeReferences(
  inputs: readonly ResourceReferenceInput[] | undefined,
): readonly ResourceReference[] {
  if (inputs === undefined) {
    return [];
  }
  if (!Array.isArray(inputs) || inputs.length > MAX_REFERENCES) {
    throw unprocessable(
      `references must contain at most ${MAX_REFERENCES} items.`,
      "invalid_references",
    );
  }
  const seen = new Set<string>();
  return inputs.map((input, index) => {
    if (
      input === null ||
      typeof input !== "object" ||
      !["user", "record", "event"].includes(input.targetType) ||
      !UUID_PATTERN.test(input.targetUserId) ||
      (input.targetType === "record"
        ? !RECORD_ID_PATTERN.test(input.targetId)
        : !UUID_PATTERN.test(input.targetId))
    ) {
      throw unprocessable(
        `references[${index}] must use UUID user/event IDs and a five-character Base64URL record ID.`,
        "invalid_references",
      );
    }
    if (input.targetType === "user" && input.targetId !== input.targetUserId) {
      throw unprocessable(
        `references[${index}].targetId must equal targetUserId for a user target.`,
        "invalid_references",
      );
    }
    const relation = input.relation ?? "reference";
    if (!RELATION_PATTERN.test(relation)) {
      throw unprocessable(
        `references[${index}].relation must be a 1 to 64 character relation identifier.`,
        "invalid_references",
      );
    }
    const key = `${relation}:${input.targetType}:${input.targetUserId}:${input.targetId}`;
    if (seen.has(key)) {
      throw unprocessable("references cannot contain duplicates.", "invalid_references");
    }
    seen.add(key);
    return {
      relation,
      targetType: input.targetType,
      targetUserId: input.targetUserId,
      targetId: input.targetId,
    };
  });
}
