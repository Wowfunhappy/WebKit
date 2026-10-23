#!/usr/bin/env python3
"""Exercise scoped media handoff lifetime and cleanup in Safari and QuickTime."""
import argparse
import json
import subprocess
import time
import urllib.parse


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40).decode().strip()


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


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cases', nargs='*', default=['throw', 'reject', 'stale', 'delayed', 'nested', 'unscoped', 'timeout'])
cases = parser.parse_args().cases
baseline = windows()
for case in cases:
    assert case in ['throw', 'reject', 'stale', 'delayed', 'nested', 'unscoped', 'timeout'], case
    url = 'http://127.0.0.1:8843/quicktime.html?' + urllib.parse.urlencode(dict(source='plain.mp4', sourceMode='direct', handoffScope=case))
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    window = osa('tell application "Safari" to get id of front window')

    def js(script):
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)

    def close():
        osa('tell application "Safari" to close current tab of window id ' + window)

    wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')
    js('document.querySelector("#open-media-player").click()')
    if case in ['throw', 'reject', 'stale', 'timeout']:
        text = wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')), seconds=330 if case == 'timeout' else 30)
        result = json.loads(text)
        expected = 'handoff-timeout' if case == 'timeout' else 'no-source' if case == 'stale' else 'scope-test-error'
        assert result == dict(error=expected), result
        assert js('document.querySelector("#media-player-result").dataset.scope') == 'aborted'
        assert windows() == baseline
        close()
        print(case, 'PASS', result, flush=True)
        continue
    assert js('document.querySelector("#media-player-result").dataset.scope') == 'active'
    close()
    if case == 'unscoped':
        end = time.monotonic() + 15
        while time.monotonic() < end:
            assert windows() == baseline, 'Unscoped call opened a receiver after tab closure'
            time.sleep(.25)
        print(case, 'PASS detached calls denied', flush=True)
        continue
    owned = wait(lambda: windows() - baseline)
    assert len(owned) == 1, owned
    movie = 'document of window id ' + str(next(iter(owned)))

    def qt(command):
        return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))

    wait(lambda: float(qt('get duration of MOVIE')) > 0)
    qt('play MOVIE')
    start = float(qt('get current time of MOVIE'))
    wait(lambda: float(qt('get current time of MOVIE')) > start + 3)
    qt('close MOVIE saving no')
    wait(lambda: windows() == baseline)
    print(case, 'PASS continuation after tab closure', flush=True)
print('PASS scoped lifetime', flush=True)
