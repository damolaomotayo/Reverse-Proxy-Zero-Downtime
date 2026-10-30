#!/usr/bin/env bash
# Scripted demo. Usage: ./scripts/demo.sh [bluegreen|canary|bad-health|bad-canary|rollback|all]
# Every scenario starts from a clean baseline (both slots v1, blue live) and checks its own result.
# A background load of 20 requests/second hits the site the whole time, so any dropped request shows up.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need_env

REL="bash $ROOT/scripts/release.sh"
PROBE="$ROOT/tools/probe.py"
STOPFILE="$ROOT/.probe-stop"
PROBE_OUT="$(mktemp)"
PROBE_PID=""
FAILURES=0
trap 'rm -f "$STOPFILE" "$PROBE_OUT"; [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null' EXIT

assert() { # LABEL COMMAND...
  local label="$1"; shift
  if "$@"; then ok "$label"; else fail "$label"; FAILURES=$((FAILURES + 1)); fi
}
live_version() { curl -s -m 3 "$PROXY_URL/api/version" | python3 -c 'import sys, json; print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "?"; }
share() { json_get "$PROBE_OUT" "d['by_version'].get('$1', {}).get('ok', 0) * 100 // max(d['total'], 1)"; }

probe_start() {
  rm -f "$STOPFILE"
  python3 "$PROBE" --url "$PROXY_URL/api/version" --duration 180 --rps 20 --stop-file "$STOPFILE" --json > "$PROBE_OUT" &
  PROBE_PID=$!
  sleep 1
}
probe_stop() {
  touch "$STOPFILE"; wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""; rm -f "$STOPFILE"
  python3 "$PROBE" --report "$PROBE_OUT"
  P_TOTAL="$(json_get "$PROBE_OUT" "d['total']")"
  P_ERR="$(json_get "$PROBE_OUT" "d['errors']")"
}
baseline() { $REL reset >/dev/null 2>&1 || { fail "could not reset to the baseline"; exit 1; }; }
finish() { # SCENARIO
  if [ "$FAILURES" -eq 0 ]; then printf '\n\033[1;32mPASS\033[0m  %s\n\n' "$1"; else printf '\n\033[1;31mFAIL\033[0m  %s\n\n' "$1"; exit 1; fi
}

scenario_bluegreen() {
  log "SCENARIO bluegreen: replace v1 with v2 while 20 requests/second keep arriving"
  baseline
  probe_start
  $REL deploy v2 || FAILURES=$((FAILURES + 1))
  sleep 2
  $REL promote   || FAILURES=$((FAILURES + 1))
  sleep 4
  probe_stop
  assert "zero failed requests during the cutover" [ "$P_ERR" -eq 0 ]
  assert "users saw v1 first and v2 after" [ "$(share v1)" -gt 0 -a "$(share v2)" -gt 0 ]
  assert "v2 is live" [ "$(live_version)" = "v2" ]
  finish bluegreen
}

scenario_canary() {
  log "SCENARIO canary: send 20% of traffic to v2, then promote"
  baseline
  $REL deploy v2 || FAILURES=$((FAILURES + 1))
  $REL canary 20 || FAILURES=$((FAILURES + 1))
  probe_start
  sleep 10
  probe_stop
  local pct; pct="$(share v2)"
  echo "    v2 received ${pct}% of requests (target 20%)"
  assert "v2 got roughly 20% of traffic" [ "$pct" -ge 12 -a "$pct" -le 28 ]
  assert "zero failed requests" [ "$P_ERR" -eq 0 ]
  $REL promote || FAILURES=$((FAILURES + 1))
  assert "v2 is live after promote" [ "$(live_version)" = "v2" ]
  finish canary
}

scenario_bad_health() {
  log "SCENARIO bad-health: a release that cannot start properly is blocked before users see it"
  baseline
  probe_start
  if $REL deploy v2 health; then fail "the bad release was NOT blocked"; FAILURES=$((FAILURES + 1)); else ok "release was blocked by the health gate"; fi
  sleep 2
  probe_stop
  assert "zero failed requests" [ "$P_ERR" -eq 0 ]
  assert "v1 is still live" [ "$(live_version)" = "v1" ]
  finish bad-health
}

scenario_bad_canary() {
  log "SCENARIO bad-canary: healthy on startup, but fails on real traffic. Caught by the canary, not the gate"
  baseline
  $REL deploy v2 errors || FAILURES=$((FAILURES + 1))
  if $REL canary 10 --watch 12; then fail "the bad canary was NOT rolled back"; FAILURES=$((FAILURES + 1)); else ok "canary was rolled back automatically"; fi
  assert "canary is switched off (0% to v2)" grep -q '^PCT=0$' "$ROOT/.state"
  assert "v1 is live" [ "$(live_version)" = "v1" ]
  finish bad-canary
}

scenario_rollback() {
  log "SCENARIO rollback: promote v2, then undo it instantly"
  baseline
  $REL deploy v2 || FAILURES=$((FAILURES + 1))
  $REL promote   || FAILURES=$((FAILURES + 1))
  assert "v2 is live" [ "$(live_version)" = "v2" ]
  probe_start
  $REL rollback  || FAILURES=$((FAILURES + 1))
  sleep 3
  probe_stop
  assert "zero failed requests during the rollback" [ "$P_ERR" -eq 0 ]
  assert "v1 is live again" [ "$(live_version)" = "v1" ]
  finish rollback
}

case "${1:-all}" in
  bluegreen)   scenario_bluegreen ;;
  canary)      scenario_canary ;;
  bad-health)  scenario_bad_health ;;
  bad-canary)  scenario_bad_canary ;;
  rollback)    scenario_rollback ;;
  all)         scenario_bluegreen; scenario_canary; scenario_bad_health; scenario_bad_canary; scenario_rollback
               echo "All scenarios passed." ;;
  *)           die "usage: $0 [bluegreen|canary|bad-health|bad-canary|rollback|all]" ;;
esac
