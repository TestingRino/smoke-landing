#!/usr/bin/env bash
# Set the final commit status on the app repo.  Usage: finalize.sh <gate_result> <deploy_result>
source "$(dirname "$0")/lib.sh"
require REPO
[[ -n "${SHA:-}" ]] || { log "no sha resolved; nothing to report"; exit 0; }
gate="$1"; staging="$2"
# VERDICT / BLOCKING come from the gate job's evaluate step (empty if the gate failed before evaluating)
if [[ "$gate" == success && "$staging" == success ]]; then
  set_status "$SHA" success "Staging live: ${APP_URL}; ready for release" "$APP_URL"
elif [[ "${VERDICT:-}" == block ]]; then
  set_status "$SHA" failure "Blocked at gate: ${BLOCKING:-?} blocking findings (see issues)"
elif [[ "$gate" != success ]]; then
  set_status "$SHA" error "Gate did not complete ($gate): see the run log"
elif [[ "$staging" == cancelled ]]; then
  set_status "$SHA" error "Staging run cancelled"
else
  set_status "$SHA" failure "Staging failed (deploy, smoke check or DAST): $staging"
fi
