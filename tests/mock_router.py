#!/usr/bin/env python3
"""A tiny stand-in for a Keenetic router's RCI API, used by tests/run.sh."""
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOGIN = "admin"
PASSWORD = "secret"
REALM = "Keenetic Test"
CHALLENGE = "AyM35b2serUTgwrbd1dJF2nNiA373zTG"
MAC = "a0:78:17:a3:67:09"

POLICIES = {
    "Policy0": {"description": "VPN", "mark": "ffffd00", "table4": 42,
                "route4": {"route": [{"destination": "0.0.0.0/0",
                                      "interface": "Wireguard0"}]}},
    "Policy1": {"description": "Work", "mark": "ffffd01", "table4": 43},
}

state = {"policy": "Policy1"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/auth":
            self.send_response(401)
            self.send_header("X-NDM-Realm", REALM)
            self.send_header("X-NDM-Challenge", CHALLENGE)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/rci/show/ip/policy":
            return self.reply(200, POLICIES)
        if self.path == "/rci/show/ip/hotspot":
            return self.reply(200, {"host": [
                {"mac": "11:22:33:44:55:66", "ip": "192.168.1.5", "policy": "Policy0"},
                {"mac": MAC, "ip": "192.168.1.30", "name": "test-mac",
                 "policy": state["policy"]},
            ]})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            data = {}

        if self.path == "/auth":
            inner = hashlib.md5(f"{LOGIN}:{REALM}:{PASSWORD}".encode()).hexdigest()
            expected = hashlib.sha256((CHALLENGE + inner).encode()).hexdigest()
            if data.get("login") == LOGIN and data.get("password") == expected:
                return self.reply(200, {"auth": "ok"})
            return self.reply(401, {"error": "auth failed"})

        if self.path == "/rci/ip/hotspot/host/policy":
            if str(data.get("mac", "")).lower() != MAC:
                return self.reply(200, {"error": "unknown host"})
            if data.get("no"):
                state["policy"] = ""
            else:
                state["policy"] = data.get("policy", state["policy"])
            return self.reply(200, {"status": "ok"})

        self.reply(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
