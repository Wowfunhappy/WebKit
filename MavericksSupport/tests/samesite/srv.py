# SameSite enforcement harness. "localhost" and "127.0.0.1" on one port are two sites to WebKit, so the
# same server answers as both and every request logs the Host it was asked as and the Cookie it carried.
# 127.0.0.2 and 127.0.0.3 are two more sites, and 10.9 answers on them only once they are aliased:
#
#   sudo ifconfig lo0 alias 127.0.0.2 up
#   sudo ifconfig lo0 alias 127.0.0.3 up
#   python srv.py 18899
#
# 127.0.0.2 holds a Strict cookie and nothing else, which is the case where an absent Cookie header would
# send everything it had just withheld. 127.0.0.3 sets an unterminated quoted value ahead of a Strict
# cookie, which is the case where a swallowed segment boundary would leave that cookie unmarked.
import BaseHTTPServer, SocketServer, sys, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18899
A = "localhost"
C = "127.0.0.1"
STRICTHOST = "127.0.0.2"
WEIRDHOST = "127.0.0.3"

class H(BaseHTTPServer.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def emit(self, label):
        print "%-28s host=%-22s cookie=%s" % (label, self.headers.get("Host"), self.headers.get("Cookie"))
        sys.stdout.flush()

    def body(self, text, ctype="text/html", extra=None):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(text)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(text)

    def do_GET(self):
        path = urlparse.urlparse(self.path).path
        if path == "/set":
            self.emit("SET")
            # The value names the host that set it, so a cookie that rides a cross-host hop is
            # identifiable at the destination even though both hosts use the same cookie names.
            tag = (self.headers.get("Host") or "?").split(":")[0]
            self.body("<h1>cookies set for %s</h1>" % tag, extra=[
                ("Set-Cookie", "strictc=STRICT_%s; Path=/; SameSite=Strict" % tag),
                ("Set-Cookie", "laxc=LAX_%s; Path=/; SameSite=Lax" % tag),
                ("Set-Cookie", "nonec=NONE_%s; Path=/" % tag),
            ])
        elif path == "/setstrict":
            # This host ends up holding a Strict cookie and NOTHING else, so a cross-site request to it
            # has every cookie withheld. That is the case where an absent Cookie header fails open.
            tag = (self.headers.get("Host") or "?").split(":")[0]
            self.emit("SETSTRICT")
            self.body("<h1>strict-only set for %s</h1>" % tag,
                      extra=[("Set-Cookie", "onlystrict=ONLY_%s; Path=/; SameSite=Strict" % tag)])
        elif path == "/setweird":
            # An unterminated quote in an earlier cookie's value must not swallow the comma before the
            # next one: sid's SameSite=Strict has to survive the segmentation.
            self.emit("SETWEIRD")
            tag = (self.headers.get("Host") or "?").split(":")[0]
            self.body("<h1>weird set for %s</h1>" % tag, extra=[
                ("Set-Cookie", 'weird="x; Path=/'),
                ("Set-Cookie", "sid=SID_%s; Path=/; SameSite=Strict" % tag),
            ])
        elif path == "/link3":
            self.emit("LINK3")
            self.body("<a id=go href='http://%s:%d/probe'>go</a>" % (WEIRDHOST, PORT))
        elif path == "/link2":
            self.emit("LINK2")
            self.body("<a id=go href='http://%s:%d/probe'>go</a>" % (STRICTHOST, PORT))
        elif path == "/probe":
            self.emit("PROBE")
            self.body("probe", "text/plain")
        elif path == "/img":
            self.emit("IMG-SUBRESOURCE")
            self.body("x", "text/plain")
        elif path == "/redir":
            # Same-site request first, then a hop to the OTHER site: any Cookie header written for the
            # first hop must not survive to the second.
            self.emit("REDIR-HOP1")
            target = "http://%s:%d/probe" % (C, PORT)
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        elif path == "/page":
            self.emit("PAGE")
            self.body("<h1>cross-site embed</h1><img src='http://%s:%d/img'>" % (A, PORT))
        elif path == "/form":
            # A cross-site POST is the unsafe-method case: Lax must be withheld as well as Strict.
            self.emit("FORM")
            self.body("<form id=f method=POST action='http://%s:%d/probe'>"
                      "<input name=q value=1></form>" % (A, PORT))
        elif path == "/link":
            self.emit("LINK")
            self.body("<a id=go href='http://%s:%d/probe'>go</a>" % (A, PORT))
        else:
            self.body("<h1>ok</h1>")

    def do_POST(self):
        self.emit("PROBE-POST")
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.body("posted", "text/plain")

class S(SocketServer.ThreadingMixIn, BaseHTTPServer.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

print "listening on %d" % PORT
sys.stdout.flush()
S(("0.0.0.0", PORT), H).serve_forever()
