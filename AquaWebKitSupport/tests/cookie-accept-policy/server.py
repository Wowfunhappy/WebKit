#!/usr/bin/env python
# Two loopback origins -- 127.0.0.1 is the first party, localhost the third -- so one page exercises
# both halves of the cookie accept policy. Each origin answers /set (Set-Cookie) and /read (reports the
# Cookie header it received). localhost resolves to ::1 before 127.0.0.1 here, so the same handler is
# served on both families.
import BaseHTTPServer, SocketServer, socket, threading

PORT = 8731

PAGE = """<!doctype html><meta charset=utf-8><title>cookie accept policy</title>
<style>body{font:14px -apple-system,sans-serif;margin:2em}b{font-family:monospace}
.y{color:#0a0}.n{color:#c00}.e{color:#c60}</style>
<h1>Cookie accept policy</h1>
<p>First party: <b>127.0.0.1</b> &middot; Third party: <b>localhost</b></p>
<div id=out>running...</div>
<script>
var THIRD = "http://localhost:%d";
// Each run stores a cookie whose name and value nothing has stored before. Under "Always" the
// Set-Cookie that would delete a previous run's cookie is itself rejected, so a fixed name reports a
// survivor as a fresh store.
var TOKEN = String(Date.now()) + String(Math.floor(Math.random()*1e6));
function get(u){
  return fetch(u,{credentials:"include"}).then(function(r){
    if(!r.ok) throw new Error(u+" -> HTTP "+r.status);
    return r.text();
  });
}
function leg(base,name){
  return get(base+"/set?t="+TOKEN).then(function(){return get(base+"/read")})
    .then(function(t){return [name, t.indexOf(TOKEN)>=0 ? "STORED" : "BLOCKED", t.replace(/\\s+$/,"")]},
          function(e){return [name, "ERROR", String(e.message || e)]});
}
// Each leg reports its own outcome, so a leg that could not run reads as ERROR rather than leaving the
// page on "running..." and window.RESULT undefined.
Promise.all([leg("", "first-party"), leg(THIRD, "third-party")]).then(function(out){
  document.getElementById("out").innerHTML = out.map(function(p){
    var cls = p[1]=="STORED" ? "y" : (p[1]=="ERROR" ? "e" : "n");
    return "<p>"+p[0]+": <b class="+cls+">"+p[1]+"</b> <span style=color:#888>("+p[2]+")</span></p>";
  }).join("");
  window.RESULT = out.map(function(p){return p[0]+"="+p[1]}).join(" ");
});
</script>""" % PORT

class H(BaseHTTPServer.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, body, content_type, extra=None):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1:%d" % PORT)
        self.send_header("Access-Control-Allow-Credentials", "true")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/":
            self._send(PAGE, "text/html; charset=utf-8")
        elif path == "/set":
            token = query.split("t=", 1)[1] if "t=" in query else "1"
            self._send("set", "text/plain", [("Set-Cookie", "wk%s=%s; Path=/; Max-Age=600" % (token, token))])
        elif path == "/read":
            self._send("Cookie: " + (self.headers.get("Cookie") or "(none)"), "text/plain")
        else:
            self.send_error(404)

class S4(SocketServer.ThreadingMixIn, BaseHTTPServer.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class S6(S4):
    address_family = socket.AF_INET6

if __name__ == "__main__":
    servers = [S4(("127.0.0.1", PORT), H), S6(("::1", PORT), H)]
    for s in servers[1:]:
        t = threading.Thread(target=s.serve_forever)
        t.daemon = True
        t.start()
    servers[0].serve_forever()
