#!/usr/bin/env bash
# Run this BEFORE the demo. It pulls every image, builds the app image and runs the
# unit tests, so any failure shows up now and not in front of an audience.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env

FAILS=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; FAILS=$((FAILS + 1)); fi
}

pull_with_retry() { # IMAGE
  local i
  for i in 1 2 3; do
    $DOCKER pull "$1" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# Docker Hub's /v2/ endpoint answers HTTP 401 (login required) when it is reachable.
# So 200 and 401 both mean "reachable". Do not add curl -f here.
hub_reachable() {
  local code
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://registry-1.docker.io/v2/ || true)"
  [ "$code" = "200" ] || [ "$code" = "401" ]
}
disk_ok()   { [ "$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')" -ge 5 ]; }
mem_ok()    { [ "$(free -m | awk '/^Mem:/{print $2}')" -ge 1500 ]; }
port_free() { ! python3 -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1"; }
unit_tests() { PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests; }
nginx_conf_valid() { # syntax-check nginx config inside the pinned image, with a throwaway upstream file
  local tmp; tmp="$(mktemp -d)"
  printf 'server app-blue:8080;\nserver app-green:8080;\n' > "$tmp/upstream.conf"
  $DOCKER run --rm --add-host app-blue:127.0.0.1 --add-host app-green:127.0.0.1 \
    -v "$ROOT/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$tmp:/etc/nginx/upstream:ro" "$NGINX_IMAGE" nginx -t
  local rc=$?; rm -rf "$tmp"; return $rc
}

log "System checks"
check "Docker daemon reachable"        $DOCKER info
check "Docker Compose v2 installed"    $DC version
check "At least 5 GB free disk"        disk_ok
check "At least 1.5 GB RAM"            mem_ok
if [ -n "$($DC ps -q 2>/dev/null)" ]; then
  ok "Stack already running (port check skipped)"
else
  for p in 80 18081 18082; do check "Port $p is free" port_free "$p"; done
fi
check "Docker Hub reachable (HTTP 200 or 401)" hub_reachable

log "Pulling images (up to 3 tries each)"
for img in "$NGINX_IMAGE" "$PYTHON_IMAGE"; do
  check "Pull $img" pull_with_retry "$img"
done

log "Building and validating"
check "Build app image"                $DC build
check "nginx config is valid"          nginx_conf_valid
check "Unit tests"                     unit_tests

echo
if [ "$FAILS" -eq 0 ]; then
  echo "Preflight passed. Safe to run ./scripts/up.sh"
  exit 0
fi
echo "Preflight found $FAILS problem(s). See the troubleshooting table in STEPS.md." >&2
echo "Image pull failed? Run 'sudo docker login' with a free Docker Hub account (avoids rate limits)," >&2
echo "or change the image tag in .env and re-run this script." >&2
exit 1
