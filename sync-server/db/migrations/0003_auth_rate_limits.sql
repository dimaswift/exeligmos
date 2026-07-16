CREATE TABLE auth_rate_limits (
  bucket_hash bytea PRIMARY KEY CHECK (octet_length(bucket_hash) = 32),
  attempts integer NOT NULL CHECK (attempts > 0),
  window_started_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CHECK (expires_at > window_started_at)
);

CREATE INDEX auth_rate_limits_expiry_idx ON auth_rate_limits (expires_at);

