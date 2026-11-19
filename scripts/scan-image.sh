#!/usr/bin/env bash
# Scan the built image (OS + language packages + baked-in secrets) and produce an SBOM.
# shellcheck disable=SC2054  # commas are inside single CLI arguments
# Uses `docker save` so the scanners never get the Docker socket.
source "$(dirname "$0")/lib.sh"
require WORK REPO IMAGE_LOCAL
REP="$WORK/reports"; EXC="$SMOKE_ROOT/policy/exceptions/$REPO"; DU="$(docker_user)"
TRIVY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/trivy"; mkdir -p "$TRIVY_CACHE"
exc_mount=(); [[ -d "$EXC" ]] && exc_mount=(-v "$EXC:/exc:ro")

tar="$WORK/image.tar"
docker save -o "$tar" "$IMAGE_LOCAL"
trap 'rm -f "$tar"' EXIT

log "trivy image"
tv=(image --input /work/image.tar --cache-dir /cache --scanners vuln,secret --format json --output /out/trivy-image.json --exit-code 0 --quiet)
[[ -f "$EXC/trivyignore" ]] && tv+=(--ignorefile /exc/trivyignore)
docker run --rm --user "$DU" -v "$WORK:/work:ro" -v "$REP:/out" -v "$TRIVY_CACHE:/cache" "${exc_mount[@]}" \
  "$TRIVY_IMAGE" "${tv[@]}"

log "syft SBOM"
# Non-root syft needs a writable /tmp to unpack the image (the syft image's own /tmp isn't), and no network:
# the update check is off. Its output goes to a log that is shown if it fails.
rc=0
docker run --rm --network none --user "$DU" --tmpfs /tmp:rw,exec,mode=1777,size=8g \
  -e HOME=/tmp -e SYFT_CHECK_FOR_APP_UPDATE=false -v "$WORK:/work:ro" -v "$REP:/out" \
  "$SYFT_IMAGE" docker-archive:/work/image.tar -o spdx-json=/out/sbom.spdx.json >/dev/null 2>"$WORK/syft.log" || rc=$?
if (( rc != 0 )) || ! jq -e '.spdxVersion' "$REP/sbom.spdx.json" >/dev/null 2>&1; then
  echo "---- syft output (last 20 lines) ----" >&2; tail -n 20 "$WORK/syft.log" >&2
  die "syft produced no valid SBOM (exit $rc): see the syft output above"
fi
log "SBOM: $(jq '.packages | length' "$REP/sbom.spdx.json") packages"
