#!/usr/bin/env python3
"""Verify that handoff retains a selected native audio track or disabled audio."""
import argparse
import array
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('selection', choices=['en', 'de', 'disabled'])
args = parser.parse_args()
window_id = None
rig = Path(__file__).resolve().parent
out = rig / 'build/audio-selection'
out.mkdir(parents=True, exist_ok=True)


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=30).decode().strip()


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of ' + ('window id ' + window_id if window_id else 'front window'))


def wait(check):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def read(url):
    return urllib.request.urlopen(url, timeout=15).read()


url = 'http://127.0.0.1:8843/quicktime.html?source=plain.mp4&subtitles=external&test=' + str(time.time_ns())
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
wait(lambda: osa('tell application "Safari" to get URL of current tab of front window') == url)
window_id = osa('tell application "Safari" to get id of front window')
print('WINDOW', window_id, flush=True)
wait(lambda: js('Boolean(document.querySelector("#open-media-player") && video.readyState>=2)') == 'true')
if args.selection != 'disabled':
    js('video.src="/quicktime-media/audio-languages.mp4";true')
    wait(lambda: js('video.readyState>=2 && video.audioTracks.length===2') == 'true')
selection = json.dumps(args.selection)
js('Array.from(video.audioTracks).forEach(t=>t.enabled=t.language===' + selection + ');video.play();true')
wait(lambda: js('video.currentTime>0.5 && !video.paused') == 'true')
state = 'JSON.stringify(Array.from(video.audioTracks).map(t=>({language:t.language,enabled:t.enabled})))'
before = json.loads(js(state))
print('BEFORE', before, js('JSON.stringify({src:video.currentSrc,time:video.currentTime})'), flush=True)
assert sum(t['enabled'] for t in before) == (0 if args.selection == 'disabled' else 1), before
js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click()')
result = json.loads(wait(lambda: (lambda s: s if s.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
print('OPEN', result, flush=True)
assert result.get('method') == 'restream', result
assert json.loads(js(state)) == before
assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'false'
master = result['url']
playlist = read(master).decode()
url = master
if '#EXT-X-STREAM-INF:' in playlist:
    url = urllib.parse.urljoin(master, next(line for line in playlist.splitlines() if line and not line.startswith('#')))
    playlist = read(url).decode()
segment = next(line for line in playlist.splitlines() if line and not line.startswith('#'))
data = read(urllib.parse.urljoin(url, segment))
media = out / (args.selection + '.ts')
media.write_bytes(data)
audio_packets = 0
for i in range(0, len(data), 188):
    packet = data[i:i + 188]
    assert packet[0] == 0x47
    if not packet[1] & 64 or not packet[3] & 16:
        continue
    offset = 4 + (packet[4] + 1 if packet[3] & 32 else 0)
    payload = packet[offset:]
    if len(payload) >= 4 and payload[:3] == b'\0\0\1' and 0xc0 <= payload[3] <= 0xdf:
        audio_packets += 1
if args.selection == 'disabled':
    assert not audio_packets, 'Disabled source audio reappeared in handoff'
else:
    assert audio_packets
    pcm = out / (args.selection + '.f32')
    gst = rig.parents[2] / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
    subprocess.run([str(gst), '-q', 'filesrc', 'location=' + str(media), '!', 'tsdemux', '!', 'aacparse', '!', 'avdec_aac', '!', 'audioconvert', '!', 'audio/x-raw,format=F32LE,rate=48000,channels=1', '!', 'filesink', 'location=' + str(pcm)], env=dict(os.environ, GST_REGISTRY_FORK='no'), check=True, timeout=30)
    samples = array.array('f', pcm.read_bytes())[2048:]
    assert len(samples) > 12000
    crossings = sum(a <= 0 < b for a, b in zip(samples, samples[1:]))
    frequency = crossings * 48000 / len(samples)
    expected = 440 if args.selection == 'en' else 880
    assert abs(frequency - expected) < 3, (frequency, expected)
    print('DECODED', args.selection, frequency, flush=True)
osa('tell application "Safari" to close current tab of window id ' + window_id)
wait(lambda: read(url).decode().count('#EXTINF:') > playlist.count('#EXTINF:') + 2)
osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
print('PASS selected audio and tab closure', args.selection, before, flush=True)
