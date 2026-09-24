import http.server, os, sys
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "site"))
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.path == "/page.html":
            self.send_header("Set-Cookie", "rewritten=%s; Path=/" % os.environ.get("REWRITE_COOKIE", "1"))
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("%s Host=%s Referer=%s Cookie=%s\n" % (self.requestline, self.headers.get("Host"), self.headers.get("Referer"), self.headers.get("Cookie")))
        sys.stderr.flush()
http.server.ThreadingHTTPServer(("127.0.0.1", 18991), H).serve_forever()
