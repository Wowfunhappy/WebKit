#!/usr/bin/env python3
"""Exercise repeated source replacement, seeking and rate changes during HLS capture."""
import argparse
import json
import re
import subprocess
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cycles', type=int, default=20)
args = parser.parse_args()


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.5)
    raise AssertionError('Timed out')


def windows():
    return {int(value) for value in osa('tell application "QuickTime Player" to get id of every window').split(',') if value.strip()}


def read(url):
    return urllib.request.urlopen(url, timeout=15).read().decode()


baseline = windows()
url = 'http://127.0.0.1:8843/quicktime.html?source=mse.mp4&subtitles=1&sourceMode=capture'
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
window = osa('tell application "Safari" to get id of front window')


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)


wait(lambda: js('Boolean(document.querySelector("#open-media-player") && video.readyState>=2)') == 'true')
js('video.loop=true; video.play(); document.querySelector("#open-media-player").click()')
reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
assert reply.get('method') == 'restream', reply
owned = wait(lambda: windows() - baseline)
assert len(owned) == 1, owned
movie = 'document of window id ' + str(next(iter(owned)))


def qt(command):
    return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))


master = read(reply['url'])
media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#'))) if '#EXT-X-STREAM-INF:' in master else reply['url']


def playlist():
    text = read(media_url)
    sequence = int(re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)$', text, re.M).group(1))
    assert sequence == 0 and '#EXT-X-PLAYLIST-TYPE:EVENT' in text, text
    durations = [float(value) for value in re.findall(r'^#EXTINF:([^,]+),', text, re.M)]
    assert durations and all(value > 0 and round(value) <= 3 for value in durations), text
    assert '#EXT-X-ENDLIST' not in text, text
    return dict(end=sequence + len(durations), discontinuities=text.splitlines().count('#EXT-X-DISCONTINUITY'), text=text)


wait(lambda: float(qt('get current time of MOVIE')) > 1)
previous = float(qt('get current time of MOVIE'))
print('OPEN', reply, 'window', owned, flush=True)
for cycle in range(args.cycles):
    for name, action in [
        ('seek', 'video.currentTime=' + str(5 + cycle % 3 * 10)),
        ('rate', 'video.playbackRate=' + str(.5 if cycle % 2 == 0 else 1.5)),
        ('replace', 'window.transitionDone=false;window.transitionError=null;replaceHandoffSource().then(()=>transitionDone=true,error=>transitionError=String(error));true'),
    ]:
        before = playlist()
        js(action)
        if name == 'replace':
            wait(lambda: js('Boolean(transitionDone || transitionError)') == 'true')
            assert js('transitionError===null') == 'true', js('transitionError')
        wait(lambda: playlist()['discontinuities'] > before['discontinuities'])
        wait(lambda: playlist()['end'] >= before['end'] + 4)
        assert owned <= windows(), 'Receiver disappeared during ' + name
        assert js('video.error===null && !video.paused') == 'true', js('JSON.stringify({error:video.error,paused:video.paused})')
        wait(lambda: float(qt('get current time of MOVIE')) > previous + 1)
        previous = float(qt('get current time of MOVIE'))
        print('TRANSITION', cycle + 1, name, 'receiver', previous, 'playlist', playlist()['end'], flush=True)
osa('tell application "Safari" to close current tab of window id ' + window)
before = playlist()
wait(lambda: playlist()['end'] >= before['end'] + 10)
wait(lambda: float(qt('get current time of MOVIE')) > previous + 5)
qt('close MOVIE saving no')
wait(lambda: windows() == baseline)
print('PASS repeated HLS transitions, retained receiver and detached playback', args.cycles, flush=True)
