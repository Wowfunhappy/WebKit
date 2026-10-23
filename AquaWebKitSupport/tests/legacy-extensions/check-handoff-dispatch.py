#!/usr/bin/env python3
"""Check host-to-content handoff ownership and single-use ticket boundaries."""
import json
import pathlib
import subprocess
import time
import urllib.parse
import urllib.request

rig = pathlib.Path(__file__).resolve().parent
control = rig / 'build/media-receiver-control.json'


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40).decode().strip()


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('Timed out')


def report(identifier, stage):
    with urllib.request.urlopen('http://127.0.0.1:8843/log', timeout=10) as response:
        records = json.load(response)
    for entry in records:
        if entry.get('path') != '/handoff-dispatch-report' or 'body' not in entry:
            continue
        value = json.loads(entry['body'])
        if value.get('id') == identifier and value.get('stage') in (stage, 'error'):
            return value


def javascript(window, script):
    return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)


def page(mode):
    identifier = str(time.time_ns())
    url = 'http://127.0.0.1:8843/quicktime.html?' + urllib.parse.urlencode(dict(source='plain.mp4', dispatchMode=mode, dispatchID=identifier))
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps(url) + '}')
    window = osa('tell application "Safari" to get id of front window')
    wait(lambda: javascript(window, 'Boolean(document.querySelector("#dispatch-media-player")&&video.readyState>=2)') == 'true')
    return window, identifier, url


def dispatch(window):
    javascript(window, 'document.querySelector("#dispatch-media-player").click()')


def close(window):
    osa('tell application "Safari" to close current tab of window id ' + window)


def complete(identifier, error=None):
    result = wait(lambda: report(identifier, 'complete'))
    assert result.get('error') == error, result
    print('RESULT', result, flush=True)
    return result


for mode in ('claim', 'cancel', 'replay', 'expired', 'close', 'busy-close'):
    control.write_text('{}')
    window, identifier, url = page(mode)
    print('CASE', mode, flush=True)
    dispatch(window)
    result = complete(identifier, 'no-source' if mode in ('cancel', 'replay', 'expired') else None)
    if mode in ('claim', 'replay'):
        assert result.get('value') == {'claimed': True}, result
    if mode.endswith('close'):
        assert result['value']['method'] == 'url', result
        assert window not in osa('tell application "Safari" to get id of every window').split(', ')
        control.write_text('{"closed":true}')
        osa('tell application id "org.aqua.webkit.media-handoff-receiver" to quit')
    else:
        close(window)
    print('PASS', mode, flush=True)

window, identifier, _ = page('port-close')
dispatch(window)
result = wait(lambda: report(identifier, 'port-roundtrip'))
assert result.get('absent') is True, result
wait(lambda: report(identifier, 'port-disconnected'))
wait(lambda: report(identifier, 'unloaded'))
assert window not in osa('tell application "Safari" to get id of every window').split(', ')
print('PASS existing ports exchange messages after tab closure and release with the handoff scope', flush=True)

window, identifier, url = page('store')
dispatch(window)
wait(lambda: report(identifier, 'stored'))
other, second, _ = page('use-stored')
dispatch(other)
complete(second, 'no-source')
close(other)
identifier = str(time.time_ns())
javascript(window, 'history.replaceState(null,"",' + json.dumps(url.replace('dispatchMode=store', 'dispatchMode=use-stored').rsplit('dispatchID=', 1)[0] + 'dispatchID=' + identifier) + ')')
dispatch(window)
assert complete(identifier)['value'] == {'claimed': True}
close(window)
print('PASS ticket belongs to its source tab', flush=True)

window, identifier, url = page('store')
dispatch(window)
wait(lambda: report(identifier, 'stored'))
identifier = str(time.time_ns())
url = url.replace('dispatchMode=store', 'dispatchMode=use-stored').rsplit('dispatchID=', 1)[0] + 'dispatchID=' + identifier
osa('tell application "Safari" to set URL of current tab of window id ' + window + ' to ' + json.dumps(url))
wait(lambda: javascript(window, 'Boolean(document.querySelector("#dispatch-media-player")&&video.readyState>=2)') == 'true')
dispatch(window)
complete(identifier, 'no-source')
close(window)
print('PASS navigation invalidates an unclaimed ticket', flush=True)
window, identifier, _ = page('unused-close')
started = time.monotonic()
dispatch(window)
wait(lambda: report(identifier, 'dispatched'))
wait(lambda: report(identifier, 'unloaded'), 45)
assert time.monotonic() - started >= 29, 'Unclaimed ticket did not retain the source'
print('PASS an unclaimed ticket releases its closed source page', flush=True)
control.write_text('{}')
print('PASS prepared handoff dispatch, claim, replay, cancellation, expiry, tab and document isolation', flush=True)
