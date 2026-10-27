#!/usr/bin/env python3
# WebSocket fixtures for websocket.html, on 127.0.0.1:18995 (http, ws) and 127.0.0.1:18996 (https, wss, with a
# certificate for 127.0.0.1 that build/tls/ holds, made on first run). Both ports serve the same paths:
#   /, /websocket.html  the driver page
#   /log                JSON: what the WebSocket paths recorded (GET /reset clears it)
#   /echo               echoes every message, answers pings, and echoes the client's Close
#   /headers            sends one text message, the handshake's request header fields as JSON, then echoes
#   /set-cookie         answers the handshake with Set-Cookie: ws-cookie=2, then sends "ok"
#   /protocol           selects the last subprotocol offered, then echoes
#   /bad-protocol       selects a subprotocol nobody offered
#   /extension          names an extension nobody offered
#   /bad-accept         answers with the wrong Sec-WebSocket-Accept
#   /close              sends a Close with ?code= and ?reason=, then waits for the client's
#   /close-empty        sends a Close with no payload
#   /abort              closes the connection right after the handshake response
#   /frame-eof          sends a text frame in the same write as the handshake response, then closes
#   /close-1000         sends Close(1000) in the same write as the handshake response, then closes
#   /drop-client-close  waits for the client's Close and drops the connection without echoing it
#   /redirect           302 to /echo on the same port
#   /basic              401 with Basic realm="ws" until Authorization: Basic test:secret, then echoes
#   /ntlm               NTLM for CURL\curl-test:correct-password (needs python3 with pyspnego; 501 without it)
#   /bad-utf8           sends a text frame that is not UTF-8
#   /masked             sends a masked frame
#   /fragmented         sends "fragmented message" as three frames with a ping between them
#   /ping               pings with "probe" and sends "pong probe" once the client's pong carries it back
#   /slow-sink          reads at 2 MB/s and records the payload bytes it took
#   /no-answer          reads the request and never answers it

import base64
import hashlib
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.abspath(__file__))
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
CREDENTIAL = 'Basic ' + base64.b64encode(b'test:secret').decode()
RATE = 2 * 1000 * 1000
LOG = []
LOCK = threading.Lock()

try:
    import spnego
    os.makedirs(os.path.join(ROOT, 'build'), exist_ok=True)
    USERS = os.path.join(ROOT, 'build', 'ntlm-users.txt')
    with open(USERS, 'w') as file:
        file.write('CURL:curl-test:correct-password\n')
    os.environ['NTLM_USER_FILE'] = USERS
except ImportError:
    spnego = None


def record(entry):
    with LOCK:
        LOG.append(dict(entry, time=time.time()))


def receive(connection, count):
    data = b''
    while len(data) < count:
        part = connection.recv(count - len(data))
        if not part:
            raise EOFError
        data += part
    return data


def read_frame(connection, delay=None):
    b0, b1 = receive(connection, 2)
    length = b1 & 0x7f
    if length == 126:
        length = int.from_bytes(receive(connection, 2), 'big')
    elif length == 127:
        length = int.from_bytes(receive(connection, 8), 'big')
    mask = receive(connection, 4) if b1 & 0x80 else b''
    if delay:
        time.sleep(length / delay)
    payload = receive(connection, length)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return b0 & 0x80, b0 & 0x0f, payload


def frame(opcode, payload=b'', fin=True, masked=False):
    header = bytes([(0x80 if fin else 0) | opcode])
    length = len(payload)
    mask_bit = 0x80 if masked else 0
    if length < 126:
        header += bytes([mask_bit | length])
    elif length < 65536:
        header += bytes([mask_bit | 126]) + length.to_bytes(2, 'big')
    else:
        header += bytes([mask_bit | 127]) + length.to_bytes(8, 'big')
    if masked:
        mask = b'\x01\x02\x03\x04'
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        header += mask
    return header + payload


def read_head(connection, buffered=b''):
    data = buffered
    while b'\r\n\r\n' not in data:
        part = connection.recv(65536)
        if not part:
            return None, None, None, b''
        data += part
    head, rest = data.split(b'\r\n\r\n', 1)
    lines = head.decode('latin-1').split('\r\n')
    method, target = lines[0].split(' ')[:2]
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(':')
        headers[name.strip().lower()] = value.strip()
    return method, target, headers, rest


def respond(connection, status, body, content_type='text/plain', headers=()):
    data = body.encode() if isinstance(body, str) else body
    lines = [f'HTTP/1.1 {status}', f'Content-Type: {content_type}', f'Content-Length: {len(data)}',
             'Cache-Control: no-store', *headers, '', '']
    connection.sendall('\r\n'.join(lines).encode() + data)


def handshake(headers, extra=()):
    accept = base64.b64encode(hashlib.sha1((headers.get('sec-websocket-key', '') + GUID).encode()).digest()).decode()
    lines = ['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade',
             f'Sec-WebSocket-Accept: {accept}', *extra, '', '']
    return '\r\n'.join(lines).encode()


def echo(connection):
    message, opcode = b'', 0
    while True:
        fin, op, payload = read_frame(connection)
        if op == 0x8:
            connection.sendall(frame(0x8, payload))
            return
        if op == 0x9:
            connection.sendall(frame(0xA, payload))
            continue
        if op == 0xA:
            continue
        if op:
            message, opcode = b'', op
        message += payload
        if fin:
            connection.sendall(frame(opcode, message))


def drain(connection):
    try:
        while connection.recv(65536):
            pass
    except OSError:
        pass


def serve_websocket(connection, path, query, headers):
    record({'path': path, 'cookie': headers.get('cookie'), 'origin': headers.get('origin'),
            'protocol': headers.get('sec-websocket-protocol'), 'authorization': (headers.get('authorization') or '').split(' ')[0] or None})
    if path == '/echo':
        connection.sendall(handshake(headers))
        return echo(connection)
    if path == '/headers':
        connection.sendall(handshake(headers) + frame(0x1, json.dumps(headers).encode()))
        return echo(connection)
    if path == '/set-cookie':
        connection.sendall(handshake(headers, ['Set-Cookie: ws-cookie=2; Path=/']) + frame(0x1, b'ok'))
        return echo(connection)
    if path == '/protocol':
        offered = [value.strip() for value in headers.get('sec-websocket-protocol', '').split(',') if value.strip()]
        connection.sendall(handshake(headers, [f'Sec-WebSocket-Protocol: {offered[-1]}'] if offered else []))
        return echo(connection)
    if path == '/bad-protocol':
        connection.sendall(handshake(headers, ['Sec-WebSocket-Protocol: nobody-offered-this']))
        return drain(connection)
    if path == '/extension':
        connection.sendall(handshake(headers, ['Sec-WebSocket-Extensions: permessage-deflate']))
        return drain(connection)
    if path == '/bad-accept':
        connection.sendall(handshake({'sec-websocket-key': 'not-the-key'}))
        return drain(connection)
    if path == '/close':
        code = int(query.get('code', ['1000'])[0])
        reason = query.get('reason', [''])[0].encode()
        connection.sendall(handshake(headers) + frame(0x8, code.to_bytes(2, 'big') + reason))
        fin, op, payload = read_frame(connection)
        record({'path': path, 'echoed': payload[:2].hex() if op == 0x8 else None})
        return
    if path == '/close-empty':
        connection.sendall(handshake(headers) + frame(0x8))
        read_frame(connection)
        return
    if path == '/abort':
        connection.sendall(handshake(headers))
        return
    if path == '/frame-eof':
        connection.sendall(handshake(headers) + frame(0x1, b'hello'))
        return
    if path == '/close-1000':
        connection.sendall(handshake(headers) + frame(0x8, (1000).to_bytes(2, 'big')))
        return
    if path == '/drop-client-close':
        connection.sendall(handshake(headers))
        read_frame(connection)
        return
    if path == '/bad-utf8':
        connection.sendall(handshake(headers) + frame(0x1, b'\xff\xfe\xfd'))
        return drain(connection)
    if path == '/masked':
        connection.sendall(handshake(headers) + frame(0x1, b'masked', masked=True))
        return drain(connection)
    if path == '/fragmented':
        connection.sendall(handshake(headers) + frame(0x1, b'fragm', fin=False) + frame(0x9, b'p') + frame(0x0, b'ented ', fin=False)
                           + frame(0x0, b'message'))
        return echo(connection)
    if path == '/ping':
        connection.sendall(handshake(headers) + frame(0x9, b'probe'))
        while True:
            fin, op, payload = read_frame(connection)
            if op == 0xA:
                connection.sendall(frame(0x1, b'pong ' + payload))
                return echo(connection)
            if op == 0x8:
                connection.sendall(frame(0x8, payload))
                return
    if path == '/slow-sink':
        connection.sendall(handshake(headers))
        total = 0
        try:
            while True:
                fin, op, payload = read_frame(connection, delay=RATE)
                if op == 0x8:
                    break
                total += len(payload)
        except (EOFError, OSError):
            pass
        record({'path': path, 'received': total})
        return
    connection.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')


def serve_basic(connection, headers, rest):
    while headers.get('authorization') != CREDENTIAL:
        record({'path': '/basic', 'authorization': (headers.get('authorization') or '').split(' ')[0] or None})
        connection.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="ws"\r\nContent-Length: 0\r\n\r\n')
        method, target, headers, rest = read_head(connection, rest)
        if not method:
            return
    serve_websocket(connection, '/echo', {}, headers)


def serve_ntlm(connection, headers, rest):
    if not spnego:
        return respond(connection, '501 Not Implemented', 'pyspnego is not installed')
    context = None
    while True:
        authorization = headers.get('authorization', '')
        record({'path': '/ntlm', 'authorization': authorization.split(' ')[0] or None})
        if authorization.startswith('NTLM '):
            context = context or spnego.server(protocol='ntlm')
            try:
                token = context.step(base64.b64decode(authorization[5:]))
            except Exception:
                context, token = None, None
            if context and context.complete:
                record({'path': '/ntlm', 'user': str(context.client_principal)})
                return serve_websocket(connection, '/echo', {}, headers)
            challenge = b'NTLM ' + base64.b64encode(token) if token else b'NTLM'
        else:
            context, challenge = None, b'NTLM'
        body = b'challenge'
        connection.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: ' + challenge + b'\r\nContent-Length: '
                           + str(len(body)).encode() + b'\r\n\r\n' + body)
        method, target, headers, rest = read_head(connection, rest)
        if not method:
            return


def handle(connection):
    try:
        method, target, headers, rest = read_head(connection)
        if not method:
            return
        parsed = urllib.parse.urlsplit(target)
        path, query = parsed.path, urllib.parse.parse_qs(parsed.query)
        if headers.get('upgrade', '').lower() != 'websocket':
            if path in ('/', '/websocket.html'):
                with open(os.path.join(ROOT, 'websocket.html'), 'rb') as file:
                    return respond(connection, '200 OK', file.read(), 'text/html; charset=utf-8')
            if path == '/log':
                with LOCK:
                    return respond(connection, '200 OK', json.dumps(LOG), 'application/json', ['Access-Control-Allow-Origin: *'])
            if path == '/reset':
                with LOCK:
                    LOG.clear()
                return respond(connection, '200 OK', 'reset', headers=['Access-Control-Allow-Origin: *'])
            return respond(connection, '404 Not Found', 'not found')
        if path == '/no-answer':
            record({'path': path})
            return drain(connection)
        if path == '/redirect':
            record({'path': path})
            return connection.sendall(b'HTTP/1.1 302 Found\r\nLocation: /echo\r\nContent-Length: 0\r\n\r\n')
        if path == '/basic':
            return serve_basic(connection, headers, rest)
        if path == '/ntlm':
            return serve_ntlm(connection, headers, rest)
        serve_websocket(connection, path, query, headers)
    except (EOFError, OSError, ssl.SSLError):
        pass
    finally:
        try:
            connection.close()
        except OSError:
            pass


def tls_context():
    directory = os.path.join(ROOT, 'build', 'tls')
    cert, key = os.path.join(directory, 'cert.pem'), os.path.join(directory, 'key.pem')
    if not os.path.exists(cert):
        os.makedirs(directory, exist_ok=True)
        config = os.path.join(directory, 'openssl.cnf')
        with open(config, 'w') as file:
            file.write('[req]\ndistinguished_name=dn\n[dn]\n[v3]\nsubjectAltName=IP:127.0.0.1\n'
                       'basicConstraints=critical,CA:TRUE\nextendedKeyUsage=serverAuth\n')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-sha256',
                        '-subj', '/CN=127.0.0.1', '-config', config, '-extensions', 'v3', '-keyout', key, '-out', cert],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


def listen(port, context=None):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(64)
    while True:
        connection, _ = listener.accept()

        def run(connection=connection):
            if context:
                try:
                    connection = context.wrap_socket(connection, server_side=True)
                except (ssl.SSLError, OSError):
                    connection.close()
                    return
            handle(connection)
        threading.Thread(target=run, daemon=True).start()


if __name__ == '__main__':
    threading.Thread(target=listen, args=(18996, tls_context()), daemon=True).start()
    listen(18995)
