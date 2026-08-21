#!/usr/bin/env python3
"""US-forwarding proxy for the opencode-go provider (scoped, per-model).

Listens on 127.0.0.1 and forwards POST /responses to the real opencode-go
gateway. Only models matching US_SOCKS5_MODELS (default: muse-spark) take the
US exit, so the gateway's per-source-IP region check sees a US address for
those requests; every other model is forwarded direct (no VPN). Only
opencode-go API traffic goes through this proxy -- nothing else on the machine
is routed.

Exit selection (first set wins):
  1. US_SOCKS5=<host:port>     -> a SOCKS5 proxy (ssh -D, microsocks, VPN SOCKS5)
     US_SOCKS5_USER / US_SOCKS5_PASS -> optional SOCKS5 credentials (NordVPN
     service credentials). Set them via the launch wrapper or your shell; they
     are never logged or written to disk by this script.
  2. US_HTTP=<host:port>       -> an HTTP/HTTPS CONNECT proxy
  3. (neither)                 -> direct (no US exit); use for a dry-run

Model selection:
  US_SOCKS5_MODELS=prefix1,prefix2  (default "muse-spark"). A request is routed
  through the US exit iff its `model` field starts with one of these prefixes.

Usage:
  US_SOCKS5=us-host:1080 python3 us-forward-proxy.py 18887
  curl -x http://127.0.0.1:18887 https://opencode.ai/zen/go/v1/models   # smoke
"""
import http.server
import json
import os
import subprocess
import sys

TARGET = "https://opencode.ai/zen/go/v1"
SOCKS = os.environ.get("US_SOCKS5")
HTTPP = os.environ.get("US_HTTP")
USR = os.environ.get("US_SOCKS5_USER")
PWD = os.environ.get("US_SOCKS5_PASS")
MODEL_PREFIXES = [
    p.strip() for p in os.environ.get("US_SOCKS5_MODELS", "muse-spark").split(",")
    if p.strip()
]

# Only engage the US exit when a SOCKS host AND (both creds or no creds) are
# present. A half-configured exit (one of user/pass missing) silently falls
# back to direct pass-through so the provider keeps working.
if SOCKS and ((USR and PWD) or not (USR or PWD)):
    pass
else:
    if SOCKS and (USR or PWD):
        print("us-forward-proxy: US_SOCKS5 set with only one of "
              "US_SOCKS5_USER/PASS; ignoring the US exit (direct pass-through)",
              file=sys.stderr)
    SOCKS = None


def model_uses_us(model: str) -> bool:
    """True when the request model should egress through the US exit."""
    if not (SOCKS or HTTPP):
        return False  # no US exit configured
    return any(model.startswith(p) for p in MODEL_PREFIXES)


def curl_cmd(use_us: bool):
    # The whole upstream response is buffered through this proxy, so the
    # max-time must cover real long turns (90s killed long muse turns).
    cmd = ["curl", "-sS", "-m", "600", "-X", "POST"]
    if use_us and SOCKS:
        cmd += ["--socks5-hostname", SOCKS]
        if USR and PWD:
            cmd += ["--proxy-user", f"{USR}:{PWD}"]
    elif use_us and HTTPP:
        cmd += ["-x", HTTPP]
    return cmd


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        # The provider base_url is http://127.0.0.1:<port>/v1, so requests
        # arrive as /v1/responses; TARGET already ends in /v1, so strip the
        # duplicate prefix before forwarding.
        fwd_path = self.path
        if fwd_path.startswith("/v1"):
            fwd_path = fwd_path[3:]
        if not fwd_path.startswith("/"):
            fwd_path = "/" + fwd_path
        try:
            model = json.loads(body).get("model", "")
        except Exception:
            model = ""
        use_us = model_uses_us(model)
        print(f"us-forward-proxy: {model or '<unknown>'} -> "
              f"{'US exit' if use_us else 'direct'}", flush=True)
        # Forward with the original auth header; drop hop-by-hop headers.
        # The body goes via stdin (--data-binary @-): passing it as a
        # command-line -d argument blew past macOS ARG_MAX (1 MiB) for large
        # conversation contexts, crashing the handler mid-request
        # ("Argument list too long", client saw 'stream disconnected').
        out = subprocess.run(
            curl_cmd(use_us)
            + ["-H", "Authorization: %s" % self.headers.get("Authorization", ""),
               "-H", "Content-Type: application/json",
               "--data-binary", "@-",
               TARGET + fwd_path],
            input=body,
            capture_output=True, timeout=610)
        if out.returncode != 0:
            self.send_response(502)
            payload = ("proxy error: "
                       + out.stderr.decode(errors="replace")[:300]).encode()
        else:
            self.send_response(200)
            payload = out.stdout
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
