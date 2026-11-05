#!/usr/bin/env python3
"""Capture of video without audio plays in QuickTime Player with aligned silence, through its end and across loops."""
import json
import os
import pathlib
import re
import subprocess
import time
import urllib.parse
import urllib.request

rig = pathlib.Path(__file__).resolve().parent
gst = rig.parents[2] / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
media = rig / 'build/quicktime-media'
proxyless = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40, stderr=subprocess.STDOUT).decode().strip()


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')


def wait(condition, seconds=60):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timeout')


def read(url):
    with proxyless.open(url, timeout=20) as response:
        return response.read()


def stream_times(transport):
    first, last = {}, {}
    for offset in range(0, len(transport) - 187, 188):
        packet = transport[offset:offset + 188]
        assert packet[0] == 0x47
        if not packet[1] & 0x40:
            continue
        pid = ((packet[1] & 31) << 8) | packet[2]
        start = 4 + (packet[4] + 1 if packet[3] & 0x20 else 0)
        header = packet[start:start + 14]
        if header[:3] != b'\0\0\1' or header[3] < 0xc0:
            continue
        stamp = (((header[9] & 0xe) << 29) | (header[10] << 22) | ((header[11] & 0xfe) << 14) | (header[12] << 7) | (header[13] >> 1)) / 90000
        first.setdefault(pid, stamp)
        last[pid] = stamp
    return first, last


def media_playlist(url):
    text = read(url).decode()
    if '#EXT-X-STREAM-INF:' in text:
        url = urllib.parse.urljoin(url, next(line for line in text.splitlines() if line and not line.startswith('#')))
        text = read(url).decode()
    return url, text


def check_segment(url, resource, duration):
    data = read(urllib.parse.urljoin(url, resource))
    first, last = stream_times(data)
    assert 0x41 in first and 0x42 in first, ('Segment lacks a track', first)
    assert abs(first[0x41] - first[0x42]) < .1, ('Silent audio misaligned', first)
    assert last[0x42] - first[0x42] <= duration + .2, ('Silent audio burst', first, last, duration)


def segments(text):
    return [(float(duration), resource) for duration, resource in re.findall(r'^#EXTINF:([^,]+),\n(\S+)$', text, re.M)]


def open_page(source, seconds_before, extra=''):
    osa('tell application "QuickTime Player" to close every document saving no')
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?source=' + source + '&sourceMode=capture' + extra) + '}')
    wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')
    assert js('video.audioTracks.length===0&&video.videoTracks.length===1') == 'true'
    js('video.play()')
    wait(lambda: float(js('video.currentTime')) > seconds_before, seconds_before + 30)


def hand_off():
    started = time.monotonic()
    js('document.querySelector("#open-media-player").click()')
    result = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    assert result.get('method') == 'restream', result
    assert time.monotonic() - started < 30, 'Slow start'
    wait(lambda: float(osa('tell application "QuickTime Player" to get current time of document 1')) > 1)
    print('handoff', round(time.monotonic() - started, 1), flush=True)
    return media_playlist(result['url'])


media.mkdir(parents=True, exist_ok=True)
for name, buffers in (('no-audio', 1800), ('no-audio-short', 240)):
    subprocess.run([str(gst), '-q', '-e'] + (f'mp4mux name=mux fragment-duration=2000 streamable=true ! filesink location={media / (name + ".mp4")} '
        f'videotestsrc num-buffers={buffers} pattern=smpte ! video/x-raw,format=NV12,width=640,height=360,framerate=30/1 '
        '! x264enc speed-preset=ultrafast key-int-max=60 bitrate=1500 ! video/x-h264,profile=main ! h264parse ! queue ! mux.video_0').split(),
        env=dict(os.environ, GST_REGISTRY_FORK='no'), check=True)

# Thirty seconds into playback, then through the source's end.
open_page('no-audio.mp4', 30)
url, text = hand_off()
parts = segments(text)
assert parts, text
check_segment(url, parts[0][1], parts[0][0])
final = wait(lambda: (lambda value: value if '#EXT-X-ENDLIST' in value else None)(read(url).decode()), 90)
parts = segments(final)
check_segment(url, parts[-1][1], parts[-1][0])
print('ended with', len(parts), 'segments', flush=True)
osa('tell application "QuickTime Player" to close every document saving no')
osa('tell application "Safari" to close current tab of front window')

# Send to QuickTime's bounded history leaves the playlist without a type.
open_page('no-audio.mp4', 1, '&capture=' + urllib.parse.quote(json.dumps({'maxWidth': 1920, 'maxHeight': 1080, 'maxHistoryDuration': 21600})))
url, text = hand_off()
assert '#EXT-X-PLAYLIST-TYPE:' not in text and '#EXT-X-ENDLIST' not in text, text
parts = segments(text)
check_segment(url, parts[0][1], parts[0][0])
osa('tell application "QuickTime Player" to close every document saving no')
osa('tell application "Safari" to close current tab of front window')

# A loop restarts the capture on a pipeline whose running time has moved on.
open_page('no-audio-short.mp4', 1)
js('video.loop=true;1')
url, text = hand_off()
count = len(segments(text))
parts = wait(lambda: (lambda value: value if len(value) > count + 12 else None)(segments(read(url).decode())), 60)
assert '#EXT-X-ENDLIST' not in read(url).decode()
check_segment(url, parts[-2][1], parts[-2][0])
position = float(osa('tell application "QuickTime Player" to get current time of document 1'))
wait(lambda: float(osa('tell application "QuickTime Player" to get current time of document 1')) > position + 1, 15)
osa('tell application "QuickTime Player" to close every document saving no')
osa('tell application "Safari" to close current tab of front window')
print('PASS capture without audio starts late, aligns, ends and survives loops', flush=True)
