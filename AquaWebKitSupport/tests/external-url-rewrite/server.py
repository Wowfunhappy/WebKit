import http.server, os, sys
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "site"))
# Redirects the rewritten page follows: one relative, one naming the requested (rewritten) site itself.
REDIRECTS = {
    "/redirect-relative": "/data.json?redirected=relative",
    "/redirect-absolute": "https://rewrite-source.invalid:18990/data.json?redirected=absolute",
}

class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path in REDIRECTS:
            self.send_response(302)
            self.send_header("Location", REDIRECTS[self.path])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.path == "/page.html":
            self.send_header("Set-Cookie", "rewritten=%s; Path=/" % os.environ.get("REWRITE_COOKIE", "1"))
        super().end_headers()
    def log_message(self, fmt, *args):
        sys.stderr.write("%s Host=%s Referer=%s Cookie=%s X-Rewrite-Test=%s X-Page-Header=%s User-Agents=%d User-Agent=%s\n" % (self.requestline, self.headers.get("Host"), self.headers.get("Referer"), self.headers.get("Cookie"), self.headers.get("X-Rewrite-Test"), self.headers.get("X-Page-Header"), len(self.headers.get_all("User-Agent") or []), self.headers.get("User-Agent")))
        sys.stderr.flush()
http.server.ThreadingHTTPServer(("127.0.0.1", 18991), H).serve_forever()
