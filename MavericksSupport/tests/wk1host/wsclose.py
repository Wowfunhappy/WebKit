#!/usr/bin/python
# A WebSocket server that sends a message and its Close frame in one write and then closes the
# socket, so both arrive in a single readable pass. The page reports what the client made of it:
# the message has to be delivered and the close has to carry the server's code, not 1006.
#
#   ./wsclose.py [port]
import base64, hashlib, socket, struct, sys, threading

GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

PAGE = """<!DOCTYPE html>
<title>ws close</title>
<body>
<script>
var log = [];
function say(text) { log.push(text); console.log(text); document.title = log.join(' | '); }
var ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
ws.onopen = function () { say('OPEN'); };
ws.onmessage = function (e) { say('MESSAGE ' + e.data); };
ws.onerror = function () { say('ERROR'); };
ws.onclose = function (e) { say('CLOSE code=' + e.code + ' reason=' + e.reason + ' clean=' + e.wasClean); };
</script>
</body>
"""


def read_headers(sock):
    data = ''
    while '\r\n\r\n' not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data += chunk
    head = data.split('\r\n\r\n', 1)[0]
    lines = head.split('\r\n')
    headers = {}
    for line in lines[1:]:
        if ':' in line:
            name, value = line.split(':', 1)
            headers[name.strip().lower()] = value.strip()
    return lines[0], headers


def frame(opcode, payload):
    header = struct.pack('!B', 0x80 | opcode)
    if len(payload) < 126:
        header += struct.pack('!B', len(payload))
    else:
        header += struct.pack('!BH', 126, len(payload))
    return header + payload


def serve(conn):
    try:
        parsed = read_headers(conn)
        if not parsed:
            return
        request, headers = parsed
        if '/ws' not in request.split(' ')[1]:
            body = PAGE
            conn.sendall('HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n'
                         'Content-Length: %d\r\nConnection: close\r\n\r\n%s' % (len(body), body))
            return
        accept = base64.b64encode(hashlib.sha1(headers.get('sec-websocket-key', '') + GUID).digest())
        conn.sendall('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                     'Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' % accept)
        # One write, two frames: a text message and the Close that ends the connection.
        conn.sendall(frame(0x1, 'coalesced') + frame(0x8, struct.pack('!H', 3001) + 'bye'))
        conn.shutdown(socket.SHUT_WR)
    finally:
        conn.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8890
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', port))
    listener.listen(8)
    print 'listening on http://127.0.0.1:%d/' % port
    sys.stdout.flush()
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=serve, args=(conn,)).start()


main()
