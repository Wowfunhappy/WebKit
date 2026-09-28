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


def record(entry):
    with LOCK:
        LOG.append(dict(entry, time=time.time()))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, 'pages'), **kwargs)

    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def reply(self, body, content_type='text/plain', status=200, headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Access-Control-Allow-Origin', '*')
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path
        if path == '/log':
            with LOCK:
                return self.reply(json.dumps(LOG, indent=1), 'application/json')
        if path == '/reset':
            with LOCK:
                LOG.clear()
            return self.reply('ok')
        record({'method': 'GET', 'path': path, 'referer': self.headers.get('Referer', '')})
        if path.startswith('/report'):
            return self.reply('ok')
        # The general pasteboard as a process outside the browser sees it, and a copy made there.
        if path == '/pbpaste':
            return self.reply(subprocess.run(['pbpaste'], capture_output=True).stdout)
        if path.startswith('/pbcopy?'):
            subprocess.run(['pbcopy'], input=urllib.parse.unquote(path.split('?', 1)[1]).encode(), check=True)
            return self.reply('ok')
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
        if path.startswith('/sse'):
            return self.reply('data: hello\n\n', 'text/event-stream')
        return super().do_GET()

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8', 'replace')
        record({'method': 'POST', 'path': self.path, 'body': body})
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


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == '__main__':
    ws = ThreadingTCPServer(('127.0.0.1', 8844), WebSocketHandler)
    threading.Thread(target=ws.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', 8843), Handler).serve_forever()
