#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts, not run directly.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Use plain docker if the current user may talk to the daemon, otherwise sudo.
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi
DC="$DOCKER compose"

PROXY_URL="${PROXY_URL:-http://127.0.0.1}"        # the proxy, as seen from the instance itself
UPSTREAM_FILE="$ROOT/nginx/upstream/upstream.conf"
STATE_FILE="$ROOT/.state"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- .env ----------
ensure_env() { [ -f "$ROOT/.env" ] || cp "$ROOT/.env.example" "$ROOT/.env"; load_env; }
load_env()   { set -a; . "$ROOT/.env"; set +a; }
need_env()   { [ -f "$ROOT/.env" ] || die ".env not found. Run ./scripts/up.sh first."; load_env; }
set_env() { # KEY VALUE: replace the line in .env, or append it
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ROOT/.env"; then sed -i "s|^${k}=.*|${k}=${v}|" "$ROOT/.env"; else echo "${k}=${v}" >> "$ROOT/.env"; fi
}
env_get() { grep "^$1=" "$ROOT/.env" 2>/dev/null | head -n1 | cut -d= -f2-; }

# ---------- networking ----------
public_ip() { # EC2 metadata (IMDSv2), then a public what-is-my-ip fallback
  local tok ip=""
  tok="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [ -n "$tok" ]; then
    ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $tok" \
          http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -fsS -m 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  echo "${ip:-<EC2-PUBLIC-IP>}"
}

http_code() { curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null || true; }  # 000 = no connection

wait_http() { # LABEL URL [SECONDS]  (any 2xx)
  local label="$1" url="$2" secs="${3:-60}" i
  for ((i = 0; i < secs; i++)); do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then ok "$label is up"; return 0; fi
    sleep 1
  done
  fail "$label did not answer at $url within ${secs}s"
  return 1
}

wait_live() { # VERSION [SECONDS]: wait until the proxy answers with VERSION 3 times in a row
  # "nginx -s reload" returns at once; old workers may answer for a few more milliseconds.
  local want="$1" secs="${2:-5}" i got good=0
  for ((i = 0; i < secs * 10; i++)); do
    got="$(curl -s -m 2 "$PROXY_URL/api/version" 2>/dev/null |
      python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", ""))' 2>/dev/null || true)"
    if [ "$got" = "$want" ]; then good=$((good + 1)); [ "$good" -ge 3 ] && return 0; else good=0; fi
    sleep 0.1
  done
  return 1
}

json_get() { # FILE PYTHON-EXPR-USING-d   e.g. json_get r.json "d['total']"
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# ---------- slots ----------
upper()   { echo "$1" | tr '[:lower:]' '[:upper:]'; }
other()   { if [ "$1" = blue ]; then echo green; else echo blue; fi; }
slot_url() { # direct address of a slot from the instance (env overrides are for testing only)
  case "$1" in
    blue)  echo "${SLOT_URL_BLUE:-http://127.0.0.1:18081}" ;;
    green) echo "${SLOT_URL_GREEN:-http://127.0.0.1:18082}" ;;
  esac
}
slot_version() {
  curl -s -m 3 "$(slot_url "$1")/healthz" 2>/dev/null |
    python3 -c 'import sys, json; print(json.load(sys.stdin).get("version", "?"))' 2>/dev/null || echo "?"
}
wait_slot_healthy() { # SLOT [SECONDS]: needs 3 consecutive HTTP 200 on /healthz
  local slot="$1" secs="${2:-20}" good=0 i
  for ((i = 0; i < secs * 2; i++)); do
    if [ "$(http_code "$(slot_url "$slot")/healthz")" = "200" ]; then
      good=$((good + 1)); [ "$good" -ge 3 ] && return 0
    else
      good=0
    fi
    sleep 0.5
  done
  return 1
}

# ---------- routing state ----------
# ACTIVE = slot that serves traffic. PCT = percent of traffic sent to the OTHER (idle) slot (canary).
# SWAPBACK=1 means the idle slot still holds the previous version, so "rollback" can swap back to it.
load_state() { ACTIVE=blue; PCT=0; SWAPBACK=0; if [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi; return 0; }
save_state() { printf 'ACTIVE=%s\nPCT=%s\nSWAPBACK=%s\n' "$ACTIVE" "$PCT" "$SWAPBACK" > "$STATE_FILE"; }

render_upstream() { # prints the nginx server lines for the current ACTIVE/PCT
  local bw gw s w
  if [ "$ACTIVE" = blue ]; then bw=$((100 - PCT)); gw=$PCT; else gw=$((100 - PCT)); bw=$PCT; fi
  for s in blue green; do
    if [ "$s" = blue ]; then w=$bw; else w=$gw; fi
    if [ "$w" -eq 0 ]; then echo "server app-${s}:8080 down;"; else echo "server app-${s}:8080 weight=${w};"; fi
  done
}
write_upstream_file() { mkdir -p "$(dirname "$UPSTREAM_FILE")"; render_upstream > "$UPSTREAM_FILE"; }

nginx_test()   { $DC exec -T nginx nginx -t; }
nginx_reload() { $DC exec -T nginx nginx -s reload; }

apply_routing() { # write upstream.conf, validate, graceful reload, remember the state
  local old=""
  [ -f "$UPSTREAM_FILE" ] && old="$(cat "$UPSTREAM_FILE")"
  write_upstream_file
  if ! nginx_test >/dev/null 2>&1; then
    if [ -n "$old" ]; then printf '%s\n' "$old" > "$UPSTREAM_FILE"; fi
    die "nginx rejected the new routing. The old routing was restored."
  fi
  nginx_reload >/dev/null 2>&1 || die "nginx reload failed (is the nginx container running?)"
  save_state
}
