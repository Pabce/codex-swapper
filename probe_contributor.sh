#!/usr/bin/env bash
# Direct probe of muse-spark-1.2-contributor through the NordVPN US SOCKS exit.
# Uses creds from the launch env file; never echoes them.
set -euo pipefail
ENV_FILE="$HOME/.config/codex-swapper/us-proxy.env"
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }
: "${NORD_SOCKS_USER:?fill NORD_SOCKS_USER in $ENV_FILE}"
: "${NORD_SOCKS_PASS:?fill NORD_SOCKS_PASS in $ENV_FILE}"
KEY="$($HOME/.codex/bin/oc-go-key)"
HOST="${US_SOCKS5:-us.socks.nordhold.net:1080}"
BODY='{"model":"muse-spark-1.2-contributor","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with exactly: OK"}]}],"max_output_tokens":32,"reasoning":{"effort":"low"}}'
echo "### muse-spark-1.2-contributor via $HOST"
curl -sS -m 60 --socks5-hostname "$HOST" --proxy-user "${NORD_SOCKS_USER}:${NORD_SOCKS_PASS}" \
  -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "$BODY" https://opencode.ai/zen/go/v1/responses | python3 -c "
import json,sys
d=json.load(sys.stdin)
if d.get('id'):
    print('OK status=', d.get('status'), 'output=', [o.get('type') for o in d.get('output',[])])
else:
    e=d.get('error') or {}
    print('ERR', e.get('type'), str(e.get('message'))[:200])
"
