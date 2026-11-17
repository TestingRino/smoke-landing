#!/usr/bin/env bash
# Generate a .env with strong random keys (once) and start Infisical.
# BACK UP .env: losing ENCRYPTION_KEY makes every stored secret unrecoverable.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .env ]]; then
  umask 077
  pw="$(openssl rand -hex 24)"
  cat > .env <<EOF
# Pin to a specific release tag from https://hub.docker.com/r/infisical/infisical/tags
INFISICAL_VERSION=latest
ENCRYPTION_KEY=$(openssl rand -hex 16)
AUTH_SECRET=$(openssl rand -base64 32)
SITE_URL=http://localhost:8080
POSTGRES_USER=infisical
POSTGRES_PASSWORD=$pw
POSTGRES_DB=infisical
DB_CONNECTION_URI=postgres://infisical:$pw@db:5432/infisical
REDIS_URL=redis://redis:6379
TELEMETRY_ENABLED=false
EOF
  echo "Wrote $(pwd)/.env: back it up somewhere safe (password manager)."
fi
docker compose up -d
echo "Infisical starting on 127.0.0.1:8080 (first boot runs DB migrations, ~1 min)."
