-- Keep direct SQL and future handlers on the same bounded Phase 3 contract as
-- the HTTP services. The compact JSON helper is installed by migration 0005.
ALTER TABLE tags
  ADD CONSTRAINT tags_metadata_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(metadata) <= 32768
  ),
  ADD CONSTRAINT tags_emoji_length_check CHECK (
    emoji IS NULL OR char_length(emoji) <= 32
  );

ALTER TABLE templates
  ADD CONSTRAINT templates_body_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(body) <= 262144
  ),
  ADD CONSTRAINT templates_variable_schema_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(variable_schema) <= 262144
  ),
  ADD CONSTRAINT templates_metadata_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(metadata) <= 32768
  ),
  ADD CONSTRAINT templates_description_length_check CHECK (
    description IS NULL OR char_length(description) <= 2000
  ),
  ADD CONSTRAINT templates_nonempty_documents_check CHECK (
    body <> '{}'::jsonb AND variable_schema <> '{}'::jsonb
  );

ALTER TABLE template_versions
  ADD CONSTRAINT template_versions_body_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(body) <= 262144
  ),
  ADD CONSTRAINT template_versions_variable_schema_size_check CHECK (
    exeligmos_jsonb_compact_octet_length(variable_schema) <= 262144
  ),
  ADD CONSTRAINT template_versions_nonempty_documents_check CHECK (
    body <> '{}'::jsonb AND variable_schema <> '{}'::jsonb
  );

ALTER TABLE media_objects
  ADD CONSTRAINT media_objects_content_type_syntax_check CHECK (
    content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'
  ),
  ADD CONSTRAINT media_objects_plaintext_content_type_syntax_check CHECK (
    plaintext_content_type IS NULL
    OR plaintext_content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'
  );

ALTER TABLE media_upload_sessions
  ADD CONSTRAINT media_upload_sessions_content_type_syntax_check CHECK (
    content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'
  ),
  ADD CONSTRAINT media_upload_sessions_plaintext_content_type_syntax_check CHECK (
    plaintext_content_type IS NULL
    OR plaintext_content_type ~ '^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$'
  );
