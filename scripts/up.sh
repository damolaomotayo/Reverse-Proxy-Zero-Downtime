#!/usr/bin/env bash
# Builds and starts nginx + the blue and green app slots with a clean baseline:
# both slots run v1, blue serves 100% of traffic.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ensure_env

log "Resetting to the baseline (blue = v1 live, green = v1 idle)"
set_env BLUE_VERSION v1;  set_env GREEN_VERSION v1
set_env BLUE_FAULT none;  set_env GREEN_FAULT none
ACTIVE=blue; PCT=0; SWAPBACK=0
write_upstream_file
save_state

log "Building and starting the stack"
$DC up -d --build

log "Waiting for everything to answer"
wait_http "Proxy (nginx)" "$PROXY_URL/nginx-health" 60
for s in blue green; do
  if wait_slot_healthy "$s" 30; then ok "$s slot is healthy"; else die "$s slot did not become healthy. Run: $DC logs app-$s"; fi
done

IP="$(public_ip)"
cat <<EOF

Stack is up. Open these in your browser (the same laptop that is allowed by the security group):
  Site       : http://${IP}/
  Dashboard  : http://${IP}/dashboard/      <- keep this open during the demo

Next: ./scripts/smoke.sh   then   ./scripts/demo.sh all
EOF
