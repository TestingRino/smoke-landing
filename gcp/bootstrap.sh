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
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com \
  cloudkms.googleapis.com

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
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"   # bind(): retries IAM bindings while new resources propagate
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

# --- Signing key (Cloud KMS). The private key never leaves KMS; only smoke-deployer may sign with it. ----
KEYRING=smoke-landing; KEY=artifact-signing
gcloud kms keyrings describe "$KEYRING" "${G[@]}" --location global >/dev/null 2>&1 || \
  gcloud kms keyrings create "$KEYRING" "${G[@]}" --location global
gcloud kms keys describe "$KEY" "${G[@]}" --location global --keyring "$KEYRING" >/dev/null 2>&1 || \
  gcloud kms keys create "$KEY" "${G[@]}" --location global --keyring "$KEYRING" \
    --purpose asymmetric-signing --default-algorithm ec-sign-p256-sha256 --protection-level software
for role in roles/cloudkms.signerVerifier roles/cloudkms.viewer; do   # viewer: cosign reads the key's metadata
  bind gcloud kms keys add-iam-policy-binding "$KEY" "${G[@]}" --location global --keyring "$KEYRING" \
    --member "serviceAccount:$SA" --role "$role"
done
gcloud kms keys versions get-public-key 1 "${G[@]}" --key "$KEY" --keyring "$KEYRING" --location global \
  --output-file smoke-landing-signing.pub

# --- Release registry: only promoted images; the boundary can READ it. No cleanup policy: releases are kept. ---
REL_REPO=smoke-release
gcloud artifacts repositories describe "$REL_REPO" "${G[@]}" --location "$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REL_REPO" "${G[@]}" --location "$REGION" --repository-format docker \
    --description "smoke-landing releases (human-promoted, signed); read by the boundary"
bind gcloud artifacts repositories add-iam-policy-binding "$REL_REPO" "${G[@]}" --location "$REGION" \
  --member "serviceAccount:$SA" --role roles/artifactregistry.repoAdmin

# --- boundary-puller: read-only on smoke-release, nothing else. Its key is created by hand (see below). ---
PULLER="boundary-puller@$PROJECT.iam.gserviceaccount.com"
gcloud iam service-accounts describe "$PULLER" "${G[@]}" >/dev/null 2>&1 || \
  gcloud iam service-accounts create boundary-puller "${G[@]}" --display-name "Boundary: pull releases (read-only)"
bind gcloud artifacts repositories add-iam-policy-binding "$REL_REPO" "${G[@]}" --location "$REGION" \
  --member "serviceAccount:$PULLER" --role roles/artifactregistry.reader

# --- smokeSecretWriter: teammates add/rotate app secrets but can't read them (no versions.access) ---
SW_PERMS=secretmanager.secrets.create,secretmanager.secrets.get,secretmanager.secrets.list,secretmanager.secrets.update,secretmanager.secrets.delete,secretmanager.versions.add,secretmanager.versions.list,secretmanager.versions.get,secretmanager.versions.enable,secretmanager.versions.disable,secretmanager.versions.destroy
if gcloud iam roles describe smokeSecretWriter "${G[@]}" >/dev/null 2>&1; then
  gcloud iam roles update smokeSecretWriter "${G[@]}" --permissions "$SW_PERMS" >/dev/null
else
  gcloud iam roles create smokeSecretWriter "${G[@]}" --title "smoke-landing secret writer" --stage GA \
    --description "Create and rotate smoke-landing secrets without reading them" --permissions "$SW_PERMS" >/dev/null
fi

cat <<EOF

Done. Put these in smoke.config.env:
GCP_PROJECT="$PROJECT"
GCP_REGION="$REGION"
GCP_WIF_PROVIDER="projects/$NUM/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
GCP_DEPLOYER_SA="$SA"

If deploys fail with "allUsers ... domain restricted sharing", your org policy
iam.allowedPolicyMemberDomains blocks public Cloud Run; override it for this project only.

SIGNING PUBLIC KEY (commit it as keys/smoke-landing-signing.pub; the boundary pins this file):
$(cat smoke-landing-signing.pub)

Boundary pull key (do this by hand when the boundary team is ready; rotate every 90 days):
  gcloud iam service-accounts keys create boundary-puller.json --iam-account $PULLER --project $PROJECT
  -> give the JSON to the GitLab team as a masked + protected CI variable, then delete your copy.
  If your org blocks service-account keys, use Workload Identity Federation from GitLab's OIDC instead
  (see boundary/README.md).
EOF
