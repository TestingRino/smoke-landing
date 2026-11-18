#!/usr/bin/env bash
# Promote a staging image to the release registry: the human-approved step before the boundary.
# Fails CLOSED: every check must pass, or nothing is copied.
#
#   In:  REPO, COMMIT (full or short SHA), JUSTIFICATION, GITHUB_ACTOR (approver)
#   1. resolve the commit, the staging image <staging>/<slug>:<sha12> and its signed digest
#   2. verify: signature; gate attestation (commit + digest match, verdict pass);
#      staging attestation (digest match, verdict pass, deployed within RELEASE_MAX_STAGING_AGE_DAYS)
#   3. cosign copy <staging>@<digest> -> <release>/<slug>:<sha12> (signature + attestations come along);
#      confirm the digest is unchanged
#   4. release attestation {approvedBy, approvedAt, justification, commit, commitAuthor, digest, sourceRepo, runs}
#   5. commit status smoke-landing/release; job summary + $WORK/release-manifest.json with the boundary reference
source "$(dirname "$0")/lib.sh"
require REPO COMMIT JUSTIFICATION OWNER RELEASE_REPO
validate_repo "$REPO"
WORK="${WORK:-${RUNNER_TEMP:-$(mktemp -d)}/release}"; mkdir -p "$WORK"
max_age="${RELEASE_MAX_STAGING_AGE_DAYS:-14}"
approver="${GITHUB_ACTOR:-$(id -un)}"
fail() { echo "- ⛔ **Release refused:** $*" | summary; die "release refused: $*"; }

[[ "$COMMIT" =~ ^[0-9a-f]{7,40}$ ]] || fail "commit must be a hex SHA (7-40 chars), got '$COMMIT'"
[[ ${#JUSTIFICATION} -ge 10 ]] || fail "justification is required (at least 10 characters)"

# 1. resolve -------------------------------------------------------------------------------------------
if [[ -n "${GH_APPS_TOKEN:-}" ]]; then
  commit_json="$(gh_apps api "repos/$OWNER/$REPO/commits/$COMMIT")" || fail "commit $COMMIT not found in $OWNER/$REPO"
  sha="$(jq -r .sha <<< "$commit_json")"; author="$(jq -r '.author.login // .commit.author.email // "unknown"' <<< "$commit_json")"
else
  [[ ${#COMMIT} -eq 40 ]] || fail "need the full 40-char SHA when GH_APPS_TOKEN is not available"
  sha="$COMMIT"; author="unknown"
fi
staging="$(image_remote "$REPO")"; release="$(release_remote "$REPO")"
[[ -z "${AR_HOST:-}" ]] && gcloud auth configure-docker "$(ar_host)" --quiet >/dev/null 2>&1
digest="$(signed_digest "$staging:${sha:0:12}")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "no SIGNED staging image $staging:${sha:0:12} (did the gate pass for this commit?)"
ref="$staging@$digest"
log "candidate: $ref"

# 2. verify --------------------------------------------------------------------------------------------
[[ -n "$(signed_digest "$ref")" ]] || fail "signature does not verify on $ref"
gate="$(read_attestations "$ref" "$ATTEST_GATE_TYPE" | jq -c --arg d "$digest" --arg c "$sha" \
        '[.[] | select(.digest == $d and .commit == $c)] | sort_by(.evaluatedAt) | last // empty')"
[[ -n "$gate" ]] || fail "no verified gate attestation for commit ${sha:0:12} on this digest"
[[ "$(jq -r .verdict <<< "$gate")" == pass ]] || fail "gate verdict is $(jq -r .verdict <<< "$gate")"
[[ "$(jq '[.checks[] | select(.max >= 0 and .count > .max)] | length' <<< "$gate")" == 0 ]] || fail "gate attestation has failing checks"
stg="$(read_attestations "$ref" "$ATTEST_STAGING_TYPE" | jq -c --arg d "$digest" --arg c "$sha" \
       '[.[] | select(.digest == $d and .commit == $c)] | sort_by(.deployedAt) | last // empty')"
[[ -n "$stg" ]] || fail "no verified staging attestation: this digest never passed staging (deploy + smoke check + DAST)"
[[ "$(jq -r .verdict <<< "$stg")" == pass ]] || fail "staging verdict is $(jq -r .verdict <<< "$stg")"
age_days=$(( ( $(date -u +%s) - $(date -u -d "$(jq -r .deployedAt <<< "$stg")" +%s) ) / 86400 ))
(( age_days <= max_age )) || fail "last staging pass is $age_days days old (max $max_age): redeploy to staging first"
log "verified: signature, gate (pass), staging (pass, $age_days d ago)"

# Separation of duties: recorded here; the BINDING check happens in the boundary (GitLab).
sod="ok"
if [[ "$author" != unknown && "${author,,}" == "${approver,,}" ]]; then
  sod="same-person"
  if [[ "${RELEASE_REQUIRE_DIFFERENT_APPROVER:-false}" == true ]]; then fail "approver $approver is also the commit author"; fi
  warn "approver $approver is also the commit author: the boundary approval must be by someone else"
fi

# 3. promote -------------------------------------------------------------------------------------------
tag="${sha:0:12}"
cosign copy --force "$ref" "$release:$tag" >/dev/null 2>&1 || fail "cosign copy to $release failed"
[[ "$(signed_digest "$release:$tag")" == "$digest" ]] || fail "digest changed or signature missing after copy"
rref="$release@$digest"

# 4. release attestation -------------------------------------------------------------------------------
run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
jq -n --arg by "$approver" --arg at "$(date -u +%FT%TZ)" --arg why "$JUSTIFICATION" --arg c "$sha" --arg a "$author" \
   --arg d "$digest" --arg src "https://github.com/$OWNER/$REPO" --arg ref "$rref" --arg sod "$sod" \
   --arg gr "$(jq -r .run <<< "$gate")" --arg sr "$(jq -r .run <<< "$stg")" --arg rr "$run_url" \
   '{approvedBy:$by, approvedAt:$at, justification:$why, commit:$c, commitAuthor:$a, separationOfDuties:$sod,
     digest:$d, image:$ref, sourceRepo:$src, gateRun:$gr, stagingRun:$sr, releaseRun:$rr}' > "$WORK/release-predicate.json"
attest "$rref" "$WORK/release-predicate.json" "$ATTEST_RELEASE_TYPE"

# 5. report --------------------------------------------------------------------------------------------
jq -n --slurpfile r "$WORK/release-predicate.json" --argjson g "$gate" --argjson s "$stg" \
   '{release: $r[0], gate: {verdict: $g.verdict, policyHash: $g.policyHash, run: $g.run},
     staging: {url: $s.url, deployedAt: $s.deployedAt, dast: $s.dast, run: $s.run}}' > "$WORK/release-manifest.json"
STATUS_CONTEXT="smoke-landing/release" set_status "$sha" success "Released by $approver: $(slug "$REPO")@${digest:7:12}" "$run_url"
{
  echo "## ✅ Released \`$OWNER/$REPO\` @ \`${sha:0:12}\`"
  echo
  echo "**Boundary reference** (pull by digest only):"
  echo
  echo "    $rref"
  echo
  echo "| | |"; echo "|---|---|"
  echo "| Approved by | \`$approver\` (commit author: \`$author\`$([[ $sod == same-person ]] && echo ' ⚠️ same person: the boundary approver must differ')) |"
  echo "| Justification | ${JUSTIFICATION//|/\\|} |"
  echo "| Gate | pass (policy \`$(jq -r .policyHash <<< "$gate")\`) |"
  echo "| Staging | $(jq -r .url <<< "$stg") · $age_days d ago · ZAP high: $(jq -r .dast.high <<< "$stg") |"
  echo
  echo "Signature, SBOM, provenance, gate, staging and release attestations travel with the image (\`cosign copy\`)."
  echo "Hand the reference to the boundary team; they run \`boundary/verify-and-import.sh\`."
} | summary
out ref "$rref"
out digest "$digest"
log "released: $rref"
