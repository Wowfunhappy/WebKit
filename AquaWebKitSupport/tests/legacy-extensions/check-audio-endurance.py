#!/usr/bin/env python3
"""Check a live audio-only HLS handoff after its source tab closes."""
import argparse
import json
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, default=3600)
args = parser.parse_args()


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=60):
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
url = 'http://127.0.0.1:8843/quicktime.html?source=flac.webm&mode=live&element=audio&sourceMode=capture'
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
window = osa('tell application "Safari" to get id of front window')


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)


wait(lambda: js('Boolean(document.querySelector("#open-media-player") && video.readyState>=2 && !video.paused)') == 'true')
assert js('video.localName==="audio" && video.videoTracks.length===0') == 'true'
js('document.querySelector("#open-media-player").click()')
reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
assert reply.get('method') == 'restream', reply
owned = wait(lambda: windows() - baseline)
assert len(owned) == 1, owned
movie = 'document of window id ' + str(next(iter(owned)))


def qt(command):
    return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))


master = read(reply['url'])
media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#'))) if '#EXT-X-STREAM-INF:' in master else reply['url']
playlist = read(media_url)
target = int(re.search(r'^#EXT-X-TARGETDURATION:(\d+)$', playlist, re.M).group(1))
initial_duration = sum(float(value) for value in re.findall(r'^#EXTINF:([^,]+),', playlist, re.M))
assert initial_duration >= 3 * target, ('Insufficient live startup buffer', initial_duration, target)
segment = urllib.parse.urljoin(media_url, next(line for line in playlist.splitlines() if line and not line.startswith('#')))
data = urllib.request.urlopen(segment, timeout=15).read()
audio_packets = 0
for offset in range(0, len(data), 188):
    packet = data[offset:offset + 188]
    assert len(packet) == 188 and packet[0] == 0x47
    if not packet[1] & 64 or not packet[3] & 16:
        continue
    payload = packet[4 + (packet[4] + 1 if packet[3] & 32 else 0):]
    if len(payload) >= 4 and payload[:3] == b'\0\0\1':
        assert not 0xe0 <= payload[3] <= 0xef, 'Audio-only capture contains video packets'
        audio_packets += 0xc0 <= payload[3] <= 0xdf
assert audio_packets, 'Audio-only capture contains no audio packets'
wait(lambda: float(qt('get current time of MOVIE')) > 1)
osa('tell application "Safari" to close current tab of window id ' + window)
print('OPEN', reply, 'window', owned, 'TAB_CLOSED', flush=True)
started = time.monotonic()
previous = float(qt('get current time of MOVIE'))
previous_end = 0
while time.monotonic() - started < args.seconds:
    time.sleep(15)
    current = float(qt('get current time of MOVIE'))
    assert current > previous + 5 and qt('get playing of MOVIE') == 'true', (previous, current)
    previous = current
    text = read(media_url)
    durations = [float(value) for value in re.findall(r'^#EXTINF:([^,]+),', text, re.M)]
    sequence = int(re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)$', text, re.M).group(1))
    assert durations and 0 < sum(durations) <= 30.000001 and '#EXT-X-ENDLIST' not in text, text
    assert sequence + len(durations) > previous_end
    previous_end = sequence + len(durations)
    print('PLAY', round(time.monotonic() - started, 1), current, 'sequence', sequence, previous_end, flush=True)
qt('close MOVIE saving no')


def released():
    try:
        read(media_url)
        return False
    except urllib.error.HTTPError as error:
        assert error.code == 404, error
        return True
    except urllib.error.URLError as error:
        if not isinstance(error.reason, ConnectionRefusedError):
            raise
        return True


wait(released)
print('PASS live audio-only HLS, tab closure, bounded playlist and endpoint cleanup', args.seconds, flush=True)
