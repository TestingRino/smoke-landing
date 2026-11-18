#!/usr/bin/env bash
# Shared helpers for the vm/defectdojo scripts. Source it; don't execute it.
# Works both from the repo checkout (vm/defectdojo/) and from the install dir (/opt/defectdojo).
set -euo pipefail

DOJO_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# smoke.config.env: next to the scripts once installed, or two levels up in the repo
for _c in "$DOJO_SRC/smoke.config.env" "$DOJO_SRC/../../smoke.config.env"; do
  # shellcheck disable=SC1090
  if [[ -r "$_c" ]]; then source "$_c"; break; fi
done
unset _c
DOJO_DIR="${DEFECTDOJO_DIR:-/opt/defectdojo}"
DOJO_ENV="$DOJO_DIR/.env"
# shellcheck disable=SC2034  # used by the scripts that source this file
DOJO_USER=smoke
# shellcheck disable=SC2034
RUNNER_ENV="${SMOKE_RUNNER_ENV:-/etc/smoke-landing/runner.env}"
# shellcheck disable=SC2034
BACKUP_DIR=/var/backups/defectdojo

log()  { echo "[defectdojo] $*" >&2; }
warn() { echo "[defectdojo] WARN: $*" >&2; }
die()  { echo "[defectdojo] ERROR: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo"; }

envget() { [[ -r "$DOJO_ENV" ]] && grep -E "^$1=" "$DOJO_ENV" | head -1 | cut -d= -f2- || true; }
envset() {   # KEY VALUE: update in place; returns 0 if changed, 1 if already equal
  local cur; cur="$(envget "$1")"
  [[ "$cur" == "$2" ]] && grep -qE "^$1=" "$DOJO_ENV" && return 1
  if grep -qE "^$1=" "$DOJO_ENV"; then sed -i "s|^$1=.*|$1=$2|" "$DOJO_ENV"; else echo "$1=$2" >> "$DOJO_ENV"; fi
  return 0
}

# COMPOSE_FILE (in .env) holds relative paths, which compose resolves against the current directory.
dc() { (cd "$DOJO_DIR" && docker compose --env-file "$DOJO_ENV" "$@"); }

dojo_port() { envget DD_PORT; }
dojo_up() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$(dojo_port)/login")" == 200 ]]; }
wait_dojo() {
  for _ in $(seq 1 "${1:-120}"); do dojo_up && return 0; sleep 5; done
  die "DefectDojo did not answer on 127.0.0.1:$(dojo_port) (check: sudo docker compose --project-directory $DOJO_DIR logs --tail 50)"
}

# The VM's primary internal IP (what IAP connects to). GCE metadata first, then the default route.
internal_ip() {
  local ip
  ip="$(curl -s --max-time 2 -H 'Metadata-Flavor: Google' \
        http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/ip 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "could not determine the VM's internal IP"
  echo "$ip"
}

# Run Python inside the DefectDojo app container (Django ORM, as the app itself). Prints stdout.
dojo_shell() { dc exec -T uwsgi python3 manage.py shell --no-imports 2>/dev/null; }
