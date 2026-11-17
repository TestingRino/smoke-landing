#!/usr/bin/env bash
# Tear down an app: Cloud Run service, its GCP secrets, runtime SA and images. Infisical is left untouched.
#   teardown.sh <repo>        one app
#   teardown.sh --expired     every smoke service not redeployed within TTL_DAYS
source "$(dirname "$0")/lib.sh"
require GCP_PROJECT GCP_REGION
G=(--project "$GCP_PROJECT" --quiet)

teardown() {   # service app-label runtime-sa
  local svc="$1" lbl="$2" sa="$3" n
  log "tearing down $svc"
  gcloud run services delete "$svc" "${G[@]}" --region "$GCP_REGION" >/dev/null 2>&1 || true
  while IFS= read -r n; do [[ -n "$n" ]] && gcloud secrets delete "${n##*/}" "${G[@]}" >/dev/null; done \
    < <(gcloud secrets list "${G[@]}" --filter="labels.smoke-app=$lbl" --format='value(name)')
  [[ "$sa" == sm-*@"$GCP_PROJECT".iam.gserviceaccount.com ]] && gcloud iam service-accounts delete "$sa" "${G[@]}" >/dev/null 2>&1 || true
  gcloud artifacts packages delete "$lbl" "${G[@]}" --repository "$AR_REPO" --location "$GCP_REGION" >/dev/null 2>&1 || true
  echo "- 🗑️ \`$svc\` removed" | summary
}

if [[ "${1:-}" == --expired ]]; then
  cutoff=$(( $(date +%s) - TTL_DAYS * 86400 ))
  gcloud run services list "${G[@]}" --region "$GCP_REGION" --filter="metadata.labels.managed-by=smoke-landing" --format=json \
  | jq -r --argjson c "$cutoff" '.[] | select(((.metadata.labels["deployed-at"] // "0") | tonumber) < $c)
        | [.metadata.name, .metadata.labels["smoke-app"], (.spec.template.spec.serviceAccountName // "")] | @tsv' \
  | while IFS=$'\t' read -r svc lbl sa; do teardown "$svc" "$lbl" "$sa"; done
else
  REPO="${1:?usage: teardown.sh <repo>|--expired}"; validate_repo "$REPO"
  teardown "$(svc_name "$REPO")" "$(label_val "$REPO")" "$(runtime_sa_email "$REPO")"
fi
