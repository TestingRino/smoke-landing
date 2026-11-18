#!/usr/bin/env bash
# Record this run's scanner reports in DefectDojo (findings tracker). NEVER affects the gate verdict:
# every failure is a ::warning:: and the script always exits 0.
#   defectdojo-import.sh gate   gitleaks, semgrep, trivy-fs, trivy-image   ($WORK/reports)
#   defectdojo-import.sh dast   zap-staging                                ($WORK/zap/zap.xml)
# Product = <repo>, product type = $DEFECTDOJO_PRODUCT_TYPE, engagement = $DEFECTDOJO_ENGAGEMENT (type CI/CD).
# Each tool is one test, re-imported every run: fixed findings are closed, new ones appear as new.
# Credentials: DEFECTDOJO_URL / DEFECTDOJO_TOKEN in /etc/smoke-landing/runner.env (user smoke-pipeline).
source "$(dirname "$0")/lib.sh"

main() {
  local mode="${1:-}"
  [[ -n "${WORK:-}" && -n "${REPO:-}" ]] || { warn "DefectDojo import: WORK/REPO not set"; return 0; }
  if [[ -z "${DEFECTDOJO_URL:-}" || -z "${DEFECTDOJO_TOKEN:-}" ]]; then
    log "DefectDojo not configured on this runner (DEFECTDOJO_URL/DEFECTDOJO_TOKEN); skipping"; return 0
  fi
  mask "$DEFECTDOJO_TOKEN"
  local api="${DEFECTDOJO_URL%/}/api/v2" t="${DEFECTDOJO_TIMEOUT:-30}" ti="${DEFECTDOJO_IMPORT_TIMEOUT:-120}"
  local auth=(-H "Authorization: Token $DEFECTDOJO_TOKEN")
  local pt="${DEFECTDOJO_PRODUCT_TYPE:-smoke-landing}" eng_name="${DEFECTDOJO_ENGAGEMENT:-smoke-gate}"
  local scm="https://github.com/$OWNER/$REPO" sha="${SHA:-}" ref="${REF:-}"
  [[ -n "$ref" ]] || ref="$(cfg_default_ref)"

  # Reports for this mode: file|scan type|test title
  local -a reports
  case "$mode" in
    gate) reports=("$WORK/reports/gitleaks.json|Gitleaks Scan|gitleaks"
                   "$WORK/reports/semgrep.json|Semgrep JSON Report|semgrep"
                   "$WORK/reports/trivy-fs.json|Trivy Scan|trivy-fs"
                   "$WORK/reports/trivy-image.json|Trivy Scan|trivy-image") ;;
    dast) reports=("$WORK/zap/zap.xml|ZAP Scan|zap-staging") ;;
    *) warn "defectdojo-import.sh: mode must be gate|dast"; return 0 ;;
  esac

  # Reachable? (fast fail when DefectDojo is down)
  local q
  q="$(curl -sS -f --max-time "$t" "${auth[@]}" -G "$api/product_types/" --data-urlencode "name=$pt" 2>&1)" \
    || { warn "DefectDojo unreachable at $DEFECTDOJO_URL ($q); findings not recorded this run (verdict unaffected)"; return 0; }
  local pt_id; pt_id="$(jq -r '.results[0].id // empty' <<< "$q")"
  [[ -n "$pt_id" ]] || { warn "DefectDojo product type '$pt' missing (re-run vm/defectdojo/setup.sh)"; return 0; }

  # Product + CI/CD engagement (reimport's auto-create can't set the engagement type, so create it here)
  local prod eng
  prod="$(curl -sS -f --max-time "$t" "${auth[@]}" -G "$api/products/" --data-urlencode "name=$REPO" | jq -r '.results[0].id // empty')" || prod=""
  if [[ -z "$prod" ]]; then
    prod="$(curl -sS -f --max-time "$t" "${auth[@]}" -H 'Content-Type: application/json' -X POST "$api/products/" \
      -d "$(jq -nc --arg n "$REPO" --argjson p "$pt_id" --arg u "$scm" '{name:$n, prod_type:$p, description:"Gated by smoke-landing: \($u)"}')" \
      | jq -r '.id // empty')" || prod=""
  fi
  [[ -n "$prod" ]] || { warn "DefectDojo: could not find/create product $REPO"; return 0; }
  eng="$(curl -sS -f --max-time "$t" "${auth[@]}" -G "$api/engagements/" --data-urlencode "product=$prod" --data-urlencode "name=$eng_name" \
         | jq -r '.results[0].id // empty')" || eng=""
  if [[ -z "$eng" ]]; then
    eng="$(curl -sS -f --max-time "$t" "${auth[@]}" -H 'Content-Type: application/json' -X POST "$api/engagements/" \
      -d "$(jq -nc --arg n "$eng_name" --argjson p "$prod" --arg u "$scm" --arg d "$(date -u +%F)" --arg e "$(date -u -d '+10 years' +%F)" \
            '{name:$n, product:$p, engagement_type:"CI/CD", status:"In Progress", target_start:$d, target_end:$e,
              source_code_management_uri:$u, deduplication_on_engagement:true, description:"smoke-landing gate and staging DAST"}')" \
      | jq -r '.id // empty')" || eng=""
  fi
  [[ -n "$eng" ]] || { warn "DefectDojo: could not find/create engagement $eng_name"; return 0; }

  local entry f st title resp n=0 lines=()
  for entry in "${reports[@]}"; do
    IFS='|' read -r f st title <<< "$entry"
    [[ -s "$f" ]] || { log "DefectDojo: no $(basename "$f") this run"; continue; }
    local args=(-F "scan_type=$st" -F "test_title=$title" -F "file=@$f"
      -F "product_type_name=$pt" -F "product_name=$REPO" -F "engagement_name=$eng_name" -F "auto_create_context=true"
      -F "close_old_findings=true" -F "deduplication_on_engagement=true" -F "minimum_severity=Info"
      -F "active=true" -F "verified=false" -F "scan_date=$(date -u +%F)"
      -F "build_id=${GITHUB_RUN_ID:-local}" -F "source_code_management_uri=$scm")
    [[ -n "$sha" ]] && args+=(-F "version=${sha:0:12}" -F "commit_hash=$sha")
    [[ -n "$ref" ]] && args+=(-F "branch_tag=$ref")
    if resp="$(curl -sS -f --max-time "$ti" "${auth[@]}" -X POST "$api/reimport-scan/" "${args[@]}" 2>&1)"; then
      n=$((n + 1))
      lines+=("$(jq -r --arg t "$title" '.statistics.after // {} | "\($t): \(.total.active // 0) active (\(.critical.active // 0) critical, \(.high.active // 0) high)"' <<< "$resp" 2>/dev/null || echo "$title: imported")")
    else
      warn "DefectDojo import of $title failed: ${resp:0:300}"
    fi
  done
  (( n > 0 )) || return 0
  {
    echo "- **DefectDojo** (tracker only, not the gate): [$REPO](${DEFECTDOJO_UI_URL:-$DEFECTDOJO_URL}/product/$prod), engagement \`$eng_name\`"
    printf '  - %s\n' "${lines[@]}"
    echo "  - Team access: \`gcloud compute start-iap-tunnel ${VM_NAME:-smoke-devsecops} ${DEFECTDOJO_PORT:-8088} --local-host-port=localhost:${DEFECTDOJO_PORT:-8088} --zone ${VM_ZONE:-us-central1-a} --project ${GCP_PROJECT:-}\`, then open ${DEFECTDOJO_UI_URL:-http://localhost:8088}"
  } | summary
  log "DefectDojo: $n report(s) recorded for $REPO"
}

# Branch name for the commit (REF is empty when the default branch was deployed)
cfg_default_ref() { git -C "$WORK/src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true; }

( main "$@" ) || warn "DefectDojo import failed unexpectedly (verdict unaffected)"
exit 0
