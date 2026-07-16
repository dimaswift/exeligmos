-- Preserve the immutable 0006/0007 history while making hard user cleanup
-- safe for both sync pruning and completed legacy imports.

CREATE OR REPLACE FUNCTION capture_sync_change_pruning()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO sync_change_retention (
    user_id,
    entity_type,
    last_pruned_sequence,
    updated_at
  )
  SELECT
    pruned.user_id,
    pruned.entity_type,
    max(pruned.sequence),
    clock_timestamp()
  FROM pruned_changes AS pruned
  WHERE EXISTS (
    SELECT 1 FROM users WHERE users.id = pruned.user_id
  )
  GROUP BY pruned.user_id, pruned.entity_type
  ON CONFLICT (user_id, entity_type) DO UPDATE SET
    last_pruned_sequence = GREATEST(
      sync_change_retention.last_pruned_sequence,
      EXCLUDED.last_pruned_sequence
    ),
    updated_at = clock_timestamp();

  RETURN NULL;
END;
$$;

ALTER TABLE legacy_import_runs
  DROP CONSTRAINT legacy_import_runs_user_id_fkey,
  ADD CONSTRAINT legacy_import_runs_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

COMMENT ON FUNCTION capture_sync_change_pruning() IS
  'Advances retained sync cursors without recreating rows for users being cascade-deleted.';
