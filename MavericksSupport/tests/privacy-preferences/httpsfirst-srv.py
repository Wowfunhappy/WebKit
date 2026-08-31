#!/usr/bin/env python3
"""Answers http://wktest.example:8080/ and reports whether WebKit tried https first.

HTTPS-by-default rewrites a plain-http main-frame navigation to https before it leaves the
process, keeping a non-default port, so the upgraded attempt lands on this same socket as a TLS
ClientHello (record type 0x16). The plain GET that follows is the automatic fallback.

    python3 httpsfirst-srv.py [port]
    open http://wktest.example:8080/

Run it on port 80 (as root) to watch the fallback instead: the upgraded https://wktest.example/
has no listener at all, which is what an http-only site looks like.

Every accepted connection prints its first bytes; "TLS" means the upgrade happened.
"""

import socket
import socketserver
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

PAGE = b"""<!DOCTYPE html>
<meta charset="utf-8">
<title>https-first: served over %s</title>
<body style="font:13px -apple-system,sans-serif;margin:2em">
<h1>Served over %s</h1>
<p>Watch the server's stdout: a <b>TLS</b> line for this host means the http navigation was
upgraded to https first and fell back when the handshake failed.</p>
"""


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            head = sock.recv(4)
        except (socket.timeout, OSError):
            head = b""
        if head[:1] == b"\x16":
            print("TLS      %s:%d  ClientHello %s" % (self.client_address + (head.hex(),)), flush=True)
            return
        if not head:
            print("EMPTY    %s:%d" % self.client_address, flush=True)
            return
        rest = b""
        try:
            while b"\r\n\r\n" not in head + rest:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                rest += chunk
        except (socket.timeout, OSError):
            pass
        request_line = (head + rest).split(b"\r\n", 1)[0]
        print("PLAIN    %s:%d  %s" % (self.client_address + (request_line.decode("latin-1"),)), flush=True)
        body = PAGE % (b"http", b"http")
        sock.sendall(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("", PORT), Handler) as server:
        print("listening on port %d; open http://wktest.example:%d/" % (PORT, PORT), flush=True)
        server.serve_forever()
