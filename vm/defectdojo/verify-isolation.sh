#!/usr/bin/env bash
# Prove that DefectDojo is reachable from the host (runner, IAP path) but NOT from build/scanner containers.
#   sudo /opt/defectdojo/verify-isolation.sh        exit 0 = all checks passed
set -euo pipefail
# shellcheck source=dojo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dojo-lib.sh"
need_root
PORT="$(dojo_port)"; IP="$(envget DD_INTERNAL_IP)"
CURL_IMG="curlimages/curl:8.17.0"
fails=0
check() {   # description expect(open|closed) command...
  local d="$1" want="$2"; shift 2
  local got=closed
  if "$@" >/dev/null 2>&1; then got=open; fi
  if [[ "$got" == "$want" ]]; then printf '  PASS  %-62s %s\n' "$d" "$got"
  else printf '  FAIL  %-62s %s (expected %s)\n' "$d" "$got" "$want"; fails=$((fails + 1)); fi
}
probe() { curl -s -o /dev/null -f --max-time 5 "$1"; }
from_container() {   # network url
  docker run --rm --network "$1" "$CURL_IMG" -s -o /dev/null -f --max-time 5 "$2"
}
dojo_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q nginx)")"
bridge_gw="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"

echo "DefectDojo isolation check (port $PORT, internal IP $IP, nginx container $dojo_ip)"
check "host -> 127.0.0.1:$PORT (runner imports)"                    open   probe "http://127.0.0.1:$PORT/login"
check "host -> $IP:$PORT (IAP path)"                                 open   probe "http://$IP:$PORT/login"
check "container (default bridge) -> $IP:$PORT"                     closed from_container bridge "http://$IP:$PORT/login"
check "container (default bridge) -> $bridge_gw:$PORT"              closed from_container bridge "http://$bridge_gw:$PORT/login"
check "container (default bridge) -> nginx container $dojo_ip:8080" closed from_container bridge "http://$dojo_ip:8080/login"
net="dojo-isolation-test-$$"
docker network create "$net" >/dev/null
check "container (user-defined bridge) -> $IP:$PORT"                closed from_container "$net" "http://$IP:$PORT/login"
check "container (user-defined bridge) -> nginx $dojo_ip:8080"      closed from_container "$net" "http://$dojo_ip:8080/login"
docker network rm "$net" >/dev/null

# docker build RUN steps (BuildKit) - what an app's Dockerfile can do
ctx="$(mktemp -d)"
printf 'FROM %s\nRUN curl -s -o /dev/null -f --max-time 5 http://%s:%s/login\n' "$CURL_IMG" "$IP" "$PORT" > "$ctx/Dockerfile"
check "docker build RUN -> $IP:$PORT"                                closed docker build --no-cache -q "$ctx"
rm -rf "$ctx"

if curl -s --max-time 2 -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/ >/dev/null 2>&1; then
  check "container -> metadata server (service-account token)"     closed \
    docker run --rm "$CURL_IMG" -s -f --max-time 5 -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/
fi

# Containers must still be able to resolve names (scanners download rules and vulnerability databases).
# Retries: a single DNS lookup can time out on a busy VM.
check "container DNS lookup works (scanners need it)"               open \
  docker run --rm alpine:3.23.7 sh -c 'for i in 1 2 3; do nslookup -timeout=5 github.com >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'

if (( fails )); then echo "$fails check(s) FAILED"; exit 1; fi
echo "All isolation checks passed."
