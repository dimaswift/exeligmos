-- UUID record identifiers may still be present in ephemeral replay caches
-- created before the compact public-ID migration. They are deliberately not
-- backward compatible: replaying one would return an obsolete resourceId or
-- reject a freshly retried mutation that reused the client mutation ID.
DELETE FROM sync_mutation_receipts;

DELETE FROM idempotency_keys
WHERE operation_id = 'applySyncBatch';

-- Older maintenance/import runs could physically remove records without a
-- foreign key from the append-only ledgers. Such rows cannot be projected to
-- a compact public ID, so remove them. Deleting change_log rows also advances
-- sync_change_retention through its statement-level pruning trigger, causing
-- an old cursor to reconcile safely instead of observing a hole.
DELETE FROM change_log AS change
WHERE change.entity_type = 'record'
  AND NOT EXISTS (
    SELECT 1
    FROM records AS record
    WHERE record.user_id = change.user_id
      AND record.id = change.entity_id
  );

DELETE FROM public_activity AS activity
WHERE activity.resource_type = 'record'
  AND NOT EXISTS (
    SELECT 1
    FROM records AS record
    WHERE record.user_id = activity.actor_user_id
      AND record.id = activity.resource_id
  );

