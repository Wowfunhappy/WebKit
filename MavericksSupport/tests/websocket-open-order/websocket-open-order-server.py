# WebSocket handshake fixture for websocket-open-order.mm. Every path answers with a valid 101:
#   /abort       closes the connection right after the handshake response
#   /frame       sends a text frame in the same write as the handshake response and keeps the connection up
#   /late-close  closes the connection half a second after the handshake response
#   /frame-eof   sends a text frame in the same write as the handshake response, then closes the connection
#   /close-1000  sends a Close frame (1000) in the same write as the handshake response, then closes the connection
#   /drop-client-close waits for the client's Close frame and drops TCP without echoing it
#   /echo-client-close echoes the client's Close frame before closing the connection
import base64, hashlib, socket, sys, threading, time
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
def receive_frame(c):
    header = c.recv(2)
    if len(header) != 2:
        return None, b''
    opcode = header[0] & 0x0f
    length = header[1] & 0x7f
    if length == 126:
        length = int.from_bytes(c.recv(2), 'big')
    elif length == 127:
        length = int.from_bytes(c.recv(8), 'big')
    mask = c.recv(4) if header[1] & 0x80 else b''
    payload = b''
    while len(payload) < length:
        part = c.recv(length - len(payload))
        if not part:
            break
        payload += part
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return opcode, payload
def handle(c):
    buf = b''
    while b'\r\n\r\n' not in buf:
        d = c.recv(4096)
        if not d:
            c.close(); return
        buf += d
    lines = buf.split(b'\r\n\r\n', 1)[0].decode('latin1').split('\r\n')
    path = lines[0].split(' ')[1]
    h = {l.split(':', 1)[0].strip().lower(): l.split(':', 1)[1].strip() for l in lines[1:] if ':' in l}
    accept = base64.b64encode(hashlib.sha1((h['sec-websocket-key'] + GUID).encode()).digest()).decode()
    response = ('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' % accept).encode()
    print('request %s' % path, flush=True)
    if path == '/abort':
        c.sendall(response); c.close(); return
    if path == '/frame':
        c.sendall(response + b'\x81\x05hello')
        try:
            while c.recv(4096):
                pass
        except OSError:
            pass
        c.close(); return
    if path == '/late-close':
        c.sendall(response); time.sleep(0.5); c.close(); return
    if path == '/frame-eof':
        c.sendall(response + b'\x81\x05hello'); c.close(); return
    if path == '/close-1000':
        c.sendall(response + b'\x88\x02\x03\xe8'); c.close(); return
    if path in ('/drop-client-close', '/echo-client-close'):
        c.sendall(response)
        opcode, payload = receive_frame(c)
        if path == '/echo-client-close' and opcode == 8:
            c.sendall(bytes([0x88, len(payload)]) + payload)
        c.close(); return
    c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(8)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
