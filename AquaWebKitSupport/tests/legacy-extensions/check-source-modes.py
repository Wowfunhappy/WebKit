#!/usr/bin/env python3
"""Exercise direct-only and capture-only delivery, including audio elements."""
import json
import argparse
import subprocess
import time
import urllib.parse

window_id = None


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40).decode().strip()


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of ' + ('window id ' + window_id if window_id else 'front window'))


def wait(check, seconds=90):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def windows():
    return {int(item) for item in osa('tell application "QuickTime Player" to get id of every window').split(',') if item.strip()}


cases = [
    ('direct-mse', dict(source='mse.mp4', sourceMode='direct'), 'no-direct-source'),
    ('direct-timeout', dict(source='mse.mp4', airplay='route-timeout', sourceMode='direct'), 'no-direct-source'),
    ('direct-paused-timeout', dict(source='mse.mp4', airplay='route-timeout', sourceMode='direct'), 'no-direct-source'),
    ('direct-unchanged', dict(source='mse.mp4', airplay='route-timeout', disconnect='none', sourceMode='direct'), 'no-direct-source'),
    ('direct-caption', dict(source='plain.mp4', subtitles='external', sourceMode='direct'), 'no-direct-source'),
    ('direct-route', dict(source='mse.mp4', airplay='route', sourceMode='direct'), 'url'),
    ('capture-route', dict(source='mse.mp4', airplay='route', sourceMode='capture'), 'restream'),
    ('pending-mismatch', dict(source='mse.mp4', sourceMode='capture', coalesceMode='direct'), 'restream'),
    ('capture-audio', dict(source='flac.webm', element='audio', sourceMode='capture'), 'restream'),
    ('direct-audio', dict(source='plain.mp4', element='audio', sourceMode='direct'), 'url'),
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', nargs='*')
selected = parser.parse_args().cases
if any(name not in [case[0] for case in cases] for name in selected):
    parser.error('Unknown case')
baseline = windows()
print('BASELINE_WINDOWS', sorted(baseline), flush=True)
for name, parameters, expected in cases:
    if selected and name not in selected:
        continue
    parameters['title'] = name + '-' + str(time.time_ns())
    url = 'http://127.0.0.1:8843/quicktime.html?' + urllib.parse.urlencode(parameters)
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    wait(lambda: osa('tell application "Safari" to get URL of current tab of front window') == url)
    window_id = osa('tell application "Safari" to get id of front window')
    wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')
    if name == 'direct-audio':
        js('video.src="/quicktime-media/audio-only.mp4";video.load()')
        wait(lambda: js('video.readyState>=2') == 'true')
    if parameters.get('element') == 'audio':
        assert js('video.localName') == 'audio'
        assert float(js('video.videoTracks.length')) == 0
    js('window.routeEvents=0;video.addEventListener("webkitcurrentplaybacktargetiswirelesschanged",()=>++routeEvents);video.currentTime=2')
    if name != 'direct-paused-timeout':
        js('video.play()')
    wait(lambda: js('!video.seeking && video.currentTime>=2') == 'true')
    js('document.querySelector("#open-media-player").click()')
    text = wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')))
    result = json.loads(text)
    print(name, result, flush=True)
    assert result.get('method', result.get('error')) == ('application-busy' if name == 'pending-mismatch' else expected), result
    if expected == 'no-direct-source':
        assert windows() == baseline, ('Receiver windows changed during direct-only failure', sorted(baseline), sorted(windows()))
        assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'false'
        wait(lambda: js('video.readyState>=2 && video.paused===' + ('true' if name == 'direct-paused-timeout' else 'false')) == 'true')
        if name.endswith('timeout'):
            wait(lambda: float(js('routeEvents')) == 2)
            wait(lambda: js('video.currentSrc.startsWith("blob:")') == 'true')
        if name == 'direct-unchanged':
            start = float(js('video.currentTime'))
            wait(lambda: float(js('video.currentTime')) > start + 1, seconds=10)
            wait(lambda: float(js('video.currentTime')) > start + 17, seconds=25)
            assert js('video.paused') == 'false'
        osa('tell application "Safari" to close current tab of window id ' + window_id)
        continue
    if parameters['sourceMode'] == 'capture':
        assert float(js('routeEvents')) == 0, 'Capture-only request negotiated a remote route'
    owned = wait(lambda: windows() - baseline)
    assert len(owned) == 1, owned
    movie = 'document of window id ' + str(next(iter(owned)))

    def qt(command):
        return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))

    wait(lambda: float(qt('get current time of MOVIE')) > 0)
    if name in ['capture-route', 'direct-route']:
        for mode in ['direct' if expected == 'restream' else 'capture', 'auto', parameters['sourceMode']]:
            js('var u=new URL(location.href);u.searchParams.set("sourceMode",' + json.dumps(mode) + ');history.replaceState(null,"",u);document.querySelector("#open-media-player").click()')
            text = wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')))
            repeated = json.loads(text)
            wanted = 'no-direct-source' if mode == 'direct' and expected == 'restream' else 'application-busy' if mode == 'capture' and expected == 'url' else expected
            assert repeated.get('method', repeated.get('error')) == wanted, repeated
            assert windows() == baseline | owned, 'Repeated request changed receivers'
            print('reactivation', name, mode, repeated, flush=True)
    if expected == 'url':
        qt('set current time of MOVIE to 20')
        qt('play MOVIE')
        wait(lambda: 20 <= float(qt('get current time of MOVIE')) < 30)
    osa('tell application "Safari" to close current tab of window id ' + window_id)
    start = float(qt('get current time of MOVIE'))
    wait(lambda: float(qt('get current time of MOVIE')) > start + 3)
    qt('close MOVIE saving no')
    wait(lambda: windows() == baseline)
print('PASS source modes, restoration, audio, seeking and tab closure', flush=True)
