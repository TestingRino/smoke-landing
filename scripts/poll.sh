#!/usr/bin/env bash
# Find opted-in repos whose default-branch HEAD has not been through the gate yet, and dispatch deploys.
# shellcheck disable=SC2054  # commas are inside single CLI arguments
# "Been through the gate" = the commit already carries a $STATUS_CONTEXT status. No changes needed in app repos.
source "$(dirname "$0")/lib.sh"
require OWNER GH_APPS_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY

list=(repo list "$OWNER" --no-archived --source --limit 1000 --json name,defaultBranchRef)
[[ "$ALL_REPOS" == true ]] || list+=(--topic "$OPT_IN_TOPIC")
mapfile -t excluded < <(grep -vE '^\s*(#|$)' "$SMOKE_ROOT/policy/exclude.txt" || true)

dispatched=0
while IFS=$'\t' read -r name branch; do
  [[ -z "$name" || -z "$branch" ]] && continue
  [[ "$OWNER/$name" == "$GITHUB_REPOSITORY" ]] && continue
  printf '%s\n' "${excluded[@]}" | grep -qxF "$name" && continue
  sha="$(gh_apps api "repos/$OWNER/$name/commits/$branch" --jq .sha 2>/dev/null)" || continue
  seen="$(gh_apps api "repos/$OWNER/$name/commits/$sha/statuses?per_page=100" | jq --arg c "$STATUS_CONTEXT" '[.[]|select(.context==$c)]|length')"
  (( seen > 0 )) && continue
  if (( dispatched >= MAX_DISPATCH_PER_POLL )); then log "dispatch cap reached; $name waits for next poll"; continue; fi
  log "dispatching $name@${sha:0:12}"
  GH_TOKEN="$GITHUB_TOKEN" gh workflow run deploy.yml -R "$GITHUB_REPOSITORY" -f repo="$name" -f ref="$sha"
  REPO="$name" set_status "$sha" pending "Queued for DevSecOps gate"
  dispatched=$((dispatched + 1))
done < <(gh_apps "${list[@]}" --jq '.[] | [.name, (.defaultBranchRef.name // "")] | @tsv')
echo "Dispatched $dispatched deploy(s)." | summary
