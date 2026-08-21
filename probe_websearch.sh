#!/usr/bin/env bash
set -u
KEY="$($HOME/.codex/bin/oc-go-key)"
MODEL="$1"
IN='[{"type":"message","role":"user","content":[{"type":"input_text","text":"What is the capital of France? Be very brief."}]}]'
BODY='{"model":"'"$MODEL"'","input":'"$IN"',"max_output_tokens":96,"tools":[{"type":"web_search"}]}'
echo "### $MODEL"
OUT=$(curl -sS -m 50 -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "$BODY" https://opencode.ai/zen/go/v1/responses)
echo "$OUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('nonjson'); raise SystemExit
if d.get('id'):
    print('OK status=', d.get('status'), 'output=', [o.get('type') for o in d.get('output',[])])
else:
    e=d.get('error') or {}
    print(f\"{e.get('type')}: {str(e.get('message'))[:160]}\")"
