#!/usr/bin/env bash
# Infisical (source of truth, on the VM) -> GCP Secret Manager (runtime delivery) for one app.
#  - reads folder /<repo> in INFISICAL_ENV, plus anything that folder imports (e.g. a shared /_shared folder)
#  - one GCP secret per key: smoke-<repo>-<KEY>, readable ONLY by that app's runtime service account
#  - deletes GCP secrets whose key was removed in Infisical
#  - writes the Cloud Run --set-secrets spec to $SECRETS_SPEC
# Values are piped via stdin: never in argv, logs, GitHub or Cloud Run revision config.
source "$(dirname "$0")/lib.sh"
require REPO GCP_PROJECT INFISICAL_URL INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET INFISICAL_PROJECT_ID INFISICAL_ENV
SECRETS_SPEC="${SECRETS_SPEC:-${RUNNER_TEMP:-/tmp}/secrets.spec}"
: > "$SECRETS_SPEC"
G=(--project "$GCP_PROJECT" --quiet)
lbl="$(label_val "$REPO")"
sa="$(runtime_sa_email "$REPO")"

# 1. Per-app runtime identity ---------------------------------------------------
if ! gcloud iam service-accounts describe "$sa" "${G[@]}" >/dev/null 2>&1; then
  log "creating runtime SA $sa"
  gcloud iam service-accounts create "$(runtime_sa_id "$REPO")" "${G[@]}" \
    --display-name "smoke runtime: ${REPO:0:60}" --description "Cloud Run identity for smoke-landing app $OWNER/$REPO"
fi

# 2. Fetch from Infisical --------------------------------------------------------
token="$(curl -fsS -X POST "$INFISICAL_URL/api/v1/auth/universal-auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$INFISICAL_CLIENT_ID" --arg s "$INFISICAL_CLIENT_SECRET" '{clientId:$id, clientSecret:$s}')" \
  | jq -r .accessToken)" || die "Infisical login failed"
[[ -n "$token" && "$token" != null ]] || die "Infisical login returned no token"
mask "$token"

path="$(infisical_path "$REPO")"
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(curl -sS -o "$body" -w '%{http_code}' -G "$INFISICAL_URL/api/v3/secrets/raw" -H "Authorization: Bearer $token" \
  --data-urlencode "workspaceId=$INFISICAL_PROJECT_ID" --data-urlencode "environment=$INFISICAL_ENV" \
  --data-urlencode "secretPath=$path" --data-urlencode "expandSecretReferences=true" --data-urlencode "include_imports=true")"
case "$code" in
  200) ;;
  404) warn "Infisical folder $path not found: deploying with no secrets"; echo '{"secrets":[]}' > "$body" ;;
  *)   die "Infisical returned HTTP $code for $path" ;;
esac
# imported secrets first, the app's own folder overrides
entries="$(jq -r '[(.imports // [])[].secrets[]?, .secrets[]] | map({key:.secretKey, value:.secretValue}) | from_entries
                  | to_entries[] | [.key, (.value|@base64)] | @tsv' "$body")"

# 3. Upsert into Secret Manager ------------------------------------------------
declare -A keep; spec=()
while IFS=$'\t' read -r key b64; do
  [[ -z "$key" ]] && continue
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || "$key" == PORT || "$key" == K_* ]]; then
    warn "skipping Infisical key '$key' (not a valid/allowed env var name)"; continue
  fi
  value="$(base64 -d <<< "$b64")"; mask "$value"
  name="$(secret_name "$REPO" "$key")"; keep[$name]=1
  vhash="$(printf '%s' "$value" | sha256sum | cut -c1-40)"

  if ! gcloud secrets describe "$name" "${G[@]}" >/dev/null 2>&1; then
    gcloud secrets create "$name" "${G[@]}" --replication-policy automatic \
      --labels "managed-by=smoke-landing,smoke-app=$lbl" >/dev/null
  fi
  if [[ "$(gcloud secrets describe "$name" "${G[@]}" --format='value(labels.vhash)')" != "$vhash" ]]; then
    printf '%s' "$value" | gcloud secrets versions add "$name" "${G[@]}" --data-file=- >/dev/null
    gcloud secrets update "$name" "${G[@]}" --update-labels "vhash=$vhash" >/dev/null
    log "updated $key"
  fi
  for i in 1 2 3 4 5; do   # new SAs take a few seconds to become bindable
    gcloud secrets add-iam-policy-binding "$name" "${G[@]}" --member "serviceAccount:$sa" \
      --role roles/secretmanager.secretAccessor >/dev/null 2>&1 && break
    (( i == 5 )) && die "could not grant $sa access to $name"; sleep $((i * 3))
  done
  spec+=("$key=$name:latest")
done <<< "$entries"

# 4. Prune keys deleted in Infisical -------------------------------------------
while IFS= read -r full; do
  [[ -z "$full" ]] && continue
  n="${full##*/}"
  if [[ -z "${keep[$n]:-}" ]]; then log "deleting removed secret $n"; gcloud secrets delete "$n" "${G[@]}" >/dev/null; fi
done < <(gcloud secrets list "${G[@]}" --filter="labels.smoke-app=$lbl" --format='value(name)')

(IFS=,; echo "${spec[*]}") > "$SECRETS_SPEC"
log "${#spec[@]} secret(s) synced for $REPO"
