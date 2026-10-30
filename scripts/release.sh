#!/usr/bin/env bash
# Release controller for the blue/green + canary demo.
#
#   release.sh status                     who runs what, and where the traffic goes
#   release.sh deploy <version> [fault]   put a new version on the IDLE slot (0% traffic) and health-check it
#                                         fault (to simulate a bad release): none | health | errors
#   release.sh canary <pct> [--watch S]   send <pct>% of traffic to the new version; with --watch, check
#                                         it for S seconds and roll back automatically if it misbehaves
#   release.sh promote                    blue-green cutover: 100% to the new version (old one stays running)
#   release.sh rollback                   cancel a canary, or swap back to the previous version after a promote
#   release.sh reset                      back to the baseline: both slots v1, blue live
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need_env
load_state

MAX_ERR_PCT="${CANARY_MAX_ERR_PCT:-5}"   # canary is rolled back if more than this % of its requests fail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
blocked() { printf '  \033[1;31mBLOCKED\033[0m %s\n' "$*"; }   # an expected, protective refusal (not a script error)

cmd_status() {
  local s v f h t
  printf '\n  %-6s %-14s %-8s %-7s %s\n' SLOT VERSION FAULT HEALTH TRAFFIC
  for s in blue green; do
    v="$(slot_version "$s")"
    f="$(env_get "$(upper "$s")_FAULT")"
    h="$(http_code "$(slot_url "$s")/healthz")"
    if [ "$s" = "$ACTIVE" ]; then t="$((100 - PCT))%"; else t="${PCT}%"; fi
    printf '  %-6s %-14s %-8s %-7s %s\n' "$s" "$v" "${f:-none}" "$h" "$t"
  done
  echo
  echo "  Site: http://$(public_ip)/     Dashboard: http://$(public_ip)/dashboard/"
}

cmd_deploy() {
  local version="${1:-}" fault="${2:-none}" idle
  [ -n "$version" ] || die "usage: release.sh deploy <version> [none|health|errors]"
  case "$fault" in none | health | errors) ;; *) die "fault must be none, health or errors" ;; esac
  idle="$(other "$ACTIVE")"

  if [ "$PCT" -gt 0 ]; then
    log "A canary is running on $idle. Cancelling it first."
    PCT=0; apply_routing
  fi

  log "Deploying $version to the idle slot ($idle). It gets 0% of traffic until you say so."
  set_env "$(upper "$idle")_VERSION" "$version"
  set_env "$(upper "$idle")_FAULT" "$fault"
  $DC up -d --no-deps --force-recreate "app-$idle" >/dev/null 2>&1 || die "could not start app-$idle"
  SWAPBACK=0; save_state   # the old idle version is gone, so there is nothing to swap back to

  log "Health gate: /healthz on $idle must answer 200 three times in a row"
  if ! wait_slot_healthy "$idle" 20; then
    blocked "$version failed its health check."
    $DC logs --tail 15 "app-$idle" 2>&1 | sed 's/^/      /' || true
    echo "!! Release BLOCKED. Nothing changed for users: $ACTIVE ($(slot_version "$ACTIVE")) is still serving 100%."
    exit 1
  fi
  ok "$version is healthy on $idle, serving 0% of traffic"
  echo "   Next: release.sh canary 10 --watch 15    or    release.sh promote"
}

cmd_canary() {
  local pct="${1:-}" watch=0 idle cand tmp total err
  [ -n "$pct" ] || die "usage: release.sh canary <1-99> [--watch SECONDS]"
  case "$pct" in '' | *[!0-9]*) die "percent must be a whole number" ;; esac
  [ "$pct" -ge 1 ] && [ "$pct" -le 99 ] || die "percent must be between 1 and 99"
  if [ "${2:-}" = "--watch" ]; then watch="${3:-15}"; fi
  idle="$(other "$ACTIVE")"
  [ "$(http_code "$(slot_url "$idle")/healthz")" = "200" ] || die "$idle is not healthy. Run release.sh deploy first."

  cand="$(slot_version "$idle")"
  PCT="$pct"; apply_routing
  ok "Canary: ${pct}% of traffic now goes to $cand ($idle), the rest stays on $(slot_version "$ACTIVE")"

  [ "$watch" -gt 0 ] || { echo "   Next: release.sh promote    or    release.sh rollback"; return 0; }

  log "Watching the canary for ${watch}s (limit: ${MAX_ERR_PCT}% failed requests)"
  tmp="$(mktemp)"
  python3 "$ROOT/tools/probe.py" --url "$PROXY_URL/api/version" --duration "$watch" --rps 20 --json > "$tmp"
  python3 "$ROOT/tools/probe.py" --report "$tmp"
  read -r total err < <(python3 - "$tmp" "$cand" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); cand = sys.argv[2]
total = err = 0
for version, c in d["by_version"].items():
    if version == cand or version == "none":          # "none" = no answer at all, counts against the canary
        total += c["ok"] + c["err"]; err += c["err"]
print(total, err)
EOF
)
  rm -f "$tmp"
  if [ "$total" -gt 0 ] && [ $((err * 100)) -gt $((MAX_ERR_PCT * total)) ]; then
    blocked "Canary $cand: $err of $total requests failed (limit ${MAX_ERR_PCT}%)"
    PCT=0; apply_routing
    wait_live "$(slot_version "$ACTIVE")" 5 || true
    echo "!! Canary ROLLED BACK automatically. 100% of traffic is back on $(slot_version "$ACTIVE")."
    exit 1
  fi
  ok "Canary $cand looks healthy: $err of $total requests failed"
  echo "   Next: release.sh promote"
}

cmd_promote() {
  local idle old
  idle="$(other "$ACTIVE")"; old="$ACTIVE"
  [ "$(http_code "$(slot_url "$idle")/healthz")" = "200" ] || die "$idle is not healthy. Run release.sh deploy first."
  ACTIVE="$idle"; PCT=0; SWAPBACK=1
  apply_routing
  wait_live "$(slot_version "$ACTIVE")" 5 || echo "   (warning: the proxy has not switched over yet; check release.sh status)"
  ok "Cutover done: 100% of traffic now on $(slot_version "$ACTIVE") ($ACTIVE)"
  echo "   $(slot_version "$old") is still running on $old, so 'release.sh rollback' is instant."
}

cmd_rollback() {
  local other_slot
  other_slot="$(other "$ACTIVE")"
  if [ "$PCT" -gt 0 ]; then
    PCT=0; apply_routing
    wait_live "$(slot_version "$ACTIVE")" 5 || true
    ok "Canary cancelled. 100% of traffic is on $(slot_version "$ACTIVE")"
  elif [ "$SWAPBACK" -eq 1 ]; then
    [ "$(http_code "$(slot_url "$other_slot")/healthz")" = "200" ] || die "the previous version on $other_slot is not healthy"
    ACTIVE="$other_slot"; SWAPBACK=0
    apply_routing
    wait_live "$(slot_version "$ACTIVE")" 5 || echo "   (warning: the proxy has not switched over yet; check release.sh status)"
    ok "Rolled back: 100% of traffic is on $(slot_version "$ACTIVE") ($ACTIVE)"
  else
    die "nothing to roll back (no canary running and no promote to undo)"
  fi
}

cmd_reset() {
  log "Reset: both slots to v1, blue live"
  set_env BLUE_VERSION v1;  set_env GREEN_VERSION v1
  set_env BLUE_FAULT none;  set_env GREEN_FAULT none
  $DC up -d --no-deps --force-recreate app-blue app-green >/dev/null 2>&1 || die "could not recreate the app slots"
  wait_slot_healthy blue 30  || die "blue did not become healthy"
  wait_slot_healthy green 30 || die "green did not become healthy"
  ACTIVE=blue; PCT=0; SWAPBACK=0
  apply_routing
  wait_live v1 5 || die "the proxy is not serving v1 after the reset"
  ok "Baseline restored"
}

cmd="${1:-status}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  status)          cmd_status ;;
  deploy)          cmd_deploy "$@" ;;
  canary)          cmd_canary "$@" ;;
  promote | switch) cmd_promote ;;
  rollback)        cmd_rollback ;;
  reset)           cmd_reset ;;
  *)               usage; exit 1 ;;
esac
