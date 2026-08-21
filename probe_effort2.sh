#!/usr/bin/env bash
set -u
KEY="$($HOME/.codex/bin/oc-go-key)"
MODEL="$1"; shift
IN='[{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]}]'
for EFF in "$@"; do
  BODY='{"model":"'"$MODEL"'","input":'"$IN"',"max_output_tokens":16,"reasoning":{"effort":"'"$EFF"'"}}'
  OUT=$(curl -sS -m 40 -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "$BODY" https://opencode.ai/zen/go/v1/responses)
  CODE=$(echo "$OUT" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('nonjson'); raise SystemExit
if d.get('id'):
    print('OK'); raise SystemExit
e=d.get('error') or {}
print(f\"{e.get('type')}: {str(e.get('message'))[:110]}\")")
  echo "  $EFF -> $CODE"
done
