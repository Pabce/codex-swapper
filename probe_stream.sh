#!/usr/bin/env bash
# Streaming probe: POST /responses with stream:true, print first SSE events / errors.
set -u
KEY="$($HOME/.codex/bin/oc-go-key)"
MODEL="$1"
BODY='{"model":"'"$MODEL"'","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with exactly: OK"}]}],"instructions":"You are Codex, an agentic coding assistant.","reasoning":{"effort":"low"},"tools":[{"type":"function","name":"shell_command","description":"Run a shell command.","parameters":{"type":"object","properties":{},"additionalProperties":false}}],"tool_choice":"auto","store":false,"stream":true,"max_output_tokens":8}'
echo "### $MODEL"
curl -sS -m 40 -N -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "$BODY" https://opencode.ai/zen/go/v1/responses \
  | head -c 1200
echo
