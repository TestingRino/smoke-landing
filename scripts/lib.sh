#!/usr/bin/env bash
# Shared helpers. Source this file; don't execute it.
set -euo pipefail

SMOKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../smoke.config.env
source "$SMOKE_ROOT/smoke.config.env"
# shellcheck source=../policy/gate.env
source "$SMOKE_ROOT/policy/gate.env"

# VM-local credentials: GH_APPS_TOKEN, INFISICAL_URL, INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET.
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
image_remote() { echo "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${AR_REPO}/$(slug "$1")"; }
secret_name() { echo "smoke-$(slug "$1")-$2"; }
infisical_path() { echo "/$(echo "$1" | sed -E 's/[^A-Za-z0-9_-]/-/g')"; }

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
