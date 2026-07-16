-- Social graph and global public-activity foundations for the desktop client.

ALTER TABLE events
  ADD COLUMN visibility text NOT NULL DEFAULT 'public'
    CHECK (visibility IN ('public', 'private'));

CREATE INDEX events_public_starts_idx
  ON events (starts_at DESC, id DESC)
  WHERE visibility = 'public' AND deleted_at IS NULL;

CREATE INDEX events_public_user_starts_idx
  ON events (user_id, starts_at DESC, id DESC)
  WHERE visibility = 'public' AND deleted_at IS NULL;

CREATE TRIGGER events_visibility_before_update
  BEFORE UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION prevent_record_visibility_change();

ALTER TABLE api_keys
  DROP CONSTRAINT api_keys_scopes_check,
  ADD CONSTRAINT api_keys_scopes_check CHECK (
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
      'subscriptions:read', 'subscriptions:write',
      'sync:read', 'sync:write'
    ]::text[]
  );

ALTER TABLE change_log
  DROP CONSTRAINT change_log_entity_type_check,
  ADD CONSTRAINT change_log_entity_type_check CHECK (
    entity_type IN (
      'user', 'device', 'record', 'event', 'tag', 'template', 'media',
      'subscription'
    )
  );

ALTER TABLE sync_change_retention
  DROP CONSTRAINT sync_change_retention_entity_type_check,
  ADD CONSTRAINT sync_change_retention_entity_type_check CHECK (
    entity_type IN (
      'user', 'device', 'record', 'event', 'tag', 'template', 'media',
      'subscription'
    )
  );

CREATE TABLE subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  include_records boolean NOT NULL DEFAULT true,
  include_events boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  UNIQUE (user_id, id),
  UNIQUE (user_id, target_user_id),
  CHECK (user_id <> target_user_id),
  CHECK (include_records OR include_events)
);

CREATE INDEX subscriptions_user_active_idx
  ON subscriptions (user_id, updated_at DESC, id DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX subscriptions_target_active_idx
  ON subscriptions (target_user_id, created_at DESC, id DESC)
  WHERE deleted_at IS NULL;

CREATE TRIGGER subscriptions_revision_before_update
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_revision_and_updated_at();

CREATE TRIGGER subscriptions_change_after_write
  AFTER INSERT OR UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION emit_change_log('subscription', 'deleted_at');

COMMENT ON TABLE subscriptions IS
  'Private owner state describing public-user subscriptions. Rows are soft-deleted so owner sync receives tombstones.';

CREATE TABLE resource_references (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source_type text NOT NULL CHECK (source_type IN ('record', 'event')),
  source_record_id uuid,
  source_event_id uuid,
  position integer NOT NULL CHECK (position >= 0 AND position < 200),
  relation text NOT NULL DEFAULT 'reference',
  target_type text NOT NULL CHECK (target_type IN ('user', 'record', 'event')),
  target_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_record_id uuid,
  target_event_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (source_user_id, source_record_id)
    REFERENCES records(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (source_user_id, source_event_id)
    REFERENCES events(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (target_user_id, target_record_id)
    REFERENCES records(user_id, id) ON DELETE CASCADE,
  FOREIGN KEY (target_user_id, target_event_id)
    REFERENCES events(user_id, id) ON DELETE CASCADE,
  CHECK (
    (source_type = 'record' AND source_record_id IS NOT NULL AND source_event_id IS NULL)
    OR
    (source_type = 'event' AND source_record_id IS NULL AND source_event_id IS NOT NULL)
  ),
  CHECK (
    (target_type = 'user' AND target_record_id IS NULL AND target_event_id IS NULL)
    OR
    (target_type = 'record' AND target_record_id IS NOT NULL AND target_event_id IS NULL)
    OR
    (target_type = 'event' AND target_record_id IS NULL AND target_event_id IS NOT NULL)
  ),
  CHECK (
    relation = btrim(relation)
    AND relation ~ '^[A-Za-z][A-Za-z0-9._:-]{0,63}$'
  )
);

CREATE UNIQUE INDEX resource_references_record_position_key
  ON resource_references (source_record_id, position)
  WHERE source_type = 'record';

CREATE UNIQUE INDEX resource_references_event_position_key
  ON resource_references (source_event_id, position)
  WHERE source_type = 'event';

CREATE INDEX resource_references_target_user_idx
  ON resource_references (target_user_id, target_type, created_at DESC);

CREATE INDEX resource_references_target_record_idx
  ON resource_references (target_record_id, created_at DESC)
  WHERE target_record_id IS NOT NULL;

CREATE INDEX resource_references_target_event_idx
  ON resource_references (target_event_id, created_at DESC)
  WHERE target_event_id IS NOT NULL;

CREATE FUNCTION validate_resource_reference()
RETURNS trigger
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

CREATE TRIGGER resource_references_validate_before_write
  BEFORE INSERT OR UPDATE ON resource_references
  FOR EACH ROW EXECUTE FUNCTION validate_resource_reference();

COMMENT ON TABLE resource_references IS
  'Typed, ordered relationships originating from records/events. Cross-user resource targets must be public; projections expose identifiers only.';

CREATE TABLE public_activity (
  sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  resource_type text NOT NULL CHECK (resource_type IN ('user', 'record', 'event')),
  resource_id uuid NOT NULL,
  operation text NOT NULL CHECK (operation IN ('upsert', 'delete')),
  revision bigint NOT NULL CHECK (revision > 0),
  published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (resource_type <> 'user' OR resource_id = actor_user_id)
);

CREATE INDEX public_activity_actor_cursor_idx
  ON public_activity (actor_user_id, sequence);

CREATE INDEX public_activity_resource_idx
  ON public_activity (resource_type, resource_id, sequence DESC);

CREATE FUNCTION emit_public_activity()
RETURNS trigger
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

CREATE CONSTRAINT TRIGGER records_public_activity_after_write
  AFTER INSERT OR UPDATE ON records
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION emit_public_activity('record');

CREATE CONSTRAINT TRIGGER events_public_activity_after_write
  AFTER INSERT OR UPDATE ON events
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION emit_public_activity('event');

CREATE FUNCTION emit_public_user_activity()
RETURNS trigger
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

CREATE CONSTRAINT TRIGGER users_public_activity_after_write
  AFTER INSERT OR UPDATE ON users
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION emit_public_user_activity();

-- Existing public actors and resources predate the outbox triggers. Seed one
-- current-state event for each so a cursor started after this migration sees a
-- complete visible base. Disabled actors intentionally have no baseline rows.
INSERT INTO public_activity (
  actor_user_id, resource_type, resource_id, operation, revision, published_at
)
SELECT id, 'user', id, 'upsert', revision, updated_at
FROM users
WHERE status = 'active';

INSERT INTO public_activity (
  actor_user_id, resource_type, resource_id, operation, revision, published_at
)
SELECT resource.user_id, 'record', resource.id, 'upsert', resource.revision, resource.updated_at
FROM records resource
JOIN users actor ON actor.id = resource.user_id AND actor.status = 'active'
WHERE resource.visibility = 'public' AND resource.deleted_at IS NULL
UNION ALL
SELECT resource.user_id, 'event', resource.id, 'upsert', resource.revision, resource.updated_at
FROM events resource
JOIN users actor ON actor.id = resource.user_id AND actor.status = 'active'
WHERE resource.visibility = 'public' AND resource.deleted_at IS NULL;

COMMENT ON FUNCTION emit_public_user_activity() IS
  'Emits identifier-only lifecycle controls: delete hides an actor and cached public resources; upsert restores the actor and requires an actor-filtered refetch.';

COMMENT ON TABLE public_activity IS
  'Append-only, monotonic cursor source for public user lifecycle controls and record/event revision notifications. It never contains private payloads.';
