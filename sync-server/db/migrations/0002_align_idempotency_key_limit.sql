ALTER TABLE idempotency_keys
  DROP CONSTRAINT idempotency_keys_idempotency_key_check;

ALTER TABLE idempotency_keys
  ADD CONSTRAINT idempotency_keys_idempotency_key_check
  CHECK (
    idempotency_key = btrim(idempotency_key)
    AND char_length(idempotency_key) BETWEEN 8 AND 255
  );

