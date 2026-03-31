-- Alert Management System - Initial PostgreSQL Schema
-- Migration: 001_init_schema
-- Notes:
--  - Designed to be idempotent where possible (CREATE ... IF NOT EXISTS).
--  - Uses uuid primary keys and JSONB for flexible per-channel configs.
--  - Keeps analytics aggregates materialized in separate tables for fast queries.
--  - Assumes running on PostgreSQL 12+.

BEGIN;

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enumerations (use DO blocks to avoid "already exists" errors)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_status') THEN
        CREATE TYPE user_status AS ENUM ('active', 'invited', 'disabled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'alert_status') THEN
        CREATE TYPE alert_status AS ENUM ('draft', 'active', 'paused', 'archived');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'delivery_channel') THEN
        CREATE TYPE delivery_channel AS ENUM ('in_app', 'email', 'sms', 'push', 'webhook');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_status') THEN
        CREATE TYPE notification_status AS ENUM ('queued', 'sent', 'failed', 'skipped', 'cancelled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'template_type') THEN
        CREATE TYPE template_type AS ENUM ('alert', 'digest', 'system');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'recurrence_frequency') THEN
        CREATE TYPE recurrence_frequency AS ENUM ('once', 'minutely', 'hourly', 'daily', 'weekly', 'monthly', 'cron');
    END IF;
END $$;

-- Core RBAC
CREATE TABLE IF NOT EXISTS roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    description text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE, -- e.g., alerts:read, alerts:write
    description text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS role_permissions (
    role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (role_id, permission_id)
);

-- Users (auth can be external; this stores profile + role bindings)
CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL UNIQUE,
    password_hash text, -- nullable if external auth
    full_name text,
    status user_status NOT NULL DEFAULT 'active',
    is_email_verified boolean NOT NULL DEFAULT false,
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_roles (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id uuid NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

-- Templates
CREATE TABLE IF NOT EXISTS templates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    template_type template_type NOT NULL DEFAULT 'alert',
    subject text,
    body_text text,
    body_html text,
    variables_schema jsonb NOT NULL DEFAULT '{}'::jsonb, -- expected variables/shape
    is_active boolean NOT NULL DEFAULT true,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- User notification preferences
CREATE TABLE IF NOT EXISTS user_preferences (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,

    timezone text NOT NULL DEFAULT 'UTC',
    locale text NOT NULL DEFAULT 'en',

    -- per-channel defaults (enablement + addresses/tokens + routing config)
    channels jsonb NOT NULL DEFAULT '{
      "in_app": {"enabled": true},
      "email": {"enabled": true},
      "sms": {"enabled": false},
      "push": {"enabled": false},
      "webhook": {"enabled": false}
    }'::jsonb,

    -- quiet hours and other global settings
    quiet_hours jsonb NOT NULL DEFAULT '{
      "enabled": false,
      "start": "22:00",
      "end": "07:00"
    }'::jsonb,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Alert definition
CREATE TABLE IF NOT EXISTS alerts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,

    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

    status alert_status NOT NULL DEFAULT 'draft',

    -- content/template configuration
    template_id uuid REFERENCES templates(id) ON DELETE SET NULL,
    message_subject text,
    message_body text, -- fallback message when template not used

    -- default channels to attempt; user prefs can override at send-time
    channels delivery_channel[] NOT NULL DEFAULT ARRAY['in_app']::delivery_channel[],

    -- targeting / audience
    target_user_ids uuid[] NOT NULL DEFAULT '{}'::uuid[], -- explicit list
    target_roles uuid[] NOT NULL DEFAULT '{}'::uuid[], -- roles whose members receive
    target_filter jsonb NOT NULL DEFAULT '{}'::jsonb, -- flexible filters

    -- scheduling / recurrence
    starts_at timestamptz,
    ends_at timestamptz,
    next_run_at timestamptz, -- scheduler can compute and persist

    recurrence_frequency recurrence_frequency NOT NULL DEFAULT 'once',
    recurrence_interval integer NOT NULL DEFAULT 1, -- e.g. every 2 days
    recurrence_byweekday int[] NOT NULL DEFAULT '{}'::int[], -- 0=Sun..6=Sat
    recurrence_bymonthday int[] NOT NULL DEFAULT '{}'::int[],
    recurrence_cron text, -- for frequency=cron
    recurrence_timezone text NOT NULL DEFAULT 'UTC',

    -- throttling / dedupe
    dedupe_key text,
    dedupe_window_seconds integer NOT NULL DEFAULT 0,

    -- metadata / tags
    tags text[] NOT NULL DEFAULT '{}'::text[],
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT alerts_owner_name_uniq UNIQUE(owner_user_id, name),
    CONSTRAINT alerts_cron_required CHECK (
        (recurrence_frequency <> 'cron') OR (recurrence_cron IS NOT NULL AND length(recurrence_cron) > 0)
    )
);

CREATE INDEX IF NOT EXISTS idx_alerts_owner ON alerts(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_alerts_status ON alerts(status);
CREATE INDEX IF NOT EXISTS idx_alerts_next_run_at ON alerts(next_run_at);

-- Alert delivery overrides per user (optional)
CREATE TABLE IF NOT EXISTS alert_user_overrides (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id uuid NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- override channels and/or per-channel config
    channels delivery_channel[],

    channel_overrides jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_muted boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    UNIQUE(alert_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_alert_user_overrides_alert ON alert_user_overrides(alert_id);
CREATE INDEX IF NOT EXISTS idx_alert_user_overrides_user ON alert_user_overrides(user_id);

-- Notification run batches (for scheduling/executions)
CREATE TABLE IF NOT EXISTS notification_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id uuid NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status text NOT NULL DEFAULT 'running', -- running|completed|failed|cancelled
    stats jsonb NOT NULL DEFAULT '{}'::jsonb,
    error_message text
);

CREATE INDEX IF NOT EXISTS idx_notification_runs_alert ON notification_runs(alert_id);
CREATE INDEX IF NOT EXISTS idx_notification_runs_started ON notification_runs(started_at);

-- Delivery logs (one per user per channel attempt)
CREATE TABLE IF NOT EXISTS notification_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    run_id uuid REFERENCES notification_runs(id) ON DELETE SET NULL,
    alert_id uuid NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    user_id uuid REFERENCES users(id) ON DELETE SET NULL,

    channel delivery_channel NOT NULL,
    status notification_status NOT NULL DEFAULT 'queued',

    provider text, -- e.g. sendgrid/twilio/firebase/custom
    provider_message_id text,

    destination text, -- email/phone/device_token/webhook_url (masked in app layer if needed)
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,

    error_code text,
    error_message text,

    queued_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    delivered_at timestamptz,
    failed_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_logs_alert_created ON notification_logs(alert_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_logs_user_created ON notification_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notification_logs_run ON notification_logs(run_id);
CREATE INDEX IF NOT EXISTS idx_notification_logs_status ON notification_logs(status);
CREATE INDEX IF NOT EXISTS idx_notification_logs_channel ON notification_logs(channel);

-- In-app notifications (materialized inbox)
CREATE TABLE IF NOT EXISTS in_app_notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    alert_id uuid REFERENCES alerts(id) ON DELETE SET NULL,
    notification_log_id uuid REFERENCES notification_logs(id) ON DELETE SET NULL,

    title text,
    body text,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,

    is_read boolean NOT NULL DEFAULT false,
    read_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_in_app_notifications_user_created ON in_app_notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_in_app_notifications_user_unread ON in_app_notifications(user_id, is_read);

-- Analytics aggregates (daily rollups)
CREATE TABLE IF NOT EXISTS alert_daily_stats (
    alert_id uuid NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    day date NOT NULL,
    queued_count bigint NOT NULL DEFAULT 0,
    sent_count bigint NOT NULL DEFAULT 0,
    failed_count bigint NOT NULL DEFAULT 0,
    delivered_count bigint NOT NULL DEFAULT 0,
    unique_users bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (alert_id, day)
);

CREATE TABLE IF NOT EXISTS channel_daily_stats (
    channel delivery_channel NOT NULL,
    day date NOT NULL,
    queued_count bigint NOT NULL DEFAULT 0,
    sent_count bigint NOT NULL DEFAULT 0,
    failed_count bigint NOT NULL DEFAULT 0,
    delivered_count bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (channel, day)
);

-- Generic updated_at trigger helper
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach triggers (only if not already present)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at') THEN
        CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_templates_updated_at') THEN
        CREATE TRIGGER trg_templates_updated_at BEFORE UPDATE ON templates
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_user_preferences_updated_at') THEN
        CREATE TRIGGER trg_user_preferences_updated_at BEFORE UPDATE ON user_preferences
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_alerts_updated_at') THEN
        CREATE TRIGGER trg_alerts_updated_at BEFORE UPDATE ON alerts
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_alert_user_overrides_updated_at') THEN
        CREATE TRIGGER trg_alert_user_overrides_updated_at BEFORE UPDATE ON alert_user_overrides
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_alert_daily_stats_updated_at') THEN
        CREATE TRIGGER trg_alert_daily_stats_updated_at BEFORE UPDATE ON alert_daily_stats
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_channel_daily_stats_updated_at') THEN
        CREATE TRIGGER trg_channel_daily_stats_updated_at BEFORE UPDATE ON channel_daily_stats
        FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    END IF;
END $$;

COMMIT;
