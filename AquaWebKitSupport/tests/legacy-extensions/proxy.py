#!/usr/bin/env python3
# Test proxies for the proxy API (pages/proxy.html, proxy.safariextension), all on 127.0.0.1:
#   8856  HTTP proxy
#   8857  HTTP proxy that requires Proxy-Authorization: Basic test:secret, answering 407 without it
#   8858  SOCKS5 proxy that requires the username "test" and the password "secret"
#   8860  HTTPS proxy: the HTTP proxy reached over TLS, with a certificate for 127.0.0.1 that build/proxy-tls/ holds
#         (made on first run). Trust it to test a trusted HTTPS proxy:
#         security add-trusted-cert -r trustRoot -p ssl -k ~/Library/Keychains/login.keychain build/proxy-tls/cert.pem
# Nothing listens on 8859, the dead proxy.
#
# The proxies reach nothing themselves. A request for a host under .proxy-test, which no resolver knows, is
# answered by the proxy with JSON naming the proxy, host, path and Proxy-Authorization it saw; a WebSocket
# handshake for one is accepted and answered with one text message, "<proxy> <path>", before the proxy closes it;
# a CONNECT is recorded, a tunnel to port 80 of such a host answered the same way, and any other tunnel closed;
# any other request is answered 502. Every request is recorded, and
# GET /log on any of the HTTP ports returns the record (GET /reset clears it).

import base64
import hashlib
import json
import os
import socket
import ssl
import subprocess
import socketserver
import threading
import time
import urllib.parse

LOG = []
LOCK = threading.Lock()
CREDENTIAL = 'Basic ' + base64.b64encode(b'test:secret').decode()


def record(entry):
    with LOCK:
        LOG.append(dict(entry, time=time.time()))


def respond(stream, status, body, content_type='application/json', headers=()):
    data = body.encode() if isinstance(body, str) else body
    lines = [f'HTTP/1.1 {status}', f'Content-Type: {content_type}', f'Content-Length: {len(data)}',
             'Access-Control-Allow-Origin: *', 'Cache-Control: no-store', 'Connection: close', *headers, '', '']
    stream.write('\r\n'.join(lines).encode() + data)
    stream.flush()


def read_head(stream):
    request_line = stream.readline().decode('latin-1').rstrip('\r\n')
    headers = {}
    while True:
        line = stream.readline().decode('latin-1')
        if line in ('\r\n', '\n', ''):
            break
        name, _, value = line.partition(':')
        headers[name.strip().lower()] = value.strip()
    return request_line, headers


def answer(stream, proxy, method, host, path, headers):
    authorization = headers.get('proxy-authorization')
    upgrade = headers.get('upgrade', '').lower() == 'websocket'
    record({'proxy': proxy, 'method': 'WEBSOCKET' if upgrade else method, 'host': host, 'path': path, 'authorization': authorization})
    if host.endswith('.proxy-test') and upgrade:
        accept = base64.b64encode(hashlib.sha1((headers.get('sec-websocket-key', '') + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        stream.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                      f'Sec-WebSocket-Accept: {accept}\r\n\r\n').encode())
        message = f'{proxy} {path}'.encode()
        stream.write(bytes([0x81, len(message)]) + message + b'\x88\x02\x03\xe8')
        stream.flush()
        time.sleep(0.5)
        return
    if host.endswith('.proxy-test'):
        respond(stream, '200 OK', json.dumps({'proxy': proxy, 'host': host, 'path': path, 'authorization': authorization}))
    else:
        respond(stream, '502 Bad Gateway', json.dumps({'proxy': proxy, 'error': 'the test proxy reaches no other host'}))


class HTTPProxy(socketserver.StreamRequestHandler):
    def handle(self):
        port = self.server.server_address[1]
        request_line, headers = read_head(self.rfile)
        parts = request_line.split(' ')
        if len(parts) != 3:
            return
        method, target, _ = parts
        authorization = headers.get('proxy-authorization')
        if target in ('/log', '/reset'):
            with LOCK:
                if target == '/reset':
                    LOG.clear()
                body = json.dumps(LOG, indent=1)
            return respond(self.wfile, '200 OK', body)
        if self.server.requires_credential and authorization != CREDENTIAL:
            record({'proxy': port, 'method': method, 'target': target, 'authorization': authorization, 'status': 407})
            return respond(self.wfile, '407 Proxy Authentication Required', '{}', headers=['Proxy-Authenticate: Basic realm="proxy-test"'])
        if method == 'CONNECT':
            record({'proxy': port, 'method': 'CONNECT', 'target': target, 'authorization': authorization})
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            self.wfile.flush()
            # A tunnel to port 80 of a .proxy-test host carries plain HTTP, which the proxy answers as the host.
            host, _, tunnel_port = target.rpartition(':')
            if host.endswith('.proxy-test') and tunnel_port == '80':
                inner_line, inner_headers = read_head(self.rfile)
                inner = inner_line.split(' ')
                if len(inner) == 3:
                    inner_headers['proxy-authorization'] = authorization
                    answer(self.wfile, port, inner[0], host, inner[1], inner_headers)
            return
        url = urllib.parse.urlsplit(target)
        answer(self.wfile, port, method, url.hostname or headers.get('host', ''), url.path + (f'?{url.query}' if url.query else ''), headers)


class SOCKS5Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        read = self.rfile.read
        version, count = read(2)
        methods = read(count)
        if version != 5 or (2 not in methods and 0 not in methods):
            self.wfile.write(b'\x05\xff')
            return
        # A client that offers credentials must give the right ones; one that offers none is let through.
        user = None
        if 2 in methods:
            self.wfile.write(b'\x05\x02')
            self.wfile.flush()
            _, user_length = read(2)
            user = read(user_length).decode()
            password_length = read(1)[0]
            password = read(password_length).decode()
            if (user, password) != ('test', 'secret'):
                record({'proxy': 'socks', 'user': user, 'status': 'refused'})
                self.wfile.write(b'\x01\x01')
                return
            self.wfile.write(b'\x01\x00')
        else:
            self.wfile.write(b'\x05\x00')
        self.wfile.flush()
        _, command, _, address_type = read(4)
        if address_type == 3:
            host = read(read(1)[0]).decode()
        elif address_type == 1:
            host = socket.inet_ntoa(read(4))
        else:
            host = socket.inet_ntop(socket.AF_INET6, read(16))
        port = int.from_bytes(read(2), 'big')
        self.wfile.write(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
        self.wfile.flush()
        request_line, headers = read_head(self.rfile)
        parts = request_line.split(' ')
        method, path = (parts[0], parts[1]) if len(parts) == 3 else ('', '')
        headers['proxy-authorization'] = None
        answer(self.wfile, 'socks' if user else 'socks-anonymous', method, host if address_type == 3 else f'{host}:{port}', path, headers)


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128


class TLSServer(Server):
    def __init__(self, address, handler, context):
        super().__init__(address, handler)
        self.context = context

    def get_request(self):
        connection, address = super().get_request()
        return self.context.wrap_socket(connection, server_side=True), address


def tls_context():
    directory = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'build', 'proxy-tls')
    cert, key = os.path.join(directory, 'cert.pem'), os.path.join(directory, 'key.pem')
    if not os.path.exists(cert):
        os.makedirs(directory, exist_ok=True)
        config = os.path.join(directory, 'openssl.cnf')
        with open(config, 'w') as file:
            file.write('[req]\ndistinguished_name=dn\n[dn]\n[v3]\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n'
                       'basicConstraints=critical,CA:TRUE\nextendedKeyUsage=serverAuth\n')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-sha256',
                        '-subj', '/CN=127.0.0.1', '-config', config, '-extensions', 'v3', '-keyout', key, '-out', cert], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    return context


def server(port, handler, requires_credential=False):
    instance = Server(('127.0.0.1', port), handler)
    instance.requires_credential = requires_credential
    return instance


if __name__ == '__main__':
    tls = TLSServer(('127.0.0.1', 8860), HTTPProxy, tls_context())
    tls.requires_credential = False
    for background in (server(8857, HTTPProxy, requires_credential=True), server(8858, SOCKS5Proxy), tls):
        threading.Thread(target=background.serve_forever, daemon=True).start()
    server(8856, HTTPProxy).serve_forever()
