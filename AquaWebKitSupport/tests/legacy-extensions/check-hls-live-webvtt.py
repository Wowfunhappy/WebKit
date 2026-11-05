#!/usr/bin/env python3
"""Live HLS with a WebVTT rendition: load time, cue alignment, and a late or missing subtitle fragment."""
import argparse
import http.server
import json
import os
import pathlib
import re
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--playlist', default=str(pathlib.Path(__file__).parent / 'build/quicktime-media/index.m3u8'))
parser.add_argument('--mode', choices=['normal', 'late', 'missing', 'first-missing', 'all-missing', 'playlist-missing', 'playlist-missing-later'], default='normal')
parser.add_argument('--delay', type=float, default=12)
parser.add_argument('--window', type=int, default=4, help='segments in the live playlist')
parser.add_argument('--no-subtitles', action='store_true')
parser.add_argument('--no-endlist', action='store_true', help='keep the stream live past its last segment')
parser.add_argument('--lag', type=float, default=0, help='seconds the live window runs ahead of playback')
parser.add_argument('--text-mode', choices=['hidden', 'disabled', 'auto', 'cycle', 'seek-only', 'disable-later', 'rapid-toggle', 'fault-reenable'], default='hidden', help='what the page does with the track')
parser.add_argument('--rapid-seconds', type=float, default=30, help='how long --text-mode rapid-toggle toggles the track every 50 to 300 ms before leaving it hidden')
parser.add_argument('--disable-at', type=float, default=20, help='when --text-mode disable-later disables the track')
parser.add_argument('--subtitles-end-at', type=int, help='segment after which the subtitle playlist has EXT-X-ENDLIST while the video continues')
parser.add_argument('--playlist-recovers-at', type=float, help='seconds after which a missing subtitle playlist is served')
parser.add_argument('--expect-no-subtitles', action='store_true', help='caption preferences leave the track disabled, so no subtitle request may happen')
parser.add_argument('--encrypt', action='store_true', help='serve AES-128 video')
parser.add_argument('--encrypt-subtitles', action='store_true', help='serve AES-128 subtitles, to which --bad-padding then applies')
parser.add_argument('--subtitle-sequence-jump-at', type=float, help='seconds after which the subtitle playlist shares nothing with its earlier versions')
parser.add_argument('--ended-baseline-ms', type=float, help='how long after its last position a run without subtitles ends')
parser.add_argument('--stable-url', action='store_true', help='use the same page URL as other --stable-url runs')
parser.add_argument('--bad-padding', type=lambda value: int(value, 16), help='hex PKCS7 padding byte for one encrypted fragment')
parser.add_argument('--tiny-fragment', action='store_true', help='make the --bad-padding fragment a single AES block')
parser.add_argument('--fault-video', action='store_true', help='apply --mode to a video fragment')
parser.add_argument('--cycle-ms', type=int, default=6000, help='how long --text-mode cycle keeps each state')
parser.add_argument('--cycle-offset-ms', type=int, default=0, help='how much earlier --text-mode cycle changes state')
parser.add_argument('--seek-on-show', action='store_true', help='seek as soon as --text-mode cycle enables the track')
parser.add_argument('--subtitle-playlist-delay', type=float, default=0, help='seconds each subtitle playlist request takes')
parser.add_argument('--teardown-stress', type=int, default=0, help='close or navigate this many pages during --text-mode cycle, then require a playing page')
parser.add_argument('--seconds', type=int, default=40)
parser.add_argument('--port', type=int, default=8899)
args = parser.parse_args()

media = pathlib.Path(args.playlist).parent
entries = re.findall(r'#EXTINF:([\d.]+),?\n(\S+)', pathlib.Path(args.playlist).read_text())
segments = [(float(duration), media / name) for duration, name in entries]
target = int(max(duration for duration, _ in segments)) + 1
HEAD = args.window - 1
FAULT = HEAD + 2
FAULT_START = sum(duration for duration, _ in segments[:FAULT])
FAULT_END = sum(duration for duration, _ in segments[:FAULT + 1])
started = None
requests = []


def first_pts(path):
    data = path.read_bytes()
    for offset in range(0, len(data) - 187, 188):
        packet = data[offset:offset + 188]
        start = 4 + (1 + packet[4] if packet[3] & 0x20 else 0)
        if packet[1] & 0x40 and packet[3] & 0x10 and packet[start:start + 3] == b'\0\0\1' and packet[start + 7] & 0x80:
            pts = packet[start + 9:start + 14]
            return (pts[0] >> 1 & 7) << 30 | pts[1] << 22 | (pts[2] >> 1) << 15 | pts[3] << 7 | pts[4] >> 1
    raise AssertionError('No PTS in ' + str(path))


def newest():
    elapsed, index = time.monotonic() - started + args.lag, HEAD
    while index + 1 < len(segments) and elapsed >= sum(duration for duration, _ in segments[HEAD:index + 1]):
        index += 1
    return index


KEY = bytes(range(16))
encrypted = {}


def encrypted_segment(index):
    if index not in encrypted:
        plain = cues(index).encode() if args.encrypt_subtitles else segments[index][1].read_bytes()
        pad = 16 - len(plain) % 16
        if args.bad_padding is not None and index == FAULT:
            plain = b'\0' * 15 if args.tiny_fragment else plain + b'\0' * (pad - 1)
            plain += bytes([args.bad_padding])
        else:
            plain += bytes([pad]) * pad
        encrypted[index] = subprocess.run(['/usr/bin/openssl', 'enc', '-aes-128-cbc', '-nopad', '-K', KEY.hex(), '-iv', '0' * 32],
                                          input=plain, stdout=subprocess.PIPE, check=True).stdout
    return encrypted[index]


def media_playlist(kind):
    last = newest()
    ended = last + 1 == len(segments) and not args.no_endlist
    if kind == 'subs' and args.subtitles_end_at is not None and last >= args.subtitles_end_at:
        last, ended = args.subtitles_end_at, True
    first = max(0, last - args.window + 1)
    jumped = kind == 'subs' and args.subtitle_sequence_jump_at is not None and time.monotonic() - started >= args.subtitle_sequence_jump_at
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:%d' % target, '#EXT-X-MEDIA-SEQUENCE:%d' % (first + (100000 if jumped else 0))]
    if (args.encrypt and kind == 'video') or (args.encrypt_subtitles and kind == 'subs'):
        lines.append('#EXT-X-KEY:METHOD=AES-128,URI="/key",IV=0x' + '0' * 32)
    for index in range(first, last + 1):
        lines += ['#EXTINF:%.3f,' % segments[index][0], '/%s-%d%s' % (kind, index, '?jumped' if jumped else '')]
    if ended:
        lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


def cues(index):
    duration = segments[index][0]
    return ('WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00.000,MPEGTS:%d\n\n00:00:00.000 --> 00:00:%06.3f\nsegment %d\n\n'
            % (first_pts(segments[index][1]), min(duration, 59), index))


PAGE = ('''<!doctype html><title>Live WebVTT</title><video id=v controls muted width=640></video><script>
var T=[],P=[],Q=[],t0=performance.now(),C=null;
["loadstart","loadedmetadata","loadeddata","canplay","playing","waiting","stalled","ended","error"].forEach(function(n){v.addEventListener(n,function(){T.push(n+"="+Math.round(performance.now()-t0));if(n=="loadeddata"&&C===null)C=v.currentTime;})});
var M="%s";function A(){var k=v.textTracks[0];if(!k)return;if(M=="hidden")k.mode="hidden";if(M=="disabled")k.mode="disabled";if(M=="seek-only"){k.mode="disabled";var span=Math.floor((performance.now()-t0+%d)/%d);if(span%%2==0&&span!=window.S){window.S=span;v.currentTime=v.currentTime+1;}}if(M=="disable-later")k.mode=performance.now()-t0<%f?"hidden":"disabled";if(M=="cycle"){var was=k.mode;k.mode=(Math.floor((performance.now()-t0+%d)/%d)%%2)?"disabled":"hidden";if(%s&&was!="hidden"&&k.mode=="hidden")v.currentTime=v.currentTime+1;}}
v.textTracks.addEventListener("addtrack",A);v.textTracks.addEventListener("change",function(){T.push("mode-"+(v.textTracks[0]&&v.textTracks[0].mode)+"="+Math.round(performance.now()-t0))});setInterval(A,200);
v.src="/master.m3u8";v.play();
setInterval(function(){P.push([Math.round(performance.now()-t0),v.currentTime]);var k=v.textTracks[0];Q.push([v.currentTime,k&&k.activeCues&&k.activeCues.length?k.activeCues[0].text:null])},250);
if(M=="fault-reenable")setInterval(function(){var k=v.textTracks[0],c=v.currentTime;if(k)k.mode=c<%f||(c>=%f&&c<%f)||c>=%f?"hidden":"disabled"},100);
if(M=="rapid-toggle")(function tick(){var k=v.textTracks[0];if(performance.now()-t0<%f){if(k)k.mode=k.mode=="hidden"?"disabled":"hidden";setTimeout(tick,50+Math.random()*250)}else{if(k)k.mode="hidden";setTimeout(tick,300)}})();
</script>''' % (args.text_mode, args.cycle_offset_ms, args.cycle_ms, args.disable_at * 1000, args.cycle_offset_ms, args.cycle_ms, 'true' if args.seek_on_show else 'false', FAULT_START - 2, FAULT_START + 1, FAULT_END + 2, FAULT_END + 4, args.rapid_seconds * 1000)).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def reply(self, body, kind='application/vnd.apple.mpegurl', status=200):
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global started
        path = self.path.split('?')[0]
        requests.append((time.monotonic(), path))
        started = started or time.monotonic()
        if path == '/':
            return self.reply(PAGE, 'text/html')
        if path == '/master.m3u8':
            if args.no_subtitles:
                return self.reply(b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="mp4a.40.2,avc1.42C01E"\n/video.m3u8\n')
            return self.reply(('#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",LANGUAGE="en",NAME="s",DEFAULT=NO,AUTOSELECT=YES,URI="/subs.m3u8"\n'
                               '#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="mp4a.40.2,avc1.42C01E",SUBTITLES="s"\n/video.m3u8\n').encode())
        if path == '/key':
            return self.reply(KEY, 'application/octet-stream')
        if path == '/video.m3u8':
            return self.reply(media_playlist('video').encode())
        if path == '/subs.m3u8':
            time.sleep(args.subtitle_playlist_delay)
            elapsed = time.monotonic() - started
            if (args.mode == 'playlist-missing' and (args.playlist_recovers_at is None or elapsed < args.playlist_recovers_at)) or (args.mode == 'playlist-missing-later' and elapsed > 10):
                return self.reply(b'', 'text/plain', 404)
            return self.reply(media_playlist('subs').encode())
        kind, _, number = path[1:].partition('-')
        if kind == 'video':
            if int(number) == FAULT and args.fault_video and args.mode == 'missing':
                return self.reply(b'', 'text/plain', 404)
            if int(number) == FAULT and args.fault_video and args.mode == 'late':
                time.sleep(args.delay)
            if args.encrypt:
                return self.reply(encrypted_segment(int(number)), 'video/mp2t')
            return self.reply(segments[int(number)][1].read_bytes(), 'video/mp2t')
        if kind == 'subs':
            if int(number) == FAULT and args.mode == 'late' and not args.fault_video:
                time.sleep(args.delay)
            if int(number) == FAULT and args.mode == 'missing' and not args.fault_video:
                return self.reply(b'', 'text/plain', 404)
            if args.mode == 'first-missing' and not any(path_.startswith('/subs-') for _, path_ in requests[:-1]):
                return self.reply(b'', 'text/plain', 404)
            if args.mode == 'all-missing':
                return self.reply(b'', 'text/plain', 404)
            if args.encrypt_subtitles:
                return self.reply(encrypted_segment(int(number)), 'text/vtt')
            return self.reply(cues(int(number)).encode(), 'text/vtt')
        self.reply(b'', 'text/plain', 404)


threading.Thread(target=http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever, daemon=True).start()


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=30).decode().strip()


# The network cache loads what an earlier visit to the same URL used, so each run has its own.
PAGE_URL = 'http://127.0.0.1:%d/%s' % (args.port, '' if args.stable_url else '?run=%d' % os.getpid())


def web_content_crashes():
    return sum(1 for item in (pathlib.Path.home() / 'Library/Logs/DiagnosticReports').glob('*WebContent*'))


crashes_before = web_content_crashes()
for iteration in range(args.teardown_stress):
    started = None
    osa('tell application "Safari" to make new document with properties {URL:"%s"}' % PAGE_URL)
    stress_window = osa('tell application "Safari" to get id of front window')
    time.sleep(1 + (iteration % 5) * .6)
    if iteration % 2:
        osa('tell application "Safari" to set URL of current tab of window id %s to "about:blank"' % stress_window)
        time.sleep(1)
    osa('tell application "Safari" to close window id ' + stress_window)
if args.teardown_stress:
    started = None
    requests.clear()

osa('tell application "Safari" to make new document with properties {URL:"%s"}' % PAGE_URL)
window = osa('tell application "Safari" to get id of front window')


def js(script):
    try:
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)
    except subprocess.TimeoutExpired:
        # A page that stops answering is sampled while it is still stuck.
        pids = subprocess.run(['pgrep', '-f', 'com.apple.WebKit.WebContent'], stdout=subprocess.PIPE).stdout.decode().split()
        for pid in pids + subprocess.run(['pgrep', '-x', 'Safari'], stdout=subprocess.PIPE).stdout.decode().split():
            subprocess.call(['sample', pid, '3', '-file', '/tmp/check-hls-live-webvtt-hang-%s.txt' % pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise


time.sleep(args.seconds)
state = json.loads(js('JSON.stringify({T:T,P:P,Q:Q,C:C,r:v.readyState,m:v.textTracks[0]&&v.textTracks[0].mode,e:v.error&&v.error.message,t:v.currentTime,cues:v.textTracks[0]&&v.textTracks[0].cues?Array.from(v.textTracks[0].cues).map(function(c){return [c.startTime,c.endTime,c.text]}):null})'))
osa('tell application "Safari" to close window id ' + window)

metadata = next((int(item.split('=')[1]) for item in state['T'] if item.startswith('loadedmetadata')), None)
playing = next((int(item.split('=')[1]) for item in state['T'] if item.startswith('playing')), None)
ended = next((int(item.split('=')[1]) for item in state['T'] if item.startswith('ended')), None)
longest, last_time, moved = 0, None, None
assert all(position is not None for _, position in state['P']) and state['t'] is not None, 'currentTime was not finite'
frozen_at = None
for at, position in state['P']:
    # Audio and video have run out at the end of the media, whatever the text is doing.
    if playing is None or at < playing or (ended is not None and at >= ended) or position >= sum(duration for duration, _ in segments) - 1:
        continue
    if last_time is None or position != last_time:
        last_time, moved = position, at
    if at - moved > longest:
        longest, frozen_at = at - moved, moved
requested = sorted(int(path.split('-')[1]) for _, path in requests if path.startswith('/subs-'))
waiting = [int(item.split('=')[1]) for item in state['T'] if item.startswith('waiting')]
print(json.dumps({'all_cues': [(round(c[0], 2), c[2]) for c in (state['cues'] or [])]}), flush=True)
print(json.dumps({'mode': args.mode, 'text_mode': state.get('m'), 'events': state['T'], 'metadata_ms': metadata, 'longest_stall_ms': longest, 'frozen_at': frozen_at, 'position': state['t'],
                  'first_frame_time': state['C'], 'cues': (state['cues'] or [])[:3], 'cue_count': len(state['cues'] or []),
                  'subtitle_requests': requested, 'error': state['e']}), flush=True)

assert metadata is not None and metadata < 5000, 'No metadata in time'
assert web_content_crashes() == crashes_before, 'WebContent crashed'
if args.bad_padding is not None and not args.encrypt_subtitles:
    # The demuxer reaches the fragment ahead of playback, and its error ends playback there.
    last_played = max(position for _, position in state['P'])
    assert last_played > 0, 'Nothing played before the bad fragment'
    assert last_played < segments[0][0] * (FAULT + 1), ('The bad fragment was accepted', last_played)
    assert state['e'] is not None, 'The refused fragment reported no error'
    print('PASS bad padding 0x%02x refused, last position %s, error %s' % (args.bad_padding, last_played, state['e']), flush=True)
    raise SystemExit(0)
if args.stable_url:
    first = next(path for _, path in requests if path not in ['/', '/favicon.ico'])
    assert first == '/master.m3u8', ('Fetched before the master playlist', [path for _, path in requests][:8])
if args.expect_no_subtitles:
    assert state.get('m') == 'disabled', ('Preferences enabled the track', state.get('m'))
    assert not requested, ('A track the preferences leave disabled fetched subtitles', requested)
    assert not any(path == '/subs.m3u8' for _, path in requests), 'A track the preferences leave disabled fetched its playlist'
if args.fault_video and args.mode == 'missing':
    assert state['e'] is not None, 'A missing video fragment is an error'
    print('PASS live WebVTT missing video fragment', flush=True)
    raise SystemExit(0)
assert state['e'] is None, state['e']
if args.text_mode == 'disabled':
    # Caption preferences can enable the track until the page's first change reaches it.
    late_requests = [path for at, path in requests if path.startswith('/subs-') and at - started > 5]
    assert not late_requests, ('A disabled track kept fetching subtitles', late_requests)
    assert not state['cues'], ('A disabled track received cues', state['cues'])
elif args.mode not in ['first-missing', 'all-missing', 'playlist-missing', 'playlist-missing-later'] and args.subtitles_end_at is None and state.get('m') != 'disabled' and args.cycle_ms >= 6000 and args.text_mode != 'rapid-toggle':
    assert state['cues'] or args.no_subtitles, 'No cues reached the track'
if args.text_mode == 'cycle':
    indexes = [int(cue[2].split()[1]) for cue in state['cues'] or []]
    if not args.seek_on_show and args.mode == 'normal' and args.bad_padding is None and args.cycle_ms >= 6000:
        # A fragment that starts while the track is hidden reaches it.
        starts = [(index, segments[0][0] * index) for index in range(len(segments))]
        expected = [index for index, start in starts if int((start * 1000 + args.cycle_offset_ms) // args.cycle_ms) % 2 == 0 and start + 2 < state['t']]
        assert set(expected) <= set(indexes), ('Captions did not come back', expected, indexes)
for cue in state['cues'] or []:
    index = int(cue[2].split()[1])
    assert abs(cue[0] - sum(duration for duration, _ in segments[:index])) < .5, ('Mistimed cue', cue)
if state['cues']:
    first = state['cues'][0]
    match = re.match(r'segment (\d+)', first[2])
    assert match, first
    assert abs(first[1] - first[0] - segments[int(match.group(1))][0]) < .1, first
    if state['C'] is not None and int(match.group(1)) == min(requested) and not args.seek_on_show and args.mode == 'normal':
        assert abs(first[0] - state['C']) < .5, ('Cue and picture differ', first[0], state['C'])
if args.subtitle_sequence_jump_at is not None:
    indexes = [int(cue[2].split()[1]) for cue in state['cues'] or []]
    assert indexes and segments[0][0] * max(indexes) > args.subtitle_sequence_jump_at + segments[0][0], ('Cues did not resume', indexes)
    assert longest < 2000, ('The subtitle playlist stalled playback', longest)
    assert not [position for at, position in state['P'] if playing is not None and position > (at - playing) / 1000 + 2], 'The subtitle playlist moved playback'
if ended is not None:
    last_position = max(position for _, position in state['P'])
    print('ended', ended - next(at for at, position in state['P'] if position >= last_position - .05), 'ms after the last position', flush=True)
if args.mode == 'late' and not args.fault_video and not args.no_endlist and args.seconds >= sum(duration for duration, _ in segments) + 3:
    # A subtitle fragment still out does not keep the element from ending with audio and video.
    assert ended is not None, ('Never ended', state['T'])
    last_position = max(position for _, position in state['P'])
    reached = next(at for at, position in state['P'] if position >= last_position - .05)
    assert args.ended_baseline_ms is None or ended - reached < args.ended_baseline_ms + 500, ('Ended later than without text', ended - reached, args.ended_baseline_ms)
if args.mode == 'playlist-missing' and args.text_mode != 'cycle':
    playlist_requests = sum(1 for _, path in requests if path == '/subs.m3u8')
    assert playlist_requests <= 8, ('The abandoned playlist kept being polled', playlist_requests)
if args.mode == 'playlist-missing' and args.playlist_recovers_at is not None:
    assert any(cue[0] > args.playlist_recovers_at for cue in state['cues'] or []), ('Captions did not recover', state['cues'])
if args.mode == 'all-missing':
    assert len(requested) <= 16, ('The abandoned fragments kept being fetched', len(requested))
if args.text_mode == 'disable-later':
    after = [position for at, position in state['P'] if at > args.disable_at * 1000 + 1000]
    assert after and after[-1] - after[0] > .8 * (args.seconds - args.disable_at - 2), ('Disabling the ended track stalled playback', after[:3], after[-3:])
    assert state.get('m') == 'disabled', state.get('m')
if args.text_mode == 'cycle' and args.cycle_ms > 6000:
    # A span with captions off longer than the live window still brings them back.
    indexes = [int(cue[2].split()[1]) for cue in state['cues'] or []]
    assert indexes and segments[0][0] * max(indexes) > 2 * args.cycle_ms / 1000 - segments[0][0], ('Captions did not come back', indexes)
if args.mode == 'normal' and args.text_mode == 'hidden' and not args.no_subtitles and args.subtitles_end_at is None and args.bad_padding is None:
    # What the track shows at each moment of playback is the cue for that moment.
    starts = [sum(duration for duration, _ in segments[:index]) for index in range(len(segments))]
    checked = 0
    for position, active in state['Q']:
        index = next((i for i, start in enumerate(starts) if start + .3 <= position < start + segments[i][0] - .3), None)
        if index is not None:
            checked += 1
            assert active == 'segment %d' % index, ('Wrong cue on screen', position, active)
    assert checked > 0, 'No cue timing samples'
if args.text_mode == 'rapid-toggle':
    # Toggling does not leave the track dead, and nothing stalls.
    indexes = [int(cue[2].split()[1]) for cue in state['cues'] or []]
    assert indexes and segments[0][0] * max(indexes) >= args.rapid_seconds, ('Captions did not survive toggling', indexes)
    assert longest < 2000, ('Toggling stalled playback', longest)
if args.bad_padding is not None and args.encrypt_subtitles:
    # Bad subtitles end only the subtitles, and enabling the track again restarts them.
    assert state['e'] is None, state['e']
    assert longest < 2000, longest
    if args.text_mode == 'cycle':
        # A selection made inside the bad fragment meets it again, so this needs one after it.
        assert args.seconds * 1000 >= (FAULT + 1) * segments[0][0] * 1000 + 2 * args.cycle_ms, 'Run too short to select past the bad fragment'
        indexes = [int(cue[2].split()[1]) for cue in state['cues'] or []]
        assert FAULT - 1 in indexes, ('Text before the bad fragment was lost', state['cues'])
        assert indexes and max(indexes) > FAULT, ('Text did not restart', state['cues'])
if args.text_mode == 'fault-reenable':
    # A selection inside the bad fragment ends the text until the next selection, which brings it back.
    active = [(position, cue) for position, cue in state['Q'] if cue]
    assert not [cue for position, cue in active if FAULT_END + .3 <= position < FAULT_END + 1.7], ('The selection was not inside the bad fragment', active)
    assert [cue for position, cue in active if position >= FAULT_END + 4.5 and int(cue.split()[1]) > FAULT], ('Text did not return on the next selection', active)
if args.mode == 'normal' and args.text_mode not in ['cycle', 'disable-later']:
    assert longest < 2000, longest
    assert playing is not None and playing < 3000, ('Slow start', playing)
elif args.text_mode == 'cycle':
    # A selected track with a failing playlist is dry until the stream gives up on it.
    assert longest < 2000, ('Selection change stalled playback', longest)
    # A seek to the live head runs ahead of the time elapsed. Catching up after a stall does not.
    jumps = [(at, position) for at, position in state['P'] if playing is not None and position > (at - playing) / 1000 + (8 if args.seek_on_show else 2)]
    assert not jumps, ('Selection change moved playback', jumps[:3])
elif args.mode == 'late':
    assert args.fault_video or FAULT in requested, requested
    assert args.fault_video or longest < 2000, ('A late subtitle fragment stalled playback', longest)
    assert longest < args.delay * 1000 + 3000, longest
    if longest >= 1000:
        # A dry track is an ordinary buffering stall: the element is waiting by the time the picture freezes.
        states = [(int(item.split('=')[1]), item.split('=')[0]) for item in state['T'] if item.split('=')[0] in ['waiting', 'playing']]
        assert [name for at, name in states if at <= frozen_at + 1000][-1] == 'waiting', ('Silent stall', frozen_at, states)
assert state['P'][-1][1] > state['P'][len(state['P']) // 2][1], 'Playback did not continue'
assert web_content_crashes() == crashes_before, 'WebContent crashed'
print('PASS live WebVTT ' + args.mode, flush=True)
