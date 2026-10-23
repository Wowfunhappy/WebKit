#!/usr/bin/env python3
"""Check decoded language changes during an active HLS capture and source loops."""
import argparse
import array
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', default='audio-languages.mp4')
parser.add_argument('--switches', type=int, default=8)
parser.add_argument('--alternate-channels', type=int, default=2)
args = parser.parse_args()
rig = Path(__file__).resolve().parent
out = rig / 'build/audio-switch'
out.mkdir(parents=True, exist_ok=True)


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=35).decode().strip()


def wait(check, seconds=50):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')


def windows():
    return {int(value) for value in osa('tell application "QuickTime Player" to get id of every window').split(',') if value.strip()}


def read(url):
    return urllib.request.urlopen(url, timeout=15).read()


baseline = windows()
window = None
owned = set()
try:
    url = 'http://127.0.0.1:8843/quicktime.html?source=plain.mp4&subtitles=external&sourceMode=capture'
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    window = osa('tell application "Safari" to get id of front window')
    print('WINDOW', window, flush=True)


    def js(script):
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)


    wait(lambda: js('Boolean(video.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')
    js('video.src=' + json.dumps('/quicktime-media/' + args.source) + ';video.loop=true;true')
    wait(lambda: js('video.readyState>=2 && video.audioTracks.length===2') == 'true')
    js('Array.from(video.audioTracks).forEach(t=>t.enabled=t.language==="en");video.play();true')
    wait(lambda: js('video.currentTime>0.5') == 'true')
    js('document.querySelector("#open-media-player").click()')
    reply = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    print('OPEN', reply, flush=True)
    assert reply.get('method') == 'restream', reply
    owned = wait(lambda: windows() - baseline)
    assert len(owned) == 1, owned
    movie = 'document of window id ' + str(next(iter(owned)))


    def qt(command):
        return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))


    master = read(reply['url']).decode()
    media_url = urllib.parse.urljoin(reply['url'], next(line for line in master.splitlines() if line and not line.startswith('#')))


    def playlist():
        text = read(media_url).decode()
        sequence = int(re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)$', text, re.M).group(1))
        discontinuity = int(re.search(r'^#EXT-X-DISCONTINUITY-SEQUENCE:(\d+)$', text, re.M).group(1))
        segments = [line for line in text.splitlines() if line and not line.startswith('#')]
        return sequence + len(segments), discontinuity + text.splitlines().count('#EXT-X-DISCONTINUITY'), segments


    wait(lambda: float(qt('get current time of MOVIE')) > 1)
    for index in range(args.switches):
        language = 'de' if index % 2 == 0 else 'en'
        before = playlist()
        before_time = float(qt('get current time of MOVIE'))
        js('Array.from(video.audioTracks).forEach(t=>t.enabled=t.language===' + json.dumps(language) + ');true')
        wait(lambda: playlist()[0] > before[0] + 4 and playlist()[1] > before[1])
        segment = playlist()[2][-2]
        transport = out / 'selected.ts'
        pcm = out / 'selected.f32'
        data = read(urllib.parse.urljoin(media_url, segment))
        channel_configurations = set()
        for offset in range(0, len(data), 188):
            packet = data[offset:offset + 188]
            if not packet[1] & 64 or not packet[3] & 16:
                continue
            payload = packet[4 + (packet[4] + 1 if packet[3] & 32 else 0):]
            if len(payload) < 9 or payload[:3] != b'\0\0\1' or not 0xc0 <= payload[3] <= 0xdf:
                continue
            adts = payload[9 + payload[8]:]
            assert len(adts) >= 7 and adts[0] == 255 and adts[1] & 246 == 240, adts[:7]
            channel_configurations.add((adts[2] & 1) << 2 | adts[3] >> 6)
        expected_channels = args.alternate_channels if language == 'de' else 2
        assert channel_configurations == {expected_channels}, (language, channel_configurations, expected_channels)
        transport.write_bytes(data)
        gst = rig.parents[1] / 'deps/build/bin/gst-launch-1.0'
        subprocess.run([str(gst), '-q', 'filesrc', 'location=' + str(transport), '!', 'tsdemux', '!', 'aacparse', '!', 'avdec_aac', '!', 'audioconvert', '!', 'audio/x-raw,format=F32LE,rate=48000,channels=1', '!', 'filesink', 'location=' + str(pcm)], env=dict(os.environ, GST_REGISTRY_FORK='no'), timeout=30, check=True)
        samples = array.array('f', pcm.read_bytes())[2048:]
        assert len(samples) > 12000, len(samples)
        frequency = sum(a <= 0 < b for a, b in zip(samples, samples[1:])) * 48000 / len(samples)
        assert abs(frequency - (880 if language == 'de' else 440)) < 4, (language, frequency)
        assert owned <= windows(), 'Receiver closed during audio selection'
        assert js('video.error===null && !video.paused') == 'true'
        wait(lambda: float(qt('get current time of MOVIE')) > before_time + 1)
        print('SWITCH', index + 1, language, 'Hz', frequency, 'receiver', qt('get current time of MOVIE'), flush=True)
    osa('tell application "Safari" to close current tab of window id ' + window)
    window = None
    before = playlist()[0]
    wait(lambda: playlist()[0] > before + 4)
    qt('close MOVIE saving no')
    wait(lambda: windows() == baseline)
    owned = set()
    print('PASS dynamic selected audio, source loops and tab closure', args.source, args.switches, flush=True)
finally:
    if window:
        try:
            osa('tell application "Safari" to close current tab of window id ' + window)
        except subprocess.CalledProcessError:
            pass
    for identifier in owned:
        try:
            osa('tell application "QuickTime Player" to close document of window id ' + str(identifier) + ' saving no')
        except subprocess.CalledProcessError:
            pass
