#!/usr/bin/env bash
# Apply policy/gate.env to reports/findings.json (see normalize.sh). Marks each finding blocking or not,
# writes reports/summary.json, renders the report, and fails the job if anything blocks.
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA
REP="$WORK/reports"
"$(dirname "$0")/normalize.sh"

# check-name | jq selector over a finding | limit
checks=(
  "secrets|.kind==\"secret\"|$MAX_SECRETS"
  "sast_high|.kind==\"sast\" and .severity==\"HIGH\"|$MAX_SAST_ERROR"
  "sast_medium|.kind==\"sast\" and .severity==\"MEDIUM\"|$MAX_SAST_WARNING"
  "vuln_critical|.kind==\"vuln\" and .severity==\"CRITICAL\" and (\$unfixed or .fixed != \"\")|$MAX_VULN_CRITICAL"
  "vuln_high|.kind==\"vuln\" and .severity==\"HIGH\" and (\$unfixed or .fixed != \"\")|$MAX_VULN_HIGH"
  "misconfig_critical|.kind==\"misconfig\" and .severity==\"CRITICAL\"|$MAX_MISCONFIG_CRITICAL"
  "misconfig_high|.kind==\"misconfig\" and .severity==\"HIGH\"|$MAX_MISCONFIG_HIGH"
)
unfixed=$([[ "$VULN_COUNT_UNFIXED" == true ]] && echo true || echo false)

verdict=pass; blocked=(); rows='[]'
cp "$REP/findings.json" "$REP/findings.tmp"
jq 'map(. + {blocking:false, check:null})' "$REP/findings.tmp" > "$REP/findings.json"
for c in "${checks[@]}"; do
  IFS='|' read -r name sel max <<< "$c"
  n=$(jq --argjson unfixed "$unfixed" "[.[] | select($sel)] | length" "$REP/findings.json")
  status=ok
  if (( max >= 0 && n > max )); then status=BLOCK; verdict=block; blocked+=("$name=$n")
  elif (( max < 0 && n > 0 )); then status=warn; fi
  blocking=$([[ $max -ge 0 ]] && echo true || echo false)
  jq --argjson unfixed "$unfixed" --arg name "$name" --argjson b "$blocking" \
    "map(if ($sel) then . + {check:\$name, blocking:\$b} else . end)" "$REP/findings.json" > "$REP/findings.tmp" \
    && mv "$REP/findings.tmp" "$REP/findings.json"
  rows=$(jq -c --arg k "$name" --argjson v "$n" --argjson m "$max" --arg s "$status" '. + [{check:$k,count:$v,max:$m,status:$s}]' <<< "$rows")
done
rm -f "$REP/findings.tmp"

jq -n --arg repo "$OWNER/$REPO" --arg sha "$SHA" --arg verdict "$verdict" --argjson checks "$rows" \
  --arg run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
  --arg at "$(date -u +%FT%TZ)" \
  --arg policy "$(sha256sum "$SMOKE_ROOT/policy/gate.env" | cut -c1-16)" \
  '{repo:$repo, commit:$sha, verdict:$verdict, checks:$checks, run:$run, evaluatedAt:$at, policyHash:$policy}' > "$REP/summary.json"
"$(dirname "$0")/report.sh"
out verdict "$verdict"
out blocking "$(jq '[.[] | select(.blocking)] | length' "$REP/findings.json")"
export_env VERDICT "$verdict"

if [[ "$verdict" == block ]]; then
  warn "Gate BLOCKED: ${blocked[*]}"
  exit 1
fi
log "Gate passed"
