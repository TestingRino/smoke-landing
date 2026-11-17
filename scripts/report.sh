#!/usr/bin/env bash
# Render the gate report for human reviewers (job summary + reports/report.md). Never prints secret values.
source "$(dirname "$0")/lib.sh"
require WORK
REP="$WORK/reports"; S="$REP/summary.json"
top() { local f="$REP/$1"; [[ -s "$f" ]] && jq -r "$2" "$f" | head -n 15; return 0; }

{
  echo "## Smoke gate: \`$(jq -r .repo "$S")\` @ \`$(jq -r '.sha[0:12]' "$S")\`"
  echo
  if [[ "$(jq -r .verdict "$S")" == pass ]]; then echo "### ✅ PASS (awaiting human review before deploy)"; else echo "### ⛔ BLOCKED"; fi
  echo
  echo "| Check | Count | Limit | Result |"
  echo "|---|---:|---:|---|"
  jq -r '.checks[] | "| \(.check) | \(.count) | \(if .max < 0 then "report only" else .max end) | \(.status) |"' "$S"
  echo
  echo "<details><summary>Secrets (redacted)</summary>"; echo
  top gitleaks.json '.[] | "- `\(.RuleID)` \(.File):\(.StartLine) (commit \(.Commit[0:8]), fingerprint `\(.Fingerprint)`)"'
  top trivy-fs.json '.Results[]? | .Target as $t | .Secrets[]? | "- `\(.RuleID)` \($t):\(.StartLine)"'
  top trivy-image.json '.Results[]? | .Target as $t | .Secrets[]? | "- image `\(.RuleID)` \($t)"'
  echo "</details>"; echo
  echo "<details><summary>SAST errors</summary>"; echo
  top semgrep.json '.results[]? | select(.extra.severity=="ERROR") | "- `\(.check_id)` \(.path | sub("^/src/";"")):\(.start.line)"'
  echo "</details>"; echo
  echo "<details><summary>Fixable CRITICAL/HIGH CVEs in image</summary>"; echo
  top trivy-image.json '[.Results[]?.Vulnerabilities[]? | select((.Severity=="CRITICAL" or .Severity=="HIGH") and ((.FixedVersion//"")!=""))] | unique_by(.VulnerabilityID+.PkgName) | sort_by(.Severity) | .[] | "- **\(.Severity)** \(.VulnerabilityID) `\(.PkgName)` \(.InstalledVersion) → \(.FixedVersion)"'
  echo "</details>"; echo
  echo "<details><summary>Misconfigurations (CRITICAL/HIGH)</summary>"; echo
  top trivy-fs.json '.Results[]? | .Target as $t | .Misconfigurations[]? | select(.Severity=="CRITICAL" or .Severity=="HIGH") | "- **\(.Severity)** \(.ID) \($t): \(.Title)"'
  echo "</details>"; echo
  echo "Full reports + SBOM are in the run artifact \`gate-reports\`. Exceptions: \`policy/exceptions/<repo>/\`."
} > "$REP/report.md"
summary < "$REP/report.md"
