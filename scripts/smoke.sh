#!/usr/bin/env bash
# Health check of the whole stack. Ends with "All N checks passed."
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_env
load_state

PASS=0
TOTAL=0
check() { # LABEL COMMAND...
  local label="$1"; shift
  TOTAL=$((TOTAL + 1))
  if "$@" >/dev/null 2>&1; then ok "$label"; PASS=$((PASS + 1)); else fail "$label"; fi
}

container_running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
slot_answers()      { [ "$(http_code "$(slot_url "$1")/healthz")" != "000" ]; }
active_healthy()    { [ "$(http_code "$(slot_url "$ACTIVE")/healthz")" = "200" ]; }
proxy_200()         { [ "$(http_code "$PROXY_URL$1")" = "200" ]; }
has_version_header(){ curl -sI -m 3 "$PROXY_URL/api/version" | grep -qi '^x-app-version:'; }
routing_file_ok()   { grep -q 'server app-blue:8080' "$UPSTREAM_FILE" && grep -q 'server app-green:8080' "$UPSTREAM_FILE"; }
reload_drops_nothing() {
  local out; out="$(mktemp)"
  python3 "$ROOT/tools/probe.py" --url "$PROXY_URL/api/version" --duration 5 --rps 20 --json > "$out" &
  local pid=$!
  sleep 1.5; nginx_reload >/dev/null 2>&1; sleep 0.5; nginx_reload >/dev/null 2>&1
  wait "$pid"
  local errors total
  errors="$(json_get "$out" "d['errors']")"; total="$(json_get "$out" "d['total']")"
  rm -f "$out"
  [ "$total" -gt 50 ] && [ "$errors" -eq 0 ]
}

log "Smoke test"
check "Docker daemon reachable"                 $DOCKER info
check "nginx container running"                 container_running zd-nginx
check "app-blue container running"              container_running zd-app-blue
check "app-green container running"             container_running zd-app-green
check "nginx config is valid (nginx -t)"        nginx_test
check "Routing file lists both slots"           routing_file_ok
check "Proxy answers /nginx-health"             proxy_200 /nginx-health
check "Proxy serves the app on /"               proxy_200 /
check "Proxy serves /api/version"               proxy_200 /api/version
check "Responses carry the X-App-Version header" has_version_header
check "Dashboard page is served"                proxy_200 /dashboard/
check "Blue slot answers"                       slot_answers blue
check "Green slot answers"                      slot_answers green
check "Live slot ($ACTIVE) is healthy"          active_healthy
check "2 graceful nginx reloads under load drop 0 requests" reload_drops_nothing

echo
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "All ${TOTAL} checks passed."
  echo "Open in your browser:  http://$(public_ip)/dashboard/"
  exit 0
fi
echo "$((TOTAL - PASS)) of ${TOTAL} checks failed." >&2
echo "--- nginx logs (last 15 lines) ---" >&2
$DC logs --no-color --tail 15 nginx 2>&1 >&2 || true
echo "See the troubleshooting table in STEPS.md." >&2
exit 1
