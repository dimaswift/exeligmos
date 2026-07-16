CREATE TABLE sync_change_retention (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entity_type text NOT NULL CHECK (
    entity_type IN ('user', 'device', 'record', 'event', 'tag', 'template', 'media')
  ),
  last_pruned_sequence bigint NOT NULL CHECK (last_pruned_sequence > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, entity_type)
);

COMMENT ON TABLE sync_change_retention IS
  'Per-user and resource-type high-water marks advanced whenever retained change rows are pruned.';

CREATE FUNCTION capture_sync_change_pruning()
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
    user_id,
    entity_type,
    max(sequence),
    clock_timestamp()
  FROM pruned_changes
  GROUP BY user_id, entity_type
  ON CONFLICT (user_id, entity_type) DO UPDATE SET
    last_pruned_sequence = GREATEST(
      sync_change_retention.last_pruned_sequence,
      EXCLUDED.last_pruned_sequence
    ),
    updated_at = clock_timestamp();

  RETURN NULL;
END;
$$;

CREATE TRIGGER change_log_capture_pruning_after_delete
  AFTER DELETE ON change_log
  REFERENCING OLD TABLE AS pruned_changes
  FOR EACH STATEMENT EXECUTE FUNCTION capture_sync_change_pruning();

CREATE TABLE sync_mutation_receipts (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_mutation_id text NOT NULL,
  request_hash bytea NOT NULL CHECK (octet_length(request_hash) = 32),
  actor_type text NOT NULL CHECK (actor_type IN ('jwt', 'api_key')),
  actor_id uuid NOT NULL,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, client_mutation_id),
  CHECK (
    client_mutation_id = btrim(client_mutation_id)
    AND char_length(client_mutation_id) BETWEEN 8 AND 128
    AND client_mutation_id ~ '^[A-Za-z0-9._:-]+$'
  ),
  CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  CHECK (expires_at > created_at)
);

CREATE INDEX sync_mutation_receipts_expiry_idx
  ON sync_mutation_receipts (expires_at);

COMMENT ON TABLE sync_mutation_receipts IS
  'Bounded replay receipts for sync clientMutationId values. NULL results exist only inside an in-flight transaction.';

-- Identity values are ordered by allocation, not by transaction commit. Take a
-- transaction-scoped per-user lock before allocating a change sequence so a
-- client can safely advance one ordered cursor without missing a late commit
-- carrying a lower sequence.
CREATE OR REPLACE FUNCTION emit_change_log()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  change_operation text;
  new_tombstone text;
  old_tombstone text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

  new_tombstone := to_jsonb(NEW) ->> TG_ARGV[1];
  old_tombstone := CASE
    WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ->> TG_ARGV[1]
    ELSE NULL
  END;
  change_operation := CASE
    WHEN new_tombstone IS NOT NULL AND old_tombstone IS NULL THEN 'delete'
    ELSE 'upsert'
  END;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('exeligmos:change:' || NEW.user_id::text, 0)
  );

  INSERT INTO change_log (
    user_id,
    entity_type,
    entity_id,
    operation,
    revision
  )
  VALUES (
    NEW.user_id,
    TG_ARGV[0],
    NEW.id,
    change_operation,
    NEW.revision
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION emit_user_change_log()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('exeligmos:change:' || NEW.id::text, 0)
  );

  INSERT INTO change_log (
    user_id,
    entity_type,
    entity_id,
    operation,
    revision
  )
  VALUES (NEW.id, 'user', NEW.id, 'upsert', NEW.revision);
  RETURN NEW;
END;
$$;
