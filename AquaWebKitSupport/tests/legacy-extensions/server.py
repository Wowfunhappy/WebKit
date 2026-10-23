#!/usr/bin/env python3
# Serves the legacy-extension API test pages on 127.0.0.1:8843 and a WebSocket endpoint on 8844.
# Every request is recorded; GET /log returns the record, GET /reset clears it.

import base64
import hashlib
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG = []
LOCK = threading.Lock()
# Held by one extension context's clipboard sequence at a time: every test extension shares the general pasteboard.
CLIPBOARD = threading.Semaphore(1)
# An ISO media file's leading box, which is all a media document needs to show a player for it.
MP4 = b'\x00\x00\x00\x14ftypisom\x00\x00\x02\x00isom'
PDF = (b'%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n'
       b'3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n')


def record(entry):
    with LOCK:
        LOG.append(dict(entry, time=time.time()))


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, '.vtt': 'text/vtt; charset=utf-8'}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, 'pages'), **kwargs)

    def log_message(self, *args):
        pass

    def end_headers(self):
        if not getattr(self, 'cacheable', False):
            self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def reply(self, body, content_type='text/plain', status=200, headers=(), cors=True):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        if cors:
            self.send_header('Access-Control-Allow-Origin', '*')
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        if self.path.startswith("/quicktime-media/"):
            return self.do_GET()
        return super().do_HEAD()

    def do_GET(self):
        path = self.path
        if urllib.parse.urlsplit(path).path == '/quicktime-delayed-captions.vtt':
            time.sleep(3)
            with open(os.path.join(ROOT, 'pages', 'quicktime-captions.vtt'), 'rb') as captions:
                return self.reply(captions.read(), 'text/vtt; charset=utf-8')
        if path.startswith('/quicktime-media/'):
            if urllib.parse.parse_qs(urllib.parse.urlsplit(path).query).get('delay') == ['3']:
                time.sleep(3)
            name = urllib.parse.urlsplit(path).path.rsplit('/', 1)[-1]
            if not name or name in ('.', '..'):
                return self.reply('not found', status=404)
            filename = os.path.join(ROOT, 'build', 'quicktime-media', name)
            try:
                with open(filename, 'rb') as media:
                    data = media.read()
            except FileNotFoundError:
                return self.reply('generate fixtures first', status=404)
            content_type = {'.mp4': 'video/mp4', '.webm': 'video/webm', '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t', '.vtt': 'text/vtt; charset=utf-8'}.get(os.path.splitext(name)[1], 'application/octet-stream')
            range_header = self.headers.get('Range')
            if range_header:
                try:
                    if not range_header.startswith('bytes='):
                        raise ValueError()
                    start, end = range_header[6:].split('-')
                    start = int(start) if start else max(0, len(data) - int(end))
                    end = min(int(end), len(data) - 1) if range_header[6:].split('-')[0] and end else len(data) - 1
                    if start < 0 or start > end or start >= len(data):
                        raise ValueError()
                except ValueError:
                    return self.reply('', status=416, headers=[('Content-Range', 'bytes */%d' % len(data))])
                return self.reply(data[start:end + 1], content_type, 206, [('Content-Range', 'bytes %d-%d/%d' % (start, end, len(data))), ('Accept-Ranges', 'bytes')])
            return self.reply(data, content_type, headers=[('Accept-Ranges', 'bytes')])
        if path == '/log':
            with LOCK:
                return self.reply(json.dumps(LOG, indent=1), 'application/json')
        if path == '/reset':
            with LOCK:
                LOG.clear()
            return self.reply('ok')
        record({'method': 'GET', 'path': path, 'referer': self.headers.get('Referer', ''), 'ifNoneMatch': self.headers.get('If-None-Match', ''),
                'authorization': self.headers.get('Authorization'), 'cookie': self.headers.get('Cookie'),
                'acceptLanguage': self.headers.get('Accept-Language'), 'acceptEncoding': self.headers.get('Accept-Encoding')})
        if path.startswith('/report'):
            return self.reply('ok')
        # The general pasteboard as a process outside the browser sees it, and a copy made there.
        if path == '/pbpaste':
            return self.reply(subprocess.run(['pbpaste'], capture_output=True).stdout)
        if path.startswith('/pbcopy?'):
            subprocess.run(['pbcopy'], input=urllib.parse.unquote(path.split('?', 1)[1]).encode(), check=True)
            return self.reply('ok')
        if path == '/clipboard-lock':
            CLIPBOARD.acquire()
            return self.reply('ok')
        if path == '/clipboard-unlock':
            CLIPBOARD.release()
            return self.reply('ok')
        if path == '/pbpng':
            data = subprocess.run(['osascript', '-e', 'the clipboard as «class PNGf»'], capture_output=True, text=True).stdout.strip()
            png = bytes.fromhex(data[len('«data PNGf'):-1]) if data.startswith('«data PNGf') else b''
            return self.reply(png, 'image/png')
        if path.startswith('/res/'):
            name = path.split('?')[0].rsplit('/', 1)[-1]
            ext = name.rsplit('.', 1)[-1] if '.' in name else ''
            types = {
                'js': 'text/javascript', 'css': 'text/css', 'json': 'application/json',
                'png': 'image/png', 'woff': 'font/woff', 'html': 'text/html', 'txt': 'text/plain',
            }
            if ext == 'png':
                body = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
            elif ext == 'js':
                body = f'window.__loaded = (window.__loaded || []).concat({json.dumps(name)});'
            elif ext == 'css':
                body = '#css-probe { width: 7px; }'
            elif ext == 'html':
                body = '<!doctype html><title>frame</title><p id="frame-probe">frame</p>'
            else:
                body = '{"ok":true}'
            return self.reply(body, types.get(ext, 'application/octet-stream'))
        if path.startswith('/csp-page'):
            with open(os.path.join(ROOT, 'pages', 'csp.html'), 'rb') as f:
                body = f.read()
            return self.reply(body, 'text/html', headers=[('Content-Security-Policy', "script-src 'self'; style-src 'self'")])
        # A response the disk cache keeps, and one it revalidates.
        if path.startswith('/cacheable'):
            self.cacheable = True
            return self.reply('{"cached":true}', 'application/json', headers=[('Cache-Control', 'max-age=600')])
        if path.startswith('/revalidate'):
            self.cacheable = True
            if self.headers.get('If-None-Match') == '"v1"':
                self.send_response(304)
                self.send_header('ETag', '"v1"')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                return
            return self.reply('{"revalidated":true}', 'application/json', headers=[('ETag', '"v1"'), ('Cache-Control', 'no-cache')])
        if path.startswith('/clear-cookies'):
            return self.reply('ok', headers=[('Set-Cookie', 'keep=; Path=/; Max-Age=0'), ('Set-Cookie', 'strip=; Path=/; Max-Age=0'), ('Set-Cookie', 'hop=; Path=/; Max-Age=0'), ('Set-Cookie', 'limited=; Path=/; Max-Age=0')])
        # Same-origin redirects: one the extension retargets, one whose first hop loses its Cookie, one that sets a cookie.
        if path.startswith('/auth-hop'):
            return self.reply('', status=302, headers=[('Location', '/res/auth-original.json')])
        # HTTP authentication, for onAuthRequired.
        # Each has a realm of its own, so credentials kept for one do not answer the other.
        if path.startswith('/auth-basic') or path.startswith('/auth-cancel'):
            if self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'extension:secret').decode():
                return self.reply('{"authenticated":true}', 'application/json')
            realm = 'legacy-extension-test' if path.startswith('/auth-basic') else 'legacy-extension-cancel'
            return self.reply('{"authenticated":false}', 'application/json', status=401, headers=[('WWW-Authenticate', f'Basic realm="{realm}"')])
        if path.startswith('/moved-script'):
            return self.reply('', status=302, headers=[('Location', '/res/moved-original.js')])
        if path.startswith('/cookie-hop'):
            return self.reply('', status=302, headers=[('Location', '/echo-headers?hop2')])
        if path.startswith('/set-cookie-hop'):
            return self.reply('', status=302, headers=[('Location', '/echo-headers?after-set-cookie'), ('Set-Cookie', 'hop=1; Path=/')])
        if path.startswith('/to-extension-page') or path.startswith('/to-data'):
            return self.reply('<!doctype html><title>not redirected</title>', 'text/html')
        if path.startswith('/set-cookies'):
            return self.reply('ok', headers=[('Set-Cookie', 'keep=1; Path=/'), ('Set-Cookie', 'strip=1; Path=/')])
        # A redirect whose response the extension rewrites or cancels.
        if path.startswith('/moved-'):
            return self.reply('', status=302, headers=[('Location', '/res/redirect-original.json')])
        if path.startswith('/echo-headers') or path.startswith('/extension-cookies/echo'):
            return self.reply(json.dumps({k.lower(): v for k, v in self.headers.items()}), 'application/json')
        # Top-level navigations whose download or display display-or-download.safariextension decides: /inline/ is
        # the extension's, /plain/ is not. The PDFs need the cookie /inline/login sets and send no CORS headers.
        # Media files download unless AquaWebKitPlayMediaFilesInline is on, whatever their Content-Disposition.
        if path.startswith('/inline/login'):
            return self.reply('ok', headers=[('Set-Cookie', 'pdf=1; Path=/; Max-Age=600')])
        if path.startswith('/inline/') or path.startswith('/plain/'):
            name = path.split('?')[0].rsplit('/', 1)[-1]
            if name.endswith('.mp4'):
                headers = [('Content-Disposition', 'inline')] if name == 'server-inline.mp4' else []
                return self.reply(MP4, 'video/mp4', headers=headers)
            if name.endswith('.pdf'):
                if 'pdf=1' not in (self.headers.get('Cookie') or ''):
                    return self.reply('no cookie', status=403, cors=False)
                return self.reply(PDF, 'application/pdf', cors=False)
            if name.endswith('.bin'):
                return self.reply('shown', 'application/octet-stream')
            return self.reply('<!doctype html><title>shown</title><p id="shown">shown</p>', 'text/html')
        # response-filter.safariextension's StreamFilters rewrite REPLACE-ME in these; /filter/plain/ has no filter.
        # The streamed ones arrive in several writes, so in several chunks.
        if path.startswith('/filter/') and not path.startswith('/filter/plain/'):
            return self.filtered(path.split('?')[0].rsplit('/', 1)[-1])
        if path.startswith('/filter/plain/'):
            return self.reply('REPLACE-ME plain', 'text/plain')
        if path == '/preconnects':
            return self.reply(json.dumps(PRECONNECTS['count']), 'application/json')
        # mime-handler.safariextension's viewer shows these PDFs; attachment.pdf downloads.
        if path.startswith('/mime-options/'):
            return self.reply('options', 'text/plain')
        if path.startswith('/mime/'):
            name = path.split('?')[0].rsplit('/', 1)[-1]
            if name == 'embed.html':
                return self.reply('<!doctype html><title>embeds</title>'
                                  '<embed id="embed" src="doc.pdf" type="application/pdf" width="300" height="200">'
                                  '<object id="object" data="doc.pdf" type="application/pdf" width="300" height="200"></object>'
                                  '<iframe id="iframe" src="doc.pdf" width="300" height="200"></iframe>', 'text/html')
            headers = [('Content-Disposition', 'attachment; filename="attachment.pdf"')] if name == 'attachment.pdf' else [('X-Test', 'mime')]
            return self.reply(PDF, 'application/pdf', headers=headers)
        # declarative-net-request.safariextension's rules act on these.
        if path.startswith('/dnr/'):
            return self.reply('{"path":' + json.dumps(path) + '}', 'application/json')
        if path.startswith('/sse'):
            return self.reply('data: hello\n\n', 'text/event-stream')
        return super().do_GET()

    def filtered(self, name):
        if name == 'page.html':
            return self.reply('<!doctype html><title>filtered</title><p id="text">REPLACE-ME</p>', 'text/html; charset=utf-8')
        if name in ('cached.txt', 'held.txt'):
            self.cacheable = True
            return self.reply('REPLACE-ME ' + name, 'text/plain', headers=[('Cache-Control', 'max-age=600')])
        if name in ('chunked-count.txt', 'suspend.txt', 'disconnect.txt', 'passthrough.txt', 'slow.txt'):
            parts = [b'REPLACE-ME first ', b'x' * 70000, b' REPLACE-ME middle ', b'y' * 70000, b' REPLACE-ME last']
            if name == 'slow.txt':
                parts = [b'REPLACE-ME %d ' % index + b'z' * 1024 for index in range(40)]
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(sum(len(part) for part in parts)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            for part in parts:
                self.wfile.write(part)
                self.wfile.flush()
                time.sleep(0.5 if name == 'slow.txt' else 0.15)
            return
        if name == 'empty.txt':
            return self.reply('', 'text/plain')
        return self.reply('var text = "REPLACE-ME";', 'text/plain')

    def do_OPTIONS(self):
        record({'method': 'OPTIONS', 'path': self.path, 'authorization': self.headers.get('Authorization')})
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Authorization')
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8', 'replace')
        record({'method': 'POST', 'path': self.path, 'body': body})
        if self.path.startswith('/main-post-target'):
            return self.reply('<!doctype html><title>posted</title><p id="posted">' + body + '</p>', 'text/html')
        self.reply('ok')


class WebSocketHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(4096).decode('latin-1')
        lines = data.split('\r\n')
        path = lines[0].split(' ')[1] if lines and ' ' in lines[0] else '?'
        record({'method': 'WS', 'path': path})
        key = ''
        for line in lines:
            if line.lower().startswith('sec-websocket-key:'):
                key = line.split(':', 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.request.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                              f'Sec-WebSocket-Accept: {accept}\r\n\r\n').encode())
        message = b'hello'
        self.request.sendall(bytes([0x81, len(message)]) + message)
        time.sleep(1)


# The coverage page opens dozens of connections at once, past socketserver's default backlog of 5.
class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 128


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


# Counts the connections opened to 8845, which only <link rel=preconnect> opens.
PRECONNECTS = {'count': 0}


class PreconnectHandler(socketserver.BaseRequestHandler):
    def handle(self):
        with LOCK:
            PRECONNECTS['count'] += 1
        time.sleep(1)


if __name__ == '__main__':
    ws = ThreadingTCPServer(('127.0.0.1', 8844), WebSocketHandler)
    threading.Thread(target=ws.serve_forever, daemon=True).start()
    preconnect = ThreadingTCPServer(('127.0.0.1', 8845), PreconnectHandler)
    threading.Thread(target=preconnect.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', 8843), Handler).serve_forever()
