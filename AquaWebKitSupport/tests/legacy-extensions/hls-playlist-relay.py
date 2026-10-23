#!/usr/bin/env python3
"""Diagnostic HTTP range/length normalization for one remote HLS media playlist."""
import argparse
import http.server
import os
import pathlib
import re
import subprocess
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url_file')
args = parser.parse_args()
source = pathlib.Path(args.url_file).read_text().strip()
assert urllib.parse.urlsplit(source).scheme in ('http', 'https')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path != '/live.m3u8':
            self.send_error(404)
            return
        try:
            text = subprocess.check_output(['/usr/bin/curl', '-fsSL', '--max-time', '15', source], timeout=20, stderr=subprocess.DEVNULL).decode()
            assert text.startswith('#EXTM3U')
            lines = []
            for line in text.splitlines():
                if line and not line.startswith('#'):
                    line = urllib.parse.urljoin(source, line)
                else:
                    line = re.sub(r'URI="([^"]*)"', lambda m: 'URI="' + urllib.parse.urljoin(source, m[1]) + '"', line)
                lines.append(line)
            body = ('\n'.join(lines) + '\n').encode()
        except Exception as error:
            print('FETCH_FAILED', type(error).__name__, flush=True)
            self.send_error(502)
            return
        start, end, status = 0, len(body)-1, 200
        requested = self.headers.get('Range')
        if requested:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', requested)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(end, int(match[2]) if match[2] else end)
            if start > end:
                self.send_error(416)
                return
            status = 206
        self.send_response(status)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end-start+1))
        if status == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(body)}')
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body[start:end+1])
            except (BrokenPipeError, ConnectionResetError):
                pass
        sequence = re.search(r'#EXT-X-MEDIA-SEQUENCE:(\d+)', text)
        print('HTTP', status, 'range', requested, 'bytes', end-start+1, 'sequence', sequence[1] if sequence else None, flush=True)


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('RELAY', os.getpid(), server.server_port, flush=True)
server.serve_forever()
