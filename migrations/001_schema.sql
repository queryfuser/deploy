-- QueryFuser self-hosted schema
-- All tables use IF NOT EXISTS / IF NOT EXISTS so this is safe to re-run.

-- ── Organizations ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS organizations (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    deployment_type VARCHAR(20)  NOT NULL DEFAULT 'self_hosted',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ── Users ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS users (
    id                  SERIAL PRIMARY KEY,
    username            VARCHAR(100) NOT NULL UNIQUE,
    email               VARCHAR(255) NOT NULL UNIQUE,
    password_hash       VARCHAR(255),
    pg_password_md5     VARCHAR(35) DEFAULT '',
    google_id           TEXT,
    google_email        TEXT,
    google_refresh_token TEXT,
    avatar_url          TEXT,
    organization_id     INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    role                VARCHAR(20) NOT NULL DEFAULT 'viewer',
    applied_for_org_id  INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_username ON users (username);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_google_id ON users (google_id) WHERE google_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_org ON users (organization_id);

-- ── Projects (BigQuery connections) ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS projects (
    id                   SERIAL PRIMARY KEY,
    user_id              INTEGER      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    organization_id      INTEGER      REFERENCES organizations(id) ON DELETE CASCADE,
    name                 VARCHAR(255) NOT NULL,
    bigquery_project_id  VARCHAR(255) NOT NULL,
    bigquery_dataset     VARCHAR(255) NOT NULL DEFAULT '',
    credentials_json     TEXT         NOT NULL DEFAULT '',
    is_default           BOOLEAN      NOT NULL DEFAULT FALSE,
    merge_window_ms      INTEGER      NOT NULL DEFAULT 200,
    min_table_overlap    INTEGER      NOT NULL DEFAULT 1,
    max_merge_group_size INTEGER      NOT NULL DEFAULT 50,
    merge_enabled        BOOLEAN      NOT NULL DEFAULT TRUE,
    proxy_username       VARCHAR(255),
    proxy_password_md5   TEXT,
    allowed_ips          TEXT         NOT NULL DEFAULT '',
    cache_optimizer_enabled BOOLEAN   NOT NULL DEFAULT FALSE,
    cache_timezone       TEXT         NOT NULL DEFAULT 'UTC',
    cache_resolution_minutes INTEGER  NOT NULL DEFAULT 5,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_user_default ON projects (user_id) WHERE is_default = TRUE;
CREATE INDEX IF NOT EXISTS idx_projects_org ON projects (organization_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_proxy_username
    ON projects (proxy_username) WHERE proxy_username IS NOT NULL;

-- ── Query logs ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS query_logs (
    id                BIGSERIAL PRIMARY KEY,
    organization_id   INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    project_id        VARCHAR(255),
    dataset           VARCHAR(255),
    original_sql      TEXT,
    translated_sql    TEXT,
    rows_returned     INTEGER,
    duration_ms       INTEGER,
    error             TEXT,
    merge_log_id      INTEGER,
    bytes_processed   BIGINT,
    slot_ms           BIGINT,
    client_ip         VARCHAR(45),
    application_name  VARCHAR(255),
    cache_hit         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_query_logs_org ON query_logs (organization_id);

-- ── Merge logs ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS merge_logs (
    id                BIGSERIAL PRIMARY KEY,
    organization_id   INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    merged_sql        TEXT,
    query_count       INTEGER,
    rows_returned     INTEGER,
    duration_ms       INTEGER,
    error             TEXT,
    project_id        VARCHAR(255),
    bytes_processed   BIGINT,
    estimated_solo_bytes BIGINT,
    slot_ms           BIGINT,
    estimated_solo_slot_ms BIGINT,
    cache_hit         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_merge_logs_org ON merge_logs (organization_id);

-- ── Performance indices for dashboard queries ────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_query_logs_solo_lookup
    ON query_logs (organization_id, translated_sql, created_at DESC)
    WHERE merge_log_id IS NULL AND error IS NULL AND bytes_processed IS NOT NULL;

-- ── Connection events ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS connection_events (
    id              BIGSERIAL PRIMARY KEY,
    event_type      TEXT NOT NULL,
    peer_addr       TEXT,
    username        TEXT,
    database_name   TEXT,
    application_name TEXT,
    error_message   TEXT,
    organization_id INTEGER REFERENCES organizations(id),
    user_id         INTEGER REFERENCES users(id),
    duration_ms     BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_connection_events_org_created
    ON connection_events (organization_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_connection_events_type
    ON connection_events (event_type, created_at DESC);

-- ── Linked BQ sources (cross-project JOINs) ─────────────────────────────────

CREATE TABLE IF NOT EXISTS project_bq_sources (
    id              SERIAL PRIMARY KEY,
    project_id      INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    bq_project_id   VARCHAR(255) NOT NULL,
    bq_dataset      VARCHAR(255) NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(project_id, bq_project_id, bq_dataset)
);

CREATE INDEX IF NOT EXISTS idx_bq_sources_project_id
    ON project_bq_sources (project_id);

-- ── Password reset tokens ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id         SERIAL PRIMARY KEY,
    user_id    INT         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token      VARCHAR(64) NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reset_tokens_token
    ON password_reset_tokens (token);
