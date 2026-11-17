#!/usr/bin/env bash
# One-time GCP setup. Use a DEDICATED project for smoke apps (blast radius = this project only).
#   ./gcp/bootstrap.sh <project-id> [region] [github-owner] [control-repo-name]
set -euo pipefail
PROJECT="${1:?project id}"; REGION="${2:-us-central1}"
GH_OWNER="${3:-TestingRino}"; CTRL="${4:-smoke-landing}"
AR_REPO=smoke-apps; POOL=smoke-landing; PROVIDER=github; SA_ID=smoke-deployer
G=(--project "$PROJECT" --quiet)
NUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
SA="$SA_ID@$PROJECT.iam.gserviceaccount.com"

gcloud services enable "${G[@]}" run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com

gcloud artifacts repositories describe "$AR_REPO" "${G[@]}" --location "$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$AR_REPO" "${G[@]}" --location "$REGION" --repository-format docker \
    --description "smoke-landing app images"
cat > /tmp/ar-cleanup.json <<'EOF'
[
  {"name": "keep-recent", "action": {"type": "Keep"}, "mostRecentVersions": {"keepCount": 3}},
  {"name": "delete-old",  "action": {"type": "Delete"}, "condition": {"olderThan": "30d"}}
]
EOF
gcloud artifacts repositories set-cleanup-policies "$AR_REPO" "${G[@]}" --location "$REGION" --policy /tmp/ar-cleanup.json --no-dry-run

gcloud iam service-accounts describe "$SA" "${G[@]}" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_ID" "${G[@]}" --display-name "smoke-landing deployer"
# A new service account takes a few seconds to become visible to IAM policy bindings: retry.
bind() {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    "$@" >/dev/null 2>&1 && return 0
    echo "  waiting for new IAM resources to propagate (attempt $i)..."; sleep $((i * 5))
  done
  "$@" >/dev/null   # final attempt shows the real error
}
for role in roles/run.admin roles/secretmanager.admin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser; do
  bind gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role "$role" --condition=None --quiet
done
bind gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" "${G[@]}" --location "$REGION" \
  --member "serviceAccount:$SA" --role roles/artifactregistry.repoAdmin

# Workload Identity Federation: ONLY the control repo's main branch can impersonate the deployer.
# NOTE: the owner name is compared CASE-SENSITIVELY: use the exact GitHub spelling (e.g. TestingRino).
gcloud iam workload-identity-pools describe "$POOL" "${G[@]}" --location global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" "${G[@]}" --location global --display-name "smoke-landing"
gcloud iam workload-identity-pools providers describe "$PROVIDER" "${G[@]}" --location global --workload-identity-pool "$POOL" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" "${G[@]}" --location global --workload-identity-pool "$POOL" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition "assertion.repository == '$GH_OWNER/$CTRL' && assertion.ref == 'refs/heads/main'"
bind gcloud iam service-accounts add-iam-policy-binding "$SA" "${G[@]}" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$NUM/locations/global/workloadIdentityPools/$POOL/attribute.repository/$GH_OWNER/$CTRL"

cat <<EOF

Done. Put these in smoke.config.env:
GCP_PROJECT="$PROJECT"
GCP_REGION="$REGION"
GCP_WIF_PROVIDER="projects/$NUM/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
GCP_DEPLOYER_SA="$SA"

If deploys fail with "allUsers ... domain restricted sharing", your org policy
iam.allowedPolicyMemberDomains blocks public Cloud Run; override it for this project only.
EOF
