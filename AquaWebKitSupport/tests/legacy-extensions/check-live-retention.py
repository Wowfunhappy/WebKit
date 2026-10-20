#!/usr/bin/env python3
"""Check accumulated HLS history, completed seeking, receiver pause and cleanup."""
import argparse
import json
import re
import subprocess
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', default='mse.mp4')
parser.add_argument('--seconds', type=int, default=180)
parser.add_argument('--pause-seconds', type=int, default=65)
args = parser.parse_args()

def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()

def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + safari_window)

def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.5)
    raise AssertionError('Timed out')

def read(url):
    return urllib.request.urlopen(url, timeout=15).read()

def windows():
    return {int(value) for value in osa('tell application "QuickTime Player" to get id of every window').split(',') if value.strip()}

def playlist(url):
    text = read(url).decode()
    ended = '#EXT-X-ENDLIST' in text
    assert ('#EXT-X-PLAYLIST-TYPE:VOD' if ended else '#EXT-X-PLAYLIST-TYPE:EVENT') in text, text
    durations = [float(value) for value in re.findall(r'^#EXTINF:([^,]+),', text, re.M)]
    assert durations and sum(durations) > 0, durations
    assert all(0 < value and round(value) <= 3 for value in durations), durations
    first = int(re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)$', text, re.M).group(1))
    assert first == 0, text
    urls = [urllib.parse.urljoin(url, line) for line in text.splitlines() if line and not line.startswith('#')]
    return dict(text=text, first=first, end=first + len(urls), urls=urls, duration=sum(durations))

def storage_bytes():
    result = subprocess.run(['/usr/sbin/lsof', '-n', '-P', '-a', '-c', 'com.apple.WebKi', '+L1', '-F', 'pnDis'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
    assert result.returncode in (0, 1), result.returncode
    output = result.stdout.decode()
    entries = {}
    device = inode = None
    size = 0
    for line in output.splitlines():
        if line.startswith('D'):
            device, inode, size = line[1:], None, 0
        elif line.startswith('i'):
            inode = line[1:]
        elif line.startswith('s'):
            size = int(line[1:])
        elif line.startswith('n') and 'media-player-stream-' in line:
            entries[(device, inode)] = size
    return sum(entries.values()), len(entries)

before = windows()
baseline_storage = storage_bytes()
query = urllib.parse.urlencode(dict(source=args.source, sourceMode='capture', subtitles='1'))
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?' + query) + '}')
safari_window = osa('tell application "Safari" to get id of front window')
wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2&&document.querySelector("#open-media-player"))') == 'true')
js('video.loop=true; video.play(); document.querySelector("#open-media-player").click()')
reply = json.loads(wait(lambda: (lambda text: text if text.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
assert reply.get('method') == 'restream', reply
owned = wait(lambda: windows() - before)
assert len(owned) == 1, owned
movie = 'document of window id ' + str(next(iter(owned)))
def qt(command):
    return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))
master = read(reply['url']).decode()
media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#'))) if '#EXT-X-STREAM-INF:' in master else reply['url']
first = playlist(media_url)
old_url = first['urls'][0]
old_data = read(old_url)
print('OPEN', reply, 'first', first['first'], flush=True)
subtitle_match = re.search(r'URI="([^"]+\.m3u8)"', master)
subtitle_url = urllib.parse.urljoin(reply['url'], subtitle_match.group(1)) if subtitle_match else None
subtitle_segment = playlist(subtitle_url)['urls'][0] if subtitle_url else None
subtitle_data = read(subtitle_segment) if subtitle_segment else None
wait(lambda: playlist(media_url)['duration'] > 70, 90)
assert read(old_url) == old_data, 'Beginning of recording expired'
if subtitle_segment:
    assert read(subtitle_segment) == subtitle_data, 'Beginning of subtitles expired'
print('BEGINNING_RETAINED_BEYOND_LIVE_WINDOW', flush=True)
js('window.receiverPlaybackEvents=[]; ["pause","play"].forEach(name=>video.addEventListener(name,()=>receiverPlaybackEvents.push(name)));true')
qt('pause MOVIE')
wait(lambda: qt('get playing of MOVIE') == 'false', 10)
paused_time = float(qt('get current time of MOVIE'))
previous_capture = playlist(media_url)
started = time.monotonic()
while time.monotonic() - started < args.pause_seconds:
    time.sleep(min(15, args.pause_seconds - (time.monotonic() - started)))
    assert js('video.paused') == 'false', 'Receiver pause paused the source'
    assert js('JSON.stringify(receiverPlaybackEvents)') == '[]', 'Receiver pause emitted source playback events'
    assert abs(float(qt('get current time of MOVIE')) - paused_time) < .1
    current_capture = playlist(media_url)
    assert current_capture['end'] > previous_capture['end'], 'Capture stopped while receiver was paused'
    assert read(old_url) == old_data, 'Paused receiver lost its retained history'
    previous_capture = current_capture
    print('RECEIVER_PAUSED_SOURCE_PLAYING', round(time.monotonic() - started, 1), 'captured', current_capture['duration'], flush=True)
qt('play MOVIE')
wait(lambda: float(qt('get current time of MOVIE')) > paused_time + 1, 15)
assert js('video.paused') == 'false'
assert js('JSON.stringify(receiverPlaybackEvents)') == '[]', 'Receiver resume emitted source playback events'
js('setTimeout(()=>video.loop=false,' + str(args.seconds * 1000) + ');true')
osa('tell application "Safari" to close current tab of window id ' + safari_window)
print('TAB_CLOSED', flush=True)
started = time.monotonic()
previous = float(qt('get current time of MOVIE'))
previous_duration = playlist(media_url)['duration']
while time.monotonic() - started < args.seconds:
    time.sleep(15)
    current = float(qt('get current time of MOVIE'))
    assert current > previous + 5, ('Receiver stalled', current, previous)
    previous = current
    state = playlist(media_url)
    assert state['duration'] > previous_duration, 'Recording stopped growing'
    previous_duration = state['duration']
    assert read(old_url) == old_data, 'Beginning of detached recording expired'
    if subtitle_segment:
        assert read(subtitle_segment) == subtitle_data
    stored, files = storage_bytes()
    assert files == baseline_storage[1] + 1, ('Capture must use one growing file', files, baseline_storage)
    print('PLAY', round(time.monotonic() - started, 1), current, 'duration', state['duration'], 'stored', stored, 'files', files, flush=True)
wait(lambda: '#EXT-X-ENDLIST' in playlist(media_url)['text'], 90)
final = playlist(media_url)
assert final['duration'] > 70 + args.seconds, final['duration']
wait(lambda: abs(float(qt('get duration of MOVIE')) - final['duration']) < 2, 30)
for target in (2, final['duration'] / 2, final['duration'] - 5):
    qt('pause MOVIE')
    qt('set current time of MOVIE to ' + str(target))
    wait(lambda: abs(float(qt('get current time of MOVIE')) - target) < 1, 15)
    qt('play MOVIE')
    wait(lambda: float(qt('get current time of MOVIE')) > target + 1, 15)
    print('COMPLETED_SEEK', target, 'duration', final['duration'], flush=True)
assert read(old_url) == old_data
assert playlist(media_url)['text'] == final['text']
qt('close MOVIE saving no')
wait(lambda: storage_bytes() == baseline_storage, 20)
print('PASS accumulated media/subtitle history, independent receiver pause/resume, detached EOS, full seeking and cleanup', flush=True)
