#!/usr/bin/env bash
# Shared helpers. Source this file; don't execute it.
set -euo pipefail

SMOKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../smoke.config.env
source "$SMOKE_ROOT/smoke.config.env"
# shellcheck source=../policy/gate.env
source "$SMOKE_ROOT/policy/gate.env"

# VM-local credentials: GH_APPS_TOKEN.
# They never live in git or in GitHub secrets.
SMOKE_RUNNER_ENV="${SMOKE_RUNNER_ENV:-/etc/smoke-landing/runner.env}"
if [[ -r "$SMOKE_RUNNER_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$SMOKE_RUNNER_ENV"
fi

OWNER="${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"

log()  { echo "[smoke] $*" >&2; }
warn() { echo "::warning::$*" >&2; }
die()  { echo "::error::$*" >&2; exit 1; }

require() { local v; for v in "$@"; do [[ -n "${!v:-}" ]] || die "$v is not set (smoke.config.env or $SMOKE_RUNNER_ENV)"; done; }

# Write a step output / env var when running under GitHub Actions.
out()     { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }
export_env() { if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$1=$2" >> "$GITHUB_ENV"; fi; export "$1=$2"; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat >&2; fi; }

# Mask a (possibly multi-line) value in Actions logs.
mask() { local line; while IFS= read -r line; do [[ -n "$line" ]] && echo "::add-mask::$line"; done <<< "$1"; return 0; }

validate_repo() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || die "invalid repo name: '$1'"; }

gh_apps() { require GH_APPS_TOKEN; GH_TOKEN="$GH_APPS_TOKEN" gh "$@"; }

# Name derivations ------------------------------------------------------------
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'; }
label_val() { local s; s="$(slug "$1")"; s="${s:0:63}"; echo "${s%-}"; }

svc_name() {   # Cloud Run: <=49 chars, starts with a letter
  local s; s="smoke-$(slug "$1")"; s="${s:0:49}"; echo "${s%-}"
}
runtime_sa_id() {   # IAM SA id: 6-30 chars. One runtime identity per app, so apps can't read each other's secrets.
  local s h; s="$(slug "$1")"; s="${s:0:18}"; s="${s%-}"
  h="$(printf '%s' "$1" | sha256sum | cut -c1-6)"
  echo "sm-${s}-${h}"
}
runtime_sa_email() { echo "$(runtime_sa_id "$1")@${GCP_PROJECT}.iam.gserviceaccount.com"; }
# AR_HOST can be overridden (tests use a local registry); in production it's <region>-docker.pkg.dev.
ar_host() { echo "${AR_HOST:-${GCP_REGION}-docker.pkg.dev}"; }
image_remote()   { echo "$(ar_host)/${GCP_PROJECT}/${AR_REPO}/$(slug "$1")"; }        # staging (every passing build)
release_remote() { echo "$(ar_host)/${GCP_PROJECT}/${RELEASE_REPO}/$(slug "$1")"; }  # promoted only; the boundary reads this
secret_name() { echo "smoke-$(slug "$1")-$2"; }

# App config (.smoke.yml, as compact JSON in $APP_CONFIG) ----------------------
cfg() { jq -r --arg k "$1" --arg d "$2" '(.[$k] // $d) | tostring' <<< "${APP_CONFIG:-{\}}"; }

# GitHub commit status on the app repo ---------------------------------------
set_status() {   # sha state description [target_url]
  local sha="$1" state="$2" desc="$3"
  local url="${4:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}}"
  gh_apps api -X POST "repos/$OWNER/$REPO/statuses/$sha" \
    -f state="$state" -f context="$STATUS_CONTEXT" -f description="${desc:0:139}" -f target_url="$url" >/dev/null \
    || warn "could not set commit status on $OWNER/$REPO@$sha"
}

docker_user() { echo "$(id -u):$(id -g)"; }

# Signing (cosign + Cloud KMS). No public transparency log: repo names/digests stay private.
COSIGN_FLAGS=(--tlog-upload=false --yes)
# SMOKE_SIGNING_KEY / SMOKE_PUBKEY_FILE: test-only overrides (a local cosign key pair instead of Cloud KMS).
PUBKEY_FILE="${SMOKE_PUBKEY_FILE:-$SMOKE_ROOT/keys/smoke-landing-signing.pub}"
sign_key()   { echo "${SMOKE_SIGNING_KEY:-$KMS_KEY}"; }
verify_key() { if [[ -s "$PUBKEY_FILE" ]]; then echo "$PUBKEY_FILE"; else sign_key; fi; }
attest() {   # ref predicate-file type
  cosign attest --key "$(sign_key)" "${COSIGN_FLAGS[@]}" --type "$3" --predicate "$2" "$1" >/dev/null
}
# All VERIFIED predicates of one attestation type on ref, as a JSON array (empty array if none verify).
# Callers select by content (digest, commit, timestamps): cosign returns attestations in no guaranteed order.
read_attestations() {   # ref type
  local out
  out="$(cosign verify-attestation --key "$(verify_key)" --insecure-ignore-tlog=true --type "$2" "$1" 2>/dev/null)" || { echo '[]'; return 0; }
  jq -s 'map(.payload | @base64d | fromjson | .predicate)' <<< "$out"
}
# Digest of a signed image: verifies the signature and returns the digest it covers (fails if unsigned).
signed_digest() {   # ref (tag or digest); prints nothing (and succeeds) if it isn't validly signed
  { cosign verify --key "$(verify_key)" --insecure-ignore-tlog=true "$1" 2>/dev/null || echo '[]'; } \
    | jq -r '[.[].critical.image["docker-manifest-digest"]] | unique | if length == 1 then .[0] else empty end'
}
