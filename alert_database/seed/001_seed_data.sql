-- Alert Management System - Seed Data
-- Seed: 001_seed_data
-- Safe to run multiple times (uses ON CONFLICT DO NOTHING where appropriate).

BEGIN;

-- Roles
INSERT INTO roles (name, description)
VALUES
  ('admin', 'Full administrative access'),
  ('user', 'Standard user access')
ON CONFLICT (name) DO NOTHING;

-- Permissions
INSERT INTO permissions (code, description)
VALUES
  ('users:read', 'Read users'),
  ('users:write', 'Create/update users'),
  ('roles:read', 'Read roles'),
  ('roles:write', 'Manage roles and permissions'),
  ('alerts:read', 'Read alerts'),
  ('alerts:write', 'Create/update alerts'),
  ('alerts:run', 'Run alerts / scheduling'),
  ('templates:read', 'Read templates'),
  ('templates:write', 'Create/update templates'),
  ('preferences:read', 'Read user preferences'),
  ('preferences:write', 'Update user preferences'),
  ('notifications:read', 'Read notification logs'),
  ('analytics:read', 'Read analytics aggregates')
ON CONFLICT (code) DO NOTHING;

-- Role -> permissions mappings
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.code IN (
  'users:read','users:write','roles:read','roles:write',
  'alerts:read','alerts:write','alerts:run',
  'templates:read','templates:write',
  'preferences:read','preferences:write',
  'notifications:read','analytics:read'
)
WHERE r.name = 'admin'
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.code IN (
  'alerts:read','alerts:write',
  'templates:read',
  'preferences:read','preferences:write',
  'notifications:read',
  'analytics:read'
)
WHERE r.name = 'user'
ON CONFLICT DO NOTHING;

-- Users (password_hash is placeholder; real auth handled by backend)
INSERT INTO users (email, password_hash, full_name, status, is_email_verified)
VALUES
  ('admin@example.com', 'dev_hash_admin', 'Admin User', 'active', true),
  ('alice@example.com', 'dev_hash_alice', 'Alice Example', 'active', true),
  ('bob@example.com', 'dev_hash_bob', 'Bob Example', 'active', true)
ON CONFLICT (email) DO NOTHING;

-- User roles
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u JOIN roles r ON r.name = 'admin'
WHERE u.email = 'admin@example.com'
ON CONFLICT DO NOTHING;

INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u JOIN roles r ON r.name = 'user'
WHERE u.email IN ('alice@example.com','bob@example.com')
ON CONFLICT DO NOTHING;

-- Preferences
INSERT INTO user_preferences (user_id, timezone, locale, channels, quiet_hours)
SELECT id, 'UTC', 'en',
'{
  "in_app": {"enabled": true},
  "email": {"enabled": true, "address": "alice@example.com"},
  "sms": {"enabled": false},
  "push": {"enabled": false},
  "webhook": {"enabled": false}
}'::jsonb,
'{"enabled": false, "start": "22:00", "end": "07:00"}'::jsonb
FROM users WHERE email='alice@example.com'
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO user_preferences (user_id, timezone, locale, channels, quiet_hours)
SELECT id, 'UTC', 'en',
'{
  "in_app": {"enabled": true},
  "email": {"enabled": false},
  "sms": {"enabled": true, "phone": "+15551234567"},
  "push": {"enabled": false},
  "webhook": {"enabled": false}
}'::jsonb,
'{"enabled": true, "start": "23:00", "end": "06:30"}'::jsonb
FROM users WHERE email='bob@example.com'
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO user_preferences (user_id)
SELECT id FROM users WHERE email='admin@example.com'
ON CONFLICT (user_id) DO NOTHING;

-- Templates
INSERT INTO templates (name, template_type, subject, body_text, variables_schema, is_active, created_by)
SELECT
  'Default Alert',
  'alert',
  'Alert: {{name}}',
  'Hello {{user_name}},\n\n{{message}}\n\n- Alert System',
  '{"type":"object","properties":{"name":{"type":"string"},"user_name":{"type":"string"},"message":{"type":"string"}}}'::jsonb,
  true,
  u.id
FROM users u WHERE u.email='admin@example.com'
ON CONFLICT (name) DO NOTHING;

INSERT INTO templates (name, template_type, subject, body_text, variables_schema, is_active, created_by)
SELECT
  'Maintenance Notice',
  'system',
  'Maintenance window',
  'Scheduled maintenance will occur at {{time}} ({{timezone}}).',
  '{"type":"object","properties":{"time":{"type":"string"},"timezone":{"type":"string"}}}'::jsonb,
  true,
  u.id
FROM users u WHERE u.email='admin@example.com'
ON CONFLICT (name) DO NOTHING;

-- Alerts
INSERT INTO alerts (
  name, description, owner_user_id, status,
  template_id, message_subject, message_body,
  channels, target_user_ids,
  starts_at, next_run_at,
  recurrence_frequency, recurrence_interval, recurrence_timezone,
  tags, metadata
)
SELECT
  'Daily Summary',
  'Example daily recurring alert',
  u.id,
  'active',
  t.id,
  NULL,
  'This is your daily summary.',
  ARRAY['in_app','email']::delivery_channel[],
  ARRAY[(SELECT id FROM users WHERE email='alice@example.com'), (SELECT id FROM users WHERE email='bob@example.com')]::uuid[],
  now(),
  now() + interval '5 minutes',
  'daily',
  1,
  'UTC',
  ARRAY['demo','daily']::text[],
  '{"source":"seed"}'::jsonb
FROM users u
JOIN templates t ON t.name = 'Default Alert'
WHERE u.email='admin@example.com'
ON CONFLICT (owner_user_id, name) DO NOTHING;

INSERT INTO alerts (
  name, description, owner_user_id, status,
  template_id, message_subject, message_body,
  channels, target_user_ids,
  starts_at, next_run_at,
  recurrence_frequency, recurrence_interval, recurrence_timezone,
  tags, metadata
)
SELECT
  'One-time Maintenance',
  'Example one-time scheduled notice',
  u.id,
  'active',
  t.id,
  NULL,
  NULL,
  ARRAY['in_app','email']::delivery_channel[],
  ARRAY[(SELECT id FROM users WHERE email='alice@example.com')]::uuid[],
  now() + interval '1 hour',
  now() + interval '1 hour',
  'once',
  1,
  'UTC',
  ARRAY['demo','maintenance']::text[],
  '{"source":"seed"}'::jsonb
FROM users u
JOIN templates t ON t.name = 'Maintenance Notice'
WHERE u.email='admin@example.com'
ON CONFLICT (owner_user_id, name) DO NOTHING;

-- Create a sample run + logs for the Daily Summary
WITH a AS (
  SELECT id FROM alerts WHERE name='Daily Summary' LIMIT 1
),
r AS (
  INSERT INTO notification_runs (alert_id, status, stats, started_at, finished_at)
  SELECT a.id, 'completed', '{"queued":2,"sent":2,"failed":0}'::jsonb, now() - interval '1 day', now() - interval '1 day' + interval '10 seconds'
  FROM a
  RETURNING id, alert_id
)
INSERT INTO notification_logs (run_id, alert_id, user_id, channel, status, provider, destination, payload, sent_at, delivered_at)
SELECT
  r.id,
  r.alert_id,
  u.id,
  'in_app'::delivery_channel,
  'sent'::notification_status,
  'internal',
  u.email,
  '{"title":"Daily Summary","body":"Demo in-app notification"}'::jsonb,
  now() - interval '1 day' + interval '1 second',
  now() - interval '1 day' + interval '2 seconds'
FROM r
JOIN users u ON u.email IN ('alice@example.com','bob@example.com');

-- In-app notifications inbox items
INSERT INTO in_app_notifications (user_id, alert_id, title, body, data, is_read)
SELECT
  u.id,
  a.id,
  'Daily Summary',
  'Demo in-app notification',
  '{"seed":true}'::jsonb,
  false
FROM users u
JOIN alerts a ON a.name='Daily Summary'
WHERE u.email IN ('alice@example.com','bob@example.com');

-- Seed analytics aggregates (yesterday)
INSERT INTO alert_daily_stats (alert_id, day, queued_count, sent_count, failed_count, delivered_count, unique_users)
SELECT a.id, (current_date - 1), 2, 2, 0, 2, 2
FROM alerts a
WHERE a.name='Daily Summary'
ON CONFLICT (alert_id, day) DO NOTHING;

INSERT INTO channel_daily_stats (channel, day, queued_count, sent_count, failed_count, delivered_count)
VALUES
  ('in_app', current_date - 1, 2, 2, 0, 2),
  ('email', current_date - 1, 2, 2, 0, 2)
ON CONFLICT (channel, day) DO NOTHING;

COMMIT;
