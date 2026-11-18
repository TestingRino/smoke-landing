#!/usr/bin/env bash
# Render the gate report (job summary + reports/report.md) from summary.json + findings.json.
# Never prints secret values (scanners run with redaction; findings carry rule + location only).
source "$(dirname "$0")/lib.sh"
require WORK
REP="$WORK/reports"; S="$REP/summary.json"; F="$REP/findings.json"

{
  echo "## Smoke gate: \`$(jq -r .repo "$S")\` @ \`$(jq -r '.commit[0:12]' "$S")\`"
  echo
  if [[ "$(jq -r .verdict "$S")" == pass ]]; then
    echo "### ✅ PASS: no critical/high issues. Deploying to staging."
  else
    echo "### ⛔ BLOCKED: fix the issues below (filed as GitHub issues in the app repo, label \`smoke-gate\`)"
  fi
  echo
  echo "| Check | Count | Limit | Result |"
  echo "|---|---:|---:|---|"
  jq -r '.checks[] | "| \(.check) | \(.count) | \(if .max < 0 then "report only" else .max end) | \(.status) |"' "$S"
  echo
  for kind in secret sast vuln misconfig; do
    n=$(jq --arg k "$kind" '[.[] | select(.kind==$k and .blocking)] | length' "$F")
    (( n == 0 )) && continue
    echo "<details><summary><b>$kind</b>: $n blocking</summary>"; echo
    jq -r --arg k "$kind" '[.[] | select(.kind==$k and .blocking)] | sort_by(.severity) | .[0:25][]
      | "- **\(.severity)** \(.title) · `\(.location)`"' "$F"
    (( n > 25 )) && echo "- … and $((n - 25)) more (see \`findings.json\` in the gate-reports artifact)"
    echo "</details>"; echo
  done
  echo "Artifacts: \`gate-reports\` (raw reports, findings.json, SBOM). Exceptions: \`policy/exceptions/<repo>/\`."
} > "$REP/report.md"
summary < "$REP/report.md"
