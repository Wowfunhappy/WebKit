#!/usr/bin/env python3
"""Compare WK1's original handshake buffer with a loopback server's raw bytes."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socketserver
import struct
import subprocess
import threading
import uuid

HERE = Path(__file__).resolve().parent


def main():
    os.environ.update(LC_ALL='en_US.UTF-8', LC_CTYPE='en_US.UTF-8')
    spec = importlib.util.spec_from_file_location('probe', HERE / 'check-extension-cookies.py')
    p = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(p)
    received = []

    class Handshake(socketserver.StreamRequestHandler):
        def handle(self):
            raw = self.rfile.readline()
            while not raw.endswith(b'\r\n\r\n'):
                line = self.rfile.readline()
                if not line:
                    return
                raw += line
            received.append(raw)
            headers = dict(line.split(b':', 1) for line in raw.split(b'\r\n')[1:-2])
            key = next(value.strip() for name, value in headers.items() if name.lower() == b'sec-websocket-key')
            accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            self.wfile.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
                             + accept + b'\r\nSec-WebSocket-Protocol: cookie-protocol\r\n\r\n')
            body = b'{"rawHandshakeReceived":true}'
            self.wfile.write(bytes([0x81, len(body)]) + body + bytes([0x88, 2]) + struct.pack('!H', 1000))
            self.wfile.flush()
            self.connection.settimeout(20)
            close = self.rfile.read(2)
            if len(close) == 2 and close[0] == 0x88 and close[1] & 0x80 and (close[1] & 0x7f) <= 125:
                self.rfile.read(4 + (close[1] & 0x7f))

    server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handshake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    windows, rows = [], []
    trace = None
    log_path = p.WORK / 'pass-through-native.log'
    log = log_path.open('wb')
    try:
        observer = p.window(p.roots()['all']); windows.append(observer)
        requester = p.window(p.roots()['some']); windows.append(requester)
        safari = next(line.split()[0] for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
                      if line.strip().endswith('/Safari.app/Contents/MacOS/Safari'))
        trace = subprocess.Popen(['sudo', '-n', 'dtrace', '-Z', '-q', '-p', safari, '-s', str(HERE / 'websocket-handshake-bytes.d')],
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        p.wait(lambda: b'READY ' in log_path.read_bytes() or trace.poll() is not None, 'handshake trace startup')
        assert trace.poll() is None, log_path.read_text()
        for observed in [False, True]:
            case_id = uuid.uuid4().hex
            if observed:
                p.js(observer, '''window.byteEvents=[]; window.byteListener=d=>{byteEvents.push({url:d.url,type:d.type}); return {};};
browser.webRequest.onBeforeRequest.addListener(byteListener,{urls:['ws://localhost/*'],types:['websocket']},['blocking']); 'registered' ''')
            url = 'ws://localhost:' + str(server.server_address[1]) + '/ws?id=' + case_id
            result = p.exercise(requester, 'browser.runtime.sendMessage(' + json.dumps(dict(cookieTest='global-websocket', options=dict(url=url, protocol='cookie-protocol'))) + ')')
            p.wait(lambda: case_id.encode() in log_path.read_bytes(), 'original handshake bytes')
            records = re.findall(rb'HANDSHAKE (\d+)\n(.*?)\nEND_HANDSHAKE\n', log_path.read_bytes(), re.S)
            sent = [(int(length), raw) for length, raw in records if case_id.encode() in raw]
            wire = [raw for raw in received if case_id.encode() in raw]
            events = json.loads(p.js(observer, 'JSON.stringify(byteEvents)')) if observed else []
            row = dict(observed=observed, result=result, events=events, writes=len(sent), requests=len(wire),
                       byteLength=sent[0][0] if sent else None,
                       originalBase64=base64.b64encode(sent[0][1]).decode() if sent else None,
                       wireBase64=base64.b64encode(wire[0]).decode() if wire else None,
                       identical=len(sent) == len(wire) == 1 and sent[0][0] == len(sent[0][1]) and sent[0][1] == wire[0])
            rows.append(row)
            assert row['identical'] and result.get('opened') and result.get('code') == 1000, row
            assert events == [dict(url=url, type='websocket')] if observed else not events, events
    finally:
        if trace and trace.poll() is None:
            subprocess.run(['sudo', '-n', '/bin/kill', '-INT', '-' + str(trace.pid)], check=True)
            trace.wait(timeout=20)
        log.close()
        if windows:
            p.js(windows[0], 'if(window.byteListener)browser.webRequest.onBeforeRequest.removeListener(byteListener); "removed"')
        for number in reversed(windows):
            p.close(number)
        server.shutdown(); server.server_close()
        text = log_path.read_text()
        result = dict(rows=rows, interceptionCalls=text.count('INTERCEPT '), probeErrors='error on enabled probe' in text)
        (p.WORK / 'pass-through.json').write_text(json.dumps(result, indent=2))
    assert not result['probeErrors'] and not result['interceptionCalls'], result
    print('WK1 handshake bytes: 2 exact matches; onBeforeRequest-only listener: 1 event; header interception calls: 0')


if __name__ == '__main__':
    main()
