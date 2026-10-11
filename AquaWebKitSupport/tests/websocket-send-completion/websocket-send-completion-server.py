# WebSocket sink for websocket-send-completion.mm. Every path answers with a valid 101:
#   /slow-sink  reads frames at 2 MB/s and prints the payload bytes it received
#   /stall      reads nothing after the handshake and keeps the connection up
#   /late-open  holds the 101 for half a second, follows it with a text frame "early N" counting the bytes that
#               arrived before it, then reads like /slow-sink
import base64, hashlib, socket, sys, threading, time
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
RATE = 2 * 1000 * 1000
def receive(c, n):
    data = b''
    while len(data) < n:
        part = c.recv(n - len(data))
        if not part:
            raise EOFError
        data += part
    return data
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
    if path == '/late-open':
        time.sleep(0.5)
        c.setblocking(False)
        try:
            early = len(c.recv(65536))
        except BlockingIOError:
            early = 0
        c.setblocking(True)
        early += len(buf.split(b'\r\n\r\n', 1)[1])
    c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' % accept).encode())
    print('request %s' % path, flush=True)
    if path == '/late-open':
        report = ('early %d' % early).encode()
        c.sendall(bytes([0x81, len(report)]) + report)
    if path == '/stall':
        time.sleep(30)
        c.close(); return
    total = 0
    try:
        while True:
            b0, b1 = receive(c, 2)
            length = b1 & 0x7f
            if length == 126:
                length = int.from_bytes(receive(c, 2), 'big')
            elif length == 127:
                length = int.from_bytes(receive(c, 8), 'big')
            receive(c, 4)
            time.sleep(length / RATE)
            receive(c, length)
            if b0 & 0x0f == 8:
                break
            total += length
    except (EOFError, OSError):
        pass
    print('%s received %d bytes' % (path, total), flush=True)
    c.close()
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', int(sys.argv[1]))); s.listen(8)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
