# Loopback NTLM and Kerberos/SPNEGO WebSocket authentication fixture.
import base64, hashlib, itertools, os, pathlib, socket, sys, threading
import spnego
from native_gss import Acceptor
ROOT = pathlib.Path(os.environ['WEBSOCKET_AUTH_WORK'])
(ROOT/'users.txt').write_text('CURL:curl-test:correct-password\n'); os.environ['NTLM_USER_FILE'] = str(ROOT/'users.txt')
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
ids = itertools.count(1)
def handle(c, cid):
    context = None; n = 0
    buf = b''
    while True:
        while b'\r\n\r\n' not in buf:
            d = c.recv(4096)
            if not d:
                print('conn %d closed after %d requests' % (cid, n), flush=True); return
            buf += d
        head, buf = buf.split(b'\r\n\r\n', 1)
        n += 1
        lines = head.decode('latin1').split('\r\n')
        h = {l.split(':', 1)[0].strip().lower(): l.split(':', 1)[1].strip() for l in lines[1:] if ':' in l}
        auth = h.get('authorization', '')
        scheme = 'Negotiate' if ' /negotiate ' in lines[0] else 'NTLM'
        print('conn %d request %d authorization=%s' % (cid, n, auth.split(' ')[0] if auth else None), flush=True)
        if auth.startswith(scheme + ' '):
            if context is None: context = Acceptor() if scheme == 'Negotiate' else spnego.server(protocol='ntlm')
            try:
                token = context.step(base64.b64decode(auth[len(scheme) + 1:]))
            except Exception as e:
                print('conn %d %s refused %r' % (cid, scheme, e), flush=True)
                context = None
                c.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: ' + scheme.encode() + b'\r\nContent-Length: 0\r\n\r\n'); continue
            if context.complete:
                if scheme == 'Negotiate' and context.client_principal != os.environ['WEBSOCKET_KERBEROS_PRINCIPAL']:
                    raise RuntimeError('unexpected fixture principal')
                accept = base64.b64encode(hashlib.sha1((h['sec-websocket-key'] + GUID).encode()).digest()).decode()
                print('conn %d upgraded principal=%s' % (cid, context.client_principal), flush=True)
                c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n%s\r\n' % (accept, ('WWW-Authenticate: Negotiate ' + base64.b64encode(token).decode() + '\r\n') if scheme == 'Negotiate' and token else '')).encode())
                c.sendall(b'\x81\x05hello')
                continue
            body = b'challenge'
            c.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: ' + scheme.encode() + b' ' + base64.b64encode(token) + b'\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            continue
        context = None
        body = b'refused'
        c.sendall(b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: ' + scheme.encode() + b'\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 18986)); s.listen(8)
while True:
    c, _ = s.accept(); threading.Thread(target=handle, args=(c, next(ids)), daemon=True).start()
