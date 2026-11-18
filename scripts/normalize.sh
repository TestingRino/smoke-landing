#!/usr/bin/env bash
# Merge all scanner reports into one list: reports/findings.json
#   [{fp, kind, severity, rule, title, location, detail}]
# fp is stable across runs (no commit SHAs or line-shift-sensitive data where avoidable), so issues
# and DefectDojo can deduplicate. A missing report BLOCKS: a scanner that crashed is not a pass.
source "$(dirname "$0")/lib.sh"
require WORK
REP="$WORK/reports"
for f in gitleaks.json semgrep.json trivy-fs.json trivy-image.json; do
  [[ -s "$REP/$f" ]] || die "missing scanner report $f: blocking"
done

jq -n \
  --slurpfile gl "$REP/gitleaks.json" \
  --slurpfile sg "$REP/semgrep.json" \
  --slurpfile tf "$REP/trivy-fs.json" \
  --slurpfile ti "$REP/trivy-image.json" '
  def sev_sg: if . == "ERROR" then "HIGH" elif . == "WARNING" then "MEDIUM" else "LOW" end;
  [
    ($gl[0][]? | {kind:"secret", severity:"CRITICAL", rule:.RuleID,
        title:"Secret in git history: \(.RuleID)", location:"\(.File):\(.StartLine)",
        detail:"Commit \(.Commit[0:12]). Rotate the credential, then remove it from history. gitleaks fingerprint: \(.Fingerprint)",
        key:"secret|\(.RuleID)|\(.File)|\(.StartLine)"}),
    ($tf[0].Results[]? | .Target as $t | .Secrets[]? | {kind:"secret", severity:"CRITICAL", rule:.RuleID,
        title:"Secret in source tree: \(.RuleID)", location:"\($t):\(.StartLine)",
        detail:"Rotate the credential and move it to Secret Manager.", key:"secret|\(.RuleID)|\($t)|\(.StartLine)"}),
    ($ti[0].Results[]? | .Target as $t | .Secrets[]? | {kind:"secret", severity:"CRITICAL", rule:.RuleID,
        title:"Secret baked into container image: \(.RuleID)", location:$t,
        detail:"The image must never contain credentials: they are injected at runtime from Secret Manager.",
        key:"image-secret|\(.RuleID)|\($t)"}),
    ($sg[0].results[]? | {kind:"sast", severity:(.extra.severity|sev_sg), rule:.check_id,
        title:"\(.check_id | split(".") | last)", location:"\(.path | sub("^/src/";"")):\(.start.line)",
        detail:(.extra.message // "" | .[0:600]), key:"sast|\(.check_id)|\(.path)|\(.extra.lines // "" | gsub("\\s+";" ") | .[0:200])"}),
    ($ti[0].Results[]? | .Target as $t | .Vulnerabilities[]? | {kind:"vuln", severity:.Severity, rule:.VulnerabilityID,
        title:"\(.VulnerabilityID) in \(.PkgName) \(.InstalledVersion)", location:$t,
        fixed:(.FixedVersion // ""),
        detail:"\(.Title // "")\nInstalled: \(.InstalledVersion)  Fixed in: \(.FixedVersion // "no fix yet")\n\(.PrimaryURL // "")",
        key:"vuln|\(.VulnerabilityID)|\(.PkgName)"}),
    ($tf[0].Results[]? | .Target as $t | .Misconfigurations[]? | {kind:"misconfig", severity:.Severity, rule:.ID,
        title:"\(.ID): \(.Title)", location:$t, detail:"\(.Message // "")\n\(.Resolution // "")",
        key:"misconfig|\(.ID)|\($t)"})
  ] | unique_by(.key)' > "$REP/findings.raw.json"

# Replace the readable key with a short hash (keys may contain paths; hash keeps issue markers tidy)
jq -c '.[]' "$REP/findings.raw.json" | while IFS= read -r f; do
  h="$(jq -r .key <<< "$f" | sha256sum | cut -c1-16)"
  jq -c --arg h "$h" '. + {fp:$h} | del(.key)' <<< "$f"
done | jq -s '.' > "$REP/findings.json"
rm -f "$REP/findings.raw.json"
log "$(jq length "$REP/findings.json") normalized findings"
