#!/usr/bin/env bash
set -euo pipefail

# ─── QueryFuser Self-Hosted Setup ─────────────────────────────────────────────
#
# This script automates the full setup:
#   1. Installs Docker (if needed)
#   2. Authenticates to the container registry
#   3. Prompts for configuration
#   4. Creates the PostgreSQL database and runs migrations
#   5. Starts QueryFuser via docker compose
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/queryfuser/deploy/main/setup.sh | bash
#
# Or clone and run:
#   git clone https://github.com/queryfuser/deploy.git && cd deploy && bash setup.sh
# ──────────────────────────────────────────────────────────────────────────────

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; exit 1; }
ask()   { echo -en "${BOLD}$1${NC}"; read -r "$2"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       QueryFuser Self-Hosted Setup           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 0. Check we're in the right directory ────────────────────────────────────

if [[ ! -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
    # If run via curl pipe, clone the repo first
    if [[ ! -d "queryfuser-deploy" ]]; then
        echo "Cloning deployment repo..."
        git clone https://github.com/queryfuser/deploy.git queryfuser-deploy
    fi
    cd queryfuser-deploy
    DEPLOY_DIR="$(pwd)"
fi
cd "$DEPLOY_DIR"

# ── 1. Docker ────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}[1/5] Checking Docker...${NC}"
if ! command -v docker &>/dev/null; then
    warn "Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    info "Docker installed. You may need to log out and back in for group changes."
else
    info "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"
fi

if ! docker compose version &>/dev/null; then
    error "docker compose plugin not found. Install it: https://docs.docker.com/compose/install/"
fi

# ── 2. Container registry auth ──────────────────────────────────────────────

echo -e "\n${BOLD}[2/5] Container registry authentication...${NC}"
if command -v gcloud &>/dev/null; then
    if ! gcloud auth print-access-token &>/dev/null 2>&1; then
        warn "Not logged in to gcloud. Running gcloud auth login..."
        gcloud auth login
    fi
    gcloud auth configure-docker us-docker.pkg.dev --quiet 2>/dev/null
    info "Authenticated to us-docker.pkg.dev"
else
    warn "gcloud CLI not found. You may need to configure Docker auth manually."
    warn "See: https://cloud.google.com/artifact-registry/docs/docker/authentication"
fi

# ── 3. Configuration ────────────────────────────────────────────────────────

echo -e "\n${BOLD}[3/5] Configuration...${NC}"

if [[ -f .env ]]; then
    warn ".env file already exists."
    ask "Overwrite? (y/N) " OVERWRITE
    if [[ "${OVERWRITE:-n}" != "y" && "${OVERWRITE:-n}" != "Y" ]]; then
        info "Keeping existing .env"
    else
        rm .env
    fi
fi

if [[ ! -f .env ]]; then
    echo ""
    ask "PostgreSQL host (Cloud SQL IP): " DB_HOST
    ask "PostgreSQL port [5432]: " DB_PORT
    DB_PORT="${DB_PORT:-5432}"
    ask "PostgreSQL user [postgres]: " DB_USER
    DB_USER="${DB_USER:-postgres}"
    ask "PostgreSQL password: " DB_PASS
    ask "Database name [queryfuser]: " DB_NAME
    DB_NAME="${DB_NAME:-queryfuser}"
    echo ""
    ask "QueryFuser license key (from queryfuser.com/deploy): " LICENSE_KEY

    if [[ -z "$LICENSE_KEY" ]]; then
        error "License key is required. Get one at https://queryfuser.com/deploy"
    fi

    # Generate secrets
    JWT_SECRET=$(openssl rand -base64 48)
    MASTER_KEY=$(openssl rand -hex 32)

    DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

    cat > .env <<EOF
DATABASE_URL=${DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
MASTER_KEY=${MASTER_KEY}
QUERYFUSER_LICENSE_KEY=${LICENSE_KEY}
EOF

    info "Generated .env with auto-generated JWT_SECRET and MASTER_KEY"
    echo ""

    # Optional: Google OAuth
    ask "Set up Google Sign-In? (y/N) " SETUP_GOOGLE
    if [[ "${SETUP_GOOGLE:-n}" == "y" || "${SETUP_GOOGLE:-n}" == "Y" ]]; then
        ask "Google Client ID: " GOOGLE_CLIENT_ID
        ask "Google Client Secret: " GOOGLE_CLIENT_SECRET
        ask "OAuth Redirect URI (e.g. https://your-domain.com/auth/google/callback): " OAUTH_REDIRECT_URI
        cat >> .env <<EOF
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
OAUTH_REDIRECT_URI=${OAUTH_REDIRECT_URI}
EOF
        info "Added Google OAuth config"
    fi
fi

# ── 4. Database setup ───────────────────────────────────────────────────────

echo -e "\n${BOLD}[4/5] Database setup...${NC}"

# Source the .env to get DATABASE_URL
set -a; source .env; set +a

# Parse DATABASE_URL
DB_USER=$(echo "$DATABASE_URL" | sed -n 's|postgres://\([^:]*\):.*|\1|p')
DB_PASS=$(echo "$DATABASE_URL" | sed -n 's|postgres://[^:]*:\([^@]*\)@.*|\1|p')
DB_HOST=$(echo "$DATABASE_URL" | sed -n 's|.*@\([^:]*\):.*|\1|p')
DB_PORT=$(echo "$DATABASE_URL" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
DB_NAME=$(echo "$DATABASE_URL" | sed -n 's|.*/\(.*\)|\1|p')

export PGPASSWORD="$DB_PASS"

# Check connectivity
if ! pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -t 5 &>/dev/null; then
    warn "Cannot reach PostgreSQL at $DB_HOST:$DB_PORT"
    warn "Make sure your Cloud SQL instance is running and the VM's IP is authorized."
    ask "Continue anyway? (y/N) " CONT
    [[ "${CONT:-n}" == "y" || "${CONT:-n}" == "Y" ]] || exit 1
else
    info "PostgreSQL reachable at $DB_HOST:$DB_PORT"

    # Create database if it doesn't exist
    if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -lqt 2>/dev/null | grep -qw "$DB_NAME"; then
        info "Creating database '$DB_NAME'..."
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;" 2>/dev/null
        info "Database created"
    else
        info "Database '$DB_NAME' already exists"
    fi

    # Run migrations
    ask "Run migrations? (Y/n) " RUN_MIG
    if [[ "${RUN_MIG:-y}" != "n" && "${RUN_MIG:-y}" != "N" ]]; then
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$DEPLOY_DIR/migrations/001_schema.sql"
        info "Migrations applied"
    fi
fi

unset PGPASSWORD

# ── 5. Start QueryFuser ─────────────────────────────────────────────────────

echo -e "\n${BOLD}[5/5] Starting QueryFuser...${NC}"

docker compose pull
docker compose up -d

echo ""

# Wait for health
echo -n "Waiting for QueryFuser to start..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:3001 &>/dev/null; then
        echo ""
        info "QueryFuser is running!"
        break
    fi
    echo -n "."
    sleep 2
done

# Get external IP
EXTERNAL_IP=$(curl -sf http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google" 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          Setup Complete! 🎉                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}  http://${EXTERNAL_IP}:3001"
echo -e "  ${BOLD}Proxy:${NC}      ${EXTERNAL_IP}:5433 (PostgreSQL)"
echo ""
echo -e "  ${BOLD}Connect your BI tool:${NC}"
echo -e "    Host:     ${EXTERNAL_IP}"
echo -e "    Port:     5433"
echo -e "    Username: (create one in the dashboard)"
echo -e "    Password: (set in the dashboard)"
echo ""
echo -e "  ${BOLD}Firewall:${NC} Make sure ports 3001 and 5433 are open."
echo ""
echo -e "  ${BOLD}Logs:${NC}      docker compose logs -f"
echo -e "  ${BOLD}Stop:${NC}      docker compose down"
echo -e "  ${BOLD}Update:${NC}    docker compose pull && docker compose up -d"
echo ""
