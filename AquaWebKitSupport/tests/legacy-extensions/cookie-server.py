#!/usr/bin/env python3
"""Loopback cookie and WebSocket fixture server."""
import argparse
from pathlib import Path
import base64
import hashlib
import json
import os
import re
import ssl
import struct
import threading
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


LOG_LOCK = threading.Lock()


def log_event(server, event):
    line = json.dumps(event, sort_keys=True)
    with LOG_LOCK:
        with server.log_path.open('a') as output:
            output.write(line + '\n')
    print(line, flush=True)


class LocalServer(ThreadingHTTPServer):
    request_queue_size = 128


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def snapshot(self):
        cookies = SimpleCookie()
        try:
            cookies.load(self.headers.get('Cookie', ''))
        except Exception:
            cookies = SimpleCookie()
        return {'method': self.command, 'path': self.path,
                'origin': self.headers.get('Origin'),
                'host': self.headers.get('Host'),
                'secure': self.server.secure,
                'cookies': {name: item.value for name, item in cookies.items()
                            if name.startswith('extck_')}}

    def reply(self, status, data, headers=()):
        body = json.dumps(data, sort_keys=True).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Access-Control-Allow-Origin', self.headers.get('Origin', '*'))
        self.send_header('Access-Control-Allow-Credentials', 'true')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Vary', 'Origin')
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.reply(200, {})

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(size)
        if urlsplit(self.path).path == '/report':
            try:
                result = json.loads(body)
            except ValueError:
                return self.reply(400, {'error': 'Expected JSON'})
            log_event(self.server, {'report': result})
        self.do_GET()

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        snapshot = self.snapshot()
        log_event(self.server, {'request': snapshot})
        if url.path in ('/cookie-frame.html', '/cookie-exercise.js'):
            path = Path(__file__).parent / 'pages' / url.path[1:]
            body = path.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html' if url.path.endswith('.html') else 'text/javascript')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
            return
        if url.path == '/navigation-echo':
            payload = json.dumps({'cookieNavigation': {'id': query.get('id', [''])[0], 'request': snapshot}}).replace('<', '\\u003c')
            body = ('<!doctype html><script>parent.postMessage(' + payload + ', "*")</script>').encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
            return
        if url.path == '/ws':
            key = self.headers.get('Sec-WebSocket-Key')
            if not key:
                return self.reply(400, {'error': 'Expected WebSocket handshake'})
            accept = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode('ascii')).digest()).decode('ascii')
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            body = json.dumps(snapshot, sort_keys=True).encode('utf-8')
            prefix = bytes([0x81, len(body)]) if len(body) < 126 else bytes([0x81, 126]) + struct.pack('!H', len(body))
            self.wfile.write(prefix + body + bytes([0x88, 2, 3, 232]))
            self.wfile.flush()
            self.close_connection = True
            return
        if url.path == '/redirect':
            target = query.get('to', [''])[0]
            parsed = urlsplit(target)
            if not (parsed.hostname in ('localhost', '127.0.0.1', 'ext-cookie.test') or (parsed.hostname or '').endswith('.ext-cookie.test')) or parsed.scheme not in ('http', 'https'):
                return self.reply(400, {'error': 'Redirect target must be a local HTTP(S) endpoint'})
            return self.reply(302, snapshot, [('Location', target)])
        headers = []
        if url.path == '/seed':
            prefix = query.get('prefix', ['extck_s' if self.server.secure else 'extck_h'])[0]
            if not re.fullmatch(r'extck_[A-Za-z0-9_]+', prefix):
                return self.reply(400, {'error': 'Invalid fixture prefix'})
            for name, attribute in [('unspecified', ''), ('none', '; SameSite=None'),
                                    ('lax', '; SameSite=Lax'), ('strict', '; SameSite=Strict')]:
                for http_only in (False, True):
                    cookie = prefix + '_' + name + ('_http' if http_only else '') + '=1; Path=/; Max-Age=3600' + attribute
                    if self.server.secure:
                        cookie += '; Secure'
                    if http_only:
                        cookie += '; HttpOnly'
                    headers.append(('Set-Cookie', cookie))
        self.reply(200, snapshot, headers)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--http-port', type=int, default=8877)
    parser.add_argument('--https-port', type=int, default=8878)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--work-dir', type=Path, default=Path(os.environ.get('AQUAWEBKIT_COOKIE_TEST_DIR', Path(__file__).resolve().parent / 'results/cookies')))
    args = parser.parse_args()
    args.work_dir = args.work_dir.expanduser().resolve()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.work_dir / 'server.jsonl'
    log_path.write_text('')
    http = LocalServer(('127.0.0.1', args.http_port), Handler)
    http.secure = False
    http.log_path = log_path
    https = LocalServer(('127.0.0.1', args.https_port), Handler)
    https.secure = True
    https.log_path = log_path
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    https.socket = context.wrap_socket(https.socket, server_side=True)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    print('Loopback HTTP/WS :%d and HTTPS/WSS :%d' % (args.http_port, args.https_port), flush=True)
    try:
        https.serve_forever()
    finally:
        http.shutdown()
        http.server_close()
        https.server_close()


if __name__ == '__main__':
    main()
