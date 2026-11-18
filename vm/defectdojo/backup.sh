#!/usr/bin/env bash
# Back up DefectDojo: pg_dump (custom format) + media volume tarball.
#   sudo /opt/defectdojo/backup.sh          (dojo-backup.timer runs it nightly)
# Local copy: /var/backups/defectdojo/<UTC timestamp>/ (last 7 kept).
# Cloud copy: gs://$DEFECTDOJO_BACKUP_BUCKET/defectdojo/<timestamp>/ using the VM's service account
# (roles/storage.objectCreator on that bucket only). Uploads use the JSON API with ifGenerationMatch=0:
# create-only, so this VM can never overwrite or delete a backup.
set -euo pipefail
# shellcheck source=dojo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dojo-lib.sh"
need_root
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dir="$BACKUP_DIR/$ts"
install -d -m 0700 "$BACKUP_DIR" "$dir"
trap 'rm -f "$dir"/*.partial' EXIT

log "pg_dump -> $dir/defectdojo.dump"
dc exec -T postgres pg_dump -U defectdojo -d defectdojo -Fc > "$dir/defectdojo.dump.partial"
mv "$dir/defectdojo.dump.partial" "$dir/defectdojo.dump"
log "media volume -> $dir/media.tgz"
docker run --rm -v "$(envget COMPOSE_PROJECT_NAME)_media:/m:ro" alpine:3.23.7 tar czf - -C /m . > "$dir/media.tgz.partial"
mv "$dir/media.tgz.partial" "$dir/media.tgz"
(cd "$dir" && sha256sum defectdojo.dump media.tgz > SHA256SUMS && echo "$DEFECTDOJO_VERSION" > VERSION)
chmod 0600 "$dir"/*
log "local backup: $(du -sh "$dir" | cut -f1)"

# keep the newest 7 local backups
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +8 | while read -r old; do rm -rf "${BACKUP_DIR:?}/$old"; done

# --- upload ---
bucket="${DEFECTDOJO_BACKUP_BUCKET:-}"
[[ -n "$bucket" ]] || { warn "DEFECTDOJO_BACKUP_BUCKET not set: local backup only"; exit 0; }
tok="$(curl -s --max-time 5 -H 'Metadata-Flavor: Google' \
       http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)"
[[ -n "$tok" ]] || { warn "no VM service account (see README: Backups): local backup only"; exit 1; }
up() {   # file object-name
  local name code
  name="$(jq -rn --arg s "$2" '$s|@uri')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 900 -X POST --data-binary "@$1" \
          -H "Authorization: Bearer $tok" -H 'Content-Type: application/octet-stream' \
          "https://storage.googleapis.com/upload/storage/v1/b/$bucket/o?uploadType=media&ifGenerationMatch=0&name=$name")"
  [[ "$code" == 200 ]] || { warn "upload of $2 failed (HTTP $code)"; return 1; }
}
rc=0
for f in defectdojo.dump media.tgz SHA256SUMS VERSION; do up "$dir/$f" "defectdojo/$ts/$f" || rc=1; done
(( rc == 0 )) && log "uploaded to gs://$bucket/defectdojo/$ts/"
exit $rc
