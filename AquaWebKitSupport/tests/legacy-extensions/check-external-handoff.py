#!/usr/bin/env python3
"""Exercise URL transfer, receiver seeking, MSE preservation and return to Safari."""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('source', nargs='?', default='mse.mp4&airplay=valid')
parser.add_argument('--expect', choices=['url', 'restream'], default='url')
parser.add_argument('--repeat', action='store_true')
parser.add_argument('--paused', action='store_true')
parser.add_argument('--reload-extension', action='store_true')
parser.add_argument('--closed-receiver', action='store_true')
parser.add_argument('--different-target', action='store_true')
parser.add_argument('--close-tab', action='store_true')
parser.add_argument('--close-pending', action='store_true')
parser.add_argument('--cancel-pending', action='store_true')
parser.add_argument('--without-controls', action='store_true')
args = parser.parse_args()
rig = pathlib.Path(__file__).resolve().parent
out = rig / 'build' / 'external-handoff'
out.mkdir(exist_ok=True)

def osa(script):
    return subprocess.check_output(['osascript', '-e', script], stderr=subprocess.DEVNULL).decode().strip()

def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of front window')

def wait(check, seconds=90):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timed out')

def windows():
    if subprocess.run(["pgrep", "-x", "QuickTime Player"], stdout=subprocess.DEVNULL).returncode:
        return set()
    text = osa('''tell application "QuickTime Player"
        set resultIDs to {}
        repeat with receiverWindow in every window
            set hasDocument to true
            try
                set hasDocument to (document of receiverWindow is not missing value)
            end try
            if hasDocument then set end of resultIDs to id of receiverWindow
        end repeat
        return resultIDs
    end tell''')
    return {int(value.strip()) for value in text.split(',') if value.strip()}

safari_pid = subprocess.check_output(['pgrep', '-x', 'Safari']).strip()
baseline = windows()
print('Existing receiver windows', sorted(baseline), flush=True)
url = 'http://127.0.0.1:8843/quicktime.html?source=' + args.source
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
def prepare_source():
    wait(lambda: js('Boolean(document.querySelector("video")?.readyState >= 2 && document.querySelector("#open-media-player"))') == 'true')
    if args.without_controls:
        js('video.controls=false;window.handoffControlsStyle=document.createElement("style");handoffControlsStyle.textContent="video:not([controls])::-webkit-media-controls{display:none}";document.head.appendChild(handoffControlsStyle)')
    js('video.currentTime=10;' + ('' if args.paused else 'video.play()'))
    wait(lambda: js('!video.seeking && video.currentTime >= 10 && video.paused === ' + ('true' if args.paused else 'false')) == 'true')
    js('window.savedMedia=window.handoffMedia; window.savedBuffers=window.handoffMedia?.sourceBuffers.length; window.events=[]; ["seeking","seeked","pause","play","volumechange"].forEach(n=>video.addEventListener(n,()=>events.push(n)))')

prepare_source()

def handoff(allow_missing=False):
    js('document.querySelector("#open-media-player").click()')
    if args.close_pending or args.cancel_pending:
        wait(lambda: js('video.paused && document.querySelector("#media-player-result").textContent === "pending"') == 'true')
        if args.close_pending:
            osa('tell application "Safari" to close current tab of front window')
            return None
        js('video.src="/quicktime-media/plain.mp4?cancelled=1";video.load()')
    value = wait(lambda: (lambda s: s if s.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')))
    value = json.loads(value)
    print('handoff', value, flush=True)
    if args.cancel_pending:
        assert value.get('error') == 'no-source', value
        wait(lambda: windows() == baseline)
        osa('tell application "Safari" to close current tab of front window')
        print('PASS cancellation', flush=True)
        raise SystemExit(0)
    if allow_missing and value.get('error') == 'no-source':
        return None
    assert value.get('method') == args.expect, value
    assert value.get('coalesced') == (2 if 'coalesce' in args.source else 1), value
    return value

result = handoff()
if args.closed_receiver:
    initial = wait(lambda: windows() - baseline)
    assert len(initial) == 1, initial
    closed_window = next(iter(initial))
    osa('tell application "QuickTime Player" to close document of window id ' + str(closed_window) + ' saving no')
    result = handoff(allow_missing=True)
    if result is None:
        result = handoff()
    replacement = wait(lambda: windows() - baseline)
    assert len(replacement) == 1 and closed_window not in replacement, replacement
    print('Closed receiver is not reported as a successful reactivation', flush=True)
if args.repeat or args.reload_extension:
    original = result
    original_windows = windows()
    page_reloaded = False
    if args.reload_extension:
        js('window.handoffReloadSentinel=true;document.querySelector("#media-player-test").dataset.beforeReload="true"')
        subprocess.run(['osascript', str(rig / 'reload-media-extensions.applescript')], check=True)
        wait(lambda: js('Boolean(document.querySelector("#media-player-test") && !document.querySelector("#media-player-test").dataset.beforeReload)') == 'true')
        page_reloaded = js('window.handoffReloadSentinel === true') != 'true'
        if page_reloaded:
            wait(lambda: windows() == baseline)
            prepare_source()
            print('Extension Builder reloaded the page and released its receiver', flush=True)
    result = handoff()
    if page_reloaded:
        assert len(windows() - baseline) == 1 and not ((windows() - baseline) & (original_windows - baseline))
    else:
        assert result == original and windows() == original_windows, (original, result)
if args.different_target:
    original_windows = windows()
    js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click()')
    rejection = wait(lambda: (lambda s: s if s.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent')))
    assert json.loads(rejection).get('error') == 'application-busy', rejection
    assert windows() == original_windows
    print('Different target preserves the existing handoff', flush=True)
owned = wait(lambda: windows() - baseline)
assert len(owned) == 1, owned
window = next(iter(owned))
movie = 'document of window id ' + str(window)

def qt(command):
    return osa('tell application "QuickTime Player" to ' + command.replace('MOVIE', movie))

if args.close_pending:
    def receiver_started():
        try:
            return float(qt('get current time of MOVIE')) > 8
        except (subprocess.CalledProcessError, ValueError):
            return False
    wait(receiver_started)
    print('Receiver starts and plays after closing the tab during handoff', flush=True)
elif args.expect == 'url':
    assert js('video.paused') == 'true'
    assert js('!window.savedMedia || (savedMedia===handoffMedia && savedBuffers===handoffMedia.sourceBuffers.length && handoffMedia.readyState!=="closed")') == 'true'
    if args.source.startswith('plain.mp4'):
        assert float(qt('get current time of MOVIE')) >= 9.5, 'Original URL lost its starting position'
    if args.paused:
        assert qt('get playing of MOVIE') == 'false'
    seek = min(30, float(qt('get duration of MOVIE')) / 2)
    qt('set current time of MOVIE to ' + str(seek))
    qt('play MOVIE')
    wait(lambda: float(qt('get current time of MOVIE')) > seek + 2)
    assert float(js('video.currentTime')) < 15
    print('Receiver seek/play works while original MSE producer stays attached and paused', flush=True)
else:
    assert js('!video.paused') == 'true'
    events = json.loads(js('JSON.stringify(events)'))
    assert events == (['pause', 'play'] if 'airplay=invalid' in args.source else []), events
    wait(lambda: float(qt('get current time of MOVIE')) > 2)
if not args.close_pending:
    if args.without_controls:
        js('window.extraCaptions=video.addTextTrack("captions","Placard check","en");extraCaptions.mode="showing";extraCaptions.addCue(new VTTCue(0,120,"Caption beneath external presentation"))')
        assert js('video.controls') == 'false'
    canvas = js('''(()=>{const c=document.createElement('canvas');c.width=32;c.height=18;
        const x=c.getContext('2d');x.drawImage(video,0,0,32,18);
        return JSON.stringify({pixels:Array.from(x.getImageData(0,0,32,18).data).filter((v,i)=>i%4!==3).reduce((a,b)=>a+b,0),pattern:!!x.createPattern(video,'repeat')});})()''')
    canvas = json.loads(canvas)
    assert canvas['pixels'] > 0 and canvas['pattern'], canvas
    print('Canvas frame reads and video patterns remain available', canvas, flush=True)
    osa('tell application "Safari" to activate')
    subprocess.run(['/usr/sbin/screencapture', '-x', str(out / 'inline-placard.png')], check=True)
if args.close_tab:
    before = float(qt('get current time of MOVIE'))
    osa('tell application "Safari" to close current tab of front window')
    wait(lambda: float(qt('get current time of MOVIE')) > before + 8)
    print('Receiver continues after source tab closure', flush=True)
qt('close MOVIE saving no')
wait(lambda: window not in windows())
if not args.close_tab and not args.close_pending:
    if args.paused:
        time.sleep(3)
        assert js('video.paused') == 'true'
    else:
        wait(lambda: js('!video.paused') == 'true')
        before = float(js('video.currentTime'))
        wait(lambda: float(js('video.currentTime')) > before + 1)
    if args.without_controls:
        js('handoffControlsStyle.remove()')
    osa('tell application "Safari" to activate')
    subprocess.run(['/usr/sbin/screencapture', '-x', str(out / 'inline-restored.png')], check=True)
    print('Inline presentation and playback restored', flush=True)
    osa('tell application "Safari" to close current tab of front window')
if args.close_pending:
    time.sleep(3)
    osa('tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:8843/quicktime.html?source=plain.mp4"}')
    wait(lambda: js('Boolean(document.querySelector("video")?.readyState >= 2)') == 'true')
    js('video.addEventListener("webkitplaybacktargetavailabilitychanged",()=>{})')
    time.sleep(.5)
    assert subprocess.check_output(['pgrep', '-x', 'Safari']).strip() == safari_pid
    osa('tell application "Safari" to close current tab of front window')
    print('Fresh AirPlay registration survives pending-handoff cleanup', flush=True)
print('PASS', flush=True)
