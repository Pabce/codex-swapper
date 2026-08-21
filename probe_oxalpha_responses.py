#!/usr/bin/env python3
"""Probe Ox Alpha (x-preview-f-free) against the Zen gateway Responses API.

Covers the four things Codex needs from a wire_api="responses" model:
  1) basic non-streaming turn
  2) SSE streaming (event inventory + assembled output_text)
  3) function-call emission (tool_choice auto)
  4) function-call round trip (feeding function_call_output back)

Usage: probe_oxalpha_responses.py [model] [base_url]
  default model:    x-preview-f-free   (zen/v1) ; ox-alpha-free (zen/go/v1)
  default base url: https://opencode.ai/zen/v1

NOTE: urllib gets 403 from Cloudflare (python-urllib UA); this script shells
out to curl to match the other probe_*.sh scripts.
"""
import json
import os
import subprocess
import sys

BASE = sys.argv[2] if len(sys.argv) > 2 else "https://opencode.ai/zen/v1"
URL = f"{BASE}/responses"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "x-preview-f-free"


def curl_json(body):
    p = subprocess.run(
        [
            "curl",
            "-sS",
            "-m",
            "120",
            "-X",
            "POST",
            "-H",
            f"Authorization: Bearer {zen_key()}",
            "-H",
            "Content-Type: application/json",
            "-d",
            json.dumps(body),
            URL,
        ],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:200])
    return json.loads(p.stdout)


def curl_stream_sse(body):
    """Return (events, deltas, final_response) from an SSE /responses stream."""
    body = dict(body, stream=True)
    p = subprocess.run(
        [
            "curl",
            "-sS",
            "-m",
            "120",
            "-N",
            "-X",
            "POST",
            "-H",
            f"Authorization: Bearer {zen_key()}",
            "-H",
            "Content-Type: application/json",
            "-d",
            json.dumps(body),
            URL,
        ],
        capture_output=True,
        text=True,
        timeout=130,
    )
    events, deltas, final, data_buf = [], [], None, []
    for line in p.stdout.splitlines():
        if line.startswith("event:"):
            events.append(line.split(":", 1)[1].strip())
        elif line.startswith("data:"):
            data_buf.append(line.split(":", 1)[1].strip())
        elif line == "" and data_buf:
            try:
                obj = json.loads("\n".join(data_buf))
            except Exception:
                obj = None
            data_buf = []
            if not isinstance(obj, dict):
                continue
            etype = obj.get("type", "")
            if etype == "response.output_text.delta":
                deltas.append(obj.get("delta", ""))
            if etype == "response.completed":
                final = obj.get("response")
    return events, deltas, final


def zen_key() -> str:
    return subprocess.check_output(
        [os.path.expanduser("~/.codex/bin/oc-go-key")], text=True
    ).strip()


def post(body):
    req = urllib.request.Request(
        URL,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {zen_key()}",
            "Content-Type": "application/json",
        },
    )
    return urllib.request.urlopen(req, timeout=120)


def output_texts(resp):
    parts = []
    for item in resp.get("output", []):
        if item.get("type") == "message":
            for c in item.get("content", []):
                parts.append(c.get("text", ""))
    return "".join(parts)


def show(tag, ok, detail):
    print(f"[{'PASS' if ok else 'FAIL'}] {tag}: {detail}")


def main():
    print(f"model: {MODEL}\nendpoint: {URL}\n")

    # 1) Basic turn
    body = {
        "model": MODEL,
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "Reply with exactly: OK"}],
            }
        ],
        "max_output_tokens": 1024,
        "store": False,
    }
    try:
        r1 = curl_json(body)
    except Exception as e:
        print(f"[FAIL] basic turn: HTTP error {e}")
        return
    if r1.get("id"):
        t = output_texts(r1)
        u = r1.get("usage", {})
        show(
            "basic turn",
            bool(t.strip()),
            f"status={r1.get('status')} text={t!r} out_tokens={u.get('output_tokens')} cost={r1.get('cost')}",
        )
    else:
        show("basic turn", False, json.dumps(r1)[:300])
        return

    # 2) Streaming
    try:
        events, deltas, final = curl_stream_sse(body)
    except Exception as e:
        show("streaming", False, f"HTTP error {e}")
        events, deltas, final = [], [], None

    if final is not None:
        streamed_text = "".join(deltas)
        show(
            "streaming",
            bool(streamed_text.strip()),
            f"{len(events)} events, types={sorted(set(events))[:6]}..., "
            f"assembled={streamed_text!r}",
        )
    elif events:
        show("streaming", False, f"no response.completed seen; events={events[:10]}")
    else:
        show("streaming", False, "no SSE events received")

    # 3) Function call emission
    tools_body = {
        "model": MODEL,
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": "What is the weather in Paris? Use the get_weather tool.",
                    }
                ],
            }
        ],
        "tools": [
            {
                "type": "function",
                "name": "get_weather",
                "description": "Get current weather for a city.",
                "parameters": {
                    "type": "object",
                    "properties": {"location": {"type": "string"}},
                    "required": ["location"],
                    "additionalProperties": False,
                },
            }
        ],
        "tool_choice": "auto",
        "max_output_tokens": 2048,
        "store": False,
    }
    try:
        r3 = curl_json(tools_body)
    except Exception as e:
        show("tool call", False, f"HTTP error {e}")
        return
    calls = [o for o in r3.get("output", []) if o.get("type") == "function_call"]
    if r3.get("id") and calls:
        c = calls[0]
        args = c.get("arguments", "")
        try:
            parsed = json.loads(args)
            args_ok = isinstance(parsed, dict) and parsed.get("location")
        except Exception:
            args_ok = False
        show(
            "tool call",
            args_ok,
            f"name={c.get('name')} call_id={c.get('call_id')} arguments={args!r}",
        )
    else:
        err = r3.get("error") or {}
        show(
            "tool call",
            False,
            f"id={bool(r3.get('id'))} output_types={[o.get('type') for o in r3.get('output', [])]} "
            f"text={output_texts(r3)[:80]!r} err={err.get('message', '')[:120]}",
        )
        return

    # 4) Round trip: feed the tool result back
    rt_input = [
        tools_body["input"][0],
        c,
        {
            "type": "function_call_output",
            "call_id": c["call_id"],
            "output": json.dumps({"temperature_c": 21, "sky": "sunny"}),
        },
    ]
    rt_body = dict(tools_body, input=rt_input)
    try:
        r4 = curl_json(rt_body)
    except Exception as e:
        show("round trip", False, f"HTTP error {e}")
        return
    if r4.get("id"):
        t4 = output_texts(r4)
        show(
            "round trip",
            bool(t4.strip()),
            f"text={t4[:160]!r} cost={r4.get('cost')}",
        )
    else:
        err = r4.get("error") or {}
        show("round trip", False, f"err={err.get('message', '')[:200]}")


if __name__ == "__main__":
    main()
