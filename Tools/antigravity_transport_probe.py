#!/usr/bin/env python3
"""Run the compiled Swift transport probe against synthetic loopback services."""
import http.server
import json
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

QUOTA = {"groups": [{"displayName": "Gemini", "buckets": [{"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.42}]}]}
STATUS = {"userStatus": {"cascadeModelConfigData": {"clientModelConfigs": []}}}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        assert self.headers.get("x-codeium-csrf-token") == "synthetic"
        mode = self.server.mode
        if mode == "slow":
            time.sleep(2)
        if mode == "redirect":
            self.send_response(307)
            self.send_header("Location", "http://127.0.0.1:%d%s" % (self.server.target_port, self.path))
            self.end_headers()
            return
        status = self.path.endswith("GetUserStatus")
        if mode == "status-failure" and status:
            self.send_response(503)
            self.end_headers()
            return
        body = b"A" * 1_100_000 if mode == "oversized" else json.dumps(STATUS if status else QUOTA).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

class IPv6Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

with tempfile.TemporaryDirectory(prefix="quotai-transport-") as directory:
    root = pathlib.Path(directory)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1", "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    servers = []
    for mode in ["http", "https", "ipv6", "redirect", "oversized", "status-failure", "slow"]:
        server = (IPv6Server if mode == "ipv6" else http.server.ThreadingHTTPServer)(("::1" if mode == "ipv6" else "127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server.mode = mode
        if mode == "https":
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(root / "cert.pem", root / "key.pem")
            server.socket = context.wrap_socket(server.socket, server_side=True)
        if mode == "redirect":
            server.target_port = servers[0].server_port
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([sys.argv[1]] + [str(s.server_port) for s in servers], check=True, timeout=30)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
