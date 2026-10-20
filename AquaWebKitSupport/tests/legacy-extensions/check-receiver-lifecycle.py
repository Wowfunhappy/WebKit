#!/usr/bin/env python3
"""Exercise generic receiver readiness, metadata loss and source detachment."""
import argparse
import json
import pathlib
import subprocess
import time

rig = pathlib.Path(__file__).resolve().parent
control = rig / 'build/media-receiver-control.json'
log = rig / 'build/media-receiver.jsonl'
controls = {
    'delayed-ready': {'readyAfter': 8},
    'startup-timeout': {'readyAfter': 60},
    'delayed-file-timeout': {'fileAfter': 35},
    'delayed-file': {'fileAfter': 8},
    'delayed-query': {'queryAfter': 8},
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
url = 'http://127.0.0.1:8843/quicktime.html?source=plain.mp4&adapter=fixture&test=' + str(time.time_ns())
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
if case == 'cancel-query':
    wait(lambda: any(json.loads(line).get('querySleeping') for line in records()[before:]))
    js('video.src="/quicktime-media/plain.mp4?cancelled=1";video.load()')
reply = result()
print('OPEN', case, round(time.monotonic() - started, 2), reply, flush=True)
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
if case != 'source-change':
    wait(lambda: js('!video.paused') == 'true', 15)
osa('tell application "Safari" to close current tab of window id ' + window_id)
osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
configure({})
print('PASS', case, flush=True)
