#!/usr/bin/env python3
"""QuickTime Player shows a picture from capture and from a handed-off URL, whatever colorimetry the source declares."""
import json
import os
import pathlib
import struct
import subprocess
import tempfile
import time
import urllib.parse
import zlib

rig = pathlib.Path(__file__).resolve().parent
gst = rig.parents[2] / 'AquaWebKitSupport/deps/build/bin/gst-launch-1.0'
media = rig / 'build/quicktime-media'
CASES = [('bt709', '2:3:5:1'), ('srgb', '2:3:7:1'), ('bt2020-pq', '2:6:14:7'), ('bt2020-hlg', '2:6:15:7'), ('dci-p3', '2:3:5:10'), ('full-range', '1:3:5:1')]


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


def mean_brightness(path):
    data = path.read_bytes()
    offset = 8
    compressed = b''
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + size]
        if kind == b'IHDR':
            width, height, _, color = struct.unpack('>IIBB', body[:10])
        elif kind == b'IDAT':
            compressed += body
        offset += 12 + size
    raw = zlib.decompress(compressed)
    pixel = {2: 3, 6: 4}[color]
    stride = width * pixel + 1
    previous = bytearray(width * pixel)
    total = count = 0
    for y in range(height):
        kind = raw[y * stride]
        row = bytearray(raw[y * stride + 1:(y + 1) * stride])
        for x in range(len(row)):
            left = row[x - pixel] if x >= pixel else 0
            up = previous[x]
            corner = previous[x - pixel] if x >= pixel else 0
            if kind == 1:
                row[x] = (row[x] + left) & 255
            elif kind == 2:
                row[x] = (row[x] + up) & 255
            elif kind == 3:
                row[x] = (row[x] + (left + up) // 2) & 255
            elif kind == 4:
                a, b, c = abs(up - corner), abs(left - corner), abs(left + up - 2 * corner)
                row[x] = (row[x] + (left if a <= b and a <= c else up if b <= c else corner)) & 255
        previous = row
        if height // 4 <= y < height * 3 // 4 and y % 6 == 0:
            samples = row[width // 4 * pixel:width * 3 // 4 * pixel:pixel * 5]
            total += sum(samples)
            count += len(samples)
    return total / count


VIDEO = 'videotestsrc num-buffers={} pattern=smpte ! video/x-raw,format=NV12,width=640,height=360,framerate=30/1,colorimetry={} ! x264enc speed-preset=ultrafast key-int-max=30 bitrate=1500 ! video/x-h264,profile=main ! h264parse'
AUDIO = 'audiotestsrc num-buffers={} samplesperbuffer=1024 ! audio/x-raw,rate=48000,channels=2 ! fdkaacenc bitrate=128000'
env = dict(os.environ, GST_REGISTRY_FORK='no')


def generate(pipeline):
    subprocess.run([str(gst), '-q', '-e'] + pipeline.split(), env=env, check=True)


def click():
    started = time.monotonic()
    js('document.querySelector("#open-media-player").click()')
    result = json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))
    return result, time.monotonic() - started


def open_page(query='source=plain.mp4'):
    osa('tell application "QuickTime Player" to close every document saving no')
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?' + query) + '}')
    wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2 && document.querySelector("#open-media-player"))') == 'true')


def use_source(source, preload=None, prefix='/quicktime-media/'):
    if preload:
        js('video.preload=' + json.dumps(preload))
    js('video.pause();video.src=' + json.dumps(prefix + source) + ';video.load();1')
    wait(lambda: js('video.currentSrc.indexOf(' + json.dumps(source) + ')>=0') == 'true')


def dismiss_dialogs():
    osa('tell application "System Events" to tell process "QuickTime Player"\nrepeat while (count of (windows whose subrole is "AXDialog")) > 0\nclick button "OK" of (first window whose subrole is "AXDialog")\ndelay .5\nend repeat\nend tell')


def close_page():
    osa('tell application "QuickTime Player" to close every document saving no')
    osa('tell application "Safari" to close current tab of front window')


def picture():
    """The brightness of the movie QuickTime Player is playing."""
    osa('tell application "QuickTime Player" to play document 1')
    wait(lambda: float(osa('tell application "QuickTime Player" to get current time of document 1')) > 2)
    osa('tell application "QuickTime Player" to activate')
    time.sleep(1.5)
    left, top, right, bottom = [int(value) for value in osa('tell application "QuickTime Player" to get bounds of window 1').split(', ')]
    with tempfile.TemporaryDirectory() as directory:
        shot = pathlib.Path(directory) / 'picture.png'
        subprocess.run(['screencapture', '-x', f'-R{left},{top},{right - left},{bottom - top}', str(shot)], check=True)
        return mean_brightness(shot)


def show(query, source=None, play=True, preload=None):
    open_page(query)
    if source:
        use_source(source, preload)
    if play:
        wait(lambda: js('video.readyState>=2') == 'true')
        js('video.play()')
        wait(lambda: js('!video.paused && video.currentTime>0') == 'true')
    result, _ = click()
    assert 'method' in result, (query, source, result)
    brightness = picture()
    close_page()
    return result['method'], brightness


media.mkdir(parents=True, exist_ok=True)
for name, colorimetry in CASES:
    generate(f'mp4mux name=mux fragment-duration=2000 streamable=true ! filesink location={media / ("color-" + name + ".mp4")} {VIDEO.format(1800, colorimetry)} ! queue ! mux.video_0 {AUDIO.format(2813)} ! aacparse ! queue ! mux.audio_0')
for name, colorimetry in (('bt709', '2:3:5:1'), ('srgb', '2:3:7:1')):
    generate(f'mp4mux name=mux ! filesink location={media / ("direct-" + name + ".mp4")} {VIDEO.format(900, colorimetry)} ! queue ! mux.video_0 {AUDIO.format(1407)} ! aacparse ! queue ! mux.audio_0')
    generate(f'mpegtsmux name=mux ! filesink location={media / ("direct-" + name + ".ts")} {VIDEO.format(900, colorimetry)} ! queue ! mux. {AUDIO.format(1407)} ! audio/mpeg,stream-format=adts ! queue ! mux.')
    (media / f'direct-{name}.m3u8').write_text(f'#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:30\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:30.0,\ndirect-{name}.ts\n#EXT-X-ENDLIST\n')

reference = None
for name, colorimetry in CASES:
    method, brightness = show('source=color-' + name + '.mp4&sourceMode=capture')
    print('capture', name, colorimetry, method, round(brightness, 1), flush=True)
    assert method == 'restream', (name, method)
    if reference is None:
        reference = brightness
        assert reference > 40, ('The reference picture is too dark to compare against', reference)
    assert abs(brightness - reference) < reference * .3, ('QuickTime Player did not show the picture', name, colorimetry, brightness, reference)

for label, source, expected, options in [
    ('direct mp4 bt709', 'direct-bt709.mp4', 'url', {}),
    ('direct hls bt709', 'direct-bt709.m3u8', 'url', {}),
    ('direct mp4 srgb', 'direct-srgb.mp4', 'restream', {}),
    ('direct hls srgb', 'direct-srgb.m3u8', 'restream', {}),
    ('unplayed mp4 srgb', 'direct-srgb.mp4', 'restream', {'play': False}),
    ('never loaded mp4 srgb', 'direct-srgb.mp4', 'restream', {'play': False, 'preload': 'none'}),
]:
    method, brightness = show('source=plain.mp4', source, **options)
    print(label, method, round(brightness, 1), flush=True)
    assert method == expected, (label, method, expected)
    assert abs(brightness - reference) < reference * .3, ('QuickTime Player did not show the picture', label, brightness, reference)

# A source the site names for the route takes the same route as the element's own. The capture then shows the
# page's inline source, which is dark.
for label, play in (('negotiated srgb playing', True), ('negotiated srgb paused', False)):
    method, _ = show('source=mse.mp4&airplay=route&routeMedia=direct-srgb.mp4', play=play)
    print(label, method, flush=True)
    assert method == 'restream', (label, method)

open_page('source=mse.mp4&airplay=route&routeMedia=direct-srgb.mp4&sourceMode=direct')
result, _ = click()
assert result.get('error') == 'no-direct-source', result
close_page()
print('negotiated srgb, direct only: no-direct-source', flush=True)

# A URL only: QuickTime Player would draw this source black, so there is none to give it.
open_page('source=plain.mp4&sourceMode=direct')
use_source('direct-srgb.mp4')
wait(lambda: js('video.readyState>=2') == 'true')
result, _ = click()
assert result.get('error') == 'no-direct-source', result
assert js('video.paused') == 'true', 'A refused direct handoff started the page'
close_page()
print('direct only of an srgb source: no-direct-source', flush=True)

# A page that replaces its source during the start owns playback of the new one.
open_page()
use_source('direct-srgb.mp4')
wait(lambda: js('video.readyState>=2') == 'true')
js('video.addEventListener("play",()=>{video.src="/quicktime-media/direct-bt709.mp4";video.load();video.play()},{once:true});1')
result, _ = click()
assert 'error' in result, result
assert js('video.currentSrc.indexOf("direct-bt709")>=0') == 'true', js('video.currentSrc')
wait(lambda: js('!video.paused&&video.currentTime>.5') == 'true', 20)
dismiss_dialogs()
close_page()
print('source replaced during the start: page keeps playing,', result['error'], flush=True)

# A never-loaded source gets its format without an extra load, and keeps its preload.
open_page()
use_source('direct-srgb.mp4', 'none')
js('window.reloads=[];["abort","emptied"].forEach(name=>video.addEventListener(name,()=>reloads.push(name)));1')
result, _ = click()
assert result.get('method') == 'restream', result
assert js('JSON.stringify(reloads)') == '[]', js('JSON.stringify(reloads)')
assert abs(picture() - reference) < reference * .3, 'never-loaded source showed no picture'
osa('tell application "QuickTime Player" to close every document saving no')
wait(lambda: js('video.preload') == 'none', 15)
wait(lambda: js('video.paused') == 'true', 15)
osa('tell application "Safari" to close current tab of front window')
print('never loaded: no reload, preload restored, paused again', flush=True)

# Another receiver gets the URL, whose picture QuickTime Player's limits do not concern.
open_page()
use_source('direct-srgb.mp4')
wait(lambda: js('video.readyState>=2') == 'true')
js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";1')
result, _ = click()
assert result.get('method') == 'url', result
close_page()
subprocess.run(['osascript', '-e', 'tell application id "org.aqua.webkit.media-handoff-receiver" to quit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('other receiver: url', flush=True)

# An explicit capture still asks for a playing source.
open_page('source=plain.mp4&sourceMode=capture')
use_source('direct-srgb.mp4')
wait(lambda: js('video.readyState>=2') == 'true')
result, _ = click()
assert result.get('error') == 'not-playing', result
close_page()
print('explicit capture of a paused source: not-playing', flush=True)

# A failed capture leaves a paused page paused.
open_page('source=plain.mp4&capture=' + urllib.parse.quote(json.dumps({'maxWidth': -1})))
use_source('direct-srgb.mp4')
wait(lambda: js('video.readyState>=2') == 'true')
result, _ = click()
assert 'error' in result, result
assert js('video.paused') == 'true', 'A failed capture left the page playing'
close_page()
print('failed capture stays paused:', result['error'], flush=True)

# A source the page cannot decode does not wait for a format it will never have, here for up to 90 s.
open_page('source=plain.mp4&routeTimeout=90')
use_source('missing.mp4')
wait(lambda: js('Boolean(video.error)') == 'true', 15)
result, elapsed = click()
assert result.get('error') != 'source-timeout' and elapsed < 60, (result, elapsed)
dismiss_dialogs()
close_page()
print('undecodable source:', result, round(elapsed, 1), flush=True)

# A slow source hands off directly once the wait for its format ends.
open_page('source=plain.mp4&routeTimeout=2')
use_source('direct-bt709.mp4', prefix='/delayed-quicktime-media/')
result, elapsed = click()
assert result.get('method') == 'url', (result, elapsed)
close_page()
print('slow source: url after', round(elapsed, 1), flush=True)
print('PASS QuickTime Player shows a picture for every declared colorimetry and route', flush=True)
