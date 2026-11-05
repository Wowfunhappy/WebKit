#!/usr/bin/env python3
"""A closed tab's page goes once its handoff no longer needs it, and a receiver keeps playing."""
import json
import subprocess
import time
import urllib.request

proxyless = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def osa(script):
    return subprocess.check_output(['osascript', '-e', script], timeout=40, stderr=subprocess.STDOUT).decode().strip()


def read(url):
    return proxyless.open(url, timeout=10).read()


def wait(condition, seconds=60):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = condition()
        if value:
            return value
        time.sleep(.25)
    raise AssertionError('Timeout')


def open_page(query):
    read('http://127.0.0.1:8843/reset')
    osa('tell application "QuickTime Player" to close every document saving no')
    osa('tell application "Safari" to make new document with properties {URL:' + json.dumps('http://127.0.0.1:8843/quicktime.html?' + query) + '}')
    window = osa('tell application "Safari" to get id of front window')

    def js(script):
        return osa('tell application "Safari" to do JavaScript ' + json.dumps(script) + ' in current tab of window id ' + window)
    wait(lambda: js('Boolean(document.querySelector("video")?.readyState>=2&&document.querySelector("#open-media-player"))') == 'true')
    js('window.addEventListener("pagehide",()=>navigator.sendBeacon("/report-page-gone","gone"));1')
    return window, js


def page_gone():
    return any(entry.get('path') == '/report-page-gone' for entry in json.loads(read('http://127.0.0.1:8843/log')))


def receiver_playing():
    return osa('tell application "QuickTime Player" to get playing of document 1') == 'true'


def assert_receiver_advances():
    position = float(osa('tell application "QuickTime Player" to get current time of document 1'))
    wait(lambda: float(osa('tell application "QuickTime Player" to get current time of document 1')) > position + .5, 15)


def result_of(js):
    return json.loads(wait(lambda: (lambda value: value if value.startswith('{') else None)(js('document.querySelector("#media-player-result").textContent'))))


# Capture with the tab closed: the page goes at completion, and the movie plays on.
window, js = open_page('source=av-short.mp4&sourceMode=capture')
js('video.play();1')
wait(lambda: float(js('video.currentTime')) > .5)
js('document.querySelector("#open-media-player").click()')
assert result_of(js).get('method') == 'restream'
osa('tell application "Safari" to close window id ' + window)
time.sleep(1)
wait(page_gone, 30)
assert_receiver_advances()
print('capture: page released at completion, movie plays on', flush=True)

# Direct with the tab closed: nothing needs the page.
window, js = open_page('source=plain.mp4')
js('video.play();1')
js('document.querySelector("#open-media-player").click()')
assert result_of(js).get('method') == 'url'
osa('tell application "Safari" to close window id ' + window)
wait(page_gone, 15)
assert_receiver_advances()
print('direct: page released, movie plays on', flush=True)

# A capture still producing keeps a closed tab's page.
window, js = open_page('source=mse.mp4&sourceMode=capture')
js('video.play();1')
wait(lambda: float(js('video.currentTime')) > .5)
js('document.querySelector("#open-media-player").click()')
assert result_of(js).get('method') == 'restream'
osa('tell application "Safari" to close window id ' + window)
time.sleep(5)
assert not page_gone(), 'The page went while its capture was producing'
assert_receiver_advances()
osa('tell application "QuickTime Player" to close every document saving no')
wait(page_gone, 20)
print('producing capture: page kept until the receiver closed', flush=True)

# A capture whose source ends before it opens, with the tab already closed, still opens.
window, js = open_page('source=av-short.mp4&captureLifetime=open-after-end')
js('document.querySelector("#open-media-player").click()')
wait(lambda: js('document.querySelector("#media-player-result").dataset.captured') == 'yes', 30)
osa('tell application "Safari" to close window id ' + window)
wait(lambda: osa('tell application "QuickTime Player" to count documents') != '0', 40)
wait(lambda: float(osa('tell application "QuickTime Player" to get current time of document 1')) > .5, 30)
wait(page_gone, 30)
print('capture opened after its source ended and its tab closed', flush=True)

# A relayed playlist's server is the page's own, so a closed tab's page stays while the movie plays.
window, js = open_page('source=index.m3u8&relayPlaylists=true')
js('video.play();1')
js('document.querySelector("#open-media-player").click()')
assert result_of(js).get('method') == 'url'
osa('tell application "Safari" to close window id ' + window)
time.sleep(5)
assert not page_gone(), 'The page went while its relay was serving'
assert_receiver_advances()
osa('tell application "QuickTime Player" to close every document saving no')
wait(page_gone, 20)
print('relay: page kept until the receiver closed', flush=True)

# An open tab keeps its session after a capture completes.
window, js = open_page('source=av-short.mp4&captureLifetime=reuse')
js('document.querySelector("#open-media-player").click()')
result = result_of(js)
assert result.get('method') == 'second-publish', result
assert not page_gone()
osa('tell application "QuickTime Player" to close every document saving no')
osa('tell application "Safari" to close window id ' + window)
print('PASS closed tabs release, receivers keep playing, open sessions stay usable', flush=True)
