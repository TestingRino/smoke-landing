#!/usr/bin/env bash
# One-screen health check:  sudo /opt/defectdojo/status.sh   (smokectl dojo-status runs it over SSH)
set -euo pipefail
# shellcheck source=dojo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dojo-lib.sh"
need_root
ok() { printf '  %-14s %s\n' "$1" "$2"; }
if dojo_up; then ok web "UP  http://127.0.0.1:$(dojo_port)  (version $(envget DD_VERSION))"; else ok web "DOWN"; fi
dc ps --format '{{.Service}}={{.State}}' 2>/dev/null | tr '\n' ' ' | sed 's/^/  services       /'; echo
ok firewall "$(systemctl is-active dojo-firewall.service 2>/dev/null || echo unknown)"
last="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)"
ok last-backup "${last:-none}  (timer: $(systemctl is-active dojo-backup.timer 2>/dev/null || echo unknown))"
ok disk "$(df -h / | awk 'NR==2 {print $4 " free of " $2}')"
mapfile -t ids < <(dc ps -q)
mem="$( ((${#ids[@]})) && docker stats --no-stream --format '{{.MemUsage}}' "${ids[@]}" 2>/dev/null \
  | awk '{v=$1; m=v+0; if (v ~ /GiB/) m*=1024; else if (v ~ /KiB/) m/=1024; s+=m} END {printf "%.0f MiB", s}')"
ok memory "${mem:-n/a} in use by DefectDojo containers (limits total ~3.6 GiB)"
