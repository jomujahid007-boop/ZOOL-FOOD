-- Idempotent: runs on every start
CREATE TABLE IF NOT EXISTS device_tokens(
 token text PRIMARY KEY, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
 platform text, at timestamptz DEFAULT now());
CREATE INDEX IF NOT EXISTS device_tokens_user ON device_tokens(user_id);
ALTER TABLE restaurants ADD COLUMN IF NOT EXISTS sort int NOT NULL DEFAULT 100;
CREATE TABLE IF NOT EXISTS app_meta(key text PRIMARY KEY, value text);
