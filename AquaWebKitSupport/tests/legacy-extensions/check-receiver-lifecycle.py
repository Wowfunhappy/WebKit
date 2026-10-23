#!/usr/bin/env python3
"""Exercise generic receiver readiness, metadata loss and source detachment."""
import argparse
import json
import pathlib
import subprocess
import time
import urllib.request
import urllib.error

rig = pathlib.Path(__file__).resolve().parent
control = rig / 'build/media-receiver-control.json'
log = rig / 'build/media-receiver.jsonl'
controls = {
    'primitives': {},
    'resources': {},
    'resources-navigation': {},
    'resources-unload': {},
    'resources-closed-session': {},
    'delayed-ready': {'readyAfter': 8},
    'startup-timeout': {'readyAfter': 60},
    'delayed-file-timeout': {'fileAfter': 35},
    'delayed-file': {'fileAfter': 8},
    'delayed-query': {'queryAfter': 8},
    'independent-route': {'duration': 'indefinite'},
    'independent-recording': {},
    'independent-native-source': {},
    'independent-invalid-option': {},
    'independent-delayed-start': {'duration': 'indefinite', 'readyAfter': 3},
    'independent-setup': {},
    'independent-disable': {},
    'independent-close': {},
    'independent-invalid-timeout': {},
    'query-timeout': {'queryAfter': 60},
    'cancel-query': {'querySleep': 8},
    'missing-file': {},
    'transient-window-list': {},
    'closed-document': {},
    'source-change': {},
    'application-exit': {},
}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('case', choices=controls)
case = parser.parse_args().case


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40).decode().strip()


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timeout')


def configure(value):
    control.write_text(json.dumps(value))


def records():
    return log.read_text().splitlines() if log.exists() else []


configure(controls[case])
subprocess.run(['osascript', '-e', 'tell application id "org.aqua.webkit.media-handoff-receiver" to quit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
source = 'plain.mp4'
if case.startswith('independent-'):
    source = 'mse.mp4&airplay=route&routeReload=0&synchronize=' + ('%22false%22' if case == 'independent-invalid-option' else 'false')
    if case == 'independent-native-source':
        source += '&disconnect=none'
    if case == 'independent-setup':
        source += '&routeSetupTimeout=3'
    if case == 'independent-invalid-timeout':
        source += '&routeSetupTimeout=-1'
url = 'http://127.0.0.1:8843/quicktime.html?source=' + source + '&adapter=fixture&test=' + str(time.time_ns())
if case == 'primitives' or case.startswith('resources'):
    url += '&primitives=1'
if case == 'resources':
    url += '&resources=1'
if case in ('resources-navigation', 'resources-unload'):
    url += '&resourceLifetime=1'
if case == 'resources-closed-session':
    url += '&resourceLifetime=closed'
osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
window_id = osa('tell application "Safari" to get id of front window')


def js(script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window_id)


def result():
    return json.loads(wait(lambda: (lambda text: text if text.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))


wait(lambda: js('Boolean(document.querySelector("#video")?.readyState>=2&&document.querySelector("#open-media-player"))') == 'true')
js('video.play()')
wait(lambda: float(js('video.currentTime')) > .5)
started = time.monotonic()
before = len(records())
js('document.querySelector("#target-application").value="org.aqua.webkit.media-handoff-receiver";document.querySelector("#open-media-player").click()')
if case == 'resources':
    resource = wait(lambda: js('document.querySelector("#media-player-result").dataset.resource'))
    root = js('document.querySelector("#media-player-result").dataset.root')
    assert urllib.request.urlopen(resource, timeout=10).read() == b'abcdef'
    response = urllib.request.urlopen(urllib.request.Request(resource, headers={'Range': 'bytes=2-4'}), timeout=10)
    assert response.status == 206 and response.headers['Content-Range'] == 'bytes 2-4/6' and response.read() == b'cde'
    assert b'#STATIC' in urllib.request.urlopen(root, timeout=10).read()
    js('document.dispatchEvent(new Event("resource-next"));true')
    wait(lambda: js('document.querySelector("#media-player-result").dataset.provider') == 'ready')
    assert urllib.request.urlopen(resource, timeout=10).read() == b'123456'
    response = urllib.request.urlopen(urllib.request.Request(root, headers={'Range': 'bytes=0-6'}), timeout=10)
    assert response.status == 206 and response.read() == b'#EXTM3U'
    assert b'index.m3u8?probe=1' in urllib.request.urlopen(root + '?probe=1', timeout=10).read()
    pending_url = resource.rsplit('/', 1)[0] + '/pending.m3u8'
    began = time.monotonic()
    try:
        urllib.request.urlopen(pending_url, timeout=5)
        raise AssertionError('An unanswered provider request succeeded')
    except urllib.error.HTTPError as error:
        assert error.code == 404
    assert time.monotonic() - began < 3
    js('document.dispatchEvent(new Event("resource-finish"));true')
    wait(lambda: js('document.querySelector("#media-player-result").dataset.removed') == 'yes')
    try:
        urllib.request.urlopen(resource, timeout=5)
        raise AssertionError('Removed resource remained readable')
    except urllib.error.HTTPError as error:
        assert error.code == 404
    js('document.dispatchEvent(new Event("resource-close"));true')
if case == 'independent-delayed-start':
    wait(lambda: any('open' in json.loads(line) for line in records()[before:]))
    old_source = js('video.currentSrc')
    js('window.replaceHandoffSource();true')
    wait(lambda: js('video.currentSrc !== ' + json.dumps(old_source) + ' && video.readyState>=2 && !video.seeking') == 'true')
    js('video.play()')
    wait(lambda: js('!video.paused') == 'true')
if case == 'cancel-query':
    wait(lambda: any(json.loads(line).get('querySleeping') for line in records()[before:]))
    js('video.src="/quicktime-media/plain.mp4?cancelled=1";video.load()')
reply = result()
print('OPEN', case, round(time.monotonic() - started, 2), reply, flush=True)
if case == 'resources-closed-session':
    osa('tell application "Safari" to close current tab of window id ' + window_id)
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    configure({})
    assert reply.get('method') == 'closed-session' and reply['errors'] == ['no-source', 'no-source'], reply
    assert reply['retainedState']['rate'] == 0, reply
    print('PASS independent receiver survives session close; new dependent resources reject', flush=True)
    raise SystemExit(0)
if case in ('resources-navigation', 'resources-unload'):
    assert reply.get('method') == 'resource-lifetime', reply
    assert b'#LIFETIME:index.m3u8' in urllib.request.urlopen(reply['url'], timeout=5).read()
    if case == 'resources-navigation':
        osa('tell application "Safari" to set URL of current tab of window id ' + window_id + ' to "http://127.0.0.1:8843/quicktime.html?source=plain.mp4&navigated=1"')
    else:
        subprocess.run(['osascript', str(rig/'reload-media-extensions.applescript')], check=True)

    def revoked():
        try:
            urllib.request.urlopen(reply['url'], timeout=5)
            return False
        except (urllib.error.HTTPError, urllib.error.URLError, ConnectionError):
            return True

    wait(revoked, 10)
    wait(lambda: any('close' in json.loads(line) for line in records()[before:]), 10)
    osa('tell application "Safari" to close current tab of window id ' + window_id)
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    configure({})
    print('PASS publisher revocation and receiver cleanup on ' + case.removeprefix('resources-'), flush=True)
    raise SystemExit(0)
if case in ('primitives', 'resources'):
    assert reply.get('method') == 'primitives', reply
    assert reply['opened']['rate'] == 0 and reply['playing']['rate'] == 1 and reply['paused']['rate'] == 0, reply
    assert abs(reply['paused']['position'] - 4) < .1 and not reply['pagePaused'], reply
    assert reply['errors'] == ['unsupported-source', 'unsupported-source', 'application-unavailable'], reply
    entries = [json.loads(line) for line in records()[before:]]
    assert len([entry for entry in entries if 'open' in entry]) == 1, entries
    assert not any('rateSet' in entry for entry in entries), entries
    assert len([entry for entry in entries if 'play' in entry]) == 1, entries
    assert len([entry for entry in entries if 'pause' in entry]) == 1, entries
    osa('tell application "Safari" to close current tab of window id ' + window_id)
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    configure({})
    print('PASS explicit source/player primitives; no implicit transport commands', flush=True)
    raise SystemExit(0)
if case in ('independent-invalid-option', 'independent-invalid-timeout'):
    expected = 'synchronize must be a boolean' if case == 'independent-invalid-option' else 'routeSetupTimeout must be a finite nonnegative number of seconds'
    assert reply.get('error') == expected, reply
    assert not any('open' in json.loads(line) for line in records()[before:])
    osa('tell application "Safari" to close current tab of window id ' + window_id)
    configure({})
    print('PASS invalid synchronization option', flush=True)
    raise SystemExit(0)
if case == 'cancel-query':
    assert reply.get('error') == 'no-source', reply
    time.sleep(10)
    assert not any('open' in json.loads(line) for line in records()[before:]), 'Cancelled preflight opened a late receiver'
    configure({})
    js('video.play()')
    wait(lambda: js('!video.paused&&video.readyState>=2') == 'true')
    js('document.querySelector("#open-media-player").click()')
    reply = result()
    print('REOPEN_AFTER_CANCELLATION', reply, flush=True)
if case in ('startup-timeout', 'delayed-file-timeout', 'query-timeout'):
    expected = 'application-timeout' if case == 'query-timeout' else 'application-start-uncertain'
    assert reply.get('error') == expected, reply
    if case == 'query-timeout':
        assert not any('open' in json.loads(line) for line in records()[before:]), 'Receiver opened before it could be queried'
    else:
        wait(lambda: any('close' in json.loads(line) for line in records()[before:]), 15)
    configure({})
    js('video.play()')
    wait(lambda: js('!video.paused') == 'true', 15)
    js('document.querySelector("#open-media-player").click()')
    reply = result()
    print('REOPEN_AFTER_TIMEOUT', reply, flush=True)
assert reply.get('method') == 'url', reply
if case.startswith('independent-'):
    if case == 'independent-delayed-start':
        assert js('!video.paused && !video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    else:
        assert js('video.paused && video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    expected_scheme = 'blob:' if case == 'independent-delayed-start' else 'http:'
    assert js('video.currentSrc.startsWith(' + json.dumps(expected_scheme) + ')') == 'true'
    assert not any('seek' in json.loads(line) for line in records()[before:])
    assert not any('rateSet' in json.loads(line) for line in records()[before:])
    print('PASS independent URL delivery and paused local source after receiver acceptance', flush=True)
if case == 'independent-disable':
    js('video.disableRemotePlayback=true;true')
    wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless && video.remote.state === "disconnected"') == 'true')
    assert js('video.paused') == 'true'
    print('PASS page-requested disconnect leaves independent receiver open', flush=True)
if case == 'independent-setup':
    before_controls = len(records())
    js('window.setupEvents=[];["play","playing","pause","seeking","seeked","webkitcurrentplaybacktargetiswirelesschanged"].forEach(n=>video.addEventListener(n,()=>setupEvents.push(n)));video.play().catch(()=>{});true')
    wait(lambda: js('video.paused && setupEvents.includes("pause")') == 'true')
    assert js('video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    wait(lambda: js('video.readyState>=2') == 'true')
    js('video.currentTime=4;true')
    wait(lambda: js('!video.seeking && Math.abs(video.currentTime-4)<0.2') == 'true')
    assert js('video.paused && video.webkitCurrentPlaybackTargetIsWireless') == 'true'
    time.sleep(3)
    js('video.play().catch(()=>{});true')
    wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless && !video.paused && video.readyState>=2') == 'true')
    assert not any(any(key in json.loads(line) for key in ('seek', 'close', 'play', 'pause')) for line in records()[before_controls:]), records()[before_controls:]
    print('PASS setup play/pause, independent seek, and post-setup play/disconnect', js('JSON.stringify(setupEvents)'), flush=True)
if case == 'application-exit':
    osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    wait(lambda: js('!video.paused') == 'true', 15)
    js('document.querySelector("#open-media-player").click()')
    reply = result()
    print('REOPEN_AFTER_APPLICATION_EXIT', reply, flush=True)
    assert reply.get('method') == 'url', reply
if case == 'closed-document':
    before = len(records())
    configure({'documentMissing': True})
    wait(lambda: js('!video.paused') == 'true', 15)
    assert not any('close' in json.loads(line) for line in records()[before:]), 'Cleanup closed a window without the owned document'
    print('PASS document closure releases ownership without closing its window', flush=True)
if case == 'delayed-query':
    entries = [json.loads(line) for line in records()[before:]]
    assert any(entry.get('queryNotReady') for entry in entries)
    assert len([entry for entry in entries if 'open' in entry]) == 1, entries
    assert reply['url'] == js('video.currentSrc'), 'Readiness failure selected capture'
if case == 'missing-file':
    configure({'missingFile': True})
    time.sleep(8)
    assert js('video.paused') == 'true', 'Receiver metadata loss returned playback to the page'
    configure({})
    js('document.querySelector("#open-media-player").click()')
    reply = result()
    print('REACTIVATE', reply, flush=True)
    assert reply.get('method') == 'url', reply
if case == 'source-change':
    before = len(records())
    js('video.src="/quicktime-media/missing.mp4";video.load()')
    time.sleep(8)
    assert not any('close' in json.loads(line) for line in records()[before:]), 'Page source change closed the independent receiver'
    print('PASS accepted receiver survives source change', flush=True)
if case == 'transient-window-list':
    configure({'omitWindowList': True})
    time.sleep(8)
    assert js('video.paused') == 'true', 'A transient window-list omission released the receiver'
    assert not any('close' in json.loads(line) for line in records()[before:]), 'A transient window-list omission closed the receiver'
    configure({})
    print('PASS retained window identity survives transient omission from application window list', flush=True)
configure({'closed': True})
if case == 'independent-close':
    wait(lambda: js('!video.webkitCurrentPlaybackTargetIsWireless && video.remote.state === "disconnected"') == 'true', 15)
    assert js('video.paused') == 'true'
    print('PASS receiver closure disconnects without browser autoplay', flush=True)
if case != 'source-change' and not case.startswith('independent-'):
    wait(lambda: js('!video.paused') == 'true', 15)
osa('tell application "Safari" to close current tab of window id ' + window_id)
osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
configure({})
print('PASS', case, flush=True)
