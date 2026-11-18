#!/usr/bin/env bash
# File one GitHub issue per BLOCKING finding in the app repo; close issues whose finding is gone.
#  - dedup marker in each issue body: <!-- smoke-gate:fp=<fingerprint> -->
#  - labels: smoke-gate, severity:<sev>, kind:<kind>
#  - secrets in PUBLIC repos are NOT described in a public issue (it would advertise a live credential);
#    one generic issue points to the private gate report instead.
# Runs on pass AND block, so fixed findings get closed. Failures here never change the gate verdict.
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA OWNER
[[ "${FILE_ISSUES:-true}" == true ]] || { log "issue filing disabled"; exit 0; }
F="$WORK/reports/findings.json"; [[ -s "$F" ]] || { warn "no findings.json; skipping issues"; exit 0; }
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
api() { gh_apps api "$@"; }

ensure_label() { api -X POST "repos/$OWNER/$REPO/labels" -f name="$1" -f color="$2" >/dev/null 2>&1 || true; }
ensure_label smoke-gate b60205
for s in critical high medium; do ensure_label "severity:$s" d93f0b; done

# Existing open smoke-gate issues: fp -> issue number
declare -A open_issue=()
while IFS=$'\t' read -r num fp; do [[ -n "$fp" ]] && open_issue[$fp]=$num; done < <(
  api --paginate "repos/$OWNER/$REPO/issues?state=open&labels=smoke-gate&per_page=100" \
    | jq -r '.[] | select(.pull_request|not) | [.number, ((.body // "") | capture("smoke-gate:fp=(?<f>[0-9a-f]+)").f // "")] | @tsv')

public=$([[ "${REPO_PRIVATE:-true}" == true ]] && echo false || echo true)
current=$(jq -c --argjson pub "$public" '
  [.[] | select(.blocking)
   | if ($pub and .kind == "secret") then {fp:"0000000000secret", kind:"secret", severity:"CRITICAL",
        title:"Secrets detected: details in the private gate report", location:"(withheld: public repository)",
        detail:"The DevSecOps gate found one or more credentials. Details are withheld because this repository is public. Open the gate run (maintainers only), rotate every listed credential, and purge it from git history."}
     else . end] | unique_by(.fp)' "$F")

declare -A seen=(); created=0; skipped=0
while IFS= read -r f; do
  fp=$(jq -r .fp <<< "$f"); seen[$fp]=1
  if [[ -n "${open_issue[$fp]:-}" ]]; then
    continue   # already tracked
  fi
  if (( created >= MAX_NEW_ISSUES_PER_RUN )); then skipped=$((skipped+1)); continue; fi
  sev=$(jq -r '.severity|ascii_downcase' <<< "$f"); kind=$(jq -r .kind <<< "$f")
  ensure_label "kind:$kind" 5319e7
  title="[smoke-gate] $(jq -r '"\(.severity) \(.title)"' <<< "$f")"
  body=$(jq -r --arg run "$run_url" --arg sha "$SHA" --arg fp "$fp" '
"**Severity:** \(.severity)  **Type:** \(.kind)  **Rule:** `\(.rule // "-")`
**Location:** `\(.location)`
**First seen:** commit `\($sha[0:12])`: [gate run](\($run))

\(.detail // "")

---
Blocks deployment until fixed. If this is a false positive or accepted risk, request a time-boxed exception in `smoke-landing/policy/exceptions/`. This issue closes automatically when a later gate run no longer finds it.
<!-- smoke-gate:fp=\($fp) -->"' <<< "$f")
  if api -X POST "repos/$OWNER/$REPO/issues" -f title="${title:0:250}" -f body="$body" \
       -f "labels[]=smoke-gate" -f "labels[]=severity:$sev" -f "labels[]=kind:$kind" >/dev/null; then
    created=$((created+1))
  else
    warn "could not create issue for $fp (does GH_APPS_TOKEN have Issues: write?)"
  fi
done < <(jq -c '.[]' <<< "$current")

closed=0
for fp in "${!open_issue[@]}"; do
  [[ -n "${seen[$fp]:-}" ]] && continue
  n=${open_issue[$fp]}
  api -X POST "repos/$OWNER/$REPO/issues/$n/comments" -f body="✅ No longer detected by the smoke gate at commit \`${SHA:0:12}\` ([run]($run_url)). Closing." >/dev/null || true
  api -X PATCH "repos/$OWNER/$REPO/issues/$n" -f state=closed -f state_reason=completed >/dev/null && closed=$((closed+1))
done

msg="- 🐞 Issues in \`$OWNER/$REPO\`: $created opened, $closed closed (fixed), ${#open_issue[@]} were already open"
(( skipped > 0 )) && msg+=", $skipped more not filed this run (cap $MAX_NEW_ISSUES_PER_RUN)"
echo "$msg" | summary
