#!/usr/bin/env bash
# Basic liveness check against the public URL.
source "$(dirname "$0")/lib.sh"
require APP_URL
hp="$(cfg health_path /)"; [[ "$hp" == /* ]] || die "health_path must start with /"
code=000
for i in $(seq 1 12); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$APP_URL$hp" || true)"
  [[ "$code" =~ ^[23] ]] && break
  log "attempt $i: HTTP $code"; sleep 5
done
if [[ "$code" =~ ^[23] ]]; then
  echo "- ✅ Smoke check \`GET $hp\` → HTTP $code" | summary
else
  echo "- ❌ Smoke check \`GET $hp\` → HTTP $code (service left running for debugging: check Cloud Run logs)" | summary
  die "smoke check failed: HTTP $code"
fi
