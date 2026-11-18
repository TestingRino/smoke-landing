#!/usr/bin/env bash
# Wire an app's secrets (Google Secret Manager = source of truth) to its Cloud Run staging service.
# The pipeline NEVER reads secret values: it only grants the app's runtime identity access and
# references the secrets by name. Values are added by people with `smokectl secret set` or the console.
#
#   per-app : smoke-<app-slug>-<KEY>   (label smoke-app=<app-slug>)
#   shared  : smoke-shared-<KEY>       (label smoke-shared=true), opted into via .smoke.yml `shared_secrets: [KEY, ...]`
#
# Output: Cloud Run --set-secrets spec in $SECRETS_SPEC. Secrets never enter the image or the signed artifact.
source "$(dirname "$0")/lib.sh"
require REPO GCP_PROJECT
SECRETS_SPEC="${SECRETS_SPEC:-${RUNNER_TEMP:-/tmp}/secrets.spec}"
: > "$SECRETS_SPEC"
G=(--project "$GCP_PROJECT" --quiet)
lbl="$(label_val "$REPO")"; prefix="smoke-$(slug "$REPO")-"
sa="$(runtime_sa_email "$REPO")"

# 1. Per-app runtime identity (one per app: an app can only read its own secrets)
if ! gcloud iam service-accounts describe "$sa" "${G[@]}" >/dev/null 2>&1; then
  log "creating runtime SA $sa"
  gcloud iam service-accounts create "$(runtime_sa_id "$REPO")" "${G[@]}" \
    --display-name "smoke runtime: ${REPO:0:60}" --description "Cloud Run identity for smoke-landing app $OWNER/$REPO"
fi

has_enabled_version() { [[ -n "$(gcloud secrets versions list "$1" "${G[@]}" --filter=state=enabled --limit=1 --format='value(name)')" ]]; }
grant() {
  local i
  for i in 1 2 3 4 5; do
    gcloud secrets add-iam-policy-binding "$1" "${G[@]}" --member "serviceAccount:$sa" \
      --role roles/secretmanager.secretAccessor >/dev/null 2>&1 && return 0
    sleep $((i * 3))   # brand-new SAs take a few seconds to become bindable
  done
  die "could not grant $sa access to $1"
}

declare -A spec
# 2. Shared secrets this app opted into
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "shared_secrets: invalid key '$key'"; continue; }
  name="smoke-shared-$key"
  if ! gcloud secrets describe "$name" "${G[@]}" >/dev/null 2>&1 || ! has_enabled_version "$name"; then
    warn "shared secret $key requested but $name has no enabled value: run 'smokectl secret set --shared $key'"; continue
  fi
  grant "$name"; spec[$key]="$name"
done < <(jq -r '(.shared_secrets // [])[]' <<< "${APP_CONFIG:-{\}}")

# 3. The app's own secrets (override shared ones with the same KEY)
while IFS= read -r full; do
  [[ -z "$full" ]] && continue
  name="${full##*/}"; key="${name#"$prefix"}"
  [[ "$name" == "$prefix"* && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$key" != PORT && "$key" != K_* ]] \
    || { warn "skipping $name (name must be ${prefix}<ENV_VAR_NAME>)"; continue; }
  has_enabled_version "$name" || { warn "skipping $name (no enabled version)"; continue; }
  grant "$name"; spec[$key]="$name"
done < <(gcloud secrets list "${G[@]}" --filter="labels.smoke-app=$lbl" --format='value(name)')

out_spec=(); for k in "${!spec[@]}"; do out_spec+=("$k=${spec[$k]}:latest"); done
(IFS=,; echo "${out_spec[*]}") > "$SECRETS_SPEC"
echo "- 🔑 ${#out_spec[@]} secret(s) wired to staging from Secret Manager: $(printf '%s ' "${!spec[@]}")" | summary
