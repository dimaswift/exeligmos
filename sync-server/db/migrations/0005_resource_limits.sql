CREATE TABLE api_rate_limit_buckets (
  bucket_hash bytea PRIMARY KEY CHECK (octet_length(bucket_hash) = 32),
  request_count integer NOT NULL CHECK (request_count > 0),
  window_started_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > window_started_at)
);

CREATE INDEX api_rate_limit_buckets_expiry_idx
  ON api_rate_limit_buckets (expires_at);

-- jsonb::text inserts spaces after separators, while the API limit is defined
-- over compact JSON. Measure an equivalent compact JSONB rendering so the
-- service and database accept the same document at the byte boundary.
CREATE FUNCTION exeligmos_jsonb_compact_octet_length(document jsonb)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
DECLARE
  document_kind text := jsonb_typeof(document);
  total_bytes bigint := 2;
  item_count bigint := 0;
  item record;
BEGIN
  IF document_kind = 'object' THEN
    FOR item IN SELECT key, value FROM jsonb_each(document) LOOP
      IF item_count > 0 THEN
        total_bytes := total_bytes + 1;
      END IF;
      total_bytes := total_bytes
        + octet_length(to_jsonb(item.key)::text)
        + 1
        + exeligmos_jsonb_compact_octet_length(item.value);
      item_count := item_count + 1;
    END LOOP;
    RETURN total_bytes;
  END IF;

  IF document_kind = 'array' THEN
    FOR item IN SELECT value FROM jsonb_array_elements(document) LOOP
      IF item_count > 0 THEN
        total_bytes := total_bytes + 1;
      END IF;
      total_bytes := total_bytes
        + exeligmos_jsonb_compact_octet_length(item.value);
      item_count := item_count + 1;
    END LOOP;
    RETURN total_bytes;
  END IF;

  RETURN octet_length(document::text);
END;
$$;

COMMENT ON FUNCTION exeligmos_jsonb_compact_octet_length(jsonb) IS
  'UTF-8 byte length of compact JSONB text, including expanded JSONB numbers.';

ALTER TABLE records
  ADD CONSTRAINT records_public_payload_size_check CHECK (
    public_payload IS NULL
    OR exeligmos_jsonb_compact_octet_length(public_payload) <= 262144
  ),
  ADD CONSTRAINT records_metadata_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(metadata) <= 32768
  ),
  ADD CONSTRAINT records_source_metadata_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(source_metadata) <= 32768
  ),
  ADD CONSTRAINT records_ciphertext_size_check CHECK (
    ciphertext IS NULL
    OR octet_length(ciphertext) <= 524288
  );

ALTER TABLE events
  ADD CONSTRAINT events_metadata_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(metadata) <= 32768
  );
