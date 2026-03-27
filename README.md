# QueryFuser — Self-Hosted Deployment

QueryFuser is a PostgreSQL-compatible proxy that intercepts queries from your BI tools, translates them to BigQuery SQL, and **merges concurrent identical queries** to reduce BigQuery costs.

## One-Line Install

SSH into your GCE VM and run:

```bash
git clone https://github.com/queryfuser/deploy.git && cd deploy && bash setup.sh
```

The setup script will:
1. Install Docker (if needed)
2. Prompt for your license key
3. Auto-generate all secrets (database password, JWT, encryption key)
4. Pull and start PostgreSQL + QueryFuser

After setup, open the dashboard to register a user and create your first BigQuery project. The proxy uses the VM's default service account — no service account JSON needed.

## Prerequisites

- A **GCP project** with BigQuery enabled
- A **GCE VM** (e2-small or larger) with:
  - Docker installed (the setup script can install it)
  - **Access scopes** set to **Allow full access to all Cloud APIs** (VM → Edit → API and identity management). This must be set at VM creation time, or by stopping the VM first.
  - **IAM roles** on the VM's default service account: **BigQuery Data Viewer**, **BigQuery Job User**, and **BigQuery User**. If you query datasets in other GCP projects (linked sources), grant the same roles on those projects too.
  - Firewall rules allowing ports **3001** (dashboard) and **5433** (proxy)
- A **QueryFuser license key** from [queryfuser.com](https://queryfuser.com)

> **Note:** PostgreSQL is bundled in Docker Compose — no external database is needed out of the box. See [Migrating to Cloud SQL](#migrating-to-cloud-sql) if you prefer a managed database.

## Manual Setup

If you prefer to set things up yourself instead of using `setup.sh`:

### 1. Clone and configure

```bash
git clone https://github.com/queryfuser/deploy.git && cd deploy
cp .env.example .env
```

Edit `.env` and set `QUERYFUSER_LICENSE_KEY` to your license key. Generate random values for `POSTGRES_PASSWORD`, `JWT_SECRET`, and `MASTER_KEY` (32-byte hex). The rest of the defaults work as-is.

> **Tip:** `setup.sh` does all of this automatically — it prompts for the license key and auto-generates all secrets.

### 2. Start QueryFuser

```bash
docker compose up -d
```

Database tables are created automatically on first startup. Schema migrations are also applied automatically on updates.

### 3. Create your BigQuery project

Open the dashboard at `http://<your-vm-ip>:3001`, register a user, and create a BigQuery project. Enter your GCP project ID and dataset — credentials are handled automatically via the VM's service account.

## Ports

| Port | Service |
|------|---------|
| **3001** | Dashboard (web UI + API) |
| **5433** | PostgreSQL proxy (point your BI tool here) |

## Connecting Your BI Tool

Configure your BI tool (Looker, Metabase, Tableau, etc.) as a PostgreSQL connection:

| Setting | Value |
|---------|-------|
| Host | `<your-vm-ip>` |
| Port | `5433` |
| Database | _(anything — it's ignored)_ |
| Username | Your QueryFuser dashboard username |
| Password | Your QueryFuser dashboard password |

## How It Works

1. Your BI tool connects to QueryFuser on port 5433 (PostgreSQL wire protocol)
2. QueryFuser translates PostgreSQL queries to BigQuery SQL
3. Concurrent identical queries are merged into a single BigQuery API call
4. Results are fanned out to all waiting clients
5. The dashboard on port 3001 shows query logs, merge stats, and cost savings

## HTTPS

The setup script asks for a **domain name** during installation. If you provide one, HTTPS is configured automatically with a free Let's Encrypt certificate. If you skip it (just press Enter), the dashboard runs on plain HTTP at `http://<your-ip>:3001`.

> **Why a domain?** Let's Encrypt cannot issue certificates for bare IP addresses. You need a domain (e.g. `queryfuser.example.com`) with a DNS A record pointing to your server's IP.

### Enabling HTTPS After Setup

If you skipped the domain during initial setup, you can enable HTTPS at any time:

1. Create a DNS A record pointing your domain to the server's IP address
2. Open ports **80** and **443** in your firewall
3. Run the enable script from the `deploy/` directory on your server:

```bash
bash enable-https.sh
```

It will ask for your domain and email, then provision the certificate automatically. The dashboard will then be available at `https://your-domain.com` and HTTP will redirect to HTTPS.

> **Note:** The PostgreSQL proxy (port 5433) is unchanged — it has separate TLS settings via `TLS_CERT_PATH`/`TLS_KEY_PATH` if needed.

### Certificate Renewal

Certificates expire every 90 days. To renew:

```bash
docker compose --profile https run --rm certbot renew
docker compose --profile https exec nginx nginx -s reload
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SELF_HOSTED` | ✅ | Set to `true` for self-hosted mode (uses VM service account, hides SA upload) |
| `COMPOSE_PROFILES` | ✅ | Set to `db` to run the bundled PostgreSQL container (remove when using Cloud SQL) |
| `POSTGRES_PASSWORD` | ✅ | Password for the bundled PostgreSQL container (auto-generated by setup.sh) |
| `JWT_SECRET` | ✅ | Secret key for signing JWT tokens |
| `MASTER_KEY` | ✅ | 32-byte hex key for encrypting BigQuery credentials at rest |
| `QUERYFUSER_LICENSE_KEY` | ✅ | Your license key from queryfuser.com |
| `DATABASE_URL` | | Override database connection (for Cloud SQL — see below) |
| `GOOGLE_CLIENT_ID` | | Google OAuth client ID (for Google Sign-In) |
| `GOOGLE_CLIENT_SECRET` | | Google OAuth client secret |
| `OAUTH_REDIRECT_URI` | | OAuth redirect URI |
| `API_HOST` | | API listen address (default: `0.0.0.0`) |
| `API_PORT` | | API listen port (default: `3001`) |
| `LISTEN_HOST` | | Proxy listen address (default: `0.0.0.0`) |
| `LISTEN_PORT` | | Proxy listen port (default: `5433`) |
| `TLS_CERT_PATH` | | Path to TLS certificate for proxy SSL |
| `TLS_KEY_PATH` | | Path to TLS private key for proxy SSL |
| `MAX_RESULT_ROWS` | | Max rows a query can return before being rejected (default: `500000`). Increase on large-memory servers. |
| `SMTP_HOST` | | SMTP server for password-reset emails (e.g. `smtp.gmail.com`) |
| `SMTP_PORT` | | SMTP port (default: `587`) |
| `SMTP_USER` | | SMTP username |
| `SMTP_PASSWORD` | | SMTP password or app password |
| `SMTP_FROM` | | From header (e.g. `QueryFuser <noreply@yourdomain.com>`) |
| `APP_URL` | | Base URL for reset links (e.g. `https://queryfuser.example.com`) |

## Database

By default, QueryFuser runs a **plain PostgreSQL 16 Docker container** alongside the proxy — this is _not_ Cloud SQL, just a standard PostgreSQL instance running in Docker on your VM. This is controlled by the `COMPOSE_PROFILES=db` setting in `.env`. Data is persisted in a Docker volume called `pgdata`.

This works well for most deployments. If you need managed backups, replication, or high availability, you can optionally [migrate to an external database](#migrating-to-cloud-sql) later.

### Backups

```bash
# Dump the database
docker compose exec db pg_dump -U queryfuser queryfuser > backup.sql

# Restore from a backup
cat backup.sql | docker compose exec -T db psql -U queryfuser queryfuser
```

### Migrating to Cloud SQL

If you need managed backups, replication, or high availability, you can migrate from the bundled PostgreSQL container to a Cloud SQL instance.

> **All commands below are run on your server** (GCE VM or on-prem) via SSH, in the `deploy/` directory where `docker-compose.yml` lives.

> **Note:** This same process works for **any external PostgreSQL** — Cloud SQL, Amazon RDS, Azure Database for PostgreSQL, or a self-managed PostgreSQL server. Just replace `CLOUD_SQL_IP` with your database host.

1. **Create an external PostgreSQL instance** (e.g. Cloud SQL in the same GCP region, or any PostgreSQL 14+ server your host can reach).

2. **Dump the bundled database:**
   ```bash
   docker compose exec db pg_dump -U queryfuser queryfuser > backup.sql
   ```

3. **Import into the external database** (run on the same server — it needs network access to the database host):
   ```bash
   psql -h <DB_HOST> -U postgres -c "CREATE DATABASE queryfuser;"
   psql -h <DB_HOST> -U postgres -d queryfuser < backup.sql
   ```
   > You'll need the `psql` client installed: `sudo apt-get install -y postgresql-client`

4. **Update `.env`:**
   ```bash
   # Remove (or comment out) the bundled DB profile:
   # COMPOSE_PROFILES=db

   # Point to your external database:
   DATABASE_URL=postgres://postgres:PASSWORD@DB_HOST:5432/queryfuser
   ```

5. **Restart:**
   ```bash
   docker compose down
   docker compose up -d
   ```

   The `db` container will no longer start since `COMPOSE_PROFILES` no longer includes `db`.

## On-Premises / Non-GCE Deployment

QueryFuser can also run on any Linux server (on-prem, AWS, Azure, etc.) — it doesn't require GCE. The main difference is **BigQuery authentication**: since there's no GCE metadata server, you must provide a service account JSON key for each project instead of relying on Application Default Credentials.

### Setup

1. Follow the normal [One-Line Install](#one-line-install) or [Manual Setup](#manual-setup) on your server.

2. In `.env`, **remove** `SELF_HOSTED=true` (or don't set it). This enables the service account JSON upload in the dashboard.

3. When creating a project in the dashboard, upload a GCP service account JSON key with BigQuery Data Viewer, BigQuery Job User, and BigQuery User roles. Credentials are encrypted at rest with your `MASTER_KEY`.

### Network Requirements

The server needs **outbound HTTPS** (port 443) to the following:

| Endpoint | Purpose |
|----------|---------|
| `bigquery.googleapis.com` | Execute BigQuery queries |
| `oauth2.googleapis.com` | Exchange SA credentials for access tokens |
| `www.googleapis.com` | BigQuery dataset/table metadata |
| `api.queryfuser.com` | License phone-home (every 4 hours) |

No inbound connections from Google are required. If your network uses an egress proxy or firewall allowlist, add the domains above.

### What Won't Work

- **Application Default Credentials (ADC)** — the GCE metadata server (`metadata.google.internal`) is not available off GCE. You must upload SA JSON for each project.
- **VM access scopes** — this is a GCE-only concept. On-prem, permissions are controlled entirely by the SA key's IAM roles.

Everything else (Docker, PostgreSQL, the dashboard, the proxy, merging, caching) works identically.

## Updating

```bash
docker compose pull
docker compose up -d
```

## Firewall

Make sure your firewall allows:

- **Port 5433** — from your BI tool IPs (proxy)
- **Port 3001** — from your team's IPs (dashboard, HTTP)
- **Port 80** — from anywhere (only needed for HTTPS — Let's Encrypt challenge + redirect)
- **Port 443** — from your team's IPs (dashboard, HTTPS)

## License

QueryFuser is proprietary software. Your license key phones home every 4 hours to verify validity. No query data is transmitted — only the license key and aggregate usage counters (query count and bytes processed).

## Support

Contact support@queryfuser.com for help.
