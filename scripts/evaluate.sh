#!/usr/bin/env bash
# Apply policy/gate.env to the scanner reports. A missing report BLOCKS: a scanner that crashed is not a pass.
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA
REP="$WORK/reports"

q() { local f="$REP/$1"; [[ -s "$f" ]] || die "missing scanner report $1: blocking"; jq "$2" "$f"; }

declare -A val max
val[secrets]=$(( $(q gitleaks.json 'length') + $(q trivy-fs.json '[.Results[]?.Secrets[]?]|length') + $(q trivy-image.json '[.Results[]?.Secrets[]?]|length') ))
val[sast_error]=$(q semgrep.json '[.results[]?|select(.extra.severity=="ERROR")]|length')
val[sast_warning]=$(q semgrep.json '[.results[]?|select(.extra.severity=="WARNING")]|length')
vq='[.Results[]?.Vulnerabilities[]?|select(.Severity==$s and ((.FixedVersion//"")!=""))]|unique_by(.VulnerabilityID+.PkgName)|length'
val[vuln_critical_fixable]=$(q trivy-image.json "${vq//\$s/\"CRITICAL\"}")
val[vuln_high_fixable]=$(q trivy-image.json "${vq//\$s/\"HIGH\"}")
val[misconfig_critical]=$(q trivy-fs.json '[.Results[]?.Misconfigurations[]?|select(.Severity=="CRITICAL")]|length')
val[misconfig_high]=$(q trivy-fs.json '[.Results[]?.Misconfigurations[]?|select(.Severity=="HIGH")]|length')

max[secrets]=$MAX_SECRETS;                         max[sast_error]=$MAX_SAST_ERROR
max[sast_warning]=$MAX_SAST_WARNING;               max[vuln_critical_fixable]=$MAX_VULN_CRITICAL_FIXABLE
max[vuln_high_fixable]=$MAX_VULN_HIGH_FIXABLE;     max[misconfig_critical]=$MAX_MISCONFIG_CRITICAL
max[misconfig_high]=$MAX_MISCONFIG_HIGH

verdict=pass; blocked=(); rows='[]'
for k in secrets sast_error sast_warning vuln_critical_fixable vuln_high_fixable misconfig_critical misconfig_high; do
  status=ok
  if (( max[$k] >= 0 && val[$k] > max[$k] )); then status=BLOCK; verdict=block; blocked+=("$k=${val[$k]}")
  elif (( max[$k] < 0 && val[$k] > 0 )); then status=warn; fi
  rows=$(jq -c --arg k "$k" --argjson v "${val[$k]}" --argjson m "${max[$k]}" --arg s "$status" '. + [{check:$k,count:$v,max:$m,status:$s}]' <<< "$rows")
done

jq -n --arg repo "$OWNER/$REPO" --arg sha "$SHA" --arg verdict "$verdict" --argjson checks "$rows" \
  '{repo:$repo, sha:$sha, verdict:$verdict, checks:$checks}' > "$REP/summary.json"
"$(dirname "$0")/report.sh"
out verdict "$verdict"

if [[ "$verdict" == block ]]; then
  die "Gate BLOCKED: ${blocked[*]}"
fi
log "Gate passed"
