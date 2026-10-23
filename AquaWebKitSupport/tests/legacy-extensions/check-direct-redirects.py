#!/usr/bin/env python3
"""Verify original-URL handoffs through relative and cross-port HTTP redirects."""
import http.server
import json
import subprocess
import threading
import time


class Redirects(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.rsplit('/', 1)[-1]
        if self.path.startswith('/start/'):
            destination, status = '/hop/' + name, 302
        else:
            destination, status = 'http://127.0.0.1:8843/quicktime-media/' + name, 307
        self.send_response(status)
        self.send_header('Location', destination)
        self.send_header('Content-Length', '0')
        self.end_headers()

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def windows():
    return {int(value) for value in osa('tell application "QuickTime Player" to get id of every window').split(',') if value.strip()}


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Redirects) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for name in ('index.m3u8', 'plain.mp4', 'audio-only.mp4'):
            baseline = windows()
            source = 'http://127.0.0.1:' + str(server.server_port) + '/start/' + name
            osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4&sourceMode=auto"}')
            window = osa('tell application "Safari" to get id of front window')

            def js(script):
                return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)

            wait(lambda: js('Boolean(document.querySelector("#open-media-player")&&video.readyState>=2)') == 'true')
            js('video.src=' + json.dumps(source) + ';video.play()')
            wait(lambda: js('video.readyState>=2 && !video.paused') == 'true')
            assert js('video.currentSrc') == source
            js('document.querySelector("#open-media-player").click()')
            reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
            print(name, reply, flush=True)
            assert reply.get('method') == 'url' and reply.get('url') == source, reply
            owned = wait(lambda: windows() - baseline)
            assert len(owned) == 1, owned
            movie = 'document of window id ' + str(next(iter(owned)))

            def qt(command):
                return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))

            wait(lambda: float(qt('get duration of MOVIE')) >= 55)
            qt('set current time of MOVIE to 20')
            qt('play MOVIE')
            wait(lambda: float(qt('get current time of MOVIE')) > 21)
            osa('tell application "Safari" to close current tab of window id ' + window)
            before = float(qt('get current time of MOVIE'))
            wait(lambda: float(qt('get current time of MOVIE')) > before + 3)
            qt('close MOVIE saving no')
            wait(lambda: windows() == baseline)
            print('PASS redirects, direct URL, seeking and tab closure', name, flush=True)
    finally:
        server.shutdown()
        thread.join()
