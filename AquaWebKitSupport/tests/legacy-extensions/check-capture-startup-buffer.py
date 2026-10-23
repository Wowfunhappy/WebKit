#!/usr/bin/env python3
"""Verify that late subtitle loading honors the live HLS startup buffer."""
import importlib.util
import json
import pathlib
import re
import subprocess
import threading
import time
import urllib.parse
import urllib.request

rig = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fixtures', rig / 'server.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
control = rig / 'build/media-receiver-control.json'


class Handler(fixtures.Handler):
    def do_GET(self):
        if self.path == '/late-captions.vtt':
            time.sleep(8)
            return self.reply('WEBVTT\n\n00:00.000 --> 00:30.000\nLate captions\n', 'text/vtt')
        return super().do_GET()


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.1)
    raise AssertionError('Timed out')


def read(url):
    return urllib.request.urlopen(url, timeout=15).read().decode()


server = fixtures.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
window = None
try:
    control.write_text('{}')
    url = f'http://127.0.0.1:{server.server_port}/quicktime.html?source=flac.webm&mode=live&element=audio&sourceMode=capture&adapter=fixture&tracks=all'
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    window = osa('tell application "Safari" to get id of front window')

    def js(script):
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)

    wait(lambda: js('Boolean(video.readyState>=2&&!video.paused&&document.querySelector("#open-media-player"))') == 'true')
    js('window.lateTrack=document.createElement("track");lateTrack.kind="subtitles";lateTrack.src="/late-captions.vtt";lateTrack.srclang="en";lateTrack.onload=()=>window.captionLoaded=performance.now();video.appendChild(lateTrack);lateTrack.track.mode="showing";true')
    wait(lambda: js('lateTrack.readyState===1') == 'true')
    js('window.captureStart=performance.now();document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click()')
    started = time.monotonic()
    reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    assert reply.get('method') == 'restream', reply
    master = read(reply['url'])
    assert '#EXT-X-MEDIA:TYPE=SUBTITLES' in master, master
    media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#')))
    playlist = read(media_url)
    target = int(re.search(r'^#EXT-X-TARGETDURATION:(\d+)$', playlist, re.M).group(1))
    duration = sum(float(value) for value in re.findall(r'^#EXTINF:([^,]+),', playlist, re.M))
    print('OPEN', round(time.monotonic() - started, 3), 'buffer', duration, 'target', target, 'caption_loaded_ms', js('captionLoaded-captureStart'), flush=True)
    assert '#EXT-X-ENDLIST' not in playlist
    assert duration >= 3 * target, ('Insufficient live startup buffer after subtitle load', duration, target)
    assert js('lateTrack.readyState===2') == 'true'
    print('PASS late subtitle loading preserves three target durations at startup', flush=True)
finally:
    control.write_text('{"closed":true}')
    if window:
        osa('tell application "Safari" to close current tab of window id ' + window)
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    control.write_text('{}')
    server.shutdown()
    server.server_close()
