ALTER TABLE users
  ADD COLUMN saros_anchor integer NOT NULL DEFAULT 141
    CHECK (saros_anchor BETWEEN 1 AND 180);

COMMENT ON COLUMN users.saros_anchor IS
  'Saros-series anchor used for the user''s realtime pulse clock and record presentation.';
