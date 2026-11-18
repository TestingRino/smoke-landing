#!/usr/bin/env bash
# After the gate passes and the image is pushed: sign it and attach
#   1. SPDX SBOM                         (--type spdxjson)
#   2. build provenance (SLSA v1 shape)  (--type slsaprovenance1)
#   3. gate result                       (--type $ATTEST_GATE_TYPE): verdict, counts, policy hash, run
# Everything is bound to the image DIGEST, so it cannot be moved to a different image.
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA DIGEST
REP="$WORK/reports"; ref="$(image_remote "$REPO")@$DIGEST"
run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

cosign sign --key "$(sign_key)" "${COSIGN_FLAGS[@]}" "$ref" >/dev/null
attest "$ref" "$REP/sbom.spdx.json" spdxjson

jq -n --arg repo "https://github.com/$OWNER/$REPO" --arg sha "$SHA" --arg run "$run_url" \
  --arg builder "https://github.com/${GITHUB_REPOSITORY:-}/.github/workflows/deploy.yml" \
  --arg started "$(date -u +%FT%TZ)" --arg runner "${RUNNER_NAME:-}" '{
  buildDefinition: {
    buildType: "https://github.com/TestingRino/smoke-landing/buildtypes/container/v1",
    externalParameters: {repository: $repo, commit: $sha},
    resolvedDependencies: [{uri: ("git+" + $repo), digest: {gitCommit: $sha}}]
  },
  runDetails: {
    builder: {id: $builder},
    metadata: {invocationId: $run, startedOn: $started, runner: $runner}
  }}' > "$WORK/provenance.json"
attest "$ref" "$WORK/provenance.json" slsaprovenance1

jq --arg digest "$DIGEST" --arg ref "$ref" \
   --arg tools "gitleaks=$GITLEAKS_IMAGE semgrep=$SEMGREP_IMAGE trivy=$TRIVY_IMAGE syft=$SYFT_IMAGE" \
   '. + {image:$ref, digest:$digest, scanners:($tools|split(" "))}' "$REP/summary.json" > "$WORK/gate-predicate.json"
attest "$ref" "$WORK/gate-predicate.json" "$ATTEST_GATE_TYPE"
echo "- ✍️ Signed \`$ref\` + SBOM, provenance and gate attestations (Cloud KMS key)" | summary
