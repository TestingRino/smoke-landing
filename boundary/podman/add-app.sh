#!/usr/bin/env bash
# Allow podman on the deploy VM to run ONE smoke-landing app from the internal registry, and only if it's
# signed by the pinned smoke-landing key for that same app.
#   sudo ./add-app.sh <app-slug> [policy.json]        (default: /etc/containers/policy.json)
#
# Each app gets an exactRepository rule: the signature's identity must be that app's smoke-landing staging
# repository (where it was signed), so a signed image of app A can't be pushed into app B's internal repo.
# (remapIdentity would cover all apps with one rule, but with podman 4.9 / containers-image 5.29 it rejected
#  valid sigstore signatures in testing; per-app rules worked.)
set -euo pipefail
slug="${1:?usage: add-app.sh <app-slug> [policy.json]}"
policy="${2:-/etc/containers/policy.json}"
INTERNAL="${INTERNAL_REGISTRY:-registry.corp.example/apps/smoke-imports}"
SIGNED="${SIGNED_PREFIX:-us-central1-docker.pkg.dev/testingrino-smoke/smoke-apps}"
KEY="${SIGNING_PUBKEY_PATH:-/etc/containers/keys/smoke-landing-signing.pub}"
[[ "$slug" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "app slug must be lowercase [a-z0-9._-]: $slug" >&2; exit 1; }
[[ -s "$policy" ]] || { echo "no policy file: $policy (install boundary/podman/policy.json first)" >&2; exit 1; }
tmp="$(mktemp)"
jq --arg scope "$INTERNAL/$slug" --arg repo "$SIGNED/$slug" --arg key "$KEY" \
  '.transports.docker[$scope] = [{type: "sigstoreSigned", keyPath: $key,
     signedIdentity: {type: "exactRepository", dockerRepository: $repo}}]' "$policy" > "$tmp"
install -m 0644 "$tmp" "$policy"; rm -f "$tmp"
echo "podman will now run $INTERNAL/$slug@sha256:... only if signed by $KEY for $SIGNED/$slug"
