#!/usr/bin/env bash
# Host firewall for the DevSecOps VM: untrusted build/scanner containers must not reach DefectDojo,
# nor the GCE metadata server (which hands out the VM's service-account token).
#
#   firewall.sh apply | remove | status
#
# Installed by setup.sh as the systemd unit dojo-firewall.service (After/PartOf docker.service, so it is
# re-applied whenever Docker restarts and on every boot). Rules:
#   DOCKER-USER (forwarded traffic, i.e. container -> published port after DNAT, container -> container):
#     anything from a Docker bridge other than DefectDojo's own whose original destination port is DD_PORT -> DROP
#     anything from a Docker bridge other than DefectDojo's own into DefectDojo's bridge              -> DROP
#     anything from any Docker bridge to 169.254.169.254 (metadata server)                             -> DROP
#   INPUT (host sockets, e.g. docker-proxy or a host-network listener):
#     Docker bridge -> tcp/DD_PORT -> DROP
# Traffic from the VM's NIC (Google IAP) and from host processes (the runner) is untouched.
set -euo pipefail
PORT="${DD_PORT:-8088}"
DOJO_BR="${DD_BRIDGE:-br-dojo}"
BLOCK_METADATA="${BLOCK_CONTAINER_METADATA:-true}"
FWD=DOJO-GUARD-FWD
INP=DOJO-GUARD-IN
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

have_chain() { iptables -n -L "$1" >/dev/null 2>&1; }
ensure_jump() {   # parent-chain target
  iptables -C "$1" -j "$2" 2>/dev/null || iptables -I "$1" 1 -j "$2"
}
remove_jump() { while iptables -C "$1" -j "$2" 2>/dev/null; do iptables -D "$1" -j "$2"; done; }

apply() {
  # Docker creates DOCKER-USER; create it ourselves too so ordering at boot doesn't matter.
  have_chain DOCKER-USER || iptables -N DOCKER-USER
  for c in "$FWD" "$INP"; do have_chain "$c" && iptables -F "$c" || iptables -N "$c"; done

  # --- forwarded traffic (DOCKER-USER runs before Docker's own FORWARD rules) ---
  iptables -A "$FWD" -i "$DOJO_BR" -j RETURN                                  # DefectDojo's own containers
  for br in docker0 'br-+'; do
    iptables -A "$FWD" -i "$br" -p tcp -m conntrack --ctorigdstport "$PORT" -j DROP
    iptables -A "$FWD" -i "$br" -o "$DOJO_BR" -j DROP
    [[ "$BLOCK_METADATA" == true ]] && iptables -A "$FWD" -i "$br" -d 169.254.169.254 -j DROP
  done
  iptables -A "$FWD" -j RETURN
  ensure_jump DOCKER-USER "$FWD"

  # --- traffic to host sockets ---
  for br in docker0 'br-+'; do
    iptables -A "$INP" -i "$br" -p tcp --dport "$PORT" -j DROP
    [[ "$BLOCK_METADATA" == true ]] && iptables -A "$INP" -i "$br" -d 169.254.169.254 -j DROP
  done
  iptables -A "$INP" -j RETURN
  ensure_jump INPUT "$INP"
  echo "dojo-firewall: applied (port $PORT, DefectDojo bridge $DOJO_BR, metadata block $BLOCK_METADATA)"
}

remove() {
  remove_jump DOCKER-USER "$FWD" 2>/dev/null || true
  remove_jump INPUT "$INP" 2>/dev/null || true
  for c in "$FWD" "$INP"; do have_chain "$c" && { iptables -F "$c"; iptables -X "$c"; }; done
  echo "dojo-firewall: removed"
}

status() {
  for c in "$FWD" "$INP"; do echo "== $c"; iptables -n -v -L "$c" 2>/dev/null || echo "(missing)"; done
  echo "== jumps"; iptables -S DOCKER-USER 2>/dev/null | grep -- "-j $FWD" || echo "DOCKER-USER: no jump"
  iptables -S INPUT | grep -- "-j $INP" || echo "INPUT: no jump"
}

case "${1:-}" in
  apply) apply ;; remove) remove ;; status) status ;;
  *) echo "usage: $0 apply|remove|status"; exit 1 ;;
esac
