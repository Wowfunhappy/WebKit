#!/usr/bin/env python3
"""Exercise curl's incremental HTTP/1 framing grammar over raw loopback sockets.
Usage: curl-http1-framing.py /path/to/curl /path/to/evidence-directory
"""
import hashlib, json, pathlib, socket, subprocess, sys, threading
curl, directory = sys.argv[1:]
root = pathlib.Path(directory)
root.mkdir(parents=True, exist_ok=True)
cases = []
for status, valid in ((b'200 OK', True), (b'200', True), (b'200 ', True), (b'2000 Odd', False), (b'20 Odd', False)):
    cases.append(('status-' + status.decode().replace(' ', '_'), valid, b'HTTP/1.1 ' + status + b'\r\nContent-Length: 5\r\nConnection: close\r\n\r\nHELLO'))
for name, size, valid in (
    ('plain', b'5', True), ('token', b'5;foo=bar', True),
    ('bare-extension', b'5;foo', True), ('two-extensions', b'5;foo=bar;baz=qux', True),
    ('quoted-semicolon', b'5;foo="a;b"', True), ('quoted-escape', b'5;foo="a\\"b\\\\c"', True),
    ('empty-quoted', b'5;foo=""', True), ('whitespace', b'5\t ; foo \t= \t"x" ; last', True),
    ('bad-size-suffix', b'5Z', False), ('bad-size-spaced-suffix', b'5 Z', False),
    ('empty-name', b'5;', False), ('empty-token-value', b'5;foo=', False),
    ('missing-name', b'5;=bar', False), ('unclosed-quoted', b'5;foo="bar', False),
    ('control-quoted', b'5;foo="a\x01b"', False), ('bad-after-quoted', b'5;foo="a"b', False),
):
    cases.append(('chunk-' + name, valid, b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n' + size + b'\r\nHELLO\r\n0\r\n\r\n'))
results = []
for name, valid, payload in cases:
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    wire = {}
    def serve():
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(10)
            request = b''
            while b'\r\n\r\n' not in request:
                part = connection.recv(4096)
                if not part:
                    return
                request += part
            wire['request_hex'] = request.hex()
            # Individual writes exercise boundaries without timed sleeps.
            try:
                for byte in payload:
                    connection.sendall(bytes([byte]))
                connection.shutdown(socket.SHUT_WR)
                wire['sent_all'] = True
            except (BrokenPipeError, ConnectionResetError):
                wire['sent_all'] = False
    worker = threading.Thread(target=serve)
    worker.start()
    process = subprocess.run([curl, '--noproxy', '*', '--silent', '--show-error', '--max-time', '10', 'http://127.0.0.1:' + str(port) + '/'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    worker.join()
    listener.close()
    passed = (process.returncode == 0 and process.stdout == b'HELLO') if valid else process.returncode != 0
    result = dict(name=name, valid=valid, rc=process.returncode, body_hex=process.stdout.hex(), error=process.stderr.decode(errors='replace'), passed=passed, payload_hex=payload.hex(), sha256=hashlib.sha256(payload).hexdigest(), **wire)
    results.append(result)
    print(name, 'rc=' + str(process.returncode), 'PASS' if passed else 'FAIL', flush=True)
(root / 'results.json').write_text(json.dumps(results, indent=2))
failures = sum(not r['passed'] for r in results)
print('curl HTTP/1 framing: checks=' + str(len(results)) + ' FAILED=' + str(failures))
sys.exit(bool(failures))
