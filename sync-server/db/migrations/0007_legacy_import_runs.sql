CREATE TABLE legacy_import_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  source_checksum bytea NOT NULL CHECK (octet_length(source_checksum) = 32),
  mapping_checksum bytea NOT NULL CHECK (octet_length(mapping_checksum) = 32),
  status text NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
  manifest jsonb NOT NULL CHECK (jsonb_typeof(manifest) = 'object'),
  result jsonb CHECK (result IS NULL OR jsonb_typeof(result) = 'object'),
  failure text,
  attempt_count integer NOT NULL DEFAULT 1 CHECK (attempt_count > 0),
  started_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  last_verified_at timestamptz,
  UNIQUE (user_id, source_checksum),
  CHECK (
    (status = 'running' AND completed_at IS NULL AND failure IS NULL)
    OR (status = 'completed' AND completed_at IS NOT NULL AND failure IS NULL AND result IS NOT NULL)
    OR (status = 'failed' AND completed_at IS NULL AND failure IS NOT NULL)
  )
);

CREATE INDEX legacy_import_runs_user_started_idx
  ON legacy_import_runs (user_id, started_at DESC, id);

COMMENT ON TABLE legacy_import_runs IS
  'Audits repeatable imports from the retired folder relay and binds each source checksum to one explicit owner/device mapping.';
