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

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
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
          WHEN 'user' THEN rr.target_user_id
          WHEN 'record' THEN rr.target_record_id
          ELSE rr.target_event_id
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
         THEN (item.value->>'targetId')::uuid ELSE NULL END,
       CASE WHEN item.value->>'targetType' = 'event'
         THEN (item.value->>'targetId')::uuid ELSE NULL END
     FROM jsonb_array_elements($4::jsonb) WITH ORDINALITY AS item(value, ordinality)`,
    [sourceUserId, sourceType, sourceId, JSON.stringify(references)],
  );
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
      !UUID_PATTERN.test(input.targetId)
    ) {
      throw unprocessable(
        `references[${index}] must name a supported target type and UUID identifiers.`,
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
