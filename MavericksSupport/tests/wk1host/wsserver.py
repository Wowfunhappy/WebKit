#!/usr/bin/python
# A canned WebSocket server for driving WebKit's handshake and frame paths from a shell.
#
#   ./wsserver.py [port] [extension-mode]
#
# extension-mode picks what goes in the Sec-WebSocket-Extensions response:
#   vscode  - VS Code's rule: echo permessage-deflate, else x-webkit-deflate-frame, else nothing
#   none    - never send the header
#   token   - echo x-webkit-deflate-frame whether or not the client offered it
#   params  - echo x-webkit-deflate-frame with a max_window_bits parameter
#   pmd     - echo permessage-deflate, which the client never offers
#
# GET / serves a page that opens a socket back to this server, sends a message and reports what
# happened through console.log(). Compressed frames (RSV1) are inflated and the echo is compressed
# back with one persistent zlib stream per direction, which is what "context takeover" means.
import base64, hashlib, re, socket, struct, sys, threading, zlib

GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

PAGE = """<!DOCTYPE html>
<title>ws</title>
<body>
<script>
var ws = new WebSocket('ws://' + location.host + '/ws');
var sent = 0;
ws.onopen = function () { console.log('WS OPEN extensions=[' + ws.extensions + ']'); ws.send('message ' + (++sent)); };
ws.onmessage = function (e) { console.log('WS MESSAGE ' + e.data); if (sent < 4) ws.send('message ' + (++sent)); };
ws.onerror = function () { console.log('WS ERROR'); };
ws.onclose = function (e) { console.log('WS CLOSE code=' + e.code + ' reason=' + e.reason + ' clean=' + e.wasClean); };
</script>
</body>
"""


def read_headers(sock):
    data = ''
    while '\r\n\r\n' not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None, ''
        data += chunk
    head, rest = data.split('\r\n\r\n', 1)
    lines = head.split('\r\n')
    headers = {}
    for line in lines[1:]:
        if ':' in line:
            name, value = line.split(':', 1)
            headers[name.strip().lower()] = value.strip()
    return (lines[0], headers), rest


def extension_response(offered, mode):
    if mode == 'none':
        return None
    if mode == 'token':
        return 'x-webkit-deflate-frame'
    if mode == 'params':
        return 'x-webkit-deflate-frame; max_window_bits=12'
    if mode == 'pmd':
        return 'permessage-deflate'
    if not offered:
        return None
    if re.search(r'\b((server_max_window_bits)|(server_no_context_takeover)|(client_no_context_takeover))\b', offered):
        return None
    if re.search(r'\b(permessage-deflate)\b', offered):
        return 'permessage-deflate'
    if re.search(r'\b(x-webkit-deflate-frame)\b', offered):
        return 'x-webkit-deflate-frame'
    return None


def send_frame(sock, payload, deflater, compress):
    rsv1 = 0
    if compress and deflater is not None and payload:
        payload = deflater.compress(payload) + deflater.flush(zlib.Z_SYNC_FLUSH)
        payload = payload[:-4]
        rsv1 = 0x40
    header = struct.pack('!B', 0x80 | rsv1 | 0x1)
    length = len(payload)
    if length < 126:
        header += struct.pack('!B', length)
    elif length < 65536:
        header += struct.pack('!BH', 126, length)
    else:
        header += struct.pack('!BQ', 127, length)
    sock.sendall(header + payload)


def serve_socket(sock, rest, extensions, log):
    inflater = zlib.decompressobj(-15)
    deflater = zlib.compressobj(6, zlib.DEFLATED, -15)
    compressing = extensions is not None
    buf = rest
    while True:
        while len(buf) < 2:
            chunk = sock.recv(4096)
            if not chunk:
                log('client closed the connection')
                return
            buf += chunk
        first, second = struct.unpack('!BB', buf[:2])
        opcode = first & 0xf
        rsv1 = bool(first & 0x40)
        masked = bool(second & 0x80)
        length = second & 0x7f
        offset = 2
        if length == 126:
            length = struct.unpack('!H', buf[offset:offset + 2])[0]
            offset += 2
        elif length == 127:
            length = struct.unpack('!Q', buf[offset:offset + 8])[0]
            offset += 8
        need = offset + (4 if masked else 0) + length
        while len(buf) < need:
            chunk = sock.recv(4096)
            if not chunk:
                log('client closed mid-frame')
                return
            buf += chunk
        mask = buf[offset:offset + 4] if masked else ''
        offset += 4 if masked else 0
        payload = buf[offset:offset + length]
        buf = buf[need:]
        if masked:
            payload = ''.join(chr(ord(c) ^ ord(mask[i % 4])) for i, c in enumerate(payload))
        if rsv1:
            payload = inflater.decompress(payload + '\x00\x00\xff\xff')
        log('frame opcode=%d rsv1=%d len=%d payload=%r' % (opcode, rsv1, length, payload[:120]))
        if opcode == 0x8:
            sock.sendall('\x88\x00')
            return
        if opcode == 0x9:
            sock.sendall('\x8a\x00')
            continue
        if opcode in (0x1, 0x2):
            send_frame(sock, 'echo: ' + payload, deflater, compressing)


def handle(sock, addr, mode):
    def log(message):
        print '[%s:%d] %s' % (addr[0], addr[1], message)
        sys.stdout.flush()

    parsed, rest = read_headers(sock)
    if parsed is None:
        return
    request_line, headers = parsed
    log('request %s' % request_line)
    for name in sorted(headers):
        log('  %s: %s' % (name, headers[name]))

    if headers.get('upgrade', '').lower() != 'websocket':
        body = PAGE
        sock.sendall('HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' % (len(body), body))
        sock.close()
        return

    accept = base64.b64encode(hashlib.sha1(headers.get('sec-websocket-key', '') + GUID).digest())
    response = ['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade',
                'Sec-WebSocket-Accept: %s' % accept]
    extensions = extension_response(headers.get('sec-websocket-extensions'), mode)
    if extensions:
        response.append('Sec-WebSocket-Extensions: %s' % extensions)
    log('responding with extensions=%r' % extensions)
    sock.sendall('\r\n'.join(response) + '\r\n\r\n')
    try:
        serve_socket(sock, rest, extensions, log)
    finally:
        sock.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    mode = sys.argv[2] if len(sys.argv) > 2 else 'vscode'
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(8)
    print 'listening on http://localhost:%d/ (mode=%s)' % (port, mode)
    sys.stdout.flush()
    while True:
        sock, addr = listener.accept()
        threading.Thread(target=handle, args=(sock, addr, mode)).start()


main()
