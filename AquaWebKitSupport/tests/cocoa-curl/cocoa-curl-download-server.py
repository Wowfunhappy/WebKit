#!/usr/bin/env python3
"""Deterministic loopback download/range/auth fixture; never changes system routing."""
import argparse, base64, gzip, json, pathlib, socket, threading
BODY = bytes(range(256)) * 8192
LOCK = threading.Lock()
PRIVATE_TRANSFERS = {}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18982)
    parser.add_argument('--log', type=pathlib.Path, required=True)
    args = parser.parse_args()
    def connection(client):
        try:
            client.settimeout(30)
            data = b''
            while b'\r\n\r\n' not in data:
                part = client.recv(65536)
                if not part:
                    return
                data += part
            lines = data.split(b'\r\n\r\n', 1)[0].split(b'\r\n')
            method, path, version = lines[0].decode('ascii').split(' ')
            headers = dict(line.decode('latin1').split(':', 1) for line in lines[1:])
            headers = {name.lower(): value.strip() for name, value in headers.items()}
            with LOCK, args.log.open('a') as log:
                log.write(json.dumps({'method': method, 'path': path, 'headers': headers}) + '\n')
            status = '200 OK'
            fields = {'Content-Type': 'application/octet-stream', 'ETag': '"download-v1"', 'Accept-Ranges': 'bytes'}
            body = BODY
            if path == '/private-page':
                fields['Content-Type'] = 'text/html'
                fields['Set-Cookie'] = 'download-owner=private; Path=/; HttpOnly; SameSite=Strict'
                body = b'<!doctype html><title>Private download owner</title><p>Ready</p>'
            if path.startswith('/private-file'):
                fields['Content-Disposition'] = 'attachment; filename=private-file.bin'
            if path.startswith('/private-file') and (headers.get('cookie') != 'download-owner=private' or headers.get('x-test-representation') != 'original'):
                status = '403 Forbidden'
                body = b'The original private cookie and representation header are required.'
            elif path.startswith('/private-file') and 'range' not in headers:
                fields['Set-Cookie'] = 'download-owner=private; Path=/; HttpOnly; SameSite=Strict'
            if path == '/basic' and headers.get('authorization') != 'Basic ' + base64.b64encode(b'curl-test:correct-password').decode():
                status = '401 Unauthorized'
                fields['WWW-Authenticate'] = 'Basic realm="curl download fixture"'
                body = b''
            elif status == '200 OK' and 'range' in headers and path != '/ignore-range':
                offset = int(headers['range'].removeprefix('bytes=').removesuffix('-'))
                if offset >= len(BODY):
                    status = '416 Range Not Satisfiable'
                    fields['Content-Range'] = 'bytes */' + str(len(BODY))
                    body = b''
                else:
                    status = '206 Partial Content'
                    first = offset + (1 if path == '/invalid-range' else 0)
                    last = len(BODY) // 2 - 1 if path == '/short-range' else len(BODY) - 1
                    fields['Content-Range'] = 'bytes %d-%d/%d' % (first, last, len(BODY))
                    body = BODY[offset:last + 1]
                    if path == '/changed-etag':
                        fields['ETag'] = '"download-v2"'
                    if path == '/compressed-range':
                        fields['Content-Encoding'] = 'gzip'
                        body = gzip.compress(body)
            fields['Content-Length'] = str(len(body))
            fields['Connection'] = 'close'
            response = ('HTTP/1.1 ' + status + '\r\n' + ''.join(name + ': ' + value + '\r\n' for name, value in fields.items()) + '\r\n').encode('ascii')
            client.sendall(response)
            if method != 'HEAD':
                if path.startswith('/private-file') and status.startswith(('200 ', '206 ')):
                    with LOCK:
                        turn = PRIVATE_TRANSFERS.get(path, 0) + 1
                        PRIVATE_TRANSFERS[path] = turn
                    # The first two legs deliberately wait for cancellation after a delivered prefix.
                    # The third leg completes. Socket EOF is the cancellation signal; no timing/polling controls the test.
                    if turn <= 2:
                        client.sendall(body[:16384])
                        client.recv(1)
                    else:
                        client.sendall(body)
                else:
                    client.sendall(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Stopping a download deliberately closes the server's connection.
        finally:
            client.close()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', args.port))
    listener.listen(16)
    print('download fixture listening on', args.port, flush=True)
    while True:
        client, _ = listener.accept()
        threading.Thread(target=connection, args=(client,), daemon=True).start()

if __name__ == '__main__':
    main()
