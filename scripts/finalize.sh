#!/usr/bin/env bash
# Set the final commit status on the app repo.  Usage: finalize.sh <gate_result> <deploy_result>
source "$(dirname "$0")/lib.sh"
require REPO
[[ -n "${SHA:-}" ]] || { log "no sha resolved; nothing to report"; exit 0; }
gate="$1"; deploy="$2"
if [[ "$gate" == success && "$deploy" == success ]]; then
  set_status "$SHA" success "Live: ${APP_URL}" "$APP_URL"
elif [[ "$gate" != success ]]; then
  set_status "$SHA" failure "Blocked at DevSecOps gate ($gate)"
elif [[ "$deploy" == cancelled ]]; then
  set_status "$SHA" error "Review rejected or run cancelled"
else
  set_status "$SHA" failure "Deploy/smoke stage: $deploy"
fi
