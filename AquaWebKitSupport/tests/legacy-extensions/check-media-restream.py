#!/usr/bin/env python3
"""Check a live extension handoff URL and save its media for decoder tests."""
import argparse
import json
import http.client
import pathlib
import re
import socket
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('url')
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path(__file__).parent / 'build' / 'restream')
args = parser.parse_args()
url = urllib.parse.urlsplit(args.url)
assert url.scheme == 'http' and url.hostname == '127.0.0.1'
connection = http.client.HTTPConnection(url.hostname, url.port, timeout=60)

def request(method, path, headers=None):
    connection.request(method, path, headers=headers or {})
    response = connection.getresponse()
    data = response.read()
    return response.status, dict(response.getheaders()), data

status, headers, playlist = request('GET', url.path)
assert status == 200 and playlist.startswith(b'#EXTM3U\n')
status, head, body = request('HEAD', url.path)
assert status == 200 and not body and int(head['Content-Length']) > 0 and head['Content-Type'] == headers['Content-Type']
assert request('GET', '/00000000000000000000000000000000/index.m3u8')[0] == 404
status, headers, body = request('POST', url.path)
assert status == 405 and headers['Allow'] == 'GET, HEAD'
args.output.mkdir(parents=True, exist_ok=True)
def local_playlist(data):
    text = data.decode()
    text = re.sub(r'URI="([^"\n]+)"', lambda m: 'URI="' + pathlib.PurePosixPath(m[1]).name + '"', text)
    return '\n'.join(pathlib.PurePosixPath(line).name if line and not line.startswith('#') else line for line in text.split('\n')).encode()

resources = {}
master_url = args.url
(args.output / 'index.m3u8').write_bytes(local_playlist(playlist))
if b'#EXT-X-STREAM-INF:' in playlist:
    master = playlist.decode()
    media = next(line for line in master.splitlines() if line and not line.startswith('#'))
    args.url = urllib.parse.urljoin(args.url, media)
    status, headers, playlist = request('GET', urllib.parse.urlsplit(args.url).path)
    assert status == 200 and playlist.startswith(b'#EXTM3U\n')
    (args.output / 'media.m3u8').write_bytes(local_playlist(playlist))
    for rendition in re.findall(r'^#EXT-X-MEDIA:.*URI="([^"]+)"', master, re.M):
        rendition_url = urllib.parse.urljoin(master_url, rendition)
        path = urllib.parse.urlsplit(rendition_url).path
        status, headers, subtitles = request('GET', path)
        assert status == 200 and subtitles.startswith(b'#EXTM3U\n')
        (args.output / pathlib.PurePosixPath(rendition).name).write_bytes(local_playlist(subtitles))
        for name in subtitles.decode().splitlines():
            if not name or name.startswith('#'):
                continue
            resource_url = urllib.parse.urljoin(rendition_url, name)
            path = urllib.parse.urlsplit(resource_url).path
            status, headers, captions = request('GET', path)
            assert status == 200 and captions.startswith(b'WEBVTT\n') and headers['Content-Type'].startswith('text/vtt')
            assert request('HEAD', path)[1]['Content-Length'] == str(len(captions))
            assert request('GET', path, {'Range': 'bytes=0-5'})[2] == b'WEBVTT'
            (args.output / pathlib.PurePosixPath(name).name).write_bytes(captions)
            resources[pathlib.PurePosixPath(name).name] = resource_url

segments = []
discontinuities = set()
for line in playlist.decode().splitlines():
    if line == '#EXT-X-DISCONTINUITY':
        discontinuities.add(len(segments))
    elif line and not line.startswith('#'):
        segments.append(line)
assert segments
previous = {}
for index, name in enumerate(segments):
    if index in discontinuities:
        previous.clear()
    path = urllib.parse.urlsplit(urllib.parse.urljoin(args.url, name)).path
    status, headers, data = request('GET', path)
    assert status == 200 and data and len(data) % 188 == 0, (name, status)
    assert request('HEAD', path)[1]['Content-Length'] == str(len(data))
    for begin, end in [(0, 187), (len(data) - 188, len(data) - 1)]:
        status, headers, part = request('GET', path, {'Range': 'bytes=%d-%d' % (begin, end)})
        assert status == 206 and part == data[begin:end + 1]
        assert headers['Content-Range'] == 'bytes %d-%d/%d' % (begin, end, len(data))
    status, headers, part = request('GET', path, {'Range': 'bytes=-188'})
    assert status == 206 and part == data[-188:]
    assert request('GET', path, {'Range': 'bytes=%d-' % len(data)})[0] == 416
    assert request('GET', path, {'Range': 'bytes=0-1,3-4'})[0] == 416
    for offset in range(0, len(data), 188):
        packet = data[offset:offset + 188]
        assert packet[0] == 0x47
        pid = ((packet[1] & 31) << 8) | packet[2]
        if pid == 8191:
            continue
        counter = packet[3] & 15
        if pid in previous:
            assert counter == (previous[pid] + bool(packet[3] & 16)) % 16, (name, pid, offset)
        previous[pid] = counter
    filename = pathlib.PurePosixPath(name).name
    assert re.fullmatch(r'\d+\.ts', filename)
    (args.output / filename).write_bytes(data)
    resources[filename] = urllib.parse.urljoin(args.url, name)
    print('%s: %d bytes; HEAD, ranges and transport continuity passed' % (name, len(data)), flush=True)
(args.output / 'resources.json').write_text(json.dumps(resources))
connection.close()
for headers in ['Host: evil.example\r\n', 'Host: 127.0.0.1:%d\r\nHost: evil.example\r\n' % url.port,
                'Host: 127.0.0.1:%d\r\nTransfer-Encoding: chunked\r\n' % url.port]:
    with socket.create_connection((url.hostname, url.port), timeout=10) as stream:
        stream.sendall(('GET %s HTTP/1.1\r\n%s\r\n' % (url.path, headers)).encode())
        response = stream.recv(4096)
        assert not response, response
print('HTTP protocol checks passed; saved %d segments in %s' % (len(segments), args.output))
