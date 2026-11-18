#!/usr/bin/env bash
# OWASP ZAP baseline (passive) scan of the live URL. Optionally revokes public access on High-risk alerts.
source "$(dirname "$0")/lib.sh"
require APP_URL REPO WORK
zap="$(cfg zap "$ZAP_ENABLED")"
[[ "$zap" == true ]] || { log "ZAP disabled"; exit 0; }

dir="$WORK/zap"; mkdir -p "$dir"; chmod 777 "$dir"
rc=0
docker run --rm -v "$dir:/zap/wrk:rw" "$ZAP_IMAGE" zap-baseline.py -t "$APP_URL" -J zap.json -x zap.xml -r zap.html -I || rc=$?
[[ -s "$dir/zap.json" ]] || { warn "ZAP produced no report (exit $rc)"; exit 0; }

high=$(jq '[.site[]?.alerts[]? | select(.riskcode=="3")] | length' "$dir/zap.json")
med=$(jq '[.site[]?.alerts[]? | select(.riskcode=="2")] | length' "$dir/zap.json")
{
  echo "- ZAP baseline: **$high high**, $med medium alerts (report in artifact \`dast-report\`)"
  jq -r '.site[]?.alerts[]? | select(.riskcode=="3" or .riskcode=="2") | "  - \(.riskdesc): \(.name)"' "$dir/zap.json" | head -n 15
} | summary

if (( high > 0 )) && [[ "$ZAP_BLOCK_ON_HIGH" == true ]]; then
  gcloud run services remove-iam-policy-binding "$(svc_name "$REPO")" --project "$GCP_PROJECT" --region "$GCP_REGION" \
    --member allUsers --role roles/run.invoker --quiet >/dev/null
  echo "- ⛔ Public access REVOKED due to High-risk ZAP alerts" | summary
  die "ZAP high-risk alerts: public access revoked"
fi
