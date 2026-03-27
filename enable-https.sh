#!/usr/bin/env bash
set -euo pipefail

# ─── QueryFuser HTTPS Setup ─────────────────────────────────────────────────
#
# This script sets up HTTPS for the QueryFuser dashboard using Let's Encrypt.
# Run it AFTER the main setup.sh has been run and QueryFuser is already running.
#
# Prerequisites:
#   - A domain name pointing to this server's IP address
#   - Ports 80 and 443 open in the firewall
#
# Usage:
#   bash enable-https.sh
# ──────────────────────────────────────────────────────────────────────────────

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

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
echo -e "${BOLD}║       QueryFuser HTTPS Setup                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Check QueryFuser is running
if ! docker compose ps --status running | grep -q queryfuser; then
    error "QueryFuser is not running. Run setup.sh first, then come back here."
fi

# Get domain name
ask "Enter your domain name (e.g. queryfuser.example.com): " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    error "Domain name is required."
fi

# Get email for Let's Encrypt
ask "Email address for Let's Encrypt notifications: " EMAIL

if [[ -z "$EMAIL" ]]; then
    error "Email address is required for Let's Encrypt."
fi

echo ""
echo -e "${BOLD}[1/4] Preparing nginx config...${NC}"

# Generate nginx.conf from template by substituting $DOMAIN
sed "s/\${DOMAIN}/$DOMAIN/g" nginx.conf > nginx-generated.conf
info "Generated nginx config for $DOMAIN"

echo -e "${BOLD}[2/4] Getting initial certificate...${NC}"

# Create required directories
mkdir -p certbot/www certbot/conf

# Start nginx with a temporary self-signed cert so certbot can do the HTTP challenge
# First, create a temporary self-signed cert
mkdir -p "certbot/conf/live/$DOMAIN"
if [[ ! -f "certbot/conf/live/$DOMAIN/fullchain.pem" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
        -keyout "certbot/conf/live/$DOMAIN/privkey.pem" \
        -out "certbot/conf/live/$DOMAIN/fullchain.pem" \
        -subj "/CN=$DOMAIN" 2>/dev/null
    info "Created temporary self-signed certificate"
fi

# Add DOMAIN to .env if not already there
if ! grep -q "^DOMAIN=" .env 2>/dev/null; then
    echo "" >> .env
    echo "# Domain for HTTPS (set by enable-https.sh)" >> .env
    echo "DOMAIN=$DOMAIN" >> .env
    info "Added DOMAIN=$DOMAIN to .env"
fi

# Start nginx
docker compose --profile https up -d nginx
info "Started nginx"

# Wait a moment for nginx to be ready
sleep 3

# Request real certificate from Let's Encrypt
echo -e "${BOLD}[3/4] Requesting Let's Encrypt certificate...${NC}"

docker compose --profile https run --rm certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    -d "$DOMAIN"

info "Certificate obtained!"

echo -e "${BOLD}[4/4] Reloading nginx with real certificate...${NC}"

# Reload nginx to pick up the real cert
docker compose --profile https exec nginx nginx -s reload
info "Nginx reloaded with Let's Encrypt certificate"

# Update APP_URL in .env for password reset links
if grep -q "^APP_URL=" .env; then
    sed -i "s|^APP_URL=.*|APP_URL=https://$DOMAIN|" .env
else
    echo "APP_URL=https://$DOMAIN" >> .env
fi
info "Set APP_URL=https://$DOMAIN"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       HTTPS Enabled! 🔒                      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}  https://$DOMAIN"
echo -e "  ${BOLD}Proxy:${NC}      $DOMAIN:5433 (PostgreSQL — unchanged)"
echo ""
echo -e "  Certificates auto-renew via the certbot container."
echo -e "  HTTP (port 80) redirects to HTTPS automatically."
echo ""
echo -e "  ${YELLOW}Make sure ports 80 and 443 are open in your firewall.${NC}"
echo ""
