#!/usr/bin/env bash
# Deploy the scanned image (by digest) to Cloud Run with a public URL.
source "$(dirname "$0")/lib.sh"
require REPO SHA DIGEST GCP_PROJECT GCP_REGION
SECRETS_SPEC="${SECRETS_SPEC:-${RUNNER_TEMP:-/tmp}/secrets.spec}"

svc="$(svc_name "$REPO")"; sa="$(runtime_sa_email "$REPO")"
port="$(cfg port 8080)";             [[ "$port" =~ ^[0-9]{2,5}$ ]]          || die "bad port: $port"
memory="$(cfg memory 512Mi)";        [[ "$memory" =~ ^[0-9]+(Mi|Gi)$ ]]     || die "bad memory: $memory"
cpu="$(cfg cpu 1)";                  [[ "$cpu" =~ ^([0-9]+(\.[0-9]+)?|[0-9]+m)$ ]] || die "bad cpu: $cpu"
maxi="$(cfg max_instances 1)";       [[ "$maxi" =~ ^[0-9]+$ ]]              || die "bad max_instances: $maxi"
(( maxi <= MAX_INSTANCES_CAP )) || { warn "max_instances capped at $MAX_INSTANCES_CAP"; maxi=$MAX_INSTANCES_CAP; }

# Non-secret env vars from .smoke.yml `env:` (JSON is valid YAML for --env-vars-file)
envfile="$(mktemp)"; trap 'rm -f "$envfile"' EXIT
jq --arg sha "$SHA" '(.env // {}) | to_entries
    | map(select(.key|test("^[A-Za-z_][A-Za-z0-9_]*$")) | select(.key != "PORT") | .value |= tostring)
    | from_entries + {SMOKE_COMMIT: $sha}' <<< "${APP_CONFIG:-{\}}" > "$envfile"

args=(run deploy "$svc" --project "$GCP_PROJECT" --region "$GCP_REGION" --quiet
  --image "$(image_remote "$REPO")@$DIGEST"
  --service-account "$sa" --port "$port" --memory "$memory" --cpu "$cpu"
  --min-instances 0 --max-instances "$maxi"
  --allow-unauthenticated --ingress all
  --env-vars-file "$envfile"
  --labels "managed-by=smoke-landing,smoke-app=$(label_val "$REPO"),commit=${SHA:0:12},deployed-at=$(date +%s)")
if [[ -s "$SECRETS_SPEC" && -n "$(cat "$SECRETS_SPEC")" ]]; then args+=(--set-secrets "$(cat "$SECRETS_SPEC")"); else args+=(--clear-secrets); fi

log "deploying $svc"
gcloud "${args[@]}"
url="$(gcloud run services describe "$svc" --project "$GCP_PROJECT" --region "$GCP_REGION" --format='value(status.url)')"
log "live at $url"
out url "$url"
export_env APP_URL "$url"
