#!/usr/bin/env python3
"""Verify site-selected external sources and bidirectional receiver controls."""
import argparse
import json
import pathlib
import subprocess
import time
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--route', default='route', choices=['route', 'route-timeout', 'route-rejected'])
parser.add_argument('--route-timeout-seconds', type=float)
parser.add_argument('--paused', action='store_true')
parser.add_argument('--fallback-screenshot', type=pathlib.Path)
parser.add_argument('--source', default='mse.mp4')
parser.add_argument('--fallback-disconnect', choices=['sync', 'async', 'none'], default='async')
parser.add_argument('--return-inline', choices=['sync', 'async', 'none', 'controlled'])
args = parser.parse_args()
rig = pathlib.Path(__file__).resolve().parent

def osa(script):
    return subprocess.check_output(['osascript', '-e', script], stderr=subprocess.DEVNULL).decode().strip()

def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')

def wait(check, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.25)
    raise AssertionError('Timed out')

def windows():
    if subprocess.run(["pgrep", "-x", "QuickTime Player"], stdout=subprocess.DEVNULL).returncode:
        return set()
    text = osa('tell application "QuickTime Player" to get id of every window')
    return {int(value) for value in text.split(',') if value.strip()}

baseline = windows()
title = 'Route title / 100% — captions'
parameters = {'source': args.source, 'airplay': args.route, 'title': title, 'disconnect': 'none' if args.return_inline == 'controlled' else args.return_inline or args.fallback_disconnect}
if args.route_timeout_seconds is not None:
    parameters['routeTimeout'] = args.route_timeout_seconds
url = 'http://127.0.0.1:8843/quicktime.html?' + urllib.parse.urlencode(parameters)
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
wait(lambda: js('Boolean(document.querySelector("video")?.readyState >= 2 && document.querySelector("#open-media-player"))') == 'true')
js('video.currentTime=10;video.playbackRate=1.25;' + ('' if args.paused else 'video.play()'))
wait(lambda: js('!video.seeking && video.currentTime>=10') == 'true')
js('document.querySelector("#open-media-player").click()')
if args.route == 'route-timeout' and args.route_timeout_seconds is not None:
    wait(lambda: js('video.webkitCurrentPlaybackTargetIsWireless') == 'true', 10)
    routed = time.monotonic()
    wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless') == 'true', args.route_timeout_seconds + 5)
    elapsed = time.monotonic() - routed
    assert args.route_timeout_seconds - .5 <= elapsed <= args.route_timeout_seconds + 3, elapsed
    print('ROUTE_TIMEOUT', round(elapsed, 2), flush=True)
if args.fallback_screenshot:
    time.sleep(6)
    wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless') == 'true')
    time.sleep(.5)
    assert js('document.querySelector("#media-player-result").textContent') == 'pending'
    osa('tell application "Safari" to activate')
    subprocess.check_call(['screencapture', '-x', str(args.fallback_screenshot)])
result = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
print(json.dumps(result), flush=True)
if args.route == 'route-rejected':
    assert result.get('error') == 'application-start-uncertain', result
    assert js('video.paused') == 'true'
    assert baseline.issubset(windows()), 'Unrelated receiver closed'
elif args.route != 'route':
    if args.paused:
        assert result.get('error') == 'not-playing', result
        assert js('video.paused') == 'true'
    else:
        assert result.get('method') == 'restream', result
        assert js('!video.paused && !video.webkitCurrentPlaybackTargetIsWireless && video.currentSrc.startsWith("blob:")') == 'true'
    assert float(js('video.currentTime')) >= 9.5
else:
    assert result.get('method') == 'url', result
    assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    owned = wait(lambda: windows() - baseline)
    assert len(owned) == 1, owned
    movie = 'document of window id ' + str(next(iter(owned)))
    def qt(command):
        return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))
    def playing():
        # QuickTime 10.2 reports playing=false at non-unit rates.
        return abs(float(qt('get rate of MOVIE'))) > .001
    assert result['url'] == js('video.currentSrc'), result
    assert qt('get name of MOVIE') == 'plain.mp4'
    assert float(qt('get current time of MOVIE')) >= 9.5
    wait(lambda: playing() == (not args.paused))
    if not args.paused:
        initial = float(qt('get current time of MOVIE'))
        wait(lambda: float(qt('get current time of MOVIE')) > initial + 1)
    assert abs(float(qt('get rate of MOVIE')) - (0 if args.paused else 1.25)) < .05
    js('video.pause();video.play()')
    wait(lambda: playing())
    time.sleep(3)
    assert playing()
    js('video.play();video.pause()')
    wait(lambda: not playing())
    js('video.playbackRate=2;video.play()')
    wait(lambda: abs(float(qt('get rate of MOVIE')) - 2) < .05)
    js('video.playbackRate=1;video.currentTime=30')
    wait(lambda: 29.5 <= float(qt('get current time of MOVIE')) < 40)
    qt('set current time of MOVIE to 15')
    wait(lambda: 14.5 <= float(js('video.currentTime')) < 25)
    qt('pause MOVIE')
    wait(lambda: js('video.paused') == 'true')
    qt('play MOVIE')
    wait(lambda: js('!video.paused') == 'true')
    js('video.currentTime=25;video.pause()')
    wait(lambda: 24.5 <= float(qt('get current time of MOVIE')) < 27 and not playing())
    assert abs(float(js('video.currentTime')) - 25) < 1
    js('video.currentTime=20;video.currentTime=30;video.playbackRate=1.5;video.play()')
    wait(lambda: 29.5 <= float(qt('get current time of MOVIE')) < 40 and abs(float(qt('get rate of MOVIE'))-1.5)<.05)
    js('video.playbackRate=0')
    wait(lambda: abs(float(qt('get rate of MOVIE'))) < .01)
    stationary = float(qt('get current time of MOVIE'))
    time.sleep(3)
    assert abs(float(qt('get current time of MOVIE')) - stationary) < .2
    assert js('video.paused') == 'false'
    js('video.playbackRate=1')
    before = float(qt('get current time of MOVIE'))
    js('video.load()')
    wait(lambda: float(qt('get current time of MOVIE')) > before + 3)
    assert windows() - baseline == owned
    assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    js('video.pause()')
    wait(lambda: not playing())
    js('video.play()')
    wait(lambda: playing())
    if args.return_inline:
        qt('pause MOVIE')
        qt('set current time of MOVIE to 20')
        time.sleep(2)
        qt('close MOVIE saving no')
        wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless') == 'true')
        if args.return_inline == 'controlled':
            js('video.pause();video.currentTime=25;video.playbackRate=1.25;video.play()')
            assert js('!video.paused && video.playbackRate===1.25 && Math.abs(video.currentTime-25)<1') == 'true'
            js('window.replaceHandoffSource()')
            wait(lambda: js('video.currentSrc.startsWith("blob:") && video.readyState>=2 && !video.seeking && !video.paused') == 'true')
            assert 24 <= float(js('video.currentTime')) < 32
            assert float(js('video.playbackRate')) == 1.25
        elif args.return_inline == 'none':
            wait(lambda: js('video.paused') == 'true', 25)
        else:
            wait(lambda: js('video.currentSrc.startsWith("blob:") && video.readyState>=2 && !video.seeking') == 'true')
            assert 19 <= float(js('video.currentTime')) < 30
            assert js('video.paused') == str(args.paused).lower()
        js('video.play()')
        before = float(js('video.currentTime'))
        wait(lambda: float(js('video.currentTime')) > before + 2)
        osa('tell application "Safari" to close current tab of front window')
        print('PASS return to inline: ' + args.return_inline, flush=True)
        raise SystemExit(0)
    before = float(qt('get current time of MOVIE'))
    js('video.src="/quicktime-media/missing.mp4";video.load()')
    wait(lambda: float(qt('get current time of MOVIE')) > before + 3)
    assert windows() - baseline == owned
    assert js('!video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    osa('tell application "Safari" to close current tab of front window')
    before = float(qt('get current time of MOVIE'))
    wait(lambda: float(qt('get current time of MOVIE')) > before + 2)
    qt('close MOVIE saving no')
    print('PASS original URL, initial state, rapid controls, seeking, same-source reload, changed-source detachment and tab closure', flush=True)
    raise SystemExit(0)
for identifier in windows() - baseline:
    osa('tell application "QuickTime Player" to close document of window id ' + str(identifier) + ' saving no')
osa('tell application "Safari" to close current tab of front window')
print('PASS uncertain launch remains paused' if args.route == 'route-rejected' else 'PASS local fallback', flush=True)
