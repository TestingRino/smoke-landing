#!/usr/bin/env bash
# Source-level scans: secrets (git history), SAST, dependency/IaC/secret scan of the tree.
# shellcheck disable=SC2054  # commas are inside single CLI arguments
source "$(dirname "$0")/lib.sh"
require WORK REPO
SRC="$WORK/src"; REP="$WORK/reports"; EXC="$SMOKE_ROOT/policy/exceptions/$REPO"
DU="$(docker_user)"
TRIVY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/trivy"; mkdir -p "$TRIVY_CACHE"

# Exceptions belong to the control repo, not the app: strip app-controlled suppression files.
rm -f "$SRC/.gitleaksignore" "$SRC/.semgrepignore" "$SRC/.trivyignore" "$SRC/.trivyignore.yaml"

exc_mount=(); [[ -d "$EXC" ]] && exc_mount=(-v "$EXC:/exc:ro")

log "gitleaks (full history)"
gl=(git /src --redact --no-banner --exit-code 0 --report-format json --report-path /out/gitleaks.json)
[[ -f "$EXC/gitleaksignore" ]] && gl+=(--gitleaks-ignore-path /exc/gitleaksignore)
docker run --rm --network none --user "$DU" \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  -v "$SRC:/src:ro" -v "$REP:/out" "${exc_mount[@]}" "$GITLEAKS_IMAGE" "${gl[@]}"

log "semgrep ($SEMGREP_RULESETS)"
sg=(semgrep scan --json --output /out/semgrep.json --metrics off --disable-nosem)
for r in $SEMGREP_RULESETS; do sg+=(--config "$r"); done
if [[ -f "$EXC/semgrep-exclude-rules.txt" ]]; then
  while IFS= read -r rule; do [[ -n "$rule" && "$rule" != \#* ]] && sg+=(--exclude-rule "$rule"); done < "$EXC/semgrep-exclude-rules.txt"
fi
sg+=(/src)
# semgrep's progress and errors go to a log (not --quiet, which also hides errors); shown if it fails
rc=0; docker run --rm --user "$DU" -e HOME=/tmp -v "$SRC:/src:ro" -v "$REP:/out" "$SEMGREP_IMAGE" "${sg[@]}" \
  >/dev/null 2>"$WORK/semgrep.log" || rc=$?
if [[ ! -s "$REP/semgrep.json" ]]; then
  echo "---- semgrep output (last 25 lines) ----" >&2; tail -n 25 "$WORK/semgrep.log" >&2
  die "semgrep produced no report (exit $rc): see the semgrep output above"
fi
n_err=$(jq '.errors | length' "$REP/semgrep.json" 2>/dev/null || echo 0)
(( n_err == 0 )) || warn "semgrep reported $n_err non-fatal error(s), e.g. $(jq -r '.errors[0].message // "" | .[0:200]' "$REP/semgrep.json")"

log "trivy fs (deps, IaC/Dockerfile misconfig, secrets)"
tv=(fs --cache-dir /cache --scanners vuln,misconfig,secret --format json --output /out/trivy-fs.json --exit-code 0 --quiet)
[[ -f "$EXC/trivyignore" ]] && tv+=(--ignorefile /exc/trivyignore)
docker run --rm --user "$DU" -v "$SRC:/src:ro" -v "$REP:/out" -v "$TRIVY_CACHE:/cache" "${exc_mount[@]}" \
  "$TRIVY_IMAGE" "${tv[@]}" /src
