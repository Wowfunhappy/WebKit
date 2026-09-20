#!/usr/bin/env python3
"""Loopback TLS fixtures for the certificate tests.

  cocoa-curl-tls-fixtures.py make <dir>
      Writes identity.p12 (RSA) and ec-identity.p12 (P-256), signed by root.pem, passphrase "fixture";
      the server's self-signed server.key / server.pem / server.der (CN 127.0.0.1, SAN IP:127.0.0.1);
      and root.pem plus trusted.key / trusted.pem, a leaf for the same name signed by that root. A run
      that trusts root.pem in the system keychain gets a chain the platform accepts.
  cocoa-curl-tls-fixtures.py serve <dir> --port N [--client-auth] [--tls 1.1|1.2|1.3] [--chain trusted]
      HTTPS server on 127.0.0.1:N presenting server.pem, or the root-signed leaf with --chain trusted;
      HTTP requests answer "mTLS" (4 bytes); /websocket upgrades and sends the same text in a frame.
      --client-auth requires a certificate signed by one of the two identities above; --tls pins the version.
  cocoa-curl-tls-fixtures.py framing <dir> --port N
      HTTPS server on the root-signed leaf that answers each path below with raw bytes and then closes
      the TCP socket without a TLS close_notify, the way a server ending a body by closing the
      connection does. The paths cover each arm of the message-framing decision that close makes:

        /close-delimited          200, no Content-Length, no chunked coding: the close ends the body
        /close-delimited-error    the same framing under a 404
        /short-length             Content-Length longer than the bytes sent
        /chunked-truncated        chunked coding cut mid-chunk
        /multipart                multipart/x-mixed-replace, two parts, no terminating boundary

      --h2 answers over HTTP/2 instead, whose framing ends a body with END_STREAM, so the same close
      truncates the response however the head was framed.
"""
import argparse, datetime, http.server, os, pathlib, socket, ssl, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, ec
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

def certificate(name, key, usage, san=None, issuer=None, signer=None, ca=False):
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.datetime.utcnow()
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer or subject).public_key(key.public_key())
               .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
               .not_valid_after(now + datetime.timedelta(days=30))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if usage:
        builder = builder.add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
    if san:
        builder = builder.add_extension(x509.SubjectAlternativeName(san), critical=False)
    return builder.sign(signer or key, hashes.SHA256())

def make(directory):
    directory.mkdir(parents=True, exist_ok=True)
    rootKey = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    root = certificate('WK Cocoa curl test root ' + datetime.datetime.utcnow().strftime('%Y%m%dT%H%M%S'), rootKey, None, ca=True)
    (directory / 'root.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
    # The client identities chain to that root, as a real one chains to an issuer the system trusts, so
    # the platform treats them as usable for client authentication and offers them.
    for name, key in (('identity', rsa.generate_private_key(public_exponent=65537, key_size=2048)), ('ec-identity', ec.generate_private_key(ec.SECP256R1()))):
        cert = certificate('curl ' + name, key, ExtendedKeyUsageOID.CLIENT_AUTH, None, root.subject, rootKey)
        (directory / (name + '.p12')).write_bytes(pkcs12.serialize_key_and_certificates(name.encode(), key, cert, [root], serialization.BestAvailableEncryption(b'fixture')))
    (directory / 'clients.pem').write_bytes(root.public_bytes(serialization.Encoding.PEM))
    import ipaddress
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    cert = certificate('127.0.0.1', key, ExtendedKeyUsageOID.SERVER_AUTH, [x509.IPAddress(ipaddress.ip_address('127.0.0.1')), x509.DNSName('localhost')])
    (directory / 'server.key').write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    (directory / 'server.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (directory / 'server.der').write_bytes(cert.public_bytes(serialization.Encoding.DER))
    leafKey = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf = certificate('127.0.0.1', leafKey, ExtendedKeyUsageOID.SERVER_AUTH,
                       [x509.IPAddress(ipaddress.ip_address('127.0.0.1')), x509.DNSName('localhost')], root.subject, rootKey)
    (directory / 'trusted.key').write_bytes(leafKey.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    (directory / 'trusted.pem').write_bytes(leaf.public_bytes(serialization.Encoding.PEM) + root.public_bytes(serialization.Encoding.PEM))
    print('fixtures in', directory, flush=True)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        if self.path == '/websocket':
            import base64, hashlib
            self.protocol_version = 'HTTP/1.1'
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            self.wfile.write(b'\x81\x04mTLS\x88\x02\x03\xe8')
            self.wfile.flush()
            return
        body = b'mTLS'
        self.send_response(200); self.send_header('Content-Type', 'text/plain'); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, format, *args):
        sys.stdout.write('%s %s\n' % (self.address_string(), format % args)); sys.stdout.flush()

def serve(directory, port, client_auth, tls, chain):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    leaf = 'trusted' if chain == 'trusted' else 'server'
    context.load_cert_chain(str(directory / (leaf + '.pem')), str(directory / (leaf + '.key')))
    if client_auth:
        context.verify_mode = ssl.CERT_REQUIRED
        context.load_verify_locations(str(directory / 'clients.pem'))
    if tls:
        version = {'1.1': ssl.TLSVersion.TLSv1_1, '1.2': ssl.TLSVersion.TLSv1_2, '1.3': ssl.TLSVersion.TLSv1_3}[tls]
        context.minimum_version = version; context.maximum_version = version
        if tls == '1.1':
            context.set_ciphers('DEFAULT:@SECLEVEL=0')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print('TLS fixture on 127.0.0.1:%d chain=%s client-auth=%d tls=%s' % (port, leaf, client_auth, tls or 'any'), flush=True)
    server.serve_forever()

# Each response is written whole and the socket is then closed with no close_notify and no TLS
# shutdown, which is what a server that ends a body by closing the connection does.
FRAMING = {
    '/close-delimited': b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nHELLO',
    '/close-delimited-error': b'HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNOPE',
    '/short-length': b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100\r\n\r\nHELLO',
    '/chunked-truncated': b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHEL',
    # Two parts and no terminating boundary: multipart/x-mixed-replace ends where the connection does.
    '/multipart': b'HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=wkframing\r\n\r\n'
                  b'--wkframing\r\nContent-Type: text/plain\r\n\r\nFIRST\r\n'
                  b'--wkframing\r\nContent-Type: text/plain\r\n\r\nSECOND',
}

def h2_frame(kind, flags, stream, payload=b''):
    return len(payload).to_bytes(3, 'big') + bytes([kind, flags]) + stream.to_bytes(4, 'big') + payload

def h2_answer(connection):
    """A complete HTTP/2 response head and body, then the same abrupt close. HTTP/2 delimits a body with
    END_STREAM rather than with the connection, so this one is truncated however it ends."""
    preface = b''
    while len(preface) < 24:
        chunk = connection.recv(24 - len(preface))
        if not chunk:
            return
        preface += chunk
    connection.sendall(h2_frame(0x4, 0, 0))          # our SETTINGS
    connection.sendall(h2_frame(0x4, 0x1, 0))        # ACK theirs, unread: nothing here depends on them
    pending = b''
    while True:                                      # read frames until the request arrives
        while len(pending) < 9:
            chunk = connection.recv(4096)
            if not chunk:
                return
            pending += chunk
        length = int.from_bytes(pending[0:3], 'big')
        kind = pending[3]
        while len(pending) < 9 + length:
            chunk = connection.recv(4096)
            if not chunk:
                return
            pending += chunk
        frame, pending = pending[:9 + length], pending[9 + length:]
        if kind == 0x1:                              # HEADERS: the request
            stream = int.from_bytes(frame[5:9], 'big') & 0x7fffffff
            connection.sendall(h2_frame(0x1, 0x4, stream, b'\x88'))   # END_HEADERS, HPACK static :status 200
            connection.sendall(h2_frame(0x0, 0, stream, b'HELLO'))    # no END_STREAM
            # A PING is answered only once the frames ahead of it have been processed, so its ACK is
            # the client saying it holds the head and the body. Closing after it makes what the client
            # has seen when the connection dies the same on every run.
            connection.sendall(h2_frame(0x6, 0, 0, b'framing!'))
            while True:
                while len(pending) < 9:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    pending += chunk
                length = int.from_bytes(pending[0:3], 'big')
                kind = pending[3]
                flags = pending[4]
                while len(pending) < 9 + length:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    pending += chunk
                pending = pending[9 + length:]
                if kind == 0x6 and flags & 0x1:
                    return

def framing(directory, port, h2=False):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(directory / 'trusted.pem'), str(directory / 'trusted.key'))
    if h2:
        context.set_alpn_protocols(['h2'])
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(16)
    print('TLS framing fixture on 127.0.0.1:%d' % port, flush=True)
    while True:
        raw, _ = listener.accept()
        try:
            connection = context.wrap_socket(raw, server_side=True)
        except ssl.SSLError:
            raw.close()
            continue
        try:
            if h2:
                h2_answer(connection)
                print('h2 -> response head and body, closing without close_notify', flush=True)
            else:
                request = b''
                while b'\r\n\r\n' not in request:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    request += chunk
                target = request.split(b' ')[1].decode() if b' ' in request else ''
                body = FRAMING.get(target)
                if body is None:
                    body = b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
                connection.sendall(body)
                print('%s -> %d bytes, closing without close_notify' % (target, len(body)), flush=True)
        except (OSError, ssl.SSLError):
            pass
        finally:
            # detach() leaves the file descriptor open and hands back the plain socket, so closing it
            # sends no close_notify.
            try:
                fd = connection.detach()
                socket.socket(fileno=fd).close()
            except OSError:
                pass

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('command', choices=['make', 'serve', 'framing']); p.add_argument('directory', type=pathlib.Path)
    p.add_argument('--port', type=int); p.add_argument('--client-auth', action='store_true'); p.add_argument('--tls', choices=['1.1', '1.2', '1.3'])
    p.add_argument('--chain', choices=['self-signed', 'trusted'], default='self-signed')
    p.add_argument('--h2', action='store_true')
    a = p.parse_args()
    if a.command == 'make':
        make(a.directory)
    elif a.command == 'framing':
        framing(a.directory, a.port, a.h2)
    else:
        serve(a.directory, a.port, a.client_auth, a.tls, a.chain)
