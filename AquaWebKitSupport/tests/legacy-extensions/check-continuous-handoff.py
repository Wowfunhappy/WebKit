#!/usr/bin/env python3
"""Drive the installed test extension in Safari and verify continuous handoff."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', help='Fixture source and optional query parameters')
parser.add_argument('--position', type=float, default=0)
parser.add_argument('--rate', type=float, default=1)
parser.add_argument('--change-rate', type=float, help='Change the source playback rate after handoff')
parser.add_argument('--inline-cues', action='store_true', help='Check inline subtitle timestamp scaling')
parser.add_argument('--seek', type=float, help='Deliberate source seek after handoff')
parser.add_argument('--web-audio', action='store_true', help='Verify shutdown on an audio route change')
parser.add_argument('--loop', action='store_true', help='Verify capture across automatic source loops')
parser.add_argument('--stop-loop', action='store_true', help='Disable looping and verify finalization')
parser.add_argument('--replace-source', action='store_true', help='Verify retained capture across a replacement MediaSource')
parser.add_argument('--replay', action='store_true', help='Verify completed playlists remain final after source replay')
parser.add_argument('--enable-inband', action='store_true', help='Select the fixture in-band caption track before handoff')
parser.add_argument('--caption-probe', action='store_true', help='Verify native caption playback with the prebuilt MediaLegibleProbe')
parser.add_argument('--paused', action='store_true', help='Verify rejection without starting the source')
args = parser.parse_args()
rig = Path(__file__).resolve().parent

def osa(script):
    return subprocess.check_output(['osascript', '-e', script]).decode().strip()

def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')

def read(url):
    return urllib.request.urlopen(url, timeout=15).read().decode()

def sequence(text, name):
    match = re.search(r'^#EXT-X-' + name + r':(\d+)$', text, re.M)
    return int(match.group(1)) if match else 0

def discontinuities(text):
    return sequence(text, 'DISCONTINUITY-SEQUENCE') + text.splitlines().count('#EXT-X-DISCONTINUITY')

def end_sequence(text):
    return sequence(text, 'MEDIA-SEQUENCE') + text.count('#EXTINF:')

def wait_for(check, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.25)
    raise AssertionError('Timed out waiting for fixture state')

url = 'http://127.0.0.1:8843/quicktime.html?source=' + args.source
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
wait_for(lambda: js('Boolean(document.querySelector("video")?.readyState >= 2 && document.querySelector("#open-media-player"))') == 'true')
assert js('typeof aqua') == 'undefined', 'Privileged API exposed to the page'
if args.enable_inband:
    wait_for(lambda: js('video.textTracks.length>0') == 'true')
    js('window.originalCaptionTrack=video.textTracks[0];originalCaptionTrack.mode="showing"')
if args.position:
    js('video.currentTime=' + str(args.position))
    wait_for(lambda: js('!video.seeking && video.readyState >= 2') == 'true')
if args.inline_cues:
    js('video.textTracks[0].addCue(new VTTCue(20,50,"Timing before <00:00:30.000>Timing after"))')
js('video.playbackRate=' + str(args.rate))
if args.loop:
    js('video.loop=true')
if not args.paused:
    js('video.play()')
    time.sleep(.5)
js('window.handoffEvents=[]; ["seeking","seeked","volumechange","pause","play"].forEach(name => video.addEventListener(name, () => handoffEvents.push({name,ended:video.ended})))')
state = 'JSON.stringify({time:video.currentTime,muted:video.muted,volume:video.volume,rate:video.playbackRate,events:handoffEvents})'
before = json.loads(js(state))
started = time.monotonic()
js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver"; document.querySelector("#open-media-player").click()')
result = wait_for(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')))
result = json.loads(result)
elapsed = time.monotonic() - started
after = json.loads(js(state))
print(json.dumps({'source': args.source, 'seconds': elapsed, 'result': result, 'before': before, 'after': after}), flush=True)
assert not [e for e in after['events'] if not ((e['name'] == 'pause' and (e['ended'] or result.get('method') == 'url')) or (args.loop and e['name'] in ('seeking', 'seeked')))], after
assert all(before[key] == after[key] for key in ('muted', 'volume', 'rate'))
if not args.loop:
    assert before['time'] <= after['time'] <= before['time'] + elapsed * before['rate'] + 2
if args.paused:
    assert result.get('error') == 'not-playing', result
    osa('tell application "Safari" to close current tab of front window')
    sys.exit(0)
assert result.get('method') in ('url', 'restream'), result
if result['method'] == 'url':
    osa('tell application "Safari" to close current tab of front window')
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    print('Direct URL delivered with a native handoff pause', flush=True)
    sys.exit(0)
media_url = result['url']
playlist = read(media_url)
if '#EXT-X-STREAM-INF:' in playlist:
    media_url = urllib.parse.urljoin(media_url, next(line for line in playlist.splitlines() if line and not line.startswith('#')))
    playlist = read(media_url)
assert '#EXT-X-PLAYLIST-TYPE:' not in playlist
assert '#EXT-X-MEDIA-SEQUENCE:' in playlist
if args.loop:
    wait_for(lambda: discontinuities(read(media_url)) >= 2)
    print('Capture continues across automatic source loops', flush=True)
if args.stop_loop:
    js('video.loop=false')
    wait_for(lambda: '#EXT-X-ENDLIST' in read(media_url))
    print('Disabling loop finalizes retained history', flush=True)
if args.replay:
    wait_for(lambda: '#EXT-X-ENDLIST' in read(media_url))
    finalized = read(media_url)
    js('video.currentTime=0; video.play()')
    time.sleep(4)
    assert read(media_url) == finalized, 'Finalized playlist changed after replay'
    print('Finalized history remains immutable after source replay', flush=True)
if args.seek is not None:
    old_count = discontinuities(read(media_url))
    js('video.currentTime=' + str(args.seek))
    wait_for(lambda: discontinuities(read(media_url)) > old_count)
    print('Source seek published a new discontinuity', flush=True)
if args.change_rate is not None:
    old_count = discontinuities(read(media_url))
    js('video.playbackRate=' + str(args.change_rate))
    wait_for(lambda: discontinuities(read(media_url)) > old_count)
    print('Source rate change published a new discontinuity', flush=True)
if args.replace_source:
    old_discontinuities = discontinuities(read(media_url))
    js('window.replaceHandoffSource()')
    wait_for(lambda: discontinuities(read(media_url)) > old_discontinuities)
    if args.enable_inband:
        wait_for(lambda: js('video.textTracks.length>0 && video.textTracks[0]!==originalCaptionTrack && video.textTracks[0].mode==="showing" && video.textTracks[0].cues.length>0') == 'true')
        master = read(result['url'])
        subtitle_path = re.search(r'TYPE=SUBTITLES[^\n]*URI="([^"]+)"', master).group(1)
        subtitle_url = urllib.parse.urljoin(result['url'], subtitle_path)
        def replacement_captions():
            text = read(subtitle_url)
            discontinuities = sequence(text, 'DISCONTINUITY-SEQUENCE')
            for line in text.splitlines():
                if line == '#EXT-X-DISCONTINUITY':
                    discontinuities += 1
                elif line and not line.startswith('#') and discontinuities > old_discontinuities:
                    text = read(urllib.parse.urljoin(subtitle_url, line))
                    if 'Align ' in text or 'Bottom Center' in text:
                        return True
            return False
        wait_for(replacement_captions)
        print('Replacement in-band track publishes new captions', flush=True)
    print('Replacement MediaSource continues the same retained playlist', flush=True)
if args.web_audio:
    js('window.handoffAudioContext=new AudioContext(); window.handoffAudioNode=handoffAudioContext.createMediaElementSource(video); handoffAudioNode.connect(handoffAudioContext.destination)')
    def stopped():
        try:
            read(media_url)
            return False
        except (urllib.error.HTTPError, urllib.error.URLError):
            return True
    wait_for(stopped)
    osa('tell application "Safari" to close current tab of front window')
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    print('Source or audio route change released capture', flush=True)
    sys.exit(0)
out = Path(tempfile.mkdtemp(prefix='continuous-' + args.source.replace('&', '-').replace('=', '-') + '-', dir=rig / 'build'))
subprocess.run([sys.executable, str(rig / 'check-media-restream.py'), result['url'], '--output', str(out)], check=True)
(rig / 'build' / 'continuous-last-result.json').write_text(json.dumps(result))
if args.inline_cues:
    def seconds(value):
        hours, minutes, seconds = value.split(':')
        return int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    matches = []
    for resource in out.glob('*.vtt'):
        matches.extend(re.findall(r'([0-9:.]+) --> [^\n]+\nTiming before <([0-9:.]+)>Timing after', resource.read_text()))
    assert matches, 'No inline timestamp survived subtitle export'
    assert any(abs(seconds(tag) - seconds(start) - 10 / args.rate) < .002 for start, tag in matches), matches
    print('Inline subtitle timestamp follows the rendered rate', flush=True)
if args.caption_probe:
    probe = subprocess.run([str(rig / 'build' / 'MediaLegibleProbe'), result['url'], '16'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    output = probe.stdout.decode()
    (out / 'captions.log').write_text(output)
    print(output, flush=True)
    assert 'CAPTION' in output and (('Align ' in output or 'Bottom Center' in output) if args.enable_inband else 'Subtitle at ' in output), 'Native player produced no fixture captions'

osa('tell application "Safari" to close current tab of front window')
playlist = read(media_url)
if '#EXT-X-ENDLIST' not in playlist:
    baseline_count = end_sequence(playlist)
    wait_for(lambda: (lambda later: end_sequence(later) >= baseline_count + 2 or '#EXT-X-ENDLIST' in later)(read(media_url)))
    print('Capture published after tab closure', flush=True)
for resource in list(out.glob('*.ts')) + list(out.glob('*.vtt')):
    retained_url = json.loads((out / 'resources.json').read_text())[resource.name]
    assert urllib.request.urlopen(retained_url, timeout=15).read() == resource.read_bytes(), resource
print('Media and subtitle history remains readable after tab closure', flush=True)
osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
def released():
    try:
        read(media_url)
        return False
    except (urllib.error.HTTPError, urllib.error.URLError, ConnectionError):
        return True
wait_for(released)
print('Receiver exit released the handoff endpoint', flush=True)
