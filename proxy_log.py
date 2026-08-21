#!/usr/bin/env python3
"""Logging reverse proxy (curl forwarding) for capturing Codex request bodies."""
import http.server
import json
import subprocess
import sys

LOG = open("/tmp/codex_req.log", "w")


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        LOG.write("===== %s =====\n" % self.path)
        redacted = {k: (v[:12] + "...") if k.lower() == "authorization" else v
                    for k, v in self.headers.items()}
        LOG.write("HEADERS: %s\n" % json.dumps(redacted))
        try:
            LOG.write("BODY: " + json.dumps(json.loads(body)) + "\n")
        except Exception:
            LOG.write("BODY(raw): " + body.decode(errors="replace") + "\n")
        LOG.flush()
        out = subprocess.run(
            ["curl", "-sS", "-m", "60", "-X", "POST",
             "-H", "Authorization: %s" % self.headers.get("Authorization", ""),
             "-H", "Content-Type: application/json",
             "-d", body.decode(),
             "https://opencode.ai/zen/go/v1" + self.path],
            capture_output=True, text=True, timeout=70)
        status = 502
        body = out.stdout.encode()
        if out.returncode != 0:
            body = out.stderr.encode()
        else:
            status = 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
