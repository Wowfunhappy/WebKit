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
parameters = {'source': args.source, 'airplay': args.route, 'title': title, 'synchronize': 'true', 'disconnect': 'none' if args.return_inline == 'controlled' else args.return_inline or args.fallback_disconnect}
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
    # A start the receiver's error dialog blocks does not block a later one for the same URL.
    def attempt():
        js('document.querySelector("#media-player-result").textContent="pending";video.play();document.querySelector("#open-media-player").click()')
        return json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    js('video.src="/quicktime-media/plain.mp4";video.load();video.play()')
    wait(lambda: js('!video.paused && video.readyState>=2') == 'true')
    blocked = attempt()
    assert blocked.get('error') == 'application-start-uncertain', blocked
    def clear_dialogs():
        return osa('tell application "System Events" to tell process "QuickTime Player"\nset found to 0\nrepeat with w in windows\nif subrole of w is "AXDialog" then\nclick button 1 of w\nset found to found + 1\nend if\nend repeat\nreturn found\nend tell') == '0'
    wait(clear_dialogs, 20)
    time.sleep(1)
    wait(lambda: js('video.readyState>=2') == 'true')
    retried = attempt()
    print('BLOCKED', blocked, 'RETRIED', retried, flush=True)
    if retried.get('error') == 'application-busy':
        # The receiver opened the queued request once its dialog closed; that movie is not ours.
        for identifier in windows() - baseline:
            osa('tell application "QuickTime Player" to close document of window id ' + str(identifier) + ' saving no')
        retried = attempt()
        print('RETRIED AFTER CLOSE', retried, flush=True)
    assert retried.get('method') == 'url', retried
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
    wait(lambda: playing() == (not args.paused))
    if not args.paused:
        initial = float(qt('get current time of MOVIE'))
        wait(lambda: float(qt('get current time of MOVIE')) > initial + 1)
    assert abs(float(qt('get rate of MOVIE')) - (0 if args.paused else 1.25)) < .05
    # Browser and receiver timelines are independent.
    before = float(qt('get current time of MOVIE'))
    js('video.currentTime=(' + str(before) + '+20)%50')
    time.sleep(2)
    assert 0 <= float(qt('get current time of MOVIE')) - before < 8
    assert not args.paused == playing()
    browser = float(js('video.currentTime'))
    qt('set current time of MOVIE to 15')
    time.sleep(1)
    assert abs(float(js('video.currentTime')) - browser) < 1
    qt('play MOVIE')
    time.sleep(1)
    assert js('video.paused') == 'true'
    before = float(qt('get current time of MOVIE'))
    js('video.load()')
    wait(lambda: float(qt('get current time of MOVIE')) > before + 3)
    assert windows() - baseline == owned
    assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'true'
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
            # The page's replacement source is a different resource, so the helper leaves it to the page.
            assert js('video.paused') == 'true'
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
    print('PASS original URL, initial state, independent timelines, same-source reload, changed-source detachment and tab closure', flush=True)
    raise SystemExit(0)
for identifier in windows() - baseline:
    osa('tell application "QuickTime Player" to close document of window id ' + str(identifier) + ' saving no')
osa('tell application "Safari" to close current tab of front window')
print('PASS uncertain launch remains paused' if args.route == 'route-rejected' else 'PASS local fallback', flush=True)
