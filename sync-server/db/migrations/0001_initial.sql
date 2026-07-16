CREATE EXTENSION IF NOT EXISTS vector;

CREATE FUNCTION exeligmos_text_array_is_unique(values_to_check text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT cardinality(values_to_check) = count(DISTINCT value)
  FROM unnest(values_to_check) AS value
$$;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  login text NOT NULL,
  display_name text NOT NULL,
  password_hash text NOT NULL,
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  disabled_at timestamptz,
  CHECK (
    login = btrim(login)
    AND char_length(login) BETWEEN 3 AND 64
    AND login ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'
  ),
  CHECK (display_name = btrim(display_name) AND char_length(display_name) BETWEEN 1 AND 120),
  CHECK ((status = 'active' AND disabled_at IS NULL) OR status = 'disabled')
);

CREATE UNIQUE INDEX users_login_casefold_key ON users (lower(login));

CREATE TABLE user_encryption_profiles (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  crypto_version integer NOT NULL DEFAULT 1 CHECK (crypto_version = 1),
  key_version integer NOT NULL DEFAULT 1 CHECK (key_version = 1),
  key_check bytea NOT NULL CHECK (octet_length(key_check) = 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'ios' CHECK (
    kind IN ('ios', 'macos', 'web', 'agent', 'server', 'other')
  ),
  platform text,
  app_version text,
  emoji text,
  public_key bytea,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  registered_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  UNIQUE (user_id, id),
  CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 120),
  CHECK (platform IS NULL OR char_length(platform) BETWEEN 1 AND 80),
  CHECK (app_version IS NULL OR char_length(app_version) BETWEEN 1 AND 80),
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX devices_user_active_idx
  ON devices (user_id, registered_at DESC)
  WHERE revoked_at IS NULL;

CREATE TABLE auth_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid,
  token_family_id uuid NOT NULL DEFAULT gen_random_uuid(),
  refresh_token_hash bytea NOT NULL UNIQUE,
  rotated_from_session_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  revoke_reason text,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (user_id, rotated_from_session_id)
    REFERENCES auth_sessions(user_id, id)
    ON DELETE SET NULL (rotated_from_session_id),
  CHECK (octet_length(refresh_token_hash) = 32),
  CHECK (expires_at > created_at)
);

CREATE INDEX auth_sessions_user_active_idx
  ON auth_sessions (user_id, expires_at)
  WHERE revoked_at IS NULL;
CREATE INDEX auth_sessions_family_idx ON auth_sessions (token_family_id);

CREATE TABLE api_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  name text NOT NULL,
  key_prefix text NOT NULL,
  key_hash bytea NOT NULL UNIQUE,
  scopes text[] NOT NULL,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  last_used_at timestamptz,
  revoked_at timestamptz,
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id)
    ON DELETE CASCADE,
  CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 120),
  CHECK (key_prefix ~ '^exk_[A-Za-z0-9]{4,16}$'),
  CHECK (octet_length(key_hash) = 32),
  CHECK (
    cardinality(scopes) > 0
    AND array_position(scopes, NULL) IS NULL
    AND exeligmos_text_array_is_unique(scopes)
    AND scopes <@ ARRAY[
      'records:read', 'records:write',
      'events:read', 'events:write',
      'tags:read', 'tags:write',
      'templates:read', 'templates:write',
      'media:read', 'media:write',
      'devices:read',
      'sync:read', 'sync:write'
    ]::text[]
  ),
  CHECK (expires_at IS NULL OR expires_at > created_at)
);

CREATE INDEX api_keys_user_active_idx
  ON api_keys (user_id, created_at DESC)
  WHERE revoked_at IS NULL;
CREATE INDEX api_keys_prefix_idx ON api_keys (key_prefix);

CREATE TABLE tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL,
  emoji text,
  color text,
  sort_order integer NOT NULL DEFAULT 0,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 120),
  CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$'),
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX tags_user_updated_idx ON tags (user_id, updated_at DESC, id);
CREATE INDEX tags_user_sort_idx
  ON tags (user_id, sort_order, name, id)
  WHERE deleted_at IS NULL;

CREATE TABLE templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  engine text NOT NULL DEFAULT 'mustache' CHECK (engine IN ('mustache')),
  body jsonb NOT NULL,
  variable_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  CHECK (name = btrim(name) AND char_length(name) BETWEEN 1 AND 120),
  CHECK (jsonb_typeof(body) = 'object'),
  CHECK (jsonb_typeof(variable_schema) = 'object'),
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE TABLE template_versions (
  user_id uuid NOT NULL,
  template_id uuid NOT NULL,
  version integer NOT NULL CHECK (version > 0),
  body jsonb NOT NULL,
  variable_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (template_id, version),
  UNIQUE (user_id, template_id, version),
  FOREIGN KEY (user_id, template_id)
    REFERENCES templates(user_id, id)
    ON DELETE CASCADE,
  CHECK (jsonb_typeof(body) = 'object'),
  CHECK (jsonb_typeof(variable_schema) = 'object')
);

CREATE INDEX templates_user_updated_idx
  ON templates (user_id, updated_at DESC, id)
  WHERE deleted_at IS NULL;

CREATE TABLE records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  visibility text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'private')),
  event_at timestamptz,
  end_at timestamptz,
  public_payload jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  template_id uuid,
  template_version integer,
  source_kind text,
  source_provider text,
  source_external_id text,
  source_url text,
  source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  cipher_algorithm text,
  crypto_version integer,
  key_version integer,
  nonce bytea,
  ciphertext bytea,
  encrypted_content_type text,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id),
  FOREIGN KEY (user_id, template_id, template_version)
    REFERENCES template_versions(user_id, template_id, version),
  CHECK (end_at IS NULL OR (event_at IS NOT NULL AND end_at >= event_at)),
  CHECK (public_payload IS NULL OR jsonb_typeof(public_payload) = 'object'),
  CHECK (jsonb_typeof(metadata) = 'object'),
  CHECK (jsonb_typeof(source_metadata) = 'object'),
  CHECK (
    (
      source_kind IS NULL
      AND source_provider IS NULL
      AND source_external_id IS NULL
      AND source_url IS NULL
      AND source_metadata = '{}'::jsonb
    )
    OR (
      source_kind IS NOT NULL
      AND source_kind IN ('client', 'agent', 'import', 'server')
      AND source_provider IS NOT NULL
      AND source_provider = btrim(source_provider)
      AND char_length(source_provider) BETWEEN 1 AND 64
      AND source_provider ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'
      AND (
        source_external_id IS NULL
        OR char_length(source_external_id) BETWEEN 1 AND 256
      )
    )
  ),
  CHECK (
    visibility = 'public'
    AND event_at IS NOT NULL
    AND public_payload IS NOT NULL
    AND cipher_algorithm IS NULL
    AND crypto_version IS NULL
    AND key_version IS NULL
    AND nonce IS NULL
    AND ciphertext IS NULL
    AND encrypted_content_type IS NULL
    OR
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
);

CREATE UNIQUE INDEX records_user_source_external_active_key
  ON records (user_id, source_provider, source_external_id)
  WHERE source_provider IS NOT NULL
    AND source_external_id IS NOT NULL
    AND deleted_at IS NULL;
CREATE INDEX records_user_updated_idx ON records (user_id, updated_at DESC, id);
CREATE INDEX records_public_event_idx
  ON records (event_at DESC, id)
  WHERE visibility = 'public' AND deleted_at IS NULL;
CREATE INDEX records_user_device_idx
  ON records (user_id, device_id, updated_at DESC)
  WHERE deleted_at IS NULL;

CREATE TABLE record_revisions (
  user_id uuid NOT NULL,
  record_id uuid NOT NULL,
  revision bigint NOT NULL CHECK (revision > 0),
  snapshot jsonb NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (record_id, revision),
  UNIQUE (user_id, record_id, revision),
  FOREIGN KEY (user_id, record_id)
    REFERENCES records(user_id, id)
    ON DELETE CASCADE,
  CHECK (jsonb_typeof(snapshot) = 'object')
);

CREATE TABLE record_tags (
  user_id uuid NOT NULL,
  record_id uuid NOT NULL,
  tag_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (record_id, tag_id),
  FOREIGN KEY (user_id, record_id)
    REFERENCES records(user_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (user_id, tag_id)
    REFERENCES tags(user_id, id)
    ON DELETE CASCADE
);

CREATE TABLE media_objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  visibility text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'private')),
  status text NOT NULL DEFAULT 'ready' CHECK (status IN ('ready', 'deleted')),
  file_name text NOT NULL,
  content_type text NOT NULL,
  byte_size bigint NOT NULL CHECK (byte_size > 0),
  sha256 bytea NOT NULL,
  storage_key text NOT NULL,
  cipher_algorithm text,
  crypto_version integer,
  key_version integer,
  nonce bytea,
  plaintext_content_type text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id),
  CHECK (
    file_name = btrim(file_name)
    AND char_length(file_name) BETWEEN 1 AND 255
    AND file_name !~ '[/\\]'
  ),
  CHECK (content_type = btrim(content_type) AND char_length(content_type) BETWEEN 3 AND 255),
  CHECK (octet_length(sha256) = 32),
  CHECK (storage_key = btrim(storage_key) AND char_length(storage_key) BETWEEN 1 AND 1024),
  CHECK (jsonb_typeof(metadata) = 'object'),
  CHECK (
    (status = 'ready' AND deleted_at IS NULL)
    OR (status = 'deleted' AND deleted_at IS NOT NULL)
  ),
  CHECK (
    visibility = 'public'
    AND cipher_algorithm IS NULL
    AND crypto_version IS NULL
    AND key_version IS NULL
    AND nonce IS NULL
    AND plaintext_content_type IS NULL
    OR
    visibility = 'private'
    AND metadata = '{}'::jsonb
    AND cipher_algorithm IS NOT NULL
    AND cipher_algorithm = 'A256GCM'
    AND crypto_version IS NOT NULL
    AND crypto_version = 1
    AND key_version IS NOT NULL
    AND key_version = 1
    AND nonce IS NOT NULL
    AND octet_length(nonce) = 12
    AND (
      plaintext_content_type IS NULL
      OR char_length(plaintext_content_type) BETWEEN 3 AND 255
    )
  )
);

CREATE INDEX media_user_updated_idx ON media_objects (user_id, updated_at DESC, id);
CREATE INDEX media_sha256_idx
  ON media_objects (sha256)
  WHERE status = 'ready' AND deleted_at IS NULL;

CREATE TABLE media_upload_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  requested_media_id uuid,
  media_id uuid,
  status text NOT NULL DEFAULT 'reserved' CHECK (
    status IN ('reserved', 'received', 'completed', 'aborted', 'expired')
  ),
  file_name text NOT NULL,
  content_type text NOT NULL,
  byte_size bigint NOT NULL CHECK (byte_size > 0 AND byte_size <= 5368709120),
  received_bytes bigint NOT NULL DEFAULT 0 CHECK (received_bytes >= 0),
  sha256 bytea NOT NULL,
  temporary_storage_key text,
  cipher_algorithm text,
  crypto_version integer,
  key_version integer,
  nonce bytea,
  plaintext_content_type text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  completed_at timestamptz,
  aborted_at timestamptz,
  UNIQUE (user_id, id),
  UNIQUE (media_id),
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id),
  FOREIGN KEY (user_id, media_id)
    REFERENCES media_objects(user_id, id),
  CHECK (
    file_name = btrim(file_name)
    AND char_length(file_name) BETWEEN 1 AND 255
    AND file_name !~ '[/\\]'
  ),
  CHECK (content_type = btrim(content_type) AND char_length(content_type) BETWEEN 3 AND 255),
  CHECK (received_bytes <= byte_size),
  CHECK (octet_length(sha256) = 32),
  CHECK (expires_at > created_at),
  CHECK (
    (
      cipher_algorithm IS NULL
      AND crypto_version IS NULL
      AND key_version IS NULL
      AND nonce IS NULL
      AND plaintext_content_type IS NULL
    )
    OR (
      cipher_algorithm IS NOT NULL
      AND cipher_algorithm = 'A256GCM'
      AND crypto_version IS NOT NULL
      AND crypto_version = 1
      AND key_version IS NOT NULL
      AND key_version = 1
      AND nonce IS NOT NULL
      AND octet_length(nonce) = 12
      AND requested_media_id IS NOT NULL
      AND (
        plaintext_content_type IS NULL
        OR char_length(plaintext_content_type) BETWEEN 3 AND 255
      )
    )
  ),
  CHECK (
    (status = 'reserved' AND media_id IS NULL AND completed_at IS NULL AND aborted_at IS NULL)
    OR (
      status = 'received'
      AND received_bytes = byte_size
      AND media_id IS NULL
      AND completed_at IS NULL
      AND aborted_at IS NULL
    )
    OR (
      status = 'completed'
      AND received_bytes = byte_size
      AND media_id IS NOT NULL
      AND (requested_media_id IS NULL OR requested_media_id = media_id)
      AND completed_at IS NOT NULL
      AND aborted_at IS NULL
    )
    OR (
      status IN ('aborted', 'expired')
      AND media_id IS NULL
      AND completed_at IS NULL
      AND aborted_at IS NOT NULL
    )
  )
);

CREATE INDEX media_upload_sessions_user_created_idx
  ON media_upload_sessions (user_id, created_at DESC, id);
CREATE UNIQUE INDEX media_upload_sessions_user_requested_media_key
  ON media_upload_sessions (user_id, requested_media_id)
  WHERE requested_media_id IS NOT NULL AND status IN ('reserved', 'received');
CREATE INDEX media_upload_sessions_expiry_idx
  ON media_upload_sessions (expires_at)
  WHERE status IN ('reserved', 'received');

CREATE TABLE record_media (
  user_id uuid NOT NULL,
  record_id uuid NOT NULL,
  media_id uuid NOT NULL,
  position integer NOT NULL DEFAULT 0 CHECK (position >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (record_id, media_id),
  UNIQUE (record_id, position),
  FOREIGN KEY (user_id, record_id)
    REFERENCES records(user_id, id)
    ON DELETE CASCADE,
  FOREIGN KEY (user_id, media_id)
    REFERENCES media_objects(user_id, id)
    ON DELETE RESTRICT
);

CREATE TABLE record_embeddings (
  user_id uuid NOT NULL,
  record_id uuid NOT NULL,
  record_revision bigint NOT NULL CHECK (record_revision > 0),
  model_key text NOT NULL,
  dimensions integer NOT NULL CHECK (dimensions BETWEEN 1 AND 16000),
  content_hash bytea NOT NULL,
  embedding vector NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (record_id, record_revision, model_key),
  FOREIGN KEY (user_id, record_id, record_revision)
    REFERENCES record_revisions(user_id, record_id, revision)
    ON DELETE CASCADE,
  CHECK (model_key = btrim(model_key) AND char_length(model_key) BETWEEN 1 AND 200),
  CHECK (octet_length(content_hash) = 32),
  CHECK (vector_dims(embedding) = dimensions)
);

CREATE INDEX record_embeddings_user_model_idx
  ON record_embeddings (user_id, model_key, record_revision DESC);

CREATE TABLE events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz,
  label text NOT NULL,
  type integer NOT NULL CHECK (type >= 0),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  FOREIGN KEY (user_id, device_id)
    REFERENCES devices(user_id, id),
  CHECK (ends_at IS NULL OR ends_at >= starts_at),
  CHECK (label = btrim(label) AND char_length(label) BETWEEN 1 AND 256),
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX events_user_starts_idx ON events (user_id, starts_at DESC, id);
CREATE INDEX events_user_type_starts_idx
  ON events (user_id, type, starts_at DESC, id)
  WHERE deleted_at IS NULL;
CREATE INDEX events_user_device_starts_idx
  ON events (user_id, device_id, starts_at DESC, id)
  WHERE deleted_at IS NULL;

CREATE TABLE event_revisions (
  user_id uuid NOT NULL,
  event_id uuid NOT NULL,
  revision bigint NOT NULL CHECK (revision > 0),
  snapshot jsonb NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, revision),
  UNIQUE (user_id, event_id, revision),
  FOREIGN KEY (user_id, event_id)
    REFERENCES events(user_id, id)
    ON DELETE CASCADE,
  CHECK (jsonb_typeof(snapshot) = 'object')
);

CREATE TABLE change_log (
  sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  entity_type text NOT NULL CHECK (
    entity_type IN ('user', 'device', 'record', 'event', 'tag', 'template', 'media')
  ),
  entity_id uuid NOT NULL,
  operation text NOT NULL CHECK (operation IN ('upsert', 'delete')),
  revision bigint NOT NULL CHECK (revision > 0),
  changed_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX change_log_user_cursor_idx ON change_log (user_id, sequence);

CREATE TABLE idempotency_keys (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  operation_id text NOT NULL,
  idempotency_key text NOT NULL,
  actor_type text NOT NULL CHECK (actor_type IN ('jwt', 'api_key')),
  actor_id uuid,
  request_hash bytea NOT NULL,
  response_status integer,
  response_headers jsonb,
  response_body jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, operation_id, idempotency_key),
  CHECK (operation_id = btrim(operation_id) AND char_length(operation_id) BETWEEN 1 AND 120),
  CHECK (idempotency_key = btrim(idempotency_key) AND char_length(idempotency_key) BETWEEN 8 AND 200),
  CHECK (octet_length(request_hash) = 32),
  CHECK (response_headers IS NULL OR jsonb_typeof(response_headers) = 'object'),
  CHECK (expires_at > created_at)
);

CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys (expires_at);

CREATE TABLE audit_log (
  sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  actor_type text NOT NULL CHECK (actor_type IN ('system', 'jwt', 'api_key')),
  actor_id uuid,
  action text NOT NULL,
  entity_type text,
  entity_id uuid,
  request_id text,
  source_ip inet,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (action = btrim(action) AND char_length(action) BETWEEN 1 AND 200),
  CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX audit_log_user_created_idx ON audit_log (user_id, created_at DESC);

CREATE FUNCTION set_revision_and_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW IS DISTINCT FROM OLD THEN
    NEW.revision := OLD.revision + 1;
    NEW.updated_at := clock_timestamp();
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION prevent_user_encryption_profile_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'crypto profile v1 is create-once'
    USING ERRCODE = '23514';
END;
$$;

CREATE FUNCTION prevent_record_visibility_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.visibility IS DISTINCT FROM OLD.visibility THEN
    RAISE EXCEPTION 'record visibility is immutable'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION require_fresh_private_record_ciphertext()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.visibility = 'private'
     AND NEW IS DISTINCT FROM OLD
     AND NOT (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
     AND (
       NEW.nonce IS NOT DISTINCT FROM OLD.nonce
       OR NEW.ciphertext IS NOT DISTINCT FROM OLD.ciphertext
     ) THEN
    RAISE EXCEPTION 'every private record revision requires fresh ciphertext'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION enforce_media_immutability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF ROW(
    NEW.user_id,
    NEW.device_id,
    NEW.visibility,
    NEW.file_name,
    NEW.content_type,
    NEW.byte_size,
    NEW.sha256,
    NEW.storage_key,
    NEW.cipher_algorithm,
    NEW.crypto_version,
    NEW.key_version,
    NEW.nonce,
    NEW.plaintext_content_type,
    NEW.metadata,
    NEW.completed_at
  ) IS DISTINCT FROM ROW(
    OLD.user_id,
    OLD.device_id,
    OLD.visibility,
    OLD.file_name,
    OLD.content_type,
    OLD.byte_size,
    OLD.sha256,
    OLD.storage_key,
    OLD.cipher_algorithm,
    OLD.crypto_version,
    OLD.key_version,
    OLD.nonce,
    OLD.plaintext_content_type,
    OLD.metadata,
    OLD.completed_at
  ) THEN
    RAISE EXCEPTION 'completed media objects are immutable'
      USING ERRCODE = '23514';
  END IF;

  IF OLD.status = 'deleted' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'deleted media objects cannot be restored'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.status = 'deleted'
     AND OLD.status IS DISTINCT FROM 'deleted'
     AND EXISTS (SELECT 1 FROM record_media WHERE media_id = OLD.id) THEN
    RAISE EXCEPTION 'attached media objects cannot be deleted'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER users_revision_before_update
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER user_encryption_profiles_immutable_before_update
  BEFORE UPDATE ON user_encryption_profiles
  FOR EACH ROW EXECUTE FUNCTION prevent_user_encryption_profile_update();
CREATE TRIGGER devices_revision_before_update
  BEFORE UPDATE ON devices
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER api_keys_revision_before_update
  BEFORE UPDATE ON api_keys
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER tags_revision_before_update
  BEFORE UPDATE ON tags
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER templates_revision_before_update
  BEFORE UPDATE ON templates
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER records_revision_before_update
  BEFORE UPDATE ON records
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER records_private_ciphertext_before_update
  BEFORE UPDATE ON records
  FOR EACH ROW EXECUTE FUNCTION require_fresh_private_record_ciphertext();
CREATE TRIGGER records_visibility_before_update
  BEFORE UPDATE ON records
  FOR EACH ROW EXECUTE FUNCTION prevent_record_visibility_change();
CREATE TRIGGER media_revision_before_update
  BEFORE UPDATE ON media_objects
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();
CREATE TRIGGER media_immutability_before_update
  BEFORE UPDATE ON media_objects
  FOR EACH ROW EXECUTE FUNCTION enforce_media_immutability();
CREATE TRIGGER events_revision_before_update
  BEFORE UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();

CREATE FUNCTION capture_record_revision()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

  INSERT INTO record_revisions (user_id, record_id, revision, snapshot)
  VALUES (NEW.user_id, NEW.id, NEW.revision, to_jsonb(NEW));
  RETURN NEW;
END;
$$;

CREATE TRIGGER records_capture_revision_after_write
  AFTER INSERT OR UPDATE ON records
  FOR EACH ROW EXECUTE FUNCTION capture_record_revision();

CREATE FUNCTION capture_event_revision()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

  INSERT INTO event_revisions (user_id, event_id, revision, snapshot)
  VALUES (NEW.user_id, NEW.id, NEW.revision, to_jsonb(NEW));
  RETURN NEW;
END;
$$;

CREATE TRIGGER events_capture_revision_after_write
  AFTER INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION capture_event_revision();

CREATE FUNCTION require_public_record()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  record_visibility text;
  record_deleted_at timestamptz;
BEGIN
  SELECT visibility, deleted_at
    INTO record_visibility, record_deleted_at
    FROM records
    WHERE user_id = NEW.user_id AND id = NEW.record_id;

  IF record_visibility IS DISTINCT FROM 'public' OR record_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'record % must be an active public record', NEW.record_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

CREATE FUNCTION require_matching_record_media_visibility()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  record_visibility text;
  record_deleted_at timestamptz;
  media_visibility text;
  media_status text;
  media_deleted_at timestamptz;
BEGIN
  SELECT visibility, deleted_at
    INTO record_visibility, record_deleted_at
    FROM records
    WHERE user_id = NEW.user_id AND id = NEW.record_id;

  SELECT visibility, status, deleted_at
    INTO media_visibility, media_status, media_deleted_at
    FROM media_objects
    WHERE user_id = NEW.user_id AND id = NEW.media_id;

  IF record_deleted_at IS NOT NULL
     OR media_status IS DISTINCT FROM 'ready'
     OR media_deleted_at IS NOT NULL
     OR record_visibility IS DISTINCT FROM media_visibility THEN
    RAISE EXCEPTION 'record and media must be active with matching visibility'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER record_tags_require_public
  BEFORE INSERT OR UPDATE ON record_tags
  FOR EACH ROW EXECUTE FUNCTION require_public_record();
CREATE TRIGGER record_media_require_matching_visibility
  BEFORE INSERT OR UPDATE ON record_media
  FOR EACH ROW EXECUTE FUNCTION require_matching_record_media_visibility();
CREATE TRIGGER record_embeddings_require_public
  BEFORE INSERT OR UPDATE ON record_embeddings
  FOR EACH ROW EXECUTE FUNCTION require_public_record();

CREATE FUNCTION emit_change_log()
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

CREATE FUNCTION emit_user_change_log()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

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

CREATE TRIGGER users_change_after_write
  AFTER INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION emit_user_change_log();

CREATE TRIGGER devices_change_after_write
  AFTER INSERT OR UPDATE ON devices
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('device', 'revoked_at');
CREATE TRIGGER records_change_after_write
  AFTER INSERT OR UPDATE ON records
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('record', 'deleted_at');
CREATE TRIGGER events_change_after_write
  AFTER INSERT OR UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('event', 'deleted_at');
CREATE TRIGGER tags_change_after_write
  AFTER INSERT OR UPDATE ON tags
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('tag', 'deleted_at');
CREATE TRIGGER templates_change_after_write
  AFTER INSERT OR UPDATE ON templates
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('template', 'deleted_at');
CREATE TRIGGER media_change_after_write
  AFTER INSERT OR UPDATE ON media_objects
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('media', 'deleted_at');

COMMENT ON TABLE events IS
  'Lightweight user events. This is not the legacy SQLite relay events table.';
COMMENT ON TABLE user_encryption_profiles IS
  'Client-created mnemonic key verification data. The server never receives the mnemonic or derived encryption keys.';
COMMENT ON TABLE record_embeddings IS
  'Model-versioned public-record embeddings. Add model-specific partial HNSW indexes only after dimensions are selected.';
COMMENT ON COLUMN record_embeddings.embedding IS
  'Generic pgvector value; dimensions are validated per row to avoid locking the schema to one embedding model.';
