#!/usr/bin/env bash
# Restore a DefectDojo backup (a directory holding defectdojo.dump, media.tgz, SHA256SUMS).
#
#   sudo /opt/defectdojo/restore.sh --scratch  <backup-dir>   restore into a separate throwaway instance on
#                                                             127.0.0.1:18088 (the live one is untouched); prints counts
#   sudo /opt/defectdojo/restore.sh --cleanup                 delete the scratch instance and its volumes
#   sudo /opt/defectdojo/restore.sh --in-place <backup-dir>   REPLACE the live database and media (asks first)
#
# Backups: /var/backups/defectdojo/<ts>/ (last 7 nights) or the bucket. To fetch one from the bucket,
# see README "Restore". The VM's own service account can only create objects, not read them.
set -euo pipefail
# shellcheck source=dojo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dojo-lib.sh"
need_root
mode="${1:-}"; src="${2:-}"
SCRATCH=defectdojo-restore
SCRATCH_PORT=18088

verify_backup() {
  [[ -d "$src" && -s "$src/defectdojo.dump" && -s "$src/media.tgz" ]] || die "not a backup directory: $src"
  (cd "$src" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch in $src"
}

load() {   # compose-wrapper-function: restore db + media into the instance that function addresses
  local c="$1" vol="$2"
  log "restoring database"
  $c up -d postgres
  for _ in $(seq 1 30); do $c exec -T postgres pg_isready -U defectdojo -d defectdojo >/dev/null 2>&1 && break; sleep 2; done
  $c exec -T postgres pg_restore -U defectdojo -d defectdojo --clean --if-exists --no-owner --role=defectdojo < "$src/defectdojo.dump"
  log "restoring media"
  docker run --rm -i -v "$vol:/m" alpine:3.23.7 sh -c 'rm -rf /m/* && tar xzf - -C /m' < "$src/media.tgz"
}

scratch_dc() {
  COMPOSE_PROJECT_NAME=$SCRATCH DD_PORT=$SCRATCH_PORT DD_BRIDGE=br-dojo-rst DD_SITE_URL="http://localhost:$SCRATCH_PORT" \
  COMPOSE_FILE=docker-compose.yml bash -c 'cd "$1" && shift && exec docker compose --env-file .env "$@"' _ "$DOJO_DIR" -p "$SCRATCH" "$@"
}

case "$mode" in
  --scratch)
    verify_backup
    scratch_dc down -v >/dev/null 2>&1 || true; docker volume rm -f "${SCRATCH}_media" >/dev/null 2>&1 || true
    load scratch_dc "${SCRATCH}_media"
    log "starting scratch instance on 127.0.0.1:$SCRATCH_PORT (same secrets as live, so encrypted fields decrypt)"
    scratch_dc up -d >/dev/null 2>&1
    for _ in $(seq 1 120); do
      [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SCRATCH_PORT/login")" == 200 ]] && break; sleep 5
    done
    counts="$(scratch_dc exec -T uwsgi python3 manage.py shell --no-imports 2>/dev/null <<'PY'
from dojo.models import Product, Engagement, Test, Finding
print("products=%d engagements=%d tests=%d findings=%d active=%d" % (Product.objects.count(), Engagement.objects.count(),
      Test.objects.count(), Finding.objects.count(), Finding.objects.filter(active=True).count()))
PY
)"
    [[ -n "$counts" ]] || die "scratch instance did not come up (check: restore.sh --cleanup, then retry)"
    log "scratch restore OK: $counts"
    log "browse it via: ssh -L $SCRATCH_PORT:127.0.0.1:$SCRATCH_PORT <vm>; then remove it: sudo $0 --cleanup"
    ;;
  --cleanup)
    scratch_dc down -v
    docker volume rm -f "${SCRATCH}_media" >/dev/null 2>&1 || true   # created outside compose by load()
    log "scratch instance removed" ;;
  --in-place)
    verify_backup
    read -r -p "This REPLACES the live DefectDojo data with $src. Type 'restore' to continue: " ans
    [[ "$ans" == restore ]] || die "aborted"
    "$DOJO_DIR/backup.sh" || warn "pre-restore backup failed (continuing: you confirmed)"
    dc stop nginx uwsgi celeryworker celerybeat
    load dc "$(envget COMPOSE_PROJECT_NAME)_media"
    dc up -d
    wait_dojo 120
    log "restored $src into the live instance"
    ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
