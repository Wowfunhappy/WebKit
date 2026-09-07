#!/usr/bin/env python3
"""Loopback TLS fixtures for the certificate tests.

  cocoa-curl-tls-fixtures.py make <dir>
      Writes identity.p12 (RSA) and ec-identity.p12 (P-256), signed by root.pem, passphrase "fixture";
      the server's self-signed server.key / server.pem / server.der (CN 127.0.0.1, SAN IP:127.0.0.1);
      and root.pem plus trusted.key / trusted.pem, a leaf for the same name signed by that root. A run
      that trusts root.pem in the system keychain gets a chain the platform accepts.
  cocoa-curl-tls-fixtures.py serve <dir> --port N [--client-auth] [--tls 1.2|1.3] [--chain trusted]
      HTTPS server on 127.0.0.1:N presenting server.pem, or the root-signed leaf with --chain trusted;
      every path answers "mTLS" (4 bytes). --client-auth requires a certificate signed by one of the two
      identities above; --tls pins the version.
"""
import argparse, datetime, http.server, os, pathlib, ssl, sys
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
        version = {'1.2': ssl.TLSVersion.TLSv1_2, '1.3': ssl.TLSVersion.TLSv1_3}[tls]
        context.minimum_version = version; context.maximum_version = version
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print('TLS fixture on 127.0.0.1:%d chain=%s client-auth=%d tls=%s' % (port, leaf, client_auth, tls or 'any'), flush=True)
    server.serve_forever()

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('command', choices=['make', 'serve']); p.add_argument('directory', type=pathlib.Path)
    p.add_argument('--port', type=int); p.add_argument('--client-auth', action='store_true'); p.add_argument('--tls', choices=['1.2', '1.3'])
    p.add_argument('--chain', choices=['self-signed', 'trusted'], default='self-signed')
    a = p.parse_args()
    make(a.directory) if a.command == 'make' else serve(a.directory, a.port, a.client_auth, a.tls, a.chain)
