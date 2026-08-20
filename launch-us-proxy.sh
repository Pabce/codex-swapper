#!/usr/bin/env bash
# US-forwarding proxy for the opencode-go provider (option B).
#
# Default mode: ensure the proxy is listening on 127.0.0.1:<PORT> (idempotent,
# starts it detached if needed) and return. Pass --foreground to run in the
# current terminal instead (manual runs / debugging).
#
# Credentials: ~/.config/codex-swapper/us-proxy.env (chmod 600):
#   NORD_SOCKS_USER=...  NORD_SOCKS_PASS=...
# NordVPN SERVICE credentials (dashboard -> Manual setup -> SOCKS5), not the
# app login. With no creds the proxy runs in pass-through mode (direct egress);
# only the US-only contributor model needs the US exit.
set -euo pipefail

PORT="${1:-18887}"
MODE="${2:-ensure}"
ENV_FILE="$HOME/.config/codex-swapper/us-proxy.env"
PROXY_SCRIPT="/Users/pbarham/opt/codex-swapper/us-forward-proxy.py"
LOG="/tmp/us-proxy.log"

if [ "$MODE" = "--foreground" ]; then
  [ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
  if [ -n "${NORD_SOCKS_USER:-}" ] && [ -n "${NORD_SOCKS_PASS:-}" ]; then
    export US_SOCKS5="${US_SOCKS5:-us.socks.nordhold.net:1080}"
    export US_SOCKS5_USER="$NORD_SOCKS_USER"
    export US_SOCKS5_PASS="$NORD_SOCKS_PASS"
  fi
  exec python3 "$PROXY_SCRIPT" "$PORT"
fi

# ensure mode: no-op when already listening
if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthcheck"; then
  echo "us-proxy already listening on :$PORT"
  exit 0
fi

[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
if [ -n "${NORD_SOCKS_USER:-}" ] && [ -n "${NORD_SOCKS_PASS:-}" ]; then
  export US_SOCKS5="${US_SOCKS5:-us.socks.nordhold.net:1080}"
  export US_SOCKS5_USER="$NORD_SOCKS_USER"
  export US_SOCKS5_PASS="$NORD_SOCKS_PASS"
fi
nohup python3 "$PROXY_SCRIPT" "$PORT" >> "$LOG" 2>&1 &
disown || true
sleep 1
if curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/healthcheck"; then
  echo "us-proxy started on :$PORT (log: $LOG)"
else
  echo "warning: us-proxy did not answer on :$PORT (log: $LOG)" >&2
  exit 1
fi
