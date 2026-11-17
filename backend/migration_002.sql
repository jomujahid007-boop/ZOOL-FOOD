-- Run once on top of schema.sql: push-notification device tokens
CREATE TABLE IF NOT EXISTS device_tokens(
 token text PRIMARY KEY, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
 platform text, at timestamptz DEFAULT now());
CREATE INDEX IF NOT EXISTS device_tokens_user ON device_tokens(user_id);
