

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

CREATE FUNCTION public.capture_event_revision() RETURNS trigger
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

CREATE FUNCTION public.capture_record_revision() RETURNS trigger
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

CREATE FUNCTION public.capture_sync_change_pruning() RETURNS trigger
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

CREATE FUNCTION public.emit_change_log() RETURNS trigger
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

CREATE FUNCTION public.emit_public_activity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_public boolean;
  new_public boolean;
  activity_operation text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.revision = OLD.revision THEN
    RETURN NEW;
  END IF;

  old_public := TG_OP = 'UPDATE'
    AND OLD.visibility = 'public'
    AND OLD.deleted_at IS NULL;
  new_public := NEW.visibility = 'public' AND NEW.deleted_at IS NULL;

  IF NOT old_public AND NOT new_public THEN
    RETURN NEW;
  END IF;

  -- This function runs from an initially-deferred constraint trigger. Normal
  -- resource statements and their row locks have therefore completed before
  -- the transaction takes the global publisher gate. Holding that gate until
  -- commit keeps identity allocation in commit order without the lock
  -- inversion possible from an immediate AFTER-row trigger.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('exeligmos:public-activity', 0)
  );

  activity_operation := CASE WHEN new_public THEN 'upsert' ELSE 'delete' END;
  INSERT INTO public_activity (
    actor_user_id, resource_type, resource_id, operation, revision
  ) VALUES (
    NEW.user_id, TG_ARGV[0], NEW.id, activity_operation, NEW.revision
  );
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.emit_public_user_activity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  activity_operation text;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status <> 'active' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.revision = OLD.revision THEN
      RETURN NEW;
    END IF;
    IF NEW.status = 'disabled' AND OLD.status = 'disabled' THEN
      RETURN NEW;
    END IF;
  END IF;

  activity_operation := CASE
    WHEN NEW.status = 'active' THEN 'upsert'
    ELSE 'delete'
  END;

  -- User lifecycle controls share the same deferred commit-order gate as
  -- record and event publications.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('exeligmos:public-activity', 0)
  );

  INSERT INTO public_activity (
    actor_user_id, resource_type, resource_id, operation, revision
  ) VALUES (
    NEW.id, 'user', NEW.id, activity_operation, NEW.revision
  );
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.emit_user_change_log() RETURNS trigger
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

CREATE FUNCTION public.enforce_media_immutability() RETURNS trigger
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

CREATE FUNCTION public.exeligmos_jsonb_compact_octet_length(document jsonb) RETURNS bigint
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    SET search_path TO 'pg_catalog', 'public'
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

CREATE FUNCTION public.exeligmos_random_record_public_id() RETURNS text
    LANGUAGE sql
    AS $$
  SELECT substring(
    translate(encode(uuid_send(gen_random_uuid()), 'base64'), '+/', '-_')
    FROM 1 FOR 5
  )
$$;

CREATE FUNCTION public.exeligmos_text_array_is_unique(values_to_check text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT
    AS $$
  SELECT cardinality(values_to_check) = count(DISTINCT value)
  FROM unnest(values_to_check) AS value
$$;

CREATE FUNCTION public.prevent_record_public_id_change() RETURNS trigger
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

CREATE FUNCTION public.prevent_record_visibility_change() RETURNS trigger
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

CREATE FUNCTION public.prevent_user_encryption_profile_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'encryption profile is create-once'
    USING ERRCODE = '23514';
END;
$$;

CREATE FUNCTION public.require_fresh_private_record_ciphertext() RETURNS trigger
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

CREATE FUNCTION public.require_matching_record_media_visibility() RETURNS trigger
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

CREATE FUNCTION public.require_public_record() RETURNS trigger
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

CREATE FUNCTION public.set_revision_and_updated_at() RETURNS trigger
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

CREATE FUNCTION public.validate_resource_reference() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  source_deleted_at timestamptz;
  source_visibility text;
  target_deleted_at timestamptz;
  target_visibility text;
  target_status text;
BEGIN
  IF NEW.source_type = 'record' THEN
    SELECT deleted_at, visibility INTO source_deleted_at, source_visibility
      FROM records
      WHERE user_id = NEW.source_user_id AND id = NEW.source_record_id;
  ELSE
    SELECT deleted_at, visibility INTO source_deleted_at, source_visibility
      FROM events
      WHERE user_id = NEW.source_user_id AND id = NEW.source_event_id;
  END IF;

  IF source_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'reference source must be active'
      USING ERRCODE = '23514';
  END IF;

  SELECT status INTO target_status FROM users WHERE id = NEW.target_user_id;
  IF target_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'reference target user must be active'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.target_type = 'user' THEN
    RETURN NEW;
  ELSIF NEW.target_type = 'record' THEN
    SELECT deleted_at, visibility INTO target_deleted_at, target_visibility
      FROM records
      WHERE user_id = NEW.target_user_id AND id = NEW.target_record_id;
  ELSE
    SELECT deleted_at, visibility INTO target_deleted_at, target_visibility
      FROM events
      WHERE user_id = NEW.target_user_id AND id = NEW.target_event_id;
  END IF;

  IF target_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'reference target must be active'
      USING ERRCODE = '23514';
  END IF;

  IF (NEW.target_user_id <> NEW.source_user_id OR source_visibility = 'public')
     AND target_visibility IS DISTINCT FROM 'public' THEN
    RAISE EXCEPTION 'cross-user and public-source reference targets must be public'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

SET default_tablespace = '';

SET default_table_access_method = heap;

CREATE TABLE public.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    name text NOT NULL,
    key_prefix text NOT NULL,
    key_hash bytea NOT NULL,
    scopes text[] NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    last_used_at timestamp with time zone,
    revoked_at timestamp with time zone,
    CONSTRAINT api_keys_check CHECK (((expires_at IS NULL) OR (expires_at > created_at))),
    CONSTRAINT api_keys_key_hash_check CHECK ((octet_length(key_hash) = 32)),
    CONSTRAINT api_keys_key_prefix_check CHECK ((key_prefix ~ '^exk_[A-Za-z0-9]{4,16}$'::text)),
    CONSTRAINT api_keys_name_check CHECK (((name = btrim(name)) AND ((char_length(name) >= 1) AND (char_length(name) <= 120)))),
    CONSTRAINT api_keys_revision_check CHECK ((revision > 0)),
    CONSTRAINT api_keys_scopes_check CHECK (((cardinality(scopes) > 0) AND (array_position(scopes, NULL::text) IS NULL) AND public.exeligmos_text_array_is_unique(scopes) AND (scopes <@ ARRAY['records:read'::text, 'records:write'::text, 'events:read'::text, 'events:write'::text, 'tags:read'::text, 'tags:write'::text, 'templates:read'::text, 'templates:write'::text, 'media:read'::text, 'media:write'::text, 'jobs:read'::text, 'jobs:write'::text, 'devices:read'::text, 'subscriptions:read'::text, 'subscriptions:write'::text, 'sync:read'::text, 'sync:write'::text])))
);

CREATE TABLE public.api_rate_limit_buckets (
    bucket_hash bytea NOT NULL,
    request_count integer NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT api_rate_limit_buckets_bucket_hash_check CHECK ((octet_length(bucket_hash) = 32)),
    CONSTRAINT api_rate_limit_buckets_check CHECK ((expires_at > window_started_at)),
    CONSTRAINT api_rate_limit_buckets_request_count_check CHECK ((request_count > 0))
);

CREATE TABLE public.audit_log (
    sequence bigint NOT NULL,
    user_id uuid,
    actor_type text NOT NULL,
    actor_id uuid,
    action text NOT NULL,
    entity_type text,
    entity_id uuid,
    request_id text,
    source_ip inet,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_log_action_check CHECK (((action = btrim(action)) AND ((char_length(action) >= 1) AND (char_length(action) <= 200)))),
    CONSTRAINT audit_log_actor_type_check CHECK ((actor_type = ANY (ARRAY['system'::text, 'jwt'::text, 'api_key'::text]))),
    CONSTRAINT audit_log_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text))
);

ALTER TABLE public.audit_log ALTER COLUMN sequence ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.auth_rate_limits (
    bucket_hash bytea NOT NULL,
    attempts integer NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT auth_rate_limits_attempts_check CHECK ((attempts > 0)),
    CONSTRAINT auth_rate_limits_bucket_hash_check CHECK ((octet_length(bucket_hash) = 32)),
    CONSTRAINT auth_rate_limits_check CHECK ((expires_at > window_started_at))
);

CREATE TABLE public.auth_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid,
    token_family_id uuid DEFAULT gen_random_uuid() NOT NULL,
    refresh_token_hash bytea NOT NULL,
    rotated_from_session_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    revoke_reason text,
    CONSTRAINT auth_sessions_check CHECK ((expires_at > created_at)),
    CONSTRAINT auth_sessions_refresh_token_hash_check CHECK ((octet_length(refresh_token_hash) = 32))
);

CREATE TABLE public.change_log (
    sequence bigint NOT NULL,
    user_id uuid NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    operation text NOT NULL,
    revision bigint NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT change_log_entity_type_check CHECK ((entity_type = ANY (ARRAY['user'::text, 'device'::text, 'record'::text, 'event'::text, 'tag'::text, 'template'::text, 'media'::text, 'subscription'::text]))),
    CONSTRAINT change_log_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT change_log_operation_check CHECK ((operation = ANY (ARRAY['upsert'::text, 'delete'::text]))),
    CONSTRAINT change_log_revision_check CHECK ((revision > 0))
);

ALTER TABLE public.change_log ALTER COLUMN sequence ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.change_log_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'ios'::text NOT NULL,
    platform text,
    app_version text,
    emoji text,
    public_key bytea,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    registered_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone,
    revoked_at timestamp with time zone,
    CONSTRAINT devices_app_version_check CHECK (((app_version IS NULL) OR ((char_length(app_version) >= 1) AND (char_length(app_version) <= 80)))),
    CONSTRAINT devices_kind_check CHECK ((kind = ANY (ARRAY['ios'::text, 'macos'::text, 'web'::text, 'agent'::text, 'server'::text, 'other'::text]))),
    CONSTRAINT devices_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT devices_name_check CHECK (((name = btrim(name)) AND ((char_length(name) >= 1) AND (char_length(name) <= 120)))),
    CONSTRAINT devices_platform_check CHECK (((platform IS NULL) OR ((char_length(platform) >= 1) AND (char_length(platform) <= 80)))),
    CONSTRAINT devices_revision_check CHECK ((revision > 0))
);

CREATE TABLE public.event_revisions (
    user_id uuid NOT NULL,
    event_id uuid NOT NULL,
    revision bigint NOT NULL,
    snapshot jsonb NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT event_revisions_revision_check CHECK ((revision > 0)),
    CONSTRAINT event_revisions_snapshot_check CHECK ((jsonb_typeof(snapshot) = 'object'::text))
);

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone,
    label text NOT NULL,
    type integer NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    visibility text DEFAULT 'public'::text NOT NULL,
    CONSTRAINT events_check CHECK (((ends_at IS NULL) OR (ends_at >= starts_at))),
    CONSTRAINT events_label_check CHECK (((label = btrim(label)) AND ((char_length(label) >= 1) AND (char_length(label) <= 256)))),
    CONSTRAINT events_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT events_metadata_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(metadata) <= 32768)),
    CONSTRAINT events_revision_check CHECK ((revision > 0)),
    CONSTRAINT events_type_check CHECK ((type >= 0)),
    CONSTRAINT events_visibility_check CHECK ((visibility = ANY (ARRAY['public'::text, 'private'::text])))
);

CREATE TABLE public.ingestion_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    source jsonb NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    total_items integer DEFAULT 0 NOT NULL,
    processed_items integer DEFAULT 0 NOT NULL,
    failed_items integer DEFAULT 0 NOT NULL,
    total_records integer DEFAULT 0 NOT NULL,
    processed_records integer DEFAULT 0 NOT NULL,
    failed_records integer DEFAULT 0 NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    CONSTRAINT ingestion_jobs_config_check CHECK ((jsonb_typeof(config) = 'object'::text)),
    CONSTRAINT ingestion_jobs_config_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(config) <= 32768)),
    CONSTRAINT ingestion_jobs_counter_check CHECK (((total_items >= 0) AND (processed_items >= 0) AND (failed_items >= 0) AND ((processed_items + failed_items) <= total_items))),
    CONSTRAINT ingestion_jobs_record_counter_check CHECK (((total_records >= 0) AND (processed_records >= 0) AND (failed_records >= 0) AND (processed_records <= total_records) AND (failed_records <= total_records))),
    CONSTRAINT ingestion_jobs_revision_check CHECK ((revision > 0)),
    CONSTRAINT ingestion_jobs_source_check CHECK ((jsonb_typeof(source) = 'object'::text)),
    CONSTRAINT ingestion_jobs_source_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(source) <= 32768)),
    CONSTRAINT ingestion_jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'completed'::text, 'failed'::text])))
);

CREATE TABLE public.ingestion_job_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    job_id uuid NOT NULL,
    ordinal integer NOT NULL,
    source_key text NOT NULL COLLATE pg_catalog."C",
    group_key text NOT NULL COLLATE pg_catalog."C",
    relative_path text NOT NULL,
    kind text NOT NULL,
    captured_at timestamp with time zone NOT NULL,
    byte_length bigint NOT NULL,
    content_sha256 bytea NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    stage text DEFAULT 'queued'::text NOT NULL,
    output_mode text,
    upload_id uuid,
    media_id uuid,
    record_id uuid,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ingestion_job_items_byte_length_check CHECK (((byte_length > 0) AND (byte_length <= '5368709120'::bigint))),
    CONSTRAINT ingestion_job_items_content_sha256_check CHECK ((octet_length(content_sha256) = 32)),
    CONSTRAINT ingestion_job_items_error_check CHECK (((error IS NULL) OR ((error = btrim(error)) AND (char_length(error) >= 1) AND (char_length(error) <= 4000)))),
    CONSTRAINT ingestion_job_items_group_key_check CHECK ((group_key ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT ingestion_job_items_kind_check CHECK ((kind = ANY (ARRAY['photo'::text, 'video'::text, 'audio'::text]))),
    CONSTRAINT ingestion_job_items_lifecycle_check CHECK ((((status = 'queued'::text) AND (error IS NULL)) OR ((status = 'processing'::text) AND (error IS NULL)) OR ((status = 'completed'::text) AND (media_id IS NOT NULL) AND (record_id IS NOT NULL) AND (error IS NULL)) OR ((status = 'failed'::text) AND (error IS NOT NULL)))),
    CONSTRAINT ingestion_job_items_ordinal_check CHECK ((ordinal >= 0)),
    CONSTRAINT ingestion_job_items_output_mode_check CHECK (((output_mode IS NULL) OR ((output_mode = btrim(output_mode)) AND (char_length(output_mode) >= 1) AND (char_length(output_mode) <= 64) AND (output_mode ~ '^[a-z][a-z0-9_-]*$'::text)))),
    CONSTRAINT ingestion_job_items_relative_path_check CHECK (((relative_path = btrim(relative_path)) AND (char_length(relative_path) >= 1) AND (char_length(relative_path) <= 1024) AND (relative_path !~ '(^/|\\\\|(^|/)\\.\\.?(/|$)|//)'::text))),
    CONSTRAINT ingestion_job_items_source_key_check CHECK ((source_key ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT ingestion_job_items_stage_check CHECK (((stage = btrim(stage)) AND (char_length(stage) >= 1) AND (char_length(stage) <= 64) AND (stage ~ '^[a-z][a-z0-9_-]*$'::text))),
    CONSTRAINT ingestion_job_items_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'completed'::text, 'failed'::text])))
);

CREATE TABLE public.worker_dream_attempts (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    record_id uuid NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT worker_dream_attempts_attempts_check CHECK ((attempts > 0))
);

CREATE TABLE public.worker_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    level text NOT NULL,
    message text NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT worker_logs_context_check CHECK ((jsonb_typeof(context) = 'object'::text)),
    CONSTRAINT worker_logs_context_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(context) <= 32768)),
    CONSTRAINT worker_logs_level_check CHECK ((level = ANY (ARRAY['debug'::text, 'info'::text, 'warn'::text, 'error'::text]))),
    CONSTRAINT worker_logs_message_check CHECK (((message = btrim(message)) AND (char_length(message) >= 1) AND (char_length(message) <= 4000)))
);

CREATE TABLE public.idempotency_keys (
    user_id uuid NOT NULL,
    operation_id text NOT NULL,
    idempotency_key text NOT NULL,
    actor_type text NOT NULL,
    actor_id uuid,
    request_hash bytea NOT NULL,
    response_status integer,
    response_headers jsonb,
    response_body jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT idempotency_keys_actor_type_check CHECK ((actor_type = ANY (ARRAY['jwt'::text, 'api_key'::text]))),
    CONSTRAINT idempotency_keys_check CHECK ((expires_at > created_at)),
    CONSTRAINT idempotency_keys_idempotency_key_check CHECK (((idempotency_key = btrim(idempotency_key)) AND ((char_length(idempotency_key) >= 8) AND (char_length(idempotency_key) <= 255)))),
    CONSTRAINT idempotency_keys_operation_id_check CHECK (((operation_id = btrim(operation_id)) AND ((char_length(operation_id) >= 1) AND (char_length(operation_id) <= 120)))),
    CONSTRAINT idempotency_keys_request_hash_check CHECK ((octet_length(request_hash) = 32)),
    CONSTRAINT idempotency_keys_response_headers_check CHECK (((response_headers IS NULL) OR (jsonb_typeof(response_headers) = 'object'::text)))
);

CREATE TABLE public.media_objects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    visibility text DEFAULT 'public'::text NOT NULL,
    status text DEFAULT 'ready'::text NOT NULL,
    file_name text NOT NULL,
    content_type text NOT NULL,
    byte_size bigint NOT NULL,
    sha256 bytea NOT NULL,
    storage_key text NOT NULL,
    cipher_algorithm text,
    nonce bytea,
    plaintext_content_type text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT media_objects_byte_size_check CHECK ((byte_size > 0)),
    CONSTRAINT media_objects_check CHECK ((((status = 'ready'::text) AND (deleted_at IS NULL)) OR ((status = 'deleted'::text) AND (deleted_at IS NOT NULL)))),
    CONSTRAINT media_objects_check1 CHECK ((((visibility = 'public'::text) AND (cipher_algorithm IS NULL) AND (nonce IS NULL) AND (plaintext_content_type IS NULL)) OR ((visibility = 'private'::text) AND (metadata = '{}'::jsonb) AND (cipher_algorithm = 'A256GCM'::text) AND (nonce IS NOT NULL) AND (octet_length(nonce) = 12) AND ((plaintext_content_type IS NULL) OR ((char_length(plaintext_content_type) >= 3) AND (char_length(plaintext_content_type) <= 255)))))),
    CONSTRAINT media_objects_content_type_check CHECK (((content_type = btrim(content_type)) AND ((char_length(content_type) >= 3) AND (char_length(content_type) <= 255)))),
    CONSTRAINT media_objects_content_type_syntax_check CHECK ((content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'::text)),
    CONSTRAINT media_objects_file_name_check CHECK (((file_name = btrim(file_name)) AND ((char_length(file_name) >= 1) AND (char_length(file_name) <= 255)) AND (file_name !~ '[/\\]'::text))),
    CONSTRAINT media_objects_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT media_objects_plaintext_content_type_syntax_check CHECK (((plaintext_content_type IS NULL) OR (plaintext_content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'::text))),
    CONSTRAINT media_objects_revision_check CHECK ((revision > 0)),
    CONSTRAINT media_objects_sha256_check CHECK ((octet_length(sha256) = 32)),
    CONSTRAINT media_objects_status_check CHECK ((status = ANY (ARRAY['ready'::text, 'deleted'::text]))),
    CONSTRAINT media_objects_storage_key_check CHECK (((storage_key = btrim(storage_key)) AND ((char_length(storage_key) >= 1) AND (char_length(storage_key) <= 1024)))),
    CONSTRAINT media_objects_visibility_check CHECK ((visibility = ANY (ARRAY['public'::text, 'private'::text])))
);

CREATE TABLE public.media_upload_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    requested_media_id uuid,
    media_id uuid,
    status text DEFAULT 'reserved'::text NOT NULL,
    file_name text NOT NULL,
    content_type text NOT NULL,
    byte_size bigint NOT NULL,
    received_bytes bigint DEFAULT 0 NOT NULL,
    sha256 bytea NOT NULL,
    temporary_storage_key text,
    cipher_algorithm text,
    nonce bytea,
    plaintext_content_type text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    completed_at timestamp with time zone,
    aborted_at timestamp with time zone,
    CONSTRAINT media_upload_sessions_byte_size_check CHECK (((byte_size > 0) AND (byte_size <= '5368709120'::bigint))),
    CONSTRAINT media_upload_sessions_check CHECK ((received_bytes <= byte_size)),
    CONSTRAINT media_upload_sessions_check1 CHECK ((expires_at > created_at)),
    CONSTRAINT media_upload_sessions_check2 CHECK ((((cipher_algorithm IS NULL) AND (nonce IS NULL) AND (plaintext_content_type IS NULL)) OR ((cipher_algorithm = 'A256GCM'::text) AND (nonce IS NOT NULL) AND (octet_length(nonce) = 12) AND (requested_media_id IS NOT NULL) AND ((plaintext_content_type IS NULL) OR ((char_length(plaintext_content_type) >= 3) AND (char_length(plaintext_content_type) <= 255)))))),
    CONSTRAINT media_upload_sessions_check3 CHECK ((((status = 'reserved'::text) AND (media_id IS NULL) AND (completed_at IS NULL) AND (aborted_at IS NULL)) OR ((status = 'received'::text) AND (received_bytes = byte_size) AND (media_id IS NULL) AND (completed_at IS NULL) AND (aborted_at IS NULL)) OR ((status = 'completed'::text) AND (received_bytes = byte_size) AND (media_id IS NOT NULL) AND ((requested_media_id IS NULL) OR (requested_media_id = media_id)) AND (completed_at IS NOT NULL) AND (aborted_at IS NULL)) OR ((status = ANY (ARRAY['aborted'::text, 'expired'::text])) AND (media_id IS NULL) AND (completed_at IS NULL) AND (aborted_at IS NOT NULL)))),
    CONSTRAINT media_upload_sessions_content_type_check CHECK (((content_type = btrim(content_type)) AND ((char_length(content_type) >= 3) AND (char_length(content_type) <= 255)))),
    CONSTRAINT media_upload_sessions_content_type_syntax_check CHECK ((content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'::text)),
    CONSTRAINT media_upload_sessions_file_name_check CHECK (((file_name = btrim(file_name)) AND ((char_length(file_name) >= 1) AND (char_length(file_name) <= 255)) AND (file_name !~ '[/\\]'::text))),
    CONSTRAINT media_upload_sessions_plaintext_content_type_syntax_check CHECK (((plaintext_content_type IS NULL) OR (plaintext_content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'::text))),
    CONSTRAINT media_upload_sessions_received_bytes_check CHECK ((received_bytes >= 0)),
    CONSTRAINT media_upload_sessions_sha256_check CHECK ((octet_length(sha256) = 32)),
    CONSTRAINT media_upload_sessions_status_check CHECK ((status = ANY (ARRAY['reserved'::text, 'received'::text, 'completed'::text, 'aborted'::text, 'expired'::text])))
);

CREATE TABLE public.public_activity (
    sequence bigint NOT NULL,
    actor_user_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    operation text NOT NULL,
    revision bigint NOT NULL,
    published_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT public_activity_check CHECK (((resource_type <> 'user'::text) OR (resource_id = actor_user_id))),
    CONSTRAINT public_activity_operation_check CHECK ((operation = ANY (ARRAY['upsert'::text, 'delete'::text]))),
    CONSTRAINT public_activity_resource_type_check CHECK ((resource_type = ANY (ARRAY['user'::text, 'record'::text, 'event'::text]))),
    CONSTRAINT public_activity_revision_check CHECK ((revision > 0))
);

ALTER TABLE public.public_activity ALTER COLUMN sequence ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.public_activity_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE public.record_embeddings (
    user_id uuid NOT NULL,
    record_id uuid NOT NULL,
    record_revision bigint NOT NULL,
    model_key text NOT NULL,
    dimensions integer NOT NULL,
    content_hash bytea NOT NULL,
    embedding public.vector NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT record_embeddings_check CHECK ((public.vector_dims(embedding) = dimensions)),
    CONSTRAINT record_embeddings_content_hash_check CHECK ((octet_length(content_hash) = 32)),
    CONSTRAINT record_embeddings_dimensions_check CHECK (((dimensions >= 1) AND (dimensions <= 16000))),
    CONSTRAINT record_embeddings_model_key_check CHECK (((model_key = btrim(model_key)) AND ((char_length(model_key) >= 1) AND (char_length(model_key) <= 200)))),
    CONSTRAINT record_embeddings_record_revision_check CHECK ((record_revision > 0))
);

CREATE TABLE public.record_media (
    user_id uuid NOT NULL,
    record_id uuid NOT NULL,
    media_id uuid NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT record_media_position_check CHECK (("position" >= 0))
);

CREATE TABLE public.record_revisions (
    user_id uuid NOT NULL,
    record_id uuid NOT NULL,
    revision bigint NOT NULL,
    snapshot jsonb NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT record_revisions_revision_check CHECK ((revision > 0)),
    CONSTRAINT record_revisions_snapshot_check CHECK ((jsonb_typeof(snapshot) = 'object'::text))
);

CREATE TABLE public.record_tags (
    user_id uuid NOT NULL,
    record_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    visibility text DEFAULT 'public'::text NOT NULL,
    event_at timestamp with time zone,
    end_at timestamp with time zone,
    public_payload jsonb,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    template_id uuid,
    source_kind text,
    source_provider text,
    source_external_id text,
    source_url text,
    source_metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    cipher_algorithm text,
    nonce bytea,
    ciphertext bytea,
    encrypted_content_type text,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    public_id text DEFAULT public.exeligmos_random_record_public_id() NOT NULL COLLATE pg_catalog."C",
    CONSTRAINT records_check CHECK (((end_at IS NULL) OR ((event_at IS NOT NULL) AND (end_at >= event_at)))),
    CONSTRAINT records_check1 CHECK ((((source_kind IS NULL) AND (source_provider IS NULL) AND (source_external_id IS NULL) AND (source_url IS NULL) AND (source_metadata = '{}'::jsonb)) OR ((source_kind IS NOT NULL) AND (source_kind = ANY (ARRAY['client'::text, 'agent'::text, 'server'::text])) AND (source_provider IS NOT NULL) AND (source_provider = btrim(source_provider)) AND ((char_length(source_provider) >= 1) AND (char_length(source_provider) <= 64)) AND (source_provider ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'::text) AND ((source_external_id IS NULL) OR ((char_length(source_external_id) >= 1) AND (char_length(source_external_id) <= 256)))))),
    CONSTRAINT records_ciphertext_size_check CHECK (((ciphertext IS NULL) OR (octet_length(ciphertext) <= 524288))),
    CONSTRAINT records_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT records_metadata_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(metadata) <= 32768)),
    CONSTRAINT records_public_id_format_check CHECK ((public_id ~ '^[A-Za-z0-9_-]{5}$'::text)),
    CONSTRAINT records_public_payload_check CHECK (((public_payload IS NULL) OR (jsonb_typeof(public_payload) = 'object'::text))),
    CONSTRAINT records_public_payload_size_check CHECK (((public_payload IS NULL) OR (public.exeligmos_jsonb_compact_octet_length(public_payload) <= 262144))),
    CONSTRAINT records_revision_check CHECK ((revision > 0)),
    CONSTRAINT records_source_metadata_check CHECK ((jsonb_typeof(source_metadata) = 'object'::text)),
    CONSTRAINT records_source_metadata_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(source_metadata) <= 32768)),
    CONSTRAINT records_visibility_check CHECK ((visibility = ANY (ARRAY['public'::text, 'private'::text]))),
    CONSTRAINT records_visibility_content_check CHECK ((((visibility = 'public'::text) AND (event_at IS NOT NULL) AND (public_payload IS NOT NULL) AND (cipher_algorithm IS NULL) AND (nonce IS NULL) AND (ciphertext IS NULL) AND (encrypted_content_type IS NULL)) OR ((visibility = 'private'::text) AND (event_at IS NULL) AND (end_at IS NULL) AND (public_payload IS NULL) AND (metadata = '{}'::jsonb) AND (template_id IS NULL) AND (source_kind IS NULL) AND (source_provider IS NULL) AND (source_external_id IS NULL) AND (source_url IS NULL) AND (source_metadata = '{}'::jsonb) AND (((deleted_at IS NULL) AND (cipher_algorithm = 'A256GCM'::text) AND (nonce IS NOT NULL) AND (octet_length(nonce) = 12) AND (ciphertext IS NOT NULL) AND (octet_length(ciphertext) >= 16) AND (encrypted_content_type = 'application/vnd.exeligmos.record+json'::text)) OR ((deleted_at IS NOT NULL) AND (cipher_algorithm IS NULL) AND (nonce IS NULL) AND (ciphertext IS NULL) AND (encrypted_content_type IS NULL))))))
);

CREATE TABLE public.resource_references (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_user_id uuid NOT NULL,
    source_type text NOT NULL,
    source_record_id uuid,
    source_event_id uuid,
    "position" integer NOT NULL,
    relation text DEFAULT 'reference'::text NOT NULL,
    target_type text NOT NULL,
    target_user_id uuid NOT NULL,
    target_record_id uuid,
    target_event_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT resource_references_check CHECK ((((source_type = 'record'::text) AND (source_record_id IS NOT NULL) AND (source_event_id IS NULL)) OR ((source_type = 'event'::text) AND (source_record_id IS NULL) AND (source_event_id IS NOT NULL)))),
    CONSTRAINT resource_references_check1 CHECK ((((target_type = 'user'::text) AND (target_record_id IS NULL) AND (target_event_id IS NULL)) OR ((target_type = 'record'::text) AND (target_record_id IS NOT NULL) AND (target_event_id IS NULL)) OR ((target_type = 'event'::text) AND (target_record_id IS NULL) AND (target_event_id IS NOT NULL)))),
    CONSTRAINT resource_references_position_check CHECK ((("position" >= 0) AND ("position" < 200))),
    CONSTRAINT resource_references_relation_check CHECK (((relation = btrim(relation)) AND (relation ~ '^[A-Za-z][A-Za-z0-9._:-]{0,63}$'::text))),
    CONSTRAINT resource_references_source_type_check CHECK ((source_type = ANY (ARRAY['record'::text, 'event'::text]))),
    CONSTRAINT resource_references_target_type_check CHECK ((target_type = ANY (ARRAY['user'::text, 'record'::text, 'event'::text])))
);

CREATE TABLE public.schema_migrations (
    id text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT schema_migrations_checksum_check CHECK ((checksum ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT schema_migrations_id_check CHECK ((id ~ '^[0-9]{4}_[a-z0-9_]+[.]sql$'::text))
);

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    target_user_id uuid NOT NULL,
    include_records boolean DEFAULT true NOT NULL,
    include_events boolean DEFAULT true NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT subscriptions_check CHECK ((user_id <> target_user_id)),
    CONSTRAINT subscriptions_check1 CHECK ((include_records OR include_events)),
    CONSTRAINT subscriptions_revision_check CHECK ((revision > 0))
);

CREATE TABLE public.sync_change_retention (
    user_id uuid NOT NULL,
    entity_type text NOT NULL,
    last_pruned_sequence bigint NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sync_change_retention_entity_type_check CHECK ((entity_type = ANY (ARRAY['user'::text, 'device'::text, 'record'::text, 'event'::text, 'tag'::text, 'template'::text, 'media'::text, 'subscription'::text]))),
    CONSTRAINT sync_change_retention_last_pruned_sequence_check CHECK ((last_pruned_sequence > 0))
);

CREATE TABLE public.sync_mutation_receipts (
    user_id uuid NOT NULL,
    client_mutation_id text NOT NULL,
    request_hash bytea NOT NULL,
    actor_type text NOT NULL,
    actor_id uuid NOT NULL,
    result jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT sync_mutation_receipts_actor_type_check CHECK ((actor_type = ANY (ARRAY['jwt'::text, 'api_key'::text]))),
    CONSTRAINT sync_mutation_receipts_check CHECK ((expires_at > created_at)),
    CONSTRAINT sync_mutation_receipts_client_mutation_id_check CHECK (((client_mutation_id = btrim(client_mutation_id)) AND ((char_length(client_mutation_id) >= 8) AND (char_length(client_mutation_id) <= 128)) AND (client_mutation_id ~ '^[A-Za-z0-9._:-]+$'::text))),
    CONSTRAINT sync_mutation_receipts_request_hash_check CHECK ((octet_length(request_hash) = 32)),
    CONSTRAINT sync_mutation_receipts_result_check CHECK (((result IS NULL) OR (jsonb_typeof(result) = 'object'::text)))
);

CREATE TABLE public.tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    emoji text,
    color text,
    sort_order integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    CONSTRAINT tags_color_check CHECK (((color IS NULL) OR (color ~ '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$'::text))),
    CONSTRAINT tags_emoji_length_check CHECK (((emoji IS NULL) OR (char_length(emoji) <= 32))),
    CONSTRAINT tags_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT tags_metadata_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(metadata) <= 32768)),
    CONSTRAINT tags_name_check CHECK (((name = btrim(name)) AND ((char_length(name) >= 1) AND (char_length(name) <= 120)))),
    CONSTRAINT tags_revision_check CHECK ((revision > 0))
);

CREATE TABLE public.templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    engine text DEFAULT 'mustache'::text NOT NULL,
    body jsonb NOT NULL,
    variable_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    retired_at timestamp with time zone,
    deleted_at timestamp with time zone,
    CONSTRAINT templates_body_check CHECK ((jsonb_typeof(body) = 'object'::text)),
    CONSTRAINT templates_body_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(body) <= 262144)),
    CONSTRAINT templates_description_length_check CHECK (((description IS NULL) OR (char_length(description) <= 2000))),
    CONSTRAINT templates_engine_check CHECK ((engine = 'mustache'::text)),
    CONSTRAINT templates_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT templates_metadata_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(metadata) <= 32768)),
    CONSTRAINT templates_name_check CHECK (((name = btrim(name)) AND ((char_length(name) >= 1) AND (char_length(name) <= 120)))),
    CONSTRAINT templates_nonempty_documents_check CHECK (((body <> '{}'::jsonb) AND (variable_schema <> '{}'::jsonb))),
    CONSTRAINT templates_revision_check CHECK ((revision > 0)),
    CONSTRAINT templates_variable_schema_check CHECK ((jsonb_typeof(variable_schema) = 'object'::text)),
    CONSTRAINT templates_variable_schema_size_check CHECK ((public.exeligmos_jsonb_compact_octet_length(variable_schema) <= 262144))
);

CREATE TABLE public.user_encryption_profiles (
    user_id uuid NOT NULL,
    key_check bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_encryption_profiles_key_check_check CHECK ((octet_length(key_check) = 32))
);

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    login text NOT NULL,
    display_name text NOT NULL,
    password_hash text NOT NULL,
    role text DEFAULT 'user'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled_at timestamp with time zone,
    saros_anchor integer DEFAULT 141 NOT NULL,
    CONSTRAINT users_check CHECK ((((status = 'active'::text) AND (disabled_at IS NULL)) OR (status = 'disabled'::text))),
    CONSTRAINT users_display_name_check CHECK (((display_name = btrim(display_name)) AND ((char_length(display_name) >= 1) AND (char_length(display_name) <= 120)))),
    CONSTRAINT users_login_check CHECK (((login = btrim(login)) AND ((char_length(login) >= 3) AND (char_length(login) <= 64)) AND (login ~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'::text))),
    CONSTRAINT users_revision_check CHECK ((revision > 0)),
    CONSTRAINT users_role_check CHECK ((role = ANY (ARRAY['user'::text, 'admin'::text]))),
    CONSTRAINT users_saros_anchor_check CHECK (((saros_anchor >= 1) AND (saros_anchor <= 180))),
    CONSTRAINT users_status_check CHECK ((status = ANY (ARRAY['active'::text, 'disabled'::text])))
);

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.api_rate_limit_buckets
    ADD CONSTRAINT api_rate_limit_buckets_pkey PRIMARY KEY (bucket_hash);

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (sequence);

ALTER TABLE ONLY public.auth_rate_limits
    ADD CONSTRAINT auth_rate_limits_pkey PRIMARY KEY (bucket_hash);

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_refresh_token_hash_key UNIQUE (refresh_token_hash);

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.change_log
    ADD CONSTRAINT change_log_pkey PRIMARY KEY (sequence);

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.event_revisions
    ADD CONSTRAINT event_revisions_pkey PRIMARY KEY (event_id, revision);

ALTER TABLE ONLY public.event_revisions
    ADD CONSTRAINT event_revisions_user_id_event_id_revision_key UNIQUE (user_id, event_id, revision);

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.ingestion_jobs
    ADD CONSTRAINT ingestion_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ingestion_jobs
    ADD CONSTRAINT ingestion_jobs_user_id_device_id_id_key UNIQUE (user_id, device_id, id);

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_job_id_ordinal_key UNIQUE (job_id, ordinal);

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_user_device_source_key UNIQUE (user_id, device_id, source_key);

ALTER TABLE ONLY public.worker_dream_attempts
    ADD CONSTRAINT worker_dream_attempts_pkey PRIMARY KEY (user_id, device_id, record_id);

ALTER TABLE ONLY public.worker_logs
    ADD CONSTRAINT worker_logs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (user_id, operation_id, idempotency_key);

ALTER TABLE ONLY public.media_objects
    ADD CONSTRAINT media_objects_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.media_objects
    ADD CONSTRAINT media_objects_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_media_id_key UNIQUE (media_id);

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.public_activity
    ADD CONSTRAINT public_activity_pkey PRIMARY KEY (sequence);

ALTER TABLE ONLY public.record_embeddings
    ADD CONSTRAINT record_embeddings_pkey PRIMARY KEY (record_id, record_revision, model_key);

ALTER TABLE ONLY public.record_media
    ADD CONSTRAINT record_media_pkey PRIMARY KEY (record_id, media_id);

ALTER TABLE ONLY public.record_media
    ADD CONSTRAINT record_media_record_id_position_key UNIQUE (record_id, "position");

ALTER TABLE ONLY public.record_revisions
    ADD CONSTRAINT record_revisions_pkey PRIMARY KEY (record_id, revision);

ALTER TABLE ONLY public.record_revisions
    ADD CONSTRAINT record_revisions_user_id_record_id_revision_key UNIQUE (user_id, record_id, revision);

ALTER TABLE ONLY public.record_tags
    ADD CONSTRAINT record_tags_pkey PRIMARY KEY (record_id, tag_id);

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_public_id_key UNIQUE (public_id);

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_target_user_id_key UNIQUE (user_id, target_user_id);

ALTER TABLE ONLY public.sync_change_retention
    ADD CONSTRAINT sync_change_retention_pkey PRIMARY KEY (user_id, entity_type);

ALTER TABLE ONLY public.sync_mutation_receipts
    ADD CONSTRAINT sync_mutation_receipts_pkey PRIMARY KEY (user_id, client_mutation_id);

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.templates
    ADD CONSTRAINT templates_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.templates
    ADD CONSTRAINT templates_user_id_id_key UNIQUE (user_id, id);

ALTER TABLE ONLY public.user_encryption_profiles
    ADD CONSTRAINT user_encryption_profiles_pkey PRIMARY KEY (user_id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

CREATE INDEX api_keys_prefix_idx ON public.api_keys USING btree (key_prefix);

CREATE INDEX api_keys_user_active_idx ON public.api_keys USING btree (user_id, created_at DESC) WHERE (revoked_at IS NULL);

CREATE INDEX api_rate_limit_buckets_expiry_idx ON public.api_rate_limit_buckets USING btree (expires_at);

CREATE INDEX audit_log_user_created_idx ON public.audit_log USING btree (user_id, created_at DESC);

CREATE INDEX auth_rate_limits_expiry_idx ON public.auth_rate_limits USING btree (expires_at);

CREATE INDEX auth_sessions_family_idx ON public.auth_sessions USING btree (token_family_id);

CREATE INDEX auth_sessions_user_active_idx ON public.auth_sessions USING btree (user_id, expires_at) WHERE (revoked_at IS NULL);

CREATE INDEX change_log_user_cursor_idx ON public.change_log USING btree (user_id, sequence);

CREATE INDEX devices_user_active_idx ON public.devices USING btree (user_id, registered_at DESC) WHERE (revoked_at IS NULL);

CREATE INDEX events_public_starts_idx ON public.events USING btree (starts_at DESC, id DESC) WHERE ((visibility = 'public'::text) AND (deleted_at IS NULL));

CREATE INDEX events_public_user_starts_idx ON public.events USING btree (user_id, starts_at DESC, id DESC) WHERE ((visibility = 'public'::text) AND (deleted_at IS NULL));

CREATE INDEX events_user_device_starts_idx ON public.events USING btree (user_id, device_id, starts_at DESC, id) WHERE (deleted_at IS NULL);

CREATE INDEX events_user_starts_idx ON public.events USING btree (user_id, starts_at DESC, id);

CREATE INDEX events_user_type_starts_idx ON public.events USING btree (user_id, type, starts_at DESC, id) WHERE (deleted_at IS NULL);

CREATE INDEX ingestion_job_items_job_status_idx ON public.ingestion_job_items USING btree (job_id, status, ordinal);

CREATE INDEX ingestion_job_items_user_group_idx ON public.ingestion_job_items USING btree (user_id, group_key, captured_at, id);

CREATE INDEX ingestion_jobs_user_created_idx ON public.ingestion_jobs USING btree (user_id, created_at DESC, id DESC);

CREATE INDEX ingestion_jobs_user_status_idx ON public.ingestion_jobs USING btree (user_id, status, updated_at DESC, id DESC);

CREATE INDEX worker_logs_user_device_created_idx ON public.worker_logs USING btree (user_id, device_id, created_at DESC, id DESC);

CREATE INDEX idempotency_keys_expiry_idx ON public.idempotency_keys USING btree (expires_at);

CREATE INDEX media_sha256_idx ON public.media_objects USING btree (sha256) WHERE ((status = 'ready'::text) AND (deleted_at IS NULL));

CREATE INDEX media_upload_sessions_expiry_idx ON public.media_upload_sessions USING btree (expires_at) WHERE (status = ANY (ARRAY['reserved'::text, 'received'::text]));

CREATE INDEX media_upload_sessions_user_created_idx ON public.media_upload_sessions USING btree (user_id, created_at DESC, id);

CREATE UNIQUE INDEX media_upload_sessions_user_requested_media_key ON public.media_upload_sessions USING btree (user_id, requested_media_id) WHERE ((requested_media_id IS NOT NULL) AND (status = ANY (ARRAY['reserved'::text, 'received'::text])));

CREATE INDEX media_user_updated_idx ON public.media_objects USING btree (user_id, updated_at DESC, id);

CREATE INDEX public_activity_actor_cursor_idx ON public.public_activity USING btree (actor_user_id, sequence);

CREATE INDEX public_activity_resource_idx ON public.public_activity USING btree (resource_type, resource_id, sequence DESC);

CREATE INDEX record_embeddings_user_model_idx ON public.record_embeddings USING btree (user_id, model_key, record_revision DESC);

CREATE INDEX records_public_event_idx ON public.records USING btree (event_at DESC, id) WHERE ((visibility = 'public'::text) AND (deleted_at IS NULL));

CREATE INDEX records_user_device_idx ON public.records USING btree (user_id, device_id, updated_at DESC) WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX records_user_source_external_active_key ON public.records USING btree (user_id, source_provider, source_external_id) WHERE ((source_provider IS NOT NULL) AND (source_external_id IS NOT NULL) AND (deleted_at IS NULL));

CREATE INDEX records_user_updated_idx ON public.records USING btree (user_id, updated_at DESC, id);

CREATE UNIQUE INDEX resource_references_event_position_key ON public.resource_references USING btree (source_event_id, "position") WHERE (source_type = 'event'::text);

CREATE UNIQUE INDEX resource_references_record_position_key ON public.resource_references USING btree (source_record_id, "position") WHERE (source_type = 'record'::text);

CREATE INDEX resource_references_target_event_idx ON public.resource_references USING btree (target_event_id, created_at DESC) WHERE (target_event_id IS NOT NULL);

CREATE INDEX resource_references_target_record_idx ON public.resource_references USING btree (target_record_id, created_at DESC) WHERE (target_record_id IS NOT NULL);

CREATE INDEX resource_references_target_user_idx ON public.resource_references USING btree (target_user_id, target_type, created_at DESC);

CREATE INDEX subscriptions_target_active_idx ON public.subscriptions USING btree (target_user_id, created_at DESC, id DESC) WHERE (deleted_at IS NULL);

CREATE INDEX subscriptions_user_active_idx ON public.subscriptions USING btree (user_id, updated_at DESC, id DESC) WHERE (deleted_at IS NULL);

CREATE INDEX sync_mutation_receipts_expiry_idx ON public.sync_mutation_receipts USING btree (expires_at);

CREATE INDEX tags_user_sort_idx ON public.tags USING btree (user_id, sort_order, name, id) WHERE (deleted_at IS NULL);

CREATE INDEX tags_user_updated_idx ON public.tags USING btree (user_id, updated_at DESC, id);

CREATE INDEX templates_user_updated_idx ON public.templates USING btree (user_id, updated_at DESC, id) WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX users_login_casefold_key ON public.users USING btree (lower(login));

CREATE TRIGGER api_keys_revision_before_update BEFORE UPDATE ON public.api_keys FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER change_log_capture_pruning_after_delete AFTER DELETE ON public.change_log REFERENCING OLD TABLE AS pruned_changes FOR EACH STATEMENT EXECUTE FUNCTION public.capture_sync_change_pruning();

CREATE TRIGGER devices_change_after_write AFTER INSERT OR UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('device', 'revoked_at');

CREATE TRIGGER devices_revision_before_update BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER events_capture_revision_after_write AFTER INSERT OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.capture_event_revision();

CREATE TRIGGER events_change_after_write AFTER INSERT OR UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('event', 'deleted_at');

CREATE CONSTRAINT TRIGGER events_public_activity_after_write AFTER INSERT OR UPDATE ON public.events DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.emit_public_activity('event');

CREATE TRIGGER events_revision_before_update BEFORE UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER events_visibility_before_update BEFORE UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.prevent_record_visibility_change();

CREATE TRIGGER ingestion_jobs_revision_before_update BEFORE UPDATE ON public.ingestion_jobs FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER media_change_after_write AFTER INSERT OR UPDATE ON public.media_objects FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('media', 'deleted_at');

CREATE TRIGGER media_immutability_before_update BEFORE UPDATE ON public.media_objects FOR EACH ROW EXECUTE FUNCTION public.enforce_media_immutability();

CREATE TRIGGER media_revision_before_update BEFORE UPDATE ON public.media_objects FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER record_embeddings_require_public BEFORE INSERT OR UPDATE ON public.record_embeddings FOR EACH ROW EXECUTE FUNCTION public.require_public_record();

CREATE TRIGGER record_media_require_matching_visibility BEFORE INSERT OR UPDATE ON public.record_media FOR EACH ROW EXECUTE FUNCTION public.require_matching_record_media_visibility();

CREATE TRIGGER record_tags_require_public BEFORE INSERT OR UPDATE ON public.record_tags FOR EACH ROW EXECUTE FUNCTION public.require_public_record();

CREATE TRIGGER records_capture_revision_after_write AFTER INSERT OR UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.capture_record_revision();

CREATE TRIGGER records_change_after_write AFTER INSERT OR UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('record', 'deleted_at');

CREATE TRIGGER records_private_ciphertext_before_update BEFORE UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.require_fresh_private_record_ciphertext();

CREATE CONSTRAINT TRIGGER records_public_activity_after_write AFTER INSERT OR UPDATE ON public.records DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.emit_public_activity('record');

CREATE TRIGGER records_public_id_immutable_before_update BEFORE UPDATE OF public_id ON public.records FOR EACH ROW EXECUTE FUNCTION public.prevent_record_public_id_change();

CREATE TRIGGER records_revision_before_update BEFORE UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER records_visibility_before_update BEFORE UPDATE ON public.records FOR EACH ROW EXECUTE FUNCTION public.prevent_record_visibility_change();

CREATE TRIGGER resource_references_validate_before_write BEFORE INSERT OR UPDATE ON public.resource_references FOR EACH ROW EXECUTE FUNCTION public.validate_resource_reference();

CREATE TRIGGER subscriptions_change_after_write AFTER INSERT OR UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('subscription', 'deleted_at');

CREATE TRIGGER subscriptions_revision_before_update BEFORE UPDATE ON public.subscriptions FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER tags_change_after_write AFTER INSERT OR UPDATE ON public.tags FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('tag', 'deleted_at');

CREATE TRIGGER tags_revision_before_update BEFORE UPDATE ON public.tags FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER templates_change_after_write AFTER INSERT OR UPDATE ON public.templates FOR EACH ROW EXECUTE FUNCTION public.emit_change_log('template', 'deleted_at');

CREATE TRIGGER templates_revision_before_update BEFORE UPDATE ON public.templates FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

CREATE TRIGGER user_encryption_profiles_immutable_before_update BEFORE UPDATE ON public.user_encryption_profiles FOR EACH ROW EXECUTE FUNCTION public.prevent_user_encryption_profile_update();

CREATE TRIGGER users_change_after_write AFTER INSERT OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.emit_user_change_log();

CREATE CONSTRAINT TRIGGER users_public_activity_after_write AFTER INSERT OR UPDATE ON public.users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.emit_public_user_activity();

CREATE TRIGGER users_revision_before_update BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_revision_and_updated_at();

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_rotated_from_session_id_fkey FOREIGN KEY (user_id, rotated_from_session_id) REFERENCES public.auth_sessions(user_id, id) ON DELETE SET NULL (rotated_from_session_id);

ALTER TABLE ONLY public.change_log
    ADD CONSTRAINT change_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.event_revisions
    ADD CONSTRAINT event_revisions_user_id_event_id_fkey FOREIGN KEY (user_id, event_id) REFERENCES public.events(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id);

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ingestion_jobs
    ADD CONSTRAINT ingestion_jobs_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id);

ALTER TABLE ONLY public.ingestion_jobs
    ADD CONSTRAINT ingestion_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_user_device_job_fkey FOREIGN KEY (user_id, device_id, job_id) REFERENCES public.ingestion_jobs(user_id, device_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_user_upload_id_fkey FOREIGN KEY (user_id, upload_id) REFERENCES public.media_upload_sessions(user_id, id);

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_user_media_id_fkey FOREIGN KEY (user_id, media_id) REFERENCES public.media_objects(user_id, id);

ALTER TABLE ONLY public.ingestion_job_items
    ADD CONSTRAINT ingestion_job_items_user_record_id_fkey FOREIGN KEY (user_id, record_id) REFERENCES public.records(user_id, id);

ALTER TABLE ONLY public.worker_dream_attempts
    ADD CONSTRAINT worker_dream_attempts_user_device_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.worker_dream_attempts
    ADD CONSTRAINT worker_dream_attempts_user_record_fkey FOREIGN KEY (user_id, record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.worker_logs
    ADD CONSTRAINT worker_logs_user_device_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.idempotency_keys
    ADD CONSTRAINT idempotency_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.media_objects
    ADD CONSTRAINT media_objects_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id);

ALTER TABLE ONLY public.media_objects
    ADD CONSTRAINT media_objects_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id);

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.media_upload_sessions
    ADD CONSTRAINT media_upload_sessions_user_id_media_id_fkey FOREIGN KEY (user_id, media_id) REFERENCES public.media_objects(user_id, id);

ALTER TABLE ONLY public.public_activity
    ADD CONSTRAINT public_activity_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_embeddings
    ADD CONSTRAINT record_embeddings_user_id_record_id_record_revision_fkey FOREIGN KEY (user_id, record_id, record_revision) REFERENCES public.record_revisions(user_id, record_id, revision) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_media
    ADD CONSTRAINT record_media_user_id_media_id_fkey FOREIGN KEY (user_id, media_id) REFERENCES public.media_objects(user_id, id) ON DELETE RESTRICT;

ALTER TABLE ONLY public.record_media
    ADD CONSTRAINT record_media_user_id_record_id_fkey FOREIGN KEY (user_id, record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_revisions
    ADD CONSTRAINT record_revisions_user_id_record_id_fkey FOREIGN KEY (user_id, record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_tags
    ADD CONSTRAINT record_tags_user_id_record_id_fkey FOREIGN KEY (user_id, record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.record_tags
    ADD CONSTRAINT record_tags_user_id_tag_id_fkey FOREIGN KEY (user_id, tag_id) REFERENCES public.tags(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_user_id_device_id_fkey FOREIGN KEY (user_id, device_id) REFERENCES public.devices(user_id, id);

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.records
    ADD CONSTRAINT records_user_id_template_id_fkey FOREIGN KEY (user_id, template_id) REFERENCES public.templates(user_id, id);

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_source_user_id_fkey FOREIGN KEY (source_user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_source_user_id_source_event_id_fkey FOREIGN KEY (source_user_id, source_event_id) REFERENCES public.events(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_source_user_id_source_record_id_fkey FOREIGN KEY (source_user_id, source_record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_target_user_id_target_event_id_fkey FOREIGN KEY (target_user_id, target_event_id) REFERENCES public.events(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.resource_references
    ADD CONSTRAINT resource_references_target_user_id_target_record_id_fkey FOREIGN KEY (target_user_id, target_record_id) REFERENCES public.records(user_id, id) ON DELETE CASCADE;

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.sync_change_retention
    ADD CONSTRAINT sync_change_retention_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.sync_mutation_receipts
    ADD CONSTRAINT sync_mutation_receipts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.templates
    ADD CONSTRAINT templates_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.user_encryption_profiles
    ADD CONSTRAINT user_encryption_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
