-- pg_dump/pg_restore deliberately clears the session search_path. This
-- function is recursive, so give it an explicit, stable lookup path; without
-- it, restoring record data can fail while evaluating JSON size constraints.
ALTER FUNCTION public.exeligmos_jsonb_compact_octet_length(jsonb)
  SET search_path TO pg_catalog, public;
