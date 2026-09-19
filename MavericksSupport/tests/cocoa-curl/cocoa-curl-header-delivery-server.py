#!/usr/bin/env python3
"""Header sections carrying a line that is not a field line, and a CONNECT proxy whose tunnel
response carries one too.

  cocoa-curl-header-delivery-server.py --port 18988             origin
  cocoa-curl-header-delivery-server.py --proxy --port 18989     CONNECT proxy, relays anywhere

Every response is written as raw bytes so a line can end in a bare LF and a line can omit its
colon, neither of which a header-writing API will produce.
"""
import argparse, socket, threading

ORIGIN_CASES = {
    # A colon-less line between two field lines.
    '/nocolon': ("HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/plain\r\n"
                 "ZYX\r\n"
                 "Content-Length: 2\r\n"
                 "Connection: close\r\n\r\nok"),
    # The shape imported/w3c/web-platform-tests/cookies/value/value.html sends: a bare LF inside a
    # field value splits the line, leaving "ZYX" as a line of its own.
    '/bareLF': ("HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain\r\n"
                "Set-Cookie: test=13\nZYX\r\n"
                "Content-Length: 2\r\n"
                "Connection: close\r\n\r\nok"),
    # A colon-less line in the chunked trailer section, before a real trailer.
    '/trailer': ("HTTP/1.1 200 OK\r\n"
                 "Content-Type: text/plain\r\n"
                 "Transfer-Encoding: chunked\r\n"
                 "Trailer: X-Tr\r\n"
                 "Connection: close\r\n\r\n"
                 "2\r\nok\r\n0\r\nTRAILERNOCOLON\r\nX-Tr: v\r\n\r\n"),
    '/plain': ("HTTP/1.1 200 OK\r\n"
               "Content-Type: text/plain\r\n"
               "Content-Length: 2\r\n"
               "Connection: close\r\n\r\nok"),
}

TUNNEL_RESPONSE = (b'HTTP/1.1 200 Connection established\r\n'
                   b'TUNNELNOCOLON\r\n'
                   b'X-Proxy: yes\r\n\r\n')


def read_head(connection):
    data = b''
    try:
        while b'\r\n\r\n' not in data:
            part = connection.recv(8192)
            if not part:
                break
            data += part
    except OSError:
        pass
    return data


def serve_origin(connection):
    connection.settimeout(10)
    request = read_head(connection)
    try:
        path = request.split(b' ')[1].decode('latin-1')
    except IndexError:
        path = '/plain'
    try:
        connection.sendall(ORIGIN_CASES.get(path, ORIGIN_CASES['/plain']).encode('latin-1'))
    except OSError:
        pass
    connection.close()


def pump(source, sink):
    try:
        while True:
            chunk = source.recv(8192)
            if not chunk:
                break
            sink.sendall(chunk)
    except OSError:
        pass
    try:
        sink.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def serve_proxy(connection):
    connection.settimeout(10)
    request = read_head(connection)
    if not request.startswith(b'CONNECT'):
        connection.close()
        return
    try:
        host, port = request.split(b' ')[1].decode('latin-1').rsplit(':', 1)
        upstream = socket.create_connection((host, int(port)), 10)
    except (IndexError, ValueError, OSError):
        connection.close()
        return
    try:
        connection.sendall(TUNNEL_RESPONSE)
    except OSError:
        connection.close()
        upstream.close()
        return
    outbound = threading.Thread(target=pump, args=(connection, upstream))
    outbound.start()
    pump(upstream, connection)
    outbound.join()
    connection.close()
    upstream.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18988)
    parser.add_argument('--proxy', action='store_true')
    options = parser.parse_args()
    handler = serve_proxy if options.proxy else serve_origin
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', options.port))
    listener.listen(64)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=handler, args=(connection,), daemon=True).start()


main()
