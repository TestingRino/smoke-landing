#!/usr/bin/env bash
# Upgrade DefectDojo to the tag pinned in smoke.config.env (DEFECTDOJO_VERSION). Backup first.
#   1. bump DEFECTDOJO_VERSION in smoke.config.env via a PR (read DefectDojo's release notes!)
#   2. on the VM:  cd ~/smoke-landing && git pull && sudo vm/defectdojo/upgrade.sh
# Rollback: restore.sh --in-place <the backup this script just made> after pinning the old tag again.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dojo-lib.sh
source "$SRC/dojo-lib.sh"
need_root
cur="$(envget DD_VERSION)"; new="${DEFECTDOJO_VERSION:?}"
[[ "$cur" != "$new" ]] || { log "already on $cur"; exit 0; }
log "upgrading DefectDojo $cur -> $new"
"$DOJO_DIR/backup.sh" || { [[ -d "$BACKUP_DIR" ]] && log "local backup taken (bucket upload failed)" || die "backup failed: not upgrading"; }
# setup.sh copies the new files, sets DD_VERSION, pulls, runs the initializer (database migrations) and re-verifies
exec "$SRC/setup.sh"
