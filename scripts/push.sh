#!/usr/bin/env bash
# Push the scanned image to Artifact Registry; emit its immutable digest (deploys pin to the digest).
source "$(dirname "$0")/lib.sh"
require REPO SHA IMAGE_LOCAL GCP_PROJECT GCP_REGION AR_REPO
remote="$(image_remote "$REPO")"
gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet >/dev/null 2>&1
docker tag "$IMAGE_LOCAL" "$remote:${SHA:0:12}"
docker push --quiet "$remote:${SHA:0:12}" >/dev/null
digest="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$remote:${SHA:0:12}" | grep "^${remote}@" | head -n1 | cut -d@ -f2)"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not determine pushed digest"
docker rmi "$IMAGE_LOCAL" "$remote:${SHA:0:12}" >/dev/null 2>&1 || true
log "Pushed $remote@$digest"
out digest "$digest"
set_status "$SHA" pending "Gate passed: signing and deploying to staging"
