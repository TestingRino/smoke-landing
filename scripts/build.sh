#!/usr/bin/env bash
# Build the container image locally. Dockerfile if present, else Google Cloud buildpacks (Node/Python/Go/...).
# The image built here is the exact image that gets scanned, pushed by digest and deployed.
source "$(dirname "$0")/lib.sh"
require WORK REPO SHA
SRC="$WORK/src"

safe_rel() { [[ "$1" != /* && "$1" != *..* ]] || die ".smoke.yml path must be relative without '..': $1"; }
dockerfile="$(cfg dockerfile Dockerfile)"; safe_rel "$dockerfile"
context="$(cfg context .)";               safe_rel "$context"

IMAGE_LOCAL="smoke-local/$(slug "$REPO"):${SHA:0:12}"

if [[ -f "$SRC/$dockerfile" ]]; then
  log "docker build ($dockerfile)"
  docker build --pull --platform linux/amd64 \
    --label "org.opencontainers.image.revision=$SHA" \
    --label "org.opencontainers.image.source=https://github.com/$OWNER/$REPO" \
    -f "$SRC/$dockerfile" -t "$IMAGE_LOCAL" "$SRC/$context"
else
  log "no Dockerfile; buildpacks ($BUILDPACK_BUILDER)"
  pk=(build "$IMAGE_LOCAL" --builder "$BUILDPACK_BUILDER" --path "$SRC/$context" --pull-policy if-not-present)
  ep="$(cfg entrypoint "")"; [[ -n "$ep" ]] && pk+=(--env "GOOGLE_ENTRYPOINT=$ep")
  pack "${pk[@]}"
fi
export_env IMAGE_LOCAL "$IMAGE_LOCAL"
