#!/usr/bin/env bash
# Removes everything this project created on the instance.
# Usage: ./scripts/destroy.sh [--keep-env]
set -uo pipefail
. "$(dirname "$0")/lib.sh"

log "Stopping the stack"
$DC down -v --remove-orphans

log "Removing the project image"
$DOCKER rmi -f zd-app:local >/dev/null 2>&1 || true
$DOCKER image prune -f >/dev/null 2>&1 || true

rm -f "$ROOT/.state" "$ROOT/.probe-stop" "$UPSTREAM_FILE"
if [ "${1:-}" != "--keep-env" ]; then rm -f "$ROOT/.env"; fi

echo
echo "Cleanup done."
echo "IMPORTANT: terminate the EC2 instance in the AWS console (EC2 > Instances >"
echo "Instance state > Terminate) so it stops costing money. Then delete the security group."
