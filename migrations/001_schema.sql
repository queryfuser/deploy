-- QueryFuser schema — run this once against a fresh PostgreSQL database.
--
--   createdb queryfuser
--   psql -d queryfuser -f migrations/001_schema.sql

-- ── Organizations ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS organizations (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
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
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_user_default ON projects (user_id) WHERE is_default = TRUE;
CREATE INDEX IF NOT EXISTS idx_projects_org ON projects (organization_id);

-- ── Query logs ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS query_logs (
    id                SERIAL PRIMARY KEY,
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
    client_ip         VARCHAR(45),
    application_name  VARCHAR(255),
    cache_hit         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_query_logs_org ON query_logs (organization_id);

-- ── Merge logs ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS merge_logs (
    id                SERIAL PRIMARY KEY,
    organization_id   INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    merged_sql        TEXT,
    query_count       INTEGER,
    rows_returned     INTEGER,
    duration_ms       INTEGER,
    error             TEXT,
    project_id        VARCHAR(255),
    bytes_processed   BIGINT,
    cache_hit         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_merge_logs_org ON merge_logs (organization_id);

-- ── Performance indices for dashboard queries ────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_query_logs_solo_lookup
    ON query_logs (organization_id, translated_sql, created_at DESC)
    WHERE merge_log_id IS NULL AND error IS NULL AND bytes_processed IS NOT NULL;
