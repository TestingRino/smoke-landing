#!/usr/bin/env bash
# Boundary-side check and import of a smoke-landing release. Fails CLOSED at every step.
#
#   verify-and-import.sh [--phase verify|rescan|import|all] <release-ref@sha256:...> <expected-github-repo>
#     e.g. verify-and-import.sh us-central1-docker.pkg.dev/testingrino-smoke/smoke-release/demo@sha256:ab.. TestingRino/demo
#
# verify  1. reference must be pinned by digest
#         2. cosign signature with the PINNED public key (no transparency log; key pinned in this repo)
#         3. gate, staging and release attestations: signed, bound to this exact digest, mutually consistent
#            (same commit), gate verdict pass with every blocking check at 0, staging verdict pass,
#            release sourceRepo == https://github.com/<expected-github-repo>
#         -> writes verify.json (commit, author, approver, ...) for the approval job
# rescan  4. the boundary's own Trivy (offline DB supported) fails on CRITICAL/HIGH
#            (boundary-owned exceptions: BOUNDARY_TRIVYIGNORE)
# import  5. cosign copy to $INTERNAL_REGISTRY by digest (signature + attestations come along); re-verify there
#         6. prints the internal reference (last line) and writes import.env (INTERNAL_REF=...)
#
# Environment:
#   SIGNING_PUBKEY        pinned public key file              (default: ./smoke-landing-signing.pub next to this script)
#   INTERNAL_REGISTRY     where images are imported, e.g. registry.corp.example/apps/smoke-imports   (import phase)
#   TRIVY_OFFLINE=true    use only the local Trivy DB (air-gapped; mirror it via TRIVY_CACHE_DIR)
#   BOUNDARY_TRIVYIGNORE  optional ignore file owned by the boundary team
#   Registry auth: `cosign login` / docker config for both registries (see README).
# shellcheck disable=SC2054  # commas are inside single CLI arguments
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PHASE=all
[[ "${1:-}" == --phase ]] && { PHASE="$2"; shift 2; }
REF="${1:?usage: verify-and-import.sh [--phase P] <release-ref@sha256:...> <expected-github-repo>}"
EXPECTED="${2:?expected GitHub repo, e.g. TestingRino/demo}"
PUB="${SIGNING_PUBKEY:-$HERE/smoke-landing-signing.pub}"
OUT="${OUT_DIR:-.}"
T_GATE="https://github.com/TestingRino/smoke-landing/attestations/gate/v1"
T_STAGING="https://github.com/TestingRino/smoke-landing/attestations/staging/v1"
T_RELEASE="https://github.com/TestingRino/smoke-landing/attestations/release/v1"

fail() { echo "BOUNDARY CHECK FAILED: $*" >&2; exit 1; }
ok()   { echo "  ok  $*" >&2; }
for c in cosign jq; do command -v "$c" >/dev/null || fail "missing tool: $c"; done
[[ -s "$PUB" ]] || fail "pinned public key not found: $PUB"

# 1. digest-pinned reference ------------------------------------------------------------------------------
[[ "$REF" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] || fail "reference must be pinned by digest (…@sha256:<64 hex>): $REF"
REPO_PATH="${BASH_REMATCH[1]}"; DIGEST="${BASH_REMATCH[2]}"
[[ "$EXPECTED" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "expected repo must look like Owner/name: $EXPECTED"

attestations() {   # type -> JSON array of verified predicates bound to DIGEST
  local raw
  raw="$(cosign verify-attestation --key "$PUB" --insecure-ignore-tlog=true --type "$1" "$REF" 2>/dev/null)" || { echo '[]'; return 0; }
  jq -s --arg d "$DIGEST" 'map(.payload | @base64d | fromjson
      | select(any(.subject[]?; ("sha256:" + .digest.sha256) == $d)) | .predicate)' <<< "$raw"
}

verify() {
  echo "verify $REF" >&2
  local sig
  sig="$(cosign verify --key "$PUB" --insecure-ignore-tlog=true "$REF" 2>/dev/null)" || fail "no valid signature from the pinned key"
  [[ "$(jq -r '[.[].critical.image["docker-manifest-digest"]] | unique | .[]' <<< "$sig")" == "$DIGEST" ]] \
    || fail "signature does not cover $DIGEST"
  ok "signature (pinned key) covers $DIGEST"

  local rel gate stg commit
  rel="$(attestations "$T_RELEASE" | jq -c --arg d "$DIGEST" '[.[] | select(.digest == $d)] | sort_by(.approvedAt) | last // empty')"
  [[ -n "$rel" ]] || fail "no release attestation: this image was never promoted by smoke-landing's release workflow"
  [[ "$(jq -r .sourceRepo <<< "$rel")" == "https://github.com/$EXPECTED" ]] \
    || fail "release is for $(jq -r .sourceRepo <<< "$rel"), expected https://github.com/$EXPECTED"
  commit="$(jq -r .commit <<< "$rel")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "release attestation has no valid commit"
  ok "release attestation: approved by $(jq -r .approvedBy <<< "$rel") at $(jq -r .approvedAt <<< "$rel")"

  gate="$(attestations "$T_GATE" | jq -c --arg d "$DIGEST" --arg c "$commit" \
          '[.[] | select(.digest == $d and .commit == $c)] | sort_by(.evaluatedAt) | last // empty')"
  [[ -n "$gate" ]] || fail "no gate attestation for commit ${commit:0:12} on this digest"
  [[ "$(jq -r .verdict <<< "$gate")" == pass ]] || fail "gate verdict is $(jq -r .verdict <<< "$gate")"
  local bad; bad="$(jq -r '[.checks[] | select(.max >= 0 and .count > 0)] | map("\(.check)=\(.count)") | join(", ")' <<< "$gate")"
  [[ -z "$bad" ]] || fail "gate attestation has blocking findings: $bad"
  ok "gate: pass, every blocking check at 0 (policy $(jq -r .policyHash <<< "$gate"))"

  stg="$(attestations "$T_STAGING" | jq -c --arg d "$DIGEST" --arg c "$commit" \
         '[.[] | select(.digest == $d and .commit == $c)] | sort_by(.deployedAt) | last // empty')"
  [[ -n "$stg" ]] || fail "no staging attestation for this digest"
  [[ "$(jq -r .verdict <<< "$stg")" == pass ]] || fail "staging verdict is $(jq -r .verdict <<< "$stg")"
  ok "staging: pass ($(jq -r .deployedAt <<< "$stg"), ZAP high: $(jq -r '.dast.high // "n/a"' <<< "$stg"))"

  jq -n --arg ref "$REF" --arg d "$DIGEST" --arg repo "$EXPECTED" --argjson r "$rel" --argjson g "$gate" --argjson s "$stg" \
    '{ref:$ref, digest:$d, sourceRepo:$repo, commit:$r.commit, commitAuthor:$r.commitAuthor, releasedBy:$r.approvedBy,
      justification:$r.justification, releasedAt:$r.approvedAt, gatePolicy:$g.policyHash, stagingAt:$s.deployedAt}' > "$OUT/verify.json"
  ok "wrote $OUT/verify.json"
}

rescan() {
  echo "rescan $REF" >&2
  command -v trivy >/dev/null || fail "missing tool: trivy"
  local args=(image --severity CRITICAL,HIGH --exit-code 1 --scanners vuln,secret --quiet --format table)
  [[ "${TRIVY_OFFLINE:-false}" == true ]] && args+=(--skip-db-update --skip-java-db-update --offline-scan)
  [[ -n "${BOUNDARY_TRIVYIGNORE:-}" ]] && args+=(--ignorefile "$BOUNDARY_TRIVYIGNORE")
  trivy "${args[@]}" "$REF" >&2 || fail "boundary re-scan found CRITICAL/HIGH issues (or could not scan)"
  ok "boundary re-scan: no CRITICAL/HIGH"
}

import() {
  echo "import $REF" >&2
  : "${INTERNAL_REGISTRY:?set INTERNAL_REGISTRY (e.g. registry.corp.example/apps/smoke-imports)}"
  local name tag dst
  name="${REPO_PATH##*/}"
  tag="$(jq -r '.commit[0:12] // empty' "$OUT/verify.json" 2>/dev/null || true)"; tag="${tag:-${DIGEST:7:12}}"
  dst="$INTERNAL_REGISTRY/$name"
  cosign copy --force "$REF" "$dst:$tag" >/dev/null 2>&1 || fail "cosign copy to $dst failed"
  local got
  got="$(cosign verify --key "$PUB" --insecure-ignore-tlog=true "$dst@$DIGEST" 2>/dev/null \
         | jq -r '[.[].critical.image["docker-manifest-digest"]] | unique | .[]')" || got=""
  [[ "$got" == "$DIGEST" ]] || fail "imported image does not verify by digest in $dst"
  ok "imported and re-verified: $dst@$DIGEST"
  echo "INTERNAL_REF=$dst@$DIGEST" > "$OUT/import.env"
  echo "$dst@$DIGEST"
}

case "$PHASE" in
  verify) verify ;;
  rescan) rescan ;;
  import) [[ -s "$OUT/verify.json" ]] || verify; import ;;
  all)    verify; rescan; import ;;
  *) fail "unknown phase $PHASE" ;;
esac
