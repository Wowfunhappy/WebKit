#!/usr/bin/env python3
"""Verify delayed and route-change-only remote source selection."""
import argparse
import json
import subprocess
import time
import urllib.parse


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def windows():
    return {int(value) for value in osa('tell application "QuickTime Player" to get id of every window').split(',') if value.strip()}


cases = [
    ('normal', {}, 'url'),
    ('change-listener-only', {'routeChangeOnly': '1'}, 'url'),
    ('slow-route', {'routeDelay': '7000'}, 'url'),
    ('source-reload', {'routeReload': '1', 'disconnect': 'none'}, 'url'),
    ('source-reload-sync-disconnect', {'routeReload': '1', 'disconnect': 'sync'}, 'url'),
    ('source-reload-async-disconnect', {'routeReload': '1', 'routeTimeout': '3'}, 'url'),
    ('source-reload-http-during-recovery', {'routeReload': '1', 'routeRecoveryHTTP': '1', 'disconnect': 'none'}, 'url'),
    ('source-reload-twice', {'routeReload': '2', 'routeStreamReload': '1', 'disconnect': 'none'}, 'url'),
    ('source-reload-recovery-generation', {'routeReload': '1', 'routeStreamReload': '1', 'routeRecoveryReload': '1', 'disconnect': 'none'}, 'url'),
    ('source-reload-dispatch-generation', {'routeReload': '1', 'routeStreamReload': '1', 'routeDispatchReload': '1', 'disconnect': 'none'}, 'url'),
    ('source-reload-deadline', {'routeReload': '2', 'routeStreamReload': '1', 'routeReloadDelay': '1500', 'routeTimeout': '1', 'disconnect': 'none'}, 'no-source'),
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', nargs='*')
selected = parser.parse_args().cases
if any(name not in [case[0] for case in cases] for name in selected):
    parser.error('Unknown case')

for name, extra, expected in cases:
    if selected and name not in selected:
        continue
    baseline = windows()
    query = dict(source='mse.mp4', airplay='route', test=str(time.time_ns()), **extra)
    url = 'http://127.0.0.1:8843/quicktime.html?' + urllib.parse.urlencode(query)
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    wait(lambda: osa('tell application "Safari" to get URL of current tab of front window') == url)
    window_id = osa('tell application "Safari" to get id of front window')

    def js(script):
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window_id)

    wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2&&document.querySelector("#open-media-player"))') == 'true')
    js('video.play()')
    wait(lambda: float(js('video.currentTime')) > .5)
    started = time.monotonic()
    js('document.querySelector("#open-media-player").click()')
    result = json.loads(wait(lambda: (lambda text: text if text.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    print(name, round(time.monotonic() - started, 3), result, flush=True)
    print('state', js('JSON.stringify({src:video.currentSrc,wireless:video.webkitCurrentPlaybackTargetIsWireless,ready:video.readyState,error:video.error?.message})'), flush=True)
    assert result.get('method', result.get('error')) == expected, (name, result)
    if expected == 'url' and extra.get('routeReload'):
        assert int(float(js('window.routeReloadCount'))) == int(extra['routeReload']), (name, js('window.routeReloadCount'))
        if not extra.get('routeRecoveryHTTP'):
            assert int(float(js('window.routeLocalAdvances'))) >= 1, (name, js('window.routeLocalAdvances'))
    if expected == 'no-source':
        assert windows() == baseline, (name, baseline, windows())
        osa('tell application "Safari" to close current tab of window id ' + window_id)
        continue
    owned = wait(lambda: windows() - baseline)
    assert len(owned) == 1, owned
    movie = 'document of window id ' + str(next(iter(owned)))

    def qt(command):
        return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))

    if extra.get('routeRecoveryHTTP'):
        assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'true'
        qt('set current time of MOVIE to 30')
        wait(lambda: 29 < float(js('video.currentTime')) < 40)
        js('video.currentTime=10')
        wait(lambda: 9 < float(qt('get current time of MOVIE')) < 20)
        js('video.pause()')
        wait(lambda: qt('get playing of MOVIE') == 'false')
        js('video.play()')
        wait(lambda: qt('get playing of MOVIE') == 'true')

    osa('tell application "Safari" to close current tab of window id ' + window_id)
    before = float(qt('get current time of MOVIE'))
    wait(lambda: float(qt('get current time of MOVIE')) > before + 2, 15)
    qt('close MOVIE saving no')
    wait(lambda: windows() == baseline)
print('PASS remote route discovery and tab closure', flush=True)
