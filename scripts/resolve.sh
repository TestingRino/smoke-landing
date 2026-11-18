#!/usr/bin/env bash
# Resolve repo/ref to an exact commit, clone it into a throwaway workspace, read .smoke.yml.
# In: REPO, REF (optional). Out: outputs sha, config; env WORK, SHA, APP_CONFIG.
source "$(dirname "$0")/lib.sh"
require OWNER GH_APPS_TOKEN REPO
validate_repo "$REPO"

meta="$(gh_apps api "repos/$OWNER/$REPO")" || die "cannot read $OWNER/$REPO (check GH_APPS_TOKEN scope)"
[[ "$(jq -r .archived <<< "$meta")" == "false" ]] || die "$OWNER/$REPO is archived"
ref="${REF:-$(jq -r .default_branch <<< "$meta")}"
[[ "$ref" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || die "invalid ref: '$ref'"
sha="$(gh_apps api "repos/$OWNER/$REPO/commits/$ref" --jq .sha)"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve $ref"
log "Resolved $OWNER/$REPO@$ref -> $sha"

WORK="${RUNNER_TEMP:-$(mktemp -d)}/smoke"
rm -rf "$WORK"; mkdir -p "$WORK/reports"

# Full clone (gitleaks scans history). The token goes in a one-off header and is not saved in .git/config.
auth="$(printf 'x-access-token:%s' "$GH_APPS_TOKEN" | base64 -w0)"; mask "$auth"
git -c http.extraHeader="Authorization: Basic $auth" clone --quiet --no-checkout \
  "https://github.com/$OWNER/$REPO.git" "$WORK/src"
git -C "$WORK/src" checkout --quiet --detach "$sha"

if [[ -f "$WORK/src/.smoke.yml" ]]; then
  APP_CONFIG="$(yq -o=json '.' "$WORK/src/.smoke.yml" | jq -c 'if type == "object" then . else {} end')" \
    || die ".smoke.yml is not valid YAML"
else
  APP_CONFIG='{}'
fi
log "App config: $APP_CONFIG"

export_env WORK "$WORK"
export_env SHA "$sha"
export_env REPO_PRIVATE "$(jq -r .private <<< "$meta")"
export_env APP_CONFIG "$APP_CONFIG"
out sha "$sha"
out config "$APP_CONFIG"
set_status "$sha" pending "DevSecOps gate running"
