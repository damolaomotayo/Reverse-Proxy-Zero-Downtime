"""versioned-app: tiny web app used to demonstrate zero-downtime releases.

Environment:
  VERSION     label shown to users, e.g. v1
  SLOT        blue | green
  FAULT       none | health | errors
                health: /healthz returns 500 (the release gate catches it)
                errors: /healthz is fine but 30% of real requests fail (only live traffic catches it)
  ERROR_RATE  0..1, failure rate used with FAULT=errors (default 0.3)
  PORT, BIND  listen address (default 8080 on 0.0.0.0)

Standard library only, so the image needs nothing from PyPI.
"""
import json
import os
import random
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG = {
    "version": os.environ.get("VERSION", "v1"),
    "slot": os.environ.get("SLOT", "blue"),
    "fault": os.environ.get("FAULT", "none"),
    "error_rate": float(os.environ.get("ERROR_RATE", "0.3")),
}
PORT = int(os.environ.get("PORT", "8080"))
BIND = os.environ.get("BIND", "0.0.0.0")
HOSTNAME = socket.gethostname()


def color_for(version: str) -> str:
    """Same hash as dashboard/index.html, so a version has the same colour everywhere."""
    h = 0
    for ch in version:
        h = (h * 31 + ord(ch)) % 360
    return f"hsl({h}, 65%, 45%)"


def page(version: str, slot: str) -> str:
    return (
        "<!doctype html><meta charset=utf-8><title>versioned-app</title>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<body style='margin:0;font-family:system-ui,sans-serif;color:#fff;"
        f"background:{color_for(version)};display:grid;place-items:center;height:100vh'>"
        f"<div style='text-align:center'><div style='font-size:14vw;font-weight:700'>{version}</div>"
        f"<div style='font-size:2vw;opacity:.85'>served by the {slot} slot</div></div>"
    )


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: str, ctype: str = "application/json") -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-App-Version", CFG["version"])
        self.send_header("X-App-Slot", CFG["slot"])
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self) -> None:  # noqa: N802 (so "curl -I" works)
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        path = self.path.split("?", 1)[0]
        info = {"version": CFG["version"], "slot": CFG["slot"]}

        if path == "/healthz":
            if CFG["fault"] == "health":
                self._send(500, json.dumps({"status": "unhealthy", **info}))
            else:
                self._send(200, json.dumps({"status": "ok", **info}))
            return

        if path in ("/", "/api/version"):
            if CFG["fault"] == "errors" and random.random() < CFG["error_rate"]:
                self._send(500, json.dumps({"error": "simulated failure", **info}))
                return
            if path == "/api/version":
                self._send(200, json.dumps({**info, "host": HOSTNAME}))
            else:
                self._send(200, page(CFG["version"], CFG["slot"]), "text/html; charset=utf-8")
            return

        self._send(404, json.dumps({"error": "not found", **info}))

    def log_message(self, fmt, *args) -> None:  # keep container logs quiet
        pass


def main() -> None:
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"versioned-app {CFG['version']} ({CFG['slot']}, fault={CFG['fault']}) on {BIND}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
