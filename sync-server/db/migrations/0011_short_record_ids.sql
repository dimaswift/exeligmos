-- Record URLs and synchronization use compact public identifiers while UUIDs
-- remain the immutable storage, relationship, revision, and cryptographic IDs.

CREATE FUNCTION exeligmos_random_record_public_id()
RETURNS text
LANGUAGE sql
VOLATILE
PARALLEL UNSAFE
AS $$
  SELECT substring(
    translate(encode(uuid_send(gen_random_uuid()), 'base64'), '+/', '-_')
    FROM 1 FOR 5
  )
$$;

ALTER TABLE records
  ADD COLUMN public_id text COLLATE "C";

-- Backfilling an API alias is not a content mutation. In particular, it must
-- not increment revisions, require a fresh private ciphertext envelope, or
-- publish hundreds of synthetic sync/public-activity entries.
ALTER TABLE records DISABLE TRIGGER records_revision_before_update;
ALTER TABLE records DISABLE TRIGGER records_private_ciphertext_before_update;
ALTER TABLE records DISABLE TRIGGER records_visibility_before_update;
ALTER TABLE records DISABLE TRIGGER records_capture_revision_after_write;
ALTER TABLE records DISABLE TRIGGER records_change_after_write;
ALTER TABLE records DISABLE TRIGGER records_public_activity_after_write;

DO $$
DECLARE
  stored record;
  candidate text;
BEGIN
  FOR stored IN SELECT id FROM records ORDER BY id LOOP
    LOOP
      candidate := exeligmos_random_record_public_id();
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM records WHERE public_id = candidate
      );
    END LOOP;
    UPDATE records SET public_id = candidate WHERE id = stored.id;
  END LOOP;
END;
$$;

-- Early iOS clients duplicated their owner UUID into otherwise-public JSON
-- and source metadata. Once the compact alias exists, keep that UUID only in
-- records.id/originId and use the public alias for first-party deduplication.
UPDATE records
SET
  public_payload = public_payload - 'id',
  source_external_id = public_id
WHERE visibility = 'public'
  AND source_kind = 'client'
  AND source_provider = 'saros-harmonic-journal'
  AND public_payload ? 'id'
  AND source_external_id = public_payload->>'id';

-- Keep historical snapshots self-describing without creating new revisions.
UPDATE record_revisions AS revision
SET snapshot = revision.snapshot || jsonb_build_object(
  'public_id', record.public_id
)
FROM records AS record
WHERE record.id = revision.record_id
  AND record.user_id = revision.user_id;

ALTER TABLE records ENABLE TRIGGER records_revision_before_update;
ALTER TABLE records ENABLE TRIGGER records_private_ciphertext_before_update;
ALTER TABLE records ENABLE TRIGGER records_visibility_before_update;
ALTER TABLE records ENABLE TRIGGER records_capture_revision_after_write;
ALTER TABLE records ENABLE TRIGGER records_change_after_write;
ALTER TABLE records ENABLE TRIGGER records_public_activity_after_write;

ALTER TABLE records
  ALTER COLUMN public_id SET DEFAULT exeligmos_random_record_public_id(),
  ALTER COLUMN public_id SET NOT NULL,
  ADD CONSTRAINT records_public_id_format_check
    CHECK (public_id ~ '^[A-Za-z0-9_-]{5}$'),
  ADD CONSTRAINT records_public_id_key UNIQUE (public_id);

CREATE FUNCTION prevent_record_public_id_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.public_id IS DISTINCT FROM OLD.public_id THEN
    RAISE EXCEPTION 'record public_id is immutable'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER records_public_id_immutable_before_update
  BEFORE UPDATE OF public_id ON records
  FOR EACH ROW EXECUTE FUNCTION prevent_record_public_id_change();

COMMENT ON COLUMN records.public_id IS
  'Globally unique five-character Base64URL API identifier. records.id remains the owner-only UUID origin and storage identity.';
