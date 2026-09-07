#!/usr/bin/env python3
"""Safari acceptance fixtures. Binds only loopback; never changes proxy or trust settings."""
import argparse
import base64
import hashlib
import http.server
import json
import pathlib
import socketserver
import ssl
import struct
import threading
import urllib.parse
import zlib

PAGE = b'''<!doctype html><meta charset="utf-8"><title>Cocoa curl browser acceptance</title>
<h1>Cocoa curl browser acceptance</h1><pre id="out"></pre>
<a href="/download">Download 64 MiB, then stop and resume in Safari</a>
<script>
window.R={results:[],done:false,ua:navigator.userAgent};
function record(name,pass,detail){R.results.push({name:name,pass:!!pass,detail:detail});out.textContent=JSON.stringify(R,null,2)}
async function run(){
 var id=new URLSearchParams(location.search).get('run')||Date.now().toString();
 try {
  var first=await (await fetch('/cache?run='+id)).text();
  var second=await (await fetch('/cache?run='+id)).text();
  record('HTTP cache',first===second,{first:first,second:second});
  var form=new FormData();form.append('text','multipart field');form.append('file',new Blob([new Uint8Array([0,1,127,128,255])]),'binary.dat');
  var upload=await (await fetch('/upload',{method:'POST',body:form})).json();
  record('FormData file and text',upload.binary&&upload.text,upload);
  await new Promise(function(resolve){
   var img=new Image();document.body.appendChild(img);
   var observer=new PerformanceObserver(function(list){if(list.getEntries().some(function(x){return x.name===img.src})){observer.disconnect();record('Multipart image replacement',img.naturalWidth===2,{width:img.naturalWidth,height:img.naturalHeight});resolve();}});
   observer.observe({entryTypes:['resource']});
   img.onload=function(){if(img.naturalWidth===1)fetch('/multipart/next?run='+id);};
   img.onerror=function(){observer.disconnect();record('Multipart image replacement',false,'image error');resolve();};
   img.src='/multipart?run='+id;
  });
  await new Promise(function(resolve){
   var socket=new WebSocket((location.protocol==='https:'?'wss:':'ws:')+'//'+location.host+'/socket','curl-fixture');
   socket.binaryType='arraybuffer';var count=0;
   socket.onopen=function(){record('WebSocket protocol',socket.protocol==='curl-fixture',socket.protocol);socket.send('Unicode: \\u03bb');socket.send(new Uint8Array([0,128,255]));};
   socket.onmessage=function(e){++count;if(typeof e.data==='string')record('WebSocket text',e.data==='Unicode: \\u03bb',e.data);else record('WebSocket binary',String(new Uint8Array(e.data))==='0,128,255',String(new Uint8Array(e.data)));if(count===2)socket.close(1000,'complete');};
   socket.onerror=function(){record('WebSocket error',false,'error');};
   socket.onclose=function(e){record('WebSocket close',count===2&&e.code===1000&&e.wasClean,{count:count,code:e.code,clean:e.wasClean});resolve();};
  });
  var cookie=await (await fetch('/socket-cookie')).json();
  record('WebSocket per-field cookie',cookie.one&&!cookie.fabricated,cookie);
 }catch(e){record('Unexpected failure',false,String(e));}
 R.done=true;out.textContent=JSON.stringify(R,null,2);
 await fetch('/complete?run='+id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(R)});
}
run();
</script>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18986)
    parser.add_argument('--directory', type=pathlib.Path, required=True)
    parser.add_argument('--certificate', type=pathlib.Path)
    parser.add_argument('--key', type=pathlib.Path)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    counts = {}
    replacements = {}

    def png(width):
        def chunk(kind, value):
            return struct.pack('!I', len(value)) + kind + value + struct.pack('!I', zlib.crc32(kind + value))
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, 1, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(b'\0' + b'\0\0\xff' * width)) + chunk(b'IEND', b''))

    def log(name, value):
        with lock, (args.directory / name).open('a') as stream:
            stream.write(json.dumps(value) + '\n')

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def respond(self, body, fields=(), status=200):
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            for name, value in fields:
                self.send_header(name, value)
            self.end_headers()
            self.close_connection = True
            if self.command != 'HEAD':
                self.wfile.write(body)

        def body(self):
            if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                data = bytearray()
                while True:
                    size = int(self.rfile.readline().split(b';', 1)[0], 16)
                    if not size:
                        while self.rfile.readline() != b'\r\n':
                            pass
                        return bytes(data)
                    data += self.rfile.read(size)
                    if self.rfile.read(2) != b'\r\n':
                        raise ValueError('invalid fixture request chunk delimiter')
            return self.rfile.read(int(self.headers.get('Content-Length', 0)))

        def do_POST(self):
            body = self.body()
            path = urllib.parse.urlsplit(self.path).path
            if path == '/complete':
                result = json.loads(body)
                result['path'] = self.path
                log('complete.jsonl', result)
                self.respond(b'OK')
            elif path == '/upload':
                result = {'binary': bytes([0, 1, 127, 128, 255]) in body,
                          'text': b'multipart field' in body,
                          'type': self.headers.get('Content-Type'), 'bytes': len(body)}
                log('uploads.jsonl', result)
                self.respond(json.dumps(result).encode(), [('Content-Type', 'application/json')])
            else:
                self.respond(b'Unknown fixture', status=404)

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            log('requests.jsonl', {'method': self.command, 'path': self.path,
                                  'range': self.headers.get('Range'), 'if-range': self.headers.get('If-Range')})
            if path == '/page':
                self.respond(PAGE, [('Content-Type', 'text/html; charset=utf-8'), ('Cache-Control', 'no-store'),
                                    ('Set-Cookie', 'curl_ws=; Path=/; Max-Age=0'),
                                    ('Set-Cookie', 'curl_ws_fabricated=; Path=/; Max-Age=0')])
            elif path == '/cache':
                with lock:
                    counts[self.path] = counts.get(self.path, 0) + 1
                    count = counts[self.path]
                self.respond(str(count).encode(), [('Cache-Control', 'max-age=3600'), ('ETag', '"cache-v1"')])
            elif path == '/multipart':
                identifier = urllib.parse.urlsplit(self.path).query
                event = threading.Event()
                with lock:
                    replacements[identifier] = event
                self.send_response(200)
                self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=curl-image-fixture')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True
                first, second = png(1), png(2)
                def part_header(data):
                    return b'--curl-image-fixture\r\nContent-Type: image/png\r\nContent-Length: ' + str(len(data)).encode() + b'\r\n\r\n'
                # The next boundary terminates the first image; publish it before waiting for onload.
                self.wfile.write(part_header(first) + first + b'\r\n' + part_header(second))
                if not event.wait(30):
                    log('multipart.jsonl', {'event': 'first image acknowledgement deadline', 'query': identifier})
                self.wfile.write(second + b'\r\n')
                self.wfile.write(b'--curl-image-fixture--\r\n')
                with lock:
                    del replacements[identifier]
            elif path == '/multipart/next':
                identifier = urllib.parse.urlsplit(self.path).query
                with lock:
                    event = replacements.get(identifier)
                if event:
                    event.set()
                self.respond(b'OK' if event else b'No active multipart response', status=200 if event else 404)
            elif path == '/socket':
                self.websocket()
            elif path == '/socket-cookie':
                cookie = self.headers.get('Cookie', '')
                result = {'one': 'curl_ws=one' in cookie, 'fabricated': 'curl_ws_fabricated=' in cookie}
                self.respond(json.dumps(result).encode(), [('Content-Type', 'application/json')])
            elif path == '/persist/set':
                identifier = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['run'][0]
                if not identifier.isalnum():
                    self.respond(b'Invalid fixture identifier', status=400)
                    return
                self.respond(('Persistence fixture set: ' + identifier).encode(), [
                    ('Content-Type', 'text/plain'), ('Cache-Control', 'no-store'),
                    ('Set-Cookie', 'curl_persist=' + identifier + '; Path=/persist; Max-Age=86400; SameSite=Strict; HttpOnly')])
            elif path == '/persist/read':
                cookie = next((x.strip() for x in self.headers.get('Cookie', '').split(';') if x.strip().startswith('curl_persist=')), '')
                log('persistence.jsonl', {'cookie': cookie})
                self.respond(cookie.encode(), [('Content-Type', 'text/plain'), ('Cache-Control', 'no-store')])
            elif path == '/download':
                self.download()
            else:
                self.respond(b'Unknown fixture', status=404)

        do_HEAD = do_GET

        def websocket(self):
            key = self.headers['Sec-WebSocket-Key']
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            for name, value in [('Upgrade', 'websocket'), ('Connection', 'Upgrade'),
                                ('Sec-WebSocket-Accept', accept), ('Sec-WebSocket-Protocol', 'curl-fixture'),
                                ('Set-Cookie', 'curl_ws=one; Path=/; SameSite=Lax; Comment=legal, curl_ws_fabricated=no')]:
                self.send_header(name, value)
            self.end_headers()
            self.close_connection = True
            while True:
                header = self.rfile.read(2)
                if not header:
                    return
                first, second = header
                length = second & 127
                if length == 126:
                    length = struct.unpack('!H', self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack('!Q', self.rfile.read(8))[0]
                if not second & 128:
                    raise ValueError('client WebSocket frame is not masked')
                mask = self.rfile.read(4)
                payload = bytes(x ^ mask[i % 4] for i, x in enumerate(self.rfile.read(length)))
                opcode = first & 15
                log('websocket.jsonl', {'opcode': opcode, 'length': length, 'sha256': hashlib.sha256(payload).hexdigest()})
                if opcode == 9:
                    opcode = 10
                frame = bytes([128 | opcode])
                frame += bytes([length]) if length < 126 else b'\x7e' + struct.pack('!H', length)
                self.wfile.write(frame + payload)
                if opcode == 8:
                    return

        def download(self):
            size = 64 * 1024 * 1024
            value = self.headers.get('Range')
            offset = int(value.removeprefix('bytes=').removesuffix('-')) if value else 0
            if offset >= size:
                self.respond(b'', [('Content-Range', 'bytes */' + str(size))], 416)
                return
            self.send_response(206 if value else 200)
            fields = [('Content-Type', 'application/octet-stream'), ('Content-Disposition', 'attachment; filename=curl-safari-64MiB.bin'),
                      ('Content-Length', str(size - offset)), ('Accept-Ranges', 'bytes'), ('ETag', '"safari-download-v1"'), ('Connection', 'close')]
            if value:
                fields.append(('Content-Range', 'bytes %d-%d/%d' % (offset, size - 1, size)))
            for name, field in fields:
                self.send_header(name, field)
            self.end_headers()
            self.close_connection = True
            if self.command == 'HEAD':
                return
            block = bytes(range(256)) * 256
            if not value:
                self.wfile.write(block * 4)
                # Wait for Safari's Stop to close the live connection. The resumed leg sends all remaining bytes.
                self.rfile.read(1)
                log('downloads.jsonl', {'event': 'stopped', 'bytes': len(block) * 4})
                return
            while offset < size:
                segment = (block + block)[offset % len(block):offset % len(block) + min(len(block), size - offset)]
                self.wfile.write(segment)
                offset += len(segment)
            log('downloads.jsonl', {'event': 'completed', 'bytes': offset})

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = Server(('127.0.0.1', args.port), Handler)
    if args.certificate:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.certificate, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print('Safari acceptance fixture listening on', args.port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
