#!/usr/bin/env bash
# After staging deploy + smoke check + DAST succeed: attest that this exact digest ran live in staging.
# Release requires this attestation. (Secrets are NOT part of the artifact: Cloud Run injects them at runtime.)
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA DIGEST APP_URL KMS_KEY
ref="$(image_remote "$REPO")@$DIGEST"
zap="$WORK/zap/zap.json"
high=null; med=null
if [[ -s "$zap" ]]; then
  high=$(jq '[.site[]?.alerts[]? | select(.riskcode=="3")] | length' "$zap")
  med=$(jq '[.site[]?.alerts[]? | select(.riskcode=="2")] | length' "$zap")
fi
jq -n --arg url "$APP_URL" --arg sha "$SHA" --arg digest "$DIGEST" --argjson high "$high" --argjson med "$med" \
  --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  --arg at "$(date -u +%FT%TZ)" --arg hp "$(cfg health_path /)" \
  '{environment:"staging", url:$url, commit:$sha, digest:$digest, smokeCheck:{path:$hp, result:"pass"},
    dast:{tool:"zap-baseline", high:$high, medium:$med}, verdict:"pass", run:$run, deployedAt:$at}' > "$WORK/staging-predicate.json"
attest "$ref" "$WORK/staging-predicate.json" "$ATTEST_STAGING_TYPE"
echo "- ✍️ Staging attestation signed: ready for release (\`smokectl release $REPO ${SHA:0:12}\`)" | summary
