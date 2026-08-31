#!/usr/bin/env python3
# Serves gzip-encoded bodies whose URL extension, Content-Type and Content-Disposition span the
# conditions 10.9 CFNetwork keys its gzip-decode suppression on, and drives fetch()/XHR over the
# matrix from the page it serves at /. Every body carries TWO gzip layers, so exactly one layer must
# come off whoever removes it -- CFNetwork or WebCore::CFNetworkSuppressedGzipDecoder -- and every
# case must arrive at 56 bytes. The page writes ALL OK or FAIL into document.title and logs the same
# line to the console, so wk1host can score it too.
#
#     python3 MavericksSupport/tests/gzip-suppression/server.py     # then open http://127.0.0.1:8101/
import gzip, io, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

def gz(b):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb') as f:
        f.write(b)
    return buf.getvalue()

PAYLOAD = b'ABCDEFGHIJ' * 500          # 5000
ONE = gz(PAYLOAD)                      # 56  (one gzip layer)
TWO = gz(ONE)                          # 72  (two layers)
A, B = b'A' * 1000, b'B' * 2000
MULTI = gz(A) + gz(B)

CTS = ['application/octet-stream', 'application/x-gzip', 'application/x-tar', 'application/x-tar-gz',
       'application/gzip', 'text/plain', 'image/png', 'application/json', 'none']
NAMES = ['f.gz', 'f.tgz', 'f.tar.gz', 'f.bin', 'f.svgz', 'f.gz.txt', '.gz']

# (URL last component, Content-Type, Content-Disposition). Every one must arrive decoded exactly once,
# whether CFNetwork reads a filename out of the header or falls through to the Content-Type branch.
CD_CASES = [
    ['f.gz',  'application/octet-stream', 'attachment; filename="x.txt"'],
    ['f.bin', 'text/plain',               'attachment; filename="x.tgz"'],
    ['f.gz',  'text/plain',               'attachment; filename="x.gz"'],
    ['f.gz',  'application/octet-stream', 'attachment'],
    ['f.bin', 'application/octet-stream', 'attachment; filename="x.txt"'],
    # the parameter name matches case-insensitively
    ['f.gz',  'application/octet-stream', 'attachment; FILENAME="x.txt"'],
    ['f.gz',  'application/octet-stream', 'attachment; Filename=x.txt'],
    ['f.bin', 'text/plain',               'attachment; FILENAME="x.tgz"'],
    # RFC 5987 extended form, which wins over the plain one in either order
    ['f.gz',  'application/octet-stream', "attachment; filename*=UTF-8''x.txt"],
    ['f.gz',  'application/octet-stream', "attachment; filename*=UTF-8''x%2Egz"],
    ['f.gz',  'application/octet-stream', "attachment; filename=\"a.txt\"; filename*=UTF-8''b.tgz"],
    ['f.gz',  'application/octet-stream', "attachment; filename*=UTF-8''b.tgz; filename=\"a.txt\""],
    ['f.gz',  'application/octet-stream', "attachment; filename=\"a.tgz\"; filename*=UTF-8''b.txt"],
    ['f.gz',  'application/octet-stream', "attachment; filename*=UTF-8''b.txt; filename=\"a.tgz\""],
    # forms CFNetwork reads no filename from, which fall through to the Content-Type branch
    ['f.gz',  'application/octet-stream', "attachment; filename*=BOGUS''x.tgz"],
    ['f.gz',  'application/octet-stream', "attachment; filename *=UTF-8''x.tgz"],
    ['f.gz',  'application/octet-stream', "attachment; filename*=\"UTF-8''x.tgz\""],
    ['f.gz',  'application/octet-stream', 'attachment; filename='],
    ['f.gz',  'application/octet-stream', 'attachment; filenamex=x.txt'],
    # a semicolon inside quotes belongs to the value; outside them it ends the parameter
    ['f.gz',  'application/octet-stream', 'attachment; filename="a.gz;b.txt"'],
    ['f.gz',  'application/octet-stream', 'attachment; filename=a.gz;b.txt'],
]


PAGE = ('''<!doctype html><meta charset=utf-8><title>waiting</title><pre id=o>running</pre><script>
const CTS = @@CTS@@, NAMES = @@NAMES@@;
async function len(u) {
  try { return (await (await fetch(u)).arrayBuffer()).byteLength; } catch (e) { return 'THREW'; }
}
(async () => {
  const bad = [], all = {};
  for (const n of NAMES) for (const ct of CTS) {
    // body carries TWO gzip layers; exactly one must be peeled, whoever peels it => 56
    const u = '/' + n + '?ct=' + encodeURIComponent(ct) + '&body=two&r=' + Math.random();
    const got = await len(u);
    all[n + ' | ' + ct] = got;
    if (got !== 56) bad.push(n + ' | ' + ct + ' = ' + got);
  }
  // Content-Disposition branch: the CD filename alone decides, Content-Type is not consulted.
  const CD = @@CD@@;
  for (const [n, ct, cd] of CD) {
    const u = '/' + n + '?ct=' + encodeURIComponent(ct) + '&cd=' + encodeURIComponent(cd) + '&body=two&r=' + Math.random();
    const got = await len(u);
    all['CD ' + n + ' | ' + ct + ' | ' + cd] = got;
    if (got !== 56) bad.push('CD ' + n + ' | ' + ct + ' | ' + cd + ' = ' + got);
  }

  // multi-member body under the suppressed combination
  const m = await len('/f.tgz?ct=application/octet-stream&body=multi&r=' + Math.random());
  if (m !== 3000) bad.push('multi = ' + m);
  const xhr = await new Promise(res => { const x = new XMLHttpRequest();
    x.open('GET', '/f.tgz?ct=application/octet-stream&body=two&r=' + Math.random());
    x.responseType = 'arraybuffer'; x.onload = () => res(x.response.byteLength);
    x.onerror = () => res('ERR'); x.send(); });
  if (xhr !== 56) bad.push('xhr = ' + xhr);
  const trunc = await fetch('/f.tgz?ct=application/octet-stream&body=trunc&r=' + Math.random())
     .then(r => r.arrayBuffer()).then(b => 'RESOLVED ' + b.byteLength, e => 'REJECTED');
  if (trunc !== 'REJECTED') bad.push('trunc = ' + trunc);
  document.getElementById('o').textContent = JSON.stringify(all, null, 1);
  console.log(bad.length ? 'RESULT FAIL ' + JSON.stringify(bad) : 'RESULT ALL OK');
  document.title = bad.length ? 'FAIL ' + JSON.stringify(bad) : 'ALL OK (' + (Object.keys(all).length + 3) + ' cases)';
})();
</script>'''
        .replace('@@CD@@', json.dumps(CD_CASES))
        .replace('@@CTS@@', str(CTS).replace("'", '"'))
        .replace('@@NAMES@@', str(NAMES).replace("'", '"'))).encode()

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(PAGE)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers(); self.wfile.write(PAGE); return
        cd = q.get('cd', [''])[0]
        kind = q.get('body', ['two'])[0]
        body = {'two': TWO, 'one': ONE, 'multi': MULTI, 'trunc': ONE[:-40]}[kind]
        ct = q.get('ct', ['none'])[0]
        self.send_response(200)
        if ct != 'none':
            self.send_header('Content-Type', ct)
        if cd:
            self.send_header('Content-Disposition', cd)
        self.send_header('Content-Encoding', 'gzip')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(('127.0.0.1', 8101), H).serve_forever()
