#!/usr/bin/env bash
# Read-only report: findings marked "risk accepted" or "false positive" in DefectDojo that have NO matching
# exception file in policy/exceptions/<repo>/. DefectDojo triage never changes the gate; this lists what
# still needs a reviewed PR (or should be un-accepted). Nothing is synced automatically.
#   scripts/defectdojo-acceptances.sh     (on the VM, in group smoke so it can read runner.env)
# Output (tab-separated): repo  triage  test  id  title
source "$(dirname "$0")/lib.sh"
require DEFECTDOJO_URL DEFECTDOJO_TOKEN
api="${DEFECTDOJO_URL%/}/api/v2"; auth=(-H "Authorization: Token $DEFECTDOJO_TOKEN")
get() { curl -sS -f --max-time 60 "${auth[@]}" "$1"; }

declare -A test_title test_eng eng_prod prod_name
lookup_repo() {   # test id -> sets REPO_NAME TOOL
  local t="$1" e p
  if [[ -z "${test_title[$t]:-}" ]]; then
    local j; j="$(get "$api/tests/$t/")"; test_title[$t]="$(jq -r .title <<< "$j")"; test_eng[$t]="$(jq -r .engagement <<< "$j")"
  fi
  e="${test_eng[$t]}"
  [[ -n "${eng_prod[$e]:-}" ]] || eng_prod[$e]="$(get "$api/engagements/$e/" | jq -r .product)"
  p="${eng_prod[$e]}"
  [[ -n "${prod_name[$p]:-}" ]] || prod_name[$p]="$(get "$api/products/$p/" | jq -r .name)"
  REPO_NAME="${prod_name[$p]}"; TOOL="${test_title[$t]}"
}

findings() {   # filter label
  local url="$api/findings/?limit=200&$1"
  while [[ -n "$url" && "$url" != null ]]; do
    local page; page="$(get "$url")" || die "DefectDojo query failed"
    jq -c --arg why "$2" '.results[] | {test, why: $why, title,
        cve: ((.vulnerability_ids // []) | map(.vulnerability_id) | first // ""), rule: (.vuln_id_from_tool // "")}' <<< "$page"
    url="$(jq -r '.next' <<< "$page")"
  done
}

missing=0
while IFS= read -r f; do
  lookup_repo "$(jq -r .test <<< "$f")"
  dir="$SMOKE_ROOT/policy/exceptions/$REPO_NAME"
  cve="$(jq -r .cve <<< "$f")"; rule="$(jq -r .rule <<< "$f")"; covered=no
  case "$TOOL" in
    trivy-*)  [[ -n "$cve" ]] && grep -qsE "^[[:space:]]*${cve}([[:space:]]|$)" "$dir/trivyignore" && covered=yes ;;
    semgrep)  [[ -n "$rule" ]] && grep -qsxF "$rule" "$dir/semgrep-exclude-rules.txt" && covered=yes ;;
    gitleaks) [[ -s "$dir/gitleaksignore" ]] && covered=check-by-hand ;;   # fingerprints include commit + path
    zap-*)    covered=n/a ;;                                               # DAST has no exception file
  esac
  [[ "$covered" == yes ]] && continue
  missing=$((missing + 1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$REPO_NAME" "$(jq -r .why <<< "$f")" "$TOOL" "${cve:-$rule}" "$(jq -r '.title[0:70]' <<< "$f")"
done < <(findings "risk_accepted=true" risk-accepted; findings "false_p=true" false-positive)

echo "$missing triaged finding(s) without a matching policy/exceptions/<repo>/ entry (the gate still blocks on them)." >&2
