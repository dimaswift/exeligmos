ALTER TABLE records
  DROP CONSTRAINT records_check2;

-- Phase 2 originally left the last live ciphertext on private rows when they
-- were soft-deleted. Scrub any such tombstones without creating a synthetic
-- revision or change-feed entry: the existing delete revision remains the
-- tombstone, while every earlier live revision keeps its original envelope.
ALTER TABLE records DISABLE TRIGGER records_revision_before_update;
ALTER TABLE records DISABLE TRIGGER records_private_ciphertext_before_update;
ALTER TABLE records DISABLE TRIGGER records_capture_revision_after_write;
ALTER TABLE records DISABLE TRIGGER records_change_after_write;

UPDATE records
SET cipher_algorithm = NULL,
    crypto_version = NULL,
    key_version = NULL,
    nonce = NULL,
    ciphertext = NULL,
    encrypted_content_type = NULL
WHERE visibility = 'private'
  AND deleted_at IS NOT NULL
  AND (
    cipher_algorithm IS NOT NULL
    OR crypto_version IS NOT NULL
    OR key_version IS NOT NULL
    OR nonce IS NOT NULL
    OR ciphertext IS NOT NULL
    OR encrypted_content_type IS NOT NULL
  );

UPDATE record_revisions AS rr
SET snapshot = rr.snapshot || jsonb_build_object(
  'cipher_algorithm', NULL,
  'crypto_version', NULL,
  'key_version', NULL,
  'nonce', NULL,
  'ciphertext', NULL,
  'encrypted_content_type', NULL
)
FROM records AS r
WHERE r.id = rr.record_id
  AND r.user_id = rr.user_id
  AND r.revision = rr.revision
  AND r.visibility = 'private'
  AND r.deleted_at IS NOT NULL;

ALTER TABLE records ENABLE TRIGGER records_revision_before_update;
ALTER TABLE records ENABLE TRIGGER records_private_ciphertext_before_update;
ALTER TABLE records ENABLE TRIGGER records_capture_revision_after_write;
ALTER TABLE records ENABLE TRIGGER records_change_after_write;

ALTER TABLE records
  ADD CONSTRAINT records_visibility_content_check
  CHECK (
    (
      visibility = 'public'
      AND event_at IS NOT NULL
      AND public_payload IS NOT NULL
      AND cipher_algorithm IS NULL
      AND crypto_version IS NULL
      AND key_version IS NULL
      AND nonce IS NULL
      AND ciphertext IS NULL
      AND encrypted_content_type IS NULL
    )
    OR
    (
      visibility = 'private'
      AND event_at IS NULL
      AND end_at IS NULL
      AND public_payload IS NULL
      AND metadata = '{}'::jsonb
      AND template_id IS NULL
      AND template_version IS NULL
      AND source_kind IS NULL
      AND source_provider IS NULL
      AND source_external_id IS NULL
      AND source_url IS NULL
      AND source_metadata = '{}'::jsonb
      AND (
        (
          deleted_at IS NULL
          AND cipher_algorithm IS NOT NULL
          AND cipher_algorithm = 'A256GCM'
          AND crypto_version IS NOT NULL
          AND crypto_version = 1
          AND key_version IS NOT NULL
          AND key_version = 1
          AND nonce IS NOT NULL
          AND octet_length(nonce) = 12
          AND ciphertext IS NOT NULL
          AND octet_length(ciphertext) >= 16
          AND encrypted_content_type IS NOT NULL
          AND encrypted_content_type = 'application/vnd.exeligmos.record+json'
        )
        OR
        (
          deleted_at IS NOT NULL
          AND cipher_algorithm IS NULL
          AND crypto_version IS NULL
          AND key_version IS NULL
          AND nonce IS NULL
          AND ciphertext IS NULL
          AND encrypted_content_type IS NULL
        )
      )
    )
  );
