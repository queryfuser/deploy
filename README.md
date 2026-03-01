# QueryFuser — Self-Hosted Deployment

QueryFuser is a PostgreSQL-compatible proxy that intercepts queries from your BI tools, translates them to BigQuery SQL, and **merges concurrent identical queries** to reduce BigQuery costs.

## One-Line Install

SSH into your GCE VM and run:

```bash
git clone https://github.com/queryfuser/deploy.git && cd deploy && bash setup.sh
```

The setup script will:
1. Install Docker (if needed)
2. Authenticate to the container registry
3. Prompt for your database and license key
4. Auto-generate JWT secret and encryption key
5. Create the database and run migrations
6. Pull and start QueryFuser

## Manual Setup

If you prefer to set things up yourself:

### Prerequisites

- A **GCP project** with BigQuery enabled
- A **Cloud SQL PostgreSQL** instance (or any PostgreSQL 14+)
- A **GCE VM** (e2-small or larger) with Docker installed
- A **QueryFuser license key** from [queryfuser.com](https://queryfuser.com)

### Quick Start

### 1. Create the database

```bash
psql -h <YOUR_DB_HOST> -U postgres -c "CREATE DATABASE queryfuser;"
```

### 2. Configure environment

```bash
cp .env.example .env
# Edit .env with your values
```

### 3. Authenticate to the container registry

```bash
gcloud auth configure-docker us-docker.pkg.dev
```

### 4. Start QueryFuser

```bash
docker compose up -d
```

Database tables are created automatically on first startup. Schema migrations are also applied automatically on updates.

## Ports

| Port | Service |
|------|---------|
| **3001** | Dashboard (web UI + API) |
| **5433** | PostgreSQL proxy (point your BI tool here) |

## Connecting your BI tool

Configure your BI tool (Looker, Metabase, Tableau, etc.) as a PostgreSQL connection:

| Setting | Value |
|---------|-------|
| Host | `<your-vm-ip>` |
| Port | `5433` |
| Database | _(anything — it's ignored)_ |
| Username | Your QueryFuser dashboard username |
| Password | Your QueryFuser dashboard password |

## How it works

1. Your BI tool connects to QueryFuser on port 5433 (PostgreSQL wire protocol)
2. QueryFuser translates PostgreSQL queries to BigQuery SQL
3. Concurrent identical queries are merged into a single BigQuery API call
4. Results are fanned out to all waiting clients
5. The dashboard on port 3001 shows query logs, merge stats, and cost savings

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | ✅ | PostgreSQL connection string for QueryFuser's own database |
| `JWT_SECRET` | ✅ | Secret key for signing JWT tokens (any random string, 32+ chars) |
| `MASTER_KEY` | ✅ | 32-byte hex key for encrypting BigQuery credentials at rest |
| `QUERYFUSER_LICENSE_KEY` | ✅ | Your license key from queryfuser.com |
| `GCP_PROJECT_ID` | | Default GCP project for BigQuery |
| `GOOGLE_CLIENT_ID` | | Google OAuth client ID (for Google Sign-In) |
| `GOOGLE_CLIENT_SECRET` | | Google OAuth client secret |
| `OAUTH_REDIRECT_URI` | | OAuth redirect URI (e.g. `https://your-domain.com/auth/google/callback`) |
| `API_HOST` | | API listen address (default: `0.0.0.0`) |
| `API_PORT` | | API listen port (default: `3001`) |
| `LISTEN_HOST` | | Proxy listen address (default: `0.0.0.0`) |
| `LISTEN_PORT` | | Proxy listen port (default: `5433`) |
| `TLS_CERT_PATH` | | Path to TLS certificate for proxy SSL |
| `TLS_KEY_PATH` | | Path to TLS private key for proxy SSL |

## Generating a Master Key

```bash
openssl rand -hex 32
```

## Generating a JWT Secret

```bash
openssl rand -base64 48
```

## Updating

```bash
docker compose pull
docker compose up -d
```

## Firewall

Make sure your GCE VM firewall allows:

- **Port 5433** — from your BI tool IPs (proxy)
- **Port 3001** — from your team's IPs (dashboard)

## License

QueryFuser is proprietary software. Your license key phones home every 4 hours to verify validity. No query data is transmitted — only the license key and aggregate usage counters (query count and bytes processed).

## Support

Contact support@queryfuser.com for help.
